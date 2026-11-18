package com.nxp.eauto

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.webkit.CookieManager
import androidx.core.content.FileProvider
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.URL
import java.net.URLDecoder
import java.net.UnknownHostException

class NotPdfException : IOException("This file is not a PDF")

object PdfStorage {
    private const val maxBytes = 80L * 1024L * 1024L
    private const val defaultUserAgent =
        "Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"

    fun download(
        context: Context,
        urlString: String,
        filenameHint: String?,
        userAgent: String?,
        referrer: String?,
    ): Map<String, String> {
        var current = URL(urlString)
        var hops = 0
        while (hops < 8) {
            if (current.protocol != "http" && current.protocol != "https") {
                throw IOException("Invalid download link")
            }
            val connection = (current.openConnection() as HttpURLConnection).apply {
                instanceFollowRedirects = false
                connectTimeout = 30_000
                readTimeout = 120_000
                setRequestProperty("Accept", "application/pdf,application/octet-stream,*/*")
                setRequestProperty(
                    "User-Agent",
                    userAgent?.takeIf { it.isNotBlank() } ?: defaultUserAgent,
                )
                if (!referrer.isNullOrBlank() && referrer != current.toString()) {
                    setRequestProperty("Referer", referrer)
                }
                CookieManager.getInstance().getCookie(current.toString())?.let { cookie ->
                    setRequestProperty("Cookie", cookie)
                }
            }

            try {
                val code = connection.responseCode
                if (code in 300..399) {
                    val location = connection.getHeaderField("Location")
                        ?: throw IOException("Couldn't download the PDF")
                    val next = URL(current, location)
                    connection.disconnect()
                    current = next
                    hops += 1
                    continue
                }
                if (code == 401 || code == 403) {
                    throw IOException("Please sign in and try again")
                }
                if (code !in 200..299) {
                    throw IOException("Couldn't download the PDF ($code)")
                }
                val length = connection.contentLengthLong
                if (length > maxBytes) {
                    throw IOException("The PDF is too large to save")
                }
                val mime = connection.contentType.orEmpty()
                val disposition = connection.getHeaderField("Content-Disposition")
                val filename = sanitize(
                    filenameFromContentDisposition(disposition)
                        ?: filenameHint
                        ?: nameFromUrl(current),
                )
                return saveResponse(context, connection, filename, mime)
            } catch (error: Exception) {
                connection.disconnect()
                throw error
            }
        }
        throw IOException("Couldn't download the PDF")
    }

    fun saveBytes(context: Context, bytes: ByteArray, filenameHint: String?): Map<String, String> {
        if (bytes.isEmpty()) throw IOException("The PDF was empty")
        if (bytes.size > maxBytes) throw IOException("The PDF is too large to save")
        if (!looksLikePdf(bytes, bytes.size, "application/pdf")) throw NotPdfException()
        val filename = sanitize(filenameHint ?: "document.pdf")
        val destination = createDestination(context, filename)
        return writeAll(destination, ByteArrayInputStream(bytes))
    }

    fun open(context: Context, path: String) {
        val uri = if (path.startsWith("content:")) {
            Uri.parse(path)
        } else {
            val file = File(path)
            if (!file.exists()) throw IOException("Couldn't open the PDF")
            FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        }
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/pdf")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            if (context !is Activity) {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        }
        try {
            context.startActivity(intent)
        } catch (_: ActivityNotFoundException) {
            throw ActivityNotFoundException("No app found to open PDFs")
        }
    }

    fun friendlyMessage(error: Exception): String {
        return when (error) {
            is UnknownHostException, is SocketTimeoutException, is SocketException ->
                "Couldn't download the PDF. Check your connection and try again."
            else -> {
                val message = error.message?.trim()
                if (message.isNullOrEmpty()) "Couldn't download the PDF" else message
            }
        }
    }

    private fun saveResponse(
        context: Context,
        connection: HttpURLConnection,
        filename: String,
        mime: String,
    ): Map<String, String> {
        val input = connection.inputStream.buffered()
        try {
            input.mark(2048)
            val probe = ByteArray(1024)
            val count = input.read(probe)
            if (count <= 0) throw IOException("The PDF was empty")
            if (!looksLikePdf(probe, count, mime)) throw NotPdfException()
            input.reset()
            val destination = createDestination(context, filename)
            return writeAll(destination, input)
        } finally {
            input.close()
            connection.disconnect()
        }
    }

