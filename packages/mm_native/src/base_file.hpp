// Platform file I/O used by the native core (positional reads/writes,
// atomic replace, timestamps). Paths are UTF-8.
#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

namespace mm {

class BaseFile {
 public:
  virtual ~BaseFile() = default;
  // Reads up to len bytes at off. Returns bytes read, or -1 on error.
  virtual int64_t pread(uint64_t off, void *buf, size_t len) = 0;
  virtual bool pwrite(uint64_t off, const void *buf, size_t len) = 0;
  virtual int64_t size() = 0;
  virtual bool truncate(uint64_t len) = 0;
  virtual bool sync() = 0;
  // Modification time in nanoseconds since the Unix epoch (0 if unknown).
  virtual int64_t mtimeNs() = 0;
  virtual bool setMtimeNs(int64_t ns) = 0;
  virtual bool writable() const = 0;
};

enum class OpenMode { Read, ReadWrite, CreateNew };

// Opens a file by path. Returns nullptr on failure and fills err.
std::unique_ptr<BaseFile> openPath(const std::string &path, OpenMode mode, std::string &err);

// Wraps a caller-owned descriptor (never closed by the wrapper).
std::unique_ptr<BaseFile> wrapFd(int fd, bool writable);

// Atomically replaces `target` with `replacement` (same directory).
bool replaceFile(const std::string &target, const std::string &replacement, std::string &err);

bool fileExists(const std::string &path);
bool removeFile(const std::string &path);
bool renameFile(const std::string &from, const std::string &to);
// Copies POSIX permission bits from one file to another (no-op on Windows).
void copyPermissions(const std::string &from, const std::string &to);
int closeFd(int fd);
// Opens a descriptor (tests / desktop helpers). Returns -1 on failure.
int openFd(const std::string &path, bool writable);

// Returns the directory part of a path (handles both separators).
std::string dirName(const std::string &path);
std::string baseName(const std::string &path);
std::string joinPath(const std::string &dir, const std::string &name);
std::string randomSuffix();

}  // namespace mm
