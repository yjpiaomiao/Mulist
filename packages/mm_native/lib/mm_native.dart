/// Dart API of the native metadata core (TagLib + safe-write shim).
///
/// Every call is synchronous and does blocking file IO, so it must only be
/// used from background isolates. A file is addressed by [MmTarget]: a path
/// on desktop, or a descriptor + file name on Android (SAF).
library;

import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'src/bindings.dart' as b;

/// Addresses a file either by [path] or by an open descriptor [fd] whose
/// file [name] (with extension) is used for format detection. The native
/// side never closes [fd].
class MmTarget {
  final String? path;
  final int fd;
  final String? name;

  const MmTarget.path(String this.path, {this.name}) : fd = -1;
  const MmTarget.fd(this.fd, String this.name) : path = null;
}

/// Thrown when the native core reports `ok: false`.
class MmException implements Exception {
  final String code;
  final String? detail;
  MmException(this.code, [this.detail]);
  @override
  String toString() => detail == null ? 'MmException($code)' : 'MmException($code: $detail)';
}

abstract final class MmNative {
  static String version() => _take(b.mm_version());

  /// Reads tags and audio properties. Throws [MmException] on failure.
  ///
  /// With [thumbDir], a JPEG thumbnail of the cover is written there as
  /// `<coverHash>.jpg` (unless it already exists). With [detail], the result
  /// also lists every tag present in the file with its own properties.
  static Map<String, dynamic> read(MmTarget t,
          {String? thumbDir, int thumbSize = 256, bool detail = false}) =>
      tryRead(t, thumbDir: thumbDir, thumbSize: thumbSize, detail: detail, check: true);

  /// Like [read] but returns the raw result (including `ok: false`).
  static Map<String, dynamic> tryRead(MmTarget t,
      {String? thumbDir, int thumbSize = 256, bool detail = false, bool check = false}) {
    final opts = jsonEncode({'thumbDir': ?thumbDir, 'thumbSize': thumbSize, 'detail': detail});
    return _call(t, (path, name, a) => b.mm_read(path, t.fd, name, a(opts)), check: check);
  }

  static Map<String, dynamic> extractPicture(MmTarget t, int index, String outPath) =>
      _call(t, (path, name, a) => b.mm_extract_picture(path, t.fd, name, index, a(outPath)));

  /// See tagio.cpp for the request and plan formats. Returns the plan.
  static Map<String, dynamic> prepareWrite(MmTarget t, Map<String, dynamic> request,
          {bool check = true}) =>
      _call(t, (path, name, a) => b.mm_prepare_write(path, t.fd, name, a(jsonEncode(request))),
          check: check);

  static Map<String, dynamic> commit(MmTarget t, Map<String, dynamic> plan, {bool check = true}) =>
      _call(t, (path, name, a) => b.mm_commit(path, t.fd, a(jsonEncode(plan))), check: check);

  static Map<String, dynamic> prepareRestore(MmTarget t, Map<String, dynamic> request,
          {bool check = true}) =>
      _call(t, (path, name, a) => b.mm_prepare_restore(path, t.fd, name, a(jsonEncode(request))),
          check: check);

  /// Copies the whole file to [outPath] (whole-file backup).
  static Map<String, dynamic> copyOut(MmTarget t, String outPath) =>
      _call(t, (path, name, a) => b.mm_copy_out(path, t.fd, a(outPath)));

  static Map<String, dynamic> makeThumb(String imagePath, String outPath, int size) =>
      using((arena) => _decode(
          b.mm_make_thumb(imagePath.toNativeUtf8(allocator: arena),
              outPath.toNativeUtf8(allocator: arena), size),
          true));

  static int closeFd(int fd) => b.mm_close_fd(fd);

  /// Opens a descriptor by path (-1 on failure). Used by tests.
  static int openFd(String path, {bool writable = false}) =>
      using((arena) => b.mm_open_fd(path.toNativeUtf8(allocator: arena), writable ? 1 : 0));

  /// Lists one directory: entries with name `n`, directory `d`, link `l`,
  /// size `s`, mtime ns `m`, hidden `h`. Throws [MmException] on failure.
  static List<Map<String, dynamic>> listDir(String path) => using((arena) {
        final m = _decode(b.mm_list_dir(path.toNativeUtf8(allocator: arena)), true);
        return (m['entries'] as List).cast<Map<String, dynamic>>();
      });

  /// `{exists, d, s, m}` of a path (links followed; `m` in ns).
  static Map<String, dynamic> stat(String path) =>
      using((arena) => _decode(b.mm_stat(path.toNativeUtf8(allocator: arena)), true));

  /// Canonical path with links resolved, or null.
  static String? realPath(String path) => using((arena) {
        final s = _take(b.mm_real_path(path.toNativeUtf8(allocator: arena)));
        return s.isEmpty ? null : s;
      });

  static Map<String, dynamic> _call(
    MmTarget t,
    Pointer<Utf8> Function(Pointer<Utf8> path, Pointer<Utf8> name, Pointer<Utf8> Function(String) a)
        f, {
    bool check = true,
  }) {
    return using((arena) {
      Pointer<Utf8> s(String? v) => v == null ? nullptr : v.toNativeUtf8(allocator: arena);
      return _decode(f(s(t.path), s(t.name), (v) => v.toNativeUtf8(allocator: arena)), check);
    });
  }

  static String _take(Pointer<Utf8> p) {
    if (p == nullptr) throw MmException('null_result');
    try {
      return p.toDartString();
    } finally {
      b.mm_free(p);
    }
  }

  static Map<String, dynamic> _decode(Pointer<Utf8> p, bool check) {
    final m = jsonDecode(_take(p)) as Map<String, dynamic>;
    if (check && m['ok'] != true) {
      throw MmException(m['error'] as String? ?? 'unknown', m['detail'] as String?);
    }
    return m;
  }
}
