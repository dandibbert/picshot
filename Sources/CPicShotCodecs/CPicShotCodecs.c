#include "CPicShotCodecs.h"

#include <limits.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <webp/decode.h>
#include <webp/demux.h>
#include <webp/encode.h>
#include <avif/avif.h>
#include <aom/aom_codec.h>

#define PS_MAX_PIXELS UINT64_C(100000000)
#define PS_MAX_BYTES (UINT64_C(128) * 1024 * 1024)
#define PS_MAX_DECODED (PS_MAX_PIXELS * 4)
#define PS_MAX_DIMENSION 16383U
#define PS_MAX_FRAMES 10000U

struct PSCodecDecoded {
    uint32_t width, height;
    uint8_t *pixels;
};
struct PSCodecAnimation {
    uint8_t *input;
    WebPAnimDecoder *decoder;
    uint32_t width, height, frameCount, loopCount, nextIndex;
    uint64_t totalDuration;
    int previousTimestamp;
};
typedef struct {
    const PSCodecOptions *options;
    PSCodecWriter writer;
    PSCodecProgress progress;
    void *context;
    uint64_t written;
    uint32_t lastProgress;
    int32_t status;
} PSWriteContext;

static int32_t fail(PSCodecError *error, int32_t code, const char *message) {
    if (error) {
        error->code = code;
        snprintf(error->message, sizeof(error->message), "%s", message ? message : "Codec error");
    }
    return code;
}
static void clearError(PSCodecError *error) {
    if (error) memset(error, 0, sizeof(*error));
}
static int validDimensions(uint32_t width, uint32_t height, uint64_t maxPixels,
                           uint64_t maxBytes) {
    const uint64_t pixels = (uint64_t)width * height;
    return width && height && width <= PS_MAX_DIMENSION && height <= PS_MAX_DIMENSION &&
           maxPixels && maxPixels <= PS_MAX_PIXELS && maxBytes && maxBytes <= PS_MAX_DECODED &&
           pixels <= maxPixels && pixels * 4 <= maxBytes && pixels * 4 <= SIZE_MAX;
}
static int notifyProgress(PSWriteContext *state, uint32_t percent) {
    if (state->status) return 0;
    if (percent < state->lastProgress) percent = state->lastProgress;
    state->lastProgress = percent;
    if (state->progress && !state->progress(percent, state->written, state->context)) {
        state->status = PS_CODEC_CANCELLED;
        return 0;
    }
    return 1;
}
static int writeBytes(PSWriteContext *state, const uint8_t *bytes, size_t size) {
    if (state->status) return 0;
    if ((uint64_t)size > state->options->maxOutputBytes - state->written) {
        state->status = PS_CODEC_LIMIT;
        return 0;
    }
    if (!notifyProgress(state, state->lastProgress)) return 0;
    if (size && !state->writer(bytes, (uint64_t)size, state->written + size, state->context)) {
        state->status = PS_CODEC_WRITE;
        return 0;
    }
    state->written += size;
    return 1;
}
static int webpWrite(const uint8_t *bytes, size_t size, const WebPPicture *picture) {
    return writeBytes((PSWriteContext *)picture->custom_ptr, bytes, size);
}
static int webpProgress(int percent, const WebPPicture *picture) {
    return notifyProgress((PSWriteContext *)picture->custom_ptr,
                          (uint32_t)(percent < 0 ? 0 : percent > 99 ? 99 : percent));
}

PSCodecOptions PSCodecDefaultOptions(uint32_t format) {
    PSCodecOptions options = { PS_CODEC_ABI_VERSION, format, 85, 0, 1, 100, 4, 2, PS_MAX_BYTES };
    return options;
}
const char *PSCodecVersion(uint32_t format) {
    /* The bridge is built only with the pinned 1.6.0 WebP. Check at runtime. */
    if (format == PS_CODEC_WEBP)
        return WebPGetEncoderVersion() == 0x010600 && WebPGetDecoderVersion() == 0x010600 ? "1.6.0" : "unexpected-webp-version";
    if (format == PS_CODEC_AVIF) return avifVersion();
    return "unsupported";
}
const char *PSCodecAOMVersion(void) { return aom_codec_version_str(); }
const char *PSCodecErrorMessage(const PSCodecError *error) { return error ? error->message : ""; }

