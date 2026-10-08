# Multi-window normalization candidate

This is an **opt-in diagnostic candidate**, based on the supplied `03cae2a31e5a37f32ca224d422b6690e25c6d7bb` snapshot. Normal capture still uses `coreGraphicsBaseline`. It has not been promoted, native-compiled, or measured on macOS by this authoring environment.

The existing baseline repeatedly draws the entire source `CGImage` through a clipped `CGContext` in 128-row strips. The candidate instead normalizes each source once into caller-owned, tightly packed, 8-bit premultiplied sRGB RGBA with `vImageBuffer_InitWithCGImage` and `kvImageNoAllocate`. It then writes nearest-neighbor, top-left pixel-center samples and premultiplied source-over bytes directly into the existing output allocation. It creates no intermediate `CGImage`, cropped raster, framework drawing context, or scaled raster. The existing final provider retains that exact output allocation, with no final canvas copy.

This does **not** establish that conversion caused the observed resource growth. `kvImageNoAllocate` constrains the supplied destination; it does not bound private vImage, ColorSync, ImageIO, CoreGraphics or kernel storage. The attribution worker's separate final-strip-order comparison is independent evidence.

## Admission and ownership

The existing 16,000,000 input pixels, 64,000,000 total input pixels, 32,000,000 output pixels, and 16,384 side limits remain unchanged. The combined admission limit is explicitly 192,000,000 bytes:

- Output: `layout.width × layout.height × 4`
- Current source: actual `image.bytesPerRow × image.height`, including padding
- Normalization: `image.width × image.height × 4`

Maximum-density layouts that cannot fit a tightly packed source and normalization are rejected before output allocation. Actual padded-source admission is checked again before allocating normalization. This intentionally rejects some combinations the baseline admits, for example a 32 MP output plus a 16 MP source, which would need 256 MB with normalization. A 16 MP output and 16 MP source fit exactly at 192 MB. No larger scratch allowance is hidden in the old two-raster claim.

One source and one normalization exist at a time. Normalization leaves scope before the next frame request. Output ownership survives the renderer through the provider and ends with the returned image. Probes count explicit canvas/normalization allocation and admitted source stride separately; they do not prove total process backing has been released.

The candidate checks cancellation/deadline before and after normalization, every 32 composition rows, and yields every 128 rows. Native conversion remains noninterruptible; a late or cancelled result is rejected. Existing sequential acquisition, failure discard, process termination/reaping and normal editor admission are unchanged.

## Native gates

Run `bash scripts/test-multiwindow-source-scope.sh` on macOS. It includes the new exact-byte tests and needs no models or third-party package dependencies. It uses Apple Accelerate.

New tests cover:

- All 65,536 source/destination alpha pairs against the baseline and a separate integer source-over oracle
- Fractional placement, negative origins, mixed density, nonintegral nearest sampling, asymmetric orientation, desktop z-order and transparent gaps
- sRGB, Display P3 and linear sRGB; straight and premultiplied alpha; RGBA and BGRA; padded rows
- Grayscale, 24-bit RGB, color decode arrays, and a fresh ImageIO PNG decode
- Repeated one-source/one-normalization ownership, final output release, cancellation/failure cleanup, and budget rejection before allocation

There is deliberately **no color or alpha tolerance**. Any baseline difference, including rounding, profile conversion, or nearest-neighbor tie behavior, blocks promotion and needs investigation. Existing end-to-end native/controller tests remain necessary; tests added here are source, not evidence that they pass.

## Fresh-process resource comparison

The existing 4-warmup / 12-measured, two-window 4K fixture accepts an optional fourth script argument:

```sh
bash scripts/multiwindow-resource-smoke.sh /absolute/PicShot.app /absolute/new-baseline-evidence SOURCE_COMMIT coreGraphicsBaseline
bash scripts/multiwindow-resource-smoke.sh /absolute/PicShot.app /absolute/new-candidate-evidence SOURCE_COMMIT normalizedCandidate
```

Use the same provenance-verified candidate binary for both fresh processes, and reverse ordering in an independent repeat if results justify further comparison. `SOURCE_COMMIT` must match that binary's embedded commit. Each launch requires a new evidence directory. The fixture-only environment key is `PICSHOT_MULTIWINDOW_COMPOSITION`; it never selects the renderer for ordinary capture.

The report records mode, production default, extra normalization bytes, combined limit, per-cycle live/peak raster counters, normalization counts, all existing memory/volatile/virtual samples, RGBA hashes, release probes, file cleanup and cancellation results. For the current fixture the tight-raster figures are:

- Baseline: 45,158,400 output + 33,177,600 source = 78,336,000 bytes
- Candidate: 45,158,400 output + 33,177,600 source + 33,177,600 normalization = 111,513,600 bytes

The counters use the actual source stride, so padding can increase the measured peak. A source stride that breaks combined admission fails before scratch allocation. Digest readback remains separately labeled and may copy output provider bytes.

Keep native exact-byte results, per-cycle late volatile/virtual/footprint changes, transient peaks, elapsed time and exit confirmation together. A completed fixture is an observation, not a leak-free or plateau verdict. Do not switch production until native correctness, cancellation, admission and resource comparison evidence supports the change.

## Authoring validation

Linux checks: shell syntax for both multi-window scripts and compilation of embedded Python passed. No Swift compiler, Apple SDK, WindowServer or native process resource measurements are available in this authoring environment. No owner checkout or published artifact was modified.
