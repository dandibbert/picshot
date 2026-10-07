# Allocator-relief result: no preview reclamation observed

Versioned diagnostic result, 2026-10-07. ARM64 and Intel are both complete. This is not a production allocator-relief recommendation or a change to the accepted app's release status.

## Provenance and workload

Source [`971a786625c97367567456a3d6e3264a68338b69`](https://github.com/dandibbert/picshot/commit/971a786625c97367567456a3d6e3264a68338b69), [run 37553988680](https://github.com/dandibbert/picshot/actions/runs/37553988680), macOS 15.7.9 (24G830). Verified artifacts: ARM64 `11453878982`; Intel `11453444454` (archive SHA256 `4c18af20c67b61395b2630be6df4d7bdd05472e3ecdb3d540ca47e0aabf3b422`).

Each architecture used separately prepared synthetic PNG bytes and fresh wait-control/allocator-relief processes: **768×576, 2 warmups +12 production previews**, unchanged preview limits. Image scopes and autorelease pools exited before one `malloc_zone_pressure_relief(nil, 33554432)` call in the relief arm; the control made zero explicit calls. Native Swift/Darwin typechecks passed. No global pressure, huge allocation, permission change, or VM purge was used.

**All four arms accumulated exactly 20.25 MiB of volatile purgeable resident backing after warmup.**

## Actual result

| Relief arm | Reported released bytes | Call time | Volatile change immediately / ~0.5s / ~2s | Footprint change at ~2s | RSS change at ~2s |
|---|---:|---:|---:|---:|---:|
| ARM64 | 0 | 1.286 ms | 0 / 0 / 0 bytes | −131,072 bytes | +294,912 bytes |
| Intel | 0 | 3.154 ms | 0 / 0 / 0 bytes | −1,011,712 bytes | −704,512 bytes |

Changes in the table are relative to each relief arm's immediately preceding sample. Nonvolatile purgeable ledger changes are also zero at all three observations. The wait-control volatile changes are zero at those same observations on both architectures.

The small footprint/RSS changes, including Intel's decrease, **do not reclaim the accumulated volatile preview backing**. The API return is not a preview-specific allocation result; the raw backing observations independently show no reduction in that accumulation.

Subsequent drawn pixels matched the separately prepared reference exactly in both arms on both architectures. Single subsequent preview timings were ARM64 2.014 ms control / 2.250 ms relief, and Intel 5.263 ms control / 13.647 ms relief. One observation per process does not establish a performance difference or zero cost.

## Evidence and conclusion

Artifacts contain `evidence/image-relief/comparison.json`, the named `image-relief-wait-control.json` and `image-relief-allocator-relief.json` reports, input provenance, and `api-typecheck.log`. `launch.json` contains report copies. The named reports retain actual invocation counts, return/duration, raw VM fields, delayed samples, and separate subsequent preview/raster timings.

**The bounded self-only allocator operation did not demonstrate preview reclamation on either tested architecture. No production-relief recommendation follows.** These observations do not establish maximum-image behavior, indefinite stability, or a remedy. The separate next draw/materialization comparison remains unexecuted: every variant must actually draw and validate pixels, so a lazy object without decoding/rendering cannot count as a fix.
