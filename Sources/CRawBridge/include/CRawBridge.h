#ifndef PRINTROOM_RAW_BRIDGE_H
#define PRINTROOM_RAW_BRIDGE_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct { int width, height, source_orientation; } PRRawMetadata;
typedef int (*PRRawCancelled)(void *context);
const char *pr_raw_version(void);
int pr_raw_metadata(const char *path, PRRawMetadata *metadata, char *error, size_t capacity);
/* Caller supplies one RGB UInt16 allocation. -2 means cancelled. */
int pr_raw_decode(const char *path, uint16_t *samples, size_t count, PRRawMetadata *metadata,
                  PRRawCancelled cancelled, void *context, char *error, size_t capacity);
#ifdef __cplusplus
}
#endif
#endif
