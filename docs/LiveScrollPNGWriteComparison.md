# Bounded live-scroll PNG write comparison

This is one diagnostic comparison of the final PNG consumer's write bridge. The production default remains the existing Foundation route. No memory improvement or new installer acceptance is claimed before complete native evidence.

## Evidence motivating the single change

Build223, source `4cbc2d31b38b491f6e067916ba8971178b0afc67`, [run38121084147](https://github.com/dandibbert/picshot/actions/runs/38121084147), completed the actual installed native demonstration and all ten resource sessions. Each resource cycle delivered and accepted218 frames, emitted one1280×7136 PNG, and released all218 source buffers plus session/control/window owners. Peak source ownership was two1280×960 buffers (9,830,400 bytes); both150ms and1000ms cleanup observations had zero live bytes, attached window graphs or remaining spool entries.

The fixed footprint growth gate failed: cycle2→10 grew9,863,168 bytes against9,830,400, an excess of32,768 bytes. The largest increment was cycle2→3 (+8,503,296), appearing between the pre-PNG and finalized-PNG boundaries. The final three increments were131,072,81,920 and49,152 bytes. This identifies an encoding boundary, not the allocator or encoder cause; it does not establish a permanent plateau. Grayscale conversion is not established as the cause of this miss.

Final RSS was240,697,344 bytes and kernel resident peak307,068,928; final physical footprint36,817,216 and kernel footprint peak120,080,576. Combined volatile ledger stayed18,513,920 at every settled cycle endpoint. The highest observed footprint118,999,232 was at the first `source-ready` boundary, before session sampling; input-validation work is part of this diagnostic process. These counters are distinct views and must not be added. Cold RSS/peak diagnostic targets missed; that is separately recorded, not converted to an acceptance failure or a stability claim.

Build223's resource gate stopped the independent ten-output verifier and review-file preparation. Each resource PNG was22,041,073 bytes, but none was uploaded; their pixels cannot be reconstructed as verified223 outputs. The separate prequalification PNG and the three native demonstration images passed their own comparisons. Subsequent full native, model and general installed gates were skipped. Intel independently failed an unchanged rich-pin initialization latency assertion (2.774 seconds against2.0), not a scrolling resource assertion.

## One variable and fixed boundaries

The paired cells use the same exact executable and prepared pixel input, the same ImageIO PNG destination, compression settings and output checks. `foundation` retains the existing synchronous Data/FileHandle bridge. `posix` writes the same consumer callback bytes to the same owned file descriptor, handling partial writes, interruption, zero/error results, cancellation and the unchanged512MiB encoded limit. Existing-file refusal, close and partial-output removal remain in place. The existing `fileExists` plus `createFile` sequence is unchanged; it is not an exclusive-create syscall or atomic rename, and these tests do not establish concurrent-creator protection.

The backend is explicitly selected only for the diagnostic final-PNG recipient. Default production call sites remain Foundation. Each cell uses fresh app processes for certification, measurement and independent validation. Both complete the original2 warmups plus8 measured sessions,218 frames per session, fixed output and reversal sequence. The590-second app,600-second launcher,180-second per-session and existing memory/ownership/output gates remain unchanged. A1500-second bounded outer pair and the existing40-minute focused job are independent enclosing limits, not permission to shorten work or extend any product deadline.

Both cells run even if the first complete cell fails its memory gate. A complete failed-memory measurement still gets independent verification of all ten PNGs, while its qualification remains failed. Incomplete, identity-mismatched or functionally failed measurements cannot become a completed cell. Each output certificate binds encoded size/SHA-256 and every decoded pixel to the independent input; the final PNG and reference are retained in separate bounded artifacts. No decoding is added to the measured process.

Cold/entry/peak/warm/final/late readings and ownership evidence are reported for both cells. A candidate can be considered only if its relevant footprint growth improves, its unchanged qualification gates and pixel/cleanup checks pass, and the complete RSS/footprint/latency record has no material regression. A noisy favorable endpoint alone is not sufficient. A failed or inconclusive comparison rejects this change; this bounded task does not expand into grayscale or alternative-encoder experiments.

## Pre-run verification

Thirteen authored native writer cases add to the existing88 LiveScroll cases; the explicit101-method focused inventory is checked against actual XCTest results. The exhaustive source inventory is2148 methods/245 classes, preserving all2047 accepted214 method IDs and their original baseline hash. Native compilation and execution remain pending.

Nineteen portable report/orchestration cases passed normally and with Python optimization. These are synthetic scalar-report tests, not macOS resource or PNG evidence. They preserve complete failed-memory cells, reject missing work/owners, altered gates, stale measurement/certificate hashes, backend/app mismatches and duplicated or resized outputs, and exercise running the second cell after the first fails. The existing33 inventory/planner tests and16 source-binding tests also passed in both modes.

## Build 224 result: candidate rejected, Foundation retained

Source `feca5122ce1a6994a5af98c8c9b7b005b0e464c5`, [run38123754810](https://github.com/dandibbert/picshot/actions/runs/38123754810), completed the single paired experiment. The 101 exact LiveScroll native methods passed once each, with zero skips; the bounded native command took 109.361 seconds. The ordinary-text, illustrated and axis-moved native demonstrations again matched every reference pixel. This job launched the exact packaged `dist/PicShot.app`; it did not unpack a ZIP or qualify an installer.

Both cells used executable SHA-256 `ab738f2955bcfeb87b11dc1f5920c8550b63749f51ea97633526143fc25473e0`, all ten original cycles and the same inputs. Each completed 218 accepted frames per cycle, one Finish, balanced source buffers, released controllers/windows and empty owned spools. All twenty outputs passed native independent-process pixel checks and share encoded SHA-256 `16b81a2ddc158b85503fb118a256603779ea6ee27b82a7b82e32143343e9ad0d`, 22,041,073 bytes. The separately retained cycle10 PNG from each cell and one reference were independently decoded and compared across all 36,536,320 RGBA bytes (1280 by 7136), with archive SHA/CRC verified. Those local comparisons cover three retained files; all twenty native certificates were audited, not twenty locally downloaded images.

| Bytes, unless stated | Foundation control | POSIX candidate |
| --- | ---: | ---: |
| Entry RSS | 70,680,576 | 70,467,584 |
| Second-cycle settled RSS | 295,174,144 | 259,883,008 |
| Final RSS | 286,212,096 | 285,491,200 |
| Sampled RSS peak | 337,084,416 | 331,022,336 |
| Kernel RSS peak | 348,995,584 | 345,800,704 |
| Warm RSS growth | -8,978,432 | **25,542,656, failed** |
| Last three RSS increments | 1,146,880 / 180,224 / 114,688 | 3,506,176 / 1,097,728 / 49,152 |
| Entry physical footprint | 20,514,880 | 20,400,192 |
| Second-cycle settled footprint | 27,494,784 | 33,900,864 |
| Final physical footprint | 36,800,896 | 36,702,592 |
| Sampled footprint peak | 119,670,976 | 119,130,304 |
| Highest separately read source-ready footprint | 119,687,360 | 119,179,456 |
| Kernel footprint peak | 120,473,792 | 119,982,272 |
| Warm footprint growth | 9,289,728 | 2,736,192 |
| Last three footprint increments | 1,163,328 / -884,800 / 98,368 | -999,488 / 1,114,176 / -1,015,872 |
| Settled/final combined volatile ledger | 18,513,920 | 18,513,920 |
| Warm and last-three volatile growth | 0; 0 / 0 / 0 | 0; 0 / 0 / 0 |
| Measurement duration, seconds | 308.695 | 286.967 |
| Original warm/late qualification | passed in this trial | **failed** |

Independent recomputation matched every cold, warm, late and peak assessment. The POSIX warm RSS increase exceeds the unchanged 9,830,400-byte gate by 15,712,256 bytes, even though its late-three sum (4,653,056) stays under 4,915,200. Its smaller warm footprint increase begins from a larger second-cycle baseline; final total RSS/footprint are nearly identical. This is not a useful demonstrated total-memory reduction. POSIX is rejected and the production default stays Foundation. No additional writer/encoder/grayscale experiment follows this pair.

Foundation passing this trial does not erase build223's 32,768-byte footprint miss. The different second-cycle endpoints and cold/final RSS show run variability; neither result proves a permanent plateau. Both cells miss the estimated cold/peak RSS targets, which remain diagnostic rather than silently changed acceptance limits. Final reusable RSS backing is still substantial and is not assumed reclaimed or free. All counters retain their distinct meanings; no leak-free, whole-app or physical-SCK claim follows.

The workflow's green status means that the pair was completely observed and preserved, including the failed candidate. `candidatePromoted` and `installerAcceptance` remain false. The follow-on resumes ordinary full qualification with Foundation unchanged, including the actual installed ZIP's original 2+8 cell, independent verification even after a complete memory failure, prior feature/model/resource gates, and the explicit real-SCK permission limitation.
