#include "base_file.hpp"

#include <chrono>
#include <random>

#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <fcntl.h>
#include <io.h>
#else
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <cerrno>
#include <cstring>
#endif

namespace mm {

#if defined(_WIN32)

static std::wstring widen(const std::string &s) {
  if (s.empty()) return std::wstring();
  int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
  std::wstring w(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), &w[0], n);
  return w;
}

// Converts to an extended-length path when needed so that paths longer than
// MAX_PATH keep working.
static std::wstring winPath(const std::string &utf8) {
  std::wstring w = widen(utf8);
  for (auto &c : w)
    if (c == L'/') c = L'\\';
  if (w.size() < 240 || w.rfind(L"\\\\?\\", 0) == 0) return w;
  if (w.rfind(L"\\\\", 0) == 0) return L"\\\\?\\UNC\\" + w.substr(2);
  if (w.size() > 2 && w[1] == L':') return L"\\\\?\\" + w;
  return w;
}

static std::string lastError() {
  DWORD e = GetLastError();
  if (e == ERROR_SHARING_VIOLATION || e == ERROR_LOCK_VIOLATION) return "file_in_use";
  if (e == ERROR_ACCESS_DENIED) return "access_denied";
  if (e == ERROR_FILE_NOT_FOUND || e == ERROR_PATH_NOT_FOUND) return "not_found";
  if (e == ERROR_DISK_FULL || e == ERROR_HANDLE_DISK_FULL) return "disk_full";
  return "win32_error_" + std::to_string(e);
}

static const int64_t kEpochDiff100ns = 116444736000000000LL;

