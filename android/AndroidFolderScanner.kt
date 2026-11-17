package dev.exifdatesync

import android.os.Environment
import java.io.File
import java.nio.file.Files
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs

/**
 * Internal shared-storage browsing and read-only progressive scan.
 * Does not use SAF URI-to-path conversions and never writes during scanning.
 */
class AndroidFolderScanner(
    private val core: AndroidFileDateCore = AndroidFileDateCore()
) {
    @Suppress("DEPRECATION")
    private fun allowedRoots(): List<File> = listOf(
        Environment.DIRECTORY_DCIM,
        Environment.DIRECTORY_PICTURES,
        Environment.DIRECTORY_DOWNLOADS
    ).map { Environment.getExternalStoragePublicDirectory(it) }
        .filter { it.isDirectory }
        .distinctBy { it.canonicalPath }

    fun rootFolders(): List<Map<String, String>> = allowedRoots().map { dir ->
        mapOf("path" to dir.canonicalPath, "name" to dir.name)
    }

    private fun validatedFolder(value: String): File {
        val requested = File(value)
        require(!Files.isSymbolicLink(requested.toPath())) { "Symbolic-link folders are not supported" }
        val canonical = requested.canonicalFile
        require(canonical.isDirectory) { "Folder not found" }
        require(allowedRoots().any { base ->
            canonical.path == base.canonicalPath ||
                canonical.path.startsWith(base.canonicalPath + File.separator)
        }) { "Folder outside DCIM, Pictures and Download" }
        return canonical
    }

    /**
     * Resolve a scanned image for read-only viewing in another app.
     * Never accept an arbitrary absolute path from the UI.
     */
    fun imageForViewing(rootPath: String, relativePath: String): File {
        val base = validatedFolder(rootPath)
        require(relativePath.isNotBlank() && !File(relativePath).isAbsolute) {
            "Relative image path required"
        }
        val requested = File(base, relativePath).toPath().normalize()
        require(requested.startsWith(base.toPath()) && requested != base.toPath()) {
            "Image outside selected folder"
        }
        var part = base.toPath()
        for (component in base.toPath().relativize(requested)) {
            part = part.resolve(component)
            require(!Files.isSymbolicLink(part)) { "Symbolic links are not supported" }
        }
        val file = requested.toFile().canonicalFile
        require(file.path.startsWith(base.canonicalPath + File.separator)) {
            "Image outside selected folder"
        }
        require(file.isFile && file.canRead()) { "Image no longer readable" }
        require(file.extension.lowercase(Locale.ROOT) in supportedImageExtensions) {
            "Unsupported image format"
        }
        return file
    }

    fun childFolders(parentPath: String): List<Map<String, String>> {
        val parent = validatedFolder(parentPath)
        return (parent.listFiles() ?: emptyArray())
            .filter { it.isDirectory && !Files.isSymbolicLink(it.toPath()) }
            .sortedBy { it.name.lowercase(Locale.ROOT) }
            .map { mapOf("path" to it.canonicalPath, "name" to it.name) }
    }

    /**
     * Runs on a worker thread. Batches are emitted in scan order and must be
     * delivered to the Flutter UI thread by the caller.
     *
     * A cancelled scan is incomplete and MUST NOT permit updates.
     */
    fun scan(
        folderPath: String,
        recursive: Boolean,
        cancel: AtomicBoolean,
        onRows: (List<Map<String, Any?>>) -> Unit
    ): Map<String, Any?> {
        val base = validatedFolder(folderPath)
        val dirs = ArrayDeque<File>()
        dirs.add(base)
        val rows = mutableListOf<Map<String, Any?>>()
        var included = 0
        var excluded = 0
        var failed = 0

        fun flush() {
            if (rows.isNotEmpty()) {
                onRows(rows.toList())
                rows.clear()
            }
        }

        while (dirs.isNotEmpty() && !cancel.get()) {
            val dir = dirs.removeFirst()
            val entries = dir.listFiles()
            if (entries == null) {
                failed++
                continue
            }
            for (file in entries.sortedBy { it.name.lowercase(Locale.ROOT) }) {
                if (cancel.get()) break
                if (Files.isSymbolicLink(file.toPath())) {
                    excluded++
                    continue
                }
                if (file.isDirectory) {
                    if (recursive) dirs.add(file)
                    continue
                }
                if (!file.isFile) {
                    excluded++
                    continue
                }
                if (file.extension.lowercase(Locale.ROOT) !in supportedImageExtensions) {
                    excluded++
                    continue
                }
                // A no-date image still appears in the UI.
                included++
                val relative = base.toPath().relativize(file.toPath()).toString()
                val status: Map<String, Any?> = try {
                    val preview = core.inspect(file)
                    mapOf(
                        "path" to preview.path,
                        "relativePath" to relative,
                        "beforeMs" to preview.beforeModifiedMs,
                        "targetMs" to preview.targetModifiedMs,
                        "size" to preview.sizeBytes,
                        "dateSource" to preview.dateSource,
                        "offset" to preview.captureOffset,
                        "status" to if (abs(preview.targetModifiedMs -
                            preview.beforeModifiedMs) <= 1000L) "UNCHANGED" else "NEEDS_UPDATE"
                    )
                } catch (error: Exception) {
                    val noDate = error.message?.contains("No EXIF capture/date") == true
                    mapOf(
                        "path" to file.absolutePath,
                        "relativePath" to relative,
                        "beforeMs" to file.lastModified(),
                        "targetMs" to null,
                        "size" to file.length(),
                        "dateSource" to "",
                        "offset" to "",
                        "status" to if (noDate) "NO_DATE" else "ERROR",
                        "message" to (error.message ?: "Cannot read metadata")
                    )
                }
                rows.add(status)
                if (rows.size >= 20) flush()
            }
        }
        flush()
        return mapOf(
            "complete" to !cancel.get(),
            "included" to included,
            "excluded" to excluded,
            "failedDirectories" to failed,
            "root" to base.path
        )
    }
}