static int encodeWebP(const uint8_t *pixels, uint32_t width, uint32_t height,
                      uint64_t stride, PSWriteContext *state, PSCodecError *error) {
    WebPConfig config;
    WebPPicture picture;
    if (!WebPConfigInit(&config) || !WebPPictureInit(&picture))
        return fail(error, PS_CODEC_ENCODE, "WebP ABI mismatch");
    config.lossless = (int)state->options->lossless;
    config.quality = (float)state->options->quality;
    config.alpha_quality = (int)(config.lossless ? 100 : state->options->alphaQuality);
    config.method = (int)state->options->effort;
    config.exact = 1;
    config.thread_level = state->options->maxThreads > 1;
    if (!WebPValidateConfig(&config)) return fail(error, PS_CODEC_INVALID, "Invalid WebP options");
    picture.use_argb = 1;
    picture.width = (int)width;
    picture.height = (int)height;
    picture.writer = webpWrite;
    picture.progress_hook = webpProgress;
    picture.custom_ptr = state;
    if (!WebPPictureImportRGBA(&picture, pixels, (int)stride)) {
        WebPPictureFree(&picture);
        return fail(error, PS_CODEC_MEMORY, "WebP input allocation failed");
    }
    if (!state->options->preserveAlpha) {
        for (uint32_t y = 0; y < height; ++y)
            for (uint32_t x = 0; x < width; ++x)
                picture.argb[(size_t)y * picture.argb_stride + x] |= UINT32_C(0xff000000);
    }
    const int result = WebPEncode(&config, &picture);
    const int nativeError = picture.error_code;
    WebPPictureFree(&picture);
    if (!result) {
        if (state->status) return state->status;
        char message[128];
        snprintf(message, sizeof(message), "WebP encode failed (%d)", nativeError);
        return fail(error, PS_CODEC_ENCODE, message);
    }
    return PS_CODEC_OK;
}

static int encodeAVIF(const uint8_t *pixels, uint32_t width, uint32_t height,
                      uint64_t stride, PSWriteContext *state, PSCodecError *error) {
    avifImage *image = avifImageCreate(width, height, 8, AVIF_PIXEL_FORMAT_YUV444);
    avifEncoder *encoder = avifEncoderCreate();
    avifRWData output = AVIF_DATA_EMPTY;
    if (!image || !encoder) {
        if (image) avifImageDestroy(image);
        if (encoder) avifEncoderDestroy(encoder);
        return fail(error, PS_CODEC_MEMORY, "AVIF allocation failed");
    }
    image->colorPrimaries = AVIF_COLOR_PRIMARIES_BT709;
    image->transferCharacteristics = AVIF_TRANSFER_CHARACTERISTICS_SRGB;
    image->matrixCoefficients = state->options->lossless ? AVIF_MATRIX_COEFFICIENTS_IDENTITY : AVIF_MATRIX_COEFFICIENTS_BT709;
    image->yuvRange = AVIF_RANGE_FULL;
    image->alphaPremultiplied = AVIF_FALSE;
    avifRGBImage rgb;
    avifRGBImageSetDefaults(&rgb, image);
    rgb.format = AVIF_RGB_FORMAT_RGBA;
    rgb.depth = 8;
    rgb.pixels = (uint8_t *)pixels;
    rgb.rowBytes = (uint32_t)stride;
    rgb.ignoreAlpha = !state->options->preserveAlpha;
    rgb.alphaPremultiplied = AVIF_FALSE;
    encoder->codecChoice = AVIF_CODEC_CHOICE_AOM;
    encoder->maxThreads = (int)state->options->maxThreads;
    encoder->speed = 10 - (int)state->options->effort;
    encoder->quality = state->options->lossless ? AVIF_QUALITY_LOSSLESS : (int)state->options->quality;
    encoder->qualityAlpha = state->options->lossless ? AVIF_QUALITY_LOSSLESS : (int)state->options->alphaQuality;
    avifResult result = avifImageRGBToYUV(image, &rgb);
    if (result == AVIF_RESULT_OK && notifyProgress(state, 10)) {
        /* libavif/libaom perform a synchronous allocation-backed encode here.
         * No streaming or preemptible-cancellation claim is made for this call. */
        result = avifEncoderWrite(encoder, image, &output);
    }
    int32_t status = state->status;
    if (!status && result != AVIF_RESULT_OK)
        status = fail(error, PS_CODEC_ENCODE, avifResultToString(result));
    if (!status && !notifyProgress(state, 90)) status = state->status;
    if (!status && (uint64_t)output.size > state->options->maxOutputBytes)
        status = fail(error, PS_CODEC_LIMIT, "AVIF output exceeds byte limit");
    for (size_t offset = 0; !status && offset < output.size;) {
        const size_t count = output.size - offset > 65536 ? 65536 : output.size - offset;
        if (!writeBytes(state, output.data + offset, count)) status = state->status;
        offset += count;
    }
    avifRWDataFree(&output);
    avifEncoderDestroy(encoder);
    avifImageDestroy(image);
    return status;
}

