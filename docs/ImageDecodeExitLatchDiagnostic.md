# Opt-in termination-latch comparison

Prepared diagnostic only; native compilation and execution of this candidate are pending. ARM timing-v3 at source 2754b779 measured roughly 67–82 ms inside the existing `waitUntilExit()` call. This comparison measures an alternative completion observation without changing the default decoder, per-launch verifier, child protocol, output bounds or production exit path.

## Run and fixed scope

```sh
scripts/image-decode-exit-comparison.sh --compare /absolute/PicShot.app /absolute/new-evidence-directory
```

The runner first executes the unchanged `--timing-v3` wait arm, then `--termination-latch`, each using fresh parent processes for 4K/5K production and isolated decode cells and the two actual native UI cells. Headless cells retain 2 warmups +12 measured cycles; UI cells retain 2 warmups +4 measured previews and the same debounce/cancel/stale-result scenarios. Each arm prepares its own immutable input/reference; the final checker requires matching source dimensions and PNG/raw hashes across arms. Fixed ordering can expose cache or runner-load differences, so a median difference alone is not proof of causation or a production recommendation.

Two separate 5K candidate probes then cancel or time out a real held post-decode child, verify its raster hash against the reference, require no raw output publication, and prove shared-lease reacquisition after exit/cleanup. They do not add samples to the repeated timing series. They use 20-second cooperative /30-second outer parent bounds, while the existing child 5/6/9-second work/backstop/exit bounds remain unchanged. Both complete six-cell arms retain their existing per-cell bounds; the combined launcher failure envelope is 2,500 seconds plus launcher overhead. Use a separate bounded diagnostic job; no workflow or installer hook is supplied.

Explicit selectors are the existing `PICSHOT_IMAGE_DECODE_LARGE_TIMING=3` plus `PICSHOT_IMAGE_DECODE_LARGE_EXIT=termination-latch`. Other EXIT values are rejected. The selector is propagated by `--termination-latch`; normal `--compare` and `--timing-v3` clear it. New `cancel-after-decode` and `timeout-after-decode` modes require that explicit candidate selector and the 5K profile. The child still uses the signed bundle-relative timing-v3 entry with the original strict v2 stdout and one-frame stderr timing contract.

## Completion and ownership

A scalar-only `ImageDecodeTerminationLatch` is installed before `Process.run()`. Its handler captures the latch, never the Process, controller or image. It records one PID/status/reason/not-running observation and callback entry/publication uptime. Duplicate, malformed, nonfinite or mismatched observations fail validation. A missing callback owns no pending dispatch-group/semaphore entry; launch failure can release both Process and latch.

After the parent observes the owned Process stop running, the candidate waits only within the existing absolute exit deadline for callback publication, continuing bounded pipe drainage. It then verifies the callback against the same still-owned Process, including its current non-running state, PID, exit status and reason. Publication arriving during drainage is rechecked before rejecting the deadline; publication itself must fall within the deadline. A callback alone cannot publish a result or release admission.

The existing terminal sequence/PID/schema, byte caps, stdout/stderr EOF, exit-code and full-pixel validation checks still run. The parent clears the handler and finishes owned job cleanup before releasing the shared admission lease. An unconfirmed child keeps admission retained; any later recovery still validates the owned stopped Process and callback before cleanup. Failed protocol/EOF validation cannot be called a successful observation. No alternate executable, shell, signature cache, helper reuse or child-cap relaxation is introduced.

Apple describes [terminationHandler](https://developer.apple.com/documentation/foundation/process/terminationhandler) as the completion callback, while [isRunning](https://developer.apple.com/documentation/foundation/process/isrunning) can be false both before a successful launch and after termination. The candidate requires the launched-owned-process and matching-callback evidence rather than relying on the boolean alone. Callback publication is recorded inside the final handler bookkeeping; it is not an exact kernel-exit timestamp or proof that every framework callback has unwound.

## Evidence and validation

Candidate reports add `exitObservationStrategy=termination-latch`, a fixed scalar `terminationLatch` record, handler-clear and both EOF flags. Parent timestamps distinguish handler installation, callback-wait start, callback validation and each EOF. The old wait timestamps remain exclusive to the reference arm. Existing child phase Mach readings, terminal write/return timing, parent memory boundaries, full lifecycle time, native queue worst-eight/timeline, pixel hashes and repeated cleanup evidence are retained.

The final `exit-comparison.json` compares three measured isolated routes (4K, 5K, native UI), reports per-launch signature and exit-confirmation timings, and validates the two lifecycle probes. Raw six-cell reports retain the production controls and complete memory/phase records. The checker rejects missing/wrong/duplicate callbacks, absent EOF or cleanup, an uncleared handler, mixed strategy evidence, changed inputs and false cancellation/deadline claims.

Eighteen new native tests cover real fast/nonzero exit, owned termination, launch failure, callback/PID/status validation, missing/duplicate/concurrent publication, object release, a caller-held admission lease, selector bounds and pre-launch cancellation. They are authored, not locally executed. Native object-release checks permit bounded Foundation notification settling after exit; the candidate itself never substitutes a run-loop wait for its callback observation.

Preview output stays 1024×576 /2.25 MiB beneath the 4 MiB production preview ceiling; diagnostic reports keep the 2 MiB cap and process memory watchdogs. Genuine 2× display coverage remains unavailable, and reported backing scale is never simulated. `parentLossVerified=false` remains explicit: early parent death or hard child exit can strand jobs. A successful diagnostic is not a production memory or responsiveness fix.

## CI collection boundary

The opt-in exit-latch workflow keeps its original 60-minute job cap and runs the reference and candidate in separate 25-minute bounded steps, then controlled probes and comparison in three minutes. Compilation, signed packaging and debug-helper setup must pass before observation steps run. A native test failure still fails the job; it does not prevent collection of independent timing observations for diagnosis. Such observations never imply that the native gates or an installer passed. The unchanged Intel GIF readiness assertion is separately instrumented without altering its 3-second readiness or 5-second synthetic-child budgets.
