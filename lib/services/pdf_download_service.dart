import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'pdf_download_script.dart';

enum PdfDownloadNotice { progress, saved, failed, dismiss }

class PdfDownloadUpdate {
  const PdfDownloadUpdate._(this.notice, this.message, this.savedPath);

  const PdfDownloadUpdate.progress(String message)
      : this._(PdfDownloadNotice.progress, message, null);

  const PdfDownloadUpdate.saved(String message, String? path)
      : this._(PdfDownloadNotice.saved, message, path);

  const PdfDownloadUpdate.failed(String message)
      : this._(PdfDownloadNotice.failed, message, null);

  const PdfDownloadUpdate.dismiss() : this._(PdfDownloadNotice.dismiss, null, null);

  final PdfDownloadNotice notice;
  final String? message;
  final String? savedPath;
}

class _IncomingPdf {
  _IncomingPdf(this.filename);
  final String filename;
  final StringBuffer data = StringBuffer();
  int expected = 0;
}

/// Saves PDFs that the wrapped website tries to download.
///
/// Chrome handles attachment responses and blob links. The WebView does not,
/// so links, forms, and Android's download callback are forwarded here and
/// written to Downloads on Android or the Files app on iOS.
class PdfDownloadService {
  PdfDownloadService({
    required this.onUpdate,
    required this.controller,
  }) {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  static const _channel = MethodChannel('com.nxp.eauto/downloads');
  static const _maxBase64Length = 110 * 1024 * 1024;

  final void Function(PdfDownloadUpdate update) onUpdate;
  final WebViewController Function() controller;

  final Map<String, _IncomingPdf> _incoming = {};
  final Map<String, DateTime> _recent = {};

  void dispose() {
    _channel.setMethodCallHandler(null);
  }

  void injectHook() {
    unawaited(_injectHook());
  }

  void ensureAndroidDownloadListener() {
    unawaited(_installAndroidDownloadListener());
  }

  bool shouldInterceptNavigation(String url) {
    final lower = url.toLowerCase();
    if (lower.startsWith('blob:')) return true;
    if (lower.startsWith('data:application/pdf') ||
        lower.startsWith('data:application/x-pdf')) {
      return true;
    }
    return _isPdfHttpUrl(url);
  }

  void handleNavigation(String url) {
    unawaited(_handleNavigation(url));
  }

  Future<void> openSaved(String path) async {
    try {
      final opened = await _channel.invokeMethod<bool>('openFile', {'path': path});
      if (opened == false) {
        onUpdate(const PdfDownloadUpdate.failed('No app found to open PDFs'));
      }
    } on PlatformException catch (error) {
      onUpdate(PdfDownloadUpdate.failed(error.message ?? "Couldn't open the PDF"));
    }
  }

  Future<void> _handleNavigation(String url) async {
    final lower = url.toLowerCase();
    if (lower.startsWith('blob:') || lower.startsWith('data:')) {
      if (!_claim(url)) return;
      await _injectHook();
      try {
        await controller().runJavaScript('window.__eautoDownload(${jsonEncode(url)});');
      } catch (error) {
        debugPrint('Blob PDF download failed: $error');
        onUpdate(const PdfDownloadUpdate.failed("Couldn't download the PDF"));
      }
      return;
    }

    await _downloadHttp(
      url,
      filename: _filenameFromUrl(url),
      referrer: await _currentUrl(),
      announceStart: true,
      quietIfNotPdf: false,
    );
  }

  Future<void> _onNativeCall(MethodCall call) async {
    if (call.method != 'onDownloadStart') return;
    final arguments = call.arguments;
    if (arguments is! Map) return;
    final args = Map<Object?, Object?>.from(arguments);
    final url = args['url'] as String? ?? '';
    if (url.isEmpty) return;

    if (url.startsWith('blob:') || url.startsWith('data:')) {
      if (!_claim(url)) return;
      await _injectHook();
      try {
        await controller().runJavaScript('window.__eautoDownload(${jsonEncode(url)});');
      } catch (error) {
        debugPrint('Blob PDF download failed: $error');
        onUpdate(const PdfDownloadUpdate.failed("Couldn't download the PDF"));
      }
      return;
    }

    final mime = args['mimeType'] as String? ?? '';
    final disposition = args['contentDisposition'] as String? ?? '';
    if (!_listenerShouldDownload(url, mime, disposition)) return;

    await _downloadHttp(
      url,
      filename: _filenameFromDisposition(disposition) ?? _filenameFromUrl(url),
      referrer: await _currentUrl(),
      userAgent: args['userAgent'] as String?,
      announceStart: true,
      quietIfNotPdf: !_explicitPdf(url, mime, disposition),
    );
  }

  Future<void> _onJavaScriptMessage(String raw) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (error) {
      debugPrint('PDF download message failed: $error');
      return;
    }
    if (decoded is! Map) return;
    final message = Map<String, dynamic>.from(decoded);
    switch (message['type']) {
      case 'url':
        final url = message['url'] as String? ?? '';
        if (url.isEmpty) return;
        final filename = message['filename'] as String? ?? '';
        await _downloadHttp(
          url,
          filename: filename.isEmpty ? _filenameFromUrl(url) : filename,
          referrer: message['referrer'] as String?,
          announceStart: true,
          quietIfNotPdf: message['quietIfNotPdf'] == true,
        );
      case 'start':
        _onStart(message);
      case 'chunk':
        _onChunk(message);
      case 'end':
        await _onEnd(message);
      case 'error':
        onUpdate(
          PdfDownloadUpdate.failed(
            message['message'] as String? ?? "Couldn't download the PDF",
          ),
        );
    }
  }