int32_t PSCodecEncodeRGBA(const uint8_t *pixels, uint64_t pixelBytes,
                         uint32_t width, uint32_t height, uint64_t stride,
                         const PSCodecOptions *options, PSCodecWriter writer,
                         PSCodecProgress progress, void *context, PSCodecError *error) {
    clearError(error);
    if (!pixels || !options || !writer || options->abiVersion != PS_CODEC_ABI_VERSION ||
        (options->format != PS_CODEC_WEBP && options->format != PS_CODEC_AVIF) ||
        options->quality > 100 || options->alphaQuality > 100 || options->lossless > 1 ||
        options->preserveAlpha > 1 || options->effort > 6 || options->maxThreads < 1 ||
        options->maxThreads > 4 || !options->maxOutputBytes || options->maxOutputBytes > PS_MAX_BYTES)
        return fail(error, PS_CODEC_INVALID, "Invalid codec input/options");
    if (!validDimensions(width, height, PS_MAX_PIXELS, PS_MAX_DECODED) ||
        stride < (uint64_t)width * 4 || stride > INT32_MAX ||
        pixelBytes < (uint64_t)(height - 1) * stride + (uint64_t)width * 4 || pixelBytes > SIZE_MAX)
        return fail(error, PS_CODEC_LIMIT, "RGBA dimensions, stride or buffer exceed limits");
    PSWriteContext state = { options, writer, progress, context, 0, 0, 0 };
    if (!notifyProgress(&state, 0)) return fail(error, state.status, "Encoding cancelled");
    int32_t status = options->format == PS_CODEC_WEBP ?
        encodeWebP(pixels, width, height, stride, &state, error) :
        encodeAVIF(pixels, width, height, stride, &state, error);
    if (!status && !state.written) status = fail(error, PS_CODEC_ENCODE, "Codec produced no bytes");
    if (!status && !notifyProgress(&state, 100)) status = state.status;
    if (status && (!error || !error->code)) {
        fail(error, status, status == PS_CODEC_CANCELLED ? "Encoding cancelled" :
             status == PS_CODEC_LIMIT ? "Encoded output exceeds byte limit" :
             status == PS_CODEC_WRITE ? "Output writer aborted" : "Encoding failed");
    }
    return status;
}

