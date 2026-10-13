// mm_core: native metadata engine for Music Manager.
//
// All strings are UTF-8. Every function returning `char*` returns a
// heap-allocated JSON document that MUST be released with mm_free().
// A file is addressed either by `path` (desktop) or by an already opened
// file descriptor `fd` (Android SAF). When fd >= 0 the path is ignored and
// `name` (a file name with extension) is used for format detection.
// The library never closes descriptors passed in by the caller.
#ifndef MM_CORE_H
#define MM_CORE_H

#include <stdint.h>

#if defined(_WIN32)
#define MM_API __declspec(dllexport)
#else
#define MM_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

MM_API void mm_free(char *p);
MM_API char *mm_version(void);

// Reads tags and audio properties.
// opts: {"thumbDir": "...", "thumbSize": 256, "detail": false}
MM_API char *mm_read(const char *path, int fd, const char *name, const char *opts);

// Writes picture #index (0-based, PICTURE complex property order) to out_path.
MM_API char *mm_extract_picture(const char *path, int fd, const char *name, int index,
                                const char *out_path);

// Prepares a tag write without touching the source file. See tagio.cpp for
// the request/plan format.
MM_API char *mm_prepare_write(const char *path, int fd, const char *name, const char *request);

// Applies a plan produced by mm_prepare_write / mm_prepare_restore.
// Idempotent: may be called again after a crash to roll forward.
MM_API char *mm_commit(const char *path, int fd, const char *plan);

// Prepares restoring a byte-level backup produced by a previous write.
MM_API char *mm_prepare_restore(const char *path, int fd, const char *name, const char *request);

// Creates a square JPEG thumbnail from an image file.
MM_API char *mm_make_thumb(const char *image_path, const char *out_path, int size);

// Closes a descriptor (helper for Android, where Dart cannot call close()).
MM_API int mm_close_fd(int fd);

// Copies the whole file to out_path (optional whole-file backup).
MM_API char *mm_copy_out(const char *path, int fd, const char *out_path);

// Opens a descriptor by path (used by tests to exercise descriptor mode).
MM_API int mm_open_fd(const char *path, int writable);

// Lists one directory (desktop scanner). See fsutil.cpp for the format.
MM_API char *mm_list_dir(const char *path);

// Size / mtime of a path (links followed). See fsutil.cpp.
MM_API char *mm_stat(const char *path);

// Canonical path with links resolved (loop detection). "" on failure.
// Returns a plain string (not JSON); release with mm_free.
MM_API char *mm_real_path(const char *path);

#ifdef __cplusplus
}
#endif

#endif
