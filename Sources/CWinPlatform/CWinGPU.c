#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include "CWinPlatform.h"

#include <d3d11.h>
#include <dxgi.h>
#include <d3dcompiler.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *kPrintroomHLSL =
"cbuffer Params : register(b0) {\n"
"  float4 cmosR;\n"
"  float4 cmosG;\n"
"  float4 cmosB;\n"
"  float4 densityR;\n"
"  float4 densityG;\n"
"  float4 densityB;\n"
"  float4 gain;\n"
"  float4 offset;\n"
"  float4 contrast;\n"
"  uint4 meta0; /* count, stage, lutSize, matrix */\n"
"  uint4 meta1; /* cmos, sourceStage, groupsX, pad0 */\n"
"};\n"
"cbuffer WhiteningParams : register(b1) {\n"
"  float4 mapX;\n"
"  float4 mapY;\n"
"  float4 limits;\n"
"  uint4 wmeta; /* width, groupsX, pad0, pad1 */\n"
"};\n"
"StructuredBuffer<float4> srcBuf : register(t0);\n"
"StructuredBuffer<float4> lutBuf : register(t1);\n"
"RWStructuredBuffer<float4> dstBuf : register(u0);\n"
"bool3 isFinite3(float3 v) {\n"
"  uint3 u = asuint(v);\n"
"  return (u & 0x7F800000u) != 0x7F800000u;\n"
"}\n"
"float3 lookupLUT(uint n, float3 p) {\n"
"  float3 q = clamp(p, 0.0f, 1.0f) * float(n - 1u);\n"
"  uint3 a = uint3(floor(q));\n"
"  uint3 b = min(a + 1u, uint3(n - 1u, n - 1u, n - 1u));\n"
"  float3 f = q - float3(a);\n"
"  uint n2 = n * n;\n"
"  float3 c000 = lutBuf[a.x + n * a.y + n2 * a.z].xyz;\n"
"  float3 c100 = lutBuf[b.x + n * a.y + n2 * a.z].xyz;\n"
"  float3 c010 = lutBuf[a.x + n * b.y + n2 * a.z].xyz;\n"
"  float3 c110 = lutBuf[b.x + n * b.y + n2 * a.z].xyz;\n"
"  float3 c001 = lutBuf[a.x + n * a.y + n2 * b.z].xyz;\n"
"  float3 c101 = lutBuf[b.x + n * a.y + n2 * b.z].xyz;\n"
"  float3 c011 = lutBuf[a.x + n * b.y + n2 * b.z].xyz;\n"
"  float3 c111 = lutBuf[b.x + n * b.y + n2 * b.z].xyz;\n"
"  return lerp(\n"
"    lerp(lerp(c000, c100, f.x), lerp(c010, c110, f.x), f.y),\n"
"    lerp(lerp(c001, c101, f.x), lerp(c011, c111, f.x), f.y),\n"
"    f.z);\n"
"}\n"
"[numthreads(256, 1, 1)]\n"
"void printroomPipeline(uint3 groupId : SV_GroupID, uint3 localId : SV_GroupThreadID) {\n"
"  uint i = (groupId.y * meta1.z + groupId.x) * 256u + localId.x;\n"
"  if (i >= meta0.x) return;\n"
"  float3 v = srcBuf[i].xyz;\n"
"  bool valid = all(isFinite3(v));\n"
"  uint stage = meta0.y;\n"
"  uint lutSize = meta0.z;\n"
"  uint matrixOn = meta0.w;\n"
"  uint cmosOn = meta1.x;\n"
"  uint sourceStage = meta1.y;\n"
"  if (sourceStage < 1u && stage >= 1u && cmosOn == 1u) {\n"
"    v = float3(dot(cmosR.xyz, v), dot(cmosG.xyz, v), dot(cmosB.xyz, v));\n"
"  }\n"
"  valid = valid && all(isFinite3(v));\n"
"  if (sourceStage < 2u && stage >= 2u) v *= gain.xyz;\n"
"  valid = valid && all(isFinite3(v));\n"
"  if (sourceStage < 3u && stage >= 3u) {\n"
"    v = -log10(max(v, float3(1e-6f, 1e-6f, 1e-6f))) / 2.048f;\n"
"  }\n"
"  valid = valid && all(isFinite3(v));\n"
"  if (sourceStage < 4u && stage >= 4u && matrixOn == 1u) {\n"
"    v = float3(dot(densityR.xyz, v), dot(densityG.xyz, v), dot(densityB.xyz, v));\n"
"  }\n"
"  valid = valid && all(isFinite3(v));\n"
"  if (sourceStage < 5u && stage >= 5u) v += offset.xyz;\n"
"  valid = valid && all(isFinite3(v));\n"
"  if (sourceStage < 6u && stage >= 6u) {\n"
"    float pivot = 685.0f / 1024.0f;\n" /* contrastPivotCV == 685 in Contracts.swift */
"    v = pivot + contrast.xyz * (v - pivot);\n"
"  }\n"
"  valid = valid && all(isFinite3(v));\n"
"  if (sourceStage < 7u && stage >= 7u) v = lookupLUT(lutSize, v);\n"
"  if (!valid) v = asfloat(0x7fc00000u).xxx;\n"
"  dstBuf[i] = float4(v, 1.0f);\n"
"}\n"
"[numthreads(256, 1, 1)]\n"
"void printroomSprocketWhitening(uint3 groupId : SV_GroupID, uint3 localId : SV_GroupThreadID) {\n"
"  uint i = (groupId.y * wmeta.y + groupId.x) * 256u + localId.x;\n"
"  if (i >= meta0.x) return;\n"
"  uint width = wmeta.x;\n"
"  float x = float(i % width);\n"
"  float y = float(i / width);\n"
"  float cx = mapX.x * x + mapX.y * y + mapX.z;\n"
"  float cy = mapY.x * x + mapY.y * y + mapY.z;\n"
"  float margin = limits.z;\n"
"  if (cx >= -margin && cx <= 1.0f + margin && cy >= -margin && cy <= 1.0f + margin) return;\n"
"  float3 raw = srcBuf[i].xyz;\n"
"  float3 linearRgb = (meta1.x == 1u) ? float3(dot(cmosR.xyz, raw), dot(cmosG.xyz, raw), dot(cmosB.xyz, raw)) : raw;\n"
"  float3 relative = linearRgb * gain.xyz / 0.75f;\n"
"  float brightness = min(relative.x, min(relative.y, relative.z));\n"
"  float t = clamp((brightness - limits.x) / limits.y, 0.0f, 1.0f);\n"
"  float amount = t * t * (3.0f - 2.0f * t);\n"
"  if (amount == 0.0f) return;\n"
"  dstBuf[i] = (amount == 1.0f) ? float4(1.0f, 1.0f, 1.0f, 1.0f) : float4(dstBuf[i].xyz + (1.0f - dstBuf[i].xyz) * amount, 1.0f);\n"
"}\n";

