# Image backing memory attribution

Diagnostic checkpoint, 2026-10-06. These observations are **not PicShot 0.9 release acceptance**, a production memory fix, a leak/no-leak verdict, or proof of zero memory cost. The newer `e4e41ba` app remains subject to its separate acceptance gates at this checkpoint.

## Evidence and workload

The final comparison is source [`14c09d510247ae700ccdf143994d75b0cbb5f057`](https://github.com/dandibbert/picshot/commit/14c09d510247ae700ccdf143994d75b0cbb5f057), [run 37541917737](https://github.com/dandibbert/picshot/actions/runs/37541917737). Both native ARM64 and Intel artifacts contain **27 completed controls**, each in a fresh app process, on macOS 15.7.9 (24G830). Look for `PicShot-Backing-arm64-14c09d5…` and `PicShot-Backing-x86_64-14c09d5…`; the artifact IDs are `11449671047` and `11449028425`. GitHub artifacts have retention limits.

Each standard control uses an original synthetic **768×576** image, **2 warmups + 12 measured cycles**. Two separately labeled AVIF controls use **2 + 48**. Their encoded inputs come from a separate preparation process. One tightly packed RGBA reference buffer is **1.6875 MiB**; returned image dimensions and stride are also reported. PDF uses an image-sized single page, not arbitrary paper dimensions.

The original [`71b2f4e32cf99508e3efef69d6b5b30ae396b424`](https://github.com/dandibbert/picshot/commit/71b2f4e32cf99508e3efef69d6b5b30ae396b424), [run 37532815863](https://github.com/dandibbert/picshot/actions/runs/37532815863), motivated this investigation: Intel export/decode workloads added approximately 19–20.5 MiB RSS, and combined workloads approximately 40 MiB, despite much smaller footprint changes. Use the completed ARM retry artifact `11445259977`, not the earlier partial ARM artifact; Intel is `11445483014`.

Important distinctions:

- Original codec `decode-only` uses **full ImageIO decoding**, fresh encoded Data, decoded-pixel rasterization, and reference comparison. It is not a thumbnail-only decoder test
- New full-decode controls separate reused versus freshly read Data and optional decoded-pixel raster/digest work
- Production preview uses bounded ImageIO thumbnails for still images and CGPDFDocument rendering for PDF. Native export includes its production verification and preview
- Synthetic source creation, snapshot copying, and raster/digest of a persistent synthetic reference each have separate controls

## What the measurements mean

RSS and physical footprint are sampled continuously at 50 ms; named boundaries additionally record self-task `TASK_VM_INFO` and `TASK_VM_INFO_PURGEABLE`. The latter explicitly queries volatile resident/virtual/pmap accounting. Ordinary `TASK_VM_INFO` does not query those fields, so its unqueried zero values are omitted. Returned struct sizes and kernel status are checked; missing observations remain missing. See Apple's [task_info header](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/mach/task_info.h) and [implementation](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c).

These calls are separate, not atomic. The report includes internal/external/reusable/compressed bytes and signed purgeable/media/graphics ledgers. Small changes also include retained scalar reports and framework activity. GPU, WindowServer, other processes, and instantaneous peaks are outside this accounting.

## Results across the 27 controls

The following are **settled volatile-resident changes after warmup**, in MiB. ARM's extra 0.015625 MiB is one 16 KiB page; Intel totals below are exact.

| Controls | Cells | ARM64 | Intel |
|---|---:|---:|---:|
| Source creation, snapshot, synthetic-reference raster/digest | 3 | 0 to 0.015625 | 0 |
| PNG/JPEG/BMP/WebP full decode; WebP fresh-Data full decode | 5 | 0 to 0.015625 | 0 |
| PNG/JPEG/BMP/WebP previews; PNG/JPEG/BMP native exports | 7 | 20.25 to 20.265625 | 20.25 |
| PDF preview, native export, independent page render, fresh-Data preview | 4 | 20.25 to 20.265625 | 20.25 |
| WebP full decode plus raster, reused or fresh Data | 2 | 20.25 to 20.265625 | 20.25 |
| PNG/WebP preview with source-local cache removal | 2 | 20.265625 | 20.25 |
| AVIF preview/full decode, 12 or 48 cycles | 4 | 0 | 0 |

For the accumulating groups, all final three volatile-resident increments are **1.6875 MiB per cycle on both architectures**. Footprint does not show that same per-buffer slope. Intel's non-AVIF footprint increases remain below 0.65 MiB over 12 cycles; ARM's largest is approximately 1.53 MiB for BMP native export. RSS is noisier, particularly on ARM.

Fresh Data alone does not reproduce the accumulation; drawing/rasterizing the decoded WebP does, with either Data lifetime. Therefore bypassing thumbnails with full decode is not established as a rendering-lifetime fix. PDF rendering reproduces the pattern without the ImageIO thumbnail API.

### AVIF: warmup, 48 cycles, and delayed sample

Changes below are relative to the post-warmup baseline, at the last measured cycle:

| Architecture / workload | RSS MiB | Footprint MiB | Nonvolatile purgeable ledger MiB |
|---|---:|---:|---:|
| ARM64 preview | −2.0625 | +7.078125 | +6.75 |
| ARM64 full decode | +0.015625 | +7.265625 | +6.75 |
| Intel preview | +0.832031 | +0.808594 | 0 |
| Intel full decode | +0.136719 | +0.851562 | +0.003906 |

ARM's nonvolatile ledger reaches 7.484375 MiB after warmup, adds 3.375 MiB in each of measured cycles 1 and 2, and has no further sustained increase through cycle 48. Temporary 1.265625 MiB excursions reverse on the next cycle. During the additional final **0.5-second settle**, both ARM workloads drop **6.75 MiB** from this ledger, back to the post-warmup level, with a corresponding footprint drop. Their remaining footprint increases are approximately 0.34 and 0.52 MiB.

Intel's preview ledger is 2.441406 MiB after warmup and unchanged through the delayed sample. Full decode starts at 4.128906 MiB and adds only one 4 KiB increment at cycle 18. Final-three-cycle ledger increments are zero for both architectures. This demonstrates architecture- and time-dependent accounting, not unlimited-run stability.

## Cache removal did not reclaim the preview accumulation

The diagnostic thumbnail variant preserves production dimension/stride limits and calls [`CGImageSourceRemoveCacheAtIndex`](https://developer.apple.com/documentation/imageio/cgimagesourceremovecacheatindex(_:_:)) once while its source and image are alive. This API returns **Void**, not a released-byte result.

Across every warmup and measured invocation on both architectures, the immediate volatile-resident and nonvolatile-ledger deltas around the call are zero. The normal 1.6875 MiB late-cycle accumulation remains, including after the final delay. Thus this experiment supplies **no preview-reclamation evidence**. The distinct delayed AVIF decrease above must not be presented as reclamation of the accumulating PNG/WebP/PDF preview backing.

## Reading and extending the evidence

Inside each artifact, `evidence/image-backing/<format>/<mode>/image-backing-<format>-<mode>.json` contains warmups, cycles, live/pool-exit/settled boundaries, and the delayed sample. The 48-cycle files are under `extended-avif/`; they reuse `installed-768x576` prepared inputs. `matrixTier`, `profile`, and `inputProfile` distinguish these scopes. A status of `observed` means the diagnostic completed, not release acceptance.

A possible **future, unexecuted** self-only experiment is a wait-only control versus one `malloc_zone_pressure_relief(NULL, 32 MiB)` call after the same 2+12 PNG previews and all workload pools have exited. Apple's [public allocator API](https://github.com/apple-oss-distributions/libmalloc/blob/main/include/malloc/malloc.h) defines best-effort relief across the process's malloc zones and a reported byte count. The goal is not a hard cap, and framework-managed backing may be unaffected. Keep the outer process deadline and make only one relief call. Record its return, elapsed time, RSS/footprint and backing fields immediately and after 0.5/2 seconds; then separately verify subsequent rendering pixels and latency. Attribution requires measured accounting changes, not the call or return alone.

No global pressure, huge allocation, permission/security change, or allocator relief was used for this checkpoint. Do not substitute `VM_PURGABLE_PURGE_ALL`: [XNU dispatches it to a global purge](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/vm/vm_map.c), even when the supplied task is self. Volatile classification is not proof of reclamation or zero cost. Maximum-size/full-screen inputs, other OS versions, longer use, and a production remedy remain unproven; the 4 MiB preview limit and other production resource gates are unchanged.