class WinFile : public BaseFile {
 public:
  WinFile(HANDLE h, bool w, bool owns = true) : h_(h), w_(w), owns_(owns) {}
  ~WinFile() override {
    if (owns_) CloseHandle(h_);
  }
  int64_t pread(uint64_t off, void *buf, size_t len) override {
    OVERLAPPED ov{};
    ov.Offset = static_cast<DWORD>(off & 0xFFFFFFFFu);
    ov.OffsetHigh = static_cast<DWORD>(off >> 32);
    DWORD got = 0;
    if (!ReadFile(h_, buf, static_cast<DWORD>(len), &got, &ov)) {
      if (GetLastError() == ERROR_HANDLE_EOF) return 0;
      return -1;
    }
    return got;
  }
  bool pwrite(uint64_t off, const void *buf, size_t len) override {
    const char *p = static_cast<const char *>(buf);
    while (len > 0) {
      OVERLAPPED ov{};
      ov.Offset = static_cast<DWORD>(off & 0xFFFFFFFFu);
      ov.OffsetHigh = static_cast<DWORD>(off >> 32);
      DWORD chunk = static_cast<DWORD>(len > (1u << 30) ? (1u << 30) : len);
      DWORD put = 0;
      if (!WriteFile(h_, p, chunk, &put, &ov) || put == 0) return false;
      p += put;
      off += put;
      len -= put;
    }
    return true;
  }
  int64_t size() override {
    LARGE_INTEGER s;
    if (!GetFileSizeEx(h_, &s)) return -1;
    return s.QuadPart;
  }
  bool truncate(uint64_t len) override {
    LARGE_INTEGER li;
    li.QuadPart = static_cast<LONGLONG>(len);
    return SetFilePointerEx(h_, li, nullptr, FILE_BEGIN) && SetEndOfFile(h_);
  }
  bool sync() override { return FlushFileBuffers(h_) != 0; }
  int64_t mtimeNs() override {
    FILETIME ft;
    if (!GetFileTime(h_, nullptr, nullptr, &ft)) return 0;
    int64_t v = (static_cast<int64_t>(ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
    return (v - kEpochDiff100ns) * 100;
  }
  bool setMtimeNs(int64_t ns) override {
    int64_t v = ns / 100 + kEpochDiff100ns;
    FILETIME ft;
    ft.dwLowDateTime = static_cast<DWORD>(v & 0xFFFFFFFF);
    ft.dwHighDateTime = static_cast<DWORD>(v >> 32);
    return SetFileTime(h_, nullptr, nullptr, &ft) != 0;
  }
  bool writable() const override { return w_; }

 private:
  HANDLE h_;
  bool w_;
  bool owns_;
};

std::unique_ptr<BaseFile> openPath(const std::string &path, OpenMode mode, std::string &err) {
  DWORD access = GENERIC_READ;
  DWORD disp = OPEN_EXISTING;
  if (mode == OpenMode::ReadWrite) access |= GENERIC_WRITE;
  if (mode == OpenMode::CreateNew) {
    access |= GENERIC_WRITE;
    disp = CREATE_NEW;
  }
  // Readers share everything; writers deny other writers.
  DWORD share = mode == OpenMode::Read ? (FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
                                       : FILE_SHARE_READ;
  HANDLE h = CreateFileW(winPath(path).c_str(), access | FILE_WRITE_ATTRIBUTES, share, nullptr,
                         disp, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (h == INVALID_HANDLE_VALUE && mode == OpenMode::Read) {
    // Retry without FILE_WRITE_ATTRIBUTES for read-only media.
    h = CreateFileW(winPath(path).c_str(), access, share, nullptr, disp, FILE_ATTRIBUTE_NORMAL,
                    nullptr);
  }
  if (h == INVALID_HANDLE_VALUE) {
    err = lastError();
    return nullptr;
  }
  return std::make_unique<WinFile>(h, mode != OpenMode::Read);
}

// CRT descriptors exist on Windows too; supporting them lets the descriptor
// code path used on Android be tested on every platform.
std::unique_ptr<BaseFile> wrapFd(int fd, bool writable) {
  intptr_t h = _get_osfhandle(fd);
  if (h == -1 || h == -2) return nullptr;
  return std::make_unique<WinFile>(reinterpret_cast<HANDLE>(h), writable, false);
}

int openFd(const std::string &path, bool writable) {
  return _wopen(winPath(path).c_str(), (writable ? _O_RDWR : _O_RDONLY) | _O_BINARY);
}

bool replaceFile(const std::string &target, const std::string &replacement, std::string &err) {
  std::wstring t = winPath(target), r = winPath(replacement);
  if (ReplaceFileW(t.c_str(), r.c_str(), nullptr, REPLACEFILE_IGNORE_MERGE_ERRORS, nullptr,
                   nullptr))
    return true;
  if (MoveFileExW(r.c_str(), t.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
    return true;
  err = lastError();
  return false;
}

bool fileExists(const std::string &path) {
  return GetFileAttributesW(winPath(path).c_str()) != INVALID_FILE_ATTRIBUTES;
}
bool removeFile(const std::string &path) { return DeleteFileW(winPath(path).c_str()) != 0; }
bool renameFile(const std::string &from, const std::string &to) {
  return MoveFileExW(winPath(from).c_str(), winPath(to).c_str(),
                     MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0;
}
void copyPermissions(const std::string &, const std::string &) {}
int closeFd(int fd) { return _close(fd); }

#else  // POSIX

#if defined(__ANDROID__) && !defined(__LP64__)
#define MM_PREAD pread64
#define MM_PWRITE pwrite64
#define MM_FTRUNCATE ftruncate64
#else
#define MM_PREAD ::pread
#define MM_PWRITE ::pwrite
#define MM_FTRUNCATE ::ftruncate
#endif

static std::string errnoName() {
  switch (errno) {
    case EACCES:
    case EPERM: return "access_denied";
    case ENOENT: return "not_found";
    case ENOSPC: return "disk_full";
    case EEXIST: return "exists";
    case EROFS: return "read_only_fs";
    default: return std::string("errno_") + std::to_string(errno);
  }
}

class PosixFile : public BaseFile {
 public:
  PosixFile(int fd, bool w, bool owns) : fd_(fd), w_(w), owns_(owns) {}
  ~PosixFile() override {
    if (owns_) ::close(fd_);
  }
  int64_t pread(uint64_t off, void *buf, size_t len) override {
    size_t total = 0;
    char *p = static_cast<char *>(buf);
    while (total < len) {
      ssize_t r = MM_PREAD(fd_, p + total, len - total, static_cast<off_t>(off + total));
      if (r < 0) {
        if (errno == EINTR) continue;
        return -1;
      }
      if (r == 0) break;
      total += static_cast<size_t>(r);
    }
    return static_cast<int64_t>(total);
  }
  bool pwrite(uint64_t off, const void *buf, size_t len) override {
    const char *p = static_cast<const char *>(buf);
    while (len > 0) {
      ssize_t r = MM_PWRITE(fd_, p, len, static_cast<off_t>(off));
      if (r < 0) {
        if (errno == EINTR) continue;
        return false;
      }
      p += r;
      off += static_cast<uint64_t>(r);
      len -= static_cast<size_t>(r);
    }
    return true;
  }
  int64_t size() override {
    struct stat st;
    if (fstat(fd_, &st) != 0) return -1;
    return st.st_size;
  }
  bool truncate(uint64_t len) override { return MM_FTRUNCATE(fd_, static_cast<off_t>(len)) == 0; }
  bool sync() override { return ::fsync(fd_) == 0; }
  int64_t mtimeNs() override {
    struct stat st;
    if (fstat(fd_, &st) != 0) return 0;
#if defined(__APPLE__)
    return static_cast<int64_t>(st.st_mtimespec.tv_sec) * 1000000000LL + st.st_mtimespec.tv_nsec;
#else
    return static_cast<int64_t>(st.st_mtim.tv_sec) * 1000000000LL + st.st_mtim.tv_nsec;
#endif
  }
  bool setMtimeNs(int64_t ns) override {
    struct timespec ts[2];
    ts[0].tv_sec = 0;
    ts[0].tv_nsec = UTIME_OMIT;
    ts[1].tv_sec = static_cast<time_t>(ns / 1000000000LL);
    ts[1].tv_nsec = static_cast<long>(ns % 1000000000LL);
    return futimens(fd_, ts) == 0;
  }
  bool writable() const override { return w_; }

 private:
  int fd_;
  bool w_;
  bool owns_;
};

std::unique_ptr<BaseFile> openPath(const std::string &path, OpenMode mode, std::string &err) {
  int flags = O_RDONLY;
  if (mode == OpenMode::ReadWrite) flags = O_RDWR;
  if (mode == OpenMode::CreateNew) flags = O_RDWR | O_CREAT | O_EXCL;
#ifdef O_CLOEXEC
  flags |= O_CLOEXEC;
#endif
  int fd = ::open(path.c_str(), flags, 0644);
  if (fd < 0) {
    err = errnoName();
    return nullptr;
  }
  return std::make_unique<PosixFile>(fd, mode != OpenMode::Read, true);
}

std::unique_ptr<BaseFile> wrapFd(int fd, bool writable) {
  return std::make_unique<PosixFile>(fd, writable, false);
}

bool replaceFile(const std::string &target, const std::string &replacement, std::string &err) {
  if (::rename(replacement.c_str(), target.c_str()) == 0) return true;
  err = errnoName();
  return false;
}

bool fileExists(const std::string &path) {
  struct stat st;
  return ::stat(path.c_str(), &st) == 0;
}
bool removeFile(const std::string &path) { return ::unlink(path.c_str()) == 0; }
bool renameFile(const std::string &from, const std::string &to) {
  return ::rename(from.c_str(), to.c_str()) == 0;
}
void copyPermissions(const std::string &from, const std::string &to) {
  struct stat st;
  if (::stat(from.c_str(), &st) == 0) ::chmod(to.c_str(), st.st_mode & 07777);
}
int closeFd(int fd) { return ::close(fd); }
int openFd(const std::string &path, bool writable) {
  return ::open(path.c_str(), (writable ? O_RDWR : O_RDONLY) | O_CLOEXEC);
}

#endif

std::string dirName(const std::string &path) {
  size_t p = path.find_last_of("/\\");
  if (p == std::string::npos) return ".";
  if (p == 0) return path.substr(0, 1);
  return path.substr(0, p);
}

std::string baseName(const std::string &path) {
  size_t p = path.find_last_of("/\\");
  return p == std::string::npos ? path : path.substr(p + 1);
}

std::string joinPath(const std::string &dir, const std::string &name) {
  if (dir.empty()) return name;
  char last = dir.back();
  if (last == '/' || last == '\\') return dir + name;
#if defined(_WIN32)
  return dir + "\\" + name;
#else
  return dir + "/" + name;
#endif
}

std::string randomSuffix() {
  static thread_local std::mt19937_64 rng(
      std::random_device{}() ^
      static_cast<uint64_t>(std::chrono::high_resolution_clock::now().time_since_epoch().count()));
  static const char *hex = "0123456789abcdef";
  std::string s;
  uint64_t v = rng();
  for (int i = 0; i < 12; i++) {
    s += hex[v & 15];
    v >>= 4;
  }
  return s;
}

}  // namespace mm
