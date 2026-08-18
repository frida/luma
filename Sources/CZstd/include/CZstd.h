#ifndef CZSTD_H
#define CZSTD_H

#include <stddef.h>

/* Zstandard's decompression entry points, as the single-file decoder defines
 * them. A kernel's payload does not declare how large it unpacks to, so it is
 * taken a buffer at a time. */

typedef struct ZSTD_DCtx_s ZSTD_DStream;

typedef struct {
    const void *src;
    size_t size;
    size_t pos;
} ZSTD_inBuffer;

typedef struct {
    void *dst;
    size_t size;
    size_t pos;
} ZSTD_outBuffer;

ZSTD_DStream *ZSTD_createDStream(void);
size_t ZSTD_freeDStream(ZSTD_DStream *stream);
size_t ZSTD_initDStream(ZSTD_DStream *stream);
size_t ZSTD_decompressStream(ZSTD_DStream *stream, ZSTD_outBuffer *output, ZSTD_inBuffer *input);
size_t ZSTD_DStreamOutSize(void);
unsigned ZSTD_isError(size_t code);

#endif
