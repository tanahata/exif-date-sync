import Foundation

@main
struct MacExifCaptureTimeTest {
  static func timestamp(_ iso: String) -> Int64 {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    return Int64((formatter.date(from: iso)!.timeIntervalSince1970 * 1000).rounded())
  }

  static func main() {
    let now = Date(timeIntervalSince1970: 1_783_000_000)
    var checks = 0
    func check(_ metadata: [String: Any], _ expected: String, _ offset: String) {
      guard let (date, source, actualOffset) = ExifCaptureTime.parse(metadata, now: now) else {
        fatalError("Expected a capture timestamp: \(metadata)")
      }
      precondition(Int64((date.timeIntervalSince1970 * 1000).rounded()) == timestamp(expected))
      precondition(source == "DateTimeOriginal" && actualOffset == offset)
      checks += 1
    }
    func reject(_ metadata: [String: Any]) {
      precondition(ExifCaptureTime.parse(metadata, now: now) == nil,
                   "Unexpected capture timestamp: \(metadata)")
      checks += 1
    }

    check(["ExifIFD:DateTimeOriginal": "2026:11:04 12:30:00"],
          "2026-11-04T03:30:00.000Z", "+09:00")
    check(["ExifIFD:DateTimeOriginal": "2026:11:04 12:30:00",
           "ExifIFD:OffsetTimeOriginal": "-05:00", "ExifIFD:SubSecTimeOriginal": "250"],
          "2026-11-04T17:30:00.250Z", "-05:00")
    check(["DateTimeOriginal": "2026:11:04 12:30:00",
           "SubSecTimeOriginal": "5"], "2026-11-04T03:30:00.500Z", "+09:00")
    check(["DateTimeOriginal": "2026:11:04 12:30:00",
           "SubSecTimeOriginal": "005"], "2026-11-04T03:30:00.005Z", "+09:00")
    check(["DateTimeOriginal": "2026:12:31 23:59:59",
           "OffsetTimeOriginal": "+14:00", "SubSecTimeOriginal": "999"],
          "2026-12-31T09:59:59.999Z", "+14:00")
    check(["DateTimeOriginal": "2026:11:04 12:30:00.123+02:00"],
          "2026-11-04T10:30:00.123Z", "+02:00")
    check(["DateTimeOriginal": "2026:11:04 12:30:00Z"],
          "2026-11-04T12:30:00.000Z", "Z")
    check(["DateTimeOriginal": "2026:11:04 12:30:00",
           "SubSecTimeOriginal": "  "], "2026-11-04T03:30:00.000Z", "+09:00")
    check(["DateTimeOriginal": "2026:11:04 12:30:00",
           "OffsetTimeOriginal": "+0900"], "2026-11-04T03:30:00.000Z", "+0900")
    check(["DateTimeOriginal": "1970:01:01 00:00:00"],
          "1969-12-31T15:00:00.000Z", "+09:00")
    reject(["CreateDate": "2026:11:04 12:30:00"])
    reject(["DateTimeOriginal": "1969:12:31 23:59:59"])
    reject(["DateTimeOriginal": "2026:02:30 12:30:00"])
    reject(["DateTimeOriginal": "2026:11:04 12:30:00", "SubSecTimeOriginal": "oops"])
    reject(["DateTimeOriginal": "2026:11:04 12:30:00", "SubSecTimeOriginal": "1234567890"])
    reject(["DateTimeOriginal": "2026:11:04 12:30:00", "OffsetTimeOriginal": "+14:30"])
    reject(["DateTimeOriginal": "2026:11:04 12:30:00", "OffsetTimeOriginal": "+15:00"])
    reject(["DateTimeOriginal": "2026:11:04 12:30:00.abc"])
    reject(["DateTimeOriginal": "2026:11:04 12:30:00+09:xx"])
    if CommandLine.arguments.count == 3 {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
      process.arguments = ExifCaptureTime.metadataArguments(for: CommandLine.arguments[2])
      let output = Pipe()
      process.standardOutput = output
      try! process.run()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      precondition(process.terminationStatus == 0)
      let rows = try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
      check(rows[0], "2024-01-01T18:04:05.005Z", "+09:00")
    }
    print("MacExifCaptureTimeTest: \(checks) checks PASS")
  }
}
