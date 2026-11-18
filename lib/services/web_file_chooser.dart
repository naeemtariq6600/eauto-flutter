import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// Opens the system gallery, camera, or files picker when a page uses
/// `<input type="file">`. Android WebView does not do this on its own.
class WebFileChooser {
  WebFileChooser({required this.contextProvider});

  final BuildContext Function() contextProvider;
  final ImagePicker _images = ImagePicker();
  bool _busy = false;

  static const _channel = MethodChannel('com.nxp.eauto/downloads');

  Future<void> attach(WebViewController controller) async {
    final platform = controller.platform;
    if (platform is! AndroidWebViewController) return;
    await platform.setAllowFileAccess(true);
    await platform.setAllowContentAccess(true);
    await platform.setOnShowFileSelector(_pick);
  }

  Future<List<String>> _pick(FileSelectorParams params) async {
    if (_busy) return const [];
    _busy = true;
    try {
      final paths = await _choose(params);
      if (paths.isEmpty) return const [];
      return _contentUris(paths);
    } catch (error, stack) {
      debugPrint('File chooser failed: $error\n$stack');
      return const [];
    } finally {
      _busy = false;
    }
  }

  Future<List<String>> _choose(FileSelectorParams params) async {
    final accept = UploadAccept.parse(params.acceptTypes);
    final multiple = params.mode == FileSelectorMode.openMultiple;

    if (params.isCaptureEnabled) {
      if (accept.videos && !accept.images) {
        return _video(ImageSource.camera);
      }
      return _photo(ImageSource.camera);
    }

    final context = contextProvider();
    if (!context.mounted) return const [];

    final choice = await showModalBottomSheet<_ChooserAction>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (accept.images || accept.unrestricted)
                ListTile(
                  leading: const Icon(Icons.photo_library_outlined),
                  title: const Text('Photo library'),
                  onTap: () =>
                      Navigator.pop(sheetContext, _ChooserAction.photos),
                ),
              if (accept.videos)
                ListTile(
                  leading: const Icon(Icons.video_library_outlined),
                  title: const Text('Video library'),
                  onTap: () =>
                      Navigator.pop(sheetContext, _ChooserAction.videos),
                ),
              if (accept.images || accept.unrestricted)
                ListTile(
                  leading: const Icon(Icons.photo_camera_outlined),
                  title: const Text('Take photo'),
                  onTap: () =>
                      Navigator.pop(sheetContext, _ChooserAction.camera),
                ),
              if (accept.videos)
                ListTile(
                  leading: const Icon(Icons.videocam_outlined),
                  title: const Text('Record video'),
                  onTap: () => Navigator.pop(
                    sheetContext,
                    _ChooserAction.recordVideo,
                  ),
                ),
              ListTile(
                leading: const Icon(Icons.folder_open_outlined),
                title: const Text('Browse files'),
                onTap: () => Navigator.pop(sheetContext, _ChooserAction.files),
              ),
              ListTile(
                leading: const Icon(Icons.close),
                title: const Text('Cancel'),
                onTap: () => Navigator.pop(sheetContext),
              ),
            ],
          ),
        );
      },
    );

    if (choice == null) return const [];
    // Let the sheet finish dismissing before the system picker opens.
    await Future<void>.delayed(const Duration(milliseconds: 250));

    switch (choice) {
      case _ChooserAction.photos:
        return multiple ? _photos() : _photo(ImageSource.gallery);
      case _ChooserAction.videos:
        return _video(ImageSource.gallery);
      case _ChooserAction.camera:
        return _photo(ImageSource.camera);
      case _ChooserAction.recordVideo:
        return _video(ImageSource.camera);
      case _ChooserAction.files:
        return _files(accept, multiple);
    }
  }

  Future<List<String>> _photo(ImageSource source) async {
    final file = await _images.pickImage(source: source);
    if (file == null) return const [];
    return [file.path];
  }

  Future<List<String>> _photos() async {
    final files = await _images.pickMultiImage();
    return [for (final file in files) file.path];
  }

  Future<List<String>> _video(ImageSource source) async {
    final file = await _images.pickVideo(source: source);
    if (file == null) return const [];
    return [file.path];
  }

  Future<List<String>> _files(UploadAccept accept, bool multiple) async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: multiple,
      type: accept.fileType,
      allowedExtensions: accept.fileType == FileType.custom
          ? accept.extensions
          : null,
    );
    if (result == null) return const [];
    return [
      for (final file in result.files)
        if (file.path != null) file.path!,
    ];
  }

  Future<List<String>> _contentUris(List<String> paths) async {
    final uris = <String>[];
    for (final path in paths) {
      final staged = await _stage(path);
      try {
        final uri = await _channel.invokeMethod<String>('fileUri', {
          'path': staged,
        });
        if (uri != null && uri.isNotEmpty) {
          uris.add(uri);
          continue;
        }
      } catch (error) {
        debugPrint('Could not share picked file: $error');
      }
      uris.add(Uri.file(staged).toString());
    }
    return uris;
  }

  Future<String> _stage(String path) async {
    if (path.startsWith('content://')) return path;
    final source = File(path);
    if (!await source.exists()) return path;
    final cache = await getTemporaryDirectory();
    final folder = Directory('${cache.path}/uploads');
    await folder.create(recursive: true);
    final name = source.uri.pathSegments.isEmpty
        ? 'upload.jpg'
        : source.uri.pathSegments.last;
    final destination = File(
      '${folder.path}/${DateTime.now().microsecondsSinceEpoch}_$name',
    );
    await source.copy(destination.path);
    return destination.path;
  }
}

