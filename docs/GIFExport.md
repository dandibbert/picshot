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

**The replacement passed its configured native and installed ARM/Intel gates at [6c808a5](https://github.com/dandibbert/picshot/commit/6c808a5edc2b36ba12a38706239a965386edb03b), [run 37454104537](https://github.com/dandibbert/picshot/actions/runs/37454104537).** The 480×270 export peak was about 195 MiB RSS on ARM and 83 MiB on Intel; the 12-frame 1920×1080 case peaked about 330 MiB and 192 MiB respectively. Full GIF stress ran from ZIP only; both installed formats passed their other native checks.

ARM still settled +49.0 MiB RSS across four combined export/validation cycles, versus +0.504 MiB on Intel. This is not a demonstrated ARM plateau or a zero-leak result. Fresh-process attribution completed in run 37458401335: eight export-only cycles retained 98.03 MiB RSS on ARM versus 0.19 MiB on Intel; eight decode-only reads of the same immutable GIF retained 0.59 MiB and 1.11 MiB respectively. This reproduces the ARM growth within export without identifying its allocation owner. A same-binary comparison in run 37462393497 then measured ARM async +98.13 MiB versus scoped synchronous +98.03 MiB over eight export-only cycles. Eleven semantic/diagnostic tests passed per architecture, but the candidate did not improve retention and was rejected. App callers still use the async default. On-demand helper isolation is under implementation, with both parent and child resource accounting required before a fix claim. See [VERIFICATION.md](VERIFICATION.md) for exact artifact hashes, sample scopes and limits.

## 0.5 process boundary: authored, native verification pending

Production `GIFExporter.export` now delegates to one on-demand invocation of the same validated, ad-hoc-signed app executable. The special entry runs before AppDelegate/NSApplication initialization. There is no automatic in-process fallback when validation or launch fails. `GIFInProcessEngine.exportDirect` remains explicitly named for the helper and semantic/baseline diagnostics; its async extraction default was not replaced by the rejected synchronous candidate.

The parent retains its one-GIF admission lease until child exit and staging cleanup are confirmed. Requests, progress/result/error messages and local file reads are bounded; the parent validates the produced GIF before exclusive publication. Cancellation, timeout, malformed replies, destination collisions and parent death have dedicated fixtures. A live/unconfirmed child preserves its staging instead of deleting underneath it. Orphan cleanup only touches validated owned files; substituted contents or failed I/O may leave reported staging rather than trigger broad deletion.

Input is explicitly a regular local, self-contained H.264 MP4 with optional AAC, at most **1 GiB**. External-reference movies/playlists and other codecs/containers are rejected before native decoding; this narrower boundary is not arbitrary-video import parity. Output remains at most **64 MiB**, with the existing dimension/frame/duration limits and explicit rejection of actual transparent frames. The helper has a 300-second operation limit, a 303-second child lifetime backstop, and a sampled 1-GiB resident-memory stop. Polling is not a kernel memory quota or a guaranteed lifetime peak.

The one-GIF admission gate is separate from the model-helper gate: one GIF job may overlap one ML job. Evidence must report app RSS/footprint, parent-polled GIF-child RSS, child-reported RSS/footprint, exit status and cleanup separately. These exclude other helpers, framework services and GPU allocations. Process isolation is intended to contain per-export retained allocations at child exit; it neither identifies their native allocation owner nor establishes a zero-leak result. No isolated-helper memory result is asserted until installed native tests and the explicit eight-cycle `isolated-helper` attribution run complete.
