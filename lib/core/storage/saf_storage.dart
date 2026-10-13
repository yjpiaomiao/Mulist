// Android Storage Access Framework backend. The Kotlin side
// (android/app/src/main/kotlin/.../SafStorage.kt) does the DocumentsContract
// work; files are handed to the native core as detached descriptors.
import 'package:flutter/services.dart';

import '../model/library_root.dart';
import '../path/path_key.dart';
import 'storage_backend.dart';

const safChannel = MethodChannel('io.github.musicmanager/saf');

/// Derives a file system path from an ExternalStorageProvider document id:
/// `primary:Music/a.mp3` -> `/storage/emulated/0/Music/a.mp3`,
/// `1A2B-3C4D:Music/a.mp3` -> `/storage/1A2B-3C4D/Music/a.mp3`.
/// Returns null for other providers.
String? safDocIdToPath(String treeUri, String docId) {
  if (!treeUri.startsWith('content://com.android.externalstorage.documents/')) return null;
  final c = docId.indexOf(':');
  if (c <= 0) return null;
  final volume = docId.substring(0, c);
  final rest = docId.substring(c + 1);
  final base = volume == 'primary'
      ? '/storage/emulated/0'
      : RegExp(r'^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$').hasMatch(volume)
          ? '/storage/$volume'
          : null;
  if (base == null) return null;
  return rest.isEmpty ? base : '$base/$rest';
}

class SafStorage implements StorageBackend {
  final MethodChannel _ch;
  SafStorage([MethodChannel? channel]) : _ch = channel ?? safChannel;

  Future<T> _call<T>(String method, Map<String, Object?> args) async {
    try {
      return await _ch.invokeMethod<T>(method, args) as T;
    } on PlatformException catch (e) {
      throw StorageException(e.code, e.message);
    }
  }

  @override
  Stream<List<FileEntry>> enumerate(LibraryRoot root, {void Function(String warning)? warnings}) async* {
    final session = await _call<int>('enumStart', {
      'tree': root.locator,
      'extensions': audioExtensions.toList(),
    });
    try {
      while (true) {
        final r = await _call<Map>('enumNext', {'session': session});
        final entries = (r['entries'] as List).cast<List>();
        for (final w in (r['warnings'] as List? ?? const [])) {
          warnings?.call(w as String);
        }
        if (entries.isNotEmpty) {
          yield [
            for (final e in entries)
              FileEntry(e[1] as String, (e[2] as num).toInt(), (e[3] as num).toInt() * 1000000, e[0] as String),
          ];
        }
        if (r['done'] == true) break;
      }
    } finally {
      await _call<void>('enumCancel', {'session': session});
    }
  }

  Future<String> _docId(LibraryRoot root, String relPath, String? docId) async {
    if (docId != null) return docId;
    final d = await _call<String?>('findDoc', {'tree': root.locator, 'rel': relPath});
    if (d == null) throw StorageException('not_found', relPath);
    return d;
  }

  @override
  Future<NativeFile> open(LibraryRoot root, String relPath, {String? docId, bool write = false}) async {
    final id = await _docId(root, relPath, docId);
    final fd = await _call<int>('openFd', {'tree': root.locator, 'doc': id, 'mode': write ? 'rw' : 'r'});
    return FdFile(fd, relName(relPath));
  }

  @override
  Future<FileEntry?> stat(LibraryRoot root, String relPath, {String? docId}) async {
    final id = docId ?? await _call<String?>('findDoc', {'tree': root.locator, 'rel': relPath});
    if (id == null) return null;
    final r = await _call<List?>('stat', {'tree': root.locator, 'doc': id});
    if (r == null) return null;
    return FileEntry(relPath, (r[0] as num).toInt(), (r[1] as num).toInt() * 1000000, id);
  }

  @override
  Future<List<String>> list(LibraryRoot root, String relDir) async =>
      (await _call<List>('listNames', {'tree': root.locator, 'rel': relDir})).cast<String>();

  @override
  Future<MovedFile> move(LibraryRoot root, String fromRel, String toRel, {String? docId}) async {
    final id = await _docId(root, fromRel, docId);
    final r = await _call<Map>('move', {
      'tree': root.locator,
      'doc': id,
      'fromDir': relDir(fromRel),
      'toDir': relDir(toRel),
      'name': relName(toRel),
    });
    // Providers may pick another name on conflicts: report what happened.
    final name = r['name'] as String;
    return MovedFile(relJoin(relDir(toRel), name), r['doc'] as String);
  }

  @override
  Future<MovedFile> moveAcross(LibraryRoot from, String fromRel, LibraryRoot to, String toRel, {String? docId}) async {
    final id = await _docId(from, fromRel, docId);
    final r = await _call<Map>('moveAcross', {
      'fromTree': from.locator,
      'doc': id,
      'fromDir': relDir(fromRel),
      'toTree': to.locator,
      'toDir': relDir(toRel),
      'name': relName(toRel),
    });
    return MovedFile(relJoin(relDir(toRel), r['name'] as String), r['doc'] as String);
  }

  @override
  Future<void> mkdirs(LibraryRoot root, String relDir) => _call<void>('mkdirs', {'tree': root.locator, 'rel': relDir});

  @override
  Future<void> removeEmptyDir(LibraryRoot root, String relDir) =>
      _call<void>('removeEmptyDir', {'tree': root.locator, 'rel': relDir});

  @override
  String? absolutePath(LibraryRoot root, String relPath, {String? docId}) {
    if (docId != null) return safDocIdToPath(root.locator, docId);
    // Derive from the tree's own document id.
    final treeDoc = Uri.decodeComponent(root.locator.split('/tree/').last);
    final base = safDocIdToPath(root.locator, treeDoc);
    return base == null ? null : '$base/$relPath';
  }

  @override
  Future<bool> exists(LibraryRoot root, String relPath) async =>
      await _call<String?>('findDoc', {'tree': root.locator, 'rel': relPath}) != null;

  /// Writes [bytes] to [relPath] inside the tree (playlist export).
  Future<void> writeFile(LibraryRoot root, String relPath, Uint8List bytes, String mime) =>
      _call<void>('writeFile', {'tree': root.locator, 'rel': relPath, 'bytes': bytes, 'mime': mime});
}
