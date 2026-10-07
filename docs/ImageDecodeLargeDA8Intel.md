# Intel completion of the da8dde5 decoder diagnostic

Intel confirms the repeated parent volatile-backing result from ARM, with substantially greater isolated-preview latency. It does **not** establish a universal peak-memory improvement: the isolated Intel native UI has slightly higher whole-run peak footprint than its control.

Source [`da8dde5661662a728770984deec1bc0ac0ed2ea3`](https://github.com/dandibbert/picshot/commit/da8dde5661662a728770984deec1bc0ac0ed2ea3), [run 37587754946](https://github.com/dandibbert/picshot/actions/runs/37587754946), successful unchanged [Intel retry job 112690258751](https://github.com/dandibbert/picshot/actions/runs/37587754946/job/112690258751). The first Intel job, 112681747102, passed computation/native tests but failed artifact upload with `ETIMEDOUT`; it produced no artifact. The figures below use only the final verified retry evidence, not two independent observations. Artifact 11468883025 is 4,587,652 bytes, outer SHA-256 `acbbfe95926b77816c35852a7273c2ab5391c9c1ce06219259906d81d8d545cd`. Build, 112 focused tests and all v1/v2 cells pass.

## Repeated parent accounting

Each headless arm has 2 warmups +12 measured cycles. Large inputs are fixed 4K/5K synthetic PNGs; outputs remain 1024×576, 2.25 MiB, with actual drawing and exact full-pixel validation. Deltas below run from the post-warmup baseline to the last settled measurement, in MiB.

| Intel arm | RSS delta | Footprint delta | Volatile resident delta |
|---|---:|---:|---:|
| Small control | 40.688 | 0.145 | 40.500 |
| Small isolated | 0.652 | 0.609 | −0.027 |
| 4K control | 54.664 | 0.637 | 54.000 |
| 4K isolated | 0.840 | 0.762 | −0.027 |
| 5K control | 54.574 | 0.574 | 54.000 |
| 5K isolated | 0.797 | 0.727 | −0.027 |
| 5K native UI control, 4 measured previews | 18.332 | 0.297 | 18.000 |
| 5K native UI isolated, 4 measured previews | 0.332 | 0.258 | 0 |

Large control volatile growth remains exactly 4.5 MiB per late headless cycle. Isolated RSS is not flat: final three increments are 0.031/0.074/0.059 MiB at 4K and 0.070/0.043/0.012 MiB at 5K. Corresponding footprint increments are 0.031/0.059/0.082 and 0.055/0.027/0.035 MiB. Two-warmup isolated RSS/footprint changes are 5.965/5.527 MiB at 4K and 6.078/5.625 MiB at 5K. Native UI isolated volatile values briefly rise and fall by 0.125 MiB; zero net growth is not zero in every cycle. `derived-results.json` preserves every raw-byte warmup/late/release delta.

## Cost and lifetime

| Median observed latency | ARM control / isolated | Intel control / isolated |
|---|---:|---:|
| Small full lifecycle | 5 / 253 ms | 16 / 517 ms |
| 4K full lifecycle | 44 / 270 ms | 61 / 521 ms |
| 5K full lifecycle | 48 / 308 ms | 76 / 512 ms |
| 5K request → native draw | 226 / 472 ms | 251 / 665 ms |

Intel per-launch signature medians are 289/270 ms for 4K/5K; child work is 99/116 ms. The still-unresolved response-prepared → parent-exit-confirmation interval is 85/79 ms. Per-launch signature/path validation remains complete; these numbers do not justify bypassing or caching it.

All 28 large headless children exit normally with exact pixels, owned cleanup and admission release. Their maximum individual self-sampled RSS/footprint are 23.453/20.879 MiB at 4K and 19.285/16.699 MiB at 5K. Small probes also confirm real post-decode cancellation/deadline cleanup. The isolated native UI has 9 launches, 8 successful provider releases and one post-decode cancellation, plus one cancellation during signature validation before launch. All stated scenario flags, stale suppression and controller-release checks pass. Signature cancellation takes 236 ms to worker completion and does not interrupt the synchronous verifier; post-decode close takes 170 ms.

Both Intel UI arms trigger the 100 ms diagnostic responsiveness flag: maximum queue acknowledgement delay is 244 ms control /234 ms isolated. Whole-UI peak RSS is 211.031/175.652 MiB; **peak footprint is 142.301/144.336 MiB**, including source/snapshot construction, faults and capture. These are independent sampled process maxima, not simultaneous or unique system RAM. Worst-stall phase attribution is not available in this version.

Both architectures report **1× actual window backing**, so genuine Retina display coverage remains absent. `parentLossVerified=false` remains explicit: early parent death/hard exit can strand jobs. No total-system reclamation, production remedy, installer change or physical-input/scanout result is claimed.

The smallest justified continuation is the already-authorized bounded timing-only observation: locate the worst queue delays and separate terminal-write, run-return, response-receipt and exit-wait boundaries. Keep the existing decoder, validation, one-child gate and pixel/cleanup checks. No genuine 2× environment is available here; do not simulate backing or change display modes to claim that coverage.
