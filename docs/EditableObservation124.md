# Build 124: correct output, adverse cold memory, combined intervention

[Source e61a91f07fa2c55df3c4df9b05adda9b91788d4c](https://github.com/dandibbert/picshot/commit/e61a91f07fa2c55df3c4df9b05adda9b91788d4c), [run 37845186625](https://github.com/dandibbert/picshot/actions/runs/37845186625), passes its native fidelity, lifecycle and output guards. It **does not demonstrate a memory remedy**. Production defaults remain reference input drawing and native renderer storage; 0.16 remains held. Latest delivered versions remain ARM 0.15.1/build 111 and Intel 0.11/build 69.

## Verified work and exact identity

ARM and Intel each pass all 340 selected cases with no skips from 1,743 discovered IDs. All twenty renderer-storage methods pass on both architectures, including the original exact zero-owned-bytes/callback endpoint. The dedicated ARM process passes all 41 drawing/renderer cases. Separate default and candidate output guards retain the 24-case / 432-rejected-attempt / 24-controller contract. These overlapping selections are not additive coverage totals.

The actual archived 20,803,440-byte ARM executable hashes to `e66f078e177b1c8c611a90426beeafe1b824008176e85bb5ace74b3388379275`. Archived plist, exact source, executable bytes and every measured process agree. The four sequential owned process IDs are 25683/26212/26741/29409; the candidate guard PID is 25359. Each process confirms owned exit within unchanged deadlines.

Independent validation reproduces both the certification and final comparison from untouched raw reports. Each arm has a separate 35-comparison byte certificate; measured arms each complete small+4K functional work, two 4K warmups and eight measured 4K cycles, with all 205 corresponding hashes and twelve original/applied document pairs. All sixteen actual PNGs validate and were visually inspected. Every native assertion and original source-format/crop/effect/output semantics remain required.

Each measured arm performs exactly 229 final renders. The owned arm publishes and releases 229 caller allocations totaling 6,550,598,400 cumulative bytes, with matching callbacks and zero active bytes at released endpoints. Native storage is not tracked by that owned allocator. Presentation allocations are 108 versus 107 because actual view redraw scheduling differs slightly; logical workflow, renderer count, hashes and document work are identical. Public callbacks do not establish native cache or allocator reclamation.

## Complete lifetime cost

Strict cold means native entry→before warmup; earliest hook precedes native entry and includes additional setup. Neither is process birth. All eight counters, both Mach flavors, every measured/released endpoint, sampled peaks, kernel peaks and complete backing dictionaries remain in the raw evidence.

| Observation (MiB) | Native final storage | Owned final storage + draw pool |
|---|---:|---:|
| Native entry→final RSS | 528.406250 | 585.687500 |
| Earliest hook→final RSS | 548.156250 | 605.296875 |
| Native entry→final footprint | 91.063965 | 94.611328 |
| Native entry→final volatile resident | 268.343750 | 268.093750 |
| Strict cold RSS | 525.515625 | 591.875000 |
| Strict cold footprint | 101.345215 | 105.251953 |
| Next two warmups RSS | -18.687500 | -5.843750 |
| Eight measured cycles RSS | 21.578125 | -0.343750 |
| Eight measured cycles footprint | 0.859314 | 1.968689 |
| Kernel lifetime RSS peak | 1574.500000 | 1560.828125 |
| Kernel lifetime footprint peak | 597.083008 | 594.442627 |
| Sampled RSS peak | 1569.390625 | 1543.562500 |

The final RSS delta is 57.28125 MiB worse in the owned arm, despite its small negative measured-phase change. Of that difference, 54.875 MiB is additional kernel reusable classification. It remains resident accounting; it is not proof of physical reclamation or allocation ownership. Entry→final footprint is also worse by about 3.547 MiB. Candidate elapsed time is 122.159 seconds versus 110.954 seconds for the native control.

The last three released RSS increments are −8.125/−2.59375/+11.953125 MiB native and −9.015625/+9.515625/+1.015625 MiB owned. Cleanup after the measured endpoint changes all eight counters by zero in both arms. Negative net late growth cannot hide roughly 592 MiB of candidate cold RSS or establish a plateau. Sampled peaks can miss transients and differ from kernel lifetime peaks; overlapping ledger categories must not be added as independent causes.

Checkpoints precede their named phases. The large `history-restore-edit-failure-retry → pin-create-reopen-hidden-preview` intervals enclose restored-editor replay, editing, failed-save/retry and reloading, before pin creation. Candidate measured increments there reach +321.4375 MiB RSS. This is a multi-operation interval, not a private allocation attribution.

## Autorelease scope is a second variable

Although both arms fix input drawing to owned-sRGB8, the legacy owned renderer wraps its private draw phase in an inner autoreleasepool; the native control does not. Build 124 therefore measures a **combined final-storage and draw-scope intervention**. Its valid pixel, ownership and effectiveness observations must not be relabeled as a pure storage experiment.

The next controls retain both old policies and the production default. Two new diagnostic policies share a whole-render pool around allocation, seeding, annotations and final output construction: native-pooled and owned-pooled. Separate four-process comparisons will measure native versus native-pooled (scope only), then native-pooled versus owned-pooled (matched-scope final storage). Each comparison retains the full original work, certifications, raw evidence and per-process deadlines. No memory verdict or feature row is promoted before those results and later installed release gates qualify an actual production correction.

## Prior failed gates remain distinct

Build 122 never ran this paired comparison: its combined portable-contract step exceeded its orchestration allowance, and a test-only missing `try` prevented native test compilation. Build 123 corrected those issues but failed one provider-only endpoint test on both architectures and the dedicated ARM process. Its `provider.data` observation was outside a draining scope.

Build 124 changes only that test observation: it scopes the temporary data read, retains every final zero-byte/callback assertion, and adds two live-provider assertions after the observation scope. Both architectures now pass. This supports the observation-lifetime explanation and does not establish a production leak cause. App implementation and native runtime deadlines are unchanged across 122–124; no failed gate is retrospectively accepted.
