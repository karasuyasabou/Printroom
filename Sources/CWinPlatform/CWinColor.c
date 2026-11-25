#define WIN32_LEAN_AND_MEAN
#include "CWinPlatform.h"

#include <windows.h>
#include <icm.h>
#include <stdlib.h>
#include <string.h>

struct PRWinColorTransform {
  HTRANSFORM htransform;
};

static wchar_t *utf8_to_wide_color(const char *utf8) {
  if (!utf8 || !utf8[0]) return NULL;
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

int pr_win_get_monitor_icc_path(intptr_t hwnd, char *out_utf8, size_t cap) {
  if (!out_utf8 || cap == 0) return -1;
  out_utf8[0] = '\0';

  HMONITOR hmon = NULL;
  if (hwnd != 0) {
    hmon = MonitorFromWindow((HWND)hwnd, MONITOR_DEFAULTTONEAREST);
  } else {
    POINT pt = { 0, 0 };
    hmon = MonitorFromPoint(pt, MONITOR_DEFAULTTOPRIMARY);
  }
  if (!hmon) return -1;

  MONITORINFOEXW miex;
  ZeroMemory(&miex, sizeof(miex));
  miex.cbSize = sizeof(miex);
  if (!GetMonitorInfoW(hmon, (LPMONITORINFO)&miex)) return -1;

  HDC hdc = CreateDCW(L"DISPLAY", miex.szDevice, NULL, NULL);
  if (!hdc) return -1;

  wchar_t wpath[MAX_PATH * 4];
  DWORD chars = (DWORD)(sizeof(wpath) / sizeof(wchar_t));
  BOOL ok = GetICMProfileW(hdc, &chars, wpath);
  DeleteDC(hdc);
  if (!ok || wpath[0] == L'\0') return -1;

  DWORD attr = GetFileAttributesW(wpath);
  if (attr == INVALID_FILE_ATTRIBUTES || (attr & FILE_ATTRIBUTE_DIRECTORY) != 0) return -1;

  int n = WideCharToMultiByte(CP_UTF8, 0, wpath, -1, out_utf8, (int)cap, NULL, NULL);
  return (n > 0) ? 0 : -1;
}

PRWinColorTransform *pr_win_color_transform_create(
    const uint8_t *src_icc_bytes, size_t src_icc_len,
    const char *dst_icc_path_utf8,
    uint32_t *win_error) {
  if (!src_icc_bytes || src_icc_len == 0 || src_icc_len > UINT32_MAX || !dst_icc_path_utf8 || !dst_icc_path_utf8[0]) {
    if (win_error) *win_error = ERROR_INVALID_PARAMETER;
    return NULL;
  }

  wchar_t *wdst = utf8_to_wide_color(dst_icc_path_utf8);
  if (!wdst) {
    if (win_error) *win_error = ERROR_OUTOFMEMORY;
    return NULL;
  }

  PROFILE src_prof;
  ZeroMemory(&src_prof, sizeof(src_prof));
  src_prof.dwType = PROFILE_MEMBUFFER;
  src_prof.pProfileData = (PVOID)src_icc_bytes;
  src_prof.cbDataSize = (DWORD)src_icc_len;

  PROFILE dst_prof;
  ZeroMemory(&dst_prof, sizeof(dst_prof));
  dst_prof.dwType = PROFILE_FILENAME;
  dst_prof.pProfileData = (PVOID)wdst;
  dst_prof.cbDataSize = (DWORD)((wcslen(wdst) + 1) * sizeof(wchar_t));

  HPROFILE h_src = OpenColorProfileW(&src_prof, PROFILE_READ, FILE_SHARE_READ, OPEN_EXISTING);
  HPROFILE h_dst = OpenColorProfileW(&dst_prof, PROFILE_READ, FILE_SHARE_READ, OPEN_EXISTING);
  free(wdst);

  if (!h_src || !h_dst) {
    if (win_error) *win_error = GetLastError();
    if (h_src) CloseColorProfile(h_src);
    if (h_dst) CloseColorProfile(h_dst);
    return NULL;
  }

  HPROFILE profiles[2] = { h_src, h_dst };
  DWORD intents[1] = { INTENT_RELATIVE_COLORIMETRIC };
  HTRANSFORM ht = CreateMultiProfileTransform(
      profiles, 2, intents, 1, BEST_MODE | USE_RELATIVE_COLORIMETRIC, INDEX_DONT_CARE);
  if (!ht) {
    ht = CreateMultiProfileTransform(
        profiles, 2, intents, 1, NORMAL_MODE | USE_RELATIVE_COLORIMETRIC, INDEX_DONT_CARE);
  }
  DWORD err = ht ? 0 : GetLastError();
  CloseColorProfile(h_src);
  CloseColorProfile(h_dst);

  if (!ht) {
    if (win_error) *win_error = err;
    return NULL;
  }

  PRWinColorTransform *out = (PRWinColorTransform *)calloc(1, sizeof(PRWinColorTransform));
  if (!out) {
    DeleteColorTransform(ht);
    if (win_error) *win_error = ERROR_OUTOFMEMORY;
    return NULL;
  }
  out->htransform = ht;
  return out;
}

void pr_win_color_transform_destroy(PRWinColorTransform *transform) {
  if (!transform) return;
  if (transform->htransform) DeleteColorTransform(transform->htransform);
  free(transform);
}

int pr_win_color_transform_apply_bgra8(
    PRWinColorTransform *transform,
    const uint16_t *rgb16_in,
    uint8_t *bgra8_out,
    uint32_t width,
    uint32_t height,
    uint32_t *win_error) {
  if (!transform || !transform->htransform || !rgb16_in || !bgra8_out || width == 0 || height == 0) {
    if (win_error) *win_error = ERROR_INVALID_PARAMETER;
    return -1;
  }
  uint64_t in_stride = (uint64_t)width * 6u;
  uint64_t out_stride = (uint64_t)width * 4u;
  if (in_stride > UINT32_MAX || out_stride > UINT32_MAX) {
    if (win_error) *win_error = ERROR_INVALID_PARAMETER;
    return -1;
  }
  BOOL ok = TranslateBitmapBits(
      transform->htransform,
      (PVOID)rgb16_in, BM_16b_RGB,
      width, height, (DWORD)in_stride,
      (PVOID)bgra8_out, BM_xBGRQUADS,
      (DWORD)out_stride,
      NULL, 0);
  if (!ok) {
    if (win_error) *win_error = GetLastError();
    return -1;
  }
  size_t n = (size_t)width * (size_t)height;
  for (size_t i = 0; i < n; ++i) {
    bgra8_out[i * 4 + 3] = 0xFF;
  }
  return 0;
}
