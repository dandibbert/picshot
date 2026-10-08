# Multi-window normalization candidate

`normalizedCandidate` is now selected for the **0.15 production-candidate build**, after the bounded ARM diagnostic comparison below. This is not installed-package acceptance. The previous path remains available as an explicit `coreGraphicsBaseline` diagnostic control. The implementation now performs one caller-owned vImage conversion per source, wraps that buffer in a zero-copy canonical `CGImage`, and uses the original Quartz strip drawing loop for sampling and source-over blending. It does not emulate Quartz's sampling arithmetic.

The fixture reports `candidateImplementation: vimage-canonical-cgimage-quartz-strips-v1` so results cannot be confused with the earlier CPU prototype under the same experimental mode name. Build101 establishes native exact-byte and bounded ARM fresh-process evidence for the corrected implementation. The subsequent production-default build still requires all focused, ordinary, real-model, UI, actual ZIP/DMG and installed 4+12 resource gates before delivery.

## Why the CPU implementation was rejected

Both ARM and Intel run100 at `83406c0d` compiled and ran 32 source-scoped tests. Thirty-one passed on each architecture. The exact fractional-density test failed at output byte 24: baseline 62 versus CPU candidate 73. For its 8-pixel source scaled into 13 pixels, destination pixel X=6 lands mathematically on source edge 4; Quartz selected source pixel 3 while the prototype selected 4.

The alpha grid, source profiles, alpha conventions, byte orders, padding, grayscale/RGB/decode arrays, ImageIO, ownership, cancellation and budgets passed that run. This single sampling point does not establish a universal tie rule. The failed implementation and native evidence remain in Git history. The corrected implementation removes CPU sampling rather than loosening any equality or expected byte. The exact fractional test remains a required live gate.

The separate native baseline/tail-first experiment on both architectures found measured late-cycle volatile increments of 3,440,640 bytes with the final 112-row clips, and 3,932,160 bytes with 128-row clips last. These match two source-width RGBA bands. Decode boundaries added no volatile bytes in that experiment. This associates the retained backing with the final draw band in that workload; it does not prove that normalizing sources removes the backing.

## Corrected ownership and admission

For each source, the candidate performs:

1. Validate source metadata and combined byte admission
2. Convert once into caller-owned 8-bit premultiplied sRGB RGBA using `vImageBuffer_InitWithCGImage` and `kvImageNoAllocate`
3. Create one `CGDataProvider` and `CGImage` referring directly to that normalization allocation
4. Draw that canonical image with the original context, transform, nearest interpolation, 128-row clip partition and source-over blend mode
5. Release the canonical image/provider and normalization before acquiring the next source

The provider release callback retains/releases the normalization allocation. It does not create `Data`, copy provider bytes, use `CGContext.makeImage`, or allocate a scaled image. The final output provider still receives the original output allocation without a canvas copy.

The existing limits remain 16,000,000 pixels per input, 64,000,000 total input pixels, 32,000,000 output pixels, and 16,384 per side. Explicit live raster admission remains at most **192,000,000 bytes**:

- Output: `layout.width × layout.height × 4`
- Source: actual `image.bytesPerRow × image.height`, including padding
- Normalization: `image.width × image.height × 4`

Impossible maximum-density layouts reject before canvas allocation. Actual padded-source admission rejects before normalization. Some layouts admitted by baseline are intentionally rejected by the candidate; a 32 MP output plus a 16 MP source would otherwise require 256 MB.

One source and one normalization remain live at a time. A weak wrapper probe verifies each canonical image is released before the next frame; explicit allocation counters also detect a provider retaining normalization after its image wrapper disappears. Both must return to zero after complete or cancelled cycles. Tests cover cancellation immediately after the first Quartz strip as well as acquisition cancellation/failure and ordinary output release.

Private Quartz, vImage, ColorSync, ImageIO and kernel storage are **not** covered by these explicit-raster counters or by `kvImageNoAllocate`. Quartz can still create native converted backing for the canonical image. Its remaining volatile/virtual/resident/footprint cost must be measured. There is no claimed process-memory cap or zero-leak result.

Cancellation/deadline checks remain before/after normalization and between Quartz strips. Native conversion/drawing is not interruptible; late or cancelled results are rejected. Existing sequential acquisition, screenshot process termination/reaping, failure discard and editor admission remain unchanged.

## Required native gates

Run `bash scripts/test-multiwindow-source-scope.sh` on macOS. The same exact tests and expected bytes cover all 65,536 source/destination alpha pairs, fractional placement and density, orientation, z-order, gaps, sRGB/P3/linear profiles, alpha conventions, byte order, padding, grayscale, RGB, decode arrays and PNG decoding. Wrapper/provider lifetime assertions and a first-strip cancellation test extend the previous ownership checks.

There is no tolerance change, expected-failure marker or test exclusion. The production-default selection is explicit in code and tested without passing a mode argument. A new failure blocks the candidate and must be investigated.

