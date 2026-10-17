package dev.example.pocket_ledger

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Storage Access Framework bridge. Uses system pickers only:
 * no READ/WRITE_EXTERNAL_STORAGE or MANAGE_EXTERNAL_STORAGE permission needed.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "pocket_ledger/saf"
    private val reqSaveFolder = 4101
    private val reqPickFiles = 4102

    private var pendingResult: MethodChannel.Result? = null
    private var pendingFiles: Map<String, ByteArray>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (pendingResult != null) {
                    result.error("BUSY", "Another file operation is in progress", null)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "saveToFolder" -> {
                        @Suppress("UNCHECKED_CAST")
                        pendingFiles = call.argument<Map<String, ByteArray>>("files")
                        pendingResult = result
                        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), reqSaveFolder)
                    }
                    "pickCsvFiles" -> {
                        pendingResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            putExtra(
                                Intent.EXTRA_MIME_TYPES, arrayOf(
                                    "text/csv", "text/comma-separated-values",
                                    "text/plain", "application/vnd.ms-excel",
                                    "application/octet-stream"
                                )
                            )
                            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                        }
                        startActivityForResult(intent, reqPickFiles)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != reqSaveFolder && requestCode != reqPickFiles) return
        val result = pendingResult ?: return
        pendingResult = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            pendingFiles = null
            result.success(null) // user cancelled
            return
        }
        if (requestCode == reqSaveFolder) {
            val files = pendingFiles ?: emptyMap()
            pendingFiles = null
            val tree = data.data ?: return result.success(null)
            Thread {
                try {
                    val parent = DocumentsContract.buildDocumentUriUsingTree(
                        tree, DocumentsContract.getTreeDocumentId(tree)
                    )
                    var written = 0
                    for ((name, bytes) in files) {
                        val uri = DocumentsContract.createDocument(
                            contentResolver, parent, "text/csv", name
                        ) ?: throw IllegalStateException("Cannot create $name")
                        contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                            ?: throw IllegalStateException("Cannot open $name")
                        written++
                    }
                    runOnUiThread { result.success(written) }
                } catch (e: Exception) {
                    runOnUiThread { result.error("WRITE_FAILED", e.javaClass.simpleName, null) }
                }
            }.start()
        } else {
            val uris = mutableListOf<Uri>()
            val clip = data.clipData
            if (clip != null) {
                for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri)
            } else {
                data.data?.let { uris.add(it) }
            }
            Thread {
                try {
                    val out = ArrayList<Map<String, Any>>()
                    for (uri in uris) {
                        val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                            ?: throw IllegalStateException("Cannot read file")
                        if (bytes.size > 20 * 1024 * 1024) throw IllegalStateException("File too large")
                        out.add(mapOf("name" to displayName(uri), "bytes" to bytes))
                    }
                    runOnUiThread { result.success(out) }
                } catch (e: Exception) {
                    runOnUiThread { result.error("READ_FAILED", e.message ?: "read error", null) }
                }
            }.start()
        }
    }

    private fun displayName(uri: Uri): String {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { c -> if (c.moveToFirst()) return c.getString(0) ?: "file.csv" }
        return uri.lastPathSegment ?: "file.csv"
    }
}
