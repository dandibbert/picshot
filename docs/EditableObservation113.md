# Editable observation build 113: normalization remedy rejected

The ARM64 diagnostic at source [c80e94de9cf712e118009700feacbd707356e0a3](https://github.com/dandibbert/picshot/commit/c80e94de9cf712e118009700feacbd707356e0a3), tree `694e4fc5c9e98ea12f23885ec544f90250c6d268`, version **0.16.0/build 113**, completed successfully in [run 37785905941, job 113340457795](https://github.com/dandibbert/picshot/actions/runs/37785905941/job/113340457795). The exact-byte experiment is valid, but **per-call vImage hash normalization is rejected as a memory remedy for this editable workload**: its paired RSS and physical-footprint growth exceed the CGContext reference. The separate candidate-only resource observation also retains positive late growth.

This result leaves **0.16 held**. It changes no product default, installer acceptance, delivery or ledger row. Accepted/delivered ARM remains **0.15.1/build 111** and Intel **0.11/build 69**; accepted behavior counts remain **ARM 60 Code / 55 Partial / 9 Missing, Intel 50 / 61 / 13**. All 133 ledger IDs, requirements, checks and citations remain. It provides no pass for the later build-114 editable-output guard or any future component experiment.

## Exact experiment and evidence boundary

Only the `editable-observation` job ran; normal installer and other lanes were skipped. One app-only package supplied one relocated, ad-hoc signed ARM executable: **20,182,816 bytes**, SHA-256 `9d976fbd09c0bc898de95425eb29e7b769735f8c3795353211bbdcde696321d8`. Certification, reference, candidate and resource observations ran in distinct fresh owned processes (**19887, 20447, 20844, 21546**), with matching source/build/executable/path reports, launcher callbacks and confirmed exits. The **300-second native / 600-second launcher caps** and cleanup contracts were unchanged. Native reference/candidate/resource durations were **15.793 / 16.269 / 133.690 seconds**; launcher durations were **16.928 / 17.442 / 134.792 seconds**, without deadline termination.

All **13 discovered ManualScrollHashTests passed exactly once, with no skips**. Certification compared every byte with `memcmp`, including alpha, of tightly packed sRGB premultiplied-last RGBA8 for the **35 actual small (640×360) and 4K (3840×2160) inputs**. Extent, row stride, component/pixel depth, alpha/bitmap flags, color-space name/model/ICC digest, rendering intent and interpolation were bound to those inputs. Both functional processes used those same 35 inputs in order, identical metadata and SHA-256 values, **358,256,624 normalized bytes and four native snapshots each**. The certification process performed 70 conversions / 716,513,248 bytes and is excluded from the paired memory comparison.

The resource process first repeated the two functional workloads, then performed **two warmups + eight measured 4K workloads**: **205 hashes/conversions, 3,836,511,024 normalized bytes**, with every repeated 4K input matched to its certified counterpart. No resized input, omitted snapshot, skipped native operation or reduced hash count was accepted. The functional processes have 31 diagnostic checkpoints each; resources have 141.

Native PNG file and decoded RGBA hashes, dimensions, geometry and native hit checks passed. Visual review covered reopened light/dark editors and hidden/restored pins. These are owned native-view snapshots, not desktop capture or physical Retina/TCC/multiple-display acceptance.

The per-call candidate destination is released when its synchronous hash call returns; the reference retains its original scoped CGContext. The sidecar retains bounded metadata, not normalization buffers. At resource endpoints no fixed input rasters remain. All observed original/base/current/canonical/editor/canvas/content/pin/store/window probes were dead after release; detached window-content graphs, owned file descriptors, export-controller counts and projection reservations were zero, and owned temporary files were removed. These object-lifetime checks do not establish release of allocator or framework backing.

The final [run artifact 11554618548](https://github.com/dandibbert/picshot/actions/runs/37785905941) has **62 entries / 679,721 bytes**, SHA-256 `36a8301abca72ee2209e8a65dc52b730ac0c7542a5ad80299eda8fd2eb2ba5b4`; its 48 functional-checkpoint files are unchanged from artifact **11554981396**, **471,614 bytes**, SHA-256 `74198be06ec260cfa118e75a215f279d9e219bdb81d5e2dfa3609cb8bd6a4705`. Archive hashes match GitHub metadata and upload logs; CRC, entry/path and source-blob/tree checks pass. The diagnostic artifacts intentionally omit the executable: signing, architecture, relocation and executable identity are CI-attested and live-report corroborated, not an independent local executable rehash or installer audit.

## Paired functional observation

Values are **MiB (1,048,576 bytes)**, rounded to three decimals. Each triplet is **RSS / physical footprint / volatile resident**; these are distinct counters.

| Boundary | CGContext reference | Per-call vImage candidate |
| --- | ---: | ---: |
| Native entry | 85.766 / 38.737 / 0 | 85.531 / 38.549 / 0 |
| Small workload released | 154.078 / 67.424 / 16.969 | 150.672 / 65.658 / 15.016 |
| 4K workload released | 567.500 / 85.316 / 315.766 | 602.734 / 126.801 / 300.750 |
| Final cleanup | 567.500 / 82.847 / 316.141 | 602.734 / 126.769 / 300.750 |
| Entry → final growth | **481.734 / 44.111 / 316.141** | **517.203 / 88.220 / 300.750** |
| 50 ms sampled peak | 1503.531 / 565.895 / 873.531 | 1514.375 / 549.896 / 858.469 |
| Kernel lifetime peak (RSS / footprint only) | 1508.438 / 570.020 | 1554.453 / 567.255 |

Candidate-minus-reference growth is **+35.469 MiB RSS / +44.109 MiB footprint / −15.391 MiB volatile resident**. Exact RSS/footprint growth is reference **505,135,104 / 46,253,568 bytes**, candidate **542,326,784 / 92,505,728 bytes**. Lower volatile resident did not reduce either RSS or footprint. Summed hash time was **0.413 seconds candidate / 0.587 reference**, while whole native functional time was **0.476 seconds longer** for the candidate; one pair does not establish a reliable speed improvement.

## Unmatched candidate resource observation

| Boundary | RSS | Footprint | Volatile resident | Volatile virtual | Compressed |
| --- | ---: | ---: | ---: | ---: | ---: |
| Native entry | 86.000 | 39.002 | 0 | 0 | 0 |
| Initial functional work / before warmup | 580.922 | 129.020 | 300.828 | 301.297 | 1.656 |
| Warmup 1 released | 615.172 | 111.770 | 311.609 | 332.641 | 22.453 |
| Warmup 2 baseline | 644.266 | 111.254 | 362.297 | 395.859 | 34.969 |
| Measured 1 | 678.219 | 114.223 | 373.969 | 457.859 | 85.219 |
| Measured 2 | 685.047 | 116.270 | 388.031 | 488.141 | 101.609 |
| Measured 3 | 736.422 | 114.676 | 433.922 | 488.641 | 55.641 |
| Measured 4 | 699.578 | 111.270 | 412.953 | 488.141 | 76.094 |
| Measured 5 | 737.141 | 113.067 | 431.875 | 488.641 | 57.656 |
| Measured 6 | 770.125 | 113.020 | 465.922 | 489.016 | 23.984 |
| Measured 7 | 776.703 | 110.520 | 468.609 | 488.641 | 20.922 |
| Measured 8 | 776.484 | 117.067 | 470.969 | 488.141 | 18.062 |
| Final cleanup | 776.484 | 115.067 | 470.969 | 488.141 | 18.062 |

Entry-to-final growth is **+690.484 MiB RSS / +76.065 footprint / +470.969 volatile resident**. Initial functional work alone adds **+494.922 / +90.017 / +300.828 MiB** before warmup. The after-warmup-to-measured changes are **+132.219 / +5.813 / +108.672 MiB**. Final cleanup changes footprint by **−2.000 MiB**, with no RSS or volatile-resident decrease; warmup and entry costs must not be discarded.

| Late interval | RSS delta | Footprint delta | Volatile-resident delta | Volatile-virtual delta | Compressed delta |
| --- | ---: | ---: | ---: | ---: | ---: |
| Measured 5 → 6 | +32.984 | −0.047 | **+34.047** | +0.375 | **−33.672** |
| Measured 6 → 7 | +6.578 | −2.500 | **+2.688** | −0.375 | **−3.062** |
| Measured 7 → 8 | −0.219 | +6.547 | **+2.359** | −0.500 | **−2.859** |

The simultaneous resident/virtual/compressed accounting movement prevents treating any one increment as an equal-sized new allocation or leak. **2,689 samples**, including **2,673 timer samples**, observed peaks of **1710.578 MiB RSS / 584.411 footprint / 1039.234 volatile resident**. Kernel lifetime peaks were **1758.031 MiB RSS / 588.630 footprint**. Sampling can miss transients. **No reference-resource or Intel cell ran**, so this observation supplies no baseline improvement ratio.

## What the boundaries can establish

The largest positive 4K stage RSS changes include seed-render → history-save/decode (**+348.859 reference / +376.578 candidate MiB**), restore/edit/retry → pin creation (**+229.109 / +245.547**), and pin-edit/apply → fresh-pin-render (**+238.750 / +269.500**). Workload release reduces RSS by **904.375 / 907.406 MiB**, yet substantial final growth remains. These stages contain overlapping source preparation, hashing, lazy materialization and native framework work. They are correlations, not proof of allocation ownership or independent additive causes.

Summed synchronous 4K hash-boundary deltas are **+224.797 / +60.203 / +164.641 MiB** for the reference and **+281.156 / +88.375 / +106.859 MiB** for the candidate. They overlap stage intervals and must not be added to them or attributed uniquely to hash allocations. Snapshot boundaries similarly include AppKit caching, compositing, hashing and PNG encoding; the after checkpoint precedes helper return and is not a snapshot-release attestation. Separate while-live counters and kernel peaks remain relevant.

The previous [actual-draw no-cache experiment](ImageRasterMaterialization59.md) is already negative evidence, not an untried fix. At its separate [59d30a83 source/run](https://github.com/dandibbert/picshot/actions/runs/37561081891), both architectures completed 2+12 actual 768×576 draws: disabling ImageIO caching still added **1.6875 MiB volatile resident per measured draw / 20.25 MiB total**, including every final interval. The owned-RGBA control excluded PNG decoding, so its zero volatile growth did not establish an end-to-end preview remedy. That small workload must not be substituted for this 4K editable result.

No pressure/purge request ran. Self-process counters exclude WindowServer/GPU and other processes; separate task-info flavor reads are not atomic, and zero counters do not prove backing release. This completed diagnostic establishes neither a plateau nor zero leaks. Any causal component experiment needs its own source-bound native evidence, matched workload and complete cleanup. Full native/model/final ZIP/DMG and physical-device acceptance remain separate requirements.
