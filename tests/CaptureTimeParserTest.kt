package dev.exifdatesync

import java.time.Instant

fun main() {
    var passed = 0
    fun eq(actual: Any, expected: Any) {
        check(actual == expected) { "expected $expected, got $actual" }
        passed++
    }
    val jst = CaptureTimeParser.parse("2026:11:04 12:30:00", null, null)
    eq(Instant.ofEpochMilli(jst.epochMillis).toString(), "2026-11-04T03:30:00Z")
    eq(jst.usedExifOffset, false)
    val est = CaptureTimeParser.parse("2026:11:04 12:30:00", "-05:00", "250")
    eq(Instant.ofEpochMilli(est.epochMillis).toString(), "2026-11-04T17:30:00.250Z")
    eq(est.usedExifOffset, true)
    val alt = CaptureTimeParser.parse("2026-11-04 12:30:00", null, "5")
    eq(Instant.ofEpochMilli(alt.epochMillis).toString(), "2026-11-04T03:30:00.500Z")
    // ExifTool and camera files may encode five milliseconds as the text "005".
    val fiveMs = CaptureTimeParser.parse("2024:01:02 03:04:05", "+09:00", "005")
    eq(Instant.ofEpochMilli(fiveMs.epochMillis).toString(), "2024-01-01T18:04:05.005Z")
    eq(fiveMs.usedExifOffset, true)
    val fiveMsFallback = CaptureTimeParser.parse("2024:01:02 03:04:05", null, "005")
    eq(fiveMsFallback.epochMillis, fiveMs.epochMillis)
    // Boundary offsets and milliseconds should map to the intended UTC instant.
    val endOfYear = CaptureTimeParser.parse("2026:12:31 23:59:59", "+14:00", "999")
    eq(Instant.ofEpochMilli(endOfYear.epochMillis).toString(), "2026-12-31T09:59:59.999Z")
    val firstMillisecond = CaptureTimeParser.parse("2026:01:01 00:00:00", "+00:00", "001")
    eq(Instant.ofEpochMilli(firstMillisecond.epochMillis).toString(), "2026-01-01T00:00:00.001Z")
    eq(jst.dateSource, "DateTimeOriginal")
    // DateTimeOriginal from 1970 onward is allowed; older photos are not edited.
    val firstYear = CaptureTimeParser.parse("1970:01:01 00:00:00", null, null)
    eq(Instant.ofEpochMilli(firstYear.epochMillis).toString(), "1969-12-31T15:00:00Z")
    val blankOffset = CaptureTimeParser.parse("2026:11:04 12:30:00", "   ", null)
    eq(blankOffset.epochMillis, jst.epochMillis)
    // No DateTimeOriginal must never be replaced by digitization or edit time.
    // The parser deliberately accepts no parameters for either alternative.
    for (missing in listOf<String?>(null, "", "   ")) {
        val error = runCatching { CaptureTimeParser.parse(missing, null, null) }
            .exceptionOrNull()
        check(error != null && error.message?.contains("No EXIF capture/date") == true) {
            "Missing original capture time must be rejected: ${missing?.length}"
        }
        passed++
    }
    val invalid = listOf(
        arrayOf<String?>(null, null, null),
        arrayOf<String?>("2026:02:30 12:30:00", null, null),
        arrayOf<String?>("1969:12:31 23:59:59", null, null),
        arrayOf<String?>("2026:11:04 12:30:00", "+14:30", null),
        arrayOf<String?>("2026:11:04 12:30:00", "+15:00", null),
        arrayOf<String?>("2026:11:04 12:30:00", null, "oops"),
        arrayOf<String?>("2026:11:04 12:30:00", null, "1234567890")
    )
    for (values in invalid) {
        var rejected = false
        try {
            CaptureTimeParser.parse(values[0], values[1], values[2])
        } catch (_: Exception) { rejected = true }
        check(rejected) { "Expected malformed EXIF to be rejected: ${values.toList()}" }
        passed++
    }
    println("CaptureTimeParserTest: $passed checks OK")
}
