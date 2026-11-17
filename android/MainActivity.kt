package dev.exifdatesync.exif_date_sync

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.media.ThumbnailUtils
import android.graphics.Bitmap
import android.util.Size
import java.io.ByteArrayOutputStream
import android.os.Build
import android.os.Environment
import android.provider.Settings
import dev.exifdatesync.AndroidBatchWriter
import dev.exifdatesync.AndroidFolderScanner
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/** Flutter bridge: folder scan, modification time update, latest-batch Undo. */
class MainActivity : FlutterActivity() {
    private val channelName = "dev.exifdatesync/storage_probe"
    private val scanner = AndroidFolderScanner()
    private val batchWriter by lazy { AndroidBatchWriter(applicationContext) }
    private val batchCancelled = AtomicBoolean(false)
    private val scanCancelled = AtomicBoolean(false)
    private var busyOperation: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "rootFolders" -> {
                        if (!hasPermission()) result.error("PERMISSION", "All-files access required", null)
                        else try { result.success(scanner.rootFolders()) }
                        catch (error: Exception) { result.error("FOLDERS", error.message, null) }
                    }
                    "childFolders" -> {
                        if (!hasPermission()) result.error("PERMISSION", "All-files access required", null)
                        else try {
                            val path = call.argument<String>("path") ?: error("Folder path required")
                            result.success(scanner.childFolders(path))
                        } catch (error: Exception) {
                            result.error("FOLDERS", error.message, null)
                        }
                    }
                    "thumbnail" -> {
                        if (!hasPermission()) {
                            result.success(null)
                        } else {
                            val root = call.argument<String>("root")
                            val relative = call.argument<String>("relativePath")
                            if (root.isNullOrBlank() || relative.isNullOrBlank()) {
                                result.success(null)
                            } else {
                                Thread {
                                    val image = try {
                                        val file = scanner.imageForViewing(root, relative)
                                        val bitmap = ThumbnailUtils.createImageThumbnail(
                                            file, Size(480, 480), null
                                        )
                                        val output = ByteArrayOutputStream()
                                        bitmap.compress(Bitmap.CompressFormat.JPEG, 82, output)
                                        bitmap.recycle()
                                        output.toByteArray()
                                    } catch (_: Exception) {
                                        null // Preview is optional; the external viewer remains usable.
                                    }
                                    runOnUiThread { result.success(image) }
                                }.start()
                            }
                        }
                    }
                    "openFile" -> {
                        if (!hasPermission()) {
                            result.error("PERMISSION", "All-files access required", null)
                        } else if (busyOperation != null) {
                            result.error("BUSY", "Finish the current operation first", null)
                        } else {
                            try {
                                val root = call.argument<String>("root") ?: error("Folder required")
                                val relative = call.argument<String>("relativePath")
                                    ?: error("Image path required")
                                val file = scanner.imageForViewing(root, relative)
                                val uri = FileProvider.getUriForFile(
                                    this, "$packageName.exif_date_sync_files", file
                                )
                                val mime = when (file.extension.lowercase(java.util.Locale.ROOT)) {
                                    "jpg", "jpeg" -> "image/jpeg"
                                    "png" -> "image/png"
                                    "heic" -> "image/heic"
                                    "heif" -> "image/heif"
                                    "arw" -> "image/x-sony-arw"
                                    "rw2" -> "image/x-panasonic-rw2"
                                    "orf" -> "image/x-olympus-orf"
                                    "dng" -> "image/x-adobe-dng"
                                    else -> "image/*"
                                }
                                fun openIntent(type: String): Intent =
                                    Intent(Intent.ACTION_VIEW).apply {
                                        setDataAndType(uri, type)
                                        clipData = ClipData.newRawUri(file.name, uri)
                                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    }
                                try {
                                    startActivity(openIntent(mime))
                                } catch (noExactViewer: ActivityNotFoundException) {
                                    // Some viewers support RAW files under image/*, not vendor MIME.
                                    if (mime == "image/*") throw noExactViewer
                                    startActivity(openIntent("image/*"))
                                }
                                result.success(null)
                            } catch (error: ActivityNotFoundException) {
                                result.error("NO_VIEWER", "この画像を開けるアプリがありません。", null)
                            } catch (error: Exception) {
                                result.error("OPEN_FILE", error.message, null)
                            }
                        }
                    }
                    "scanFolder" -> {
                        if (!hasPermission()) {
                            result.error("PERMISSION", "All-files access required", null)
                        } else if (busyOperation != null) {
                            result.error("BUSY", "Another operation is in progress", null)
                        } else {
                            val folder = call.argument<String>("path")
                            val recursive = call.argument<Boolean>("recursive") ?: false
                            if (folder.isNullOrEmpty()) {
                                result.error("FOLDER", "Folder required", null)
                            } else {
                                busyOperation = "scan"
                                scanCancelled.set(false)
                                Thread {
                                    try {
                                        val report = scanner.scan(folder, recursive, scanCancelled) { rows ->
                                            runOnUiThread { channel.invokeMethod("scanRows", rows) }
                                        }
                                        runOnUiThread {
                                            busyOperation = null
                                            result.success(report)
                                        }
                                    } catch (error: Exception) {
                                        runOnUiThread {
                                            busyOperation = null
                                            result.error("SCAN", error.message, null)
                                        }
                                    }
                                }.start()
                            }
                        }
                    }
                    "cancelScan" -> {
                        scanCancelled.set(true)
                        result.success(null)
                    }
                    "lastBatch" -> {
                        Thread {
                            try {
                                val report = batchWriter.summary()
                                runOnUiThread { result.success(report) }
                            } catch (error: Exception) {
                                runOnUiThread { result.error("HISTORY", error.message, null) }
                            }
                        }.start()
                    }
                    "applyBatch" -> {
                        if (!hasPermission()) {
                            result.error("PERMISSION", "All-files access required", null)
                        } else if (busyOperation != null) {
                            result.error("BUSY", "Another operation is in progress", null)
                        } else {
                            val root = call.argument<String>("root")
                            val selected = call.argument<List<Map<String, Any?>>>("selected")
                            if (root == null || selected.isNullOrEmpty()) {
                                result.error("BATCH", "No folder or selected image", null)
                            } else {
                                busyOperation = "apply"
                                batchCancelled.set(false)
                                Thread {
                                    try {
                                        val report = batchWriter.apply(root, selected, batchCancelled) { p ->
                                            runOnUiThread { channel.invokeMethod("batchProgress", p) }
                                        }
                                        runOnUiThread {
                                            busyOperation = null
                                            result.success(report)
                                        }
                                    } catch (error: Exception) {
                                        runOnUiThread {
                                            busyOperation = null
                                            result.error("BATCH", error.message, null)
                                        }
                                    }
                                }.start()
                            }
                        }
                    }
                    "undoLastBatch" -> {
                        if (!hasPermission()) {
                            result.error("PERMISSION", "All-files access required", null)
                        } else if (busyOperation != null) {
                            result.error("BUSY", "Another operation is in progress", null)
                        } else {
                            busyOperation = "undo"
                            Thread {
                                try {
                                    val report = batchWriter.undo()
                                    runOnUiThread {
                                        busyOperation = null
                                        result.success(report)
                                    }
                                } catch (error: Exception) {
                                    runOnUiThread {
                                        busyOperation = null
                                        result.error("UNDO", error.message, null)
                                    }
                                }
                            }.start()
                        }
                    }
                    "cancelBatch" -> {
                        if (busyOperation == "apply") {
                            batchCancelled.set(true)
                        }
                        result.success(null)
                    }
                    "hasPermission" -> result.success(hasPermission())
                    "openPermissionSettings" -> {
                        try {
                            openPermissionSettings()
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("SETTINGS", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun hasPermission(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && Environment.isExternalStorageManager()

    private fun openPermissionSettings() {
        val appSettings = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
            Uri.parse("package:$packageName"))
        try {
            startActivity(appSettings)
        } catch (_: ActivityNotFoundException) {
            startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
        }
    }

}
