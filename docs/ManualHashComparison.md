# Manual hash production path and diagnostic comparison

The production and normal verification defaults use `ManualScrollObservationStrategy.productionDefault`, now `vimage-full-frame`, following the bounded ARM comparison below. Explicit legacy/full-frame and context variants remain available for diagnostics. This harness compares those strategies through the complete manual-scroll fixture; it does not create installers or replace the separate installer gates.

Run `bash scripts/manual-hash-comparison.sh APP NEW_EVIDENCE COMMIT [context-reuse|direct-conversion]` with an absolute signed app path, a new absolute evidence directory and the exact app source commit. The optional fourth argument selects an exact ordered suite:

- `context-reuse` (default): `full-frame`, `pooled-full-frame`, `reusable-full-frame`, preserving the original three-cell comparison
- `direct-conversion`: `full-frame`, then `vimage-full-frame`; only these two fresh-process cells run

The launcher uses the same executable and worker for the selected sequential fresh app processes. Unknown modes fail before launch; a matrix with an extra, missing, duplicate, reordered or substituted strategy cannot be accepted. The direct suite compares an explicitly selected legacy control with the vImage path in the same executable, even when vImage is the production default. The strategy is explicitly forwarded in `PICSHOT_MANUAL_HASH_STRATEGY` and injected into every functional/resource verification driver. The prior baseline split matrix is not rerun by this harness.

Each cell preserves the native controls, exact output comparisons, uncertain-seam rejection, pause/retry/move behavior, cancellation and source-file immutability checks. The resource portion keeps 8 warmups + 16 measured cycles interleaving 4K/5K vertical/horizontal profiles, four accepted sources, the original 240-second cooperative resource deadline, and the unchanged 600-second outer app deadline. Capture counts remain observed values: the final comparison requires every strategy's complete capture-count vector to match, rather than assuming faster hashing performed identical work.

The independent legacy output-digest verifier remains in place. Existing large-output digests are exposed as scalar SHA-256 strings without an extra rasterization/hash pass. Comparability requires matching large-output digests and every ordered accepted-PNG byte count/hash, as well as matching executable SHA, source commit, architecture, OS and build mode. PIDs and invocation UUIDs must differ. These are same-executable candidate comparisons; the overlay hash algorithm is not labeled a shipped 0.13 feature.

## Memory and ownership evidence

True process-birth memory is not available from these fixture entry points. Reports explicitly say `processStartMemoryCaptured=false`. The earliest new boundary is the first manual smoke route after AppDelegate startup, before functional verification. It is preserved immediately in `manual-hash-entry.json`, including if later work fails. Additional actual self-task boundaries are after functional/before resource, pre-warmup, post-warmup and final cleanup. RSS/footprint and actual `TASK_VM_INFO`/`TASK_VM_INFO_PURGEABLE` observations remain separate, non-atomic readings. Summaries retain volatile resident/virtual/pmap, compressed/reusable bytes, and signed volatile/nonvolatile/compressed ledgers, with stage deltas. A separately named derived field adds the returned volatile-resident and volatile-compressed ledgers so a shift into compression is visible; that sum is not another kernel field or an ownership claim.

The original resource JSON payload and strict validator are retained. An explicit `diagnosticHashComparison` extension carries strategy, entry boundaries, runtime identity and 24 matching ownership records. The dedicated checker validates this extension and then passes the unchanged original fields through the existing resource checker. Ordinary non-comparison runs keep resource schema 2. Their normalization sampling, nominal workspace bound, all seven drained-release checks and close check are enforced unconditionally; only the extra diagnostic JSON projection is optional.

The normalization workspace is sampled through the candidate driver's short metadata-lock getter. Reusable and vImage modes must show their exact one-viewport RGBA buffer bound; full-frame and pooled-full-frame must report zero persistent workspace. Caller-owned vImage destination storage does not bound its framework conversion/cache allocations. Every ordinary installed-app resource run and diagnostic run samples one owned workspace bounded by viewport pixels × 4, at most 96,000,000 bytes. All seven drained pause/recovery/cancel/reset checkpoints and final close require zero workspace. This describes owned scratch storage, not CoreGraphics backing ownership or a leak verdict.

