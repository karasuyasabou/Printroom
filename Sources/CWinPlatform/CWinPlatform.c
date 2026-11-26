#include "CWinPlatform.h"

#ifdef _WIN32

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void set_error(uint32_t *win_error, DWORD code) {
  if (win_error) {
    *win_error = (uint32_t)code;
  }
}

static wchar_t *utf8_to_wide(const char *utf8_path, uint32_t *win_error) {
  if (!utf8_path || utf8_path[0] == '\0') {
    set_error(win_error, ERROR_INVALID_PARAMETER);
    return NULL;
  }
  int len = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8_path, -1, NULL, 0);
  if (len <= 0) {
    set_error(win_error, GetLastError());
    return NULL;
  }
  wchar_t *wide = (wchar_t *)malloc((size_t)len * sizeof(wchar_t));
  if (!wide) {
    set_error(win_error, ERROR_OUTOFMEMORY);
    return NULL;
  }
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8_path, -1, wide, len) <= 0) {
    set_error(win_error, GetLastError());
    free(wide);
    return NULL;
  }
  for (int i = 0; i < len - 1; ++i) {
    if (wide[i] == L'/') {
      wide[i] = L'\\';
    }
  }
  return wide;
}

static void filetime_to_unix(FILETIME ft, int64_t *sec, int64_t *nsec) {
  uint64_t ticks = ((uint64_t)ft.dwHighDateTime << 32) | (uint64_t)ft.dwLowDateTime;
  const uint64_t epoch_diff = 116444736000000000ULL;
  if (ticks >= epoch_diff) {
    uint64_t unix_ticks = ticks - epoch_diff;
    *sec = (int64_t)(unix_ticks / 10000000ULL);
    *nsec = (int64_t)((unix_ticks % 10000000ULL) * 100ULL);
  } else {
    uint64_t before = epoch_diff - ticks;
    int64_t s = (int64_t)(before / 10000000ULL);
    uint64_t rem = before % 10000000ULL;
    if (rem == 0) {
      *sec = -s;
      *nsec = 0;
    } else {
      *sec = -s - 1;
      *nsec = (int64_t)((10000000ULL - rem) * 100ULL);
    }
  }
}

