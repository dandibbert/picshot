# Manual hash candidate comparison

This diagnostic harness compares `full-frame`, `pooled-full-frame`, and `reusable-full-frame` through the complete existing manual-scroll fixture. It does not select a new production default, create installers, or claim a memory fix. It requires the separate `ManualScrollObservationStrategy`/driver patch; the live-capture initializer remains on the original full-frame implementation.

Run `bash scripts/manual-hash-comparison.sh APP NEW_EVIDENCE COMMIT` with an absolute signed app path, a new absolute evidence directory and the exact app source commit. The launcher uses the same executable and worker for three sequential fresh app processes. The strategy is explicitly forwarded in `PICSHOT_MANUAL_HASH_STRATEGY` and injected into every functional/resource verification driver. The prior baseline split matrix is not rerun by this harness.

Each cell preserves the native controls, exact output comparisons, uncertain-seam rejection, pause/retry/move behavior, cancellation and source-file immutability checks. The resource portion keeps 8 warmups + 16 measured cycles interleaving 4K/5K vertical/horizontal profiles, four accepted sources, the original 240-second cooperative resource deadline, and the unchanged 600-second outer app deadline. Capture counts remain observed values: the final comparison requires every strategy's complete capture-count vector to match, rather than assuming faster hashing performed identical work.

The independent legacy output-digest verifier remains in place. Existing large-output digests are exposed as scalar SHA-256 strings without an extra rasterization/hash pass. Comparability requires matching large-output digests and every ordered accepted-PNG byte count/hash, as well as matching executable SHA, source commit, architecture, OS and build mode. PIDs and invocation UUIDs must differ. These are same-executable candidate comparisons; the overlay hash algorithm is not labeled a shipped 0.13 feature.

## Memory and ownership evidence

True process-birth memory is not available from these fixture entry points. Reports explicitly say `processStartMemoryCaptured=false`. The earliest new boundary is the first manual smoke route after AppDelegate startup, before functional verification. It is preserved immediately in `manual-hash-entry.json`, including if later work fails. Additional actual self-task boundaries are after functional/before resource, pre-warmup, post-warmup and final cleanup. RSS/footprint and actual `TASK_VM_INFO`/`TASK_VM_INFO_PURGEABLE` observations remain separate, non-atomic readings. Summaries retain volatile resident/virtual/pmap, compressed/reusable bytes, and signed volatile/nonvolatile/compressed ledgers, with stage deltas.

The original resource JSON payload and strict validator are retained. An explicit `diagnosticHashComparison` extension carries strategy, entry boundaries, runtime identity and 24 matching ownership records. The dedicated checker validates this extension and then passes the unchanged original fields through the existing resource checker. Ordinary non-comparison runs keep the original resource schema.

The normalization workspace is sampled through the candidate driver's short metadata-lock getter. Reusable mode must show its exact one-viewport RGBA buffer bound; the other strategies must report zero persistent workspace. All seven drained pause/recovery/cancel/reset checkpoints and final close require zero workspace. This describes owned scratch storage, not CoreGraphics backing ownership or a leak verdict.

## Failure isolation

`launch.json.launcher.json` records the LaunchServices-owned PID/path, fresh-instance setting, timeout and confirmed termination. A resource timeout or assertion failure is preserved as failed/partial evidence and the next independent strategy still runs once that process has exited. Empty, missing, stale, failed or shortened resource evidence cannot pass. If process exit cannot be confirmed after the outer deadline and termination attempts, later cells are explicitly marked blocked instead of overlapping an unconfirmed live process.

Each cell emits `checked-cell.json`; `comparison.json` is observed only when all three cells completed and their workload/runtime/pixel identities match. Otherwise it is incomplete and the command exits nonzero while preserving every cell's evidence. Fixed strategy order can still confound timing or ambient memory conditions. A low late slope cannot erase a large warmup allocation, and volatile classification is not a reclamation proof.

## Local validation

The new checker/control-flow suite has 11 passing synthetic tests, including continuation after one confirmed failed process and blocking peers after unconfirmed exit. The existing strict resource-checker suite has 58 passing tests. Shell syntax and Python syntax checks pass. Synthetic files and mocked executables in those tests are not native evidence. Swift compilation, candidate pixel tests, and actual three-cell memory outcomes remain for native CI.
