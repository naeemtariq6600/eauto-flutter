package com.nxp.eauto

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

class MainActivity : FlutterActivity() {
    private var downloadChannel: MethodChannel? = null
    private var pendingCall: MethodCall? = null
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        downloadChannel = channel
        channel.setMethodCallHandler { call, result ->
            handle(call, result, skipPermission = false)
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result, skipPermission: Boolean) {
        when (call.method) {
            "installDownloadListener" -> result.success(installDownloadListener())
            "openFile" -> openFile(call, result)
            "fileUri" -> fileUri(call, result)
            "downloadUrl", "saveBytes" -> {
                if (!skipPermission && !hasStoragePermission()) {
                    if (pendingResult != null) {
                        result.error(
                            "busy",
                            "Another download is already waiting for permission",
                            null,
                        )
                        return
                    }
                    pendingCall = call
                    pendingResult = result
                    requestPermissions(
                        arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                        storageRequestCode,
                    )
                    return
                }
                startTransfer(call, result)
            }
            else -> result.notImplemented()
        }
    }

    private fun startTransfer(call: MethodCall, result: MethodChannel.Result) {
        Thread {
            try {
                val saved = when (call.method) {
                    "downloadUrl" -> {
                        val url = call.argument<String>("url")
                        if (url.isNullOrBlank()) throw IOException("Invalid download link")
                        PdfStorage.download(
                            this,
                            url,
                            call.argument("filename"),
                            call.argument("userAgent"),
                            call.argument("referrer"),
                        )
                    }
                    "saveBytes" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                            ?: throw IOException("The PDF was empty")
                        PdfStorage.saveBytes(this, bytes, call.argument("filename"))
                    }
                    else -> throw IOException("Couldn't save the PDF")
                }
                runOnUiThread {
                    try {
                        result.success(saved)
                    } catch (_: IllegalStateException) {
                    }
                }
            } catch (error: NotPdfException) {
                replyError(result, "not_pdf", error.message ?: "This file is not a PDF")
            } catch (error: Exception) {
                replyError(result, "download_failed", PdfStorage.friendlyMessage(error))
            }
        }.start()
    }

    private fun fileUri(call: MethodCall, result: MethodChannel.Result) {
        val raw = call.argument<String>("path")
        if (raw.isNullOrBlank()) {
            result.error("bad_args", "Couldn't read the selected file", null)
            return
        }
        if (raw.startsWith("content://")) {
            result.success(raw)
            return
        }
        val path = if (raw.startsWith("file://")) Uri.parse(raw).path else raw
        if (path.isNullOrBlank()) {
            result.error("bad_args", "Couldn't read the selected file", null)
            return
        }
        val file = File(path)
        if (!file.exists()) {
            result.error("missing", "Couldn't read the selected file", null)
            return
        }
        try {
            val uri = FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                file,
            )
            val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION
            for (target in listOf(packageName, "com.google.android.webview", "com.android.chrome")) {
                try {
                    grantUriPermission(target, uri, flags)
                } catch (_: Exception) {
                }
            }
            result.success(uri.toString())
        } catch (_: IllegalArgumentException) {
            result.success(file.toURI().toString())
        }
    }

    private fun openFile(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path.isNullOrBlank()) {
            result.error("bad_args", "Couldn't open the PDF", null)
            return
        }
        try {
            PdfStorage.open(this, path)
            result.success(true)
        } catch (_: ActivityNotFoundException) {
            result.error("no_app", "No app found to open PDFs", null)
        } catch (_: Exception) {
            result.error("open_failed", "Couldn't open the PDF", null)
        }
    }

    private fun installDownloadListener(): Boolean {
        val webView = findWebView(window.decorView) ?: return false
        webView.setDownloadListener { url, userAgent, contentDisposition, mimetype, _ ->
            downloadChannel?.invokeMethod(
                "onDownloadStart",
                mapOf(
                    "url" to url,
                    "userAgent" to userAgent,
                    "contentDisposition" to contentDisposition,
                    "mimeType" to mimetype,
                ),
            )
        }
        return true
    }

    private fun findWebView(view: View): WebView? {
        if (view is WebView) return view
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) {
                val match = findWebView(view.getChildAt(index))
                if (match != null) return match
            }
        }
        return null
    }

    private fun hasStoragePermission(): Boolean {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q ||
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
            PackageManager.PERMISSION_GRANTED
    }

    @Suppress("DEPRECATION")
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != storageRequestCode) return
        val call = pendingCall
        val pending = pendingResult
        pendingCall = null
        pendingResult = null
        if (call == null || pending == null) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            pending.error("permission_denied", "Allow storage access to save PDFs", null)
            return
        }
        handle(call, pending, skipPermission = true)
    }

    private fun replyError(result: MethodChannel.Result, code: String, message: String) {
        runOnUiThread {
            try {
                result.error(code, message, null)
            } catch (_: IllegalStateException) {
            }
        }
    }

    companion object {
        private const val channelName = "com.nxp.eauto/downloads"
        private const val storageRequestCode = 4811
    }
}
