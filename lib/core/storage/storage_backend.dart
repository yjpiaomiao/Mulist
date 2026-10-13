// Storage abstraction. Tracks are addressed as (root, relPath); backends
// hide the differences between plain paths (Windows/Linux, macOS after the
// bookmark was resolved) and Android SAF document trees.
//
// All methods except the pickers are used from background isolates.
import 'package:mm_native/mm_native.dart';

import '../model/library_root.dart';

class FileEntry {
  /// '/'-separated path relative to the root, as on disk.
  final String relPath;
  final int size;
  final int mtimeNs;

  /// SAF document id (Android only).
  final String? docId;

  const FileEntry(this.relPath, this.size, this.mtimeNs, [this.docId]);
}

/// An open file for the native core. Must be closed.
abstract class NativeFile {
  MmTarget get target;
  void close();
}

class PathFile implements NativeFile {
  @override
  final MmTarget target;
  PathFile(String path) : target = MmTarget.path(path);
  @override
  void close() {}
}

class FdFile implements NativeFile {
  @override
  final MmTarget target;
  bool _closed = false;
  FdFile(int fd, String name) : target = MmTarget.fd(fd, name);
  @override
  void close() {
    if (_closed) return;
    _closed = true;
    MmNative.closeFd(target.fd);
  }
}

class StorageException implements Exception {
  final String code;
  final String? detail;
  StorageException(this.code, [this.detail]);
  @override
  String toString() => 'StorageException($code${detail == null ? '' : ': $detail'})';
}

/// Result of a rename/move: the actual new location (a provider may pick a
/// different name than requested).
class MovedFile {
  final String relPath;
  final String? docId;
  const MovedFile(this.relPath, [this.docId]);
}

abstract class StorageBackend {
  /// Enumerates audio files below [root] (recursive, hidden entries skipped,
  /// links followed with loop detection). Batches are emitted as they are
  /// found. [warnings] receives non-fatal problems (unreadable folders,
  /// link loops, ...).
  Stream<List<FileEntry>> enumerate(LibraryRoot root, {void Function(String warning)? warnings});

  /// Opens a file for reading (or writing) by the native core.
  Future<NativeFile> open(LibraryRoot root, String relPath, {String? docId, bool write = false});

  /// Size and mtime of a file, or null if it does not exist.
  Future<FileEntry?> stat(LibraryRoot root, String relPath, {String? docId});

  /// Names of the entries in directory [relDir] ('' = root). Used for
  /// companion files and conflict checks.
  Future<List<String>> list(LibraryRoot root, String relDir);

  /// Renames / moves a file within the root. Fails if [toRel] exists.
  Future<MovedFile> move(LibraryRoot root, String fromRel, String toRel, {String? docId});

  /// Moves a file from one root to another (rename into a target folder).
  Future<MovedFile> moveAcross(LibraryRoot from, String fromRel, LibraryRoot to, String toRel, {String? docId});

  /// Creates [relDir] and missing parents.
  Future<void> mkdirs(LibraryRoot root, String relDir);

  /// Removes [relDir] if it is empty (after moving files out).
  Future<void> removeEmptyDir(LibraryRoot root, String relDir);

  /// Absolute path of a file for playlists, or null if it cannot be derived.
  String? absolutePath(LibraryRoot root, String relPath, {String? docId});

  /// True if [relPath] is inside a directory that exists in [root].
  Future<bool> exists(LibraryRoot root, String relPath);
}

/// True if [name] should be skipped while scanning (hidden).
bool isHiddenName(String name) => name.startsWith('.') || name == r'$RECYCLE.BIN' || name == 'System Volume Information';
