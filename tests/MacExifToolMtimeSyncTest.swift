import Foundation

@main
struct MacExifToolMtimeSyncTest {
  static func unixJST(_ raw: String) -> Int64 {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(secondsFromGMT: 9 * 3600)
    fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
    return Int64((fmt.date(from: raw)!.timeIntervalSince1970 * 1000).rounded())
  }

  static func check(_ condition: Bool, _ reason: String) {
    precondition(condition, reason)
  }

  static func main() throws {
    let args = CommandLine.arguments
    precondition(args.count == 3, "Expected synthetic JPEG and ExifTool executable")
    let originalFixture = URL(fileURLWithPath: args[1])
    let tool = args[2]
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(
      "exiftool-mtime-mvp-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let image = root.appendingPathComponent("sample.jpg")
    try FileManager.default.copyItem(at: originalFixture, to: image)
    let beforeBytes = try Data(contentsOf: image)
    let old = try FileManager.default.attributesOfItem(atPath: image.path)
    let beforeMs = Int64((((old[.modificationDate] as! Date).timeIntervalSince1970) * 1000).rounded())
    let targetMs = unixJST("2024:01:02 03:04:05")
    check(targetMs != beforeMs, "Synthetic sample must need an mtime update")

    let storage = root.appendingPathComponent("history", isDirectory: true)
    let sync = try ExifToolMtimeSync(storageDirectory: storage, exiftool: tool)
    let plan = ExifToolMtimeSync.Plan(relativePath: "sample.jpg", beforeMs: beforeMs, targetMs: targetMs)

    // A second hard link shares the inode and mtime. Its path may be inside
    // the test root even though the underlying file also exists outside it.
    let linked = root.appendingPathComponent("hardlink.jpg")
    try FileManager.default.linkItem(at: image, to: linked)
    do {
      _ = try sync.apply(root: root, plans: [
        .init(relativePath: "hardlink.jpg", beforeMs: beforeMs, targetMs: targetMs)
      ], replaceConfirmed: false, captureTime: { _ in targetMs })
      fatalError("A hard-linked image was accepted")
    } catch ExifToolMtimeSync.Failure.changed {}
    check((try sync.summary())["exists"] as? Bool == false,
          "Hard-link rejection must not write journal")
    try FileManager.default.removeItem(at: linked)

    // Incorrect or missing EXIF cannot update a file, even if it has a name and mtime.
    do {
      _ = try sync.apply(root: root, plans: [plan], replaceConfirmed: false,
                         captureTime: { _ in nil })
      fatalError("No EXIF capture timestamp was accepted")
    } catch ExifToolMtimeSync.Failure.changed {}
    check((try sync.summary())["exists"] as? Bool == false, "Rejected scan must not write journal")

    do {
      _ = try sync.apply(root: root, plans: [plan], replaceConfirmed: false,
                         captureTime: { _ in targetMs + 10_000 })
      fatalError("Stale metadata was accepted")
    } catch ExifToolMtimeSync.Failure.changed {}

    // Two selected files turn invalid before execution. Only the valid JPEG
    // should be changed, and rejected files must keep their original mtime.
    let stale = root.appendingPathComponent("stale.jpg")
    let undated = root.appendingPathComponent("undated.jpg")
    try FileManager.default.copyItem(at: originalFixture, to: stale)
    try FileManager.default.copyItem(at: originalFixture, to: undated)
    let staleAttrs = try FileManager.default.attributesOfItem(atPath: stale.path)
    let undatedAttrs = try FileManager.default.attributesOfItem(atPath: undated.path)
    let staleBytes = try Data(contentsOf: stale)
    let undatedBytes = try Data(contentsOf: undated)
    let updated = try sync.apply(root: root, plans: [
      .init(relativePath: "stale.jpg", beforeMs: -1, targetMs: targetMs),
      .init(relativePath: "undated.jpg", beforeMs: Int64(
        ((undatedAttrs[.modificationDate] as! Date).timeIntervalSince1970 * 1000).rounded()),
        targetMs: targetMs),
      plan
    ], replaceConfirmed: false, captureTime: { url in
      url.lastPathComponent == "undated.jpg" ? nil : targetMs
    })
    check(updated["applied"] as? Int == 1, "Expected one applied file")
    check(updated["skipped"] as? Int == 2, "Only invalid files should be skipped")
    check(updated["appliedPaths"] as? [String] == [plan.relativePath], "Applied paths incorrect")
    check(Set(updated["skippedPaths"] as? [String] ?? []) == Set(["stale.jpg", "undated.jpg"]),
          "Skipped paths incorrect")
    check(try Data(contentsOf: stale) == staleBytes &&
          Data(contentsOf: undated) == undatedBytes, "Skipped image contents changed")
    let staleNow = try FileManager.default.attributesOfItem(atPath: stale.path)
    let undatedNow = try FileManager.default.attributesOfItem(atPath: undated.path)
    check((staleNow[.modificationDate] as! Date) == (staleAttrs[.modificationDate] as! Date) &&
          (undatedNow[.modificationDate] as! Date) == (undatedAttrs[.modificationDate] as! Date),
          "Skipped image mtime changed")
    let changed = try FileManager.default.attributesOfItem(atPath: image.path)
    let changedMs = Int64((((changed[.modificationDate] as! Date).timeIntervalSince1970) * 1000).rounded())
    check(abs(changedMs - targetMs) <= 1000, "ExifTool did not set expected UTC instant")
    check(try Data(contentsOf: image) == beforeBytes, "Image or EXIF bytes changed after update")

    // A fresh coordinator reads the latest batch from a persisted JSON journal.
    let reopened = try ExifToolMtimeSync(storageDirectory: storage, exiftool: tool)
    let restored = try reopened.undo(approvedRoot: root)
    check(restored["undone"] as? Int == 1, "Reopened journal Undo failed")
    let back = try FileManager.default.attributesOfItem(atPath: image.path)
    let restoredMs = Int64((((back[.modificationDate] as! Date).timeIntervalSince1970) * 1000).rounded())
    check(abs(restoredMs - beforeMs) <= 1000, "Undo did not restore previous mtime")
    check(try Data(contentsOf: image) == beforeBytes, "Image bytes changed after Undo")

    // Rejecting every image must never overwrite the previous Undo history.
    let previous = try sync.summary()
    do {
      _ = try sync.apply(root: root, plans: [
        .init(relativePath: "sample.jpg", beforeMs: -1, targetMs: targetMs)
      ], replaceConfirmed: true, captureTime: { _ in targetMs })
      fatalError("An all-skipped batch was accepted")
    } catch ExifToolMtimeSync.Failure.changed {}
    check((try sync.summary())["undone"] as? Int == previous["undone"] as? Int,
          "An all-skipped batch erased previous Undo history")

    // Path traversal is rejected without changing any file.
    do {
      _ = try sync.apply(root: root,
                         plans: [.init(relativePath: "../sample.jpg", beforeMs: beforeMs,
                                       targetMs: targetMs)],
                         replaceConfirmed: true, captureTime: { _ in targetMs })
      fatalError("Path traversal was accepted")
    } catch ExifToolMtimeSync.Failure.changed {}

    // If a file changes after prevalidation but before its mtime write, skip
    // only that file and leave the successful rows available for Undo.
    let lateA = root.appendingPathComponent("late-a.jpg")
    let lateB = root.appendingPathComponent("late-b.jpg")
    try FileManager.default.copyItem(at: originalFixture, to: lateA)
    try FileManager.default.copyItem(at: originalFixture, to: lateB)
    let attrsA = try FileManager.default.attributesOfItem(atPath: lateA.path)
    let attrsB = try FileManager.default.attributesOfItem(atPath: lateB.path)
    let beforeA = Int64((((attrsA[.modificationDate] as! Date).timeIntervalSince1970) * 1000).rounded())
    let beforeB = Int64((((attrsB[.modificationDate] as! Date).timeIntervalSince1970) * 1000).rounded())
    let lateSync = try ExifToolMtimeSync(
      storageDirectory: root.appendingPathComponent("late-history", isDirectory: true),
      exiftool: tool)
    let lateReport = try lateSync.apply(root: root, plans: [
      .init(relativePath: "late-a.jpg", beforeMs: beforeA, targetMs: targetMs),
      .init(relativePath: "late-b.jpg", beforeMs: beforeB, targetMs: targetMs)
    ], replaceConfirmed: false, captureTime: { url in
      if url.lastPathComponent == "late-b.jpg" {
        try FileManager.default.setAttributes([
          .modificationDate: Date(timeIntervalSince1970: 1_600_000_000)
        ], ofItemAtPath: lateA.path)
      }
      return targetMs
    })
    check(lateReport["applied"] as? Int == 1 &&
          lateReport["skipped"] as? Int == 1 &&
          lateReport["unresolved"] as? Int == 0,
          "A stale pre-write file blocked a valid update")
    check((lateReport["skippedPaths"] as? [String])?.count == 1,
          "Late skip path missing")
    let lateUndo = try lateSync.undo(approvedRoot: root)
    check(lateUndo["undone"] as? Int == 1,
          "Undo was unavailable after an unwritten file was skipped")

    // A file removed after prevalidation must also be skipped. Its disappearance
    // must not block a second valid file or the latest-batch Undo.
    let missingA = root.appendingPathComponent("missing-a.jpg")
    let remainingB = root.appendingPathComponent("remaining-b.jpg")
    try FileManager.default.copyItem(at: originalFixture, to: missingA)
    try FileManager.default.copyItem(at: originalFixture, to: remainingB)
    let missingAttrs = try FileManager.default.attributesOfItem(atPath: missingA.path)
    let remainingAttrs = try FileManager.default.attributesOfItem(atPath: remainingB.path)
    let missingBefore = Int64((((missingAttrs[.modificationDate] as! Date).timeIntervalSince1970) * 1000).rounded())
    let remainingBefore = Int64((((remainingAttrs[.modificationDate] as! Date).timeIntervalSince1970) * 1000).rounded())
    let missingSync = try ExifToolMtimeSync(
      storageDirectory: root.appendingPathComponent("missing-history", isDirectory: true),
      exiftool: tool)
    let missingReport = try missingSync.apply(root: root, plans: [
      .init(relativePath: "missing-a.jpg", beforeMs: missingBefore, targetMs: targetMs),
      .init(relativePath: "remaining-b.jpg", beforeMs: remainingBefore, targetMs: targetMs)
    ], replaceConfirmed: false, captureTime: { url in
      if url.lastPathComponent == "remaining-b.jpg" {
        try FileManager.default.removeItem(at: missingA)
      }
      return targetMs
    })
    check(missingReport["applied"] as? Int == 1 &&
          missingReport["skipped"] as? Int == 1 &&
          missingReport["unresolved"] as? Int == 0,
          "A disappeared pre-write file blocked valid updates")
    let missingUndo = try missingSync.undo(approvedRoot: root)
    check(missingUndo["undone"] as? Int == 1,
          "Undo unavailable after pre-write file disappearance")

    // Undo must preserve fractional milliseconds from the original file mtime.
    // Previously the ExifTool timestamp string omitted ".SSS" and lost them.
    let fractional = root.appendingPathComponent("fractional.jpg")
    try FileManager.default.copyItem(at: originalFixture, to: fractional)
    try FileManager.default.setAttributes([
      .modificationDate: Date(timeIntervalSince1970: 1_700_000_000.375)
    ], ofItemAtPath: fractional.path)
    let fractionalOld = try FileManager.default.attributesOfItem(atPath: fractional.path)
    let fractionalBefore = Int64((((fractionalOld[.modificationDate] as! Date)
      .timeIntervalSince1970) * 1000).rounded())
    check(fractionalBefore % 1000 != 0, "Fractional mtime fixture was rounded to seconds")
    let fractionalSync = try ExifToolMtimeSync(
      storageDirectory: root.appendingPathComponent("fractional-history", isDirectory: true),
      exiftool: tool)
    let fractionalResult = try fractionalSync.apply(root: root, plans: [
      .init(relativePath: "fractional.jpg", beforeMs: fractionalBefore, targetMs: targetMs)
    ], replaceConfirmed: false, captureTime: { _ in targetMs })
    check(fractionalResult["applied"] as? Int == 1, "Fractional test update failed")
    let fractionalReopened = try ExifToolMtimeSync(
      storageDirectory: root.appendingPathComponent("fractional-history", isDirectory: true),
      exiftool: tool)
    let fractionalUndo = try fractionalReopened.undo(approvedRoot: root)
    check(fractionalUndo["undone"] as? Int == 1, "Fractional test Undo failed")
    let fractionalRestored = try FileManager.default.attributesOfItem(atPath: fractional.path)
    let fractionalRestoredMs = Int64((((fractionalRestored[.modificationDate] as! Date)
      .timeIntervalSince1970) * 1000).rounded())
    check(abs(fractionalRestoredMs - fractionalBefore) <= 1,
          "Undo lost original mtime milliseconds")

    let fractionalTarget = targetMs + 375
    let subsecondResult = try fractionalSync.apply(root: root, plans: [
      .init(relativePath: "fractional.jpg", beforeMs: fractionalRestoredMs,
            targetMs: fractionalTarget)
    ], replaceConfirmed: true, captureTime: { _ in fractionalTarget })
    check(subsecondResult["applied"] as? Int == 1, "Subsecond update failed")
    let subsecondAttrs = try FileManager.default.attributesOfItem(atPath: fractional.path)
    let subsecondMs = Int64((((subsecondAttrs[.modificationDate] as! Date)
      .timeIntervalSince1970) * 1000).rounded())
    check(abs(subsecondMs - fractionalTarget) <= 1, "Update lost capture milliseconds")
    _ = try fractionalSync.undo(approvedRoot: root)
    let subsecondUndo = try FileManager.default.attributesOfItem(atPath: fractional.path)
    let subsecondUndoMs = Int64((((subsecondUndo[.modificationDate] as! Date)
      .timeIntervalSince1970) * 1000).rounded())
    check(abs(subsecondUndoMs - fractionalBefore) <= 1, "Subsecond Undo failed")

    _ = try fractionalSync.apply(root: root, plans: [
      .init(relativePath: "fractional.jpg", beforeMs: subsecondUndoMs,
            targetMs: fractionalTarget)
    ], replaceConfirmed: true, captureTime: { _ in fractionalTarget })
    let conflictingMs = fractionalTarget + 250
    try FileManager.default.setAttributes([
      .modificationDate: Date(timeIntervalSince1970: Double(conflictingMs) / 1000)
    ], ofItemAtPath: fractional.path)
    let changedUndo = try fractionalSync.undo(approvedRoot: root)
    check(changedUndo["unresolved"] as? Int == 1, "Undo accepted a changed subsecond mtime")
    let changedAttrs = try FileManager.default.attributesOfItem(atPath: fractional.path)
    let changedAfter = Int64((((changedAttrs[.modificationDate] as! Date)
      .timeIntervalSince1970) * 1000).rounded())
    check(abs(changedAfter - conflictingMs) <= 1, "Undo changed a conflicting file")

    // A changed file must not be reverted based on stale history.
    // ExifTool may store only seconds. A new scan must provide fresh beforeMs
    // instead of reusing the old pre-Undo milliseconds.
    let renewed = ExifToolMtimeSync.Plan(
      relativePath: "sample.jpg", beforeMs: restoredMs, targetMs: targetMs)
    _ = try sync.apply(root: root, plans: [renewed], replaceConfirmed: true,
                       captureTime: { _ in targetMs })
    try FileManager.default.setAttributes([
      .modificationDate: Date(timeIntervalSince1970: 1_600_000_000)
    ], ofItemAtPath: image.path)
    let conflict = try reopened.undo(approvedRoot: root)
    check(conflict["undone"] as? Int == 0, "Conflicted file was incorrectly restored")
    check(conflict["unresolved"] as? Int == 1, "Conflict must block a new batch")
    check(try Data(contentsOf: image) == beforeBytes, "Conflicted file bytes changed")

    // Cooperative cancellation uses a separate journal and disposable copies.
    // Stopping before the first write must not create or replace history.
    let cancelA = root.appendingPathComponent("cancel-a.jpg")
    let cancelB = root.appendingPathComponent("cancel-b.jpg")
    try FileManager.default.copyItem(at: originalFixture, to: cancelA)
    try FileManager.default.copyItem(at: originalFixture, to: cancelB)
    let controlledBefore = Date(timeIntervalSince1970: 1_700_000_000)
    for file in [cancelA, cancelB] {
      try FileManager.default.setAttributes([.modificationDate: controlledBefore],
                                            ofItemAtPath: file.path)
    }
    let cancelBeforeMs = Int64((controlledBefore.timeIntervalSince1970 * 1000).rounded())
    check(cancelBeforeMs != targetMs, "Cancellation fixtures must need updates")
    let cancelABytes = try Data(contentsOf: cancelA)
    let cancelBBytes = try Data(contentsOf: cancelB)
    let cancelStorage = root.appendingPathComponent("cancel-history", isDirectory: true)
    let cancelSync = try ExifToolMtimeSync(storageDirectory: cancelStorage, exiftool: tool)
    let cancellationPlans: [ExifToolMtimeSync.Plan] = [
      .init(relativePath: "cancel-a.jpg", beforeMs: cancelBeforeMs, targetMs: targetMs),
      .init(relativePath: "cancel-b.jpg", beforeMs: cancelBeforeMs, targetMs: targetMs)
    ]
    let cancelledEarly = try cancelSync.apply(
      root: root, plans: cancellationPlans, replaceConfirmed: false,
      shouldCancel: { true }, captureTime: { _ in targetMs })
    check(cancelledEarly["cancelled"] as? Bool == true &&
          cancelledEarly["applied"] as? Int == 0 &&
          cancelledEarly["remaining"] as? Int == 2,
          "Early cancellation should report two untouched files")
    check((try cancelSync.summary())["exists"] as? Bool == false,
          "Early cancellation created a journal")

    // After the first image finishes, the next image is not touched.
    let partial = try cancelSync.apply(
      root: root, plans: cancellationPlans, replaceConfirmed: false,
      shouldCancel: {
        let attributes = try? FileManager.default.attributesOfItem(atPath: cancelA.path)
        guard let updatedTime = attributes?[.modificationDate] as? Date else {
          return false
        }
        let updatedMs = Int64((updatedTime.timeIntervalSince1970 * 1000).rounded())
        return abs(updatedMs - targetMs) <= 1
      }, captureTime: { _ in targetMs })
    check(partial["cancelled"] as? Bool == true &&
          partial["applied"] as? Int == 1 &&
          partial["remaining"] as? Int == 1 &&
          partial["skipped"] as? Int == 0,
          "Cancellation after first file must leave exactly one file untouched")
    check(partial["appliedPaths"] as? [String] == ["cancel-a.jpg"],
          "Cancelled batch reported an unexpected applied file")
    let cancelBAttrs = try FileManager.default.attributesOfItem(atPath: cancelB.path)
    let cancelBNow = Int64((((cancelBAttrs[.modificationDate] as! Date)
      .timeIntervalSince1970) * 1000).rounded())
    check(abs(cancelBNow - cancelBeforeMs) <= 1,
          "Cancellation changed the file that was not yet attempted")
    check(try Data(contentsOf: cancelA) == cancelABytes &&
          Data(contentsOf: cancelB) == cancelBBytes,
          "Cancellation changed image or EXIF bytes")
    let cancelReopened = try ExifToolMtimeSync(storageDirectory: cancelStorage, exiftool: tool)
    let cancelUndo = try cancelReopened.undo(approvedRoot: root)
    check(cancelUndo["undone"] as? Int == 1 && cancelUndo["unresolved"] as? Int == 0,
          "Restart Undo was lost after cancelling a partial batch")
    let cancelAAttrs = try FileManager.default.attributesOfItem(atPath: cancelA.path)
    let cancelARestoredMs = Int64((((cancelAAttrs[.modificationDate] as! Date)
      .timeIntervalSince1970) * 1000).rounded())
    check(abs(cancelARestoredMs - cancelBeforeMs) <= 1,
          "Cancellation Undo did not restore the first file")

    // A newly cancelled batch must not erase a previously completed Undo record.
    let savedHistory = try cancelReopened.summary()
    let cancelledAgain = try cancelReopened.apply(
      root: root, plans: cancellationPlans, replaceConfirmed: true,
      shouldCancel: { true }, captureTime: { _ in targetMs })
    check(cancelledAgain["cancelled"] as? Bool == true,
          "Cancellation with existing history was ignored")
    let savedAfterCancel = try cancelReopened.summary()
    check(savedAfterCancel["count"] as? Int == savedHistory["count"] as? Int &&
          savedAfterCancel["undone"] as? Int == savedHistory["undone"] as? Int &&
          savedAfterCancel["unresolved"] as? Int == 0,
          "Cancellation before writing erased existing Undo journal")

    // Simulate cancellation arriving after a prepared journal was saved but
    // before the first write. A previous Undo record must survive.
    var stopChecks = 0
    let cancelledAtWriteBoundary = try cancelReopened.apply(
      root: root, plans: cancellationPlans, replaceConfirmed: true,
      shouldCancel: {
        stopChecks += 1
        // Two preflight rows, one pre-journal check, then first write boundary.
        return stopChecks == 4
      }, captureTime: { _ in targetMs })
    check(cancelledAtWriteBoundary["cancelled"] as? Bool == true &&
          cancelledAtWriteBoundary["applied"] as? Int == 0,
          "Cancellation at first write boundary should not update any file")
    let restoredHistory = try cancelReopened.summary()
    check(restoredHistory["count"] as? Int == savedHistory["count"] as? Int &&
          restoredHistory["undone"] as? Int == savedHistory["undone"] as? Int,
          "Cancellation at first write boundary erased earlier Undo data")

    print("ExifToolMtimeSync: cancellation before write, partial stop, persisted Undo PASS")

    print("ExifToolMtimeSync: EXIF-only test, update, content integrity, restart Undo, conflict PASS")
  }
}
