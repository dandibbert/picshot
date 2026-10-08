# Build 118: full-size owned decoding and timestamp fidelity

[Source eb320ff6bda329f9b76138fd953acc68024f814b](https://github.com/dandibbert/picshot/commit/eb320ff6bda329f9b76138fd953acc68024f814b), [run 37808798894](https://github.com/dandibbert/picshot/actions/runs/37808798894), completes all four selected jobs. This is a completed ARM component experiment and narrow native validation, **not full 0.16 or installer acceptance**. Accepted deliveries remain ARM 0.15.1/build 111 and Intel 0.11/build 69.

## Native correctness and scope

ARM and Intel each pass all 287 selected cases from 1,690 discovered tests, with no skips. Each architecture includes the four new timestamp regressions. The separate ARM installed guard passes 24 cases / 432 rejected attempts / 24 controller releases. Seven component-admission cases pass. These overlapping stages are not additive coverage counts.

All eight fresh, sequential native processes use one signed relocated application. Reports bind executable SHA-256 `d958ab4c981f0644f62b8a300664709e4fc6ee2af8dbbcc39f8509b53cbe9c31`, the exact source, OS and installed path. The archived reports do not include the executable or Info.plist; signing and executable identity are CI-verified, while independent offline replay validates the actual data and archived identity without pretending to rehash an absent binary.

The five consumers each complete two warmups and eight measured cycles: 50 recorded cycles and 180 exact full-size consumer pixel comparisons. The immutable PNG/raw inputs retain the prior build 113 dimensions, alpha/color/ICC metadata and exact reference bytes; preparation totals 82,141,127 bytes. Each consumer retains 81,553,744 bytes of validation destinations until its explicit cleanup. No resized input or new golden substitutes for the existing workload.

The new canonical owned-decode route performs 30 decodes, 30 direct vImage conversions, 60 CGImages and 30 actual validation draws. All conversions return zero with `kvImageNoAllocate` (512). All 120 decode/conversion/release checkpoints and both metadata sets validate. Each of 30 supplied provider allocations receives its public release callback and deallocates; every destination releases. Ending the decoded-reference/autorelease-pool scope does not prove that ImageIO has no private objects or backing.

The previously failing editable cell now completes 20 restores, ten native Apply operations, ten fresh renders and 60 full-pixel checks with an unchanged encoded document. The timestamp fix therefore passes the original fidelity gate. This cell has zero persistence commits; it does not replace changed-edit/history/export acceptance.

A separate post-exit process verifies all 30 PNG writer outputs, their full decoded pixels, hashes and report/source binding. Encoded outputs total 5,761,650 bytes and remain intentionally retained as evidence. All complete reports remain below the unchanged 2 MiB cap, and all processes remain within the original 300-second native, 600-second owned-launch and 620-second per-wrapper limits.

## Complete lifetime costs

MiB means 1,048,576 bytes. Peak columns below are kernel lifetime peaks at final cleanup. Fixed-input, preparation, warmup, every measured interval, destination release and final input release remain separately recorded; sampled peaks can miss transients.

| Cell | Entry→final RSS | Entry→final footprint | Warmup→measured RSS | Warmup→measured volatile resident | Final volatile resident | RSS peak | Footprint peak |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Raw draw | +293.921875 | +4.094238 | +0.609375 | 0 | 0.015625 | 360.656250 | 256.502502 |
| PNG write | +292.140625 | +4.578552 | −1.500000 | 0 | 0.015625 | 362.125000 | 257.002563 |
| PNG decode/draw | +994.781250 | +6.376892 | +623.328125 | +622.375000 | 777.968750 | 1217.078125 | 244.910217 |
| Canonical owned decode/draw | +291.890625 | +3.094238 | −2.109375 | 0 | 0 | 423.859375 | 272.549438 |
| Editable render/pin | +501.046875 | +39.969543 | +7.781250 | 0 | 141.843750 | 806.390625 | 444.518799 |

The owned-decode candidate avoids continued retained volatile growth in this specific route. Its last three measured-release RSS increments are +0.109375/+0.171875/+0.140625 MiB, versus baseline decode +77.906250/+77.906250/+77.921875 MiB. This does not erase cold cost: candidate final RSS is 358.546875 MiB, with an entry-to-final reusable increase of 290.734375 MiB and internal increase of 2.968750 MiB. Reusable is a measured kernel classification, not physical reclamation or a proven allocator owner.

The candidate also reaches a sampled volatile-resident peak of 63.281250 MiB before returning to zero. Its charged footprint peak exceeds the baseline's despite its much lower retained RSS/volatile growth. It is not uniformly better on every memory metric.

The editable cell remains material: final RSS 567.687500 MiB, footprint 59.893555 MiB, volatile resident 141.843750 MiB and reusable 339.906250 MiB. Its last three measured-release RSS increments are +8.234375/+0.421875/+0.171875 MiB. Each destination/input cleanup separately lowers internal/footprint by 77.781250 MiB and raises reusable by that amount while RSS/volatile stay unchanged. None of its 60 validation draws adds volatile resident; recurring rises already occur in the combined render/crop/decoration chain. Those intervals do not isolate the owner or justify changing the shared CIContext.

All eight counters, 810 signed derived intervals and 1,025 kernel observations are retained in the source-bound evidence. The raw standard/purgeable calls are separate and non-atomic. Kernel categories and volatile ledgers overlap and are never summed as independent causes. Measured-release endpoints and later after-measured checkpoints remain distinct. No pressure, purge or allocator-relief request is used.

## Next boundary: preserve source fidelity

The successful candidate produces premultiplied sRGB RGBA8 working images. That cannot replace every production decode: existing acceptance explicitly requires a 16-bit editable base to remain 16-bit, and original copy/reset/re-persistence still consume the decoded original. Retaining the old PNG on disk alone would not protect those routes.

A separate candidate will copy into caller-owned storage while matching source depth, alpha association, bitmap layout, color-space object, rendering intent and interpolation. Straight-alpha hidden RGB and 16-bit values need direct sample-level certification outside measured cycles; rendered sRGB8 equivalence is insufficient. Unsupported valid layouts must retain an explicit unchanged-image outcome, and eligible-copy failures must not publish partial pixels. Non-nil decode arrays remain outside initial eligibility. No production caller has switched, no broader-format claim follows from build 118, and no 0.16 ledger row is promoted.
