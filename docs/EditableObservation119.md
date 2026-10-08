# Build 119: source-format fidelity passes, memory remedy rejected

[Source cce44c481666efb8e9ae40163b26918263b7cf5f](https://github.com/dandibbert/picshot/commit/cce44c481666efb8e9ae40163b26918263b7cf5f), [run 37815722825](https://github.com/dandibbert/picshot/actions/runs/37815722825), completes its four selected jobs. This is diagnostic evidence, not 0.16 or installer acceptance. Accepted deliveries remain ARM 0.15.1/build 111 and Intel 0.11/build 69.

Both architectures pass 299/299 selected native cases with no skips, including eleven source-format methods and four timestamp regressions. ARM additionally passes 19/19 pre-matrix cases and the 24-case / 432-attempt / 24-controller output-failure guard. These overlapping selections are not additive coverage.

All nine fresh ARM processes complete. Six consumers each run two warmups and eight measured cycles, totaling 60 cycles and 210 exact canonical pixel comparisons. A separate post-writer-exit process verifies 30 actual PNG outputs. The original 3840×2160 original/base and 2414×1574 current inputs, original hashes, deadlines and cleanup contracts remain unchanged.

The source-format copy preserves direct active samples and source metadata in its tested RGB8/RGB16 native fixtures, including low alpha, hidden RGB, supported byte orders and profiles. Actual full-size certification covers straight-alpha sRGB RGBA8; it does not extend that full-size result to every profile or depth. Measured cells perform no additional provider-byte readback. All 30 caller-owned copy allocations, release callbacks and deallocations reconcile, with zero active owned bytes at cleanup. This does not prove private ImageIO backing reclamation.

## Full-lifetime observations

All values are MiB. Peaks are kernel lifetime peaks. Cells perform different work; their differences do not identify allocator ownership.

| Cell | Entry→final RSS | Entry→final footprint | Warmup→measured RSS | Warmup→measured volatile resident | Final volatile resident | RSS peak | Footprint peak |
|---|---:|---:|---:|---:|---:|---:|---:|
| Raw draw | +294.437500 | +2.719116 | +0.609375 | 0 | 0 | 361.437500 | 255.315002 |
| PNG write | +292.546875 | +1.703552 | −2.750000 | 0 | 0.015625 | 362.328125 | 256.768188 |
| PNG decode/draw | +995.453125 | +4.470642 | +623.343750 | +622.375000 | 777.968750 | 1217.796875 | 243.129150 |
| Canonical owned | +291.562500 | +3.687927 | −2.156250 | 0 | 0.015625 | 424.046875 | 273.096436 |
| Source-format preserved | +1073.859375 | +4.955078 | +624.015625 | +622.375000 | 777.984375 | 1140.781250 | 287.690247 |
| Editable render/pin | +488.750000 | +37.641418 | +3.765625 | 0 | 141.843750 | 794.046875 | 444.659424 |

The preserving candidate's last three measured RSS increments are +78.03125 / +77.96875 / +78.015625 MiB. Its entry-to-final internal increase is 782.4375 MiB and reusable increase is 290.140625 MiB. Public buffer release therefore coexists with continued native backing growth; the candidate is rejected as a memory remedy.

Canonical owned drawing has smaller late increments (+0.1875 / +0.140625 / +0.15625 MiB), but retains material cold cost and a higher footprint peak than baseline decoding. It cannot replace original/source decoding without changing straight-alpha and 16-bit semantics. The editable control has no changed-document persistence commits and cannot substitute for the complete workflow.

The archived evidence retains all eight task counters, every warmup/late/release endpoint, sampled and kernel peaks, 1,056 derived intervals and 1,332 kernel observations. Kernel categories and ledgers overlap; reusable does not mean physically reclaimed. No purge, pressure or allocator-relief intervention is used. Native signature and identity checks bind executable SHA-256 `023bf189d4f4225e33432e4105343c0e96d36f26e155213854dbe681a9516b4c`; the 119 artifact does not contain the executable, so offline report replay does not claim to rehash an absent binary.

## Next candidate

The [drawing-only paired diagnostic](editable-drawing-pair-diagnostic.md) keeps model originals, source depth/profile, persistence, copy/reset and effect inputs intact. It prepares eligible sRGB8 drawing representations only at explicit rendering/presentation boundaries, while unsupported sources retain their native path. Production remains reference drawing. Complete cross-process pixels, document semantics, output-failure behavior and full native persistence/editor/pin/export lifetimes must qualify before any promotion. No 0.16 ledger row is promoted by either diagnostic.
