// Platform integration used by the UI isolate: folder pickers, macOS
// bookmarks, Android SAF pickers, reveal in file manager.
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

import '../core/storage/saf_storage.dart';

const _bookmarks = MethodChannel('io.github.musicmanager/bookmarks');

class PickedFolder {
  final String kind; // path | bookmark | saf
  final String locator;
  final String display;
  final Uint8List? bookmark;
  final String? docId;
  const PickedFolder(this.kind, this.locator, this.display, {this.bookmark, this.docId});

  Map<String, Object?> toArgs() =>
      {'kind': kind, 'locator': locator, 'display': display, 'bookmark': bookmark, 'docId': docId};
}

abstract final class PlatformIo {
  static bool get isDesktop => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// Lets the user choose a folder and keeps access to it.
  static Future<PickedFolder?> pickFolder({String? title}) async {
    if (Platform.isAndroid) {
      final r = await safChannel.invokeMapMethod<String, Object?>('pickTree');
      if (r == null) return null;
      return PickedFolder('saf', r['uri'] as String, r['name'] as String, docId: r['docId'] as String?);
    }
    final path = await getDirectoryPath(confirmButtonText: title);
    if (path == null) return null;
    if (Platform.isMacOS) {
      final bm = await _bookmarks.invokeMethod<Uint8List>('create', {'path': path});
      return PickedFolder('bookmark', path, path, bookmark: bm);
    }
    return PickedFolder('path', path, path);
  }

  /// macOS: resolves a stored bookmark and starts accessing it. Returns the
  /// current path and a refreshed bookmark if it was stale.
  static Future<({String path, Uint8List? refreshed})?> resolveBookmark(Uint8List bookmark) async {
    try {
      final r = await _bookmarks.invokeMapMethod<String, Object?>('resolve', {'bookmark': bookmark});
      if (r == null) return null;
      return (path: r['path'] as String, refreshed: r['bookmark'] as Uint8List?);
    } on PlatformException {
      return null;
    }
  }

  /// Save location for an exported playlist (desktop). Returns a path.
  static Future<String?> pickSavePath(String suggestedName, List<String> extensions) async {
    final loc = await getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: [XTypeGroup(label: extensions.join('/'), extensions: extensions)],
    );
    return loc?.path;
  }

  /// Android: lets the user create a document anywhere and writes [bytes].
  static Future<({String uri, String? docId})?> androidCreateDocument(String name, Uint8List bytes) async {
    final r = await safChannel.invokeMapMethod<String, Object?>(
        'createDocument', {'name': name, 'bytes': bytes, 'mime': 'application/octet-stream'});
    if (r == null) return null;
    return (uri: r['uri'] as String, docId: r['docId'] as String?);
  }

  /// Android: overwrites the document at [uri].
  static Future<void> androidWriteUri(String uri, Uint8List bytes) =>
      safChannel.invokeMethod<void>('writeUri', {'uri': uri, 'bytes': bytes});

  /// Picks an image file (cover).
  static Future<String?> pickImage() async {
    final f = await openFile(acceptedTypeGroups: const [
      XTypeGroup(label: 'Images', extensions: ['jpg', 'jpeg', 'png'], mimeTypes: ['image/jpeg', 'image/png']),
    ]);
    return f?.path;
  }

  /// Shows a file in the system file manager.
  static Future<void> reveal(String path) async {
    if (Platform.isWindows) {
      await Process.run('explorer.exe', ['/select,', path]);
    } else if (Platform.isMacOS) {
      await _bookmarks.invokeMethod('reveal', {'path': path});
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [File(path).parent.path]);
    }
  }
}
