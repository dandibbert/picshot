# ARM large-input decoder observation, da8dde5

ARM demonstrates lower repeated parent volatile backing with an isolated decoder at 4K and 5K, with significant launch/validation latency and residual parent RSS growth. This is diagnostic evidence, not a production memory remedy. Intel was still pending when this note was prepared.

[Source da8dde5661662a728770984deec1bc0ac0ed2ea3](https://github.com/dandibbert/picshot/commit/da8dde5661662a728770984deec1bc0ac0ed2ea3), [run 37587754946](https://github.com/dandibbert/picshot/actions/runs/37587754946), [ARM job 112681747435](https://github.com/dandibbert/picshot/actions/runs/37587754946/job/112681747435). Native build, 112 focused tests, v1 and v2 comparisons passed on macOS 15.7.9 (24G830). Verified artifact 11467487803: SHA-256 `2ad9273868b10f4a19217d7257c61fb9a9d54d48dfba1802c98a4e736cf86c12`.

## Scope and parent accounting

V1 uses 768×576 input/output. V2 uses separately prepared immutable synthetic PNGs at 3840×2160 and 5120×2880, with the production thumbnail operation bounded to 1024×576, premultiplied sRGB RGBA, **2.25 MiB**. Both modes actually draw and validate every output pixel with zero tolerance. Headless arms have two warmups and twelve measured cycles; native UI arms have two warmups and four measured previews, followed by separately recorded debounce/cancellation scenarios. Preparation is excluded from these repeated intervals. The structured alpha pattern is not a photographic or incompressible-input workload.

All quantities below are MiB. Each triple is **RSS / physical footprint / volatile purgeable resident**. Warmup delta runs from the first warmup's pre-work sample to the post-warmup baseline; measured delta runs from that baseline to the final settled cycle. The fields are actual successful self-Mach measurements, not inferred purgeable classifications.

| ARM arm | Two-warmup delta | Measured delta |
|---|---:|---:|
| 768×576 control | 7.688 / 0.406 / 6.781 | 40.719 / 0.234 / 40.500 |
| 768×576 isolated | 9.438 / 0.266 / 0 | 3.578 / 0.156 / 0 |
| 4K control | 21.531 / 0.500 / 9.031 | 67.953 / 0.453 / 54.000 |
| 4K isolated | 9.453 / 0.547 / 0.031 | 7.344 / 1.047 / 0 |
| 5K control | 23.969 / 1.078 / 9.031 | 64.141 / 0.375 / 54.000 |
| 5K isolated | 10.688 / 0.500 / 0.031 | 8.859 / 0.906 / 0 |
| 5K native UI control | 32.547 / 12.188 / 9.031 | 28.875 / 1.047 / 18.000 |
| 5K native UI isolated | 19.672 / 11.594 / 0.078 | 2.891 / −1.625 / −0.047 |

Late headless control volatile increments remain exactly 3.375 MiB per small cycle and 4.5 MiB per large cycle. Large isolated volatile increments are zero, but the last three RSS/footprint increments remain nonzero:

| Isolated arm | Last three RSS increments | Last three footprint increments |
|---|---:|---:|
| 768×576 | 0.046875, 0.046875, 0.015625 | 0.046875, 0.046875, 0.015625 |
| 4K | 0.046875, 0.093750, 0.046875 | 0.046875, 0.078125, 0.046875 |
| 5K | 0.015625, 0.046875, 0.109375 | 0.015625, 0.046875, 0.109375 |
| 5K native UI | 1.578125, 0.031250, 0.046875 | −1.109375, 0.031250, 0.046875 |

For large isolated headless arms, measured reusable bytes increase 6.297/7.953 MiB; internal bytes increase 1.047/0.906 MiB. Destination closure subsequently lowers footprint by approximately one 2.25 MiB raster while volatile resident stays unchanged. These observations do not prove total-system reclamation or zero allocation cost. Full raw-byte warmup, per-cycle, late and release deltas for all eight arms are in `derived-results.json`.

## Lifetime and separate peak scopes

All 14 small and all 28 large successful headless children exited normally, with exact pixels, owned cleanup and admission release. Each isolated headless arm records 14 provider releases and zero live owned provider bytes. Large children themselves still report 2.25 MiB volatile resident after thumbnail creation and 4.5 MiB after drawing, remaining 4.5 MiB at their final sample. There is no invented zero sample after process death.

Maximum child self-sampled RSS/footprint are 10.578/5.673 MiB for small, 29.938/18.642 MiB for 4K, and 26.219/18.673 MiB for 5K. The separate parent poll reaches 29.984 MiB RSS for 4K. Large isolated parent sampled peaks are 88.734/26.205 MiB and 91.047/25.908 MiB. These separate maxima are not simultaneous, unique physical RAM totals, or instantaneous upper bounds.

V1 real post-decode cancellation and deadline probes also confirm exit, cleanup and admission release, with child error outcomes `cancelled` and `deadline`, status 1, and no terminate/kill escalation. Their process lifecycles are 287 ms and 5.241 seconds.

## Latency and native UI

| ARM arm | Control median | Isolated median |
|---|---:|---:|
| Small full lifecycle | 5.2 ms | 253.3 ms |
| 4K full lifecycle | 43.6 ms | 270.4 ms |
| 5K full lifecycle | 48.5 ms | 308.2 ms |
| 5K native request → draw | 226.4 ms | 471.9 ms |

For 4K/5K isolated headless cycles, per-launch signature validation medians are 107.8/119.6 ms; app validity contributes 91.9/102.2 ms and helper validity 14.9/10.8 ms. Launch-through-confirmed-exit medians are 155.9/173.5 ms; child work is 61.4/79.2 ms, including image creation 33.3/47.3 ms. Raw read/hash costs 2.0/2.2 ms. These independent medians must not be added as though they describe one cycle.

The interval from the child's response-prepared timestamp to the parent's confirmed-exit timestamp is 85.6/80.9 ms median. It includes currently unresolved child finalization/exit and parent observation/scheduling costs; it is not established as IPC overhead or an avoidable wait.

Both native UI arms complete six exact previews, suppress stale results, coalesce a three-action burst into one worker, release all controllers and leave zero jobs. The isolated arm launches nine children: eight complete and one cancels after decode. Its other worker cancels during signature validation before launch. Its owned provider has eight releases, zero live bytes and a one-raster peak.

Actual isolated cancellation during signature validation is observed, with 104.5 ms from the action to worker completion; the synchronous signature call is explicitly not interruptible. Post-decode close takes 202.7 ms, and the held completed-result cancellation takes 35.6 ms. Control cancellation scenarios act on a held completed result; they do not establish interruption of active ImageIO decode. All requested scenario flags are true within that stated scope.

Maximum main-queue acknowledgement delays are **130.4 ms control / 126.1 ms isolated**, triggering the 100 ms diagnostic flag in both. Mean delays are 1.63/0.80 ms; 257/263 and 381/386 samples fall below 10 ms. These whole-run histograms lack timestamps for attributing worst stalls to construction, steady previews, fault scenarios or capture. First controller/snapshot construction separately adds about **57.5 MiB footprint**, taking 57.9/42.7 ms, outside request-to-draw timing. Whole-UI parent peaks include those sources, snapshots, faults and capture: 252.734/142.893 MiB RSS/footprint control, 164.813/101.127 isolated.

Actual window backing is **1× in both arms**. A 5K source does not establish Retina display coverage. The two content-view PNGs are byte-identical, 620×550, and show the same controls/pattern. The clear left quarter is intentional source transparency; it is not clipping. Captures are outside the repeated memory interval and do not prove physical screen output or monitor scanout. The UI uses the real controller/view with a prepared-PNG encoder adapter; complete export encoding and saving remain excluded.

## Smallest next step

First complete the already-running Intel comparison and qualify any architectural differences. Then repeat only the two 5K UI arms on an available native window reporting genuine 2× backing, using the existing bounds and unchanged per-launch signed-helper validation. Do not change system display modes to manufacture coverage.

If latency work continues, the smallest additional diagnostic is a bounded timestamp record for the worst main-queue delays and child terminal-write/exit-observation boundaries. That can separate construction/UI stalls and the approximately 80 ms post-response interval before proposing an optimization. Preserve signature/path/identity validation, one-child admission, exact pixels and cleanup; no signature cache or helper reuse is justified by this run.

**`parentLossVerified=false` remains explicit.** Early parent death or a hard child exit can strand files, and no orphan reaper is proven. No global pressure, relief operation, permissions change or production memory fix is part of this result.