typedef struct {
  ID3D11Buffer *buf;
  ID3D11ShaderResourceView *srv;
  ID3D11UnorderedAccessView *uav;
  ID3D11Buffer *staging;
  size_t elem_count;
  size_t byte_size;
} PRWinGPUBuf;

struct PRWinGPUDevice {
  ID3D11Device *device;
  ID3D11DeviceContext *context;
  ID3D11ComputeShader *cs_pipeline;
  ID3D11ComputeShader *cs_whitening;
  ID3D11Buffer *cb_params;
  ID3D11Buffer *cb_whitening;
  CRITICAL_SECTION ctx_lock;
};

struct PRWinGPUSession {
  PRWinGPUDevice *dev;
  PRWinGPUBuf slots[4]; /* 0=src, 1=dst, 2=d1, 3=lut */
  PRWinGPUSessionStats stats;
};

static void set_win_err(uint32_t *out, HRESULT hr) {
  if (out) *out = (uint32_t)hr;
}

static void release_gpu_buf(PRWinGPUBuf *b) {
  if (b->uav) { ID3D11UnorderedAccessView_Release(b->uav); b->uav = NULL; }
  if (b->srv) { ID3D11ShaderResourceView_Release(b->srv); b->srv = NULL; }
  if (b->staging) { ID3D11Buffer_Release(b->staging); b->staging = NULL; }
  if (b->buf) { ID3D11Buffer_Release(b->buf); b->buf = NULL; }
  b->elem_count = 0;
  b->byte_size = 0;
}

