# Historical diagnostic 138 and 143 outcomes and failed ARM build 145

These source-qualified records are historical. None is a build 145 acceptance or a replacement for the unchanged 134–136 history.

## Build 138 failed its installed-default gate

Source `6dca7272e4484fc3a2309bd566c65bbf049a606d`, tree `7849601ec46c9928f712535cae29d0592a1ed49c`, [run 37898862351](https://github.com/dandibbert/picshot/actions/runs/37898862351), [ARM job 113716466642](https://github.com/dandibbert/picshot/actions/runs/37898862351/job/113716466642). Artifact 11602982457: 17,874,065 bytes, SHA-256 `ff0539be4ffbd59e50e69c8cff680ab39682115fdb8fcf6e46ca6f2e35a55ed7`; 559 extracted files, safe paths and CRCs checked in the local independent audit.

The raw no-override owned-sRGB8 report completed two warmups and eight measured cycles, 170 actions, 130 checkpoints, 70 phase timings and 40 persisted versions. One of the 30 required released checkpoints failed: cycle 5 `group-hidden-released` still had one 15,198,544-byte provider, 18 allocations versus 17 releases. The checkpoint's tracked owners/jobs were clear. Every separately recorded cycle-end balanced, including cycle 5 and final cycle 10; final 40 allocations/releases and 607,941,760 allocated/released bytes balanced. The intermediate failure remains real. Cumulative counts do not identify a particular provider's callback time or exact private holder.

The unchanged raw checker reproduces that failure in normal and optimized Python. The owned measured PID exited without forced termination, but preflight prevented the independent post-exit output decoder from running. Metadata, archived hashes, certified goldens and broad ZIP/DMG subsets do not replace the missing measured-output decoding. Model discovery/logs showed 12 passes; no exhaustive native suite or Intel job ran in diagnostic 138.

Historical RSS / physical footprint in MiB:

| Endpoint | RSS | Footprint |
| --- | ---: | ---: |
| Entry | 67.375 | 19.643 |
| After two warmups | 413.313 | 91.971 |
| Last measured cycle | 417.453 | 93.143 |
| Final | 417.609 | 90.753 |
| Warmup to final delta | +4.297 | −1.219 |
| Sampled peak | 685.750 | 292.409 |
| Kernel peak at final | 693.922 | 311.737 |

These remain failed-run observations, not remediation or stability evidence. Diagnostic artifacts omit the executable and installer ZIP/DMG bytes; native-reported identities cannot be called independently rehashed installer bytes. No accepted or delivered installer follows.

## Build 143 failed two of 32 diagnostic native cases

Source `8fbc38d6a95409a9d726c173147addb1ab46b380`, tree `f918035f8768f580e490356f4df54cda2e61da63`, [run 37912326966](https://github.com/dandibbert/picshot/actions/runs/37912326966), [ARM job 113760176191](https://github.com/dandibbert/picshot/actions/runs/37912326966/job/113760176191). Artifact 11607588206: 98,964 bytes, SHA-256 `8989cd35b12735ece76c96cb15eb4eadfe98d47beef05d1abff234a21d69fec5`, 18 safe extracted files. Normal and optimized audit replay agree.

Discovery found 1,798 methods in 205 classes; the selected diagnostic ran 32, with 30 passes, two failures and no skips. Six provider-retirement tests passed. The new readiness fixture compared `/private/var` with `/var` as unequal strings; the original cross-format recovery test rejected readiness because its sole emitted 0.5 progress did not satisfy the production parser's required first value 0. The wrapper exited normally with 1 in 35.272 seconds under the unchanged 420-second cap; native test time was 31.386 seconds. This was not a launch-timeout finding. Neither cross-format recovery branch completed successfully.

Model files downloaded, but model execution, installed preflight, ZIP/DMG smoke and installed-default gates were skipped. There was no installed-default attempt. Sidecars/build metadata do not supply the absent app and installer bytes. This diagnostic remains failed and unaccepted.

## Build 145 ARM failed the full run

Source `f991c23aaa60469db0e2dc77cb94198d0dc74c08`, tree `2347fb7fe45cf809e4cd6aa43fc2426a1fbff7b1`, [run 37915896096](https://github.com/dandibbert/picshot/actions/runs/37915896096), started 2026-10-09 10:10 UTC. The publication manifest binds 710 source files. GIF fixture changes require a complete request and closed readiness marker, emit initial 0 then distinct readiness 0.5, and compare real directory identity. A new regression uses the actual production pipe parser. FIFO fixture readiness retries only ENXIO/EINTR while the same owned process remains live and inside its existing deadline.

All 271 `Sources` files and original `VideoTrimTests.swift` are unchanged from frozen 143. Workflow changes run ordinary full ARM and Intel validation, preserve 420 seconds per native process, and give Intel's existing four-process stages their complete aggregate allowance. Portable fixture/routing checks are not native test discovery or installed results.

The inherited retirement measurement contract is product certificate `editable-product-resource-v3`, installed-default `editable-product-installed-default-v2`, native schema 1. It preserves the first weak/job-drained counters and separately requires balanced providers inside two seconds, with 10 ms polling inside the original 300-second native deadline. Thirty-one ordered observations are required. This changes the observation endpoint and does not claim a product memory fix or retroactively pass build 138.

[The exact ARM final audit](Production145ARMNotAccepted.md) records 1,615 full-suite passes, two permitted model-fixture skips and 182 methods lacking completion evidence after process3 reached 420.040 seconds. Focused 1,259/1,259 and early UI/recovery pass, but models/final installed/default resources and installer uploads were skipped. ARM145 is terminally unaccepted. Later independent diagnostics may use immutable145 product source with separate workflow identity; they do not establish release acceptance. Latest delivered ARM remains 0.15.1/build111; Intel is classified separately and its delivered baseline remains 0.11/build69.
