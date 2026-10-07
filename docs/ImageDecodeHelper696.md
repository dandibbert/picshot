# Signed PNG decode helper result on ARM64 and Intel

Versioned diagnostic result, 2026-10-07. A disposable signed decoder avoided the previous per-preview volatile-resident slope in the parent for this small fixture, but introduced substantial latency and did not make parent memory flat. **This is not a production recommendation.**

## Provenance and completed scope

Source [`696b22865ff0065b89b77da364e4a407b9ec263a`](https://github.com/dandibbert/picshot/commit/696b22865ff0065b89b77da364e4a407b9ec263a), [run 37567338578](https://github.com/dandibbert/picshot/actions/runs/37567338578), [ARM64 job 112617955569](https://github.com/dandibbert/picshot/actions/runs/37567338578/job/112617955569) and [Intel job 112617955689](https://github.com/dandibbert/picshot/actions/runs/37567338578/job/112617955689). Both jobs succeeded on macOS 15.7.9 (24G830), with 42 focused native tests passing on each architecture.

Each architecture used fresh production-control and isolated-decode parent processes, separately prepared **768×576 PNG/reference inputs, 2 warmups +12 measured cycles**, and one reused destination per parent. Both routes completed all **14 actual draws and exact full-pixel validations**. The isolated route started a fresh signed bundle child for every decode; only PNG bytes entered the child. Its decoded raw output and the parent's subsequent drawn pixels matched the reference exactly. All 14 child exits, private-job cleanups and admission releases were confirmed.

Named reports are under `evidence/image-decode-helper/<mode>/image-decode-helper-<mode>.json`; `comparison.json` summarizes them. The earlier [actual-draw controls](ImageRasterMaterialization59.md) establish why already-decoded raw rendering alone was insufficient evidence.

## Parent memory

Settled changes from each post-warmup baseline, in MiB:

| Architecture and route | Volatile resident | RSS | Physical footprint |
|---|---:|---:|---:|
| ARM64 production control | +40.500000 | +40.718750 | +0.203125 |
| ARM64 isolated decode | 0 | +8.484375 | +0.390625 |
| Intel production control | +40.500000 | +40.796875 | +0.222656 |
| Intel isolated decode | −0.027344 | +0.585938 | +0.500000 |

Production control's final three volatile increments were +3.375 MiB each on both architectures. Isolated ARM's final three RSS increments were **+0.921875 / +0.031250 / +0.046875 MiB**; Intel's were **+0.101563 / +0.007813 / +0.058594 MiB**. The isolated route's nonvolatile purgeable ledger was unchanged over the measured cycles. These residual RSS/footprint changes rule out a flat-memory or zero-cost claim; twelve cycles do not establish a plateau.

Each isolated parent recorded 14 owned-provider allocations, release callbacks and deallocations, zero active owned bytes at the end, and a one-provider peak of **1.6875 MiB**. That counter excludes the separate transient raw Data buffer and persistent input/reference allocations. All destination callbacks/deallocations also completed. Callback counts establish supplied-buffer lifetime, not physical reclamation.

The largest sampled child RSS/footprint was **10.609375 / 5.688660 MiB on ARM64**, and **7.511719 / 3.277344 MiB on Intel**. The reported sum of separate parent/child maxima was **95.812500 / 30.456360 MiB RSS/footprint on ARM64**, and **61.023438 / 26.882813 MiB on Intel**. These are sampled envelopes, not simultaneous peaks, hard upper bounds or unique physical RAM. Receipt-time pairs had up to approximately 32–35 ms skew. Shared pages, kernel file cache, GPU, WindowServer and unrelated processes are outside a total-memory conclusion.

## Latency attribution

Measured-cycle medians, in milliseconds:

| Interval | ARM64 | Intel |
|---|---:|---:|
| Production control full lifecycle | 4.092 | 20.054 |
| Isolated decode full lifecycle | 265.569 | 572.246 |
| Per-launch signature validation | 138.437 | 420.227 |
| Launch through confirmed child exit | 117.708 | 130.312 |
| Child-reported work, inside the launch interval | 37.283 | 37.639 |
| Raw read and hash in parent | 1.640 | 5.571 |

Full lifecycle includes signature validation, staging, launch, decode, transport, exit, parent drawing/validation, pool exit and owned cleanup; the deliberate settle wait is excluded. Independent medians are not additive. Signature plus launch-through-exit accounts for a median **97.7% / 96.8%** of each cycle's full duration on ARM64 / Intel. The launch interval already includes child decoding and drawing.

The median per-cycle difference between launch-through-exit and child-reported work was approximately **86.8 / 92.2 ms**. It mixes uninstrumented startup, scheduling, protocol observation and exit costs; it cannot all be called process creation or PNG decoding. Per-launch signature checks remain required and unchanged. Apple notes that [a static signature verdict depends on the code remaining unmodified](https://developer.apple.com/documentation/security/secstaticcodecheckvalidity(_:_:_:)); these timings do not justify caching or skipping validation.

## Cancellation and remaining limitations

Each architecture also completed one real post-decode cancellation and one deadline probe at an explicit pre-publication hold. Decoded-reference hashes matched; the child exited normally with status 1; no raw output was accepted; cleanup and admission release succeeded. Neither probe needed SIGTERM/SIGKILL escalation. These were diagnostic protocol controls, not native UI cancellation tests, and exact cancel-request-to-exit latency was not separately recorded.

**`parentLossVerified=false` remains explicit.** Abrupt parent death before child startup, or a hard-backstop child exit without a live parent, can strand a private job. No orphan reaper or abrupt-parent-loss guarantee was established.

This result does not cover large images, Retina backing, repeated AppKit display, complete export encoding, long-run stability or production UI responsiveness. The [bounded large-input and UI proposal](ImageDecodeHelperLargeUIPlan.md) keeps those questions separate and preserves executable-validation guarantees.
