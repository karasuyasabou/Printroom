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

#ifdef __cplusplus
}
#endif

#endif
