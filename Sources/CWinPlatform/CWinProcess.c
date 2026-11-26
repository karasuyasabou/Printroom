#define WIN32_LEAN_AND_MEAN
#include "CWinPlatform.h"

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static wchar_t *utf8_to_wide_proc(const char *utf8) {
  if (!utf8) return NULL;
  int len = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
  if (len <= 0) return NULL;
  wchar_t *w = (wchar_t *)malloc((size_t)len * sizeof(wchar_t));
  if (!w) return NULL;
  if (MultiByteToWideChar(CP_UTF8, 0, utf8, -1, w, len) <= 0) {
    free(w);
    return NULL;
  }
  return w;
}

static int file_exists_regular(const wchar_t *wpath) {
  DWORD attr = GetFileAttributesW(wpath);
  return attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

int pr_win_get_file_version_string(
    const char *utf8_path,
    char *out_version_utf8, size_t ver_cap) {
  if (!utf8_path || !out_version_utf8 || ver_cap == 0) return -1;
  out_version_utf8[0] = '\0';
  wchar_t *wpath = utf8_to_wide_proc(utf8_path);
  if (!wpath) return -1;
  DWORD dummy = 0;
  DWORD sz = GetFileVersionInfoSizeW(wpath, &dummy);
  if (sz == 0) {
    free(wpath);
    return -1;
  }
  void *buf = malloc(sz);
  if (!buf) {
    free(wpath);
    return -1;
  }
  int rc = -1;
  if (GetFileVersionInfoW(wpath, 0, sz, buf)) {
    VS_FIXEDFILEINFO *ffi = NULL;
    UINT len = 0;
    if (VerQueryValueW(buf, L"\\", (void **)&ffi, &len) && ffi && len >= sizeof(VS_FIXEDFILEINFO)) {
      snprintf(out_version_utf8, ver_cap, "%u.%u.%u.%u",
          (unsigned)HIWORD(ffi->dwFileVersionMS),
          (unsigned)LOWORD(ffi->dwFileVersionMS),
          (unsigned)HIWORD(ffi->dwFileVersionLS),
          (unsigned)LOWORD(ffi->dwFileVersionLS));
      rc = 0;
    }
  }
  free(buf);
  free(wpath);
  return rc;
}

int pr_win_find_adobe_dng_converter(
    char *out_path_utf8, size_t path_cap,
    char *out_version_utf8, size_t ver_cap) {
  if (!out_path_utf8 || path_cap == 0 || !out_version_utf8 || ver_cap == 0) return -1;
  out_path_utf8[0] = '\0';
  out_version_utf8[0] = '\0';

  wchar_t candidate[MAX_PATH * 2];
  const wchar_t *app_paths = L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\App Paths\\Adobe DNG Converter.exe";
  REGSAM views[2] = { KEY_WOW64_64KEY, KEY_WOW64_32KEY };
  for (int v = 0; v < 2; ++v) {
    HKEY hkey = NULL;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, app_paths, 0, KEY_READ | views[v], &hkey) == ERROR_SUCCESS) {
      DWORD bytes = sizeof(candidate);
      DWORD type = 0;
      LSTATUS st = RegQueryValueExW(hkey, NULL, NULL, &type, (LPBYTE)candidate, &bytes);
      RegCloseKey(hkey);
      if (st == ERROR_SUCCESS && (type == REG_SZ || type == REG_EXPAND_SZ)) {
        wchar_t expanded[MAX_PATH * 2];
        if (type == REG_EXPAND_SZ) {
          ExpandEnvironmentStringsW(candidate, expanded, MAX_PATH * 2);
        } else {
          wcscpy_s(expanded, MAX_PATH * 2, candidate);
        }
        if (file_exists_regular(expanded)) {
          WideCharToMultiByte(CP_UTF8, 0, expanded, -1, out_path_utf8, (int)path_cap, NULL, NULL);
          if (pr_win_get_file_version_string(out_path_utf8, out_version_utf8, ver_cap) != 0) {
            snprintf(out_version_utf8, ver_cap, "windows-registry");
          }
          return 0;
        }
      }
    }
  }

  const wchar_t *fallbacks[] = {
    L"C:\\Program Files\\Adobe\\Adobe DNG Converter\\Adobe DNG Converter.exe",
    L"D:\\Program Files\\Adobe\\Adobe DNG Converter\\Adobe DNG Converter.exe",
    L"C:\\Program Files (x86)\\Adobe\\Adobe DNG Converter\\Adobe DNG Converter.exe",
  };
  for (int i = 0; i < 3; ++i) {
    if (file_exists_regular(fallbacks[i])) {
      WideCharToMultiByte(CP_UTF8, 0, fallbacks[i], -1, out_path_utf8, (int)path_cap, NULL, NULL);
      if (pr_win_get_file_version_string(out_path_utf8, out_version_utf8, ver_cap) != 0) {
        snprintf(out_version_utf8, ver_cap, "windows-installed");
      }
      return 0;
    }
  }
  return -1;
}

typedef struct {
  wchar_t *data;
  size_t len;
  size_t cap;
} WStrBuf;

static int wstr_append(WStrBuf *b, const wchar_t *s, size_t n) {
  if (b->len + n + 1 > b->cap) {
    size_t ncap = b->cap ? b->cap * 2 : 256;
    while (ncap < b->len + n + 1) ncap *= 2;
    wchar_t *nd = (wchar_t *)realloc(b->data, ncap * sizeof(wchar_t));
    if (!nd) return -1;
    b->data = nd;
    b->cap = ncap;
  }
  memcpy(b->data + b->len, s, n * sizeof(wchar_t));
  b->len += n;
  b->data[b->len] = L'\0';
  return 0;
}

