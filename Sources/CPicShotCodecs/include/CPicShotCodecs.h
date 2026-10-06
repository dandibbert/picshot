#ifndef PICSHOT_CODECS_H
#define PICSHOT_CODECS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Original PicShot ABI. No upstream structure layout is exposed here. */
enum {
    PS_CODEC_ABI_VERSION = 1,
    PS_CODEC_WEBP = 1,
    PS_CODEC_AVIF = 2,
    PS_CODEC_OK = 0,
    PS_CODEC_END = 1,
    PS_CODEC_INVALID = -1,
    PS_CODEC_LIMIT = -2,
    PS_CODEC_MEMORY = -3,
    PS_CODEC_ENCODE = -4,
    PS_CODEC_DECODE = -5,
    PS_CODEC_CANCELLED = -6,
    PS_CODEC_WRITE = -7
};

typedef struct {
    uint32_t abiVersion;
    uint32_t format;
    uint32_t quality;          /* 0..100; ignored for lossless color */
    uint32_t lossless;         /* 0 or 1; preserves RGBA exactly */
    uint32_t preserveAlpha;    /* 0 or 1; 0 discards alpha, no compositing */
    uint32_t alphaQuality;     /* 0..100; lossless forces 100 */
    uint32_t effort;           /* 0..6; larger is slower */
    uint32_t maxThreads;       /* 1..4 */
    uint64_t maxOutputBytes;   /* 1..128 MiB, enforced before each write */
} PSCodecOptions;

typedef struct {
    int32_t code;
    char message[256];
} PSCodecError;

/* Synchronous callbacks on the calling thread. Bytes are borrowed for this call.
 * Return 1 to continue, 0 to abort. cumulativeBytes includes this write.
 * Callers must discard partial output unless the encode returns PS_CODEC_OK.
 * Progress is nondecreasing 0..100; 100 is offered after all output writes.
 * The encode return code is still authoritative if that callback aborts. AVIF progress is
 * coarse because its encode call is not interruptible and buffers its output. */
typedef int32_t (*PSCodecWriter)(const uint8_t *bytes, uint64_t count,
                               uint64_t cumulativeBytes, void *context);
typedef int32_t (*PSCodecProgress)(uint32_t percent, uint64_t cumulativeBytes,
                                 void *context);

PSCodecOptions PSCodecDefaultOptions(uint32_t format);
const char *PSCodecVersion(uint32_t format); /* Static string; do not free. */
const char *PSCodecAOMVersion(void);         /* Static string; do not free. */
const char *PSCodecErrorMessage(const PSCodecError *error);

/* Input is top-to-bottom, unpremultiplied RGBA8 in sRGB, with positive stride.
 * Width/height <=16383, <=100M pixels, stride <=INT32_MAX. pixelBytes must cover
 * (height-1)*stride + width*4. Input and context remain owned by caller.
 * No metadata, orientation, source layers or ICC payload are accepted. */
int32_t PSCodecEncodeRGBA(const uint8_t *pixels, uint64_t pixelBytes,
                         uint32_t width, uint32_t height, uint64_t stride,
                         const PSCodecOptions *options, PSCodecWriter writer,
                         PSCodecProgress progress, void *context,
                         PSCodecError *error);

/* Still decoding rejects animated containers. Explicit caps are required and
 * checked before RGBA allocation. Hard caps: 128 MiB input, 100M pixels, 400M
 * output bytes. RGBA is tightly packed, straight alpha. Codec scratch memory
 * is additional to the output limit. NULL result signals error. */
typedef struct PSCodecDecoded PSCodecDecoded;
PSCodecDecoded *PSCodecDecodeRGBA(uint32_t format, const uint8_t *bytes,
                                uint64_t count, uint64_t maxPixels,
                                uint64_t maxDecodedBytes, PSCodecError *error);
uint32_t PSCodecDecodedWidth(const PSCodecDecoded *decoded);
uint32_t PSCodecDecodedHeight(const PSCodecDecoded *decoded);
uint64_t PSCodecDecodedStride(const PSCodecDecoded *decoded);
uint64_t PSCodecDecodedByteCount(const PSCodecDecoded *decoded);
const uint8_t *PSCodecDecodedPixels(const PSCodecDecoded *decoded);
void PSCodecDecodedFree(PSCodecDecoded *decoded);

/* Full WebP demux and sequential composited-frame decoding. Opening verifies
 * all frame rectangles/timing and frame count, and copies the encoded input.
 * Limits apply to the canvas and each decoded frame, not total animation bytes.
 * No frame is silently replaced with the first frame. The RGBA pointer returned
 * by Next is borrowed until the next Next call or Free. Times are exact integer
 * milliseconds from the container; zero-duration frames remain zero-duration.
 * Codec-owned compositing buffers are additional to maxDecodedBytes. */
typedef struct PSCodecAnimation PSCodecAnimation;
PSCodecAnimation *PSCodecWebPAnimationOpen(const uint8_t *bytes, uint64_t count,
                                         uint64_t maxPixels, uint32_t maxFrames,
                                         uint64_t maxDecodedBytes,
                                         PSCodecError *error);
uint32_t PSCodecAnimationWidth(const PSCodecAnimation *animation);
uint32_t PSCodecAnimationHeight(const PSCodecAnimation *animation);
uint32_t PSCodecAnimationFrameCount(const PSCodecAnimation *animation);
uint32_t PSCodecAnimationLoopCount(const PSCodecAnimation *animation);
uint64_t PSCodecAnimationDurationMS(const PSCodecAnimation *animation);
int32_t PSCodecAnimationNext(PSCodecAnimation *animation, const uint8_t **rgba,
                             uint64_t *byteCount, uint32_t *durationMS,
                             PSCodecError *error);
void PSCodecAnimationFree(PSCodecAnimation *animation);

#ifdef __cplusplus
}
#endif
#endif