enum _ChooserAction { photos, videos, camera, recordVideo, files }

class UploadAccept {
  const UploadAccept({
    required this.images,
    required this.videos,
    required this.audio,
    required this.unrestricted,
    required this.extensions,
  });

  final bool images;
  final bool videos;
  final bool audio;
  final bool unrestricted;
  final List<String> extensions;

  bool get _mediaOnly =>
      (images || videos || audio) && !unrestricted && extensions.isEmpty;

  FileType get fileType {
    if (unrestricted || (!_mediaOnly && extensions.isEmpty)) {
      return FileType.any;
    }
    if (extensions.isNotEmpty && !images && !videos && !audio) {
      return FileType.custom;
    }
    if (images && !videos && !audio) return FileType.image;
    if (videos && !images && !audio) return FileType.video;
    if (audio && !images && !videos) return FileType.audio;
    if (images || videos) return FileType.media;
    return FileType.any;
  }

  static const _imageExtensions = {
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'heic',
    'heif',
    'bmp',
  };
  static const _videoExtensions = {'mp4', 'mov', 'm4v', 'webm', '3gp', 'mkv'};
  static const _audioExtensions = {'mp3', 'wav', 'm4a', 'aac', 'ogg'};

  factory UploadAccept.parse(List<String> acceptTypes) {
    if (acceptTypes.isEmpty ||
        acceptTypes.every((type) => type.trim().isEmpty)) {
      return const UploadAccept(
        images: true,
        videos: false,
        audio: false,
        unrestricted: true,
        extensions: [],
      );
    }

    var images = false;
    var videos = false;
    var audio = false;
    var unrestricted = false;
    final extensions = <String>[];

    for (final raw in acceptTypes.expand((type) => type.split(','))) {
      final type = raw.trim().toLowerCase();
      if (type.isEmpty || type == '*/*' || type == '*') {
        unrestricted = true;
        images = true;
        continue;
      }
      if (type.startsWith('.')) {
        final extension = type.substring(1);
        if (extension.isEmpty) continue;
        extensions.add(extension);
        images = images || _imageExtensions.contains(extension);
        videos = videos || _videoExtensions.contains(extension);
        audio = audio || _audioExtensions.contains(extension);
        continue;
      }
      if (type.startsWith('image/')) {
        images = true;
      } else if (type.startsWith('video/')) {
        videos = true;
      } else if (type.startsWith('audio/')) {
        audio = true;
      } else {
        unrestricted = true;
      }
    }

    return UploadAccept(
      images: images,
      videos: videos,
      audio: audio,
      unrestricted: unrestricted,
      extensions: extensions,
    );
  }
}
