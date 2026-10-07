# Manual scroll memory: attribution pending

The actual ARM64 end-to-end run at `0361a7eb1fe9c9ab39732853852b50a6d690a15a` completed its unchanged 8 warmups + 16 measured interleaved 4K/5K, vertical/horizontal cycles in 138.891 seconds. All owned cleanup counters were zero, while settled RSS grew 714,358,784 bytes after warmup. The last three intervals added 42,565,632 / 49,643,520 / 68,403,200 bytes. Physical footprint grew 771,520 bytes. The 1,759 measured RSS/footprint observations had zero failed samples; sampled peaks were 2,011,627,520 RSS / 157,143,680 footprint bytes.

The same ARM source passed 947 focused native tests, then all 1,436 discovered ordinary tests with 1,433 passes and three documented pre-model skips; the separate actual-model stage passed 12 tests. Exact fractional preview pixels, owned-window interaction/close and inspector layout passed. Final ZIP functional work and the resource workload ran, but the old resource checker incorrectly required one latest-viewport range instead of the four adjacent source bands. The script stopped before the DMG phase. The corrected schema does not retroactively establish installer acceptance, and delivery remains held on the large repeated-capture RSS result.

That run did not record `TASK_VM_INFO_PURGEABLE`. The RSS/footprint gap cannot establish purgeability, reclaimability, a leak verdict, or stability. Zero explicit owners and deleted spool directories establish that particular cleanup, not release of all framework backing.

## What the source establishes

The exact accepted baseline is `fa4cb0ad742e89c9235cfea2eef6b5d7840a78a9`. Its [ScrollSequenceImageIO.swift](https://github.com/dandibbert/picshot/blob/fa4cb0ad742e89c9235cfea2eef6b5d7840a78a9/Sources/PicShot/ScrollSequenceImageIO.swift) has Git blob SHA `ab225f841db976c2455ecb2cfd715f74f5d43dbb`, exactly matching the current file's computed Git blob SHA. The entire controller `accept(_:)` implementation and `ScrollImageIO.readImage` / `luminance` implementations also match.

Consequently these potentially significant operations already existed in 0.13:

- Native bounded PNG encoding of each accepted source
- Full stored-PNG decoding and rasterization during immutable overlap checks, including luminance and bounded color-tile draws
- An 800-pixel overview rebuilt after each acceptance, decoding and drawing every contributed source; four monotonic accepts cause 1+2+3+4 source thumbnails

The manual RGBA observation and sampled detail renderer are new. The current end-to-end fixture also creates five distinct synthetic viewports (four accepted and one rejected), repeatedly hashes stable samples, exercises pause/retry/cancel, and navigates detail. Every measured run reported 13 captures/sampled frames. Thus a large RSS delta is not sufficient to attribute the growth specifically to the new preview or capture code.

Earlier small-image backing studies found actual volatile-accounting growth for several decode-and-draw workloads. Their dimensions, work counts, application sources and sometimes runtime environments differ; they motivate the decode/draw hypothesis, but they are not the requested 0.13/0.14 matched runtime comparison.

## Separate diagnostic comparison

Use one process per cell and one separate input-preparation process. The common diagnostic overlay compiles against both exact pinned production bases without importing any new manual-capture classes into the baseline. Stamp both production and overlay commits, preserve original/file overlay hashes in the build manifest, and record the executable SHA-256. The baseline is labeled “fa4cb0ad production code + diagnostic overlay,” never the delivered 0.13 binary.

Each cell retains eight warmups and sixteen measured cycles interleaving the same four large profiles, a 240-second cooperative deadline, 150 ms settles, and 50 ms RSS/footprint sampling. The parent polls sampled peaks every 50 ms, requests cancellation, and drains the one sequential workload on failure or a 3 GiB RSS / 512 MiB footprint ceiling. These ceilings are sampled watchdogs, not allocation quotas; the separate 600-second launcher handles a noncooperative native call. No global pressure, purge, live capture, TCC, network or settings change is involved.

| Cell | Per-cycle work | Baseline available |
|---|---|---|
| source-create | Four identical original procedural viewports, sequential release | Yes |
| capture-hash | Same four sources, two draw/hash observations each | Yes, explicitly an isolated diagnostic algorithm |
| png-spool | Same four sources and four production PNG writes | Yes |
| stitch-overlap | Same four sources, four luminance conversions, three matches/overlap validations against prepared PNGs | Yes |
| overview | Production overview after 1/2/3/4 prepared sources | Yes |
| detail | Two fixed beginning/end calls to current production sampled renderer | No |
| shared-accept | Four real pinned-controller accept calls, controller close and spool verification | Yes |

The common cells are fixed accepted-equivalent workloads. They intentionally omit rejected-candidate, coordinator, cancellation, and variable UI-job work and do not replace or reproduce all operation counts of the original end-to-end fixture. The detail requests are fixed direct renders, not identical asynchronous UI job counts. The shared controller starts at its default fit view; current detail scheduling requires zoom greater than one.

Every existing scalar RSS/footprint boundary is accompanied by real self-task `TASK_VM_INFO` and `TASK_VM_INFO_PURGEABLE`, including status, returned size, unsigned fields and signed ledgers. Stages include before source creation, source alive, after operation with explicit extended source lifetime, pool exit, and settled cycle cleanup as applicable. Reports retain only bounded scalar metadata. Reader cells use the same separately prepared PNGs in both builds, verify file hashes before and after, and expose the ordered identities for the matrix checker.

Interpret current versus baseline only after matched architecture, OS, toolchain, build configuration, profile order, source hashes and overlay are verified. Compare source-only with source-plus-hash/encoder, compare reader-only stages, and compare the real shared acceptance cells. Report observed accounting fields separately; additive attribution is not guaranteed because stages can share caches/backing. A stage-local increase is a lead to investigate, not proof of object ownership.

## Validation status

The Python checker and nine synthetic mutation tests pass in the Linux editing workspace. They reject missing accounting, failed calls, unqueried standard-flavor purgeable zeros, sampler gaps, ceiling violations, changed provenance, reduced work counts and missing cleanup. Returned purgeable zeros and signed negative ledger values remain valid observations. Growth is reported without a memory-stability pass or leak label.

Swift source and tests require the native build. The current-only Swift test compares the copied procedural generator/hash to the production manual algorithms. Baseline-compatible tests cover known quarter-step matches, hash changes, configuration rejection and sampled watchdog failures. No new native memory results are claimed in this document.
