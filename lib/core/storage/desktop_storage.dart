// Path based storage (Windows, Linux, and macOS once the security-scoped
// bookmark of the root has been resolved and access started).
import 'dart:async';
import 'dart:io';

import 'package:mm_native/mm_native.dart';
import 'package:path/path.dart' as p;

import '../model/library_root.dart';
import '../path/path_key.dart';
import 'lnk.dart';
import 'storage_backend.dart';

class DesktopStorage implements StorageBackend {
  /// Resolved targets of Windows shortcuts that stand for folders:
  /// "<physical dir>|<name>" -> target path.
  final _lnkDirs = <String, String>{};

  String _join(String dir, String name) => dir.endsWith(Platform.pathSeparator) ? '$dir$name' : '$dir${Platform.pathSeparator}$name';

  /// Physical path of [relPath]. Path segments that are folder shortcuts
  /// (Windows .lnk) are replaced by their targets.
  String physical(LibraryRoot root, String relPath) {
    var cur = root.locator;
    final segs = splitRel(relPath);
    for (var i = 0; i < segs.length; i++) {
      final s = segs[i];
      if (Platform.isWindows && i < segs.length - 1) {
        final t = _lnkDirs['$cur|$s'] ?? _resolveLnkDir(cur, s);
        if (t != null) {
          cur = t;
          continue;
        }
      }
      cur = _join(cur, s);
    }
    return cur;
  }

  String? _resolveLnkDir(String dir, String name) {
    final candidate = _join(dir, name);
    if (FileSystemEntity.typeSync(candidate) != FileSystemEntityType.notFound) return null;
    final lnk = '$candidate.lnk';
    if (!File(lnk).existsSync()) return null;
    final t = readLnkTarget(lnk);
    if (t == null || !Directory(t).existsSync()) return null;
    _lnkDirs['$dir|$name'] = t;
    return t;
  }

  @override
  Stream<List<FileEntry>> enumerate(LibraryRoot root, {void Function(String warning)? warnings}) async* {
    final visited = <String>{};
    final rootReal = MmNative.realPath(root.locator);
    if (rootReal == null) throw StorageException('root_unavailable', root.displayPath);
    visited.add(rootReal.toLowerCase());
    // (physical dir, relative dir)
    final queue = <(String, String)>[(root.locator, '')];
    var batch = <FileEntry>[];
    final sw = Stopwatch()..start();
    while (queue.isNotEmpty) {
      final (dir, rel) = queue.removeAt(0);
      List<Map<String, dynamic>> entries;
      try {
        entries = MmNative.listDir(dir);
      } on MmException catch (e) {
        warnings?.call('${e.code}: $dir');
        continue;
      }
      for (final e in entries) {
        final name = e['n'] as String;
        if (e['h'] == true || isHiddenName(name)) continue;
        final full = _join(dir, name);
        final relPath = rel.isEmpty ? name : '$rel/$name';
        if (e['d'] == true) {
          if (e['l'] == true) {
            final real = MmNative.realPath(full);
            if (real == null || !visited.add(real.toLowerCase())) {
              warnings?.call('link_loop: $full');
              continue;
            }
          } else {
            // Plain directories can still be reached twice through links.
            final real = MmNative.realPath(full);
            if (real != null && !visited.add(real.toLowerCase())) continue;
          }
          queue.add((full, relPath));
          continue;
        }
        final ext = extOf(name);
        if (Platform.isWindows && ext == 'lnk') {
          final target = readLnkTarget(full);
          if (target == null) continue;
          final type = FileSystemEntity.typeSync(target);
          final shown = name.substring(0, name.length - 4);
          final shownRel = rel.isEmpty ? shown : '$rel/$shown';
          if (type == FileSystemEntityType.directory) {
            final real = MmNative.realPath(target);
            if (real == null || !visited.add(real.toLowerCase())) {
              warnings?.call('link_loop: $full');
              continue;
            }
            // A sibling with the same name would shadow the shortcut.
            if (FileSystemEntity.typeSync(_join(dir, shown)) != FileSystemEntityType.notFound) continue;
            _lnkDirs['$dir|$shown'] = target;
            queue.add((target, shownRel));
          }
          // Shortcuts to single files are not followed: renaming them would
          // need the shortcut and the target to be kept in sync.
          continue;
        }
        if (!audioExtensions.contains(ext)) continue;
        batch.add(FileEntry(relPath, (e['s'] as num).toInt(), (e['m'] as num).toInt()));
        if (batch.length >= 500 || sw.elapsedMilliseconds > 100) {
          yield batch;
          batch = <FileEntry>[];
          sw.reset();
        }
      }
    }
    if (batch.isNotEmpty) yield batch;
  }

