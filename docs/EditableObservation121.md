# Build 121: drawing-only full-workflow comparison

[Source ef610bb5665c29138b5deeb1bb1865c531552f77](https://github.com/dandibbert/picshot/commit/ef610bb5665c29138b5deeb1bb1865c531552f77), [run 37829535234](https://github.com/dandibbert/picshot/actions/runs/37829535234), completes the full paired ARM diagnostic. Independent validation reproduces the certification and comparison reports from unchanged raw data. This is diagnostic acceptance, not production promotion, 0.16 acceptance or an installer. Latest deliveries remain ARM 0.15.1/build 111 and Intel 0.11/build 69.

## Exact native evidence

ARM and Intel each pass 320/320 selected cases with no skips from the same 1,723 discovered IDs, including all 21 drawing-raster methods. Different discovery line order does not change the canonical inventory. Native input/source fidelity, both backing scales, presentation identity/invalidation, provider release, export detachment, effect pixels and failure paths pass within their authored fixture scope.

Four sequential owned ARM processes use the same signed relocated app: two separate 35-comparison byte certifications, then reference and owned-sRGB8 complete small+4K functional workflows with two warmups and eight measured 4K cycles each. All 205 corresponding hashes, 12 original/applied document pairs per measured arm and 16 actual PNGs independently validate. UUID/date normalization remains narrowly declared; no replacement golden or reduced work is used. All four screenshot kinds also happen to have identical encoded file hashes across the four processes, although cross-session chrome equality was not a required gate.

The archived 20,744,368-byte ARM executable hashes to `6f4fb853f0a565a79514ac75b4d0ab76d835928d3230ae40240dada53bc366a2`; the actual archived plist binds source and build 121. Owned PIDs are 26228/26784/27268/30508, with distinct sequential confirmed exits. The candidate-mode output guard passes 24 cases / 432 rejected attempts / 24 controller releases; it reports 588 seeded contexts and zero reference-path use, conversion/presentation fallback, failures or live owned bytes. It retains the prior guard's reported-effect-failure scope and does not reproduce a physical GPU failure.

All 110 presentation-provider allocations release in the measured candidate, with 1,231,796,592 allocated/callback/deallocated bytes and matched sizes; peak live caller-owned presentation storage is 47,954,928 bytes. The 255 seeded contexts account for 7,150,466,528 cumulative bytes. These public counts do not account for every native allocation or prove native cache reclamation.

## Memory outcome and full cold cost

All values below are MiB, except elapsed seconds. The candidate improves repeated RSS/volatile growth but remains materially resident and has worse footprint results. It is not accepted as a product memory remedy.

| Observation | Reference | Owned drawing |
|---|---:|---:|
| Native entry RSS | 85.687500 | 86.296875 |
| Final RSS | 802.859375 | 617.171875 |
| Native entry→final RSS | 717.171875 | 530.875000 |
| Native entry→final footprint | 77.611450 | 92.563904 |
| Native entry→final volatile resident | 487.171875 | 267.968750 |
| Entry→before warmup RSS | 519.671875 | 517.218750 |
| Next two warmups RSS | 81.234375 | 9.812500 |
| Eight measured cycles RSS | 116.265625 | 3.843750 |
| Eight measured cycles footprint | 1.343872 | 3.906250 |
| Eight measured cycles volatile resident | 92.703125 | -0.500000 |
| Kernel lifetime RSS peak | 1770.062500 | 1576.343750 |
| Kernel lifetime footprint peak | 591.676941 | 596.770569 |
| Native workflow elapsed seconds | 127.768156 | 103.650097 |

The earliest drawing hook precedes the native-entry metric: RSS is 66.828125 MiB reference and 66.906250 MiB candidate. Earliest-hook→final candidate RSS is therefore +550.265625 MiB, including 19.390625 MiB of setup before the native-entry metric. Neither endpoint measures process birth. Cleanup after the measured endpoint changes candidate RSS by zero; it does not reclaim that cold retained memory.

Every candidate measured RSS increment is positive: +0.546875, +0.718750, +0.359375, +0.359375, +0.375000, +0.546875, +0.781250 and +0.156250 MiB. The last three baseline increments are +6.359375/+10.671875/+4.921875 MiB. This is one bounded run and does not establish a plateau or zero leaks.

Final internal/external/reusable classifications are 556.8125/57.796875/188.25 MiB reference and 353.390625/57.78125/206 MiB candidate. Candidate entry→final reusable growth is +204.59375 MiB, compared with reference +186.71875 MiB; reusable is not physical reclamation. Kernel RSS peaks exceed 50 ms sampled peaks (1739.3125/1565.96875 MiB). Graphics/media/device counters, compression, all eight counters, every endpoint and both non-atomic Mach accounting flavors remain in the raw reports. Overlapping ledgers are never added as independent allocations. No pressure, purge, allocator relief or deadline change occurs.

## Remaining boundary and scope

Checkpoints occur before their named phases. Candidate cold `seed-native-render-crop → history-save-reopen-decode` adds +384.296875 MiB RSS / +190.90625 MiB volatile resident while creating the seed editor, rendering, cropping and decorating, before history saving. `history-restore-edit-failure-retry → pin-create-reopen-hidden-preview` adds +271.328125 / +222.265625 MiB during restored editing, failure/retry and reloading, before pin creation/hiding. These intervals include several operations and cannot identify a private allocation owner.

The source-format-preserving originals and P3/16-bit/custom inputs remain unchanged. This candidate changes only eligible sRGB8 drawing; unsupported input follows the prior native path. Real capture configuration requests BGRA without forcing a color profile, so this synthetic result does not prove a universal real-display or wide-gamut memory fix. Production still defaults to reference drawing.

A next isolated diagnostic will test caller-owned final renderer destination storage while retaining the same owned input seeding, intermediate effect snapshots, crop, export snapshot and presentation allocators. It must preserve exact pixel/document/output-failure evidence and all cold, peak, late and cleanup observations. No current memory hold or ledger row is lifted by this proposal.

Build 120 is distinct: both architectures passed the same 320 focused cases and its reference guard passed, but its pair stopped before native execution because a synthetic temporary path did not canonicalize the macOS `/var` alias. Build 121 canonicalizes all four test roots without weakening the strict evidence-path checker and preserves portable logs.