  void onJavaScriptMessage(JavaScriptMessage message) {
    unawaited(_onJavaScriptMessage(message.message));
  }

  void _onStart(Map<String, dynamic> message) {
    final id = message['id'] as String? ?? '';
    final total = message['total'] as int? ?? 0;
    if (id.isEmpty || total <= 0 || total > _maxBase64Length) {
      onUpdate(const PdfDownloadUpdate.failed('The PDF is too large to save'));
      return;
    }
    final filename = message['filename'] as String? ?? 'document.pdf';
    final incoming = _IncomingPdf(filename)..expected = total;
    _incoming[id] = incoming;
    onUpdate(const PdfDownloadUpdate.progress('Downloading PDF…'));
  }

  void _onChunk(Map<String, dynamic> message) {
    final incoming = _incoming[message['id'] as String? ?? ''];
    final chunk = message['data'] as String? ?? '';
    incoming?.data.write(chunk);
  }

  Future<void> _onEnd(Map<String, dynamic> message) async {
    final incoming = _incoming.remove(message['id'] as String? ?? '');
    if (incoming == null) return;
    try {
      final encoded = incoming.data.toString();
      final bytes = await Isolate.run(() => base64Decode(encoded));
      final saved = await _channel.invokeMethod('saveBytes', {
        'bytes': bytes,
        'filename': incoming.filename,
      });
      _announceSaved(saved);
    } on PlatformException catch (error) {
      onUpdate(PdfDownloadUpdate.failed(_errorMessage(error)));
    } catch (error) {
      debugPrint('Saving PDF bytes failed: $error');
      onUpdate(const PdfDownloadUpdate.failed("Couldn't save the PDF"));
    }
  }

  Future<void> _downloadHttp(
    String url, {
    String? filename,
    String? referrer,
    String? userAgent,
    required bool announceStart,
    required bool quietIfNotPdf,
  }) async {
    if (!_claim(url)) return;
    if (announceStart) {
      onUpdate(const PdfDownloadUpdate.progress('Downloading PDF…'));
    }
    try {
      final resolvedAgent = (userAgent == null || userAgent.isEmpty)
          ? await controller().getUserAgent()
          : userAgent;
      final saved = await _channel.invokeMethod('downloadUrl', {
        'url': url,
        'filename': filename ?? '',
        'userAgent': resolvedAgent ?? '',
        'referrer': _referrerFor(referrer, url),
      });
      _announceSaved(saved);
    } on PlatformException catch (error) {
      if (error.code == 'not_pdf' && quietIfNotPdf) {
        onUpdate(const PdfDownloadUpdate.dismiss());
        return;
      }
      onUpdate(PdfDownloadUpdate.failed(_errorMessage(error)));
    } catch (error) {
      debugPrint('PDF download failed: $error');
      onUpdate(const PdfDownloadUpdate.failed("Couldn't download the PDF"));
    }
  }

