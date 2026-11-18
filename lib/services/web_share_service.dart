import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'web_share_script.dart';

class _IncomingFile {
  _IncomingFile(this.name, this.mime, this.total);

  final String name;
  final String mime;
  final int total;
  final StringBuffer data = StringBuffer();
  bool ended = false;
}

class _IncomingShare {
  _IncomingShare({
    required this.title,
    required this.text,
    required this.url,
    required this.fileCount,
  });

  final String title;
  final String text;
  final String url;
  final int fileCount;
  final Map<int, _IncomingFile> files = {};
}

/// Opens the system share sheet for WhatsApp links and `navigator.share`,
/// including when the page attaches a file.
class WebShareService {
  WebShareService({
    required this.controller,
    required this.shareOrigin,
  });

  static const _maxBase64Length = 40 * 1024 * 1024;

  final WebViewController Function() controller;
  final Rect Function() shareOrigin;

  final Map<String, _IncomingShare> _incoming = {};
  bool _sharing = false;
  String _recentKey = '';
  DateTime _recentAt = DateTime.fromMillisecondsSinceEpoch(0);

  void injectHook() {
    controller().runJavaScript(webShareHookScript).catchError((Object error) {
      debugPrint('Share hook failed: $error');
    });
  }

  bool shouldInterceptNavigation(String url) => _isWhatsappLink(url);

  void shareFromUrl(String url) {
    final message = _messageFromWhatsapp(url);
    if (message.isEmpty || !_claim(message)) return;
    _present(
      id: null,
      title: 'Share',
      text: message,
      files: const [],
    );
  }

  void onJavaScriptMessage(JavaScriptMessage message) {
    final Object? decoded;
    try {
      decoded = jsonDecode(message.message);
    } catch (error) {
      debugPrint('Share message failed: $error');
      return;
    }
    if (decoded is! Map) return;
    final payload = Map<String, dynamic>.from(decoded);
    switch (payload['type']) {
      case 'begin':
        _onBegin(payload);
      case 'fileStart':
        _onFileStart(payload);
      case 'chunk':
        _onChunk(payload);
      case 'fileEnd':
        _onFileEnd(payload);
      case 'go':
        _onGo(payload['id'] as String? ?? '');
      case 'abort':
        _incoming.remove(payload['id'] as String? ?? '');
    }
  }

  void _onBegin(Map<String, dynamic> payload) {
    final id = payload['id'] as String? ?? '';
    if (id.isEmpty) return;
    final count = payload['fileCount'] as int? ?? 0;
    if (count < 0 || count > 10) {
      _finish(id, 'failed');
      return;
    }
    _incoming[id] = _IncomingShare(
      title: payload['title'] as String? ?? '',
      text: _composeText(
        payload['text'] as String? ?? '',
        payload['url'] as String? ?? '',
      ),
      url: payload['url'] as String? ?? '',
      fileCount: count,
    );
  }

  void _onFileStart(Map<String, dynamic> payload) {
    final share = _incoming[payload['id'] as String? ?? ''];
    final index = payload['index'] as int? ?? -1;
    final total = payload['total'] as int? ?? 0;
    if (share == null || index < 0 || total < 0 || total > _maxBase64Length) {
      return;
    }
    share.files[index] = _IncomingFile(
      payload['name'] as String? ?? 'file',
      payload['mime'] as String? ?? '',
      total,
    );
  }

  void _onChunk(Map<String, dynamic> payload) {
    final share = _incoming[payload['id'] as String? ?? ''];
    final file = share?.files[payload['index'] as int? ?? -1];
    final chunk = payload['data'] as String? ?? '';
    file?.data.write(chunk);
  }

  void _onFileEnd(Map<String, dynamic> payload) {
    final share = _incoming[payload['id'] as String? ?? ''];
    final file = share?.files[payload['index'] as int? ?? -1];
    if (file == null) return;
    file.ended = file.data.length == file.total;
  }

