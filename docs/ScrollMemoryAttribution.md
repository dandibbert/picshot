# Manual scroll memory: attribution and vImage integration
Latest integration checkpoint: the ARM direct-conversion comparison at `6d274ecf0dfff8776a2711e8043720045d9390eb` supports selecting vImage through the shared `productionDefault`. Full installer gates and Intel direct-conversion acceptance remain separate; no result below is promoted to installed acceptance for a later source. The earlier investigations are preserved as source-specific history.

## Initial 0361 checkpoint

The actual ARM64 end-to-end run at `0361a7eb1fe9c9ab39732853852b50a6d690a15a` completed its unchanged 8 warmups + 16 measured interleaved 4K/5K, vertical/horizontal cycles in 138.891 seconds. All owned cleanup counters were zero, while settled RSS grew 714,358,784 bytes after warmup. The last three intervals added 42,565,632 / 49,643,520 / 68,403,200 bytes. Physical footprint grew 771,520 bytes. The 1,759 measured RSS/footprint observations had zero failed samples; sampled peaks were 2,011,627,520 RSS / 157,143,680 footprint bytes.

The same ARM source passed 947 focused native tests, then all 1,436 discovered ordinary tests with 1,433 passes and three documented pre-model skips; the separate actual-model stage passed 12 tests. Exact fractional preview pixels, owned-window interaction/close and inspector layout passed. Final ZIP functional work and the resource workload ran, but the old resource checker incorrectly required one latest-viewport range instead of the four adjacent source bands. The script stopped before the DMG phase. The corrected schema does not retroactively establish installer acceptance, and delivery at that checkpoint remained held on the large repeated-capture RSS result.

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

The current-only Swift test compares the copied procedural generator/hash to the production manual algorithms. Baseline-compatible tests cover known quarter-step matches, hash changes, configuration rejection and sampled watchdog failures. Both architectures passed 59 selected native tests at the source below.


## Measured comparison at fda0e7e5