  void _announceSaved(Object? saved) {
    if (saved is! Map) {
      onUpdate(const PdfDownloadUpdate.failed("Couldn't save the PDF"));
      return;
    }
    final map = Map<Object?, Object?>.from(saved);
    final filename = map['filename'] as String? ?? 'PDF';
    final location = map['location'] as String? ?? 'storage';
    final path = map['path'] as String?;
    onUpdate(PdfDownloadUpdate.saved('Saved $filename to $location', path));
  }

  Future<void> _injectHook() async {
    try {
      await controller().runJavaScript(pdfDownloadHookScript);
    } catch (error) {
      debugPrint('PDF download hook failed: $error');
    }
  }

  Future<void> _installAndroidDownloadListener() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<bool>('installDownloadListener');
    } catch (error) {
      debugPrint('PDF download listener failed: $error');
    }
  }

  Future<String?> _currentUrl() async {
    try {
      return await controller().currentUrl();
    } catch (_) {
      return null;
    }
  }

  bool _claim(String url) {
    final now = DateTime.now();
    _recent.removeWhere((_, time) => now.difference(time) > const Duration(seconds: 30));
    final key = url.split('#').first;
    final last = _recent[key];
    if (last != null && now.difference(last) < const Duration(seconds: 3)) {
      return false;
    }
    _recent[key] = now;
    return true;
  }

  bool _listenerShouldDownload(String url, String mime, String disposition) {
    if (_explicitPdf(url, mime, disposition)) return true;
    final normalized = mime.toLowerCase();
    return normalized.isEmpty ||
        normalized.contains('octet-stream') ||
        normalized.contains('force-download') ||
        normalized.contains('application/binary');
  }

  bool _explicitPdf(String url, String mime, String disposition) {
    if (mime.toLowerCase().contains('pdf')) return true;
    if (_isPdfHttpUrl(url)) return true;
    final name = _filenameFromDisposition(disposition);
    return name != null && name.toLowerCase().endsWith('.pdf');
  }

  bool _isPdfHttpUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    final path = _safeDecode(uri.path).toLowerCase().split(';').first;
    if (path.endsWith('.pdf')) return true;
    final format = (uri.queryParameters['format'] ??
            uri.queryParameters['type'] ??
            uri.queryParameters['ext'] ??
            '')
        .toLowerCase();
    return format == 'pdf';
  }

  String _filenameFromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return 'document.pdf';
    final segments = uri.pathSegments.where((part) => part.isNotEmpty).toList();
    if (segments.isEmpty) return 'document.pdf';
    return _safeDecode(segments.last.split(';').first);
  }

  String? _filenameFromDisposition(String header) {
    if (header.isEmpty) return null;
    String? star;
    String? plain;
    for (final part in header.split(';')) {
      final item = part.trim();
      final lower = item.toLowerCase();
      final separator = item.indexOf('=');
      if (separator == -1) continue;
      final value = item.substring(separator + 1).trim();
      if (lower.startsWith('filename*=')) {
        star = value;
      } else if (lower.startsWith('filename=')) {
        plain = value;
      }
    }
    if (star != null) {
      final encoded = star.contains("''") ? star.split("''").last : star;
      final name = _safeDecode(encoded.replaceAll('"', '').trim());
      return name.isEmpty ? null : name;
    }
    if (plain == null) return null;
    final name = plain.replaceAll('"', '').trim();
    return name.isEmpty ? null : name;
  }

  String _safeDecode(String value) {
    try {
      return Uri.decodeComponent(value);
    } catch (_) {
      return value;
    }
  }

  String _referrerFor(String? referrer, String url) {
    if (referrer == null || !referrer.startsWith('http')) return '';
    if (referrer.split('#').first == url.split('#').first) return '';
    return referrer;
  }

  String _errorMessage(PlatformException error) {
    final message = error.message?.trim();
    if (message == null || message.isEmpty) return "Couldn't download the PDF";
    return message;
  }
}