static int ensure_gpu_buf(
    PRWinGPUDevice *dev,
    PRWinGPUSession *sess,
    PRWinGPUBuf *b,
    size_t elem_count,
    int need_uav,
    int need_staging,
    uint32_t *win_error) {
  if (elem_count == 0 || elem_count > UINT32_MAX) {
    set_win_err(win_error, E_INVALIDARG);
    return -2;
  }
  size_t bytes = elem_count * 16;
  if (b->buf && b->elem_count == elem_count &&
      (!need_uav || b->uav != NULL) &&
      (!need_staging || b->staging != NULL)) {
    return 0;
  }
  release_gpu_buf(b);

  D3D11_BUFFER_DESC desc;
  ZeroMemory(&desc, sizeof(desc));
  desc.ByteWidth = (UINT)bytes;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_SHADER_RESOURCE | (need_uav ? D3D11_BIND_UNORDERED_ACCESS : 0);
  desc.MiscFlags = D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;
  desc.StructureByteStride = 16;

  HRESULT hr = ID3D11Device_CreateBuffer(dev->device, &desc, NULL, &b->buf);
  if (FAILED(hr)) { release_gpu_buf(b); set_win_err(win_error, hr); return -1; }

  D3D11_SHADER_RESOURCE_VIEW_DESC srv_desc;
  ZeroMemory(&srv_desc, sizeof(srv_desc));
  srv_desc.Format = DXGI_FORMAT_UNKNOWN;
  srv_desc.ViewDimension = D3D11_SRV_DIMENSION_BUFFEREX;
  srv_desc.BufferEx.FirstElement = 0;
  srv_desc.BufferEx.NumElements = (UINT)elem_count;
  hr = ID3D11Device_CreateShaderResourceView(dev->device, (ID3D11Resource *)b->buf, &srv_desc, &b->srv);
  if (FAILED(hr)) { release_gpu_buf(b); set_win_err(win_error, hr); return -1; }

  if (need_uav) {
    D3D11_UNORDERED_ACCESS_VIEW_DESC uav_desc;
    ZeroMemory(&uav_desc, sizeof(uav_desc));
    uav_desc.Format = DXGI_FORMAT_UNKNOWN;
    uav_desc.ViewDimension = D3D11_UAV_DIMENSION_BUFFER;
    uav_desc.Buffer.FirstElement = 0;
    uav_desc.Buffer.NumElements = (UINT)elem_count;
    hr = ID3D11Device_CreateUnorderedAccessView(dev->device, (ID3D11Resource *)b->buf, &uav_desc, &b->uav);
    if (FAILED(hr)) { release_gpu_buf(b); set_win_err(win_error, hr); return -1; }
  }

  if (need_staging) {
    D3D11_BUFFER_DESC st_desc;
    ZeroMemory(&st_desc, sizeof(st_desc));
    st_desc.ByteWidth = (UINT)bytes;
    st_desc.Usage = D3D11_USAGE_STAGING;
    st_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    hr = ID3D11Device_CreateBuffer(dev->device, &st_desc, NULL, &b->staging);
    if (FAILED(hr)) { release_gpu_buf(b); set_win_err(win_error, hr); return -1; }
  }

  b->elem_count = elem_count;
  b->byte_size = bytes;
  sess->stats.buffer_allocations += 1;
  return 0;
}

static int compile_cs(ID3D11Device *dev, const char *entry, ID3D11ComputeShader **out_cs, uint32_t *win_error) {
  ID3DBlob *code = NULL;
  ID3DBlob *err = NULL;
  UINT flags = D3DCOMPILE_IEEE_STRICTNESS | D3DCOMPILE_OPTIMIZATION_LEVEL3;
  HRESULT hr = D3DCompile(
      kPrintroomHLSL, strlen(kPrintroomHLSL),
      "printroom.hlsl", NULL, NULL,
      entry, "cs_5_0", flags, 0, &code, &err);
  if (FAILED(hr) || !code) {
    if (err) ID3D10Blob_Release(err);
    if (code) ID3D10Blob_Release(code);
    set_win_err(win_error, hr);
    return -1;
  }
  if (err) ID3D10Blob_Release(err);
  hr = ID3D11Device_CreateComputeShader(
      dev, ID3D10Blob_GetBufferPointer(code), ID3D10Blob_GetBufferSize(code), NULL, out_cs);
  ID3D10Blob_Release(code);
  if (FAILED(hr)) {
    set_win_err(win_error, hr);
    return -1;
  }
  return 0;
}