## Failure isolation

`launch.json.launcher.json` records the LaunchServices-owned PID/path, fresh-instance setting, timeout and confirmed termination. A resource timeout or assertion failure is preserved as failed/partial evidence and the next independent strategy still runs once that process has exited. Empty, missing, stale, failed or shortened resource evidence cannot pass. If process exit cannot be confirmed after the outer deadline and termination attempts, later cells are explicitly marked blocked instead of overlapping an unconfirmed live process.

Each cell emits `checked-cell.json`; `comparison.json` is observed only when every cell in the exact selected suite completed and their workload/runtime/pixel identities match. It records the suite, ordered strategy list and ordering caveat. Otherwise it is incomplete and the command exits nonzero while preserving every cell's evidence. A failed native resource report is recognized before success-schema checks: its exact status/reason, elapsed time, declared deadline, and recorded completed warmup/measured rows remain visible as explicitly unvalidated partial evidence. Those fields never promote an incomplete cell into acceptance. Fixed strategy order can still confound timing or ambient memory conditions. A low late slope cannot erase a large warmup allocation, and volatile classification is not a reclamation proof.

## Native context-reuse result: 8cb0c700

[Run 37676118472](https://github.com/dandibbert/picshot/actions/runs/37676118472), source `8cb0c7003bc2e75859f2b41ba687bd6e937f5ae3`, completed the ARM context-reuse matrix. Both architectures passed 70 selected native tests with zero failures. All three ARM cells completed their unchanged 8 warmups + 16 measured cycles, with matching captured-source and large-output digests, capture-count vectors, executable and runtime identity.

The following exact-byte deltas are post-warmup to final cleanup:

| ARM strategy | RSS | Volatile resident ledger | Compressed volatile ledger | Combined volatile ledgers | Volatile virtual |
|---|---:|---:|---:|---:|---:|
| full-frame | 527,515,648 | 670,351,360 | 43,335,680 | 713,687,040 | 714,244,096 |
| pooled-full-frame | 691,814,400 | 713,687,040 | 0 | 713,687,040 | 714,244,096 |
| reusable-full-frame | 417,366,016 | 520,470,528 | 193,216,512 | 713,687,040 | 714,244,096 |

The actual volatile-resident deltas equal the volatile-resident ledger deltas in this table. Every strategy has identical combined volatile-ledger and virtual growth. Reusable mode's lower RSS/resident value accompanies more compressed backing; this run does **not** establish a backing-memory remedy. Footprint changes were respectively 1,525,440 / 1,263,168 / 1,459,840 bytes. Resource durations were 124.0254 / 123.2584 / 120.3770 seconds; one fixed-order run does not establish a performance improvement.

Intel's functional fixtures passed for all three strategies, but every resource cell reached its original 240-second deadline. They recorded 8 warmups plus only 4 / 2 / 3 measured cycles in strategy order, at 240.03252045 / 240.026264247 / 240.035119159 seconds. The native failure strings were respectively “First source not accepted,” “Moved source not accepted,” and “Stable source 4 not accepted.” These are interrupted stage labels at the global deadline, not completed memory-comparison results. The previous checker obscured these reports as “unexpected object keys”; the new failure path preserves the actual native reason and partial counts while continuing to reject incomplete evidence. Later independent cells ran after each owned process exited.

At the 8cb checkpoint, neither an autorelease pool nor a reused CGContext established a fix; vImage had no native result yet. Those historical binaries retained the full-frame production default. Their evidence is not relabeled as proof for the subsequently integrated default. The next checkpoint below evaluates direct conversion without relaxing the 240/600-second deadlines, work counts, pixel assertions or resource-admission limits.

## ARM direct-conversion result: 6d274ecf

[Run 37684339137](https://github.com/dandibbert/picshot/actions/runs/37684339137), exact source `6d274ecf0dfff8776a2711e8043720045d9390eb`, passed 72 selected ARM native tests and both complete paired E2E cells on macOS 15.7.9 (24G830), release arm64. Both cells used executable SHA-256 `9b815647cc6ac5b48607bdc63c5e325928554d2e390b7ea77da3274a1c64b572`, separate confirmed-exited PIDs, matching source/output digests, 13 captures and four accepted sources in every cycle, and all 8 warmups + 16 measured cycles. All owned cleanup and normalization release assertions passed.

The following are absolute bytes, not growth from an assumed empty process. “Smoke entry” occurs after AppDelegate startup; process-birth memory was not captured. Functional verification runs before the resource workload in each process.

| ARM strategy / boundary | RSS | Footprint | Actual volatile resident | Volatile resident + compressed ledger sum |
|---|---:|---:|---:|---:|
| Legacy / smoke entry | 69,500,928 | 21,072,064 | 0 | 0 |
| Legacy / after functional | 817,872,896 | 38,063,744 | 228,851,712 | 227,278,848 |
| Legacy / pre-resource warmup | 820,592,640 | 40,701,568 | 228,851,712 | 227,278,848 |
| Legacy / post-warmup | 1,064,796,160 | 39,342,080 | 445,054,976 | 444,137,472 |
| Legacy / final cleanup | 1,427,439,616 | 40,785,344 | 954,515,456 | 1,148,387,328 |
| vImage / smoke entry | 69,599,232 | 20,842,624 | 0 | 0 |
| vImage / after functional | 915,603,456 | 37,670,720 | 228,065,280 | 227,278,848 |
| vImage / pre-resource warmup | 921,288,704 | 43,274,048 | 228,065,280 | 227,278,848 |
| vImage / post-warmup | 800,718,848 | 39,063,040 | 74,252,288 | 73,728,000 |
| vImage / final cleanup | 801,898,496 | 39,554,560 | 74,252,288 | 73,728,000 |

The legacy cell added 704,249,856 bytes to its combined volatile ledgers after warmup. vImage's post-warmup-to-final RSS and footprint changes were +1,179,648 and +491,520 bytes, with zero net change in volatile resident, virtual, pmap, resident ledger, compressed ledger, and their combined sum. Its volatile virtual endpoint was 74,678,272 bytes; compressed backing was zero at the post-warmup and final boundaries. Final RSS still includes substantial process/allocator/framework state; this is not zero memory use.

The vImage cycle endpoints varied: the volatile resident ledger ranged from 65,028,096 to 81,723,392 bytes, and the final three increments were +16,678,912 / −16,695,296 / +8,699,904. Therefore the result is bounded cycling in this observed workload, not literal zero in every interval. Profiles are interleaved, so successive endpoints switch profile and same-profile comparisons include intervening workloads.

vImage supplied 1,093 warmup and 2,269 measured RSS/footprint sample pairs with zero failures; measured sampled peaks were RSS 958,513,152 / footprint 131,567,168 bytes. The resource workload took 166.753466 seconds versus 152.471865 for the legacy control. vImage was slower in this run; the fixed ordering and one runner do not establish a universal performance ratio.

This evidence supports the production integration for the tested synthetic pipeline. Intel direct-conversion evidence was still pending at this ARM checkpoint, and full installed ZIP/DMG acceptance remains a separate required gate. No real ScreenCaptureKit crop/backing, physical-display scrolling, TCC, system input, global pressure or leak-free claim follows from these runs. The installed resource loop now checks the same normalization bound and drain contract even without a diagnostic extension.

The helper checker expects the vImage production-default label for new sources. Only exact historical commits `8cb0c7003bc2e75859f2b41ba687bd6e937f5ae3` and `6d274ecf0dfff8776a2711e8043720045d9390eb` retain a source-scoped full-frame-default expectation; both were diagnostic binaries before the default switch. An explicit legacy control in a new binary must still declare that binary's vImage production default.

## Validation

The checker/control-flow suite has 21 passing synthetic tests, including source-scoped production-default checks, exact suite selection, pixel/workload identity, workspace bounds and failure isolation. The unchanged strict resource-checker suite has 58 passing tests. Historical 8cb and 6d274 comparisons retain their original source-scoped labels when replayed. New-source/default integration and complete installers must be validated against their own commit; earlier diagnostics are not substituted for those gates.
