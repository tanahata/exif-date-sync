package dev.exifdatesync

import java.time.DateTimeException
import java.time.LocalDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.ResolverStyle
import java.util.Locale

/** OS-independent EXIF date parser. No user-configurable timezone shift. */
object CaptureTimeParser {
    private val exifFormat = DateTimeFormatter
        .ofPattern("uuuu:MM:dd HH:mm:ss", Locale.ROOT)
        .withResolverStyle(ResolverStyle.STRICT)
    private val alternateFormat = DateTimeFormatter
        .ofPattern("uuuu-MM-dd HH:mm:ss", Locale.ROOT)
        .withResolverStyle(ResolverStyle.STRICT)
    private val offsets = Regex("[+-]\\d{2}:\\d{2}")

    data class Parsed(
        val epochMillis: Long,
        val offset: String,
        val usedExifOffset: Boolean,
        val dateSource: String = "DateTimeOriginal"
    )

    /** Only EXIF DateTimeOriginal is a capture date. Missing means no update. */
    fun parse(
        dateTimeOriginal: String?,
        offsetTimeOriginal: String?,
        subSecTimeOriginal: String?
    ): Parsed {
        val raw = dateTimeOriginal?.trim()
        require(!raw.isNullOrEmpty()) { "No EXIF capture/date tag available" }
        val captured = try {
            LocalDateTime.parse(raw, exifFormat)
        } catch (primary: DateTimeException) {
            LocalDateTime.parse(raw, alternateFormat)
        }
        val thisYear = java.time.LocalDate.now().year
        require(captured.year in 1970..(thisYear + 1)) { "Capture year outside safety range" }
        val tagOffset = offsetTimeOriginal?.trim().orEmpty()
        val selectedOffset = tagOffset.ifEmpty { "+09:00" }
        require(offsets.matches(selectedOffset)) { "Invalid EXIF UTC offset" }
        val parsedOffset = ZoneOffset.of(selectedOffset)
        require(kotlin.math.abs(parsedOffset.totalSeconds) <= 14 * 3600) {
            "UTC offset outside range"
        }
        val millis = when {
            subSecTimeOriginal.isNullOrBlank() -> 0
            else -> {
                val digits = subSecTimeOriginal.trim()
                require(digits.length <= 9 && digits.all { it.isDigit() }) {
                    "Invalid EXIF subsecond field"
                }
                digits.take(3).padEnd(3, '0').toInt()
            }
        }
        return Parsed(captured.toInstant(parsedOffset).toEpochMilli() + millis,
            selectedOffset, tagOffset.isNotEmpty())
    }
}
