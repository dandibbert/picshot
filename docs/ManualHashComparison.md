# Manual hash candidate comparison

This diagnostic harness compares explicit hashing strategies through the complete existing manual-scroll fixture. It does not select a new production default, create installers, or claim a memory fix. It requires the separate `ManualScrollObservationStrategy`/driver patch; the live-capture initializer remains on the original full-frame implementation.

Run `bash scripts/manual-hash-comparison.sh APP NEW_EVIDENCE COMMIT [context-reuse|direct-conversion]` with an absolute signed app path, a new absolute evidence directory and the exact app source commit. The optional fourth argument selects an exact ordered suite:

- `context-reuse` (default): `full-frame`, `pooled-full-frame`, `reusable-full-frame`, preserving the original three-cell comparison
- `direct-conversion`: `full-frame`, then `vimage-full-frame`; only these two fresh-process cells run

The launcher uses the same executable and worker for the selected sequential fresh app processes. Unknown modes fail before launch; a matrix with an extra, missing, duplicate, reordered or substituted strategy cannot be accepted. The direct suite requires the separately reviewed vImage driver patch, whose normal capture initializer still selects legacy full-frame hashing. The strategy is explicitly forwarded in `PICSHOT_MANUAL_HASH_STRATEGY` and injected into every functional/resource verification driver. The prior baseline split matrix is not rerun by this harness.

Each cell preserves the native controls, exact output comparisons, uncertain-seam rejection, pause/retry/move behavior, cancellation and source-file immutability checks. The resource portion keeps 8 warmups + 16 measured cycles interleaving 4K/5K vertical/horizontal profiles, four accepted sources, the original 240-second cooperative resource deadline, and the unchanged 600-second outer app deadline. Capture counts remain observed values: the final comparison requires every strategy's complete capture-count vector to match, rather than assuming faster hashing performed identical work.

The independent legacy output-digest verifier remains in place. Existing large-output digests are exposed as scalar SHA-256 strings without an extra rasterization/hash pass. Comparability requires matching large-output digests and every ordered accepted-PNG byte count/hash, as well as matching executable SHA, source commit, architecture, OS and build mode. PIDs and invocation UUIDs must differ. These are same-executable candidate comparisons; the overlay hash algorithm is not labeled a shipped 0.13 feature.

## Memory and ownership evidence

True process-birth memory is not available from these fixture entry points. Reports explicitly say `processStartMemoryCaptured=false`. The earliest new boundary is the first manual smoke route after AppDelegate startup, before functional verification. It is preserved immediately in `manual-hash-entry.json`, including if later work fails. Additional actual self-task boundaries are after functional/before resource, pre-warmup, post-warmup and final cleanup. RSS/footprint and actual `TASK_VM_INFO`/`TASK_VM_INFO_PURGEABLE` observations remain separate, non-atomic readings. Summaries retain volatile resident/virtual/pmap, compressed/reusable bytes, and signed volatile/nonvolatile/compressed ledgers, with stage deltas. A separately named derived field adds the returned volatile-resident and volatile-compressed ledgers so a shift into compression is visible; that sum is not another kernel field or an ownership claim.

The original resource JSON payload and strict validator are retained. An explicit `diagnosticHashComparison` extension carries strategy, entry boundaries, runtime identity and 24 matching ownership records. The dedicated checker validates this extension and then passes the unchanged original fields through the existing resource checker. Ordinary non-comparison runs keep the original resource schema.

The normalization workspace is sampled through the candidate driver's short metadata-lock getter. Reusable and vImage modes must show their exact one-viewport RGBA buffer bound; full-frame and pooled-full-frame must report zero persistent workspace. Caller-owned vImage destination storage does not bound its framework conversion/cache allocations. All seven drained pause/recovery/cancel/reset checkpoints and final close require zero workspace. This describes owned scratch storage, not CoreGraphics backing ownership or a leak verdict.

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

Neither an autorelease pool nor a reused CGContext is established as a fix. The vImage direct-conversion suite is a separate diagnostic candidate; it has no native result at this checkpoint. No production default, 240/600-second deadline, original work count, exact-pixel assertion or resource-admission limit is relaxed.

## Local validation

The checker/control-flow suite has 18 passing synthetic tests, covering both exact suites, unknown/extra/substituted/reordered strategies, vImage workspace bounds, native timeout reporting, continuation after one confirmed failed process, and blocking peers after unconfirmed exit. The unchanged strict resource-checker suite has 58 passing tests. Replaying the three actual 8cb Intel failure files yields their native reason and exact 8+4/2/3 row counts, with a failed exit status in every case. Shell and Python syntax checks pass. Synthetic test data and mocked processes are not native memory evidence; vImage compilation, pixel tests and complete direct-suite runs remain for native CI.
