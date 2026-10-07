# Actual image drawing results on ARM64 and Intel

Versioned diagnostic result, 2026-10-07. Both architectures completed the three actual-draw controls. Disabling ImageIO caching reduced the observed volatile-resident accumulation, but did not eliminate it once pixels were drawn. The owned-RGBA control had no measured volatile growth; it starts with decoded pixels and therefore does not establish an end-to-end PNG remedy.

## Provenance and workload

Source [`59d30a835e71addd0254dbd2c4ecdf03c8ada63f`](https://github.com/dandibbert/picshot/commit/59d30a835e71addd0254dbd2c4ecdf03c8ada63f), [run 37561081891](https://github.com/dandibbert/picshot/actions/runs/37561081891), macOS 15.7.9 (24G830), ARM64 and Intel. Named evidence is under `evidence/image-draw/<mode>/image-draw-<mode>.json`; `comparison.json` summarizes timing and RSS/footprint. The raw named reports are required for the backing fields and phase boundaries.

Each fresh app process used the same separately prepared immutable PNG and canonical production-preview RGBA reference: **768×576, 2 warmups +12 measured cycles**. One tightly packed RGBA raster is **1,769,472 bytes, or 1.6875 MiB**. A single preallocated destination was reused throughout each process. Every cycle created an image, actually drew it 1:1, and read/compared every channel. All **14 draws and full-pixel validations per arm matched exactly**, although the permitted tolerance was 2.

All 76 named self-Mach observations per arm returned successful `TASK_VM_INFO_PURGEABLE` results with volatile resident/virtual/pmap fields present. These are accounting observations, separate from the ordinary `TASK_VM_INFO` calls, rather than attribution to a particular private allocator.

## Backing boundaries

The following volatile-resident changes were identical on ARM64 and Intel throughout the 12 measured cycles:

| Arm | Image creation per cycle | Draw and readback per cycle | Measured total | Each final three cycles |
|---|---:|---:|---:|---:|
| Production PNG preview then draw | +1.6875 MiB | +1.6875 MiB | +40.5 MiB | +3.375 MiB |
| Full ImageIO image with caching disabled then draw | 0 | +1.6875 MiB | +20.25 MiB | +1.6875 MiB |
| Owned RGBA provider then draw | 0 | 0 | 0 | 0 |

The second warmup already showed these steady increments; the first also included small framework-page changes. Pool exit, settling, and the final destination-owner drop did not reduce the accumulated volatile values. The additional half-second observation after destination close retained the same measured totals.

Each destination's callback and owned deallocation completed once. The raw arm recorded **14 allocations, 14 provider-release callbacks, 14 deallocations, zero active owned bytes, and a one-raster peak of 1.6875 MiB**, on both architectures. These counts describe supplied-buffer ownership, not physical RAM reclamation or ImageIO's uninstrumented providers.

## RSS footprint and timing

Settled changes from the post-warmup baseline, in production / no-cache / raw order:

- ARM64 RSS: **+40.765625 / +17.187500 / +2.890625 MiB**; physical footprint: **+0.281372 / −0.093689 / +0.140625 MiB**
- Intel RSS: **+40.886719 / +20.679688 / +0.183594 MiB**; physical footprint: **+0.351562 / +0.394531 / +0.148438 MiB**

Raw ARM RSS rose mainly in the first two measured cycles; its final three increments were +0.015625 / +0.015625 / 0 MiB. Intel raw's final three were +0.011719 / +0.015625 / +0.015625 MiB. RSS noise and small retained-report/framework costs should not be substituted for the separately observed volatile-buffer slope.

Median creation + draw + full validation time, in the same order, was **7.825 / 4.305 / 1.773 ms on ARM64** and **11.698 / 8.769 / 5.786 ms on Intel**. These measured operation timings exclude later caller pool cleanup and diagnostic settling. The raw arm also excludes PNG decoding; these numbers do not establish a full-lifecycle or production performance improvement.

## Conclusion and next question

Apple's [cache option](https://developer.apple.com/documentation/imageio/kcgimagesourceshouldcache) controls decoded-image caching. The actual draw boundary is essential: a cheap, lazy image-creation result alone missed the remaining one-buffer-per-cycle accumulation. The shared destination itself was released, without reducing that accumulation.

The earlier [allocator-relief experiment](ImageAllocatorRelief971.md) was negative on both architectures. This completed draw result supersedes that note's then-future statement that the draw comparison had not run. Neither experiment changes production preview defaults or release acceptance. Volatile classification does not demonstrate reclamation, zero cost, or indefinite stability; full-size images, AppKit display, WindowServer/GPU and other processes remain outside this small synthetic control.

The next proposed experiment is [a disposable signed PNG decoder with actual parent drawing](ImageDecodeHelperDiagnosticPlan.md). It must include decoding, transport, process overlap and cleanup costs before any remedy is considered.
