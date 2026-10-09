# Build 133: bounded actual product work supports an owned-drawing candidate

[Source a4c3d12836ceae8c905b6f2675ddb832c08b5684](https://github.com/dandibbert/picshot/commit/a4c3d12836ceae8c905b6f2675ddb832c08b5684), [run 37875423363](https://github.com/dandibbert/picshot/actions/runs/37875423363), completes the independently verified actual-product comparison. The existing owned-sRGB8 drawing path substantially reduces resident growth for this workload, with higher physical footprint. This supports a production-default candidate for eligible formats; the experiment itself does not qualify an installer or establish unlimited-duration stability.

## Exact work and limits

Each fresh measured app performs two warmups and eight measured 3840×2160 cycles: edit/undo, native crop, actual history save/close/reopen, pin, annotation hide/show, group hide/show, Space editing, Apply and close. The seven-layer seed and history/group entry calls are programmatic; owned AppKit controls and responder events perform the interactions. This is not desktop capture, physical input, real TCC, Retina, multiple monitors or thumbnail-grid coverage. History and pin retention quotas are one.

Each cell completes 170 actions, 130 state/memory checkpoints, 70 phase timings and 40 committed versions. Both measured apps exit before either independent decoder starts. The two decoders compare all 96,752,288 premultiplied sRGB RGBA8 bytes, including alpha, across original/base/seven/eight outputs in each cell. Outputs also match each other byte-for-byte. Certified historical hashes anchor the goldens; measured outputs are not their own reference. Original/base identity, immutable pin original, crop, all layer geometry/styles and metadata relationships remain exact. Only declared UUID fields and the new eighth annotation's bounded session date normalize.

## Full memory accounting

Values are RSS / physical footprint in MiB. Cold cycle is also the first warmup; it must not be added again to the two-warmup delta.

| Observation | Reference | Owned-sRGB8 |
|---|---:|---:|
| Native entry | 66.391 / 19.596 | 66.750 / 19.721 |
| Before warmups | 87.812 / 40.018 | 88.500 / 40.471 |
| Cold released endpoint | 475.781 / 57.706 | 410.766 / 86.659 |
| Cold entry-to-release delta | 409.391 / 38.110 | 344.016 / 66.938 |
| After two warmups | 572.250 / 58.863 | 411.922 / 87.565 |
| Eight measured cycles delta | 166.672 / 3.032 | 0.594 / 2.703 |
| Final cleanup delta | 0.156 / −1.203 | 0.219 / −1.141 |
| Absolute final | 739.078 / 60.691 | 412.734 / 89.128 |
| 50 ms sampled peak | 1004.109 / 277.457 | 662.109 / 275.706 |
| Kernel peak through final reading | 1031.922 / 281.535 | 689.000 / 310.394 |

Candidate final RSS is 326.344 MiB lower, but final footprint is 28.437 MiB higher and kernel footprint peak is 28.859 MiB higher. Its substantial cold retained cost is included. A lower sampled footprint maximum does not erase the kernel peak.

Reference measured released RSS increments are +60.641, +63.234, +32.031, +0.516, +8.469, +0.234, +0.781 and +0.766 MiB. Candidate increments are −2.797, +0.250, +0.406, +1.031, +0.797, +0.359, +0.328 and +0.219 MiB. Candidate endpoints span 409.125–412.516 MiB; there is no repeating retained 31.641 MiB 4K-raster step in its measured window. This is bounded evidence, not a zero-RSS or private-backing-release claim.

Final volatile resident/ledger values are 552.547/542.141 MiB reference and 205.453/195.047 MiB candidate. All eight counters, full standard/purgeable dictionaries and per-phase observations remain in the raw evidence. These overlapping categories are not summed or dismissed as free memory. Fifty-millisecond sampling can miss transients, and self-task accounting does not attribute WindowServer/GPU costs. The final report serialization follows finalMemory, so its last transient peak is not claimed captured.

## Ownership and observation cost

Every released cycle has zero live editor/pin/view graphs, attached windows, known rasters, undo/preview/base owners, reservations, queues, export sessions and owned descriptors. All five run-level owners survive the repeated work and retire at final cleanup. Both cells perform 100 native final renders, 270 successful reference effect patches and 40 completed projections. Only input drawing strategy differs.

Candidate's 40 owned allocations, callbacks and deallocations balance at 607,941,760 bytes, with zero remaining active bytes. Peak owned buffers are 28.989 MiB. This proves retirement of explicit buffers, not private framework caches. Maximum observed identity/stride raster accounting is 109.416 MiB in both cells; admission estimates are not process memory limits.

Each app streams 200 committed versions, approximately 22.52 MiB, through 64 KiB buffers and retains 55 unique evidence files, approximately 0.94 MiB. Hashing, copies and scalar report serialization stay in measured costs. There are no in-process duplicate reference raster renders or pixel-oracle decodes, but no pure-product-RSS estimate is claimed. Thumbnail-grid UI is unexercised; pin cache is zero and the history cache's observed cost is unavailable, with its 24 MiB policy disclosed.

## Timing and qualification

Reference/candidate cold cycles take 3.739/4.190 seconds. Measured-cycle medians are 3.422/3.305 seconds; full native intervals are 36.282/34.564 seconds. These close timing differences are not a speed claim. Open/reopen/group-show/Space timings include 150 ms settling; output actions await durable callbacks and job drain. They are semantic completion times, not first-painted-frame or physical-input latency. Reverse-order replication would strengthen comparative timing confidence, but is not a new blocking gate for the large within-run RSS result.

All five distinct app PIDs and two decoder PIDs, commands, raw reports, source, executable, plist and output identities verify. Normal and optimized checker replay reproduce identical results. The actual ARM executable has 21,438,544 bytes and SHA256 `63112ac3e262407d7bad464d5e8e42c5ce2241ec23bb12e5ed28dad5d6b11a72`; plist binds version 0.16.0/build 133. CI signature checks passed; independent Linux review verifies archived bytes rather than rerunning codesign. Signing remains ad-hoc and unnotarized.

Both architectures pass 379 methods from 1,782 discovered. Dedicated 80 methods overlap that coverage. Separate failure guards retain 24 cases, 432 refusals, 48 cache failures, 24 releases and 12 balanced retry projections. All processes finish without forced cleanup under unchanged 300/600/620-second app bounds. The full outer comparison takes 101.118 seconds. Focused/guard archive binary and retired-payload omissions remain explicit.

## Production candidate

The next candidate changes only the existing drawing default. Original and model-source images remain untouched. Supported sRGB8 layouts use bounded owned drawing; 16-bit, Display P3, linear/device and other unsupported profiles retain the native reference fallback. Conversion failures remain fail-closed. Native final storage, effects, all resource limits, editable persistence and the 0.15.1 output-safety fix remain intact.

Actual no-override execution from the ZIP-installed app, the full correctness/failure fixtures, model checks and both installer startup paths still need to pass for the new source. The previous diagnostic source did not change production defaults, and its accepted evidence cannot be relabeled as installed-default qualification. Latest delivered ARM remains 0.15.1 until that separate handoff.
