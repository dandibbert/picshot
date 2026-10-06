/* Original deterministic tests. Compiled/run only by the native macOS build. */
#include "CPicShotCodecs.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    uint8_t *bytes;
    size_t count;
    uint32_t percent;
    int abortWrite;
    int cancelProgress;
    int writes;
} Output;
static int32_t writer(const uint8_t *bytes, uint64_t count, uint64_t cumulative, void *opaque) {
    Output *out = opaque;
    assert(cumulative == out->count + count);
    if (out->abortWrite) return 0;
    uint8_t *grown = realloc(out->bytes, out->count + (size_t)count);
    assert(grown);
    out->bytes = grown;
    memcpy(out->bytes + out->count, bytes, (size_t)count);
    out->count += (size_t)count;
    ++out->writes;
    return 1;
}
static int32_t progress(uint32_t percent, uint64_t cumulative, void *opaque) {
    Output *out = opaque;
    assert(percent >= out->percent && percent <= 100);
    assert(cumulative == out->count);
    out->percent = percent;
    return !out->cancelProgress;
}
static void clear(Output *out) { free(out->bytes); memset(out, 0, sizeof(*out)); }
static void fill(uint8_t *pixels, uint32_t width, uint32_t height, unsigned shift) {
    for (uint32_t y = 0; y < height; ++y) for (uint32_t x = 0; x < width; ++x) {
        size_t p = ((size_t)y * width + x) * 4;
        pixels[p] = (uint8_t)(x * 47 + y * 11 + shift);
        pixels[p+1] = (uint8_t)(x * 13 + y * 61 + shift * 3);
        pixels[p+2] = (uint8_t)(x * 23 + y * 7 + shift * 5);
        pixels[p+3] = (x + y) % 3 == 0 ? 0 : (x + y) % 3 == 1 ? 127 : 255;
    }
}
static Output encode(uint32_t format, const uint8_t *pixels, uint32_t w, uint32_t h,
                     uint32_t lossless, uint32_t quality, uint32_t alpha) {
    Output out = {0};
    PSCodecOptions options = PSCodecDefaultOptions(format);
    options.lossless = lossless; options.quality = quality; options.preserveAlpha = alpha;
    PSCodecError error = {0};
    int32_t result = PSCodecEncodeRGBA(pixels, (uint64_t)w*h*4, w,h,(uint64_t)w*4,
                                     &options, writer, progress, &out, &error);
    if (result) fprintf(stderr, "encode %u: %s\n", format, PSCodecErrorMessage(&error));
    assert(result == PS_CODEC_OK && error.code == 0 && out.percent == 100 && out.writes > 0);
    if (format == PS_CODEC_WEBP) assert(out.count > 12 && !memcmp(out.bytes,"RIFF",4) && !memcmp(out.bytes+8,"WEBP",4));
    else assert(out.count > 12 && !memcmp(out.bytes+4,"ftyp",4) && !memcmp(out.bytes+8,"avif",4));
    return out;
}
static void verifyStill(uint32_t format) {
    const uint32_t w=65,h=47;
    uint8_t pixels[65*47*4]; fill(pixels,w,h,3);
    Output lossless = encode(format,pixels,w,h,1,75,1);
    PSCodecError error = {0};
    PSCodecDecoded *decoded = PSCodecDecodeRGBA(format,lossless.bytes,lossless.count,w*h,w*h*4,&error);
    if (!decoded) fprintf(stderr,"decode %u: %s\n",format,PSCodecErrorMessage(&error));
    assert(decoded && PSCodecDecodedWidth(decoded)==w && PSCodecDecodedHeight(decoded)==h);
    assert(PSCodecDecodedStride(decoded)==w*4 && PSCodecDecodedByteCount(decoded)==sizeof(pixels));
    assert(!memcmp(PSCodecDecodedPixels(decoded),pixels,sizeof(pixels)));
    PSCodecDecodedFree(decoded);
    Output low=encode(format,pixels,w,h,0,20,1), high=encode(format,pixels,w,h,0,95,1);
    assert(low.count != high.count || memcmp(low.bytes,high.bytes,low.count));
    decoded=PSCodecDecodeRGBA(format,high.bytes,high.count,w*h,w*h*4,&error);
    assert(decoded);
    for(size_t i=3;i<sizeof(pixels);i+=4) assert(PSCodecDecodedPixels(decoded)[i]==pixels[i]);
    PSCodecDecodedFree(decoded);
    Output opaque=encode(format,pixels,w,h,1,75,0);
    decoded=PSCodecDecodeRGBA(format,opaque.bytes,opaque.count,w*h,w*h*4,&error); assert(decoded);
    for(size_t i=0;i<sizeof(pixels);i+=4) {
        assert(!memcmp(PSCodecDecodedPixels(decoded)+i,pixels+i,3));
        assert(PSCodecDecodedPixels(decoded)[i+3]==255);
    }
    PSCodecDecodedFree(decoded);
    assert(!PSCodecDecodeRGBA(format,lossless.bytes,lossless.count,w*h-1,w*h*4,&error));
    assert(!PSCodecDecodeRGBA(format,lossless.bytes,lossless.count,w*h,w*h*4-1,&error));
    assert(!PSCodecDecodeRGBA(format,lossless.bytes,lossless.count/2,w*h,w*h*4,&error));
    uint8_t invalid[16]={0};
    assert(!PSCodecDecodeRGBA(format,invalid,sizeof(invalid),w*h,w*h*4,&error));
    Output rejected={0};
    PSCodecOptions options=PSCodecDefaultOptions(format);
    assert(PSCodecEncodeRGBA(pixels,sizeof(pixels)-1,w,h,w*4,&options,writer,progress,&rejected,&error)==PS_CODEC_LIMIT);
    assert(!rejected.count);
    assert(PSCodecEncodeRGBA(pixels,sizeof(pixels),w,h,w*4-1,&options,writer,progress,&rejected,&error)==PS_CODEC_LIMIT);
    assert(PSCodecEncodeRGBA(pixels,sizeof(pixels),UINT32_MAX,h,UINT64_MAX,&options,writer,progress,&rejected,&error)==PS_CODEC_LIMIT);
    options.maxOutputBytes=1;
    assert(PSCodecEncodeRGBA(pixels,sizeof(pixels),w,h,w*4,&options,writer,progress,&rejected,&error)==PS_CODEC_LIMIT);
    assert(!rejected.count); clear(&rejected);
    options=PSCodecDefaultOptions(format); rejected.abortWrite=1;
    assert(PSCodecEncodeRGBA(pixels,sizeof(pixels),w,h,w*4,&options,writer,progress,&rejected,&error)==PS_CODEC_WRITE);
    assert(!rejected.count); clear(&rejected); rejected.cancelProgress=1;
    assert(PSCodecEncodeRGBA(pixels,sizeof(pixels),w,h,w*4,&options,writer,progress,&rejected,&error)==PS_CODEC_CANCELLED);
    assert(!rejected.count);
    printf("format %u: lossless RGBA exact, alpha, lossy quality, byte/size bounds, abort and cancellation passed (%zu/%zu/%zu bytes)\n",format,lossless.count,low.count,high.count);
    clear(&lossless);clear(&low);clear(&high);clear(&opaque);clear(&rejected);
}
static void append(Output *out,const void *bytes,size_t count) {
    assert(writer(bytes,count,out->count+count,out));
}
static void le24(uint8_t *p,uint32_t n) {p[0]=(uint8_t)n;p[1]=(uint8_t)(n>>8);p[2]=(uint8_t)(n>>16);}
static void le32(uint8_t *p,uint32_t n) {le24(p,n);p[3]=(uint8_t)(n>>24);}
static uint32_t read32(const uint8_t *p) {return (uint32_t)p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24);}
static void chunk(Output *out,const char tag[4],const uint8_t *bytes,size_t length) {
    uint8_t size[4];le32(size,(uint32_t)length);append(out,tag,4);append(out,size,4);append(out,bytes,length);
    if(length&1){uint8_t zero=0;append(out,&zero,1);}
}
static void verifyAnimation(void) {
    const uint32_t w=7,h=5;
    uint8_t frames[3][7*5*4];
    const uint32_t durations[3]={17,101,0};
    Output animation={0};
    uint8_t riff[12]={'R','I','F','F',0,0,0,0,'W','E','B','P'};append(&animation,riff,12);
    uint8_t vp8x[10]={0x12,0,0,0};le24(vp8x+4,w-1);le24(vp8x+7,h-1);chunk(&animation,"VP8X",vp8x,10);
    uint8_t anim[6]={0,0,0,0,3,0};chunk(&animation,"ANIM",anim,6);
    for(unsigned i=0;i<3;++i) {
        fill(frames[i],w,h,i*37);
        Output still=encode(PS_CODEC_WEBP,frames[i],w,h,1,75,1), payload={0};
        uint8_t header[16]={0};le24(header+6,w-1);le24(header+9,h-1);le24(header+12,durations[i]);header[15]=2;
        append(&payload,header,16);
        int found=0;
        for(size_t pos=12;pos+8<=still.count;) {
            uint32_t n=read32(still.bytes+pos+4);assert((uint64_t)pos+8+n+(n&1)<=still.count);
            if(!memcmp(still.bytes+pos,"VP8L",4)) {append(&payload,still.bytes+pos,8+n+(n&1));++found;}
            pos+=8+n+(n&1);
        }
        assert(found==1);chunk(&animation,"ANMF",payload.bytes,payload.count);clear(&payload);clear(&still);
    }
    le32(animation.bytes+4,(uint32_t)animation.count-8);
    PSCodecError error={0};
    assert(!PSCodecDecodeRGBA(PS_CODEC_WEBP,animation.bytes,animation.count,w*h,w*h*4,&error));
    assert(!PSCodecWebPAnimationOpen(animation.bytes,animation.count,w*h,2,w*h*4,&error));
    assert(!PSCodecWebPAnimationOpen(animation.bytes,animation.count,w*h-1,3,w*h*4,&error));
    assert(!PSCodecWebPAnimationOpen(animation.bytes,animation.count-4,w*h,3,w*h*4,&error));
    PSCodecAnimation *decoder=PSCodecWebPAnimationOpen(animation.bytes,animation.count,w*h,3,w*h*4,&error);
    if(!decoder)fprintf(stderr,"animation: %s\n",PSCodecErrorMessage(&error));
    assert(decoder&&PSCodecAnimationWidth(decoder)==w&&PSCodecAnimationHeight(decoder)==h);
    assert(PSCodecAnimationFrameCount(decoder)==3&&PSCodecAnimationLoopCount(decoder)==3&&PSCodecAnimationDurationMS(decoder)==118);
    const uint8_t *rgba=NULL;uint64_t count=0;uint32_t duration=0;
    for(unsigned i=0;i<3;++i){
        assert(PSCodecAnimationNext(decoder,&rgba,&count,&duration,&error)==PS_CODEC_OK);
        assert(count==sizeof(frames[i])&&duration==durations[i]);
        assert(!memcmp(rgba,frames[i],sizeof(frames[i])));
    }
    assert(PSCodecAnimationNext(decoder,&rgba,&count,&duration,&error)==PS_CODEC_END);
    assert(!rgba&&!count&&!duration);
    PSCodecAnimationFree(decoder);clear(&animation);
    puts("animation: all 3 odd-sized alpha frames and exact 17/101/0 ms timing passed");
}
int main(void) {
    assert(!strcmp(PSCodecVersion(PS_CODEC_WEBP),"1.6.0"));
    assert(!strcmp(PSCodecVersion(PS_CODEC_AVIF),"1.4.2"));
    assert(strstr(PSCodecAOMVersion(),"3.15.0"));
    verifyStill(PS_CODEC_WEBP);verifyStill(PS_CODEC_AVIF);verifyAnimation();
    printf("Native codec selftests passed: WebP %s, AVIF %s, AOM %s\n",PSCodecVersion(PS_CODEC_WEBP),PSCodecVersion(PS_CODEC_AVIF),PSCodecAOMVersion());
    return 0;
}