static PSCodecDecoded *allocateDecoded(uint32_t width, uint32_t height,
                                       uint64_t maxPixels, uint64_t maxBytes,
                                       PSCodecError *error) {
    if (!validDimensions(width, height, maxPixels, maxBytes)) {
        fail(error, PS_CODEC_LIMIT, "Decoded dimensions exceed limits");
        return NULL;
    }
    PSCodecDecoded *decoded = calloc(1, sizeof(*decoded));
    if (decoded) decoded->pixels = malloc((size_t)width * height * 4);
    if (!decoded || !decoded->pixels) {
        free(decoded);
        fail(error, PS_CODEC_MEMORY, "Decoded RGBA allocation failed");
        return NULL;
    }
    decoded->width = width;
    decoded->height = height;
    return decoded;
}
PSCodecDecoded *PSCodecDecodeRGBA(uint32_t format, const uint8_t *bytes,
                                uint64_t count, uint64_t maxPixels,
                                uint64_t maxDecodedBytes, PSCodecError *error) {
    clearError(error);
    if (!bytes || !count || count > PS_MAX_BYTES || count > SIZE_MAX ||
        !maxPixels || maxPixels > PS_MAX_PIXELS || !maxDecodedBytes || maxDecodedBytes > PS_MAX_DECODED) {
        fail(error, PS_CODEC_LIMIT, "Invalid compressed input or decode limits");
        return NULL;
    }
    PSCodecDecoded *decoded = NULL;
    if (format == PS_CODEC_WEBP) {
        WebPBitstreamFeatures features;
        if (WebPGetFeatures(bytes, (size_t)count, &features) != VP8_STATUS_OK || features.has_animation) {
            fail(error, PS_CODEC_DECODE, "Expected a complete still WebP image");
            return NULL;
        }
        decoded = allocateDecoded((uint32_t)features.width, (uint32_t)features.height, maxPixels, maxDecodedBytes, error);
        if (decoded && !WebPDecodeRGBAInto(bytes, (size_t)count, decoded->pixels,
                                         (size_t)PSCodecDecodedByteCount(decoded), (int)(decoded->width * 4))) {
            PSCodecDecodedFree(decoded);
            decoded = NULL;
            fail(error, PS_CODEC_DECODE, "WebP pixel decoding failed");
        }
    } else if (format == PS_CODEC_AVIF) {
        avifDecoder *decoder = avifDecoderCreate();
        if (!decoder) { fail(error, PS_CODEC_MEMORY, "AVIF decoder allocation failed"); return NULL; }
        decoder->codecChoice = AVIF_CODEC_CHOICE_AOM;
        decoder->maxThreads = 1;
        decoder->imageSizeLimit = (uint32_t)maxPixels;
        decoder->imageDimensionLimit = PS_MAX_DIMENSION;
        decoder->imageCountLimit = 1;
        decoder->ignoreExif = AVIF_TRUE;
        decoder->ignoreXMP = AVIF_TRUE;
        avifResult result = avifDecoderSetIOMemory(decoder, bytes, (size_t)count);
        if (result == AVIF_RESULT_OK) result = avifDecoderParse(decoder);
        if (result == AVIF_RESULT_OK && (decoder->imageCount != 1 || decoder->imageSequenceTrackPresent)) {
            fail(error, PS_CODEC_DECODE, "Animated AVIF is not a still image");
        } else if (result == AVIF_RESULT_OK) {
            decoded = allocateDecoded(decoder->image->width, decoder->image->height, maxPixels, maxDecodedBytes, error);
            if (decoded) result = avifDecoderNextImage(decoder);
            if (decoded && result == AVIF_RESULT_OK &&
                (decoder->image->width != decoded->width || decoder->image->height != decoded->height)) {
                result = AVIF_RESULT_ISPE_SIZE_MISMATCH;
            }
            if (decoded && result == AVIF_RESULT_OK) {
                avifRGBImage rgb;
                avifRGBImageSetDefaults(&rgb, decoder->image);
                rgb.format = AVIF_RGB_FORMAT_RGBA;
                rgb.depth = 8;
                rgb.alphaPremultiplied = AVIF_FALSE;
                rgb.pixels = decoded->pixels;
                rgb.rowBytes = decoded->width * 4;
                result = avifImageYUVToRGB(decoder->image, &rgb);
            }
        }
        if (result != AVIF_RESULT_OK) {
            PSCodecDecodedFree(decoded); decoded = NULL;
            fail(error, PS_CODEC_DECODE, avifResultToString(result));
        }
        avifDecoderDestroy(decoder);
    } else fail(error, PS_CODEC_INVALID, "Unsupported decode format");
    return decoded;
}
uint32_t PSCodecDecodedWidth(const PSCodecDecoded *d) { return d ? d->width : 0; }
uint32_t PSCodecDecodedHeight(const PSCodecDecoded *d) { return d ? d->height : 0; }
uint64_t PSCodecDecodedStride(const PSCodecDecoded *d) { return d ? (uint64_t)d->width * 4 : 0; }
uint64_t PSCodecDecodedByteCount(const PSCodecDecoded *d) { return d ? (uint64_t)d->width * d->height * 4 : 0; }
const uint8_t *PSCodecDecodedPixels(const PSCodecDecoded *d) { return d ? d->pixels : NULL; }
void PSCodecDecodedFree(PSCodecDecoded *d) { if (d) { free(d->pixels); free(d); } }

