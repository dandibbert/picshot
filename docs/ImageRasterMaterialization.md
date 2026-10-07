# Opt-in image draw/materialization comparison

Prepared diagnostic only; no native pass or memory remedy is claimed. Production preview defaults, resource gates, and pin workflows are unchanged. The separate [allocator-relief result](ImageAllocatorRelief971.md) was negative on ARM64 and Intel.

Run only with an existing signed app built with this diagnostic patch; no new installer is required solely for observations:

```sh
scripts/image-draw-attribution.sh --compare /absolute/PicShot.app /absolute/new-evidence-directory
```

There is no normal build/smoke hook. Only the explicitly selected `[codec-attribution] [image-draw]` CI job runs this comparison, without publishing installers. The runner verifies the signature, native architecture, protocol and real Swift SDK API imports before starting one preparation process and three fresh comparison processes. Each arm uses fixed **768×576, 2 warmups +12 measured cycles**, a 45-second cooperative deadline, and a 60-second outer work deadline (plus up to three seconds solely to confirm killed-process exit). Counts, dimensions, tolerance, and deadlines cannot be overridden.

## Three arms, identical actual drawing

- `production-draw`: calls the unchanged production PNG preview, then actually draws its returned image
- `imageio-no-cache-draw`: creates a full ImageIO image with `kCGImageSourceShouldCache=false`, `kCGImageSourceShouldCacheImmediately=false`, and `kCGImageSourceShouldAllowFloat=false`, then actually draws it. Exact PNG metadata, 768×576 dimensions, 8-bit depth, orientation 1 and returned stride bounds are checked; this is not a full-size-image fallback for production
- `owned-rgba-draw`: copies the separately prepared raw reference into one owned RGBA source buffer per cycle, constructs a public CGDataProvider/CGImage, then actually draws it

The raw arm starts with already decoded bytes: it isolates provider/render behavior and excludes PNG decoding. A lower raw-arm footprint alone would not establish an end-to-end export fix.

Apple documents [decoded-image caching](https://developer.apple.com/documentation/imageio/kcgimagesourceshouldcache) and [immediate versus render-time decoding](https://developer.apple.com/documentation/imageio/kcgimagesourceshouldcacheimmediately). A cheap lazy image object alone is not a fix. Every measured cycle performs the same 1:1 CGContext draw into a **single preallocated destination buffer/context per process**, then reads and validates every RGBA byte. The destination is cleared, uses copy blending/no interpolation, and is not snapshotted with makeImage. A flush call is included consistently; full bitmap readback/pixel validation supplies the materialization evidence, not flush alone.

Preparation writes immutable PNG bytes and a canonical raw raster derived from the production preview in a separate process. Every arm retains the same two input buffers once. Pixel comparison covers all channels with the existing maximum absolute tolerance of 2; actual hashes/differences are reported. Readback hashing borrows the preallocated destination instead of allocating a copied per-cycle raster. No per-cycle image or decoded-raster arrays are retained in evidence.

## Ownership, timing, and memory

The raw arm records public [CGDataProvider release callbacks](https://developer.apple.com/documentation/coregraphics/cgdataproviderreleasedatacallback) and actual owned-buffer deallocation calls. One analogous public bitmap-context release callback tracks the destination. Counters store only scalars, not images/pointers. Callback completion means Core Graphics no longer requires those supplied bytes; deallocation calls do **not** prove physical-memory reclamation. ImageIO providers are not instrumented, rather than reported as a fabricated zero.

Reports record creation, actual draw, full pixel validation, their summed operation time, and total instrumented wall time. Inspect the combined timings, never creation time alone. Self-Mach backing observations bracket creation, drawing/readback, pool exit, settling, and dropping the destination owner. Retention by the shared destination is therefore visible separately. Its reuse is a controlled difference from earlier diagnostics that allocated a new validation raster each cycle.

Named reports are `image-draw-<mode>.json`; `comparison.json` summarizes them. Raw-provider allocation count is capped at 14 fixed 1.6875 MiB buffers; destination allocation count is one. Encoded input is capped at 8 MiB, raw input must be exactly 1,769,472 bytes, and reports at 1 MiB. No allocator-relief call, global pressure, huge allocation, private API, new dependency/model/download, or production preview change is included. Any later remedy needs native evidence and appropriate large-input/UI validation.
