# Build 130: separate native editing from fixture reference work

[Source c6320bf68d5195a56cb77d0e8c58a43f3f3b8cbd](https://github.com/dandibbert/picshot/commit/c6320bf68d5195a56cb77d0e8c58a43f3f3b8cbd), [run 37871847933](https://github.com/dandibbert/picshot/actions/runs/37871847933), passed all four intended jobs. The new observations locate substantial fixture-only reference work within the old combined stage. They do not establish a memory remedy or clear release acceptance. ARM 0.15.1/build 111 and Intel 0.11/build 69 remain the latest delivered packages.

## Within-process intervals

All values below are MiB. The first interval includes editor construction, show, settling and native crop, not crop alone.

| Interval | Cold 4K RSS / footprint delta | Measured 4K RSS / footprint delta |
|---|---:|---:|
| Native editor/show/settling/crop | +219.453 / +83.907 | −60.141 to −60.109 / +75.546 to +77.937 |
| Fixture full reference render | +90.719 / +18.391 | +82.766 to +82.781 / +18.453 to +18.469 |
| Fixture reference-crop materialization | +22.906 / +22.906 | +22.891 / +22.891 |

The last boundary is the original eight-counter `reference-crop.before` observation. It has no full backing dictionary; nearby backing readings were not substituted. The first interval's declining RSS accompanies rising footprint and changes to volatile/graphics accounting. It does not prove net physical release or identify a private allocator. These intervals cannot be subtracted from a different run to estimate ordinary product memory.

## Full lifetime remains visible

The complete resource process still performs the unchanged small+4K functional work, two warmups and eight measured 4K workflows. It uses owned-sRGB8 input drawing, native final rendering and reference effects, matching the fixed diagnostic configuration.

| Observation | RSS / footprint, MiB |
|---|---:|
| Earliest drawing entry | 66.875 / 19.705 |
| Native entry | 86.344 / 38.893 |
| Final | 622.641 / 131.644 |
| Native entry to final delta | 536.297 / 92.752 |
| Earliest drawing entry to final delta | 555.766 / 111.939 |
| Cold entry to pre-warmup delta | 525.734 / 103.517 |
| Two warmups delta | 1.062 / −12.531 |
| Eight measured cycles delta | 9.500 / 1.766 |
| Final cleanup delta | 0 / 0 |
| 50 ms sampled maxima | 1569.656 / 589.943 |
| Kernel peaks reported through final observation | 1581.531 / 632.911 |

The final three released increments are RSS +0.328/+0.125/+0.516 MiB and footprint +1.266/−1.328/+0.391 MiB. Final volatile resident is 268.844 MiB; volatile ledger is 257.562 MiB. Overlapping counters are not added as independent ownership buckets or discarded as free memory.

Two scalar memory samples per workflow add non-atomic task-info reads and bounded metadata allocation. That overhead stays in subsequent readings. Final sidecar serialization follows native finalMemory; the last serialization peak is not claimed captured. Native entry follows context construction; neither entry is process birth. Resource native/owned-launch/wrapper durations are 81.291/82.126/82.694 seconds, with no forced cleanup.

## Verification

All 685 source blobs reconstruct tree `e8f911a005925cb3fb21e85442bdd2e6a57b8c5f`. Exact removal of the two new native hooks and three metadata lifecycle lines recovers the earlier fixture bodies; production rendering and lifetimes are unchanged.

ARM and Intel each pass 371 selected methods from 1774 discovered, exactly the previous 363 plus eight probe methods, without skips. The dedicated 72 methods overlap that coverage. The independent default output guard retains 24 cases, 432 refusals, 48 cache failures, 24 controller releases and 12 drained projection jobs, with no rejected output delivered.

The two fresh sequential app processes retain 35 certification hashes / 70 conversions and 205 resource hashes/conversions, 2/12 document pairs, 4/24 added memory points and all eight actual PNGs. Every resource image/document maps to certified work; byte/pixel checks and actual visual inspection pass. Normal and optimized checker replay reproduces identical attribution values. All owned app processes exit within unchanged 300/600/620-second bounds.

The archived ARM executable is 20,999,856 bytes, SHA256 `c35ed172f4326c0743bb51be5c1aab028203eb8e42c630cf967f9722139559d8`; actual plist source/version/build match 0.16.0/130. CI signature checks passed, and archived metadata records ad-hoc signing without notarization. Independent Linux review verifies bytes rather than rerunning codesign. Focused archives omit binaries; the separate default-guard archive omits executable/plist and deleted output payloads. Those limits are not replaced by inferred verification.

## Next gate

The separate product-resource fixture runs real save/reopen/pin lifecycles without duplicate reference rendering in the measured process. Its output pixels are checked independently after exit. This complements the full fidelity/failure fixture; it does not replace it or permit ignoring cold costs.

Initial build 131 compiled the app and standalone pixel verifier, but a new directory-safety method exposed two assertions: Foundation could leave a URL unresolved when a missing child lay below a symlinked ancestor. The pending correction checks each ancestor before creating directories or encoded output. It preserves the strict test and existing workload/deadlines. This is diagnostic file handling, and is explicitly not a race-free directory-fd traversal claim. No product measurement or installer acceptance follows from that initial compile checkpoint.