After exact tests pass, run the same provenance-verified binary in separate fresh processes:

```sh
bash scripts/multiwindow-resource-smoke.sh /absolute/PicShot.app /absolute/new-baseline-evidence SOURCE_COMMIT coreGraphicsBaseline
bash scripts/multiwindow-resource-smoke.sh /absolute/PicShot.app /absolute/new-candidate-evidence SOURCE_COMMIT normalizedCandidate
```

The fixture-only key remains `PICSHOT_MULTIWINDOW_COMPOSITION`. The independent tail-first control remains restricted to baseline. No ordinary capture reads this diagnostic mode selector. The three-argument installed resource runner unsets inherited composition, tail-first and trace selectors. Its raw and checked reports must state `compositionModeSource: productionDefault` and a null override. Four-argument comparisons require an explicit, matching diagnostic override.

For the two-window 4K workload, tight explicit raster accounting is:

- Baseline: 45,158,400 output + 33,177,600 source = 78,336,000 bytes
- Candidate: 45,158,400 output + 33,177,600 source + 33,177,600 normalization = 111,513,600 bytes

The report adds canonical wrapper creation/live counts to actual source-stride and normalization accounting. It retains output SHA-256, weak input/decoder/output probes, cancellation and file/exit cleanup, all measured memory fields, phase boundaries and transient peaks. Digest readback can allocate and remains separately labeled. Completed observations do not establish memory stability.

## Standalone sampling calibration

`probe-multiwindow-nearest.swift` records 1,211 small coordinate-encoded cases, covering source sizes 2–17 and destinations 2–33, translations, both axes, mirrored transforms, exact run100 canvas geometry, long thin rasters, and whole/128-row/tail-first clipping. `analyze-multiwindow-nearest.py` compares explicit exact-tie and floating/fixed-point hypotheses, separating tie from non-tie differences and checking translation, clipping and reflection effects.

These tools diagnose the rejected CPU assumption; they do not establish a universal Quartz arithmetic contract or modify rendering. Their native output should accompany the next comparison run.

## Verified diagnostic evidence and remaining acceptance

Source `00a1b9973571d8cef23aca6ba934daf52f2ed2e9`, run `37737735045`, build 101: ARM and Intel source-scoped native suites each passed 33/33 tests, including the unchanged fractional pixel expectation and cancellation after the first Quartz strip. Raw runner reports confirmed exit 0, no timeout and no truncated log. Continued GitHub step conclusions are not used as test-pass evidence.

The ARM six-cell comparison completed in six distinct exited processes with identical source/output hashes and workloads: four warmups plus twelve measured cycles, two fresh 3840×2160 PNG decodes per cycle, and a 4480×2520 output. Candidate and candidate-traced records passed the strict 1,574-event topology, required counter availability, canonical/source/provider/output cleanup, cancellation and temporary-file checks. All counters below are MiB, measured in this one bounded synthetic workload:

| ARM untraced cell | Entry RSS | After PNG preparation | After four warmups | Final after twelve measurements | Sampled RSS peak |
|---|---:|---:|---:|---:|---:|
| Baseline |66.719|109.031|166.063|206.922|236.922|
| Normalized Quartz |66.531|108.813|152.484|153.688|185.234|

Candidate total entry-to-cleanup RSS rise remains 87.156 MiB:42.281 MiB during preparation,43.672 MiB during warmup, then1.203 MiB after warmup. Traced candidate post-warmup RSS rises1.266 MiB. Both candidate cells have zero measured and late-cycle volatile resident/virtual growth, while baseline adds 39.375 MiB volatile resident and tail-first adds 45 MiB. Candidate final volatile resident/virtual remains 16 KiB; sampled transient volatile peak is 31.656 MiB. Footprint rises 0.516 MiB untraced and0.469 MiB traced after warmup. Candidate late RSS still increases by32–192 KiB per interval; these observations do not establish an overall RSS plateau or leak-free behavior.

The untraced candidate completes the same 4+12 workload in 3.648 s versus baseline 5.429 s. Sampled peaks are lower bounds at sampled times. Kernel lifetime peaks are 185.422 MiB RSS / 95.049 MiB footprint for the untraced candidate and 186.969 / 98.190 MiB for the traced candidate; the sampled untraced footprint peak was only 79.534 MiB. Kernel lifetime peaks cover the entire fresh process lifetime, whereas phase samples cover the fixture. Neither implies a guaranteed product memory maximum. Private graphics/decoder backing remains outside the 192,000,000-byte explicit-raster admission. No screenshot permissions, real foreign-window capture, physical multi-display configuration, system pressure or user assets are involved.

This supports testing the production replacement for the repeated final-band growth. The actual installed production-default resource run and complete 0.15 functional/model/install gates remain pending. Other export/preview backing observations and the accepted 0.14 memory caveats remain separate; no universal memory remedy is claimed.