static int wstr_append_char(WStrBuf *b, wchar_t c) {
  return wstr_append(b, &c, 1);
}

static int append_quoted_arg(WStrBuf *b, const wchar_t *arg) {
  int needs_quotes = (arg[0] == L'\0') || wcschr(arg, L' ') || wcschr(arg, L'\t') || wcschr(arg, L'"');
  if (!needs_quotes) {
    return wstr_append(b, arg, wcslen(arg));
  }
  if (wstr_append_char(b, L'"') != 0) return -1;
  size_t backslashes = 0;
  for (const wchar_t *p = arg; *p; ++p) {
    if (*p == L'\\') {
      backslashes++;
    } else if (*p == L'"') {
      for (size_t k = 0; k < backslashes * 2 + 1; ++k) {
        if (wstr_append_char(b, L'\\') != 0) return -1;
      }
      backslashes = 0;
      if (wstr_append_char(b, L'"') != 0) return -1;
    } else {
      for (size_t k = 0; k < backslashes; ++k) {
        if (wstr_append_char(b, L'\\') != 0) return -1;
      }
      backslashes = 0;
      if (wstr_append_char(b, *p) != 0) return -1;
    }
  }
  for (size_t k = 0; k < backslashes * 2; ++k) {
    if (wstr_append_char(b, L'\\') != 0) return -1;
  }
  return wstr_append_char(b, L'"');
}

int pr_win_run_hidden_process(
    const char *exe_utf8,
    const char *const *args_utf8,
    size_t arg_count,
    const char *log_path_utf8,
    uint32_t timeout_ms,
    PRWinCancelCallback cancel_cb,
    void *cancel_ctx,
    int32_t *out_exit_code,
    uint32_t *win_error) {
  if (!exe_utf8 || !log_path_utf8 || !out_exit_code) {
    if (win_error) *win_error = ERROR_INVALID_PARAMETER;
    return -1;
  }
  *out_exit_code = -1;

  wchar_t *wexe = utf8_to_wide_proc(exe_utf8);
  wchar_t *wlog = utf8_to_wide_proc(log_path_utf8);
  if (!wexe || !wlog) {
    free(wexe);
    free(wlog);
    if (win_error) *win_error = ERROR_OUTOFMEMORY;
    return -1;
  }

  WStrBuf cmdline = { NULL, 0, 0 };
  if (append_quoted_arg(&cmdline, wexe) != 0) {
    free(cmdline.data); free(wexe); free(wlog);
    if (win_error) *win_error = ERROR_OUTOFMEMORY;
    return -1;
  }
  for (size_t i = 0; i < arg_count; ++i) {
    if (wstr_append_char(&cmdline, L' ') != 0) {
      free(cmdline.data); free(wexe); free(wlog);
      if (win_error) *win_error = ERROR_OUTOFMEMORY;
      return -1;
    }
    wchar_t *warg = utf8_to_wide_proc(args_utf8[i] ? args_utf8[i] : "");
    if (!warg || append_quoted_arg(&cmdline, warg) != 0) {
      free(warg); free(cmdline.data); free(wexe); free(wlog);
      if (win_error) *win_error = ERROR_OUTOFMEMORY;
      return -1;
    }
    free(warg);
  }

  SECURITY_ATTRIBUTES sa;
  ZeroMemory(&sa, sizeof(sa));
  sa.nLength = sizeof(sa);
  sa.bInheritHandle = TRUE;

  HANDLE hLog = CreateFileW(
      wlog, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
      &sa, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  if (hLog == INVALID_HANDLE_VALUE) {
    if (win_error) *win_error = GetLastError();
    free(cmdline.data); free(wexe); free(wlog);
    return -1;
  }

  HANDLE hNul = CreateFileW(
      L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
      &sa, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);

  STARTUPINFOW si;
  ZeroMemory(&si, sizeof(si));
  si.cb = sizeof(si);
  si.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
  si.wShowWindow = SW_HIDE;
  si.hStdInput = (hNul != INVALID_HANDLE_VALUE) ? hNul : NULL;
  si.hStdOutput = hLog;
  si.hStdError = hLog;

  PROCESS_INFORMATION pi;
  ZeroMemory(&pi, sizeof(pi));

  BOOL ok = CreateProcessW(
      wexe, cmdline.data, NULL, NULL, TRUE,
      CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT,
      NULL, NULL, &si, &pi);

  DWORD create_err = ok ? 0 : GetLastError();
  CloseHandle(hLog);
  if (hNul != INVALID_HANDLE_VALUE) CloseHandle(hNul);
  free(cmdline.data);
  free(wexe);
  free(wlog);

  if (!ok) {
    if (win_error) *win_error = create_err;
    return -1;
  }

  ULONGLONG start_tick = GetTickCount64();
  int status = 0; /* 0 = exited, -2 = cancelled, -3 = timeout */
  while (1) {
    DWORD w = WaitForSingleObject(pi.hProcess, 25);
    if (w == WAIT_OBJECT_0) break;
    if (cancel_cb && cancel_cb(cancel_ctx)) {
      TerminateProcess(pi.hProcess, 1);
      WaitForSingleObject(pi.hProcess, 2000);
      status = -2;
      break;
    }
    if (timeout_ms > 0 && (GetTickCount64() - start_tick) >= (ULONGLONG)timeout_ms) {
      TerminateProcess(pi.hProcess, 1);
      WaitForSingleObject(pi.hProcess, 2000);
      status = -3;
      break;
    }
  }

  DWORD exit_code = 1;
  if (status == 0) {
    GetExitCodeProcess(pi.hProcess, &exit_code);
    *out_exit_code = (int32_t)exit_code;
  } else {
    *out_exit_code = status;
  }

  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  return status;
}
