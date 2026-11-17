import Foundation

/// Small ExifTool-only mtime writer for the personal macOS app.
/// A journal holds just the latest batch. Image bytes and EXIF are never written
/// by this class; the only ExifTool assignment is FileModifyDate.
final class ExifToolMtimeSync {
  struct Plan {
    let relativePath: String
    let beforeMs: Int64
    let targetMs: Int64
  }

  struct Entry: Codable {
    var relativePath: String
    var beforeMs: Int64
    var targetMs: Int64
    var size: Int64
    var inode: UInt64
    var device: UInt64
    var state: String
  }

  struct Batch: Codable {
    let root: String
    var entries: [Entry]
  }

  enum Failure: Error {
    case invalidPath, changed, unresolved, confirmationRequired
    case missingHistory, wrongFolder, failed(String)
  }

  private let journalURL: URL
  private let tool: String

  init(storageDirectory: URL, exiftool: String) throws {
    try FileManager.default.createDirectory(
      at: storageDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    journalURL = storageDirectory.appendingPathComponent("last-batch.json")
    tool = exiftool
  }

  private func read() throws -> Batch? {
    guard FileManager.default.fileExists(atPath: journalURL.path) else { return nil }
    let data = try Data(contentsOf: journalURL)
    return try JSONDecoder().decode(Batch.self, from: data)
  }

  private func store(_ batch: Batch) throws {
    // A complete JSON replacement is written before any file attribute change.
    let data = try JSONEncoder().encode(batch)
    try data.write(to: journalURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                          ofItemAtPath: journalURL.path)
  }

  private func secureFile(root: URL, relative: String) throws -> (URL, [FileAttributeKey: Any]) {
    guard root.isFileURL, root.path == root.standardizedFileURL.path,
          root.path == root.resolvingSymlinksInPath().path else { throw Failure.invalidPath }
    let segments = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard !segments.isEmpty, segments.allSatisfy({
      !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\u{0000}")
    }) else { throw Failure.invalidPath }

    var url = root
    for segment in segments {
      url.appendPathComponent(segment)
      let vals = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
      guard vals.isSymbolicLink != true else { throw Failure.invalidPath }
    }
    guard url.standardizedFileURL.path.hasPrefix(root.path + "/"),
          url.path == url.resolvingSymlinksInPath().path else { throw Failure.invalidPath }
    let vals = try url.resourceValues(forKeys: [.isRegularFileKey])
    guard vals.isRegularFile == true else { throw Failure.invalidPath }
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    // Changing a hard link's mtime would also change the original file outside
    // the selected folder. Reject files with multiple hard links.
    guard let references = attrs[.referenceCount] as? NSNumber,
          references.intValue == 1 else { throw Failure.invalidPath }
    return (url, attrs)
  }

  private func ms(_ attrs: [FileAttributeKey: Any]) throws -> Int64 {
    guard let d = attrs[.modificationDate] as? Date else { throw Failure.invalidPath }
    return Int64((d.timeIntervalSince1970 * 1000).rounded())
  }

  private func identity(_ attrs: [FileAttributeKey: Any]) throws -> (Int64, UInt64, UInt64) {
    guard let size = attrs[.size] as? NSNumber,
          let inode = attrs[.systemFileNumber] as? NSNumber,
          let device = attrs[.systemNumber] as? NSNumber else { throw Failure.invalidPath }
    return (size.int64Value, inode.uint64Value, device.uint64Value)
  }

  private func value(_ timestamp: Int64) -> String {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(secondsFromGMT: 0)
    // Retain millisecond precision so Undo can restore the original mtime.
    fmt.dateFormat = "yyyy:MM:dd HH:mm:ss.SSS"
    return fmt.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)) + "+00:00"
  }

  private func setMtime(_ url: URL, to timestamp: Int64) throws {
    // ExifTool's filesystem timestamp writer can discard fractional seconds.
    // Foundation sets only the filesystem mtime and retains milliseconds.
    if timestamp % 1000 != 0 {
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)],
        ofItemAtPath: url.path)
      return
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = ["-FileModifyDate=" + value(timestamp), "--", url.path]
    let output = Pipe()
    p.standardOutput = output
    p.standardError = output
    try p.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
      // Do not include private paths or ExifTool stdout in UI/error logs.
      _ = data
      throw Failure.failed("ExifToolが変更日時を更新できませんでした")
    }
  }

  func summary() throws -> [String: Any] {
    guard let b = try read() else { return ["exists": false] }
    let applied = b.entries.filter { $0.state == "applied" }.count
    let undone = b.entries.filter { $0.state == "undone" }.count
    let unresolved = b.entries.filter { $0.state == "pending" ||
      $0.state == "undoPending" || $0.state == "conflict" }.count
    return ["exists": true, "count": b.entries.count, "applied": applied,
            "undone": undone, "unresolved": unresolved, "root": b.root]
  }

  /// Reread the EXIF capture timestamp immediately before writing. The caller
  /// supplies the same EXIF-only parser used to build the preview.
  func apply(root: URL, plans: [Plan], replaceConfirmed: Bool,
             shouldCancel: () -> Bool = { false },
             captureTime: (URL) throws -> Int64?) throws -> [String: Any] {
    guard !plans.isEmpty else { throw Failure.invalidPath }
    let previous = try read()
    if let previous {
      guard !previous.entries.contains(where: { ["pending", "undoPending", "conflict"].contains($0.state) })
        else { throw Failure.unresolved }
      guard replaceConfirmed else { throw Failure.confirmationRequired }
    }
    var names = Set<String>()
    var entries: [Entry] = []
    var skipped = 0
    var skippedPaths: [String] = []
    // Cancel before the first journal replacement to preserve prior Undo.
    func cancelledBeforeWrite() -> [String: Any] {
      return ["cancelled": true, "applied": 0, "skipped": skipped,
              "remaining": plans.count - skipped,
              "appliedPaths": [String](), "skippedPaths": skippedPaths]
    }
    for plan in plans {
      if shouldCancel() { return cancelledBeforeWrite() }
      guard names.insert(plan.relativePath).inserted else { throw Failure.invalidPath }
      // An unreadable or changed image is skipped, not a batch-wide failure.
      guard let (file, attrs) = try? secureFile(root: root, relative: plan.relativePath),
            let (size, inode, dev) = try? identity(attrs),
            let before = try? ms(attrs), before == plan.beforeMs,
            let capture = try? captureTime(file), capture == plan.targetMs else {
        skipped += 1
        skippedPaths.append(plan.relativePath)
        continue
      }
      entries.append(Entry(relativePath: plan.relativePath, beforeMs: plan.beforeMs,
                           targetMs: plan.targetMs, size: size, inode: inode,
                           device: dev, state: "prepared"))
    }
    // No writes or journal replacement when cancelled during validation.
    if shouldCancel() { return cancelledBeforeWrite() }
    // No writes or journal replacement when every selected image was skipped.
    guard !entries.isEmpty else { throw Failure.changed }
    var batch = Batch(root: root.path, entries: entries)
    try store(batch)
    var cancelledAfterWriteStarted = false
    var attemptedWrite = false
    for i in batch.entries.indices {
      // Finish any current file and its journal before stopping the next.
      if shouldCancel() {
        if !attemptedWrite {
          // Cancellation can arrive just after the new prepared journal was
          // saved. Restore the old one if no mtime write was attempted.
          if let previous {
            try store(previous)
          } else {
            try FileManager.default.removeItem(at: journalURL)
          }
          return cancelledBeforeWrite()
        }
        cancelledAfterWriteStarted = true
        break
      }
      let entry = batch.entries[i]
      guard let (file, attrs) = try? secureFile(root: root, relative: entry.relativePath),
            let (size, inode, dev) = try? identity(attrs),
            let before = try? ms(attrs),
            size == entry.size, inode == entry.inode, dev == entry.device,
            before == entry.beforeMs else {
        // No write was attempted. A stale file must not block Undo of valid files.
        batch.entries[i].state = "skipped"
        skipped += 1
        skippedPaths.append(entry.relativePath)
        try store(batch)
        continue
      }
      batch.entries[i].state = "pending"
      try store(batch)
      attemptedWrite = true
      try setMtime(file, to: entry.targetMs)
      let (_, after) = try secureFile(root: root, relative: entry.relativePath)
      let (sizeAfter, inodeAfter, devAfter) = try identity(after)
      guard sizeAfter == entry.size, inodeAfter == entry.inode, devAfter == entry.device,
            abs(try ms(after) - entry.targetMs) <= 1 else {
        throw Failure.changed  // Preserve pending for review.
      }
      batch.entries[i].state = "applied"
      try store(batch)
    }
    var result = try summary()
    result["skipped"] = skipped
    result["cancelled"] = cancelledAfterWriteStarted
    result["remaining"] = batch.entries.filter { $0.state == "prepared" }.count
    result["appliedPaths"] = batch.entries.filter { $0.state == "applied" }.map(\.relativePath)
    result["skippedPaths"] = skippedPaths
    return result
  }

  func undo(approvedRoot: URL) throws -> [String: Any] {
    guard var batch = try read() else { throw Failure.missingHistory }
    guard approvedRoot.path == batch.root else { throw Failure.wrongFolder }
    guard !batch.entries.contains(where: { $0.state == "pending" ||
      $0.state == "undoPending" }) else { throw Failure.unresolved }
    for i in batch.entries.indices where batch.entries[i].state == "applied" {
      let entry = batch.entries[i]
      guard let (file, attrs) = try? secureFile(root: approvedRoot, relative: entry.relativePath),
            let (size, inode, dev) = try? identity(attrs),
            let current = try? ms(attrs),
            size == entry.size, inode == entry.inode, dev == entry.device,
            abs(current - entry.targetMs) <= 1 else {
        batch.entries[i].state = "conflict"
        try store(batch)
        continue
      }
      batch.entries[i].state = "undoPending"
      try store(batch)
      try setMtime(file, to: entry.beforeMs)
      let (_, after) = try secureFile(root: approvedRoot, relative: entry.relativePath)
      guard abs(try ms(after) - entry.beforeMs) <= 1 else {
        throw Failure.changed  // Keep unresolved journal, never auto-retry.
      }
      batch.entries[i].state = "undone"
      try store(batch)
    }
    return try summary()
  }
}
