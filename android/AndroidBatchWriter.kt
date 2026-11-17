package dev.exifdatesync

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.os.Environment
import android.system.Os
import java.io.File
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs

/**
 * Stores only the latest batch in app-private SQLite.
 *
 * Every PENDING record is committed before its file's mtime can be changed.
 * After a process crash, Undo checks identity + observed mtime rather than
 * blindly restoring paths. Neither this class nor the EXIF core writes image bytes.
 */
class AndroidBatchWriter(
    context: Context,
    private val core: AndroidFileDateCore = AndroidFileDateCore()
) : SQLiteOpenHelper(context.applicationContext, "last_batch_mtime.sqlite", null, 1) {

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """CREATE TABLE batch (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                created_ms INTEGER NOT NULL,
                root TEXT NOT NULL
            )"""
        )
        db.execSQL(
            """CREATE TABLE items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                path TEXT NOT NULL UNIQUE,
                dev INTEGER NOT NULL,
                inode INTEGER NOT NULL,
                size INTEGER NOT NULL,
                before_ms INTEGER NOT NULL,
                target_ms INTEGER NOT NULL,
                actual_ms INTEGER,
                date_source TEXT NOT NULL,
                offset TEXT NOT NULL,
                status TEXT NOT NULL,
                message TEXT NOT NULL DEFAULT ''
            )"""
        )
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        error("Migration required: refusing to drop the most recent Undo journal")
    }

    private data class Entry(
        val id: Long,
        val path: String,
        val dev: Long,
        val inode: Long,
        val size: Long,
        val before: Long,
        val target: Long,
        val actual: Long?,
        val source: String,
        val offset: String,
        val status: String,
        val message: String
    )

    private fun allowedRoots(): List<File> {
        @Suppress("DEPRECATION")
        val roots = listOf(
            Environment.DIRECTORY_DCIM,
            Environment.DIRECTORY_PICTURES,
            Environment.DIRECTORY_DOWNLOADS
        ).map { Environment.getExternalStoragePublicDirectory(it) }
        return roots.filter { it.isDirectory }.map { it.canonicalFile }
    }

    private fun checkedRoot(raw: String): File {
        val root = File(raw).canonicalFile
        require(root.isDirectory && !Files.isSymbolicLink(root.toPath())) {
            "Selected root is not a real directory"
        }
        require(allowedRoots().any {
            root.path == it.path || root.path.startsWith(it.path + File.separator)
        }) { "Only internal DCIM/Pictures/Download folders are supported" }
        return root
    }

    private fun checkedFile(path: String, root: File): File {
        val input = File(path)
        require(input.isAbsolute) { "Absolute file path required" }
        require(!Files.isSymbolicLink(input.toPath())) { "Symlinks are forbidden" }
        val file = input.canonicalFile
        require(file.path.startsWith(root.path + File.separator)) {
            "Image is outside the confirmed folder"
        }
        require(file.isFile) { "File missing or not regular" }
        return file
    }

    private fun identity(file: File): Pair<Long, Long> {
        val stat = Os.lstat(file.absolutePath)
        require(!Files.isSymbolicLink(file.toPath()) && file.isFile) {
            "Image is missing or a symlink"
        }
        // Multiple hard links can refer to one file from different folders.
        // Reject unknown or multiple hard links before apply, retry and Undo.
        require(stat.st_nlink == 1L) {
            "Image has multiple or unverified hard links; mtime write refused"
        }
        return Pair(stat.st_dev, stat.st_ino)
    }

    private fun number(value: Any?): Long =
        (value as? Number)?.toLong() ?: error("Invalid scan preview number")

    private fun insert(db: SQLiteDatabase, row: Entry) {
        val values = ContentValues().apply {
            put("path", row.path)
            put("dev", row.dev)
            put("inode", row.inode)
            put("size", row.size)
            put("before_ms", row.before)
            put("target_ms", row.target)
            if (row.actual != null) put("actual_ms", row.actual)
            put("date_source", row.source)
            put("offset", row.offset)
            put("status", row.status)
            put("message", row.message)
        }
        db.insertOrThrow("items", null, values)
    }

    private fun changeState(id: Long, state: String, message: String, actual: Long? = null) {
        val values = ContentValues().apply {
            put("status", state)
            put("message", message)
            if (actual != null) put("actual_ms", actual)
        }
        writableDatabase.update("items", values, "id = ?", arrayOf(id.toString()))
    }

    private fun readEntries(states: Set<String>): List<Entry> {
        val answer = mutableListOf<Entry>()
        readableDatabase.rawQuery(
            "SELECT id, path, dev, inode, size, before_ms, target_ms, actual_ms, " +
                "date_source, offset, status, message FROM items ORDER BY id", null
        ).use { cursor ->
            while (cursor.moveToNext()) {
                val state = cursor.getString(10)
                if (state !in states) continue
                answer.add(
                    Entry(
                        cursor.getLong(0), cursor.getString(1), cursor.getLong(2),
                        cursor.getLong(3), cursor.getLong(4), cursor.getLong(5),
                        cursor.getLong(6), if (cursor.isNull(7)) null else cursor.getLong(7),
                        cursor.getString(8), cursor.getString(9), state, cursor.getString(11)
                    )
                )
            }
        }
        return answer
    }

    fun summary(): Map<String, Any> {
        var exists = false
        var created = 0L
        var root = ""
        readableDatabase.rawQuery("SELECT created_ms, root FROM batch WHERE id = 1", null)
            .use { cursor ->
                if (cursor.moveToFirst()) {
                    exists = true
                    created = cursor.getLong(0)
                    root = cursor.getString(1)
                }
            }
        val counts = mutableMapOf<String, Int>()
        readableDatabase.rawQuery(
            "SELECT status, COUNT(*) FROM items GROUP BY status", null
        ).use { cursor ->
            while (cursor.moveToNext()) counts[cursor.getString(0)] = cursor.getInt(1)
        }
        val applied = counts.getOrDefault("APPLIED", 0)
        val uncertain = counts.getOrDefault("UNCERTAIN", 0)
        val pending = counts.getOrDefault("PENDING", 0)
        val failure = counts.getOrDefault("FAILED", 0)
        return mapOf(
            "exists" to exists,
            "createdMs" to created,
            "root" to root,
            "total" to counts.values.sum(),
            "applied" to applied,
            "failed" to failure,
            "pending" to pending,
            "uncertain" to uncertain,
            "undone" to counts.getOrDefault("UNDONE", 0),
            "conflicts" to counts.getOrDefault("UNDO_CONFLICT", 0),
            "canUndo" to (applied + uncertain + pending + counts.getOrDefault("UNDO_CONFLICT", 0) > 0)
        )
    }

    /**
     * A complete scan + explicit Flutter confirmation is required before call.
     * Re-inspects every selected image and compares mtime, EXIF target and size.
     * Do not replace the preceding Undo until at least one valid row is staged.
     */
    fun apply(
        rawRoot: String,
        selected: List<Map<String, Any?>>,
        cancel: AtomicBoolean,
        progress: (Map<String, Any>) -> Unit
    ): Map<String, Any> {
        val root = checkedRoot(rawRoot)
        val prior = summary()
        require(((prior["pending"] as? Number)?.toInt() ?: 0) == 0 &&
            ((prior["uncertain"] as? Number)?.toInt() ?: 0) == 0) {
            "前回の処理に未確定の変更があります。先にUndoで状態を確認してください"
        }
        require(selected.isNotEmpty()) { "No files selected" }
        require(selected.size <= 20000) { "Too many files in one batch" }
        val unique = selected.distinctBy { it["path"]?.toString() }
        val planned = mutableListOf<Entry>()
        var valid = 0
        for (row in unique) {
            val original = row["path"] as? String ?: continue
            var dev = 0L
            var inode = 0L
            var size = (row["size"] as? Number)?.toLong() ?: 0L
            val before = (row["beforeMs"] as? Number)?.toLong() ?: 0L
            val target = (row["targetMs"] as? Number)?.toLong() ?: 0L
            var source = row["dateSource"]?.toString() ?: ""
            var offset = row["offset"]?.toString() ?: ""
            var state = "PENDING"
            var message = ""
            try {
                require(row["status"] == "NEEDS_UPDATE") { "Not marked for update" }
                val file = checkedFile(original, root)
                val fresh = core.inspect(file)
                require(fresh.beforeModifiedMs == before &&
                        fresh.targetModifiedMs == target && fresh.sizeBytes == size &&
                        fresh.dateSource == source && fresh.captureOffset == offset) {
                    "Image changed since scan; re-scan before updating"
                }
                val id = identity(file)
                dev = id.first
                inode = id.second
                size = fresh.sizeBytes
                source = fresh.dateSource
                offset = fresh.captureOffset
                valid++
            } catch (error: Exception) {
                state = "FAILED"
                message = error.message ?: "Preview validation failed"
            }
            planned.add(Entry(0L, original, dev, inode, size, before, target, null,
                source, offset, state, message))
        }
        require(valid > 0) { "No safely validated images; previous Undo retained" }

        val db = writableDatabase
        db.beginTransaction()
        try {
            db.delete("items", null, null)
            db.delete("batch", null, null)
            db.insertOrThrow("batch", null, ContentValues().apply {
                put("id", 1)
                put("created_ms", System.currentTimeMillis())
                put("root", root.path)
            })
            for (row in planned) insert(db, row)
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }

        return executePending(cancel, progress)
    }

    private fun executePending(
        cancel: AtomicBoolean,
        progress: (Map<String, Any>) -> Unit
    ): Map<String, Any> {
        val initial = readEntries(setOf("PENDING"))
        val total = initial.size
        var completed = 0
        var applied = 0
        var failed = 0
        for (row in initial) {
            if (cancel.get()) break
            var status = "FAILED"
            var message = "File was not updated"
            var actual: Long? = null
            try {
                val file = File(row.path)
                require(identity(file) == Pair(row.dev, row.inode)) {
                    "Image identity changed after confirmation"
                }
                val fresh = core.inspect(file)
                require(fresh.sizeBytes == row.size &&
                        fresh.beforeModifiedMs == row.before &&
                        fresh.targetModifiedMs == row.target &&
                        fresh.dateSource == row.source &&
                        fresh.captureOffset == row.offset) {
                    "Image metadata or mtime changed after confirmation"
                }
                val outcome = core.apply(fresh)
                actual = outcome.actualModifiedMs
                message = outcome.message
                if (outcome.success && actual != null &&
                    abs(actual - row.target) <= 1000L) {
                    status = "APPLIED"
                    applied++
                } else if (actual != null && actual != row.before) {
                    status = "UNCERTAIN" // Undo must check exact identity/observed mtime.
                    failed++
                } else {
                    failed++
                }
            } catch (error: Exception) {
                val file = File(row.path)
                actual = if (file.exists()) file.lastModified() else null
                // A crash/error can occur after writing but before recording success.
                status = if (actual != null && actual != row.before) "UNCERTAIN" else "FAILED"
                message = error.message ?: "File update failed"
                failed++
            }
            changeState(row.id, status, message, actual)
            completed++
            progress(mapOf("done" to completed, "total" to total,
                "applied" to applied, "failed" to failed))
        }
        if (cancel.get()) {
            // Cancellation is checked only between files. The remaining PENDING
            // records were never attempted, so they are not retry failures.
            // Crash-time PENDING records are untouched (this loop does not run).
            for (remaining in readEntries(setOf("PENDING"))) {
                changeState(remaining.id, "NOT_APPLIED", "Cancelled before writing")
            }
        }
        return summary() + mapOf("cancelled" to cancel.get())
    }

    fun undo(): Map<String, Any> {
        val preceding = summary()
        require(preceding["exists"] == true) { "No batch exists" }
        // Undo must obey the same selected-folder scope as apply.
        val root = checkedRoot(preceding["root"] as String)
        val items = readEntries(setOf("APPLIED", "PENDING", "UNCERTAIN", "UNDO_CONFLICT"))
        var restored = 0
        var conflicts = 0
        for (row in items) {
            try {
                val file = checkedFile(row.path, root)
                require(identity(file) == Pair(row.dev, row.inode)) {
                    "Image identity changed; cannot restore"
                }
                require(file.length() == row.size) { "Image size changed; cannot restore" }
                val observed = file.lastModified()
                if (observed == row.before) {
                    // Idempotent crash recovery: the file may already have been
                    // restored before the journal could be updated. Never set
                    // its mtime again. Identity and size were checked above.
                    if (row.status == "PENDING") {
                        changeState(row.id, "NOT_APPLIED", "Interrupted before updating")
                    } else {
                        changeState(row.id, "UNDONE", "Already restored before journal save", observed)
                        restored++
                    }
                    continue
                }
                // For interrupted PENDING files the committed target value is
                // the only safe evidence of a completed mtime change.
                val accepted = if (row.status == "PENDING") {
                    abs(observed - row.target) <= 1000L
                } else {
                    val lastSet = row.actual ?: row.target
                    observed == lastSet
                }
                require(accepted) { "mtime differs from recorded update; not overwriting" }
                require(file.setLastModified(row.before)) { "mtime restoration denied" }
                require(abs(file.lastModified() - row.before) <= 1000L) {
                    "Restored mtime verification failed"
                }
                changeState(row.id, "UNDONE", "Original mtime restored", file.lastModified())
                restored++
            } catch (error: Exception) {
                changeState(row.id, "UNDO_CONFLICT", error.message ?: "Undo rejected")
                conflicts++
            }
        }
        return summary() + mapOf("restored" to restored, "conflicts" to conflicts)
    }
}
