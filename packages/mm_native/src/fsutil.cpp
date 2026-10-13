// Directory listing for the desktop scanner: one call per directory returns
// names with type, size, mtime and the hidden flag (FindFirstFileExW on
// Windows avoids a stat call per file).
#include <cstring>
#include <string>

#include "json.hpp"
#include "mm_core.h"

#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <climits>
#include <cstdlib>
#endif

namespace {

char *dupStr(const std::string &s) {
  char *p = static_cast<char *>(malloc(s.size() + 1));
  if (p) memcpy(p, s.c_str(), s.size() + 1);
  return p;
}

#if defined(_WIN32)
std::wstring widen(const std::string &s) {
  if (s.empty()) return std::wstring();
  int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
  std::wstring w(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), &w[0], n);
  return w;
}

std::string narrow(const wchar_t *w) {
  int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
  if (n <= 1) return std::string();
  std::string s(n - 1, '\0');
  WideCharToMultiByte(CP_UTF8, 0, w, -1, &s[0], n, nullptr, nullptr);
  return s;
}

std::wstring longPath(const std::string &utf8) {
  std::wstring w = widen(utf8);
  for (auto &c : w)
    if (c == L'/') c = L'\\';
  if (w.rfind(L"\\\\?\\", 0) == 0) return w;
  if (w.rfind(L"\\\\", 0) == 0) return L"\\\\?\\UNC\\" + w.substr(2);
  if (w.size() > 2 && w[1] == L':') return L"\\\\?\\" + w;
  return w;
}