[Run 37661169415](https://github.com/dandibbert/picshot/actions/runs/37661169415), exact source `fda0e7e5c5fbec02f0bd434f3e4811205a12322f`, completed all 13 ARM cells on macOS 15.7.9 (24G830). Each used eight warmup and sixteen measured cycles, for 312 split cycles and 12,024 sampled RSS/footprint pairs, with zero failed samples. The checked matrix confirmed common source hash vectors, identical prepared PNGs, architecture, OS and release build. Current cells preceded the instrumented baseline, so ordering remains a timing confound. This is diagnostic app evidence, not installed ZIP/DMG acceptance.

The current capture-hash control acquired exactly 1,474,560,000 additional volatile-resident bytes during the 32 warmup source normalization/hash intervals. Each 4K source added 33,177,600 bytes and each 5K source 58,982,400 bytes. Source creation added only one other 16 KiB page; subsequent outer pool exits released none of that volatile backing. This localizes the rise to the combined normalization/hash interval but does not isolate which of its two draw/hash calls, context, source conversion or framework cache owns it. A flat measured volatile slope follows about 1.37 GiB of retained backing and is not a low-memory result.

The instrumented baseline hash cell ends at essentially the same volatile total. Its warm-to-final volatile-resident increase of 235,388,928 bytes is exactly matched by a decrease of 235,388,928 in the compressed volatile ledger; volatile virtual size is unchanged at 1,475,870,720 bytes. That is consistent with residency/compression changes in existing backing, not evidence of that much new logical allocation. The hash algorithm in this baseline cell is an added diagnostic control and was not shipped as continuous capture in 0.13.

The shared production acceptance control has unchanged source at the two commits. Current and baseline both finish with 8.75 MiB volatile resident and no measured volatile growth. Their warm-to-final RSS increments are 17.297 and 9.125 MiB respectively. This single paired observation does not attribute that difference to an owned image or a new feature. The separate current detail control retains 228.375 MiB volatile resident after warmup; it does not establish reclaimability.

### Full end-to-end observations

ARM's unchanged full workload completed in 145.2964 seconds, with eight warmups and sixteen measured cycles, four accepted frames and 13 observations per cycle, and zero explicit owners after close. Unlike the split eight-hash cell, it includes rejection, pause/move/retry, asynchronous preview and cancellation. Stage deltas are not additive or workload-identical.

The resource loop runs after functional manual verification in the same process. Its pre-warm boundary already has RSS 818,085,888 / volatile resident 228,720,640 bytes and is not process-cold. Resource warmup adds RSS 238,764,032 / volatile resident 206,766,080 bytes. After warmup, the final increase is RSS 730,906,624 / volatile resident 713,687,040 / physical footprint 575,040 bytes. The final actual volatile-resident total is 1,149,173,760 bytes. Compressed volatile/nonvolatile ledgers remain zero, while volatile virtual size increases 714,244,096 bytes.

The last three RSS increments are 42,565,632 / 49,577,984 / 68,452,352 bytes; actual volatile-resident increments are 42,827,776 / 49,315,840 / 68,648,960 bytes. There are 892 warmup and 2,040 measured sample pairs, with zero failures. Measured sampled peaks are RSS 2,012,938,240 / footprint 157,438,400 bytes. All four profiles are interleaved, so even repeated endpoints for one profile include the intervening profiles. These measurements established actual volatile accounting, not harmlessness, reclamation, a leak verdict or overall memory stability. That diagnostic source did not establish installer acceptance.

### Intel limits

Intel passed the same 59 selected tests and completed the current source-create, capture-hash and PNG-spool cells. Its hash warmup also reached 1,474,560,000 volatile-resident bytes. Stitch-overlap reached the unchanged 240-second cooperative cap at 240.1166 seconds after all eight warmups and 13 of 16 measured cycles. Its 4,822 valid samples remained below sampled ceilings, so this is a time limit and incomplete comparison, not a memory-watchdog failure. Later current cells, all baseline cells and the full Intel end-to-end workload were unrun. No Intel installer acceptance follows from these diagnostics.


## Direct conversion and production integration

The context-pool/reuse comparison at `8cb0c700` did not remove the backing growth: all three ARM strategies added 713,687,040 bytes to the combined volatile ledgers, with differing resident/compressed splits. The full source-scoped accounting is in [ManualHashComparison.md](ManualHashComparison.md).

The subsequent [ARM run 37684339137](https://github.com/dandibbert/picshot/actions/runs/37684339137), source `6d274ecf0dfff8776a2711e8043720045d9390eb`, passed 72 selected native tests and complete same-executable legacy/vImage E2E cells. Every cycle retained 13 captures, four accepted sources, the original 8 warmups + 16 measured cycles, pixel and PNG hash checks, cancellation/cleanup checks, and the 240/600-second deadlines. vImage's absolute smoke-entry → after-functional → post-warmup → final RSS values were 69,599,232 → 915,603,456 → 800,718,848 → 801,898,496 bytes; footprint was 20,842,624 → 37,670,720 → 39,063,040 → 39,554,560. These are post-startup observations, not process-birth memory.

Actual volatile-resident totals at those same vImage boundaries were 0 → 228,065,280 → 74,252,288 → 74,252,288 bytes. After warmup, RSS increased 1,179,648 bytes and footprint 491,520; volatile resident/virtual/pmap and volatile resident/compressed ledger endpoints had zero net change. The legacy control added 704,249,856 bytes to its combined volatile ledgers over the same measured workload. This improvement is not explained by a compensating compressed volatile increase in vImage.

The vImage ledger still cycled between 65,028,096 and 81,723,392 bytes across measured endpoints, with final increments +16,678,912 / −16,695,296 / +8,699,904. It is a bounded observation with interleaved profiles, not a claim of zero allocation or zero change in every interval. There were 1,093 warmup and 2,269 measured sampler pairs, all successful. vImage took 166.753 seconds versus 152.472 for legacy in this run. Cold/functional/pre-resource/warm/final totals and full counter qualifications are recorded in the comparison document.

Normal driver/controller/fixture defaults now resolve through `ManualScrollObservationStrategy.productionDefault` to vImage. Explicit legacy controls remain selectable. Ordinary installed resource runs sample and enforce one normalization workspace no larger than viewport pixels × 4 (at most 96,000,000 bytes) and zero workspace at every drained pause/recovery/cancel/reset and close, irrespective of whether diagnostic JSON is requested. Resource schema 2, existing limits/counts/deadlines and exact-pixel checks stay intact. Native conversion scratch, decoded backing and framework caches are not bounded by that owned-workspace number.

The paired 6d274 artifact still had a legacy production default and is not relabeled as a post-switch installer. Intel direct-conversion status was pending at the ARM checkpoint. New production-source compilation, native tests, real model stages and ZIP/DMG acceptance must pass independently. Synthetic injected providers do not establish live ScreenCaptureKit full-display backing behavior, physical application scrolling, TCC or system-input acceptance, and these measurements do not prove zero leaks or unlimited-duration stability.