PRWinGPUDevice *pr_win_gpu_create(char *name_utf8, size_t name_cap, uint32_t *win_error) {
  D3D_FEATURE_LEVEL levels[] = { D3D_FEATURE_LEVEL_11_0 };
  D3D_FEATURE_LEVEL achieved = D3D_FEATURE_LEVEL_11_0;
  ID3D11Device *device = NULL;
  ID3D11DeviceContext *context = NULL;

  HRESULT hr = D3D11CreateDevice(
      NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0,
      levels, 1, D3D11_SDK_VERSION, &device, &achieved, &context);
  if (FAILED(hr)) {
    hr = D3D11CreateDevice(
        NULL, D3D_DRIVER_TYPE_WARP, NULL, 0,
        levels, 1, D3D11_SDK_VERSION, &device, &achieved, &context);
    if (FAILED(hr)) {
      set_win_err(win_error, hr);
      return NULL;
    }
  }

  PRWinGPUDevice *dev = (PRWinGPUDevice *)calloc(1, sizeof(PRWinGPUDevice));
  if (!dev) {
    ID3D11DeviceContext_Release(context);
    ID3D11Device_Release(device);
    set_win_err(win_error, E_OUTOFMEMORY);
    return NULL;
  }
  InitializeCriticalSection(&dev->ctx_lock);
  dev->device = device;
  dev->context = context;

  if (compile_cs(device, "printroomPipeline", &dev->cs_pipeline, win_error) != 0 ||
      compile_cs(device, "printroomSprocketWhitening", &dev->cs_whitening, win_error) != 0) {
    pr_win_gpu_destroy(dev);
    return NULL;
  }

  D3D11_BUFFER_DESC cb_desc;
  ZeroMemory(&cb_desc, sizeof(cb_desc));
  cb_desc.Usage = D3D11_USAGE_DEFAULT;
  cb_desc.BindFlags = D3D11_BIND_CONSTANT_BUFFER;

  cb_desc.ByteWidth = sizeof(PRWinGPUParams);
  hr = ID3D11Device_CreateBuffer(device, &cb_desc, NULL, &dev->cb_params);
  if (FAILED(hr)) { set_win_err(win_error, hr); pr_win_gpu_destroy(dev); return NULL; }

  cb_desc.ByteWidth = sizeof(PRWinGPUWhiteningParams);
  hr = ID3D11Device_CreateBuffer(device, &cb_desc, NULL, &dev->cb_whitening);
  if (FAILED(hr)) { set_win_err(win_error, hr); pr_win_gpu_destroy(dev); return NULL; }

  if (name_utf8 && name_cap > 0) {
    snprintf(name_utf8, name_cap, "Direct3D 11 Compute");
    IDXGIDevice *dxgi_dev = NULL;
    if (SUCCEEDED(ID3D11Device_QueryInterface(device, &IID_IDXGIDevice, (void **)&dxgi_dev)) && dxgi_dev) {
      IDXGIAdapter *adapter = NULL;
      if (SUCCEEDED(IDXGIDevice_GetAdapter(dxgi_dev, &adapter)) && adapter) {
        DXGI_ADAPTER_DESC adesc;
        if (SUCCEEDED(IDXGIAdapter_GetDesc(adapter, &adesc))) {
          WideCharToMultiByte(CP_UTF8, 0, adesc.Description, -1, name_utf8, (int)name_cap, NULL, NULL);
        }
        IDXGIAdapter_Release(adapter);
      }
      IDXGIDevice_Release(dxgi_dev);
    }
  }
  return dev;
}

void pr_win_gpu_destroy(PRWinGPUDevice *dev) {
  if (!dev) return;
  if (dev->cb_whitening) ID3D11Buffer_Release(dev->cb_whitening);
  if (dev->cb_params) ID3D11Buffer_Release(dev->cb_params);
  if (dev->cs_whitening) ID3D11ComputeShader_Release(dev->cs_whitening);
  if (dev->cs_pipeline) ID3D11ComputeShader_Release(dev->cs_pipeline);
  if (dev->context) ID3D11DeviceContext_Release(dev->context);
  if (dev->device) ID3D11Device_Release(dev->device);
  DeleteCriticalSection(&dev->ctx_lock);
  free(dev);
}

PRWinGPUSession *pr_win_gpu_session_create(PRWinGPUDevice *device) {
  if (!device) return NULL;
  PRWinGPUSession *s = (PRWinGPUSession *)calloc(1, sizeof(PRWinGPUSession));
  if (!s) return NULL;
  s->dev = device;
  return s;
}

void pr_win_gpu_session_destroy(PRWinGPUSession *s) {
  if (!s) return;
  for (int i = 0; i < 4; ++i) release_gpu_buf(&s->slots[i]);
  free(s);
}

