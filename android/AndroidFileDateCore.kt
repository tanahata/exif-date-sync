package dev.exifdatesync

import androidx.exifinterface.media.ExifInterface
import android.system.Os
import java.io.File
import java.nio.file.Files
import java.util.Locale

internal val supportedImageExtensions = setOf(
    "jpg", "jpeg", "png", "heic", "heif", "arw", "rw2", "orf", "dng"
) // Leica .rwl is intentionally unsupported on Android.

/**
 * Android's EXIF-only mtime core. Uses direct-path access in approved shared
 * storage folders; arbitrary SAF content:// URIs are not supported.
 *
 * The Flutter host should request all-files access through the OS permission flow
 * and provide a folder browser based on directly accessible filesystem paths.
 */
class AndroidFileDateCore {
    data class Preview(
        val path: String,
        val sizeBytes: Long,
        val beforeModifiedMs: Long,
        val targetModifiedMs: Long,
        val captureOffset: String,
        val dateSource: String
    )

    data class Applied(val success: Boolean, val message: String, val actualModifiedMs: Long?)

    fun inspect(file: File): Preview {
        require(!Files.isSymbolicLink(file.toPath())) { "Symlinks are not supported" }
        require(file.isFile) { "Not a regular file" }
        require(file.extension.lowercase(Locale.ROOT) in supportedImageExtensions) { "Unsupported image format" }
        val beforeSize = file.length()
        val beforeMtime = file.lastModified()
        require(beforeMtime > 0L) { "mtime not available" }
        val exif = ExifInterface(file.absolutePath) // Read-only: never call saveAttributes().
        val captured = CaptureTimeParser.parse(
            exif.getAttribute(ExifInterface.TAG_DATETIME_ORIGINAL),
            exif.getAttribute(ExifInterface.TAG_OFFSET_TIME_ORIGINAL),
            exif.getAttribute(ExifInterface.TAG_SUBSEC_TIME_ORIGINAL)
        )
        require(file.length() == beforeSize && file.lastModified() == beforeMtime) {
            "File changed while reading EXIF"
        }
        return Preview(file.absolutePath, beforeSize, beforeMtime,
            captured.epochMillis, captured.offset, captured.dateSource)
    }

    /** Set only file modification time, then read back. Never touch image data or EXIF. */
    fun apply(preview: Preview): Applied {
        val file = File(preview.path)
        if (Files.isSymbolicLink(file.toPath()) || !file.isFile) {
            return Applied(false, "File missing or symlink", null)
        }
        if (file.length() != preview.sizeBytes || file.lastModified() != preview.beforeModifiedMs) {
            return Applied(false, "File changed since preview", file.lastModified())
        }
        if (kotlin.math.abs(preview.beforeModifiedMs - preview.targetModifiedMs) <= 1000L) {
            return Applied(true, "Already correct", file.lastModified())
        }
        // Repeat at the last write boundary, not only during batch validation.
        // Fail closed if this file is also linked outside the approved folder.
        if (Os.lstat(file.absolutePath).st_nlink != 1L) {
            return Applied(false, "Hard-linked or unverified file; mtime write refused",
                file.lastModified())
        }
        if (!file.setLastModified(preview.targetModifiedMs)) {
            return Applied(false, "setLastModified denied by filesystem/permissions", file.lastModified())
        }
        val actual = file.lastModified()
        if (kotlin.math.abs(actual - preview.targetModifiedMs) > 1000L) {
            return Applied(false, "Read-back mtime verification failed", actual)
        }
        return Applied(true, "mtime verified", actual)
    }
}
