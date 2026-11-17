import Foundation

/// Extracts only EXIF capture time, never modification or digitization times.
/// Independent of Flutter, allowing date parsing to be checked without a Mac app.
enum ExifCaptureTime {
  private static let captureArguments = [
    "-json", "-api", "StructFormat=JSONQ", "-G1", "-s",
    "-DateTimeOriginal", "-OffsetTimeOriginal", "-SubSecTimeOriginal"
  ]

  static func metadataArguments(for path: String) -> [String] {
    captureArguments + ["--", path]
  }

  static func metadataArguments(for paths: [String]) -> [String] {
    captureArguments + ["-Error", "--"] + paths
  }

  private static func tag(_ metadata: [String: Any], _ name: String) -> String? {
    for key in ["ExifIFD:" + name, "IFD0:" + name, "EXIF:" + name, name] {
      if let value = metadata[key] as? String, !value.isEmpty { return value }
    }
    return nil
  }

  private static func timeZone(_ raw: String?) -> TimeZone? {
    guard let raw = raw, !raw.isEmpty else { return TimeZone(secondsFromGMT: 9 * 3600) }
    if raw == "Z" { return TimeZone(secondsFromGMT: 0) }
    let hasColon = raw.count == 6 && raw.dropFirst(3).first == ":" &&
      raw.filter { $0 == ":" }.count == 1
    guard hasColon || (raw.count == 5 && !raw.contains(":")) else { return nil }
    let normalized = raw.replacingOccurrences(of: ":", with: "")
    guard let sign = normalized.first, sign == "+" || sign == "-",
          let hours = Int(normalized.dropFirst().prefix(2)),
          let minutes = Int(normalized.suffix(2)),
          hours <= 14, minutes < 60, !(hours == 14 && minutes != 0) else { return nil }
    return TimeZone(secondsFromGMT: (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1))
  }

  static func parse(_ metadata: [String: Any], now: Date = Date()) -> (Date, String, String)? {
    guard let original = tag(metadata, "DateTimeOriginal"), original.count >= 19,
          let year = Int(original.prefix(4)),
          year >= 1970,
          year <= Calendar.current.component(.year, from: now) + 1 else { return nil }

    // ExifTool normally exposes subseconds in the separate SubSecTimeOriginal tag.
    // Also accept a fractional suffix on DateTimeOriginal when present.
    let suffix = String(original.dropFirst(19))
    var fraction = ""
    var embeddedOffset = suffix
    if suffix.hasPrefix(".") {
      let rest = suffix.dropFirst()
      let digits = rest.prefix { $0 >= "0" && $0 <= "9" }
      guard !digits.isEmpty && digits.count <= 9 else { return nil }
      fraction = String(digits)
      embeddedOffset = String(rest.dropFirst(digits.count))
    }
    guard embeddedOffset.isEmpty || timeZone(embeddedOffset) != nil else { return nil }

    // The explicit EXIF fractional tag takes precedence if both are supplied.
    if let subsec = tag(metadata, "SubSecTimeOriginal") {
      let digits = subsec.trimmingCharacters(in: .whitespacesAndNewlines)
      if !digits.isEmpty { fraction = digits }
    }
    guard fraction.count <= 9,
          fraction.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
    let offset = embeddedOffset.isEmpty ? tag(metadata, "OffsetTimeOriginal") : embeddedOffset
    guard let zone = timeZone(offset) else { return nil }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.isLenient = false
    formatter.timeZone = zone
    formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
    guard let date = formatter.date(from: String(original.prefix(19))) else { return nil }
    let millis = fraction.isEmpty ? 0 : Int(String(fraction.prefix(3)).padding(
      toLength: 3, withPad: "0", startingAt: 0))!
    return (date.addingTimeInterval(Double(millis) / 1000), "DateTimeOriginal",
            offset?.isEmpty == false ? offset! : "+09:00")
  }
}