void pr_win_gpu_session_get_stats(PRWinGPUSession *s, PRWinGPUSessionStats *out_stats) {
  if (!s || !out_stats) return;
  *out_stats = s->stats;
  out_stats->retained_pixel_bytes =
      s->slots[0].byte_size + s->slots[1].byte_size + s->slots[2].byte_size;
}

void pr_win_gpu_session_release_pixel_buffers(PRWinGPUSession *s) {
  if (!s) return;
  for (int i = 0; i < 3; ++i) release_gpu_buf(&s->slots[i]);
}

int pr_win_gpu_session_prepare_buffers(
    PRWinGPUSession *s,
    size_t pixel_count,
    const float *source_rgba, int32_t upload_source,
    size_t lut_entry_count,
    const float *lut_rgba, int32_t upload_lut,
    int32_t need_d1,
    uint32_t *win_error) {
  if (!s || !s->dev) return -2;
  int rc = ensure_gpu_buf(s->dev, s, &s->slots[0], pixel_count, 0, 0, win_error);
  if (rc != 0) return rc;
  rc = ensure_gpu_buf(s->dev, s, &s->slots[1], pixel_count, 1, 1, win_error);
  if (rc != 0) return rc;
  if (need_d1) {
    rc = ensure_gpu_buf(s->dev, s, &s->slots[2], pixel_count, 1, 1, win_error);
    if (rc != 0) return rc;
  }
  rc = ensure_gpu_buf(s->dev, s, &s->slots[3], lut_entry_count, 0, 0, win_error);
  if (rc != 0) return rc;

  EnterCriticalSection(&s->dev->ctx_lock);
  if (upload_source && source_rgba) {
    ID3D11DeviceContext_UpdateSubresource(
        s->dev->context, (ID3D11Resource *)s->slots[0].buf, 0, NULL, source_rgba, 0, 0);
    s->stats.source_uploads += 1;
  }
  if (upload_lut && lut_rgba) {
    ID3D11DeviceContext_UpdateSubresource(
        s->dev->context, (ID3D11Resource *)s->slots[3].buf, 0, NULL, lut_rgba, 0, 0);
    s->stats.lut_uploads += 1;
  }
  LeaveCriticalSection(&s->dev->ctx_lock);
  return 0;
}

static void calc_dispatch(uint32_t count, UINT *gx, UINT *gy) {
  uint32_t groups = (count + 255u) / 256u;
  if (groups == 0u) groups = 1u;
  *gx = groups <= 65535u ? (UINT)groups : 65535u;
  *gy = (UINT)((groups + *gx - 1u) / *gx);
}

int pr_win_gpu_session_dispatch_pipeline(
    PRWinGPUSession *s,
    int32_t src_slot,
    int32_t dst_slot,
    const PRWinGPUParams *params,
    uint32_t *win_error) {
  if (!s || !s->dev || !params || src_slot < 0 || src_slot > 2 || dst_slot < 1 || dst_slot > 2) {
    set_win_err(win_error, E_INVALIDARG);
    return -2;
  }
  if (!s->slots[src_slot].srv || !s->slots[dst_slot].uav || !s->slots[3].srv) {
    set_win_err(win_error, E_INVALIDARG);
    return -2;
  }

  PRWinGPUParams local = *params;
  UINT gx = 1, gy = 1;
  calc_dispatch(local.count, &gx, &gy);
  local.groupsX = (uint32_t)gx;

  PRWinGPUDevice *dev = s->dev;
  EnterCriticalSection(&dev->ctx_lock);
  ID3D11DeviceContext_UpdateSubresource(dev->context, (ID3D11Resource *)dev->cb_params, 0, NULL, &local, 0, 0);

  ID3D11ShaderResourceView *srvs[2] = { s->slots[src_slot].srv, s->slots[3].srv };
  ID3D11UnorderedAccessView *uavs[1] = { s->slots[dst_slot].uav };
  ID3D11Buffer *cbs[1] = { dev->cb_params };

  ID3D11DeviceContext_CSSetShader(dev->context, dev->cs_pipeline, NULL, 0);
  ID3D11DeviceContext_CSSetConstantBuffers(dev->context, 0, 1, cbs);
  ID3D11DeviceContext_CSSetShaderResources(dev->context, 0, 2, srvs);
  ID3D11DeviceContext_CSSetUnorderedAccessViews(dev->context, 0, 1, uavs, NULL);
  ID3D11DeviceContext_Dispatch(dev->context, gx, gy, 1);

  ID3D11ShaderResourceView *null_srvs[2] = { NULL, NULL };
  ID3D11UnorderedAccessView *null_uavs[1] = { NULL };
  ID3D11DeviceContext_CSSetShaderResources(dev->context, 0, 2, null_srvs);
  ID3D11DeviceContext_CSSetUnorderedAccessViews(dev->context, 0, 1, null_uavs, NULL);

  if (dst_slot == 2) s->stats.density_passes += 1;
  LeaveCriticalSection(&dev->ctx_lock);
  return 0;
}

