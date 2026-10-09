# Build 126: matched scopes qualify output, not memory improvement

[Source ac8486b37208c9414e0a5aa774e7c46d61518dd3](https://github.com/dandibbert/picshot/commit/ac8486b37208c9414e0a5aa774e7c46d61518dd3), [run 37856040051](https://github.com/dandibbert/picshot/actions/runs/37856040051), completes two separate matched comparisons. Neither whole-render autorelease pooling nor caller-owned final storage supports production promotion. Defaults remain reference input drawing and native final storage; 0.16 remains held. Latest delivered packages remain ARM 0.15.1/build 111 and Intel 0.11/build 69.

## Verified work

All 656 source blobs reconstruct tree `beee71db0f7ea8f7b596e82cc337ea39a502a173`. The actual archived ARM executable is 20,811,312 bytes with SHA256 `672d869891053d32cac7523fe85400fa63f4308587d96a873c2a574d3d4a49d0`; its plist and build metadata bind the same source and diagnostic build 0.16.0/126.

ARM and Intel each pass all 345 selected methods from 1,748 discovered IDs, without skips. Dedicated 46 methods exactly overlap 25 renderer and 21 drawing cases. Each pooled-policy guard passes 24 cases, 432 refused output attempts and 24 controller releases. Each has 588 renderer attempts, 480 failure events and 108 publications. Owned guard allocations/deallocations reconcile at 588, with 108 provider callbacks and zero final active bytes. The default guard also passes; its separate archive omits executable and plist, so independent identity verification is limited to source-bound build-info, report and launcher metadata.

Each comparison uses four distinct, sequential, normally exited application processes: two separate 35-hash certifications, then two full resource workflows. Each measured arm completes small+4K functional work, two 4K warmups and eight measured 4K cycles, all 205 corresponding hashes and twelve canonical document pairs. Sixteen actual PNGs per comparison, thirty-two total, pass file/pixel checks and visual inspection. These screenshots show the small workflow; 4K coverage is native hash/document evidence. Both comparison and certification JSONs reproduce exactly with the frozen checkers and unchanged raw evidence.

Input drawing is owned-sRGB8 in both comparisons. Pool-only compares native storage without a renderer-owned pool to native storage inside a whole-render pool. The separate storage comparison holds the whole-render pool constant while comparing native versus owned final storage. It does not compare production reference input drawing to a final production candidate. Per-cell native/owned-launch/wrapper deadlines remain 300/600/620 seconds; no forced cleanup is needed. Each comparison is one ordered experiment, not a statistical stability result. Native AppKit redraw counts can differ (229 versus 231 in the pool-only pair); required logical work, hashes, documents and observer mode are identical.

## Complete measured costs

All quantities are MiB; each value is RSS / physical footprint. Cold is native entry through both functional workloads. Native entry follows the earliest diagnostic hook, and neither is process birth. The two experiments must not be combined by cross-run subtraction.

| Interval | Native | Native-pooled | Matched native-pooled | Owned-pooled |
|---|---:|---:|---:|---:|
| Cold delta | 517.672 / 101.845 | 528.844 / 103.033 | 527.344 / 103.408 | 591.859 / 103.299 |
| Two warmups | 0.672 / −11.125 | 6.219 / −12.063 | 9.781 / 0.281 | 1.766 / −13.328 |
| Eight measured cycles | 8.047 / 3.094 | 11.344 / 2.266 | 7.813 / −12.656 | 3.547 / 2.828 |
| Final cleanup | 0 / 0 | 0 / 0 | 0 / −0.250 | 0 / 0 |
| Native entry→final | 526.391 / 93.814 | 546.406 / 93.236 | 544.938 / 90.783 | 597.172 / 92.799 |
| Earliest hook→final | 546.000 / 113.236 | 565.578 / 112.220 | 564.641 / 110.298 | 616.719 / 112.158 |
| Final absolute level | 613.188 / 133.269 | 632.438 / 131.879 | 631.531 / 130.082 | 684.156 / 132.035 |
| Sampled peak | 1555.922 / 583.692 | 1576.328 / 580.615 | 1579.641 / 589.599 | 1552.391 / 584.427 |
| Kernel lifetime peak | 1573.766 / 598.489 | 1592.094 / 596.458 | 1590.672 / 608.021 | 1564.688 / 587.364 |

Last three released RSS increments are −13.719/+14.922/+0.484; +8.578/+0.266/+0.672; +0.172/+3.859/+0.484; and +0.328/+0.156/+0.219 respectively. Elapsed native seconds are 112.182, 93.809, 103.349 and 105.014. Smaller late increments or lower peaks do not erase the cold residual.

Pool-only ends with 20.015625 MiB more entry→final RSS, despite 0.578064 MiB less footprint. Matched owned storage has 64.515625 MiB more cold RSS and 52.234375 MiB more entry→final RSS. Its entry→final footprint is 2.015991 MiB worse. These observations reject both as demonstrated memory remedies; they do not prove an inevitable regression across machines or attribute private allocator ownership.

The matched candidate's additional cold RSS accompanies 64.96875 MiB additional reusable accounting. Entry→final excess reusable is 50.703125 MiB. All four arms end with 257.5625 MiB volatile ledger and approximately 268 MiB volatile resident accounting. These overlapping categories cannot be added as separate ownership buckets, and reusable does not mean physically reclaimed.

All 229 owned renderer allocations/releases and 6,550,598,400 cumulative bytes reconcile, with zero final active bytes and peak owned bytes 199,065,600. Drawing provider callbacks also balance. This proves public ownership retirement only. Cold4K cleanup releases 885.875 MiB RSS in the matched native arm and 847.500 MiB in its candidate, while reusable increases 0.28125 versus 53.546875 MiB. Final cleanup contributes no RSS reduction in any arm. Every raw counter, backing dictionary, snapshot-live observation, cycle increment and kernel peak remains part of the evidence.

## What remains unexplained

Checkpoint labels name work about to start. The large seed-native-render-crop→history-save-reopen-decode interval precedes the first persistence save/decode. It includes editor construction/show/crop, fixture-only full rendering/reference crop, canvas flattening, diagnostic hashes and decoration projection. Existing pre-hash boundaries show 275.48–321.50 MiB RSS and 182.92–183.375 MiB volatile-ledger growth before the reference-crop hash. Three subsequent diagnostic hashes add 57.328 MiB RSS and no volatile-ledger increase. Observation cost is separate from production operations.

After the history-replayed hash and before pin creation, edit/undo, failed-save/retry and saved-again decode add 325.31–380.05 MiB RSS and 285.875–317.516 MiB volatile ledger. Per-hash readings contain eight counters, not full backing dictionaries; nearby backing readings must not be substituted as exact substage evidence.

Intermediate `context.makeImage` snapshots for grouped mosaic, blur/pixelation and magnifier remain under every tested final-storage policy. The shared Core Image effect context also remains unchanged. Narrower scalar boundaries after crop interaction and around fixture-only reference rendering, then around failure/retry and payload decoding, can distinguish these operations without changing image lifetimes or hash work. A source-format-owned persistence decoder alone cannot explain the earlier pre-decode growth.

A separate finite, smoke-only Core Image memory-target control is now being prepared. [Apple documents memoryTarget](https://developer.apple.com/documentation/coreimage/cicontextoption/memorytarget) as a per-context render-task memory setting with a performance tradeoff. A fixed value of 32 changes neither the original image format nor the effect graph, but still needs exact native pixel/failure/full-lifetime verification. It is not a process-RSS cap. Pool changes, cache clearing and source decoding remain separate from that trial. No feature row or package is promoted by preparing it.

## Prior failure preserved

Build 125 passed all 345 selected methods on both architectures and the default output guard, but its dedicated comparison stopped in a portable fixture: the newly added temporary root retained macOS's `/var` alias while the strict reader required its canonical path. Both comparisons and their dedicated guards were unrun. Build 126 changes only that test root before fixture identity and CLI invocation. The old source reproduces all three alias failures; the corrected nine methods pass under deliberately aliased TMPDIR in ordinary and optimized Python. Strict production readers, app code, workflow, deadlines and resource limits are unchanged.
