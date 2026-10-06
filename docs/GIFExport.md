# Bounded GIF export

GIF export is for **opaque video frames**, including PicShot's screen-recorded MP4s. Actual transparent or fractional-alpha video frames are rejected with an explicit unsupported-input error. Opaque images with an alpha-capable storage format remain supported; unused bytes in `noneSkipFirst`/`noneSkipLast` layouts are not mistaken for transparency. This restriction does not change animated GIF/WebP pin decoding.

## Streaming architecture

- AVFoundation extracts one requested frame at a time
- ImageIO receives exactly one still image per destination. It supplies the native palette and LZW encoding, then that destination is released before the next frame
- A strict GIF parser requires one complete, full-canvas image with a valid palette, image-data subblocks and trailer
- A file-backed GIF89a writer promotes each effective palette to a local table and copies the native interlace flag and LZW payload unchanged. It supplies the animation loop and centisecond timing
- No animated ImageIO destination, whole-animation `Data`, frame array, custom quantizer or per-frame helper process is used
- Opaque-only validation is necessary: copying independent still images' transparency flags does not correctly compose all opaque-to-transparent animation transitions. Unsupported alpha is rejected instead of flattened or silently corrupted

The encoded still-frame buffer has an 8 MiB limit. Opacity verification, when needed, uses one floating-point RGBA raster, bounded by the 1920-pixel dimension limit, and releases it before encoding. These are application-owned bounds; Apple framework allocations and codec caches still require runtime measurement. They are not a kernel memory quota or a zero-leak guarantee.

The animation retains its hard 64 MiB output limit. Default export remains 12 FPS, at most 1280 pixels, 30 seconds and 360 frames. Options allow at most 1920 pixels, 60 seconds and 600 frames. Frame limiting preserves playback duration by redistributing GIF centisecond delays.

Staging creation is exclusive. Failed, oversized or cancelled exports never publish the requested destination, and a failed streaming writer cannot subsequently be finalized. Successful output is flushed and closed before the existing non-overwriting publication move.

## Verification boundary

The prior multi-frame ImageIO destination exceeded the configured 384 MiB sampled-growth envelope on both architectures at source commit `c0adee4e26d52315b0fe5c154c1ccc3ec23cf49f`. Those maxima were sampled **before decoder validation** and therefore establish an export-path resource problem. ARM settled memory rose across four runs, while Intel settled memory did not rise monotonically; those observations alone do not establish a general persistent leak.

The replacement has authored tests for strict parsing and truncation rejection, native standalone-versus-animation pixel equivalence, byte-identical LZW payloads, changing palettes, alpha semantics, byte caps, cancellation and cleanup. Its installed fixture preserves the original 30-second/360-frame warm-up plus four sequential exports and cancellation case. It additionally measures one 12-frame 1920×1080 export.

Export peaks, immediately-after-export memory, settled-before-validation memory, validator peaks and post-validation memory are recorded separately. The original repeated-export envelopes remain 384 MiB peak growth, 96 MiB final growth and 32 MiB last-interval growth. The one-shot high-resolution case uses the same peak/final envelopes and makes no plateau claim.

**The streaming replacement's native tests and installed ARM/Intel memory results are pending.** Source changes and static review are not runtime evidence. Keep the installer unreleased until exact-commit verification passes.