    private fun writeAll(destination: Destination, input: InputStream): Map<String, String> {
        try {
            val buffer = ByteArray(8192)
            var total = 0L
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                total += read
                if (total > maxBytes) throw IOException("The PDF is too large to save")
                destination.stream.write(buffer, 0, read)
            }
            if (total == 0L) throw IOException("The PDF was empty")
            destination.stream.flush()
            destination.stream.close()
            destination.complete()
            return mapOf(
                "path" to destination.path,
                "filename" to destination.displayName,
                "location" to "Downloads",
            )
        } catch (error: Exception) {
            runCatching { destination.stream.close() }
            destination.abandon()
            throw error
        }
    }

    private fun createDestination(context: Context, filename: String): Destination {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = context.contentResolver
            val displayName = uniqueDisplayName(context, filename)
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, displayName)
                put(MediaStore.Downloads.MIME_TYPE, "application/pdf")
                put(MediaStore.Downloads.IS_PENDING, 1)
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            }
            val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val uri = resolver.insert(collection, values) ?: throw IOException("Couldn't save the PDF")
            val stream = resolver.openOutputStream(uri)
            if (stream == null) {
                resolver.delete(uri, null, null)
                throw IOException("Couldn't save the PDF")
            }
            return Destination(
                displayName = displayName,
                stream = stream,
                path = uri.toString(),
                complete = {
                    val published = ContentValues().apply {
                        put(MediaStore.Downloads.IS_PENDING, 0)
                    }
                    resolver.update(uri, published, null, null)
                },
                abandon = { resolver.delete(uri, null, null) },
            )
        }

        val directory = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        if (!directory.exists() && !directory.mkdirs()) {
            throw IOException("Couldn't save the PDF")
        }
        val file = uniqueFile(directory, filename)
        return Destination(
            displayName = file.name,
            stream = FileOutputStream(file),
            path = file.absolutePath,
            complete = {
                MediaScannerConnection.scanFile(
                    context,
                    arrayOf(file.absolutePath),
                    arrayOf("application/pdf"),
                    null,
                )
            },
            abandon = { file.delete() },
        )
    }

    private fun uniqueDisplayName(context: Context, filename: String): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return filename
        val resolver = context.contentResolver
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val dot = filename.lastIndexOf('.')
        val base = if (dot > 0) filename.substring(0, dot) else filename
        val extension = if (dot > 0) filename.substring(dot) else ""
        var candidate = filename
        var index = 1
        while (index < 100) {
            val exists = try {
                val cursor = resolver.query(
                    collection,
                    arrayOf(MediaStore.Downloads._ID),
                    "${MediaStore.Downloads.DISPLAY_NAME}=?",
                    arrayOf(candidate),
                    null,
                )
                cursor?.use { it.moveToFirst() } == true
            } catch (_: Exception) {
                false
            }
            if (!exists) return candidate
            candidate = "$base ($index)$extension"
            index += 1
        }
        return filename
    }

    private fun uniqueFile(directory: File, filename: String): File {
        var candidate = File(directory, filename)
        val dot = filename.lastIndexOf('.')
        val base = if (dot > 0) filename.substring(0, dot) else filename
        val extension = if (dot > 0) filename.substring(dot) else ""
        var index = 1
        while (candidate.exists() && index < 100) {
            candidate = File(directory, "$base ($index)$extension")
            index += 1
        }
        return candidate
    }

    private fun looksLikePdf(data: ByteArray, count: Int, mime: String): Boolean {
        val sampleLength = count.coerceAtMost(1024).coerceAtMost(data.size)
        if (sampleLength <= 0) return false
        val sample = String(data, 0, sampleLength, Charsets.ISO_8859_1)
        val trimmed = sample.trimStart()
        val lower = trimmed.lowercase()
        if (lower.startsWith("<!") ||
            lower.startsWith("<html") ||
            lower.startsWith("<?xml") ||
            trimmed.startsWith("{")
        ) {
            return false
        }
        if (sample.contains("%PDF")) return true
        return mime.lowercase().contains("pdf")
    }

    private fun filenameFromContentDisposition(header: String?): String? {
        if (header.isNullOrBlank()) return null
        var star: String? = null
        var plain: String? = null
        for (part in header.split(';')) {
            val item = part.trim()
            val separator = item.indexOf('=')
            if (separator == -1) continue
            val lower = item.substring(0, separator).trim().lowercase()
            val value = item.substring(separator + 1).trim()
            when (lower) {
                "filename*" -> star = value
                "filename" -> plain = value.trim('"')
            }
        }
        if (star != null) {
            val encoded = star.substringAfter("''", star).trim().trim('"')
            return try {
                URLDecoder.decode(encoded, Charsets.UTF_8.name())
            } catch (_: Exception) {
                encoded
            }.takeIf { it.isNotBlank() }
        }
        return plain?.takeIf { it.isNotBlank() }
    }

    private fun nameFromUrl(url: URL): String {
        val last = url.path.substringAfterLast('/').substringBefore(';')
        if (last.isBlank()) return "document.pdf"
        return try {
            URLDecoder.decode(last, Charsets.UTF_8.name())
        } catch (_: Exception) {
            last
        }
    }

    private fun sanitize(raw: String?): String {
        var name = raw?.substringAfterLast('/')?.substringAfterLast('\\')?.trim().orEmpty()
        name = name.replace(Regex("""[\\/:*?"<>|]"""), "_")
        if (name.length > 120) name = name.take(120)
        if (!name.lowercase().endsWith(".pdf")) name += ".pdf"
        if (name == ".pdf" || name.isBlank()) name = "document.pdf"
        return name
    }

    private class Destination(
        val displayName: String,
        val stream: OutputStream,
        val path: String,
        val complete: () -> Unit,
        val abandon: () -> Unit,
    )
}