  Future<void> _onGo(String id) async {
    final share = _incoming.remove(id);
    if (share == null) return;
    if (share.files.length != share.fileCount ||
        share.files.values.any((file) => !file.ended)) {
      _finish(id, 'failed');
      return;
    }
    final claimKey = share.fileCount == 0 ? share.text : '${share.text}|${share.fileCount}';
    if (!_claim(claimKey)) {
      _finish(id, 'shared');
      return;
    }

    final saved = <XFile>[];
    try {
      final directory = Directory('${(await getTemporaryDirectory()).path}/shares');
      await directory.create(recursive: true);
      for (var index = 0; index < share.fileCount; index++) {
        final incoming = share.files[index]!;
        final bytes = incoming.total == 0
            ? const <int>[]
            : await Isolate.run(() => base64Decode(incoming.data.toString()));
        final name = _safeName(incoming.name, index);
        final file = File('${directory.path}/$name');
        await file.writeAsBytes(bytes, flush: true);
        saved.add(XFile(file.path, mimeType: _mime(incoming.mime, name), name: name));
      }
    } catch (error) {
      debugPrint('Preparing shared file failed: $error');
      _finish(id, 'failed');
      return;
    }

    await _present(
      id: id,
      title: share.title.isEmpty ? 'Share' : share.title,
      text: share.text,
      files: saved,
    );
  }

  Future<void> _present({
    required String? id,
    required String title,
    required String text,
    required List<XFile> files,
  }) async {
    if (text.isEmpty && files.isEmpty) {
      if (id != null) _finish(id, 'failed');
      return;
    }
    if (_sharing) {
      if (id != null) _finish(id, 'dismissed');
      return;
    }
    _sharing = true;
    try {
      final result = await SharePlus.instance.share(
        ShareParams(
          text: text.isEmpty ? null : text,
          title: title.isEmpty ? 'Share' : title,
          subject: title.isEmpty ? null : title,
          files: files.isEmpty ? null : files,
          fileNameOverrides: files.isEmpty ? null : [for (final file in files) file.name],
          sharePositionOrigin: shareOrigin(),
        ),
      );
      if (id == null) return;
      final status = result.status == ShareResultStatus.dismissed ? 'dismissed' : 'shared';
      _finish(id, status);
    } catch (error) {
      debugPrint('Share sheet failed: $error');
      if (id != null) _finish(id, 'failed');
    } finally {
      _sharing = false;
    }
  }

  void _finish(String id, String status) {
    controller()
        .runJavaScript(
          'window.__eautoShareResult(${jsonEncode(id)}, ${jsonEncode(status)});',
        )
        .catchError((Object error) {
          debugPrint('Share result failed: $error');
        });
  }

  bool _claim(String key) {
    final now = DateTime.now();
    if (key == _recentKey && now.difference(_recentAt) < const Duration(seconds: 2)) {
      return false;
    }
    _recentKey = key;
    _recentAt = now;
    return true;
  }

  bool _isWhatsappLink(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'whatsapp') return true;
    if (scheme == 'intent' && url.toLowerCase().contains('whatsapp')) return true;
    final host = uri.host.toLowerCase();
    return host == 'wa.me' ||
        host == 'api.whatsapp.com' ||
        host == 'web.whatsapp.com' ||
        host == 'chat.whatsapp.com';
  }

  String _messageFromWhatsapp(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return '';
    final text = uri.queryParameters['text'] ?? '';
    if (text.isNotEmpty) return text;
    return url;
  }

  String _composeText(String text, String url) {
    if (text.isEmpty) return url;
    if (url.isEmpty || text.contains(url)) return text;
    return '$text\n$url';
  }

  String _safeName(String raw, int index) {
    var name = raw.split(RegExp(r'[\\/]')).last.trim();
    name = name.replaceAll(RegExp(r'[^\w.\-]+'), '_');
    if (name.isEmpty || name == '.' || name == '..') name = 'file';
    if (name.length > 80) name = name.substring(name.length - 80);
    return '${index}_$name';
  }

  String _mime(String mime, String name) {
    final given = mime.toLowerCase().split(';').first.trim();
    if (given.isNotEmpty && given != 'application/octet-stream') return given;
    final extension = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    switch (extension) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'gif':
        return 'image/gif';
      case 'pdf':
        return 'application/pdf';
      case 'mp4':
        return 'video/mp4';
      default:
        return given.isEmpty ? 'application/octet-stream' : given;
    }
  }
}