PSCodecAnimation *PSCodecWebPAnimationOpen(const uint8_t *bytes, uint64_t count,
                                         uint64_t maxPixels, uint32_t maxFrames,
                                         uint64_t maxDecodedBytes, PSCodecError *error) {
    clearError(error);
    if (!bytes || !count || count > PS_MAX_BYTES || count > SIZE_MAX || !maxFrames || maxFrames > PS_MAX_FRAMES) {
        fail(error, PS_CODEC_LIMIT, "Invalid animation input/limits"); return NULL;
    }
    WebPData data = { bytes, (size_t)count };
    WebPDemuxer *demux = WebPDemux(&data);
    if (!demux) { fail(error, PS_CODEC_DECODE, "WebP demux failed"); return NULL; }
    uint32_t width = WebPDemuxGetI(demux, WEBP_FF_CANVAS_WIDTH);
    uint32_t height = WebPDemuxGetI(demux, WEBP_FF_CANVAS_HEIGHT);
    uint32_t frames = WebPDemuxGetI(demux, WEBP_FF_FRAME_COUNT);
    uint32_t loops = WebPDemuxGetI(demux, WEBP_FF_LOOP_COUNT);
    if (!frames || frames > maxFrames || !validDimensions(width, height, maxPixels, maxDecodedBytes)) {
        WebPDemuxDelete(demux); fail(error, PS_CODEC_LIMIT, "Animation canvas/frame count exceeds limits"); return NULL;
    }
    WebPIterator frame;
    uint64_t duration = 0;
    int valid = WebPDemuxGetFrame(demux, 1, &frame);
    if (valid) {
        uint32_t seen = 0;
        do {
            ++seen;
            if (!frame.complete || frame.duration < 0 || frame.width <= 0 || frame.height <= 0 ||
                frame.x_offset < 0 || frame.y_offset < 0 ||
                (uint64_t)frame.x_offset + frame.width > width || (uint64_t)frame.y_offset + frame.height > height) {
                valid = 0; break;
            }
            duration += (uint32_t)frame.duration;
            if (duration > INT32_MAX) { valid = 0; break; }
        } while (WebPDemuxNextFrame(&frame));
        if (seen != frames) valid = 0;
        WebPDemuxReleaseIterator(&frame);
    }
    WebPDemuxDelete(demux);
    if (!valid) { fail(error, PS_CODEC_DECODE, "Invalid/incomplete WebP frame sequence"); return NULL; }
    PSCodecAnimation *animation = calloc(1, sizeof(*animation));
    if (animation) animation->input = malloc((size_t)count);
    if (!animation || !animation->input) {
        PSCodecAnimationFree(animation); fail(error, PS_CODEC_MEMORY, "Animation input allocation failed"); return NULL;
    }
    memcpy(animation->input, bytes, (size_t)count);
    data.bytes = animation->input;
    WebPAnimDecoderOptions options;
    if (!WebPAnimDecoderOptionsInit(&options)) {
        PSCodecAnimationFree(animation); fail(error, PS_CODEC_DECODE, "WebP demux ABI mismatch"); return NULL;
    }
    options.color_mode = MODE_RGBA;
    options.use_threads = 0;
    animation->decoder = WebPAnimDecoderNew(&data, &options);
    if (!animation->decoder) {
        PSCodecAnimationFree(animation); fail(error, PS_CODEC_DECODE, "WebP animation decoder failed"); return NULL;
    }
    animation->width = width; animation->height = height;
    animation->frameCount = frames; animation->loopCount = loops; animation->totalDuration = duration;
    return animation;
}
uint32_t PSCodecAnimationWidth(const PSCodecAnimation *a) { return a ? a->width : 0; }
uint32_t PSCodecAnimationHeight(const PSCodecAnimation *a) { return a ? a->height : 0; }
uint32_t PSCodecAnimationFrameCount(const PSCodecAnimation *a) { return a ? a->frameCount : 0; }
uint32_t PSCodecAnimationLoopCount(const PSCodecAnimation *a) { return a ? a->loopCount : 0; }
uint64_t PSCodecAnimationDurationMS(const PSCodecAnimation *a) { return a ? a->totalDuration : 0; }
int32_t PSCodecAnimationNext(PSCodecAnimation *a, const uint8_t **rgba,
                             uint64_t *byteCount, uint32_t *durationMS, PSCodecError *error) {
    clearError(error);
    if (rgba) *rgba = NULL;
    if (byteCount) *byteCount = 0;
    if (durationMS) *durationMS = 0;
    if (!a || !rgba || !byteCount || !durationMS) return fail(error, PS_CODEC_INVALID, "Invalid frame output");
    if (a->nextIndex == a->frameCount) {
        if (WebPAnimDecoderHasMoreFrames(a->decoder) || (uint64_t)a->previousTimestamp != a->totalDuration)
            return fail(error, PS_CODEC_DECODE, "Unexpected animation frame count/timing");
        return PS_CODEC_END;
    }
    uint8_t *pixels = NULL;
    int timestamp = 0;
    if (!WebPAnimDecoderGetNext(a->decoder, &pixels, &timestamp) || timestamp < a->previousTimestamp)
        return fail(error, PS_CODEC_DECODE, "WebP frame decode/timing failed");
    *rgba = pixels; *byteCount = (uint64_t)a->width * a->height * 4;
    *durationMS = (uint32_t)(timestamp - a->previousTimestamp);
    a->previousTimestamp = timestamp;
    ++a->nextIndex;
    return PS_CODEC_OK;
}
void PSCodecAnimationFree(PSCodecAnimation *a) {
    if (a) { if (a->decoder) WebPAnimDecoderDelete(a->decoder); free(a->input); free(a); }
}
