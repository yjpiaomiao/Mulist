// Raw FFI declarations for src/mm_core.h.
@DefaultAsset('package:mm_native/mm_core')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

@Native<Void Function(Pointer<Utf8>)>(isLeaf: true)
external void mm_free(Pointer<Utf8> p);

@Native<Pointer<Utf8> Function()>(isLeaf: true)
external Pointer<Utf8> mm_version();

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Int32, Pointer<Utf8>, Pointer<Utf8>)>()
external Pointer<Utf8> mm_read(Pointer<Utf8> path, int fd, Pointer<Utf8> name, Pointer<Utf8> opts);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Int32, Pointer<Utf8>, Int32, Pointer<Utf8>)>()
external Pointer<Utf8> mm_extract_picture(
    Pointer<Utf8> path, int fd, Pointer<Utf8> name, int index, Pointer<Utf8> outPath);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Int32, Pointer<Utf8>, Pointer<Utf8>)>()
external Pointer<Utf8> mm_prepare_write(
    Pointer<Utf8> path, int fd, Pointer<Utf8> name, Pointer<Utf8> request);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Int32, Pointer<Utf8>)>()
external Pointer<Utf8> mm_commit(Pointer<Utf8> path, int fd, Pointer<Utf8> plan);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Int32, Pointer<Utf8>, Pointer<Utf8>)>()
external Pointer<Utf8> mm_prepare_restore(
    Pointer<Utf8> path, int fd, Pointer<Utf8> name, Pointer<Utf8> request);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Int32)>()
external Pointer<Utf8> mm_make_thumb(Pointer<Utf8> imagePath, Pointer<Utf8> outPath, int size);

@Native<Int32 Function(Int32)>(isLeaf: true)
external int mm_close_fd(int fd);

@Native<Int32 Function(Pointer<Utf8>, Int32)>()
external int mm_open_fd(Pointer<Utf8> path, int writable);

@Native<Pointer<Utf8> Function(Pointer<Utf8>)>()
external Pointer<Utf8> mm_list_dir(Pointer<Utf8> path);

@Native<Pointer<Utf8> Function(Pointer<Utf8>)>()
external Pointer<Utf8> mm_real_path(Pointer<Utf8> path);

@Native<Pointer<Utf8> Function(Pointer<Utf8>, Int32, Pointer<Utf8>)>()
external Pointer<Utf8> mm_copy_out(Pointer<Utf8> path, int fd, Pointer<Utf8> outPath);

@Native<Pointer<Utf8> Function(Pointer<Utf8>)>()
external Pointer<Utf8> mm_stat(Pointer<Utf8> path);