int pr_win_lstat(const char *utf8_path, PRWinFileStat *out_stat, uint32_t *win_error) {
  if (!out_stat) {
    set_error(win_error, ERROR_INVALID_PARAMETER);
    return -1;
  }
  memset(out_stat, 0, sizeof(*out_stat));
  wchar_t *wide = utf8_to_wide(utf8_path, win_error);
  if (!wide) {
    return -1;
  }
  HANDLE handle = CreateFileW(
      wide,
      FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
      NULL,
      OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
      NULL);
  DWORD err = GetLastError();
  free(wide);
  if (handle == INVALID_HANDLE_VALUE) {
    set_error(win_error, err);
    if (err == ERROR_FILE_NOT_FOUND || err == ERROR_PATH_NOT_FOUND) {
      return 1;
    }
    return -1;
  }
  BY_HANDLE_FILE_INFORMATION info;
  if (!GetFileInformationByHandle(handle, &info)) {
    err = GetLastError();
    CloseHandle(handle);
    set_error(win_error, err);
    return -1;
  }
  CloseHandle(handle);
  out_stat->is_reparse = (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ? 1 : 0;
  out_stat->is_directory = (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? 1 : 0;
  out_stat->is_regular = (!out_stat->is_reparse && !out_stat->is_directory) ? 1 : 0;
  out_stat->size = (int64_t)(((uint64_t)info.nFileSizeHigh << 32) | (uint64_t)info.nFileSizeLow);
  out_stat->file_id = ((uint64_t)info.nFileIndexHigh << 32) | (uint64_t)info.nFileIndexLow;
  filetime_to_unix(info.ftLastWriteTime, &out_stat->mtime_sec, &out_stat->mtime_nsec);
  set_error(win_error, 0);
  return 0;
}

int pr_win_path_exists_nofollow(const char *utf8_path, uint32_t *win_error) {
  wchar_t *wide = utf8_to_wide(utf8_path, win_error);
  if (!wide) {
    return -1;
  }
  WIN32_FILE_ATTRIBUTE_DATA data;
  BOOL ok = GetFileAttributesExW(wide, GetFileExInfoStandard, &data);
  DWORD err = GetLastError();
  free(wide);
  if (ok) {
    set_error(win_error, 0);
    return 1;
  }
  if (err == ERROR_FILE_NOT_FOUND || err == ERROR_PATH_NOT_FOUND) {
    set_error(win_error, 0);
    return 0;
  }
  set_error(win_error, err);
  return -1;
}

intptr_t pr_win_open_read(const char *utf8_path, uint32_t *win_error) {
  wchar_t *wide = utf8_to_wide(utf8_path, win_error);
  if (!wide) {
    return -1;
  }
  HANDLE handle = CreateFileW(
      wide,
      GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
      NULL,
      OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL,
      NULL);
  DWORD err = GetLastError();
  free(wide);
  if (handle == INVALID_HANDLE_VALUE) {
    set_error(win_error, err);
    return -1;
  }
  set_error(win_error, 0);
  return (intptr_t)handle;
}

int64_t pr_win_pread(intptr_t handle_val, uint64_t offset, void *buffer, size_t count, uint32_t *win_error) {
  HANDLE handle = (HANDLE)handle_val;
  if (handle == INVALID_HANDLE_VALUE || (!buffer && count > 0)) {
    set_error(win_error, ERROR_INVALID_PARAMETER);
    return -1;
  }
  uint8_t *dst = (uint8_t *)buffer;
  size_t total = 0;
  while (total < count) {
    size_t remaining = count - total;
    DWORD chunk = remaining > 0x40000000ULL ? 0x40000000UL : (DWORD)remaining;
    uint64_t pos = offset + (uint64_t)total;
    OVERLAPPED ov;
    memset(&ov, 0, sizeof(ov));
    ov.Offset = (DWORD)(pos & 0xFFFFFFFFULL);
    ov.OffsetHigh = (DWORD)((pos >> 32) & 0xFFFFFFFFULL);
    DWORD read_bytes = 0;
    if (!ReadFile(handle, dst + total, chunk, &read_bytes, &ov)) {
      DWORD err = GetLastError();
      if (err == ERROR_HANDLE_EOF) {
        break;
      }
      set_error(win_error, err);
      return -1;
    }
    if (read_bytes == 0) {
      break;
    }
    total += (size_t)read_bytes;
  }
  set_error(win_error, 0);
  return (int64_t)total;
}

intptr_t pr_win_open_temp_excl(const char *utf8_path, uint32_t *win_error) {
  wchar_t *wide = utf8_to_wide(utf8_path, win_error);
  if (!wide) {
    return -1;
  }
  HANDLE handle = CreateFileW(
      wide,
      GENERIC_READ | GENERIC_WRITE,
      0,
      NULL,
      CREATE_NEW,
      FILE_ATTRIBUTE_NORMAL,
      NULL);
  DWORD err = GetLastError();
  free(wide);
  if (handle == INVALID_HANDLE_VALUE) {
    set_error(win_error, err);
    return -1;
  }
  set_error(win_error, 0);
  return (intptr_t)handle;
}

int pr_win_write_all(intptr_t handle_val, const void *buffer, size_t count, uint32_t *win_error) {
  HANDLE handle = (HANDLE)handle_val;
  if (handle == INVALID_HANDLE_VALUE || (!buffer && count > 0)) {
    set_error(win_error, ERROR_INVALID_PARAMETER);
    return -1;
  }
  const uint8_t *src = (const uint8_t *)buffer;
  size_t total = 0;
  while (total < count) {
    size_t remaining = count - total;
    DWORD chunk = remaining > 0x40000000ULL ? 0x40000000UL : (DWORD)remaining;
    DWORD written = 0;
    if (!WriteFile(handle, src + total, chunk, &written, NULL)) {
      set_error(win_error, GetLastError());
      return -1;
    }
    if (written == 0) {
      set_error(win_error, ERROR_WRITE_FAULT);
      return -1;
    }
    total += (size_t)written;
  }
  set_error(win_error, 0);
  return 0;
}

int pr_win_pwrite_all(intptr_t handle_val, uint64_t offset, const void *buffer, size_t count, uint32_t *win_error) {
  HANDLE handle = (HANDLE)handle_val;
  if (handle == INVALID_HANDLE_VALUE) {
    set_error(win_error, ERROR_INVALID_PARAMETER);
    return -1;
  }
  LARGE_INTEGER pos;
  pos.QuadPart = (LONGLONG)offset;
  if (!SetFilePointerEx(handle, pos, NULL, FILE_BEGIN)) {
    set_error(win_error, GetLastError());
    return -1;
  }
  return pr_win_write_all(handle_val, buffer, count, win_error);
}

int pr_win_flush_close(intptr_t handle_val, uint32_t *win_error) {
  HANDLE handle = (HANDLE)handle_val;
  if (handle == INVALID_HANDLE_VALUE) {
    set_error(win_error, ERROR_INVALID_HANDLE);
    return -1;
  }
  BOOL flushed = FlushFileBuffers(handle);
  DWORD flush_err = flushed ? 0 : GetLastError();
  BOOL closed = CloseHandle(handle);
  DWORD close_err = closed ? 0 : GetLastError();
  if (!flushed) {
    set_error(win_error, flush_err);
    return -1;
  }
  if (!closed) {
    set_error(win_error, close_err);
    return -1;
  }
  set_error(win_error, 0);
  return 0;
}

void pr_win_close(intptr_t handle_val) {
  HANDLE handle = (HANDLE)handle_val;
  if (handle != INVALID_HANDLE_VALUE && handle != NULL) {
    CloseHandle(handle);
  }
}

int pr_win_move_excl(const char *src_utf8, const char *dst_utf8, uint32_t *win_error) {
  wchar_t *src = utf8_to_wide(src_utf8, win_error);
  if (!src) {
    return -1;
  }
  wchar_t *dst = utf8_to_wide(dst_utf8, win_error);
  if (!dst) {
    free(src);
    return -1;
  }
  BOOL ok = MoveFileExW(src, dst, MOVEFILE_WRITE_THROUGH);
  DWORD err = GetLastError();
  free(src);
  free(dst);
  if (ok) {
    set_error(win_error, 0);
    return 0;
  }
  set_error(win_error, err);
  if (err == ERROR_ALREADY_EXISTS || err == ERROR_FILE_EXISTS) {
    return 1;
  }
  return -1;
}

int pr_win_move_replace(const char *src_utf8, const char *dst_utf8, uint32_t *win_error) {
  wchar_t *src = utf8_to_wide(src_utf8, win_error);
  if (!src) {
    return -1;
  }
  wchar_t *dst = utf8_to_wide(dst_utf8, win_error);
  if (!dst) {
    free(src);
    return -1;
  }
  DWORD err = 0;
  for (int attempt = 0; attempt < 6; ++attempt) {
    if (MoveFileExW(src, dst, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
      free(src);
      free(dst);
      set_error(win_error, 0);
      return 0;
    }
    err = GetLastError();
    if (err != ERROR_SHARING_VIOLATION && err != ERROR_ACCESS_DENIED) {
      break;
    }
    Sleep(25U * (uint32_t)(attempt + 1));
  }
  free(src);
  free(dst);
  set_error(win_error, err);
  return -1;
}

intptr_t pr_win_lock_open(const char *utf8_path, uint32_t *win_error) {
  wchar_t *wide = utf8_to_wide(utf8_path, win_error);
  if (!wide) {
    return -1;
  }
  HANDLE handle = CreateFileW(
      wide,
      GENERIC_READ | GENERIC_WRITE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
      NULL,
      OPEN_ALWAYS,
      FILE_ATTRIBUTE_NORMAL,
      NULL);
  DWORD err = GetLastError();
  free(wide);
  if (handle == INVALID_HANDLE_VALUE) {
    set_error(win_error, err);
    return -1;
  }
  set_error(win_error, 0);
  return (intptr_t)handle;
}

int pr_win_lock_try(intptr_t handle_val, int exclusive, uint32_t *win_error) {
  HANDLE handle = (HANDLE)handle_val;
  if (handle == INVALID_HANDLE_VALUE) {
    set_error(win_error, ERROR_INVALID_HANDLE);
    return -1;
  }
  OVERLAPPED ov;
  memset(&ov, 0, sizeof(ov));
  DWORD flags = LOCKFILE_FAIL_IMMEDIATELY | (exclusive ? LOCKFILE_EXCLUSIVE_LOCK : 0);
  if (LockFileEx(handle, flags, 0, 1, 0, &ov)) {
    set_error(win_error, 0);
    return 0;
  }
  DWORD err = GetLastError();
  set_error(win_error, err);
  if (err == ERROR_LOCK_VIOLATION) {
    return 1;
  }
  return -1;
}

void pr_win_lock_close(intptr_t handle_val) {
  HANDLE handle = (HANDLE)handle_val;
  if (handle != INVALID_HANDLE_VALUE && handle != NULL) {
    OVERLAPPED ov;
    memset(&ov, 0, sizeof(ov));
    UnlockFileEx(handle, 0, 1, 0, &ov);
    CloseHandle(handle);
  }
}

void pr_win_format_error(uint32_t win_error, char *buffer, size_t capacity) {
  if (!buffer || capacity == 0) {
    return;
  }
  buffer[0] = '\0';
  wchar_t wbuf[512];
  DWORD n = FormatMessageW(
      FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
      NULL,
      win_error,
      MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
      wbuf,
      (DWORD)(sizeof(wbuf) / sizeof(wbuf[0])),
      NULL);
  if (n == 0) {
    snprintf(buffer, capacity, "Win32 error %lu", (unsigned long)win_error);
    return;
  }
  while (n > 0 && (wbuf[n - 1] == L'\r' || wbuf[n - 1] == L'\n' || wbuf[n - 1] == L' ')) {
    wbuf[--n] = L'\0';
  }
  int written = WideCharToMultiByte(CP_UTF8, 0, wbuf, -1, buffer, (int)capacity, NULL, NULL);
  if (written <= 0) {
    snprintf(buffer, capacity, "Win32 error %lu", (unsigned long)win_error);
  }
}

static FILETIME unix_to_filetime(int64_t sec, int64_t nsec) {
  const int64_t epoch_diff_sec = 11644473600LL;
  int64_t total_sec = sec + epoch_diff_sec;
  int64_t ticks = total_sec * 10000000LL + (nsec / 100LL);
  if (ticks < 0) ticks = 0;
  uint64_t uticks = (uint64_t)ticks;
  FILETIME ft;
  ft.dwLowDateTime = (DWORD)(uticks & 0xFFFFFFFFULL);
  ft.dwHighDateTime = (DWORD)((uticks >> 32) & 0xFFFFFFFFULL);
  return ft;
}

int pr_win_get_file_dates(
    const char *utf8_path,
    int32_t *has_creation, int64_t *creation_sec, int64_t *creation_nsec,
    int32_t *has_mod, int64_t *mod_sec, int64_t *mod_nsec,
    uint32_t *win_error) {
  if (has_creation) *has_creation = 0;
  if (has_mod) *has_mod = 0;
  wchar_t *wide = utf8_to_wide(utf8_path, win_error);
  if (!wide) return -1;
  HANDLE handle = CreateFileW(
      wide,
      FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
      NULL,
      OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS,
      NULL);
  DWORD err = GetLastError();
  free(wide);
  if (handle == INVALID_HANDLE_VALUE) {
    set_error(win_error, err);
    return -1;
  }
  FILETIME ctime, atime, mtime;
  BOOL ok = GetFileTime(handle, &ctime, &atime, &mtime);
  err = GetLastError();
  CloseHandle(handle);
  if (!ok) {
    set_error(win_error, err);
    return -1;
  }
  if ((ctime.dwHighDateTime || ctime.dwLowDateTime) && has_creation && creation_sec && creation_nsec) {
    *has_creation = 1;
    filetime_to_unix(ctime, creation_sec, creation_nsec);
  }
  if ((mtime.dwHighDateTime || mtime.dwLowDateTime) && has_mod && mod_sec && mod_nsec) {
    *has_mod = 1;
    filetime_to_unix(mtime, mod_sec, mod_nsec);
  }
  set_error(win_error, 0);
  return 0;
}

int pr_win_set_file_dates(
    const char *utf8_path,
    int32_t has_creation, int64_t creation_sec, int64_t creation_nsec,
    int32_t has_mod, int64_t mod_sec, int64_t mod_nsec,
    uint32_t *win_error) {
  wchar_t *wide = utf8_to_wide(utf8_path, win_error);
  if (!wide) return -1;
  HANDLE handle = CreateFileW(
      wide,
      FILE_WRITE_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
      NULL,
      OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS,
      NULL);
  DWORD err = GetLastError();
  free(wide);
  if (handle == INVALID_HANDLE_VALUE) {
    set_error(win_error, err);
    return -1;
  }
  FILETIME ctime, mtime;
  FILETIME *pctime = NULL;
  FILETIME *pmtime = NULL;
  if (has_creation) {
    ctime = unix_to_filetime(creation_sec, creation_nsec);
    pctime = &ctime;
  }
  if (has_mod) {
    mtime = unix_to_filetime(mod_sec, mod_nsec);
    pmtime = &mtime;
  }
  BOOL ok = SetFileTime(handle, pctime, NULL, pmtime);
  err = GetLastError();
  CloseHandle(handle);
  if (!ok) {
    set_error(win_error, err);
    return -1;
  }
  set_error(win_error, 0);
  return 0;
}

#else

int pr_win_lstat(const char *utf8_path, PRWinFileStat *out_stat, uint32_t *win_error) { (void)utf8_path; (void)out_stat; (void)win_error; return -1; }
int pr_win_path_exists_nofollow(const char *utf8_path, uint32_t *win_error) { (void)utf8_path; (void)win_error; return -1; }
intptr_t pr_win_open_read(const char *utf8_path, uint32_t *win_error) { (void)utf8_path; (void)win_error; return -1; }
int64_t pr_win_pread(intptr_t handle, uint64_t offset, void *buffer, size_t count, uint32_t *win_error) { (void)handle; (void)offset; (void)buffer; (void)count; (void)win_error; return -1; }
intptr_t pr_win_open_temp_excl(const char *utf8_path, uint32_t *win_error) { (void)utf8_path; (void)win_error; return -1; }
int pr_win_write_all(intptr_t handle, const void *buffer, size_t count, uint32_t *win_error) { (void)handle; (void)buffer; (void)count; (void)win_error; return -1; }
int pr_win_pwrite_all(intptr_t handle, uint64_t offset, const void *buffer, size_t count, uint32_t *win_error) { (void)handle; (void)offset; (void)buffer; (void)count; (void)win_error; return -1; }
int pr_win_flush_close(intptr_t handle, uint32_t *win_error) { (void)handle; (void)win_error; return -1; }
void pr_win_close(intptr_t handle) { (void)handle; }
int pr_win_move_excl(const char *src_utf8, const char *dst_utf8, uint32_t *win_error) { (void)src_utf8; (void)dst_utf8; (void)win_error; return -1; }
int pr_win_move_replace(const char *src_utf8, const char *dst_utf8, uint32_t *win_error) { (void)src_utf8; (void)dst_utf8; (void)win_error; return -1; }
intptr_t pr_win_lock_open(const char *utf8_path, uint32_t *win_error) { (void)utf8_path; (void)win_error; return -1; }
int pr_win_lock_try(intptr_t handle, int exclusive, uint32_t *win_error) { (void)handle; (void)exclusive; (void)win_error; return -1; }
void pr_win_lock_close(intptr_t handle) { (void)handle; }
void pr_win_format_error(uint32_t win_error, char *buffer, size_t capacity) { (void)win_error; if (buffer && capacity) buffer[0] = '\0'; }
int pr_win_get_file_dates(const char *utf8_path, int32_t *has_creation, int64_t *creation_sec, int64_t *creation_nsec, int32_t *has_mod, int64_t *mod_sec, int64_t *mod_nsec, uint32_t *win_error) {
  (void)utf8_path; (void)has_creation; (void)creation_sec; (void)creation_nsec; (void)has_mod; (void)mod_sec; (void)mod_nsec; (void)win_error; return -1;
}
int pr_win_set_file_dates(const char *utf8_path, int32_t has_creation, int64_t creation_sec, int64_t creation_nsec, int32_t has_mod, int64_t mod_sec, int64_t mod_nsec, uint32_t *win_error) {
  (void)utf8_path; (void)has_creation; (void)creation_sec; (void)creation_nsec; (void)has_mod; (void)mod_sec; (void)mod_nsec; (void)win_error; return -1;
}

#endif