int64_t ftToNs(const FILETIME &ft) {
  int64_t v = (static_cast<int64_t>(ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
  return (v - 116444736000000000LL) * 100;
}
#endif

}  // namespace

extern "C" {

// Lists a directory: {"ok":true,"entries":[{"n","d","l","s","m","h"}...]}
//   d: directory (links resolved), l: symlink/junction/reparse point,
//   s: size, m: mtime ns, h: hidden (dot file or hidden attribute)
MM_API char *mm_list_dir(const char *path) {
  mm::JsonWriter w;
  if (!path) return dupStr("{\"ok\":false,\"error\":\"no_path\"}");
#if defined(_WIN32)
  std::wstring pattern = longPath(path);
  if (!pattern.empty() && pattern.back() != L'\\') pattern += L'\\';
  std::wstring dir = pattern;
  pattern += L'*';
  WIN32_FIND_DATAW fd;
  HANDLE h = FindFirstFileExW(pattern.c_str(), FindExInfoBasic, &fd, FindExSearchNameMatch, nullptr,
                              FIND_FIRST_EX_LARGE_FETCH);
  if (h == INVALID_HANDLE_VALUE) {
    DWORD e = GetLastError();
    if (e == ERROR_FILE_NOT_FOUND) return dupStr("{\"ok\":true,\"entries\":[]}");
    w.beginObject().kv("ok", false).kv("error", e == ERROR_ACCESS_DENIED ? "access_denied" : "list_failed");
    w.kv("code", static_cast<int64_t>(e)).endObject();
    return dupStr(w.str());
  }
  w.beginObject().kv("ok", true).key("entries").beginArray();
  do {
    const wchar_t *n = fd.cFileName;
    if (wcscmp(n, L".") == 0 || wcscmp(n, L"..") == 0) continue;
    bool isDir = (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
    bool isLink = (fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
    bool hidden = (fd.dwFileAttributes & (FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_SYSTEM)) != 0 || n[0] == L'.';
    int64_t size = (static_cast<int64_t>(fd.nFileSizeHigh) << 32) | fd.nFileSizeLow;
    int64_t mtime = ftToNs(fd.ftLastWriteTime);
    if (isLink && !isDir) {
      // File symlink: report the target's size and time.
      WIN32_FILE_ATTRIBUTE_DATA ad;
      if (GetFileAttributesExW((dir + n).c_str(), GetFileExInfoStandard, &ad)) {
        size = (static_cast<int64_t>(ad.nFileSizeHigh) << 32) | ad.nFileSizeLow;
        mtime = ftToNs(ad.ftLastWriteTime);
      }
    }
    w.beginObject().kv("n", narrow(n)).kv("d", isDir).kv("l", isLink).kv("s", size).kv("m", mtime);
    w.kv("h", hidden).endObject();
  } while (FindNextFileW(h, &fd));
  FindClose(h);
#else
  DIR *d = opendir(path);
  if (!d) return dupStr("{\"ok\":false,\"error\":\"list_failed\"}");
  int dfd = dirfd(d);
  w.beginObject().kv("ok", true).key("entries").beginArray();
  while (struct dirent *e = readdir(d)) {
    const char *n = e->d_name;
    if (strcmp(n, ".") == 0 || strcmp(n, "..") == 0) continue;
    struct stat ls, st;
    if (fstatat(dfd, n, &ls, AT_SYMLINK_NOFOLLOW) != 0) continue;
    bool isLink = S_ISLNK(ls.st_mode);
    bool broken = false;
    if (isLink) {
      if (fstatat(dfd, n, &st, 0) != 0) broken = true;
    } else {
      st = ls;
    }
    if (broken) continue;
#if defined(__APPLE__)
    int64_t mtime = static_cast<int64_t>(st.st_mtimespec.tv_sec) * 1000000000LL + st.st_mtimespec.tv_nsec;
    bool hidden = n[0] == '.' || (ls.st_flags & UF_HIDDEN) != 0;
#else
    int64_t mtime = static_cast<int64_t>(st.st_mtim.tv_sec) * 1000000000LL + st.st_mtim.tv_nsec;
    bool hidden = n[0] == '.';
#endif
    w.beginObject().kv("n", std::string(n)).kv("d", S_ISDIR(st.st_mode)).kv("l", isLink);
    w.kv("s", static_cast<int64_t>(st.st_size)).kv("m", mtime).kv("h", hidden).endObject();
  }
  closedir(d);
#endif
  w.endArray().endObject();
  return dupStr(w.str());
}

// {"ok":true,"exists":bool,"d":bool,"s":size,"m":mtimeNs} (links followed)
MM_API char *mm_stat(const char *path) {
  mm::JsonWriter w;
  if (!path) return dupStr("{\"ok\":false,\"error\":\"no_path\"}");
#if defined(_WIN32)
  WIN32_FILE_ATTRIBUTE_DATA ad;
  if (!GetFileAttributesExW(longPath(path).c_str(), GetFileExInfoStandard, &ad)) {
    DWORD e = GetLastError();
    if (e == ERROR_FILE_NOT_FOUND || e == ERROR_PATH_NOT_FOUND) return dupStr("{\"ok\":true,\"exists\":false}");
    w.beginObject().kv("ok", false).kv("error", "stat_failed").kv("code", static_cast<int64_t>(e)).endObject();
    return dupStr(w.str());
  }
  int64_t size = (static_cast<int64_t>(ad.nFileSizeHigh) << 32) | ad.nFileSizeLow;
  bool dir = (ad.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
  int64_t mtime = ftToNs(ad.ftLastWriteTime);
#else
  struct stat st;
  if (stat(path, &st) != 0) return dupStr("{\"ok\":true,\"exists\":false}");
  int64_t size = st.st_size;
  bool dir = S_ISDIR(st.st_mode);
#if defined(__APPLE__)
  int64_t mtime = static_cast<int64_t>(st.st_mtimespec.tv_sec) * 1000000000LL + st.st_mtimespec.tv_nsec;
#else
  int64_t mtime = static_cast<int64_t>(st.st_mtim.tv_sec) * 1000000000LL + st.st_mtim.tv_nsec;
#endif
#endif
  w.beginObject().kv("ok", true).kv("exists", true).kv("d", dir).kv("s", size).kv("m", mtime).endObject();
  return dupStr(w.str());
}

// Canonical path (links resolved) for loop detection; empty on failure.
MM_API char *mm_real_path(const char *path) {
  if (!path) return dupStr("");
#if defined(_WIN32)
  HANDLE h = CreateFileW(longPath(path).c_str(), 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                         nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
  if (h == INVALID_HANDLE_VALUE) return dupStr("");
  wchar_t buf[32768];
  DWORD n = GetFinalPathNameByHandleW(h, buf, 32768, FILE_NAME_NORMALIZED);
  CloseHandle(h);
  if (n == 0 || n >= 32768) return dupStr("");
  return dupStr(narrow(buf));
#else
  char *r = realpath(path, nullptr);
  if (!r) return dupStr("");
  std::string s(r);
  free(r);
  return dupStr(s);
#endif
}

}  // extern "C"
