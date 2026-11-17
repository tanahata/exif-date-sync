// Compiled into Runner/MainFlutterWindow.swift by scripts/generate_macos_host.sh.
// Reads capture EXIF and updates mtime only in folders chosen by the user.
// The ExifTool executable is installed separately (e.g. via Homebrew).
final class ExifToolMacBridge {
  private let channel: FlutterMethodChannel
  private let queue = DispatchQueue(label: "dev.exifdatesync.macos.exif", qos: .userInitiated)
  private let lock = NSLock()
  private var cancelled = false
  private var scanning = false
  private var updating = false
  private var updateCancelRequested = false
  private var approvedRoot: String?

  init(controller: FlutterViewController) {
    channel = FlutterMethodChannel(
      name: "dev.exifdatesync/macos",
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "CLOSED", message: "The window was closed", details: nil))
        return
      }
      self.handle(call, result)
    }
  }

  private func setState(scanning next: Bool, cancelled cancel: Bool) {
    lock.lock()
    scanning = next
    cancelled = cancel
    lock.unlock()
  }

  private func isCancelled() -> Bool {
    lock.lock()
    let value = cancelled
    lock.unlock()
    return value
  }

  private func beginScan() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !scanning && !updating else { return false }
    scanning = true
    cancelled = false
    return true
  }

  private func beginUpdate(root: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard approvedRoot == root && !scanning && !updating else { return false }
    updating = true
    updateCancelRequested = false
    return true
  }

  private func isUpdateCancelled() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return updateCancelRequested
  }

  private func finishUpdate() {
    lock.lock()
    updating = false
    updateCancelRequested = false
    lock.unlock()
  }

  // Reused for both external viewing and the read-only thumbnail.
  private func imageForViewing(path: String, relative: String) -> URL? {
    let root = URL(fileURLWithPath: path).standardizedFileURL
    lock.lock()
    let authorized = approvedRoot == root.path
    lock.unlock()
    let segments = relative.split(separator: "/", omittingEmptySubsequences: false)
    let allowed = Set(["jpg", "jpeg", "png", "heic", "heif", "hif", "arw", "rwl",
                       "rw2", "orf", "dng", "cr2", "cr3", "nef", "raf"])
    let file = root.appendingPathComponent(relative).standardizedFileURL
    guard authorized,
          !segments.isEmpty,
          segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
          file.path.hasPrefix(root.path + "/"),
          file.resolvingSymlinksInPath().standardizedFileURL.path == file.path,
          allowed.contains(file.pathExtension.lowercased()),
          let properties = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
          properties.isRegularFile == true,
          properties.isSymbolicLink != true else { return nil }
    return file
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "checkExifTool":
      queue.async {
        do {
          let exiftool = try self.findExifTool()
          let info = try self.runProcess(executable: exiftool, arguments: ["-ver"])
          DispatchQueue.main.async {
            result(["path": exiftool, "version": info.trimmingCharacters(in: .whitespacesAndNewlines)])
          }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "EXIFTOOL", message: error.localizedDescription, details: nil))
          }
        }
      }

    case "pickFolder":
      // The standard open panel grants an explicit user choice.
      let dialog = NSOpenPanel()
      dialog.canChooseFiles = false
      dialog.canChooseDirectories = true
      dialog.allowsMultipleSelection = false
      dialog.canCreateDirectories = false
      dialog.prompt = "フォルダを選択"
      dialog.begin { response in
        guard response == .OK, let url = dialog.url else {
          result(nil)
          return
        }
        let selected = url.resolvingSymlinksInPath().standardizedFileURL.path
        self.lock.lock()
        self.approvedRoot = selected
        self.lock.unlock()
        result(selected)
      }

    case "cancelScan":
      lock.lock()
      cancelled = true
      lock.unlock()
      result(nil)

    case "cancelBatch":
      // Cooperative stop: the current file finishes and its journal is saved.
      lock.lock()
      if updating { updateCancelRequested = true }
      lock.unlock()
      result(nil)

    case "scanFolder":
      guard let args = call.arguments as? [String: Any],
            let requested = args["path"] as? String,
            let recursive = args["recursive"] as? Bool else {
        result(FlutterError(code: "ARGS", message: "Missing scan folder", details: nil))
        return
      }
      let root = URL(fileURLWithPath: requested).resolvingSymlinksInPath().standardizedFileURL
      let includeRaw = args["includeRaw"] as? Bool ?? true
      lock.lock()
      let allowed = approvedRoot == root.path
      lock.unlock()
      guard allowed else {
        result(FlutterError(code: "FOLDER", message: "Choose the folder again", details: nil))
        return
      }
      guard beginScan() else {
        result(FlutterError(code: "BUSY", message: "Scan already running", details: nil))
        return
      }
      queue.async {
        do {
          let tool = try self.findExifTool()
          let report = try self.scan(root: root, recursive: recursive, includeRaw: includeRaw, tool: tool)
          self.setState(scanning: false, cancelled: false)
          DispatchQueue.main.async { result(report) }
        } catch {
          self.setState(scanning: false, cancelled: false)
          DispatchQueue.main.async {
            result(FlutterError(code: "SCAN", message: error.localizedDescription, details: nil))
          }
        }
      }

    case "openFile":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            let relative = args["relativePath"] as? String,
            let file = imageForViewing(path: path, relative: relative) else {
        result(FlutterError(code: "SCOPE", message: "選択フォルダ内の画像だけを開けます", details: nil))
        return
      }
      guard NSWorkspace.shared.open(file) else {
        result(FlutterError(code: "OPEN", message: "既定のアプリで開けませんでした", details: nil))
        return
      }
      result(nil)

    case "thumbnail":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            let relative = args["relativePath"] as? String,
            let file = imageForViewing(path: path, relative: relative) else {
        result(nil)
        return
      }
      let request = QLThumbnailGenerator.Request(
        fileAt: file,
        size: CGSize(width: 360, height: 360),
        scale: 1,
        representationTypes: .thumbnail
      )
      QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, _ in
        let bytes: Data? = thumbnail.flatMap { representation in
          NSBitmapImageRep(cgImage: representation.cgImage)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.82])
        }
        DispatchQueue.main.async {
          result(bytes.map { FlutterStandardTypedData(bytes: $0) })
        }
      }

    case "checkWriteScope":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(false)
        return
      }
      let root = URL(fileURLWithPath: path).standardizedFileURL
      lock.lock()
      let selected = approvedRoot == root.path
      lock.unlock()
      result(selected)

    case "lastBatch":
      queue.async {
        do {
          let updater = try self.mtimeSync()
          let summary = try updater.summary()
          DispatchQueue.main.async { result(summary) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "HISTORY", message: "履歴を読み取れません", details: nil))
          }
        }
      }

    case "applyBatch":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            let items = args["items"] as? [[String: Any]],
            let replaceConfirmed = args["replaceConfirmed"] as? Bool,
            !items.isEmpty else {
        result(FlutterError(code: "ARGS", message: "更新対象がありません", details: nil))
        return
      }
      let root = URL(fileURLWithPath: path).standardizedFileURL
      guard beginUpdate(root: root.path) else {
        result(FlutterError(code: "SCOPE", message: "更新するフォルダを選択し直してください", details: nil))
        return
      }
      queue.async {
        do {
          let tool = try self.findExifTool()
          let updater = try self.mtimeSync()
          let plans: [ExifToolMtimeSync.Plan] = try items.map { item in
            guard let relative = item["relativePath"] as? String,
                  let before = item["beforeMs"] as? NSNumber,
                  let target = item["targetMs"] as? NSNumber else {
              throw ExifToolMtimeSync.Failure.invalidPath
            }
            return .init(relativePath: relative, beforeMs: before.int64Value,
                         targetMs: target.int64Value)
          }
          let summary = try updater.apply(root: root, plans: plans,
                                          replaceConfirmed: replaceConfirmed,
                                          shouldCancel: { self.isUpdateCancelled() }) { file in
            let metadata = try self.readMetadata(file, tool: tool)
            return ExifCaptureTime.parse(metadata).map {
              Int64(($0.0.timeIntervalSince1970 * 1000).rounded())
            }
          }
          self.finishUpdate()
          DispatchQueue.main.async { result(summary) }
        } catch {
          self.finishUpdate()
          DispatchQueue.main.async {
            result(FlutterError(code: "UPDATE", message: "日時更新を中断しました。履歴を確認してください。", details: nil))
          }
        }
      }

    case "undoLastBatch":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "ARGS", message: "フォルダを選択してください", details: nil))
        return
      }
      let root = URL(fileURLWithPath: path).standardizedFileURL
      lock.lock()
      let authorized = approvedRoot == root.path && !scanning
      lock.unlock()
      guard authorized else {
        result(FlutterError(code: "SCOPE", message: "Undoの対象フォルダを再選択してください", details: nil))
        return
      }
      queue.async {
        do {
          let updater = try self.mtimeSync()
          let summary = try updater.undo(approvedRoot: root)
          DispatchQueue.main.async { result(summary) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "UNDO", message: "Undoを安全に完了できません。履歴を保持しました。", details: nil))
          }
        }
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func mtimeSync() throws -> ExifToolMtimeSync {
    let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
      .appendingPathComponent("EXIFDateSync", isDirectory: true)
    return try ExifToolMtimeSync(storageDirectory: support, exiftool: findExifTool())
  }

  private func findExifTool() throws -> String {
    let locations = [
      "/opt/homebrew/bin/exiftool",
      "/usr/local/bin/exiftool",
      "/usr/bin/exiftool"
    ]
    if let path = locations.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
      return path
    }
    throw NSError(
      domain: "ExifDateSync", code: 2,
      userInfo: [NSLocalizedDescriptionKey: "ExifToolが見つかりません。Macで brew install exiftool を実行してください。"]
    )
  }

  private func runProcess(executable: String, arguments: [String], acceptedStatuses: Set<Int32> = [0]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments // No shell interpolation.
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    // Small, whitelisted metadata response only.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationReason == .exit, acceptedStatuses.contains(process.terminationStatus) else {
      throw NSError(
        domain: "ExifDateSync", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "ExifToolの読み取りに失敗しました"]
      )
    }
    guard let output = String(data: data, encoding: .utf8) else {
      throw NSError(
        domain: "ExifDateSync", code: 4,
        userInfo: [NSLocalizedDescriptionKey: "ExifToolが不正なテキストを返しました"]
      )
    }
    return output
  }

  private func readMetadata(_ file: URL, tool: String) throws -> [String: Any] {
    // File edit and digitization timestamps are not reliable capture times.
    let output = try runProcess(
      executable: tool,
      arguments: ExifCaptureTime.metadataArguments(for: file.path)
    )
    guard let data = output.data(using: .utf8),
          let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
          let metadata = list.first, list.count == 1 else {
      throw NSError(
        domain: "ExifDateSync", code: 5,
        userInfo: [NSLocalizedDescriptionKey: "ExifToolの結果を読み取れません"]
      )
    }
    return metadata
  }

  private func readMetadata(_ files: [URL], tool: String) throws -> [String: [String: Any]] {
    let output = try runProcess(
      executable: tool,
      arguments: ExifCaptureTime.metadataArguments(for: files.map(\.path)),
      acceptedStatuses: [0, 1, 2]
    )
    guard let data = output.data(using: .utf8),
          let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      throw NSError(
        domain: "ExifDateSync", code: 5,
        userInfo: [NSLocalizedDescriptionKey: "ExifToolの結果を読み取れません"]
      )
    }
    var byPath: [String: [String: Any]] = [:]
    for metadata in list {
      if let path = metadata["SourceFile"] as? String { byPath[path] = metadata }
    }
    return byPath
  }

  private func scan(root: URL, recursive: Bool, includeRaw: Bool, tool: String) throws -> [String: Any] {
    let standard = Set(["jpg", "jpeg", "png", "heic", "heif", "hif"])
    let raw = Set(["arw", "rwl", "rw2", "orf", "dng", "cr2", "cr3", "nef", "raf"])
    let allowed = includeRaw ? standard.union(raw) : standard
    let options: FileManager.DirectoryEnumerationOptions =
      recursive ? [] : [.skipsSubdirectoryDescendants]
    guard let enumerator = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: options
    ) else {
      throw NSError(
        domain: "ExifDateSync", code: 6,
        userInfo: [NSLocalizedDescriptionKey: "フォルダ内を調べられません"]
      )
    }

    var total = 0
    var excluded = 0
    var unreadable = 0
    var batch: [[String: Any]] = []
    func emit() {
      if batch.isEmpty { return }
      let sending = batch
      batch.removeAll(keepingCapacity: true)
      DispatchQueue.main.async {
        self.channel.invokeMethod("macRows", arguments: sending)
      }
    }
    let rootPrefix = root.path + "/"

    func scanChunk(_ files: [URL]) {
      guard !files.isEmpty, !isCancelled() else { return }
      let metadataByPath = (try? readMetadata(files, tool: tool)) ?? [:]
      for file in files {
        if isCancelled() { break }
        total += 1
        let relative = file.path.hasPrefix(rootPrefix)
          ? String(file.path.dropFirst(rootPrefix.count))
          : file.lastPathComponent
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let before = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        var row: [String: Any] = [
          "relativePath": relative,
          "size": size,
          "beforeMs": before.map { Int64(($0 * 1000).rounded()) } ?? 0,
          "status": "NO_DATE"
        ]

        if let metadata = metadataByPath[file.path], metadata["ExifTool:Error"] == nil, metadata["Error"] == nil {
          if let (date, source, offset) = ExifCaptureTime.parse(metadata) {
            let targetMs = Int64((date.timeIntervalSince1970 * 1000).rounded())
            let beforeMs = row["beforeMs"] as? Int64 ?? 0
            row["targetMs"] = targetMs
            row["dateSource"] = source
            row["offset"] = offset
            row["status"] = abs(targetMs - beforeMs) <= 1000 ? "UNCHANGED" : "NEEDS_UPDATE"
          }
        } else {
          row["status"] = "ERROR"
          row["message"] = "ExifToolの読み取りに失敗しました"
          unreadable += 1
        }
        batch.append(row)
      }
      emit()
    }

    var files: [URL] = []
    for case let file as URL in enumerator {
      if isCancelled() { break }
      let properties = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      if properties?.isSymbolicLink == true { excluded += 1; continue }
      if properties?.isRegularFile != true { continue }
      if !allowed.contains(file.pathExtension.lowercased()) { excluded += 1; continue }
      files.append(file)
      if files.count == (total == 0 ? 5 : 20) {
        scanChunk(files)
        files.removeAll(keepingCapacity: true)
      }
    }
    scanChunk(files)
    emit()
    return [
      "complete": !isCancelled(),
      "total": total,
      "excluded": excluded,
      "unreadable": unreadable,
      "root": root.path
    ]
  }
}
