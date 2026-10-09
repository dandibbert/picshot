# Build 129: no complete-lifetime improvement from the Core Image target

[Source faa6b258f1418474709113c8acb8f6231049818b](https://github.com/dandibbert/picshot/commit/faa6b258f1418474709113c8acb8f6231049818b), [run 37867874196](https://github.com/dandibbert/picshot/actions/runs/37867874196), completes the reference versus `memory32` comparison. The candidate is not promoted. Production retains reference drawing, native final-render storage and the reference effect context. Latest delivered packages remain ARM 0.15.1/build 111 and Intel 0.11/build 69; this run creates no accepted installer.

## Verified scope

All 674 source blobs reconstruct tree `dace005ea5e968d56c2169db3e04f2195443a9f8`. The actual archived ARM executable has 20,975,328 bytes and SHA256 `3d06553728557e8617aab55731b90ea0b7e1744d10b5bc70152adc416accf6bd`; the actual plist binds the same source and version 0.16.0/build 129.

ARM and Intel each pass 363 selected methods from 1,766 discovered, without skips. The 64 dedicated methods pass and exactly overlap focused coverage; counts are not additive. Each effect policy's output guard retains 24 cases, 432 refusals and 24 controller releases. Its unchanged failure fixture makes zero normal effect-context calls before the separately reported positive control. That control adds exactly two real process calls for blur/pixelation, matching an independent legacy context's pixels and metadata, with five raster observations and no memory samples. Refusals and positive controls are distinct evidence.

Two independent 35-hash certification processes and two complete 205-hash/12-document resource processes pass. Both resource arms retain small and 4K functional cases, two warmups and eight measured 4K cycles. All 16 actual PNGs pass byte/pixel checks and visual inspection; these screenshots show the small workflow, while 4K fidelity uses hashes and documents. All six app processes, including two separate guards, exit normally within unchanged native/launch/wrapper bounds. No forced cleanup is needed. All 94 raw archive members remain unchanged after independent reproduction.

The focused archives omit executable bytes, and the separate default-guard archive omits executable/plist; their identity evidence has that limit. The effect archive includes its actual executable and plist. This is one ARM ordered comparison, not an Intel memory result or general stability proof.

## Complete costs

Values are MiB, expressed as RSS / physical footprint. Cold includes both functional cases. Native entry occurs after the earliest drawing hook and neither is process birth.

| Interval | Reference | memory32 |
|---|---:|---:|
| Cold delta | 528.031 / 103.361 | 487.266 / 102.361 |
| Two warmups | 6.094 / −13.438 | 34.406 / −11.875 |
| Eight measured cycles | 2.531 / 1.719 | 17.766 / 1.375 |
| Native entry to final | 536.656 / 91.642 | 539.438 / 91.861 |
| Earliest drawing hook to final | 556.563 / 111.189 | 559.266 / 111.377 |
| Final absolute | 622.984 / 130.941 | 625.969 / 131.254 |
| Sampled peak | 1576.813 / 577.427 | 1581.391 / 583.318 |
| Kernel lifetime peak | 1581.984 / 633.740 | 1585.125 / 633.583 |
| Final cleanup delta | 0 / 0 | 0 / 0 |

The 40.766 MiB cold RSS advantage disappears during warmups and measured work. Earliest-hook-to-final RSS is 2.703 MiB higher and native-entry-to-final footprint is 0.219 MiB higher. These results do not demonstrate a complete-lifetime improvement. They also do not establish inevitable regression or private allocator ownership. All eight counters, both complete backing dictionaries, individual increments, live snapshots and peaks remain relevant; overlapping accounting categories are not summed or subtracted as supposedly free memory.

AppKit redraw/effect counts differ (231/618 reference, 229/612 candidate), while all required logical work matches. The configured 32 is Apple's MB unit, not MiB, a physical allocation readback, or a process RSS limit. The constructor option and immutable context are the only effect-policy differences.

## Product and fixture costs still need separation

The existing resource loop repeats the full correctness workload, including duplicate reference rendering/cropping/decoration, diagnostic hashes, decoded export comparisons, failure/retry and legacy cases. Its observed approximately 537 MiB residual is real for that workload, but cannot identify ordinary product costs alone. It must not be dismissed as fixture-only without evidence.

A narrow opt-in observation adds two scalar memory checkpoints to the unchanged workflow: after native crop and after fixture reference full rendering. The existing pre-reference-crop-hash boundary then locates crop materialization, but has only eight counters and no full backing dictionaries. This probe changes no image lifetimes, pools, decoding, reference work or product defaults; it diagnoses intervals rather than qualifying a memory remedy.

A separate product-resource fixture is planned around actual editor/history/pin callbacks with independently certified output pixels verified after the measured process exits. It will retain cold costs and peaks, release local image/controller ownership between phases, and report two warmups plus eight measured cycles. Closed-cycle controllers, owned rasters, jobs, reservations and descriptors must retire; run-level stores and caches remain charged. Repeated image-sized late growth remains actionable. Zero RSS and return to process-entry memory are not acceptance targets. This proposed fixture has not yet run and does not clear the 0.16 hold.

## Earlier failures remain explicit

Build 127 failed native compilation on typed rendering-intent metadata and an integrated source-order contract; its native comparison never ran. Build 128 corrected those and passed the default output guard, but one dedicated pixel-oracle method failed on both architectures: it demanded unused padding after the final meaningful row of a valid cropped image. Its resource pair remained unrun.

Build 129 changes only that test oracle. A 91×73 image with 516-byte stride legitimately provides `(73−1)×516 + 91×4 = 37,516` bytes; demanding 37,668 included 152 bytes of unused final padding. The corrected helper verifies every meaningful byte with checked dimension/stride/arithmetic bounds and rejects missing pixels. Two additional tests cover exact/padded tails, single rows, invalid dimensions/strides and overflow. Application code and comparison workload are byte-identical to build 128; the actual native runtime pass is build 129's evidence.
