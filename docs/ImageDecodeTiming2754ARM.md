# ARM timing-v3 result at 2754b779

The previously unresolved post-response interval is mainly spent inside the parent's `Process.waitUntilExit()` call. Child terminal sending and return are sub-millisecond. This identifies a measured API boundary, not a proven safe optimization or kernel-exit time.

[Source 2754b77954415a8273c14a7fe5245330bec39996](https://github.com/dandibbert/picshot/commit/2754b77954415a8273c14a7fe5245330bec39996), [run 37602641265](https://github.com/dandibbert/picshot/actions/runs/37602641265), [ARM job 112730667497](https://github.com/dandibbert/picshot/actions/runs/37602641265/job/112730667497): 134 selected native tests passed, followed by the v1 and instrumented v3 comparisons. Artifact 11473976958 was independently checked against its 4,596,130-byte size and SHA-256 `7eb9bf2541155aadeb93fe98384cea7e9b276f36ecaf5ab071a4fc09a6c4f0cd`, then safely extracted as 57 entries / 15,731,644 uncompressed bytes. The exact-source checker accepts all six v3 cells.

## Where the exit interval is spent

Values are medians in milliseconds, using twelve measured headless cycles or four measured native UI previews after two warmups. Separate medians must not be summed as one representative cycle.

| Isolated route | 4K headless | 5K headless | 5K native UI |
|---|---:|---:|---:|
| Terminal `writer.send` | 0.130 | 0.193 | 0.133 |
| Send completed → diagnostic run returned | 0.011 | 0.011 | 0.013 |
| Timing frame prepared → parent first observes not running | 12.876 | 7.852 | 18.668 |
| First not-running observation → wait call starts | 0.009 | 0.013 | 0.013 |
| **Inside `waitUntilExit()`** | **67.451** | **68.511** | **81.662** |
| Response prepared → parent confirms exit | 80.509 | 81.695 | 100.482 |
| Per-launch signature validation | 136.997 | 139.030 | 121.887 |

The maximum measured exit-wait duration is 73.748 ms at 4K and 92.156 ms at 5K headless. The terminal send includes its encoding/locking/writing cost. The separate timing frame is prepared only after run and deferred cleanup return; its own later stderr serialization/write can add observation overhead, bounded by the 50 ms writer deadline.

Terminal receipt timing is not simply transport latency: 8/12 4K terminal frames and 4/12 5K frames were read after the exit wait, while the other frames were read before it. The parent stops draining during that synchronous wait. The v3 record validates both legal orders; a late receipt cannot be attributed wholly to child sending.

Apple documents that [waitUntilExit](https://developer.apple.com/documentation/foundation/process/waituntilexit()) checks running state and polls the current run loop until completion. A [terminationHandler](https://developer.apple.com/documentation/foundation/process/terminationhandler) is invoked on task completion, but its block is not guaranteed fully executed before the wait returns. The observed timings do not establish Foundation's internal cause, an exact kernel reap time, or that the entire interval can safely be removed.

## Native main-queue intervals

Both arms still exceed the 100 ms diagnostic flag, but their worst intervals occur outside the four steady previews:

- Isolated maximum **125.518 ms** spans setup, source construction (53.284 ms overlap), controller/snapshot construction (48.564 ms), and the start of the coarse warmup phase. It finishes just before the first preview control action is handled, so it is not that preview's PNG decoder delay
- Isolated subsequent large intervals are controller construction → cancellation scenario (88.293, 62.729 and 48.298 ms) and evidence capture → cleanup (77.172 ms)
- Control maximum **122.605 ms** is labeled first warmup, but its queued time is **3.090 ms after the first recorded native draw**. This does not prove that the PNG decoder or the draw call itself took 122 ms. Another 115.443 ms interval spans initial source/controller setup
- The largest sampled acknowledgements wholly within steady-preview phases are **9.900 ms control / 8.229 ms isolated**. The retained worst-eight records contain no larger interval overlapping those steady phases in this run

The probe has one outstanding callback, 256/418 acknowledged samples, zero callbacks outstanding at completion, no timeline overflow and no invalid timestamps. Only the worst eight intervals are retained; this is not a complete trace of every callback or a physical-input/scanout measurement. Source/controller labels are coarse brackets, and overlap is not causal proof. `derived-timing.json` retains exact timestamps and all phase overlaps.

Median request-to-native-draw is **250.853 ms control / 526.051 ms isolated**. Thus a responsive steady main queue does not make isolated preview completion fast. Actual window backing remains **1×** in both arms; no Retina coverage is claimed.

## Memory, lifetime and limits

At both 4K and 5K, the control again adds exactly **54 MiB volatile resident** over twelve measured actual draws; isolated parent volatile growth is zero. Isolated parent RSS/footprint still increases **8.625/0.969 MiB at 4K** and **8.156/0.578 MiB at 5K**. Median full lifecycle is 314/324 ms isolated versus 57/73 ms control. These are process-specific measurements, not total-system reclamation or a production memory fix.

All **37 launched v3 children** have valid single timing frames, unique PIDs, confirmed exit, owned cleanup and admission release. One additional UI worker cancels during signature validation before child launch. Both UI arms verify the requested cancellation/stale-result scenarios and release their controllers. The isolated UI releases all eight owned providers, with zero live bytes and a one-raster peak. Exact pixels and fixed 1024×576 / 2.25 MiB preview output remain verified.

`parentLossVerified=false` remains explicit. Early parent death or hard child exit can strand files. Per-launch signature/path checks and independent installer gates remain unchanged. Intel has not produced timing observations for this source: its first attempt stopped on the pre-existing readiness assertion described separately; an unchanged retry has been requested after the first workflow attempt completed.

## Smallest safe next experiment

Use a **diagnostic-only 5K comparison**, two warmups plus twelve measured cycles per fresh parent, between the existing exit wait and a preinstalled, bounded termination-callback latch. Keep every per-launch signed-helper check, the same decode/pixels/caps, and the shared lease until confirmed completion/status, both pipe EOFs and owned cleanup. Add one post-decode cancellation and one deadline probe to the candidate path; cover immediate exit and launch failure so callbacks cannot lose a race or retain a process.

Record callback entry/completion and the same existing timestamps before deciding whether this can replace any production wait. Do not merely skip `waitUntilExit()` on an `isRunning=false` read, change signature caching, reuse helpers or switch the default decoder. This experiment tests whether the measured wait cost is avoidable while retaining the lifecycle guarantees; it does not assume the result.