int pr_win_gpu_session_dispatch_whitening(
    PRWinGPUSession *s,
    const PRWinGPUParams *params,
    const PRWinGPUWhiteningParams *whitening,
    uint32_t *win_error) {
  if (!s || !s->dev || !params || !whitening || !s->slots[0].srv || !s->slots[1].uav) {
    set_win_err(win_error, E_INVALIDARG);
    return -2;
  }
  PRWinGPUParams lp = *params;
  PRWinGPUWhiteningParams lw = *whitening;
  UINT gx = 1, gy = 1;
  calc_dispatch(lp.count, &gx, &gy);
  lp.groupsX = (uint32_t)gx;
  lw.groupsX = (uint32_t)gx;

  PRWinGPUDevice *dev = s->dev;
  EnterCriticalSection(&dev->ctx_lock);
  ID3D11DeviceContext_UpdateSubresource(dev->context, (ID3D11Resource *)dev->cb_params, 0, NULL, &lp, 0, 0);
  ID3D11DeviceContext_UpdateSubresource(dev->context, (ID3D11Resource *)dev->cb_whitening, 0, NULL, &lw, 0, 0);

  ID3D11ShaderResourceView *srvs[1] = { s->slots[0].srv };
  ID3D11UnorderedAccessView *uavs[1] = { s->slots[1].uav };
  ID3D11Buffer *cbs[2] = { dev->cb_params, dev->cb_whitening };

  ID3D11DeviceContext_CSSetShader(dev->context, dev->cs_whitening, NULL, 0);
  ID3D11DeviceContext_CSSetConstantBuffers(dev->context, 0, 2, cbs);
  ID3D11DeviceContext_CSSetShaderResources(dev->context, 0, 1, srvs);
  ID3D11DeviceContext_CSSetUnorderedAccessViews(dev->context, 0, 1, uavs, NULL);
  ID3D11DeviceContext_Dispatch(dev->context, gx, gy, 1);

  ID3D11ShaderResourceView *null_srvs[1] = { NULL };
  ID3D11UnorderedAccessView *null_uavs[1] = { NULL };
  ID3D11DeviceContext_CSSetShaderResources(dev->context, 0, 1, null_srvs);
  ID3D11DeviceContext_CSSetUnorderedAccessViews(dev->context, 0, 1, null_uavs, NULL);
  LeaveCriticalSection(&dev->ctx_lock);
  return 0;
}

int pr_win_gpu_session_readback(
    PRWinGPUSession *s,
    int32_t slot,
    float *out_rgba,
    size_t pixel_count,
    uint32_t *win_error) {
  if (!s || !s->dev || !out_rgba || slot < 1 || slot > 2) {
    set_win_err(win_error, E_INVALIDARG);
    return -2;
  }
  PRWinGPUBuf *b = &s->slots[slot];
  if (!b->buf || !b->staging || b->elem_count != pixel_count) {
    set_win_err(win_error, E_INVALIDARG);
    return -2;
  }

  PRWinGPUDevice *dev = s->dev;
  EnterCriticalSection(&dev->ctx_lock);
  ID3D11DeviceContext_CopyResource(dev->context, (ID3D11Resource *)b->staging, (ID3D11Resource *)b->buf);
  D3D11_MAPPED_SUBRESOURCE mapped;
  ZeroMemory(&mapped, sizeof(mapped));
  HRESULT hr = ID3D11DeviceContext_Map(dev->context, (ID3D11Resource *)b->staging, 0, D3D11_MAP_READ, 0, &mapped);
  if (SUCCEEDED(hr)) {
    memcpy(out_rgba, mapped.pData, pixel_count * 16);
    ID3D11DeviceContext_Unmap(dev->context, (ID3D11Resource *)b->staging, 0);
  }
  LeaveCriticalSection(&dev->ctx_lock);
  if (FAILED(hr)) {
    set_win_err(win_error, hr);
    return -1;
  }
  return 0;
}
