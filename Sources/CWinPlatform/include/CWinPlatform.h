#ifndef CWINPLATFORM_H
#define CWINPLATFORM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  int64_t size;
  int64_t mtime_sec;
  int64_t mtime_nsec;
  uint64_t file_id;
  int32_t is_regular;
  int32_t is_directory;
  int32_t is_reparse;
} PRWinFileStat;

int pr_win_lstat(const char *utf8_path, PRWinFileStat *out_stat, uint32_t *win_error);
int pr_win_path_exists_nofollow(const char *utf8_path, uint32_t *win_error);

intptr_t pr_win_open_read(const char *utf8_path, uint32_t *win_error);
int64_t pr_win_pread(intptr_t handle, uint64_t offset, void *buffer, size_t count, uint32_t *win_error);

intptr_t pr_win_open_temp_excl(const char *utf8_path, uint32_t *win_error);
int pr_win_write_all(intptr_t handle, const void *buffer, size_t count, uint32_t *win_error);
int pr_win_pwrite_all(intptr_t handle, uint64_t offset, const void *buffer, size_t count, uint32_t *win_error);
int pr_win_flush_close(intptr_t handle, uint32_t *win_error);
void pr_win_close(intptr_t handle);

int pr_win_move_excl(const char *src_utf8, const char *dst_utf8, uint32_t *win_error);
int pr_win_move_replace(const char *src_utf8, const char *dst_utf8, uint32_t *win_error);

intptr_t pr_win_lock_open(const char *utf8_path, uint32_t *win_error);
int pr_win_lock_try(intptr_t handle, int exclusive, uint32_t *win_error);
void pr_win_lock_close(intptr_t handle);

void pr_win_format_error(uint32_t win_error, char *buffer, size_t capacity);

int pr_win_get_file_dates(
    const char *utf8_path,
    int32_t *has_creation, int64_t *creation_sec, int64_t *creation_nsec,
    int32_t *has_mod, int64_t *mod_sec, int64_t *mod_nsec,
    uint32_t *win_error);

int pr_win_set_file_dates(
    const char *utf8_path,
    int32_t has_creation, int64_t creation_sec, int64_t creation_nsec,
    int32_t has_mod, int64_t mod_sec, int64_t mod_nsec,
    uint32_t *win_error);

/* Direct3D 11 Compute GPU Pipeline */
typedef struct PRWinGPUDevice PRWinGPUDevice;
typedef struct PRWinGPUSession PRWinGPUSession;

typedef struct {
  float cmosR[4], cmosG[4], cmosB[4];
  float densityR[4], densityG[4], densityB[4];
  float gain[4], offset[4], contrast[4];
  uint32_t count, stage, lutSize, matrix;
  uint32_t cmos, sourceStage, groupsX, pad0;
} PRWinGPUParams;

typedef struct {
  float mapX[4], mapY[4], limits[4];
  uint32_t width, groupsX, pad0, pad1;
} PRWinGPUWhiteningParams;

typedef struct {
  uint64_t buffer_allocations;
  uint64_t source_uploads;
  uint64_t lut_uploads;
  uint64_t density_passes;
  uint64_t density_cache_hits;
  uint64_t retained_pixel_bytes;
} PRWinGPUSessionStats;

PRWinGPUDevice *pr_win_gpu_create(char *name_utf8, size_t name_cap, uint32_t *win_error);
void pr_win_gpu_destroy(PRWinGPUDevice *device);

PRWinGPUSession *pr_win_gpu_session_create(PRWinGPUDevice *device);
void pr_win_gpu_session_destroy(PRWinGPUSession *session);
void pr_win_gpu_session_get_stats(PRWinGPUSession *session, PRWinGPUSessionStats *out_stats);
void pr_win_gpu_session_release_pixel_buffers(PRWinGPUSession *session);

/* Returns 0 on success, -1 on DX/allocation failure, -2 on invalid argument */
int pr_win_gpu_session_prepare_buffers(
    PRWinGPUSession *session,
    size_t pixel_count,
    const float *source_rgba, int32_t upload_source,
    size_t lut_entry_count,
    const float *lut_rgba, int32_t upload_lut,
    int32_t need_d1,
    uint32_t *win_error);

int pr_win_gpu_session_dispatch_pipeline(
    PRWinGPUSession *session,
    int32_t src_slot, /* 0=src, 2=d1 */
    int32_t dst_slot, /* 1=dst, 2=d1 */
    const PRWinGPUParams *params,
    uint32_t *win_error);

int pr_win_gpu_session_dispatch_whitening(
    PRWinGPUSession *session,
    const PRWinGPUParams *params,
    const PRWinGPUWhiteningParams *whitening,
    uint32_t *win_error);

int pr_win_gpu_session_readback(
    PRWinGPUSession *session,
    int32_t slot, /* 1=dst, 2=d1 */
    float *out_rgba,
    size_t pixel_count,
    uint32_t *win_error);

/* WIC JPEG/PNG encoding & decoding */
void pr_win_free_buffer(void *ptr);

int pr_win_wic_encode_jpeg_rgb8(
    const uint8_t *rgb24,
    uint32_t width,
    uint32_t height,
    uint8_t **out_bytes,
    size_t *out_len,
    uint32_t *win_error);

int pr_win_wic_decode_image_rgb8(
    const char *utf8_path,
    uint8_t **out_rgb24,
    uint32_t *out_width,
    uint32_t *out_height,
    uint32_t *win_error);

int pr_win_wic_encode_png_rgba16(
    const uint16_t *rgba16,
    uint32_t width,
    uint32_t height,
    const uint8_t *icc_bytes,
    size_t icc_len,
    uint8_t **out_bytes,
    size_t *out_len,
    uint32_t *win_error);

int pr_win_wic_decode_png_rgba16(
    const char *utf8_path,
    uint16_t **out_rgba16,
    uint32_t *out_width,
    uint32_t *out_height,
    uint32_t *win_error);

/* Hidden Win32 Process Runner & Adobe DNG Converter Discovery */
typedef int (*PRWinCancelCallback)(void *ctx);

int pr_win_find_adobe_dng_converter(
    char *out_path_utf8, size_t path_cap,
    char *out_version_utf8, size_t ver_cap);

int pr_win_get_file_version_string(
    const char *utf8_path,
    char *out_version_utf8, size_t ver_cap);

/* args_packed: double-null-terminated or newline-separated UTF-8 args */
int pr_win_run_hidden_process(
    const char *exe_utf8,
    const char *const *args_utf8,
    size_t arg_count,
    const char *log_path_utf8,
    uint32_t timeout_ms,
    PRWinCancelCallback cancel_cb,
    void *cancel_ctx,
    int32_t *out_exit_code,
    uint32_t *win_error);

/* Monitor ICC & WCS/ICM Color Management */
typedef struct PRWinColorTransform PRWinColorTransform;

int pr_win_get_monitor_icc_path(intptr_t hwnd, char *out_utf8, size_t cap);

PRWinColorTransform *pr_win_color_transform_create(
    const uint8_t *src_icc_bytes, size_t src_icc_len,
    const char *dst_icc_path_utf8,
    uint32_t *win_error);

void pr_win_color_transform_destroy(PRWinColorTransform *transform);

int pr_win_color_transform_apply_bgra8(
    PRWinColorTransform *transform,
    const uint16_t *rgb16_in,
    uint8_t *bgra8_out,
    uint32_t width,
    uint32_t height,
    uint32_t *win_error);

#ifdef __cplusplus
}
#endif

#endif