  @override
  Future<NativeFile> open(LibraryRoot root, String relPath, {String? docId, bool write = false}) async =>
      PathFile(physical(root, relPath));

  @override
  Future<FileEntry?> stat(LibraryRoot root, String relPath, {String? docId}) async {
    // Native stat: same nanosecond mtime as the scanner's listing.
    final s = MmNative.stat(physical(root, relPath));
    if (s['exists'] != true || s['d'] == true) return null;
    return FileEntry(relPath, (s['s'] as num).toInt(), (s['m'] as num).toInt());
  }

  @override
  Future<List<String>> list(LibraryRoot root, String relDir) async {
    try {
      return [for (final e in MmNative.listDir(physical(root, relDir))) e['n'] as String];
    } on MmException {
      return const [];
    }
  }

  @override
  Future<MovedFile> move(LibraryRoot root, String fromRel, String toRel, {String? docId}) async {
    final from = physical(root, fromRel);
    final to = physical(root, toRel);
    _rename(from, to);
    return MovedFile(toRel);
  }

  @override
  Future<MovedFile> moveAcross(LibraryRoot from, String fromRel, LibraryRoot to, String toRel, {String? docId}) async {
    _rename(physical(from, fromRel), physical(to, toRel));
    return MovedFile(toRel);
  }

  void _rename(String from, String to) {
    final caseOnly = from.toLowerCase() == to.toLowerCase();
    if (!caseOnly && FileSystemEntity.typeSync(to, followLinks: false) != FileSystemEntityType.notFound) {
      throw StorageException('target_exists', to);
    }
    try {
      File(from).renameSync(to);
    } on FileSystemException catch (e) {
      // Different volume: copy, verify the size, then delete.
      if (e.osError?.errorCode == 17 /* ERROR_NOT_SAME_DEVICE */ || e.osError?.errorCode == 18 /* EXDEV */) {
        final src = File(from);
        final tmp = '$to.mm-copy';
        src.copySync(tmp);
        if (File(tmp).lengthSync() != src.lengthSync()) {
          File(tmp).deleteSync();
          throw StorageException('copy_failed', to);
        }
        File(tmp).renameSync(to);
        File(to).setLastModifiedSync(src.lastModifiedSync());
        src.deleteSync();
        return;
      }
      throw StorageException(_code(e), '${e.message}: $from');
    }
  }

  static String _code(FileSystemException e) {
    final c = e.osError?.errorCode;
    if (c == 32 || c == 33) return 'file_in_use';
    if (c == 5 || c == 13 || c == 1) return 'access_denied';
    if (c == 2 || c == 3) return 'not_found';
    return 'rename_failed';
  }

  @override
  Future<void> mkdirs(LibraryRoot root, String relDir) async {
    if (relDir.isEmpty) return;
    Directory(physical(root, relDir)).createSync(recursive: true);
  }

  @override
  Future<void> removeEmptyDir(LibraryRoot root, String relDir) async {
    if (relDir.isEmpty) return;
    final d = Directory(physical(root, relDir));
    try {
      if (d.listSync().isEmpty) d.deleteSync();
    } on FileSystemException {
      // not empty / in use: leave it
    }
  }

  @override
  String? absolutePath(LibraryRoot root, String relPath, {String? docId}) => p.normalize(physical(root, relPath));

  @override
  Future<bool> exists(LibraryRoot root, String relPath) async =>
      FileSystemEntity.typeSync(physical(root, relPath)) != FileSystemEntityType.notFound;
}
