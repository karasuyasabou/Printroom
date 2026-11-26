#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include "CWinPlatform.h"

#include <windows.h>
#include <objbase.h>
#include <propidl.h>
#include <wincodec.h>
#include <stdlib.h>
#include <string.h>

void pr_win_free_buffer(void *ptr) {
  free(ptr);
}

static wchar_t *utf8_to_wide_alloc(const char *utf8) {
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

static int ensure_wic_factory(IWICImagingFactory **out_factory, int *did_coinit, uint32_t *win_error) {
  HRESULT cohr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
  *did_coinit = SUCCEEDED(cohr) ? 1 : 0;
  if (FAILED(cohr) && cohr != RPC_E_CHANGED_MODE) {
    if (win_error) *win_error = (uint32_t)cohr;
    return -1;
  }
  HRESULT hr = CoCreateInstance(
      &CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER,
      &IID_IWICImagingFactory, (void **)out_factory);
  if (FAILED(hr) || !*out_factory) {
    if (*did_coinit) CoUninitialize();
    *did_coinit = 0;
    if (win_error) *win_error = (uint32_t)hr;
    return -1;
  }
  return 0;
}

static int stream_to_malloc(IStream *stream, uint8_t **out_bytes, size_t *out_len, uint32_t *win_error) {
  STATSTG st;
  ZeroMemory(&st, sizeof(st));
  HRESULT hr = IStream_Stat(stream, &st, STATFLAG_NONAME);
  if (FAILED(hr)) {
    if (win_error) *win_error = (uint32_t)hr;
    return -1;
  }
  if (st.cbSize.QuadPart == 0 || st.cbSize.QuadPart > (ULONGLONG)512 * 1024 * 1024) {
    if (win_error) *win_error = E_FAIL;
    return -1;
  }
  size_t len = (size_t)st.cbSize.QuadPart;
  LARGE_INTEGER zero;
  zero.QuadPart = 0;
  hr = IStream_Seek(stream, zero, STREAM_SEEK_SET, NULL);
  if (FAILED(hr)) {
    if (win_error) *win_error = (uint32_t)hr;
    return -1;
  }
  uint8_t *buf = (uint8_t *)malloc(len);
  if (!buf) {
    if (win_error) *win_error = E_OUTOFMEMORY;
    return -1;
  }
  size_t read_total = 0;
  while (read_total < len) {
    ULONG chunk = 0;
    ULONG ask = (ULONG)((len - read_total) > 0x1000000u ? 0x1000000u : (len - read_total));
    hr = IStream_Read(stream, buf + read_total, ask, &chunk);
    if (FAILED(hr) || chunk == 0) {
      free(buf);
      if (win_error) *win_error = FAILED(hr) ? (uint32_t)hr : E_FAIL;
      return -1;
    }
    read_total += chunk;
  }
  *out_bytes = buf;
  *out_len = len;
  return 0;
}

int pr_win_wic_encode_jpeg_rgb8(
    const uint8_t *rgb24,
    uint32_t width,
    uint32_t height,
    uint8_t **out_bytes,
    size_t *out_len,
    uint32_t *win_error) {
  if (!rgb24 || !out_bytes || !out_len || width == 0 || height == 0) {
    if (win_error) *win_error = E_INVALIDARG;
    return -1;
  }
  *out_bytes = NULL;
  *out_len = 0;

  uint64_t pixel_count64 = (uint64_t)width * (uint64_t)height;
  uint64_t stride64 = (uint64_t)width * 3u;
  uint64_t total64 = pixel_count64 * 3u;
  if (stride64 > UINT32_MAX || total64 > UINT32_MAX) {
    if (win_error) *win_error = E_INVALIDARG;
    return -1;
  }
  uint8_t *bgr = (uint8_t *)malloc((size_t)total64);
  if (!bgr) {
    if (win_error) *win_error = E_OUTOFMEMORY;
    return -1;
  }
  for (uint64_t i = 0; i < pixel_count64; ++i) {
    bgr[i * 3 + 0] = rgb24[i * 3 + 2];
    bgr[i * 3 + 1] = rgb24[i * 3 + 1];
    bgr[i * 3 + 2] = rgb24[i * 3 + 0];
  }

  IWICImagingFactory *factory = NULL;
  int did_coinit = 0;
  if (ensure_wic_factory(&factory, &did_coinit, win_error) != 0) {
    free(bgr);
    return -1;
  }

  IStream *stream = NULL;
  IWICBitmapEncoder *encoder = NULL;
  IWICBitmapFrameEncode *frame = NULL;
  IPropertyBag2 *props = NULL;
  int rc = -1;

  HRESULT hr = CreateStreamOnHGlobal(NULL, TRUE, &stream);
  if (FAILED(hr) || !stream) goto cleanup;

  hr = IWICImagingFactory_CreateEncoder(factory, &GUID_ContainerFormatJpeg, NULL, &encoder);
  if (FAILED(hr) || !encoder) goto cleanup;

  hr = IWICBitmapEncoder_Initialize(encoder, stream, WICBitmapEncoderNoCache);
  if (FAILED(hr)) goto cleanup;

  hr = IWICBitmapEncoder_CreateNewFrame(encoder, &frame, &props);
  if (FAILED(hr) || !frame) goto cleanup;

  if (props) {
    PROPBAG2 option;
    VARIANT var;
    ZeroMemory(&option, sizeof(option));
    option.pstrName = L"ImageQuality";
    VariantInit(&var);
    var.vt = VT_R4;
    var.fltVal = 1.0f;
    (void)IPropertyBag2_Write(props, 1, &option, &var);
  }

  hr = IWICBitmapFrameEncode_Initialize(frame, props);
  if (FAILED(hr)) goto cleanup;

  hr = IWICBitmapFrameEncode_SetSize(frame, width, height);
  if (FAILED(hr)) goto cleanup;

  WICPixelFormatGUID fmt = GUID_WICPixelFormat24bppBGR;
  hr = IWICBitmapFrameEncode_SetPixelFormat(frame, &fmt);
  if (FAILED(hr)) goto cleanup;

  hr = IWICBitmapFrameEncode_WritePixels(frame, height, (UINT)stride64, (UINT)total64, bgr);
  if (FAILED(hr)) goto cleanup;

  hr = IWICBitmapFrameEncode_Commit(frame);
  if (FAILED(hr)) goto cleanup;

  hr = IWICBitmapEncoder_Commit(encoder);
  if (FAILED(hr)) goto cleanup;

  rc = stream_to_malloc(stream, out_bytes, out_len, win_error);

cleanup:
  if (FAILED(hr) && win_error && *win_error == 0) *win_error = (uint32_t)hr;
  if (props) IPropertyBag2_Release(props);
  if (frame) IWICBitmapFrameEncode_Release(frame);
  if (encoder) IWICBitmapEncoder_Release(encoder);
  if (stream) IStream_Release(stream);
  IWICImagingFactory_Release(factory);
  if (did_coinit) CoUninitialize();
  free(bgr);
  return rc;
}

int pr_win_wic_decode_image_rgb8(
    const char *utf8_path,
    uint8_t **out_rgb24,
    uint32_t *out_width,
    uint32_t *out_height,
    uint32_t *win_error) {
  if (!utf8_path || !out_rgb24 || !out_width || !out_height) {
    if (win_error) *win_error = E_INVALIDARG;
    return -1;
  }
  *out_rgb24 = NULL;
  *out_width = 0;
  *out_height = 0;

  wchar_t *wpath = utf8_to_wide_alloc(utf8_path);
  if (!wpath) {
    if (win_error) *win_error = ERROR_PATH_NOT_FOUND;
    return -1;
  }

  IWICImagingFactory *factory = NULL;
  int did_coinit = 0;
  if (ensure_wic_factory(&factory, &did_coinit, win_error) != 0) {
    free(wpath);
    return -1;
  }

  IWICBitmapDecoder *decoder = NULL;
  IWICBitmapFrameDecode *frame = NULL;
  IWICFormatConverter *conv = NULL;
  uint8_t *buf = NULL;
  int rc = -1;

  HRESULT hr = IWICImagingFactory_CreateDecoderFromFilename(
      factory, wpath, NULL, GENERIC_READ, WICDecodeMetadataCacheOnDemand, &decoder);
  if (FAILED(hr) || !decoder) goto cleanup;

  hr = IWICBitmapDecoder_GetFrame(decoder, 0, &frame);
  if (FAILED(hr) || !frame) goto cleanup;

  UINT w = 0, h = 0;
  hr = IWICBitmapFrameDecode_GetSize(frame, &w, &h);
  if (FAILED(hr) || w == 0 || h == 0) goto cleanup;

  hr = IWICImagingFactory_CreateFormatConverter(factory, &conv);
  if (FAILED(hr) || !conv) goto cleanup;

  hr = IWICFormatConverter_Initialize(
      conv, (IWICBitmapSource *)frame, &GUID_WICPixelFormat24bppRGB,
      WICBitmapDitherTypeNone, NULL, 0.0, WICBitmapPaletteTypeCustom);
  if (FAILED(hr)) goto cleanup;

  uint64_t stride64 = (uint64_t)w * 3u;
  uint64_t total64 = stride64 * (uint64_t)h;
  if (stride64 > UINT32_MAX || total64 > UINT32_MAX) {
    hr = E_INVALIDARG;
    goto cleanup;
  }
  buf = (uint8_t *)malloc((size_t)total64);
  if (!buf) { hr = E_OUTOFMEMORY; goto cleanup; }

  hr = IWICFormatConverter_CopyPixels(conv, NULL, (UINT)stride64, (UINT)total64, buf);
  if (FAILED(hr)) { free(buf); buf = NULL; goto cleanup; }

  *out_rgb24 = buf;
  *out_width = w;
  *out_height = h;
  buf = NULL;
  rc = 0;

cleanup:
  if (FAILED(hr) && win_error) *win_error = (uint32_t)hr;
  if (buf) free(buf);
  if (conv) IWICFormatConverter_Release(conv);
  if (frame) IWICBitmapFrameDecode_Release(frame);
  if (decoder) IWICBitmapDecoder_Release(decoder);
  IWICImagingFactory_Release(factory);
  if (did_coinit) CoUninitialize();
  free(wpath);
  return rc;
}

int pr_win_wic_encode_png_rgba16(
    const uint16_t *rgba16,
    uint32_t width,
    uint32_t height,
    const uint8_t *icc_bytes,
    size_t icc_len,
    uint8_t **out_bytes,
    size_t *out_len,
    uint32_t *win_error) {
  if (!rgba16 || !out_bytes || !out_len || width == 0 || height == 0) {
    if (win_error) *win_error = E_INVALIDARG;
    return -1;
  }
  *out_bytes = NULL;
  *out_len = 0;

  uint64_t stride64 = (uint64_t)width * 8u;
  uint64_t total64 = stride64 * (uint64_t)height;
  if (stride64 > UINT32_MAX || total64 > UINT32_MAX) {
    if (win_error) *win_error = E_INVALIDARG;
    return -1;
  }

  IWICImagingFactory *factory = NULL;
  int did_coinit = 0;
  if (ensure_wic_factory(&factory, &did_coinit, win_error) != 0) return -1;

  IStream *stream = NULL;
  IWICBitmapEncoder *encoder = NULL;
  IWICBitmapFrameEncode *frame = NULL;
  IWICColorContext *color_ctx = NULL;
  int rc = -1;

  HRESULT hr = CreateStreamOnHGlobal(NULL, TRUE, &stream);
  if (FAILED(hr) || !stream) goto cleanup;

  hr = IWICImagingFactory_CreateEncoder(factory, &GUID_ContainerFormatPng, NULL, &encoder);
  if (FAILED(hr) || !encoder) goto cleanup;

  hr = IWICBitmapEncoder_Initialize(encoder, stream, WICBitmapEncoderNoCache);
  if (FAILED(hr)) goto cleanup;

  hr = IWICBitmapEncoder_CreateNewFrame(encoder, &frame, NULL);
  if (FAILED(hr) || !frame) goto cleanup;

  hr = IWICBitmapFrameEncode_Initialize(frame, NULL);
  if (FAILED(hr)) goto cleanup;

  hr = IWICBitmapFrameEncode_SetSize(frame, width, height);
  if (FAILED(hr)) goto cleanup;

  WICPixelFormatGUID fmt = GUID_WICPixelFormat64bppRGBA;
  hr = IWICBitmapFrameEncode_SetPixelFormat(frame, &fmt);
  if (FAILED(hr)) goto cleanup;

  if (icc_bytes && icc_len > 0 && icc_len <= UINT32_MAX) {
    if (SUCCEEDED(IWICImagingFactory_CreateColorContext(factory, &color_ctx)) && color_ctx) {
      if (SUCCEEDED(IWICColorContext_InitializeFromMemory(color_ctx, icc_bytes, (UINT)icc_len))) {
        IWICColorContext *contexts[1] = { color_ctx };
        (void)IWICBitmapFrameEncode_SetColorContexts(frame, 1, contexts);
      }
    }
  }

  hr = IWICBitmapFrameEncode_WritePixels(frame, height, (UINT)stride64, (UINT)total64, (BYTE *)rgba16);
  if (FAILED(hr)) goto cleanup;

  hr = IWICBitmapFrameEncode_Commit(frame);
  if (FAILED(hr)) goto cleanup;

  hr = IWICBitmapEncoder_Commit(encoder);
  if (FAILED(hr)) goto cleanup;

  rc = stream_to_malloc(stream, out_bytes, out_len, win_error);

cleanup:
  if (FAILED(hr) && win_error && *win_error == 0) *win_error = (uint32_t)hr;
  if (color_ctx) IWICColorContext_Release(color_ctx);
  if (frame) IWICBitmapFrameEncode_Release(frame);
  if (encoder) IWICBitmapEncoder_Release(encoder);
  if (stream) IStream_Release(stream);
  IWICImagingFactory_Release(factory);
  if (did_coinit) CoUninitialize();
  return rc;
}

int pr_win_wic_decode_png_rgba16(
    const char *utf8_path,
    uint16_t **out_rgba16,
    uint32_t *out_width,
    uint32_t *out_height,
    uint32_t *win_error) {
  if (!utf8_path || !out_rgba16 || !out_width || !out_height) {
    if (win_error) *win_error = E_INVALIDARG;
    return -1;
  }
  *out_rgba16 = NULL;
  *out_width = 0;
  *out_height = 0;

  wchar_t *wpath = utf8_to_wide_alloc(utf8_path);
  if (!wpath) {
    if (win_error) *win_error = ERROR_PATH_NOT_FOUND;
    return -1;
  }

  IWICImagingFactory *factory = NULL;
  int did_coinit = 0;
  if (ensure_wic_factory(&factory, &did_coinit, win_error) != 0) {
    free(wpath);
    return -1;
  }

  IWICBitmapDecoder *decoder = NULL;
  IWICBitmapFrameDecode *frame = NULL;
  IWICFormatConverter *conv = NULL;
  uint16_t *buf = NULL;
  int rc = -1;

  HRESULT hr = IWICImagingFactory_CreateDecoderFromFilename(
      factory, wpath, NULL, GENERIC_READ, WICDecodeMetadataCacheOnDemand, &decoder);
  if (FAILED(hr) || !decoder) goto cleanup;

  hr = IWICBitmapDecoder_GetFrame(decoder, 0, &frame);
  if (FAILED(hr) || !frame) goto cleanup;

  UINT w = 0, h = 0;
  hr = IWICBitmapFrameDecode_GetSize(frame, &w, &h);
  if (FAILED(hr) || w == 0 || h == 0) goto cleanup;

  hr = IWICImagingFactory_CreateFormatConverter(factory, &conv);
  if (FAILED(hr) || !conv) goto cleanup;

  hr = IWICFormatConverter_Initialize(
      conv, (IWICBitmapSource *)frame, &GUID_WICPixelFormat64bppRGBA,
      WICBitmapDitherTypeNone, NULL, 0.0, WICBitmapPaletteTypeCustom);
  if (FAILED(hr)) goto cleanup;

  uint64_t stride64 = (uint64_t)w * 8u;
  uint64_t total64 = stride64 * (uint64_t)h;
  if (stride64 > UINT32_MAX || total64 > UINT32_MAX) { hr = E_INVALIDARG; goto cleanup; }
  buf = (uint16_t *)malloc((size_t)total64);
  if (!buf) { hr = E_OUTOFMEMORY; goto cleanup; }

  hr = IWICFormatConverter_CopyPixels(conv, NULL, (UINT)stride64, (UINT)total64, (BYTE *)buf);
  if (FAILED(hr)) { free(buf); buf = NULL; goto cleanup; }

  *out_rgba16 = buf;
  *out_width = w;
  *out_height = h;
  buf = NULL;
  rc = 0;

cleanup:
  if (FAILED(hr) && win_error) *win_error = (uint32_t)hr;
  if (buf) free(buf);
  if (conv) IWICFormatConverter_Release(conv);
  if (frame) IWICBitmapFrameDecode_Release(frame);
  if (decoder) IWICBitmapDecoder_Release(decoder);
  IWICImagingFactory_Release(factory);
  if (did_coinit) CoUninitialize();
  free(wpath);
  return rc;
}
