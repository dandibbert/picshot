# Verification evidence and release boundary

Reviewed **7 October 2026**. **Accepted and delivered ARM is 0.10.0 build 67 at [03cf310](https://github.com/dandibbert/picshot/commit/03cf310c4228bdbfdc3f9a81ceec810651552f81)**, terminal-success [run 37575644941 / ARM job 112643816594](https://github.com/dandibbert/picshot/actions/runs/37575644941/job/112643816594); ARM DMG/ZIP replacements and the updated guide are confirmed. **Delivered Intel remains 0.9.0 build 52 at b44c1fb**, with its original independent evidence below. Successful Intel ac8 is historical and was not delivered; Intel 03cf310 is rerunning unchanged after aggregate full-suite budget exhaustion. Native/package acceptance is not full parity, real-device acceptance or leak freedom. All **133 requirements** remain in [PARITY.md](PARITY.md).

The earlier ARM 0.5 delivery at [87eaedf16aaf6c2df2001d35ce08af2762ac33c2](https://github.com/dandibbert/picshot/commit/87eaedf16aaf6c2df2001d35ce08af2762ac33c2), delivered at 15:57 UTC, passed [run 37489170662](https://github.com/dandibbert/picshot/actions/runs/37489170662), [build/package job 112357029365](https://github.com/dandibbert/picshot/actions/runs/37489170662/job/112357029365) and [attribution job 112357029582](https://github.com/dandibbert/picshot/actions/runs/37489170662/job/112357029582). Intel 2043254 changes only `.github/workflows/macos.yml` from that application source. Its annotation effects, camera/live annotations, recovery and corrected isolated GIF export remain included in 0.6. [04999d0](https://github.com/dandibbert/picshot/commit/04999d0fd92a00e11bcbbfd2c9fe813f8ea9f11d), [run 37471951304](https://github.com/dandibbert/picshot/actions/runs/37471951304), remains an earlier both-architecture functionality checkpoint. Results and measurements apply only to their identified source, artifact, process and fixture; identical application code does not make differently packaged bytes or measurements interchangeable. Current ARM 0.7 evidence is recorded separately below; older measurements retain their original provenance.


## Accepted ARM 0.10 at 03cf310, build 67

[03cf310](https://github.com/dandibbert/picshot/commit/03cf310c4228bdbfdc3f9a81ceec810651552f81), [run 37575644941 / ARM job 112643816594](https://github.com/dandibbert/picshot/actions/runs/37575644941/job/112643816594), passes **1,190 ordinary tests: 1,187 passed, 3 intentional pre-weight model skips, zero failures; 732 focused and 12 actual-model tests passed**. The three ordinary skips require explicitly supplied formula/table/smart-erase weights; the later real-weight stage passes. Stages overlap and are not additive independent totals. Native runtime is **macOS 15.7.9 (24G830), Xcode 16.4 / macOS SDK 15.5**. Embedded metadata identifies 0.10.0, build 67, arm64, macOS 14 minimum, ad-hoc signing and no notarization; macOS 14 runtime is untested.

Both installed ZIP/DMG independently pass expected architecture/signature, no-argument LaunchServices, visible native windows, Save/Retry/owned export panels, actual codecs, signed models, capture/export/recognition, pin sessions/groups, interaction, recording composition and recording WebP. Actual own-app Accessibility remains `skipped-no-existing-accessibility-permission`; no TCC grant or foreign-app acceptance is inferred. Separate own-child SIGKILL recovery passes with five fragments, five seconds recovered, 50 video / 239,552 audio frames decoded, unchanged source and confirmed cleanup; no live devices were started.

### Exact ARM 0.10 bytes and integrity

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `PicShot-0.10.0-macos-arm64.build-info.json` | 177 | `9e9aff7b0a2ba9f5f197fef1f697efbf3ca6280cba726b75eed6bc14671b4b51` |
| `PicShot-0.10.0-macos-arm64.dmg` | 19,656,613 | `ba488d73805e35e2fc48ca641d10bab44c0b471848d4d51ed2b9832b6d07a2d6` |
| `PicShot-0.10.0-macos-arm64.zip` | 16,960,876 | `d71c84a3dd4331f7dafccad9279db59b2727e15280efeee48ac32579352910e4` |

All sidecars match actual downloaded bytes. ZIP CRC checks pass; embedded build-info is byte-identical to external metadata, and Info.plist agrees on version/build/source. The bundled formula runtime checksum and 78 CodeResources file digests match; all 166 application sourceCommit fields in the inspected JSON artifacts identify 03cf310. The native package log verifies the DMG internal checksum and relocated renderer/missing-resource rejection. These checks do not establish notarization, publisher identity or Gatekeeper acceptance.

### New pin functionality and exact scope

- **LaTeX:** actual bundled renderer, retained source/options, atomic edit/invalid-draft/cancel, source copy, ten-source/options undo, restore using stored PNG without automatic rendering, and actual .tex/MathML/SVG/PNG/PDF exports pass in both installs. Recognition uses the same prepared route, but the pin fixture itself does no OCR/model inference. White backing is presentation-only; exported PNG alpha is unchanged
- **Owned Save chooser:** native bounds/visibility/ownership checks keep the same edge-positioned pin exactly 180 × 72 screen points before showing, while open and after real Cancel. Controller/content/source remain intact; callbacks release and no orphan panel remains. The chooser is not a sheet. Remote chooser pixels were not captured; physical Retina/multi-display placement is unverified
- **Group:** shown native manager/context selection, Escape, numeric move/scale Apply, six alignments, undo/redo and constrained-window atomic rollback pass for image, rotated fixed-zoom image and text plus an unselected sentinel. Rollback preserves all live presentations, manifest/index/assets and history. Sizes stay unchanged by alignment; center origins use the destination pixel grid, with possible half-grid residuals. Direct collective drag/resize is absent
- **Desktop policy and dismissal:** public flags, menus, Settings and synthetic lifecycle pass. Same-mode draft preservation and actual-change editor teardown regressions pass in both ordinary and focused tests. `physicalSpacesVerified=false`; global all/assigned-Space selection does not establish named/per-pin placement, active-Space following or original-Space restart restoration

### Installed pin resources: comparable endpoints

All values are **ARM 03cf310**, with independent ZIP/DMG baselines. Formula uses 2 warm-ups + 12 hide/show/close/reopen cycles, **zero fixture-requested renders in the measured phase**; actual render/edit/export occurs outside it. Group uses 3 + 20 transform/undo/inspector/hide/show cycles. Comparable endpoints retain one formula or four group pins; final cleanup has zero and is reported separately.

| Install / workload | RSS baseline → measured end bytes | RSS change bytes | Last three single-cycle RSS increments bytes | Footprint change bytes |
| --- | --- | ---: | --- | ---: |
| ZIP / latex | 104,120,320 → 104,218,624 | +98,304 | +0 / +0 / +0 | +163,840 |
| ZIP / group | 122,372,096 → 122,650,624 | +278,528 | +49,152 / +0 / +0 | -491,520 |
| DMG / latex | 103,268,352 → 103,415,808 | +147,456 | +147,456 / +0 / +0 | +147,456 |
| DMG / group | 122,142,720 → 122,208,256 | +65,536 | +0 / +32,768 / -32,768 | +180,224 |

All four reports complete their observations with zero failed RSS/footprint samples, unchanged asset hashes, zero final live pins and zero retained tracked controllers/content; formula source models also release. Continuous 50 ms sampling includes asset validation/cleanup and can miss transients. Parent measurements exclude WindowServer/GPU/helpers. Bounded releases and flat/negative intervals do not establish a plateau, zero leaks, repeated-render memory behavior or a preview-memory remedy.

### Other installed ARM resources and unresolved preview growth

| Workload | ZIP RSS change MiB | DMG RSS change MiB | Scope / late interval |
| --- | ---: | ---: | --- |
| Editor/pin lifecycle | +0.6875 | +0.34375 | 10 + 40; last ten +0.0625/+0.03125; windows 7 → 7, zero tracked retained content/windows |
| Save jobs | +0.375 | +0.453125 | 2 + 8 small real jobs; footprint +0.328125/+0.28125; jobs/input/controllers/owned temporary files released |
| Static WebP/AVIF | +25.71875 | +24.8125 | 768 × 576, three per format plus encode/preview/independent decode/quality/save/cancel; no separate warm-up or phases |
| PNG/JPEG/BMP/PDF | +25.671875 | +25.890625 | 1440 × 900, 1 + 4; final interval +7.515625/+2.109375 MiB despite session/job/temp cleanup |
| Full GIF export plus decode | +0.015625 | Not run | ZIP-only 1 + 4, 30 seconds/360 frames at 480 × 270; last RSS interval 0; exit/cancel/cleanup pass |

**Existing preview-resource growth remains unresolved.** Static-codec and existing-format measurements have different work/stage scopes; they do not establish an encoder owner or a production memory fix. Model-child parent-polled peak RSS bytes, ZIP/DMG respectively: **354,320,384 / 411,058,176 formula; 193,757,184 / 209,616,896 table; 1,633,583,104 / 1,852,456,960 smart erase**. All exit 0 with confirmed cleanup. GIF's four child self-RSS peaks are 74,694,656 / 74,809,344 / 75,530,240 / 74,956,800 bytes; its separate 1920 × 1080/12-frame self-peak is 179,355,648 bytes. Sampled peaks are not whole-system or kernel lifetime maxima; the short high-resolution case is not maximum square area/frame count or sustained use.

### Source-qualified candidate history and Intel boundary

- e8209a8 / run 37559437370 compiled on both architectures and passed public desktop flags, but failed LaTeX raster display and group Apply; no release was accepted
- 761c423 / run 37566701405 passed the new early UI on both, then retained one focused assertion: the formula editor view after policy dismissal. Its early resource figures are not final 03cf310 figures
- [Intel ac8a93e / run 37572456117, job 112633899835](https://github.com/dandibbert/picshot/actions/runs/37572456117/job/112633899835) passed 1,190 ordinary (3 intentional pre-weight skips), 732 focused, 12 actual-model and both installed formats at its own source, including the corrected dismissal regression. It is an **undelivered historical candidate**, not current Intel 0.10
- Intel 03cf310 reached the aggregate 420-second ordinary-suite budget. Completed-test runtime increased about 63.1 seconds across suites relative to the prior run; no assertion failure or blocked GIF/Scroll case is established. GIF pre-frame/collision cases returned. The same source is rerunning; no successful result is assigned to it. Delivered Intel remains 0.9 b44c1fb

The separate 696b2286 / run 37567338578 decode/draw-helper diagnostic is not a production preview change: at 768 × 576, 2 + 12, the old 40.5 MiB volatile accumulation disappears, but parent RSS still grows 8.484375 MiB ARM / 0.5859375 MiB Intel and median operation time is about 266/572 ms versus 4/20 ms controls. Larger inputs, UI responsiveness and parent-loss orphan cleanup remain open. Existing 0.9 preview-memory caveats remain historical evidence of the unresolved problem, not a claimed 0.10 fix.

## Accepted ARM and Intel 0.9 at b44c1fb

### Historical review status before ARM 0.10

Reviewed **7 October 2026**. **ARM and Intel 0.9.0 build 52 are independently accepted at [b44c1fb0ecc71fbe652ed3c74e377e8f3ea8ba27](https://github.com/dandibbert/picshot/commit/b44c1fb0ecc71fbe652ed3c74e377e8f3ea8ba27)** in [run 37547871044](https://github.com/dandibbert/picshot/actions/runs/37547871044), with terminal-success [ARM job 112556128669](https://github.com/dandibbert/picshot/actions/runs/37547871044/job/112556128669) and [Intel job 112556128799](https://github.com/dandibbert/picshot/actions/runs/37547871044/job/112556128799). Both architecture installer replacements are confirmed; Intel's confirmation is 00:28 UTC. Each result uses its actual ZIP/DMG and own measurements. Earlier candidate failures and diagnostics remain source-labeled history. The **133-row scope** remains in [PARITY.md](PARITY.md); native/package acceptance is not full parity, whole-device acceptance or leak freedom. Diagnostic-only follow-up source 7c3e76c does not replace these accepted installers or change their app source.

Downloaded final logs on each architecture independently report **1,080 ordinary tests: 1,077 passed, 3 intentional pre-weight model skips and zero failures; 635 focused passed; 12 actual-model tests passed**. The selected groups overlap and are not additive distinct-test totals. Both installed ZIP/DMG on each architecture pass architecture/signature, no-argument LaunchServices, visible owned UI, save/naming/Retry, codecs, signed models, interaction, recording composition/recovery and cleanup gates. **Full GIF resource/cancellation runs from ZIP only.** Native evidence is macOS 15.7.9 (24G830); macOS 14 runtime remains untested. Packages remain ad-hoc signed and not notarized.

### Exact ARM 0.9 bytes

Downloaded sidecars match both actual installers and both build-info copies. Metadata identifies 0.9.0, arm64, exact source b44c1fb, macOS 14 minimum, ad-hoc signing and `notarized: false`; package build is 52.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `PicShot-0.9.0-macos-arm64.dmg` | 18,724,951 | `b0d3f8c170d10fe39699a5ebb848b02e3737c8d9457651b81695a504a26ea136` |
| `PicShot-0.9.0-macos-arm64.zip` | 16,184,932 | `956bd7aaa906307ad7fc3b3d1a3d3da63502694e66f3aa1f36304036e721ad8d` |
| `PicShot-0.9.0-macos-arm64.build-info.json` | 176 | `3cc3049cec51954f29167b416bb9f5100ba889d51953a26f3ff40e1cf77979a8` |


### Exact Intel 0.9 bytes and independent gates

The independent Intel logs report **1,080 ordinary tests: 1,077 passed, 3 intentional pre-weight skips, zero failures; 635 focused passed; 12 actual-model passed**. Both installed formats pass startup and source-specific owned-panel, Save/Retry, codecs, models and existing feature/recovery gates. Final Intel focused logs independently pass frozen export bytes, parent movement/close and real-child late-exit/cross-format recovery; ARM is not used as Intel execution evidence.

Every downloaded Intel installer/build-info sidecar matches actual bytes, and duplicate metadata copies match. Metadata identifies source b44c1fb, 0.9.0, x86_64, macOS 14 minimum, ad-hoc signing and no notarization. Tests run on macOS 15.7.9 (24G830), not macOS 14.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `PicShot-0.9.0-macos-x86_64.dmg` | 21,913,370 | `9cdb5ee2ae1cae1b77ddd263f6e8bfc27a10d3c5f149a7d458164fdf0b64d387` |
| `PicShot-0.9.0-macos-x86_64.zip` | 18,689,723 | `5cd57817a28a7aaa5036e4c7b4a8f44bfc6bea847fd875a4230a04e1beddcb1e` |
| `PicShot-0.9.0-macos-x86_64.build-info.json` | 177 | `8607d650dba9799aef6f3995943afedc36db9e2767fd8a27a3d19f1377e0fd48` |

### Final ARM/Intel UI, save and exceptional GIF scope

Production export UI now uses **owned child panels rather than AppKit sheets**. Native tests verify frozen export bytes despite later editor edits, panel placement after parent movement, parent-close cancellation/release, cancel preserving the parent and toolbar hierarchy/alignment. Both installed save reports pass light/dark settings, template rejection/preview, folder/picker cancellation, actual flattened quick-save pixels, Keep Both/Cancel, source preservation, quiet finalized-action copies, exact saved PNG bytes on a private pasteboard and injected copy-failure file preservation. This is source-specific synthetic/native evidence, not general external-app clipboard or physical-user acceptance.

The final focused log passes `testUnconfirmedGIFExitRemovesOuterStageWhileSiblingSurvivesUntilCrossFormatRecovery`. It uses a real test child with injected stop actions to simulate late exit: caller trim is removed while the sibling child retains its independent source; after exit, a WebP/AVIF attempt recovers admission and owned cleanup. Source/old target preservation and ownership/link/race refusal cases also pass. This addresses the specified 0.8 residue scenario. Unknown/replaced entries still deliberately block deletion; **all crashes, power loss and storage removal are not thereby guaranteed clean**.

### Final installed ARM resources, separated by workload

All values below identify b44c1fb installed bytes. They are sampled observations, not maximum-resolution, whole-system or zero-leak acceptance. ZIP and DMG have separate baselines; negative/flat intervals do not establish a plateau.

| Workload | ZIP RSS change MiB | DMG RSS change MiB | Scope and final interval |
| --- | ---: | ---: | --- |
| Editor/pin lifecycle | +0.203125 | −1.000000 | 10 warm-ups + 40 measured; final 10 cycles +0.140625 / 0; windows 7 → 7, zero tracked controllers/content/cycle windows |
| Save workflow | −1.812500 | −1.921875 | 2 warm-ups + 8 small actual jobs; footprint +0.265625 / +0.140625; active jobs/retained input/owned temporary files zero |
| Static WebP/AVIF combined | +20.046875 | +22.281250 | 3 repeated exports per format plus alpha/quality, independent parent decode, preview/save/cancel; no separated warm-up/phases; footprint −9.171875 / −2.296875 |
| Existing PNG/JPEG/BMP/PDF | +10.500000 | +23.546875 | 1440 × 900, 1 warm-up + 4 measured; last RSS interval −12.968750 / +0.015625; sessions/jobs/temporary cleanup confirmed |
| Full GIF export plus decode | +0.109375 | Not run | ZIP: 1 warm-up + 4 measured; final RSS interval 0; actual child exit/cancel/cleanup confirmed |

The combined codec sample does not attribute its retained RSS to encoder, decoder or UI, nor prove a production memory fix relative to differently scoped older runs. Volatile PNG/WebP/PDF preview/raster backing remains a separate unresolved concern. Model helper parent-polled peaks, ZIP/DMG respectively, are **321,110,016/304,037,888 bytes formula**, **223,805,440/225,116,160 bytes table**, and **1,627,324,416/1,840,103,424 bytes smart erase**; all exit 0 and cleanup is confirmed. Sampling can miss transient peaks and excludes framework/GPU/other processes. These child peaks must not replace main-process workload measurements.


### Final installed Intel resources: separate evidence, continuing growth

Each Intel workload has its own baseline and must not inherit ARM deltas. Parent samples and child samples remain separate scopes; the complete GIF resource profile is **ZIP-only**.

| Intel workload | ZIP RSS change MiB | DMG RSS change MiB | Scope and final interval |
| --- | ---: | ---: | --- |
| Editor/pin lifecycle | +0.80078125 | +0.82421875 | 10 warm-ups + 40 measured; final 10 cycles +0.078125 / +0.1875; windows 7 → 7 and zero retained tracked content/windows |
| Save workflow | −1.8359375 | −1.80078125 | 2 warm-ups + 8 small actual jobs; footprint +0.12109375 / +0.03125; tracked jobs/input and owned temporary files cleaned |
| Static WebP/AVIF combined | +23.81640625 | +16.13671875 | No separated warm-up or encode/preview/independent-decode phases; footprint −2.35546875 / −3.1875 |
| Existing PNG/JPEG/BMP/PDF | +29.7421875 | +43.1015625 | 1 warm-up + 4 measured; final RSS interval +10.69140625 / +6.390625; footprint +0.90234375 / +2.84375 |
| Full GIF export plus decode | +0.16015625 | Not run | ZIP: 1 warm-up + 4 measured; last RSS interval +0.01953125; real helper exits/cancellation/cleanup pass |

The existing-format RSS deltas across the four cycles are **2,719,744 / 10,608,640 / 19,976,192 / 31,186,944 bytes ZIP**, and **15,491,072 / 28,176,384 / 38,494,208 / 45,195,264 bytes DMG**, each relative to its post-warm-up baseline. Growth continues through both final intervals despite sessions/jobs/owned-file cleanup. **This remains unresolved; successful cleanup, small footprint changes, or source14c's distinct AVIF delayed drop do not establish stable memory or zero leaks.**

Intel model parent-polled peaks, ZIP/DMG respectively, are **300,613,632/300,126,208 bytes formula**, **185,884,672/186,892,288 bytes table**, and **1,031,409,664/1,020,493,824 bytes smart erase**. All report child exit/cleanup confirmed. GIF children self-sample **47.46484375–47.578125 MiB** during the four-cycle ZIP profile; the separate 1920 × 1080/12-frame child self-peak is **133.00390625 MiB**. Different sampling schedules/process scopes cannot be added as a simultaneous system peak. This short high-resolution case is not maximum square area/frame count or sustained-use acceptance.

### Earlier de4/e4 checkpoints remain history

The prior de4b24a run stopped ARM before app compilation in the bounded-command Python stage (`wrapper_error` hid its underlying report), while Intel exposed a Swift/Darwin API-name collision. [e4e41ba30b0c0d2bfff9cfe14fcf70eeeb0fcf4d](https://github.com/dandibbert/picshot/commit/e4e41ba30b0c0d2bfff9cfe14fcf70eeeb0fcf4d), [run 37545701554](https://github.com/dandibbert/picshot/actions/runs/37545701554), used kevent64 and exposed fuller runner diagnostics. Its earlier compiling/packaging snapshot was not an accepted release and is not the current accepted app state. Final acceptance belongs only to b44c1fb; failed/incomplete candidates are not retroactively changed to passes.

### Earlier 14c: early successes and failed focused suites

[14c09d510247ae700ccdf143994d75b0cbb5f057](https://github.com/dandibbert/picshot/commit/14c09d510247ae700ccdf143994d75b0cbb5f057), [run 37541917737](https://github.com/dandibbert/picshot/actions/runs/37541917737), compiled on both architectures and passed early UI/backing-control stages. [ARM job 112536699632](https://github.com/dandibbert/picshot/actions/runs/37541917737/job/112536699632) then reported **631 focused tests, 35 failures (11 unexpected)**; [Intel job 112536699321](https://github.com/dandibbert/picshot/actions/runs/37541917737/job/112536699321) reported **631 tests, 34 failures (10 unexpected)**. These are failure counts, not a count of failed tests. Neither focused stage passed; final b44c1fb corrections now have their own independent ARM/Intel results, without changing this history.

The inspected ARM `preview.json` identifies 14c and `uiPreviewOnly=true`. Its save-workflow report records light/dark settings preview, invalid-template/folder-cancel checks, flattened quick-save pixels, Keep Both/Cancel collision behavior, source preservation, private PNG clipboard equality, injected copy-failure preservation and quiet final-action automatic copies. Two warm-ups and eight small measured jobs end without tracked active jobs/retained input, with controller release/temporary cleanup observed. No general clipboard, live desktop, network or user preferences are used. These narrow early checks are not full acceptance, sustained resources or a zero-leak result. Intel is not assigned uninspected per-field results from the ARM artifact.

### Accepted ARM/Intel SaveWorkflow scope and remaining gaps

Implemented routes: editor **Quick Save PNG**, **Save PNG and Copy**, **Save and Naming settings**; export-sheet **Quick Save** and **Save and Copy** for the prepared actual format, including current/original pin export routes. Settings drafts require **Save Settings**. A manual first-use folder selection can establish one remembered base directory; it is not per-destination profiles or general picker history.

Folder/filename templates support **{date}, {time}, {width}, {height}, {counter}**, and use the actual encoder extension. Date/time are save-job time in the current timezone with a fixed Gregorian/POSIX formatter, not capture/window/app metadata. Unicode-safe bounded names reject malformed/unknown variables and traversal; the persisted monotonic counter can leave gaps after cancellation. Window/app variables, arbitrary date-format expressions and replacement remain absent.

Automatic copies are **off by default**, require a folder and only follow explicit editor **Copy, Pin or Save-to-history** actions, writing the final flattened PNG. Immediate Copy does not wait for save admission. Capture acquisition, opening history, preview updates, ongoing editing, cancel and OCR do not trigger this path. It is neither continuous autosave nor retention of every raw capture. Application-owned jobs can outlive the editor.

Publication remains **save-new-copy**. Ask collisions offer Keep Both, another name or Cancel; bounded Keep Both suffix searches never replace existing files. An explicitly approved folder resolves once to its physical path; later jobs validate retained descriptors/identities rather than follow substituted ancestors. Source paths, occupied files and link aliases are protected by native-tested b44c1fb checks; unknown/replaced staging is not recursively deleted. Save and Copy commits the file before copying its same encoded bytes/type. Copy failure/cancellation preserves the file; copy failure offers Retry Copy. WebP/AVIF/PDF have no generic PNG fallback, per-type clipboard settings or general drag-out. Private-pasteboard evidence does not prove external-app compatibility.

Configured limits: **two jobs/controllers, 256 MiB estimated retained inputs/artifacts, 128 MiB encoded artifact, eight relative folder levels, 1,024-byte full path, 180-byte rendered component and 10,000 Keep Both attempts**, with a five-minute cooperative deadline. Native calls can finish after cancellation while queued inputs are cleared. These are safeguards, not whole-process RSS ceilings. See [SaveWorkflow.md](SaveWorkflow.md) for reachability, privacy and remaining acceptance.

### Accepted ARM/Intel Retry and scoped GIF cleanup

Accepted ARM/Intel b44c1fb adds visible Retry and cancellable shared GIF/WebP/AVIF-child admission waiting up to **300 seconds**, with stale-generation/close suppression. Delayed-cleanup doubles test scheduling, not actual codecs; genuine-helper and repeated/interrupted native UI evidence must remain separate. Independent final ARM/Intel acceptance is b44c1fb, not e4e41ba.

The verified 0.8 `exitUnconfirmed` outer-trim residue remains historical. Accepted ARM/Intel `OwnedVideoExportStage` separates caller trim from sibling helper jobs with identity-bound ownership; a surviving child keeps its independent source while caller staging can be cleaned. Unknown/replaced entries deliberately block deletion. The real-child late-exit test injects stop actions and exercises subsequent WebP/AVIF admission, source preservation and cleanup; it passes in the final b44c1fb focused suite. The assertion is limited to that workload and ownership scope; earlier failures remain history.

### Source71b diagnostics remain independent evidence

Completed [71b2f4e32cf99508e3efef69d6b5b30ae396b424](https://github.com/dandibbert/picshot/commit/71b2f4e32cf99508e3efef69d6b5b30ae396b424) controls use fresh processes with **two warm-ups plus twelve measured cycles**. Export-only, decode-only and combined modes on both architectures retain positive growth in their final three RSS intervals. Export-only excludes independent WebP/AVIF validation but still includes production PNG staging/preview and helper-preview decoding; decode-only reuses a separately prepared immutable input.

| Architecture / format | Export-only final RSS change | Decode-only final RSS change | Combined final RSS change |
| --- | ---: | ---: | ---: |
| ARM WebP | +28,950,528 B | +28,016,640 B | +50,036,736 B |
| ARM AVIF | +24,608,768 B | +25,919,488 B | +50,413,568 B |
| Intel WebP | +20,045,824 B | +21,319,680 B | +41,746,432 B |
| Intel AVIF | +19,927,040 B | +21,491,712 B | +41,963,520 B |

Footprint is mostly flat relative to RSS growth. No tracked controllers/queued jobs and confirmed fixture cleanup identify neither backing allocation nor owner. Later backing-control results require their own exact-source measurement analysis; **no plateau, purgeability, reclamation, no-leak or whole-system guarantee is inferred here**. These source71b observations do not become measurements of corrected 0.9 code.

### Independent 14c backing diagnostics are not final-artifact measurements

[ImageBackingAttribution.md](ImageBackingAttribution.md) records source14c controls: each architecture has 27 fresh-process controls, normally 2 warm-ups + 12 measured cycles, plus separately labeled 2+48 AVIF comparisons. Direct `TASK_VM_INFO_PURGEABLE` observations identify late **1.6875 MiB/cycle volatile-resident accumulation** in affected preview/native-export/PDF-render and decoded-WebP-raster paths; source creation/snapshot and several full-decode controls do not show that pattern. This is a measured accounting class, not proof that memory has been reclaimed or has zero cost.

ARM AVIF's distinct 48-cycle nonvolatile ledger adds 6.75 MiB early and loses that extra amount during the final 0.5-second settle; Intel is nearly flat. That delayed decrease is not reclamation evidence for accumulating PNG/WebP/PDF preview backing. Source-local cache removal did not demonstrate such reclamation. These diagnostic checkpoints remain separate from b44c1fb installed workloads and do not establish a production remedy, unlimited stability or a no-leak verdict.

### Ledger consequence

No category changes: **48 Code / 61 Partial / 15 Missing** across 124 behavior rows plus nine unchanged adaptation notes, preserving **133 IDs**, original requirements/acceptance checks and official citations. EXP-05/06 now have independently accepted ARM/Intel implementation and native evidence but retain material feature gaps. EXP-04 keeps Code status with b44c1fb Retry/owned-panel evidence. Both architecture results are now independently verified.

## Historical accepted ARM and Intel 0.8 at 7df562b

Downloaded source-labeled logs on each architecture report **986 ordinary tests (983 passed, 3 intentional pre-weight model skips), 541 focused tests and 12 actual-model tests**, all with zero failures. Focused/model selections overlap ordinary coverage; these are not additive distinct-test totals, and ordinary skips are not model passes. Both installed ZIP/DMG on each architecture pass normal startup/LaunchServices, signed helper/runtime checks, new static/animated codec fixtures and the existing capture, interaction, model, composition and recovery gates. Full GIF resource/cancellation remains ZIP-only. Reports identify macOS **15.7.9 (24G830)**; minimum deployment is macOS 14, whose runtime acceptance is still open.

### Exact ARM 0.8 installer bytes

All downloaded installer/build-info sidecars were checked against the actual files, and duplicate build-info copies match. Metadata identifies version 0.8.0, arm64, source `7df562b5c75830b6328d28c585667c761d38f5a2`, macOS 14 minimum, ad-hoc signing and `notarized: false`. These hashes identify exact bytes, not any later build sharing the version label.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `PicShot-0.8.0-macos-arm64.dmg` | 18,260,556 | `a65c9b6e1108fb18323227ddc2baba847dbb8b9a41bf729b3aea8839982725dc` |
| `PicShot-0.8.0-macos-arm64.zip` | 15,763,219 | `ddee7c4bf675c7dddc2518e3f1a6eeaa3b5f7d9445f97af02d73abfab6557dc4` |
| `PicShot-0.8.0-macos-arm64.build-info.json` | 176 | `9d7880245ad2c3b145d0c10cfe070100d84602d9d7b1f584626e500d34055238` |

### Exact Intel 0.8 installer bytes

The independent Intel job passes the same 986/541/12 stage counts with zero failures. Both installed static-codec and recording-WebP fixtures pass, along with prior native/model gates. All installer/build-info sidecars were checked against actual bytes; duplicate build-info copies match. Metadata identifies x86_64, version 0.8.0 and exact source 7df562b, with ad-hoc signing and no notarization.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `PicShot-0.8.0-macos-x86_64.dmg` | 21,403,348 | `1042a2377b3c579d8f3f2284ca61ea7a75e340312125bcff963158b91a9ffb03` |
| `PicShot-0.8.0-macos-x86_64.zip` | 18,232,106 | `8efbfb8a989f39d9c9e2ed1314defe9d87dcadfe3a416ba94d43bc99a605cb33` |
| `PicShot-0.8.0-macos-x86_64.build-info.json` | 177 | `3e9607eb814b7de28f26022d2e831d46a172f03867bb9aa87256d6aebfee08f7` |

### Real bundled still WebP/AVIF, not an ImageIO writer claim

An original C bridge links source-built **libwebp 1.6.0, libavif 1.4.2 and libaom 3.15.0** inside the separately signed on-demand codec helper. These are exact approved upstream pins, with full source/build/license provenance and system-only dynamic linkage documented in [WEB_CODECS.md](WEB_CODECS.md). The dependency-only ARM/Intel checkpoint [51260f2](https://github.com/dandibbert/picshot/commit/51260f2d4122fc9cdba1ad5bdc6f6a6c21677d8b), [run 37521945118](https://github.com/dandibbert/picshot/actions/runs/37521945118), is separate from whole-app acceptance. Codecs are not downloaded on export, and the still writer does not rely on missing ImageIO WebP/AVIF destinations.

At 7df562b, reachable native WebP/AVIF choices provide quality, lossless, preserve-alpha and alpha-quality controls with byte-derived preview and exclusive same-byte save. The original first five formats retain their existing paths. Native UI evidence includes genuine signed helpers, light/dark and regular/compact layout, independent decoded pixels/alpha, explicit alpha-off white composition, source preservation and no-overwrite. The synthetic 160 × 112 UI fixture produces WebP **288 bytes lossless / 422 bytes lossy** and AVIF **1,130 / 574 bytes**, with actual quality 0.37 and alpha quality 0.61 in its lossy cases. These sizes characterize one fixture, not general compression performance.

Both installed formats on each architecture repeat **three lossless WebP and three lossless AVIF exports** of original **768 × 576** pixels. Each output is decoded by the helper for preview and separately by parent ImageIO, with dimensions/type, every premultiplied color/alpha channel and saved-byte checks (pixel comparison tolerance 2). Alpha-off output is checked against white-composited reference pixels. Separate low/high quality runs change both actual bytes and decoded pixels: WebP **7,546 → 12,032 bytes**, AVIF **4,475 → 12,096 bytes ARM / 4,474 → 12,096 bytes Intel**. Collision preservation and ordinary cancellation confirm no published cancelled destination, observed child exit and owned cleanup. These results support **EXP-02 Code** for the integrated formats; broad visual quality, maximum-size and independent target-app workflows remain open.

Still-codec input is bounded to **16 million pixels, 8,192 pixels per side and 80,000,000 encoded input bytes**, with output at **128 MiB**. This is narrower than the existing ImageIO/PDF path's 100-million-pixel source limit. The helper uses a **300-second deadline** and **1 GiB sampled RSS abort threshold**, neither an instantaneous kernel quota nor whole-device ceiling. AVIF encoding is synchronous and internally buffers its native output before bounded forwarding; it is not a streaming/one-chunk-memory claim. One native-export child is shared by GIF/WebP/AVIF, independently of model-helper admission; an in-process ImageIO/PDF operation may still overlap it. Save-new-copy remains mandatory: no existing destination or source is overwritten.

### Static-codec resource observations: combined workload, no warm-up separation

`codec-export-resource.json` reports successful functional/process checks, but its parent memory observations cover the **combined** workload: the six repeated still exports plus alpha-off, low/high-quality and cancellation cases, helper previews and parent independent ImageIO decoding. A frozen source snapshot exists before baseline. There is **no separate warm-up, fresh-process export-only comparison or decoder/UI phase separation**. The word “settled” in per-run fields does not establish a plateau.

| Architecture / install | Parent baseline → final RSS bytes | RSS change | Footprint change |
| --- | --- | ---: | ---: |
| ARM ZIP | 466,157,568 → 505,184,256 | +39,026,688 (37.219 MiB) | −556,928 |
| ARM DMG | 468,959,232 → 508,084,224 | +39,124,992 (37.313 MiB) | −1,556,480 |
| Intel ZIP | 401,805,312 → 443,678,720 | +41,873,408 (39.934 MiB) | +1,187,840 |
| Intel DMG | 407,224,320 → 447,877,120 | +40,652,800 (38.770 MiB) | −3,715,072 |

Each recorded repeated-export child exits 0 with confirmed process exit and owned-directory cleanup. Real cancellation children report `cancelled`, exit 1 and cleanup; all four final fixture directories are removed. Parent RSS/footprint, parent-polled child RSS and child-reported samples are separate scopes; peaks can miss transients and exclude framework services/GPU/other helpers. **Footprint falls in three copies and rises in Intel ZIP; neither pattern nor successful child cleanup explains the retained parent RSS or establishes leak freedom.** These data identify neither allocation owner nor encoder/decoder attribution, and do not demonstrate a plateau, sustained-use bound or whole-system peak. The roughly 37.2–39.9 MiB retained parent RSS remains a specific follow-up investigation on both architectures.

### Animated recording WebP and its input boundary

The production recording preview exports the selected contiguous clip through a signed helper with lossy/lossless, quality, FPS and dimension choices. It is silent, loops indefinitely and writes sequential full-canvas frames, with rounded cumulative millisecond timing. The accepted source remains a regular local self-contained **H.264 MP4/optional AAC**, capped at **1 GiB**. Output limits are **60 seconds, 600 frames, 1,920-pixel maximum dimension, 8 MiB encoded frame and 64 MiB complete file**, with request validation up to 30 FPS. Reaching the frame cap reduces sampling rather than silently shortening selected duration.

All four installed copies pass lossless and lossy selected-range outputs of **12 frames, 1,200 ms, 160 × 90**: ARM files are respectively **5,068/3,028 bytes**, Intel **5,806/3,078 bytes**. These are independent architecture-specific results, not byte-identical output claims. The helper independently demuxes and fully decodes every composited canvas; parent checks container rectangles, positive durations, frame count and full size. Separately, **ImageIO on macOS 15.7.9 independently decodes all 12 frames with all delays totaling 1,200 ms** in each installed result. This compatibility probe is successful runtime evidence, not a universal animation-reader guarantee or a substitute for the helper verifier. Original MP4 bytes and racing destinations remain unchanged. Cancellation at first observed frame progress and after helper publication confirms cancellation fences, child exit and cleanup.

Native animation/container tests cover source-boundary sampling, variable millisecond timing, odd dimensions, lossless/lossy frames and transparent replacement at the low-level writer. **The public H.264 input route does not provide transparent-animation input.** Consequently **REC-03 is Partial**, not Missing, and the original transparency/motion acceptance requirement remains intact. Low-level alpha tests cannot stand in for that reachable end-to-end workflow. Live screen input, broad video formats, real external viewers across OS versions, maximum-size and long-running resource acceptance remain open.

### Historical 0.8 cleanup gap and later source boundary

At 7df562b, the inherited exceptional GIF path remained unresolved: after stop escalation returns **`exitUnconfirmed`**, the outer `.picshot-trim-*` directory is deliberately preserved. Eventual helper recovery removes its nested owned GIF job but does not own the outer selected clip, which can remain on disk. Ordinary confirmed cancellation passes and does not prove cleanup of this condition. The WebP path uses an independently copied private helper input, allowing outer trim cleanup without deleting a still-running helper's files. No complete exceptional-GIF-cleanup claim is made.

Save/queued-child/explicit-Retry and owned GIF-stage changes were not part of accepted 7df562b. Final ARM/Intel b44c1fb now have their own acceptance recorded above; those passes do not change this older build or its measurements. Both architecture results are now independently verified. The tested outer-trim fix does not imply all-crash or foreign-file cleanup guarantees.

### Existing lifecycle and ledger boundary

After 10 warm-ups, 40 measured editor/pin cycles report **+688,128/−2,080,768 bytes ARM ZIP/DMG** and **+1,183,744/+581,632 bytes Intel ZIP/DMG** main RSS, zero retained tracked controllers/content/windows and **7 → 7 windows**. These are separate phases from the combined static-codec measurements and must not replace them. Older GIF attribution remains source-specific history.

The 124 behavior rows now contain **48 Code / 61 Partial / 15 Missing** at verified ARM/Intel 0.8: EXP-02 moves Partial → Code; REC-03 moves Missing → Partial with transparent-input limitations explicit. The nine macOS notes remain three Partial, one Missing, four Platform and one permissions note, preserving **all 133 IDs**, original requirements/acceptance checks and official citations. Both architecture pipelines pass; installer delivery is confirmed separately from CI. Actual AX/TCC, real devices, broad quality, sustained resources and all other incomplete requirements remain open; full parity is not claimed.


## Historical available ARM and Intel 0.7 at a8600a3

[Source a8600a3a4739ec3663a5929d13154a55463ebcbf](https://github.com/dandibbert/picshot/commit/a8600a3a4739ec3663a5929d13154a55463ebcbf) passes both complete architecture jobs in run 37516561276. Downloaded ARM and Intel logs each report **934 ordinary tests (931 passed, 3 intentional model skips), 488 selected critical and 12 actual-model tests**, with zero failures. The selected stages overlap; these are not additive distinct-test totals. The ordinary skips are not model passes. Both actual installed ZIP and DMG on each architecture pass signature/architecture, no-argument LaunchServices, native windows, models, new capture/export/barcode fixtures, existing interaction/composition/recovery and cleanup gates. The full GIF resource/cancellation profile remains **ZIP-only**.

Native reports identify **macOS 15.7.9 (24G830), arm64 and x86_64**. The minimum remains macOS 14, whose runtime acceptance is untested. The packages are ad-hoc signed and not notarized. Native/package gates do not establish publisher identity, Gatekeeper acceptance, physical TCC interaction, foreign-app capture or full parity. Intel 0.7 now passes its independent exact-source pipeline; older 0.6 evidence remains unchanged as history below.

### Exact ARM 0.7 installer bytes

All downloaded ZIP/DMG and build-info sidecars were checked against the actual files; duplicate build-info copies match. Metadata identifies source a8600a3, version 0.7.0, arm64, macOS 14 minimum, ad-hoc signing and `notarized: false`. Installer replacements are confirmed; these hashes identify exact bytes rather than every build sharing the version label.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `PicShot-0.7.0-macos-arm64.dmg` | 14,623,506 | `b6fbdc36fcc6ef785f9476fc9f4a90f8519bec28f7fb5d0e32f40c4ea830234a` |
| `PicShot-0.7.0-macos-arm64.zip` | 13,138,304 | `adca2c077b180fb3b2f5feebf12d127715e2ed77415348d0abbf7fe08940f9a4` |
| `PicShot-0.7.0-macos-arm64.build-info.json` | 176 | `d8431170cc0d3a13c2b6674c96c50a7d6a12edee08d138e51700c4d30bb29b67` |

### Exact Intel 0.7 bytes and independent installed observations

Intel ZIP/DMG and both build-info sidecar copies were checked against the downloaded bytes. Metadata identifies the same source a8600a3, version 0.7.0, x86_64, macOS 14 minimum, ad-hoc signing and `notarized: false`.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `PicShot-0.7.0-macos-x86_64.dmg` | 17,991,358 | `b213b6ae6328df253456eb4b8ad92e98104285d118254506381e071e24a52b47` |
| `PicShot-0.7.0-macos-x86_64.zip` | 15,208,927 | `423fbbcbc9356a4a9f4a8a99a543dfed4b12b10aee221b68fc9084beb570f230` |
| `PicShot-0.7.0-macos-x86_64.build-info.json` | 177 | `d78918f9210c8103eca5a5a04b69cc6f4f76cfe4dd39e08ba29556c9479f3ea6` |

Intel independently passes **934 ordinary tests (931 passed, 3 intentional skips), 488 critical and 12 actual-model tests**, zero failures. Both installed formats pass startup, new capture/export/barcode fixtures and all earlier corresponding feature/model/recovery gates. Actual own-app AX remains skipped for missing existing permission; both codec probes list WebP/AVIF readers but no writers. Seven clean barcode fixtures pass without unsupported skips. The same-source code does not make architecture-specific bytes, timings or memory observations interchangeable.

One installed LaMa fixture completes in **58.132986 seconds ZIP / 87.762908 seconds DMG**, with sampled child RSS peaks **1,025,245,184 / 1,039,495,168 bytes**, respectively (554/813 parent samples at 100 ms). Both exit 0 with process exit and temporary cleanup confirmed. These total fixture timings are not child-only time or general latency guarantees; samples omit transient/system/GPU peaks. The unchanged Intel helper limit is 300 seconds/2 GiB.

The Intel ZIP GIF resource profile records **253,952 bytes parent RSS growth**, with successful child exits/cleanup and cancellation. This is the ordinary four-cycle installed profile, not a new eight-cycle attribution result; the latter remains labeled with original source 87eaedf. DMG does not inherit a separately executed full GIF profile.

### Presets and AX: distinguish executed fake-provider checks from skipped real AX

`CapturePreset`/store/controller and capture/menu/settings routes implement up to **32 metadata-only presets** in a versioned **128 KiB** catalog: name, integral source-pixel rectangle, stable display UUID/configuration and a 0/3/5/10-second delay. Native tests and both installed fixtures pass two-preset persistence/recreated-store, manager create/rename/delay/delete/invoke/cancel callbacks, frozen-pixel geometry and rejection paths. Missing, ambiguous or changed display position/resolution/scale/rotation is rejected rather than silently relocating the region. Actual app restart, delayed live acquisition and physical monitor changes remain acceptance work. This supports the narrow **CAP-06 Code** promotion, not those real-device checks.

The read-only AX provider requests role/geometry rather than labels, values or document text. Its serial worker bounds traversal to **80 nodes, 12 levels, 240 calls and 200 ms**, with **25 ms per-message timeout**; a deadline can overrun by one in-flight AX call. Both installed fake-provider fixtures pass parent/child/undo, stale cancellation, frozen-pixel selection and rectangle fallback. Actual own-app AX reports **`skipped-no-existing-accessibility-permission`** in each format. The aggregate fixture's pass is not an AX pass. Neither permissions nor TCC are changed, no foreign application is tested, and AX geometry sampled after screenshot freeze cannot prove that moving controls still match those pixels. **CAP-05 and MAC-02 remain Partial.**

### Encoded preview, corrected on-screen layout, BMP and paged PDF

The editor, current/original image pins and history route through an owned frozen raster snapshot and PNG/JPEG/TIFF/BMP/PDF sheet. Native tests pass requested-type independent decoding, pixel/dimension/alpha checks, mutable-provider/source-layer isolation, JPEG quality changes, PDF media boxes and exact integral-row/column seams, generation/close cancellation, destination/source/symlink protection and exclusive publication races. PNG/TIFF preserve alpha; JPEG/BMP flatten on white and PDF uses white paper.

Both installed native control/preview/save fixtures report JPEG quality **0.31 / 93,957 bytes**, with saved bytes exactly matching the preview artifact; Letter PDF with **36-point margins / three pages / 246,564 bytes** also saves identical bytes. PDF source row ranges are **[0,816), [816,1632), [1632,1711)**, without a repeated or omitted boundary. BMP has `BM` magic and **3,141,450 bytes**. The PDF bytes/hash may differ between runs; same-byte assertions compare each saved file with its own preview artifact, not a historical PDF hash. These are original synthetic fixture results, not universal codec/interoperability guarantees.

The earlier intrinsic-image window bug is corrected. Final JPEG/PDF content screenshots are **620 × 550**, window frames **620 × 578**, and every action stays inside the native visible frame. A constrained **580 × 480** visible-frame case yields **556 × 428** content / **556 × 456** window, preserving aspect ratio and all controls. Native attached-sheet and compact-layout tests pass. Pixel review of final ZIP JPEG and DMG PDF agrees with the report; broader screen/font/Retina permutations remain unverified.

PDF includes image-sized single page, A4/Letter, portrait/landscape, equal margins and vertical/horizontal pagination with actual encoded-page navigation. It is raster PDF, without searchable OCR, vectors, PDF/A or accessibility tagging. **EXP-03 and EXP-04 move narrowly to Code** for paged output and actual encoded preview. Crop is performed in the editor; the preview is bounded, not a full-resolution pixel display. Independent target-viewer and large/real-image workflows remain acceptance work.

**Save-new-copy only:** both picker validation and final exclusive publication reject existing files, original paths and symlink collisions. A private staged file is synchronized and published without replacement, with cancellation ordered against commit. There is no overwrite/replace-in-place workflow; unsupported filesystems fail rather than weaken that rule. Bounds remain **100 million source pixels, 128 MiB encoded bytes, 200 PDF pages, 1024-pixel/4 MiB decoded preview per page, first-plus-one-page cache up to 8 MiB, two sheets total/one per parent and one serial encoder**. A native codec already running can finish before cancellation releases its resources; these caps are not a measured process-RSS ceiling.

**At 0.7, WebP/AVIF were unintegrated.** All four installed macOS 15.7.9 architecture/format probes list readers but no writers (`not-in-native-destination-list`), so no native encoding/alpha pass is established. There are no format buttons or codec dependencies that add export support. This runtime observation is not a claim about every macOS version/architecture. **EXP-02 remains Partial** despite verified BMP. [ImageExport.md](ImageExport.md) retains implementation limits and official-source research.

### Multiple barcode evidence and limits

Both installed formats run actual Apple Vision and pass all seven original clean-label fixtures with exact text/source geometry: **QR, Code128, EAN13, UPC-A via zero-prefixed EAN13, Code39, DataMatrix and PDF417**, with **no unsupported fixture skips**. Multiple/rotated labels, near-miss rejection, duplicate-location semantics, list/source selection, keyboard copy, transformed geometry and stale/edit/hide/close invalidation pass. Twelve release cycles leave **zero retained barcode surfaces and zero active/waiting recognition jobs**. **OCR-05 and OCR-06 move to Code** for multiple QR browsing and the specifically listed local formats; this does not establish broad industrial recognition quality.

Typed results preserve each complete decoder string and polygon; equal values at separate regions remain separate. Unlocalized values remain available in the list; binary/no-text values and cap omissions are disclosed. Bounds remain **128 results, 4,096 UTF-16 units per value, 65,536 total, 32-million-pixel source and shared two-active/four-waiting recognition admission**. UPC-A equivalence is a separate checked alias; copy retains the native zero-prefixed EAN13 text. Configurable detection modes, damaged/GS1 labels, broad industrial/camera quality and automatic new-pin OCR remain outside these checks.

The HTTP(S) action validates the URL and requires explicit invocation. Recognition, selection and copy do not auto-open payloads. Isolated-pasteboard and injected-opener tests do not prove general clipboard use, real URL opening or physical interaction with an external app. No user screen, TCC database, preference or network state is changed by these fixtures.

### Separate installed export-resource and editor/pin measurements

`image-export-resource.json` is **`status=observed`**, not a threshold-based memory pass. Each installed copy completes one warm-up and **four measured 1440 × 900 cycles**, each serially previewing/encoding/saving/closing PNG, JPEG, BMP and PDF. Main-process Mach RSS/physical footprint are sampled every **50 ms plus explicit boundaries** during source creation through cleanup. These sampled maxima can miss short peaks and exclude WindowServer, GPU and other processes. The separate 160 × 100/two-cycle unit profile is not substituted for this installed workload.

| Architecture / format | Settled RSS change from post-warm-up baseline, cycles 1–4 (bytes) | Final interval RSS change | Final settled footprint change |
| --- | --- | ---: | ---: |
| ARM ZIP | +1,851,392 / +1,867,776 / +2,277,376 / +1,867,776 | −409,600 | −5,029,888 |
| ARM DMG | −262,144 / +2,359,296 / +2,359,296 / +2,359,296 | 0 | −933,824 |
| Intel ZIP | +2,224,128 / +2,306,048 / +106,496 / +2,297,856 | +2,191,360 | −176,128 |
| Intel DMG | −1,527,808 / +2,105,344 / +5,853,184 / +6,111,232 | +258,048 | +3,600,384 |

After every cycle, owned temporary files, active sessions and queued/running jobs are zero; weak controller release is observed. All four final temporary workspaces are removed. These are short fixed-workload observations with no new resource threshold; ARM has a final flat/decreasing RSS interval, while Intel ends with positive intervals and its DMG grows across the last three intervals. Neither pattern is **a plateau, zero-leak, maximum-resolution or long-running claim**. The installed launcher's outer timeout covers non-preemptible native calls.

Separately, the established **10-warm-up plus 40-measured editor/pin lifecycle** phase reports **147,456/98,304 bytes ARM ZIP/DMG** and **520,192/966,656 bytes Intel ZIP/DMG** main-process RSS growth, zero retained tracked controllers/content or cycle windows and **7 → 7 windows**. Earlier model/GIF phases can affect its baseline. These editor/pin figures must not replace the export-resource measurements, helper RSS or whole-system memory.

### Counts and remaining release boundaries

The 124 behavior rows now contain **47 Code / 61 Partial / 16 Missing**. Five narrow Partial-to-Code promotions are CAP-06, OCR-05, OCR-06, EXP-03 and EXP-04. The nine adaptation notes remain **three Partial, one Missing, four Platform and one permissions note**. All **133 IDs**, original requirements/acceptance checks and official citations remain preserved. Code status does not close real-device or full-quality acceptance.

Source-labeled `capture-export-recognition.json`, `capture-presets-elements.json`, `image-export-preview.json`, `image-export-resource.json`, barcode reports/images, codec results, logs and installer hashes underpin these findings. Early UI-only reports still explicitly skip export resource cycles; full installed a8600a3 reports are separate. Actual AX/TCC, foreign-app capture, physical displays/restart, independent export interoperability and sustained resources remain open on both architectures. Existing model/GIF/recovery behavior passes its corresponding source-specific architecture gates without granting OS permissions.

### Historical 0.7 compile and visual failures

Initial [791f2dd9a7e4aac5c15d5e98f6f1ccea5a9578d0](https://github.com/dandibbert/picshot/commit/791f2dd9a7e4aac5c15d5e98f6f1ccea5a9578d0) failed ARM compilation because `BarcodeResultController.document` collided with inherited `NSWindowController.document`. Renamed-property [8e43f67ac223071c1b5870ba30d1f0cb203e3abd](https://github.com/dandibbert/picshot/commit/8e43f67ac223071c1b5870ba30d1f0cb203e3abd), [run 37513586696 / job 112440697858](https://github.com/dandibbert/picshot/actions/runs/37513586696/job/112440697858), compiled/packaged and passed an **early UI-only** stage, including seven real-Vision barcode fixtures, exact-byte JPEG/PDF save and fake-provider/preset controls. Real own-app AX was skipped and repeated export resources were explicitly not run.

That attempt then failed test compilation at `CapturePresetTests.swift:64` on ambiguous `.infinity`. Pixel review also found export content **620 × 1185 JPEG / 648 × 1001 PDF**, too tall for the **1024 × 768** fixture display. Thus it had no ordinary/critical/model suite pass or full visual acceptance. The explicit-CGFloat and non-intrinsic/on-screen layout corrections now pass at final a8600a3; the older failed stages are not retroactively relabeled as passes.

## Historical 0.6: ARM 6a154fb and Intel b0b0eab

[Final ARM source 6a154fb09beb72845a03c2bc68d643901e3bb6ba](https://github.com/dandibbert/picshot/commit/6a154fb09beb72845a03c2bc68d643901e3bb6ba) passed [run 37503402218 / job 112405849837](https://github.com/dandibbert/picshot/actions/runs/37503402218/job/112405849837). Downloaded native logs report **836 ordinary tests: 833 passed, 3 intentional model-dependent skips; 390 selected critical tests; and 12 genuine-model tests**, all with zero failures. Critical/model groups overlap the ordinary suite and are not additive distinct-test counts. Both signed installed ZIP and DMG pass startup/LaunchServices, visible native UI, model exit/cleanup, editor/pin/composition and `interactionParityEvidence`, recorded in `evidence/{zip,dmg}/interaction-parity.json`; recording recovery and the ZIP-only GIF resource/cancellation profile pass. The final scroll reports identify source 6a154fb, Chinese captions and composition of cached transparent content over the effective NSWindow background. This verification-window rendering does not change capture/output raster pixels.

**Release boundary:** the earlier [9b63ddf810a05160dd746750307119cbc1b361e7](https://github.com/dandibbert/picshot/commit/9b63ddf810a05160dd746750307119cbc1b361e7) functionality checkpoint passed **both architecture pipelines** in [run 37498347869](https://github.com/dandibbert/picshot/actions/runs/37498347869), including [ARM job 112388583473](https://github.com/dandibbert/picshot/actions/runs/37498347869/job/112388583473), with the same 836/390/12 counts. Its transparent-window snapshot predates the final composition/localization change. Final `6a154fb` Intel was cancelled without a useful diagnostic log; that establishes neither a successful pipeline nor an identified application defect. Its unchanged-application retry at [b0b0eab9b6db9379a08340119f1e1658d16f20f7](https://github.com/dandibbert/picshot/commit/b0b0eab9b6db9379a08340119f1e1658d16f20f7), [run 37510990742 / job 112431773788](https://github.com/dandibbert/picshot/actions/runs/37510990742/job/112431773788), now reaches terminal success: **836 ordinary tests (833 passed, 3 intentional skips), 390 critical and 12 genuine-model tests**, zero failures, and both installed formats pass all prior feature/model/composition/recovery gates. ZIP alone runs the full GIF resource/cancellation profile. Installer replacements are confirmed; this exact-source result, rather than an inherited pre-final pass, establishes Intel 0.6 availability.

### Exact ARM 0.6 installer bytes

The three downloaded SHA-256 sidecars were independently checked against the actual files. Build metadata records version 0.6.0, arm64, exact source `6a154fb09beb72845a03c2bc68d643901e3bb6ba`, macOS 14 minimum, ad-hoc signing and `notarized: false`. The native run is macOS 15.7.9; it does not establish macOS 14 runtime acceptance. A matching version label alone does not identify these bytes.

| File | SHA-256 |
| --- | --- |
| `PicShot-0.6.0-macos-arm64.dmg` | `5cb298dc2f5cade58d57e5cd9d78e39f6d7d6c54fef352577e5f4cd001fec2a4` |
| `PicShot-0.6.0-macos-arm64.zip` | `83aa56c6dc95e04a84f59baee02754ad1f44f3dcb2eabcd9524a6db2d8ecb580` |
| `PicShot-0.6.0-macos-arm64.build-info.json` | `0a55aee1a3239cea2e3a37b9d40a43ac062659e581137887263f9387e6017fb8` |

The interaction details below were first verified at the 9b63ddf checkpoint and repeated from both delivered ARM 6a154fb and Intel b0b0eab installed formats. They describe original synthetic input and native controls, with separate actual local Vision inference where explicitly stated. They are not user-desktop, physical input or TCC tests.

### Exact Intel 0.6 bytes and bounded installed observations

All three downloaded sidecar hashes were checked against the actual files. Metadata identifies version 0.6.0, x86_64, exact source `b0b0eab9b6db9379a08340119f1e1658d16f20f7`, macOS 14 minimum, ad-hoc signing and `notarized: false`.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `PicShot-0.6.0-macos-x86_64.dmg` | 17,569,678 | `9fefbf7917fc644fc7a8d48619f079321322bb184840bac88a4c1bc5000ac952` |
| `PicShot-0.6.0-macos-x86_64.zip` | 14,823,918 | `53a49bb6bf4e537e0911efcd6344272a15df12097747ecc85807b2a5b733af22` |
| `PicShot-0.6.0-macos-x86_64.build-info.json` | 177 | `063d089760ccc3045810d9c67e7516f9e84645ad537985b933365ba2e7ff93c6` |

Both installed copies pass the 10-warm-up/40-measured-cycle editor/pin workload with **507,904 bytes ZIP / 249,856 bytes DMG** main-process RSS growth, zero retained tracked controllers/content or cycle windows and **7 → 7 windows**. ZIP baseline/final RSS is 410,669,056 → 411,176,960 bytes; DMG is 384,978,944 → 385,228,800 bytes. Each installed actual LaMa path completes in approximately 50 seconds, with parent-polled sampled child RSS peaks **1,034,031,104 bytes ZIP / 1,020,973,056 bytes DMG** and confirmed child exit/cleanup. These are workload observations, not universal latency or whole-system peaks.

The Intel ZIP four-export GIF workload retains **229,376 bytes of parent RSS**, with successful child exits, temporary cleanup and cancellation checks. This is the ordinary installed resource profile, not a new eight-cycle attribution comparison. The independent eight-cycle measurements below retain their original source 87eaedf. DMG does not inherit ZIP's full GIF resource run. Product timeouts, memory bounds and fidelity assertions are unchanged.

### Editable arcs, sectors and bounded polylines

The installed path fixture uses an original **1024 × 760 synthetic desktop at 1×** and native AppKit controls/canvas NSEvents. It verifies editable open arcs and filled sectors, negative sweeps, angle/rotated-endpoint edits preserving the opposite endpoint, correct fill pixels, repeated undo/redo and canceled-drag preservation. Four-node click-built polylines support vertex edits, Return/Finish/double-click commit, Backspace/Command-Z vertex removal and Escape/tool-switch cancellation. Drafts stay out of exports; the 256-point limit auto-finishes with a single undo state. Four-edge toolbar/palette placement and owned UI/cache release pass.

This supports **ANN-01 Code** for the stated geometry row. **ANN-07 remains Partial**: arrow toggles and configurable joins/end caps are still absent. Synthetic 1× pixels do not establish Retina acquisition, physical input, all fonts/scales or real captured-desktop acceptance.

### Real Vision image-pin text selection and native payload paths

The installed fixture runs **actual Apple Vision** on locally authored Latin text and an observational mixed-text image. It verifies word geometry, explicit image orientation, source-coordinate mapping through zoom/scroll, image-edit invalidation, Unicode keyboard/phrase selection and exact copy. It exercises the production native mouse/keyboard handlers and `NSDraggingItem` writer, then has an owned `NSTextView` consume the exact payload on an isolated pasteboard. Drag cancellation, Escape and disabled-overlay pass-through pass. **A physical drag/drop into an external application is not tested.** The user's general clipboard, preferences and permissions are unchanged.

Twelve repeated mode/hide/close cycles retain zero tracked controllers/overlays; all recognition jobs settle. Admission remains bounded to two active/four waiting recognition jobs, 32,768 document UTF-16 units and 8,192 geometry units. These checks support **PIN-18 Code** for its reachable overlay/selection/drag path, not broad OCR/layout accuracy or a zero-leak result. **OCR-07 remains Partial** because new-pin recognition/selection requires explicit enablement rather than running automatically. The separate OCR result window still lacks a complete linked source/layout model.

### Bidirectional scroll projection, reverse Auto-Crop and middle-band edits

Native scroll-controller controls and original coordinate-hashed source pixels exercise signed placement in **both axes and both initial directions**. Reverse Auto-Crop removes the correct edge, supports explicit/mode/minimum-extent direction reset, and restores captured coverage without duplicating sources. Arbitrary selected/numeric middle bands can cross source boundaries, reconnect retained content and survive forward restoration. Undo/redo/apply/cancel restore intervals and cuts; original disk-source bytes remain unchanged. The fixture verifies 25-pixel reverse removal and 80-pixel arbitrary removal crossing two source boundaries in each direction/axis case, plus conservative repeated/ambiguous-content rejection, disk-limit refusal and in-flight cancellation cleanup.

Small-fixture preview/export pixels match, and editor→pin pixels plus an isolated PNG clipboard round-trip pass. **The direct system Copy button is not invoked, and equality of previews scaled from inputs longer than 800 pixels remains unverified.** Final ARM 6a154fb separately verifies the effective-background composition and Chinese labels in its window screenshots; this does not expand the small-fixture edited-raster pixel checks or establish scaled-preview equality. These findings support **LONG-06 and LONG-07 Code**, while continuous manual monitoring, adjustable live capture regions, physical app routing, Retina, real dynamic/fixed page content and maximum-size/long-session resources remain open.

### Installed lifecycle scope and ledger counts

Both delivered ARM 6a154fb installed copies complete **10 warm-up plus 40 measured editor/pin lifecycle cycles**: main-process RSS grows **131,072 bytes ZIP / 589,824 bytes DMG**, with zero retained tracked controllers/content or cycle windows and **7 → 7 windows**. ZIP baseline/final RSS is 490,717,184 → 490,848,256 bytes; DMG is 461,930,496 → 462,520,320 bytes. The earlier 9b63ddf ARM results remain **458,752 bytes ZIP / 344,064 bytes DMG**, also zero retained tracked references and 7 → 7 windows; these are separate measurements, not relabeled final-source results. These bounded synthetic observations exclude whole-system/GPU/helper peaks and do not prove leak freedom.

The **0.6** behavior ledger contains **42 Code / 63 Partial / 19 Missing** rows; only ANN-01, PIN-18, LONG-06 and LONG-07 changed status in that batch. The early source-only 0.7 inventory was 42/66/16. Final native-verified ARM/Intel 0.7 now has **47 Code / 61 Partial / 16 Missing**, with its five narrow promotions described above. Counts identify implementation scope, not full acceptance. All **133 IDs**, original requirements, acceptance checks and official source citations remain intact.

## Verified 0.5: ARM 87eaedf and Intel 2043254

Native evidence is from macOS 15.7.9 (24G830); the package minimum remains macOS 14, whose runtime acceptance is still open. `test.log`, `critical-tests.log`, `model-inference.log`, `recording-recovery.log`, package/UI/smoke logs and `evidence/` identify the exact source. Independent GIF jobs retain their focused-test and attribution logs.

| Stage | ARM 87eaedf | Intel 2043254, with earlier independent 87eaedf GIF evidence labeled |
| --- | --- | --- |
| Ordinary native suite | **764 reported: 761 passed, 3 intentional model skips, zero failures** | Same counts/skips, zero failures |
| Selected critical suite | **287 passed, zero failures** | 287 passed, zero failures |
| Genuine-model suite | **12 passed, zero failures** | **12 passed, zero failures** |
| GIF-focused suite | **123 passed, zero failures** | 123 passed at app-identical 87eaedf in its independent GIF job |
| Installed ZIP/DMG and LaunchServices | **Both pass**, including native UI/model/pin/editor/composition checks | **Both pass** at 2043254, including model exits/cleanup and composition |
| Abrupt recording recovery | **Pass** | Pass |
| GIF resource/cancellation profile | **Pass from ZIP only** | **Pass from ZIP only** at 2043254 |
| Eight-cycle GIF attribution | **Completed with helper exit/cleanup evidence** | Completed at app-identical 87eaedf; not relabeled as a new 2043254 measurement |

The selected critical, model and GIF-focused stages overlap the ordinary suite and each other; these are not additive distinct-test totals. Intentional model skips in the ordinary suite are not model passes.

The ARM ZIP and DMG both pass signature/architecture validation, no-argument LaunchServices activation and visible native windows. Synthetic native annotation effects, signed models, pin/editor cycles, recording composition and recovery are rechecked at 87eaedf. The full GIF/cancellation profile is **ZIP-only**; DMG does not inherit a separately executed GIF profile. ARM recovery again reports its own child SIGKILL (9), five recovered fragments/five seconds, 50 decoded video frames and 239,552 audio frames, with original bytes unchanged and child/temporary cleanup confirmed. Real camera/TCC, Retina acquisition, live screen/audio and visible-preview force-kill remain untested.

### Exact ARM installer bytes

All three downloaded SHA-256 sidecars below were checked against the actual files. Build metadata records version 0.5.0, arm64, exact source `87eaedf16aaf6c2df2001d35ce08af2762ac33c2`, macOS 14 minimum, ad-hoc signing and `notarized: false`. These hashes do not identify another build with the same version label.

| File | SHA-256 |
| --- | --- |
| `PicShot-0.5.0-macos-arm64.dmg` | `10d2c3a2e4b00f88d8d55e7809d51ec1c64601ce2f77a5804c86685cdea8200a` |
| `PicShot-0.5.0-macos-arm64.zip` | `8054c7791c65e5a6c89a532e6042caf77649bd675fd9d124d645daa330fcd536` |
| `PicShot-0.5.0-macos-arm64.build-info.json` | `2bec7a2e75bab9de8cea24e9f4e2a454291224a8e5efdf8ab58d5c3facaf65a4` |

### Exact Intel installer bytes and installed evidence

All three Intel SHA-256 sidecars were checked against downloaded bytes. Build metadata records version 0.5.0, x86_64, exact source `204325409123a07dc8a1bd472817a0ca38664092`, macOS 14 minimum, ad-hoc signing and `notarized: false`.

| File | SHA-256 |
| --- | --- |
| `PicShot-0.5.0-macos-x86_64.dmg` | `f92de567db034ecb986f11e9447390f096cb60f55b8200a8f5ca43e952b08f16` |
| `PicShot-0.5.0-macos-x86_64.zip` | `3f7cd767c96632ab89a8b4eb5ce172514a235fcf41acaaa2e1f6fcfee9a3078a` |
| `PicShot-0.5.0-macos-x86_64.build-info.json` | `e181a7187a1736124d985b6d29ab77a6f276d4e1d7ef1dbfd479379e0a275f11` |

Both Intel installed formats pass normal startup/LaunchServices, visible native windows, signed formula/table/smart-erase model paths, confirmed model-child exit 0 and temporary cleanup, recording composition and lifecycle checks. The installed smart-erase fixture reports **53.5869 seconds ZIP / 50.6499 seconds DMG** for one successful production-helper job in each copy, retaining all outside-mask/alpha bytes. These fixture elapsed times are not a universal inference-latency guarantee or the child-only timing field.

After ten warm-ups, **40 measured editor/pin lifecycle cycles** retain **987,136 bytes ZIP / 827,392 bytes DMG** of main-process RSS. Both end with zero retained tracked controllers/content or cycle windows and **7 → 7 windows**. This is a bounded main-process observation, not whole-device memory or a zero-leak result. Intel recovery again confirms own-child SIGKILL (9), five fragments/five seconds, 50 decoded video frames and 239,552 audio frames with source preservation and cleanup. The full GIF/cancellation profile passes from ZIP only: cancellation confirms child exit 1, `cancelled`, destination absent and cleanup; DMG explicitly records that profile as not run.

### Isolated GIF export: measured improvement with residual parent growth

At source **87eaedf**, each architecture compares its own **same installed binary** in fresh-process in-process-baseline and isolated-helper modes: one warm-up, then eight 30-second/360-frame exports from authored 640 × 360 media to 480 × 270 GIFs. These attribution measurements predate the workflow-only 2043254 Intel packaging run and retain their original provenance. There are zero GIF decoder validations before/during measured export cycles, followed by one final full-file validation. AVFoundation video decoding is still part of export. Independent decode-only runs warm up and read one immutable GIF eight times with no intervening exports.

| Architecture | Baseline export-only retained RSS bytes | Isolated-helper parent retained RSS bytes | Baseline / helper-prepared same-file decode-only retained RSS bytes |
| --- | ---: | ---: | ---: |
| ARM | 102,678,528 (97.922 MiB) | 1,720,320 (1.641 MiB) | 360,448 / 622,592 |
| Intel | 225,280 (0.215 MiB) | 159,744 (0.152 MiB) | 1,110,016 / 1,454,080 |

ARM helper-parent final physical-footprint growth is **0 bytes**, but **all eight settled RSS intervals are positive** and the final three add **491,520 bytes (0.469 MiB)**. The report key `lastFourObservationGrowthBytes` is the difference between four observations, meaning three intervals. This is substantial containment of retained parent RSS relative to the same-binary baseline, **not a demonstrated plateau or zero leak**. Same-file decode reuse may benefit from OS/framework caches and does not exclude new-file or cross-export decoder retention. The underlying native allocation owner remains unidentified.

For the ARM isolated export sequence, **all nine helpers including warm-up exit 0**, with child exit and owned temporary-directory removal confirmed. Child-reported sampled RSS peaks range **72,613,888–75,005,952 bytes (72.6–75.0 MB decimal)**; the parent's independently polled child RSS peaks range **58,376,192–65,732,608 bytes (58.4–65.7 MB decimal)**. They observe the same child at different sampling boundaries and must not be added together. Parent RSS/footprint, child self-samples and parent-polled child samples are separate scopes; none is a synchronized whole-app/system peak. Sampling can miss transient peaks and excludes other helpers, framework-service processes and GPU memory. One GIF job may overlap one model job because their admission gates are separate.

The ZIP cancellation fixture requests cancellation after 36 parent-observed frame-progress messages. It confirms `cancelled`, **child exit 1**, destination absent, no partial files and child/staging cleanup. Queued progress does not establish an exact child-frame stop count. Existing codec, output/input, time and resource envelopes remain unchanged; neither this bounded workload nor cleanup success establishes sustained recording, maximum-resolution or real-device acceptance.

### Intel failure history and final resolution

[Intel build job 112357029587](https://github.com/dandibbert/picshot/actions/runs/37489170662/job/112357029587) first failed because `testRealCoreMLRemovesMarkedObjectAndPreservesOutsidePixels` took **314.905896243 seconds**, exceeding the unchanged **300-second** assertion. Its image/preservation checks passed, but that attempt remained a real-model gate failure and skipped installed smoke. The same-source 87eaedf retry passed the model gate, then reached the outer CI time window during smoke; it was not a complete pass either.

Workflow-only 2043254 introduced an independent **40-minute Intel CI lane** and completed the full pipeline in [run 37496626993 / job 112382709941](https://github.com/dandibbert/picshot/actions/runs/37496626993/job/112382709941). **No application timeout, memory envelope or fidelity threshold was weakened**; the application implementation is identical to delivered ARM 87eaedf. Both 0.5 architectures are now available. Earlier failed/incomplete attempts remain recorded rather than being relabeled as successful.

## Historical functionality checkpoint at 04999d0

Both architecture jobs in run 37471951304 passed on macOS 15.7.9 (24G830). This is not a macOS 14 runtime result. Evidence is in that run's architecture-specific QA artifacts, including `test.log`, `critical-tests.log`, `model-inference.log`, `ui-preview.log`, `package.log`, `smoke.log`, `recording-recovery.log` and `evidence/`.

| Stage | arm64 and x86_64 result | Boundary |
| --- | --- | --- |
| Ordinary native suite | **689 tests reported, 3 intentional model-dependent skips, zero failures** | The skipped cases are not model passes |
| Selected critical stage | **204 tests passed, zero skips/failures** | Overlaps the ordinary suite |
| Genuine-model stage | **12 tests passed, zero skips/failures** | Also overlaps; do not add these stages into a distinct-test total |
| Native annotation/UI | **Passed**, including all four effects and their flattened outputs | Original 1× synthetic desktop, native AppKit controls/synthetic events; no real desktop capture, physical input or TCC |
| Installed ZIP and DMG | **Passed on both architectures** | Launch/signature/architecture, model, pin, editor and recording-composition checks for this exact source |
| Installed recording composition | **One warm-up plus three measured cycles passed per ZIP/DMG install** | Synthetic camera/screen, production compositor/controller/writer and actual H.264 decode; no hardware capture |
| Installed abrupt recovery | **Passed on both architectures** | A signed installed app killed only its own unfinished writer child, then recovered and decoded the bounded synthetic media |
| Existing GIF resource profile | **Passed from ZIP only** | The in-process writer's configured regression envelope; not helper isolation or proof of a plateau |

### Annotation effect evidence

ANN-11–14 have reachable native controls and verified pixel paths at 04999d0. `evidence/ui/annotation-effects-preview.json` reports `status=passed`, all owned editors closed and original raster preserved:

- Brush/rectangle eraser removes preceding ink without erasing the captured base or later marks. Native gestures, Escape/cancel, clear and repeated pixel-identical undo/redo pass
- Spotlight varies shape, dimming and border; its interior remains unchanged, exterior dims and light/dark appearance does not alter export. Native tests also check stacking and transparent-base alpha
- Watermark supports tiled/anchored text, opacity/spacing and frozen date/timezone substitution. Native controls and repeated undo/redo preserve the timestamp. Imported images are labeled with editing-start time rather than an invented capture time
- Magnifier moves source and lens independently, with shape/scale/connector/smoothing/shadow controls. Export tests preserve redactions even when ordinary annotation visibility changes or a redaction is added after the lens

The main fixture desktops are 1024 × 768 ARM and 1920 × 1080 Intel, both 1×. The earlier ARM preview set at source `535833a` contains the same annotation code; it is also an **original 1× synthetic desktop**, not user-screen or Retina evidence. The 04999d0 artifacts provide an exact-batch repeat. Raster bounds and released fixture windows are not a sustained-memory or leak measurement. These tests support Code status for the narrow ledger rows, not complete parity acceptance.

### Installed recording composition and color

Each `evidence/{zip,dmg}/recording-composition.json` reports three measured cycles after one warm-up. Each cycle encodes and decodes seven H.264 frames at 640 × 360 / 10 FPS for 0.7 seconds, with 95 decoded pixel checks. Synthetic quadrants and gray/color ramps verify placement, resize, mirror/crop, live pen/eraser, static-screen updates, pause removal and the frozen Stop snapshot. The source/compositor input is sRGB; encoded properties are BT.709, with decoded ramps checked in sRGB against a 12-channel-value tolerance. Frame packets are adjacent with positive durations; the synthetic one-second pause is absent from output.

Four production pipelines and four overlay controllers are created and released per installed copy, with no tracked objects, retained writer-frame references, camera slots or temporary files left after each cleanup. Resource samples cover the **main process only**, including composition, encode, decode and cleanup: a 50 ms timer plus explicit boundaries, not kernel peaks. They exclude GPU and AVFoundation service memory.

| Architecture / format | Sampled peak RSS / footprint MiB | Settled RSS / footprint growth MiB |
| --- | ---: | ---: |
| arm64 ZIP | 129.594 / 66.049 | -5.078 / +7.297 |
| arm64 DMG | 127.703 / 65.830 | -4.266 / +0.125 |
| x86_64 ZIP | 86.094 / 41.066 | -7.375 / -2.281 |
| x86_64 DMG | 91.629 / 45.527 | -7.297 / -2.031 |

These short fixed-resolution observations pass the configured envelope; falling RSS is not a zero-leak result. The fixture directly calls production overlay-controller methods and invokes the refresh handler on a deterministic encoder clock. It creates no overlay window, posts no physical input, and does not exercise timer scheduling, camera provider/hardware, TCC, Retina placement, actual ScreenCaptureKit window exclusion or live screen/audio sync. The source behavior and remaining device checks are described in [RecordingOverlays.md](RecordingOverlays.md); its authored-test inventory is not itself execution evidence.

### Installed journaled recovery

Both `evidence/recording-recovery/recovery.json` reports identify 04999d0 and `status=passed`. Each confirms its own child exited from **SIGKILL (signal 9)**, discovers one interrupted capture, and recovers **five complete fragments into a five-second MP4**, fully decoding **50 video frames and 239,552 non-silent audio frames**. Expected synthetic video colors pass. Original source bytes remain unchanged; child exit and temporary-directory cleanup are confirmed. Screen, camera and microphone started flags are all false.

Saved-preview journal reopening and explicit dismissal also pass, preserving the movie. This models reopening a fresh store; **the visible preview window was not force-killed**. Recovery remuxes only complete owned journaled fragments to a new file; it does not resume devices/capture, reconstruct missing fragments or adopt arbitrary legacy MP4s. Native tests separately cover real writer cancellation, protected-file survival, torn tails, malformed inputs and source preservation. Power loss, storage removal and real hardware/permission timing remain open. [RecordingRecovery.md](RecordingRecovery.md) records the transaction, limits and remaining acceptance gates.

## GIF helper chronology: failures, diagnosis and corrected 87eaedf result

The initial candidate [f65f4749cd00972c8e539aea7e856118ded5e06b](https://github.com/dandibbert/picshot/commit/f65f4749cd00972c8e539aea7e856118ded5e06b), [run 37474097686](https://github.com/dandibbert/picshot/actions/runs/37474097686), compiled, packaged and passed synthetic UI. Its first ARM focused stage instead reported **276 tests with 17 failures (7 unexpected)**. `critical-tests.log` showed legitimate production-style MP4s rejected as `invalidSource`, preventing successful export/cancellation/collision paths, alongside a child-readiness timeout and orphan-cleanup assertion failure. This remains historical evidence, not the latest failure count.

Subsequent native source [01d8951ea5c16c473ad2e8e287055a1dd8f45706](https://github.com/dandibbert/picshot/commit/01d8951ea5c16c473ad2e8e287055a1dd8f45706), [run 37484485789](https://github.com/dandibbert/picshot/actions/runs/37484485789), **compiled, packaged and passed synthetic UI on both ARM and Intel**. Each architecture's focused stage reported **285 tests, exactly four authored decoded-pixel assertion failures and zero unexpected failures**. Genuine signed-helper exports, admission, short-line progress, cancellation/orphan cleanup, protocol and output-verifier tests passed. Successful export and process cleanup did not turn the incorrect boundary frames into a semantic pass; that commit's focused stage failed.

The cause was isolated with production-identical, test-only instrumentation at [0b5f997835ee5ba1d265874678454c19a602461c](https://github.com/dandibbert/picshot/commit/0b5f997835ee5ba1d265874678454c19a602461c), [run 37487357552](https://github.com/dandibbert/picshot/actions/runs/37487357552). Raw timing logs and parsed/reconstructed JSON record compressed/decoded source timestamps, requested/actual generator times, GIF pixels and independent nearest-tick probes. Independent source decoding has the correct boundary content. In both architectures, binary Double values just below the intended boundary truncate during CMTime conversion:

| Intended time | Production request at timescale 600 | Selected preceding source time | Nearest-tick probe request / actual |
| --- | --- | --- | --- |
| 0.2 s | 119/600 | 60/600 | 120/600 / 120/600 |
| 0.8 s | 479/600 | 420/600 | 480/600 / 480/600 |
| 1.6 s | 959/600 | 900/600 | 960/600 / 960/600 |

Nearest-tick probes return the intended boundary frames on ARM and Intel, while the original production requests select preceding frames. Matching GIF/source-generator pixels further localize these failures to request-time construction rather than GIF palette/LZW assembly. These are targeted diagnostic observations on authored fixtures, not a corrected production run or a universal codec-fidelity claim.

The narrow shared-rounding correction is present in **87eaedf**, with unchanged-threshold boundary-pixel regressions passing in its critical/GIF-focused stages on both architectures. The ARM final pipeline, app-identical Intel 2043254 final pipeline and both architectures' source-labeled eight-cycle isolated attribution have results above. The original failures and diagnostic probes remain history rather than being relabeled as passes. Both 0.5 architectures are available; real-device, broad-quality and sustained-resource acceptance remain open.

[GIFExport.md](GIFExport.md) describes the production process boundary at 87eaedf: one on-demand same-executable child, with a **regular local self-contained H.264 MP4/optional AAC input cap of 1 GiB** and no silent in-process fallback. This is narrower than general video input or the recording/recovery maximum; larger otherwise valid recordings are not silently accepted for GIF. One GIF job has a separate admission gate from the ML gate, so one GIF job may overlap one model job. Recorded evidence separates parent RSS/footprint, parent-polled child RSS, child-reported RSS/footprint, child exit and cleanup; those scopes exclude other helpers, framework services and GPU allocations. Bounded measurements do not remove those limits or establish a system-wide resource guarantee.

## Delivered 0.4 run and artifacts

Both jobs ran on GitHub-hosted macOS 15.7.9 (24G830), Xcode 16.4 / macOS 15.5 SDK. The package minimum is macOS 14; this run does not establish macOS 14 runtime compatibility.

| Stage | arm64 and x86_64 result | Boundary |
| --- | --- | --- |
| Ordinary native suite | **561 tests reported, 3 intentional weight-dependent skips, zero failures** | A skipped case is not a model pass |
| Selected critical stage | **87 tests passed, zero skips/failures** | Overlaps the ordinary suite |
| Genuine-model stage | **12 tests passed, zero skips/failures**, using original-source SHA-256-verified optional weights | Also overlaps; do not claim 660 distinct tests |
| Streaming GIF writer | **9 new tests passed** within the suites above | Parser/truncation, native palette/LZW preservation, alpha rejection, caps, cancellation and cleanup; not nine extra tests |
| Native UI | **Revised installed-AppKit fixture passed** | Synthetic desktop at 1×, no TCC, screen capture or OCR inference |
| Installed packages | **ZIP and DMG passed on both architectures** | Signature/architecture, no-argument LaunchServices, visible native windows, signed model paths, pin sessions and editor cycles |
| GIF resource profile | **Passed from each architecture's ZIP install** | Not repeated from DMG; residual growth remains below the configured regression envelope |

All six accompanying SHA-256 files (four installers and two build-info files) were checked against downloaded bytes. Build metadata identifies `6c808a5edc2b36ba12a38706239a965386edb03b`, version 0.4.0, architecture, ad-hoc signing and `notarized: false`.

| Installer | SHA-256 |
| --- | --- |
| `PicShot-0.4.0-macos-arm64.dmg` | `672b80ecc749f8fa788d9c928977c454864731a860af33c7253c2f12528018bf` |
| `PicShot-0.4.0-macos-arm64.zip` | `3dfa9067f99c98f16657a93ebdf7d0dae160993ad4b048ff836dffe021244fe0` |
| `PicShot-0.4.0-macos-x86_64.dmg` | `6eeadfad7b59bef934c34af5be9970b7fa894e7e6ee48b5a0fa9a5e5b0398da1` |
| `PicShot-0.4.0-macos-x86_64.zip` | `56d4264020a666e7ab41688d81a54f2896ac885bf233c880d9e19a0ba563c295` |

QA artifacts contain `test.log`, `critical-tests.log`, `model-inference.log`, `package.log`, `ui-preview.log`, `smoke.log` and `evidence/{ui,zip,dmg}`. They include `launch.json`, `model-evidence.json`, `pin-session.json` and ZIP-only `gif-resource.json`. GitHub artifact retention is 14 days. These hashes identify exact bytes, not a later build sharing the version label.

## Delivered 0.4 native UI and functional fixture scope

- The frozen-desktop fixture is **1024 × 768 on ARM and 1920 × 1080 on Intel, both 1×**. Actual AppKit toolbar/canvas events exercise rectangle drawing, inline text accept/cancel, styled text, light/dark surfaces, capture-boundary resize/undo/Escape/redo, preserved annotation placement, pin Space-open/cancel and dark OCR-result presentation. It uses original synthetic pixels; no user screen, TCC database, OCR inference or system preference is modified
- Genuine formula recognition passes three authored image fixtures. Installed formula recognition returns `E = m c ^ { 2 }`; local MathJax produces the preview plus SVG/MathML/PNG/PDF. This does not establish multi-formula segmentation, editable Office OMML, Typst/AsciiMath or broad recognition accuracy
- The native table helper uses real SLANet-plus structure and Apple Vision text. Installed results retain four rows/three columns. Structured editing and OOXML/ZIP tests pass; the known high-confidence rowspan misprediction remains a rejection case, and independent Excel/LibreOffice UI acceptance remains open
- All four installed smart-erase fixtures change 12,302 masked pixels, preserve every outside-mask RGB byte and alpha byte, and leave no new job directory. Masked RGB MAE falls from 98.8802269 to about 1.5883. This covers one successful 800 × 800 production-helper job per installed copy, not arbitrary images or forced timeout/crash/cancellation
- Translation request/state tests and weak framework linkage pass. Actual Apple language download, successful/offline translation and macOS 14 launch remain untested

Weights remain optional external data from pinned original publisher locations, verified by exact size/SHA-256, never committed or bundled as model weights. Model provenance/licenses are in [MODELS.md](MODELS.md), [TABLE_MODEL.md](TABLE_MODEL.md) and [SmartErase.md](SmartErase.md); the recording-GIF architecture and limits are in [GIFExport.md](GIFExport.md).

## Delivered 0.4 main-process lifecycle measurements

Each installed copy performs **10 warm-up plus 40 synthetic editor/pin create-render-close cycles**. All end with 7 → 7 windows, zero retained cycle controllers/content and zero retained cycle windows. RSS below is the main process during that phase, not whole-app-plus-helper or peak inference memory; earlier model/GIF phases may affect its baseline.

| Architecture / format | Baseline → final RSS bytes | Delta MiB | Sampled peak RSS MiB |
| --- | ---: | ---: | ---: |
| arm64 ZIP | 268,632,064 → 269,008,896 | +0.359 | 256.656 |
| arm64 DMG | 153,255,936 → 154,091,520 | +0.797 | 147.031 |
| x86_64 ZIP | 110,010,368 → 110,817,280 | +0.770 | 105.684 |
| x86_64 DMG | 114,003,968 → 115,261,440 | +1.199 | 109.922 |

A separate **3-warm-up plus 20-cycle pin-session fixture** exercises hide/show, archive/reopen, group switching, saved original/current presentation, new-store restoration guards and explicit removal in a temporary store. All four pass 54 weak release probes with zero retained pin controllers/content or empty panels; temporary directories are removed and user defaults stay unchanged.

| Architecture / format | Pin-session RSS delta MiB |
| --- | ---: |
| arm64 ZIP | -1.312 |
| arm64 DMG | -1.375 |
| x86_64 ZIP | -1.152 |
| x86_64 DMG | -1.289 |

These bounded synthetic observations are not a sustained-use or zero-leak result. File-reference drag behavior, every rich-pin decoder, physical monitor removal and real restart scenarios still require broader acceptance.

## Delivered 0.4 signed model-child resource evidence

All recorded formula/table/inpainting children exit with status 0, confirmed process exit and confirmed temporary-directory cleanup. The service samples **child RSS every 100 ms** while the child runs. Values below are maximum successful samples; transient peaks between samples and separate system/GPU-service allocations are not included. They are not kernel lifetime peaks or complete device memory use. Counts in parentheses are actual successful RSS samples.

| Architecture / format | Formula peak MiB (samples) | Table peak MiB (samples) | Erase peak MiB (samples) | Erase child runtime s |
| --- | ---: | ---: | ---: | ---: |
| arm64 ZIP | 360.188 (12) | 203.609 (13) | 1872.219 (150) | 16.295 |
| arm64 DMG | 316.031 (9) | 228.375 (14) | 1482.062 (181) | 19.517 |
| x86_64 ZIP | 287.012 (24) | 175.781 (23) | 965.914 (758) | 77.800 |
| x86_64 DMG | 286.738 (17) | 177.543 (24) | 971.996 (698) | 71.637 |

Configured caps remain formula/table **1 GiB / 120 seconds**, smart erase **2 GiB / ARM 150 seconds or Intel 300 seconds**. Those are limits, not observed peaks. The largest sampled erase value here is about 1,872 MiB on ARM; passing this fixture does not guarantee headroom for every input or machine. The table covers three inference helpers, not every process or a formula-render-helper RSS peak. Main-process lifecycle results above must not be substituted for these child measurements.

## Delivered 0.4 streaming GIF and subsequent attribution

The published writer replaces the old multi-frame ImageIO destination with **one native still-frame encode at a time plus file-backed GIF89a assembly**. Native palettes/LZW payloads are preserved. The encoded frame buffer is capped at 8 MiB and final output at 64 MiB. Screen-recording export supports **opaque frames only**: actual transparent/fractional-alpha frames fail explicitly rather than being flattened or incorrectly composited. Alpha-capable storage with genuinely opaque pixels remains supported. This restriction does **not** change animated GIF/WebP pin decoding.

On each architecture, ZIP runs one warm-up then **four measured exports** from an authored changing 640 × 360, 30-second, 12-FPS source, exporting 360 frames at 480 × 270. All output frames decode serially with ImageIO caching disabled, distinct thumbnail fingerprints and approximately 30-second playback. Fingerprints check diversity, not full fidelity. Cancellation at frame 36 is observed without publishing the destination or leaving partial files. A separate one-shot 1920 × 1080 / 12-frame export also passes; it is not a maximum-square-area, maximum-frame-count or plateau test. No live recording/audio or external download occurs in this fixture.

Measurements cover the **main process only**, excluding AVFoundation services and GPU memory. Export-only peaks are sampled before validation with a 50 ms timer plus frame-progress boundaries, including single-frame ImageIO finalization. Successful export sample counts range from 692 to 978, with no missing RSS/physical-footprint samples in the measured four-export runs. These remain sampled maxima, not kernel peaks. The report separately records immediate/settled pre-validation readings, validator peaks and post-validation readings.

| Architecture | Peak export RSS MiB | Peak export footprint MiB | Four-cycle combined settled RSS growth MiB | Combined footprint growth MiB |
| --- | ---: | ---: | ---: | ---: |
| arm64 | 195.031 | 133.159 | +49.000 | +49.094 |
| x86_64 | 82.945 | 35.816 | +0.504 | +0.445 |

The unchanged repeated-run regression envelopes are **384 MiB sampled peak growth, 96 MiB final settled growth and 32 MiB last-interval growth**; both architectures pass. Relative to their own post-warm-up baselines, export RSS peak growth improved from about 417.0 → 55.8 MiB on ARM and 392.0 → 7.48 MiB on Intel versus `c0adee4`. This is a fixture comparison, not a universal performance promise.

**ARM still grows 49.0 MiB across four combined export/validation/cleanup cycles; it is not a plateau or a zero-leak result.** Intel's corresponding growth is 0.504 MiB. Settled combined readings include validation and cannot be attributed solely to the encoder. Separate fresh-process export-only and decode-only experiments completed successfully in [diagnostic run 37458401335](https://github.com/dandibbert/picshot/actions/runs/37458401335). The production-default export-only workload (one warm-up plus eight 30-second/360-frame exports, with zero GIF decoder calls during measurement) retained **98.03 MiB RSS on ARM** and **0.19 MiB on Intel**. Decode-only repeated eight full reads of one immutable GIF after warm-up: **0.59 MiB ARM / 1.11 MiB Intel**. ARM export-only readings increased from 109,379,584 to 212,172,800 bytes; the final three intervals added 38,502,400 bytes. This reproduces the growth inside the export pipeline without GIF validation; it does **not identify a specific allocation owner or prove a framework leak**. Same-file decoder caching and framework/GPU service allocations are outside that conclusion. All diagnostic media cleanup was confirmed. A same-binary comparison completed in [run 37462393497](https://github.com/dandibbert/picshot/actions/runs/37462393497), source `d810984`: ARM async export-only retained 102,891,520 bytes (98.13 MiB), scoped synchronous extraction retained 102,793,216 bytes (98.03 MiB). Their final three intervals added 38,486,016 and 38,453,248 bytes. Intel retained 77,824 and 274,432 bytes respectively. All 11 extraction-fidelity/cancellation/diagnostic tests passed on each architecture, all four fresh-process reports per architecture completed, and temporary cleanup was confirmed. **The synchronous candidate was rejected as ineffective; it was not promoted to the production default.** At that checkpoint, the bounded export-process boundary was not yet verified. Final 87eaedf parent/child measurements and remaining limits are recorded above; they do not retroactively change this earlier in-process result. Output limits and acceptance thresholds have not been relaxed. Remaining ARM growth is open investigation despite the configured envelope passing. DMG reports explicitly mark this full GIF profile `not-run` because it is run from ZIP only.

## Historical boundary

| Commit / run | Result and how it applies |
| --- | --- |
| [c0adee4e26d52315b0fe5c154c1ccc3ec23cf49f](https://github.com/dandibbert/picshot/commit/c0adee4e26d52315b0fe5c154c1ccc3ec23cf49f), [run 37450349815](https://github.com/dandibbert/picshot/actions/runs/37450349815) | Both passed 551 ordinary tests (3 intentional skips), 39 selected critical and 12 genuine-model tests, plus revised UI. Installed ZIP then failed the old GIF memory envelope; DMG launch was not reached. Peaks were sampled before validation, establishing an export-path resource problem. The 6c808a5 profile passes, with residual growth disclosed above |
| [ccb70f897df31232f604a8d25848d7d348b21dd9](https://github.com/dandibbert/picshot/commit/ccb70f897df31232f604a8d25848d7d348b21dd9), [run 37446248077](https://github.com/dandibbert/picshot/actions/runs/37446248077) | Both ordinary suites reported 544 tests, 3 intentional skips and 14 failures (2 unexpected); packaging/early UI success did not make it installer-ready |
| [caf71931e5c622d7ee0d7d6d549a902c00a6658f](https://github.com/dandibbert/picshot/commit/caf71931e5c622d7ee0d7d6d549a902c00a6658f), [run 37429201431](https://github.com/dandibbert/picshot/actions/runs/37429201431) | Delivered 0.2 passed its then-complete pipeline: 184 ordinary tests (3 intentional skips), 12 genuine-model tests and both installed formats. Its exporter was byte-identical to c0adee4's old implementation, suggesting shared-path risk. The new stress test was not run against 0.2; do not report a demonstrated 0.2 failure |
| [199566dd87af4f79ade76795bd21eb250e7e5ae7](https://github.com/dandibbert/picshot/commit/199566dd87af4f79ade76795bd21eb250e7e5ae7), [run 37427240555](https://github.com/dandibbert/picshot/actions/runs/37427240555) | ARM packaged erase output lost pixels after temporary cleanup; Intel produced correct pixels but exceeded the old 150-second cap. These were fixed before delivered 0.2 |
| [104e42e181eabac60a1df9c81cc6d85424a60314](https://github.com/dandibbert/picshot/commit/104e42e181eabac60a1df9c81cc6d85424a60314), [run 37426021201](https://github.com/dandibbert/picshot/actions/runs/37426021201) | Native/real-model stages passed on both; smoke failed compiling the launcher before app launch. No accepted installer |
| [0143e58d5a576a3def256267ac53cda5d5618e31](https://github.com/dandibbert/picshot/commit/0143e58d5a576a3def256267ac53cda5d5618e31), [run 37420240366](https://github.com/dandibbert/picshot/actions/runs/37420240366) | First delivered 0.1: 65 tests and both installed formats passed per architecture; later model features were absent |

## Still requires real-device and full-scope acceptance

User-TCC grant/deny/revoke/relaunch; real application capture; physical multi-monitor/mixed Retina/negative-origin/display-removal flows; complete capture → annotate → copy/export → pin → OCR → history paths; system/microphone audio sync and sustained recording; real camera selection/disconnect/indicator shutdown and overlay exclusion; Retina/user-desktop annotation effects; visible-preview force-kill, power loss and storage-removal recovery; long scrolling and prolonged resource use; broad multilingual/table/formula/inpainting/barcode quality; real Apple language download/translation; independent Office/export interoperability; sustained isolated-GIF resource behavior and every remaining parity-row requirement. Historical 0.6 introduced the narrow arcs/polylines, image-pin text selection and scroll-editing evidence above, with the final localized/composited window snapshots. App-identical Intel 0.6 passed its own final pipeline and both installed formats; physical external-app drag, direct Copy and >800 px scaled-preview equality remain unverified. ARM and Intel 0.7 presets/export/barcode work now pass their independent native and both-format installed gates; actual AX/real-device acceptance remains open. Click/scroll/keystroke effects, transparent/broader animation input, broader exceptional GIF cleanup and sustained codec resources remain open alongside all other Missing/Partial features; the specific outer-trim regression has source-qualified b44c1fb evidence. ARM/Intel 0.8 adds verified still WebP/AVIF and bounded recording WebP as qualified above; ARM/Intel b44c1fb Save/Retry and scoped GIF-stage changes now have independent native acceptance; broader real-device/exceptional cases and sustained resources remain open.

CI does not grant the user's OS permissions or modify permission databases. Packages are ad-hoc signed and **not notarized**; integrity checks do not establish publisher identity or Gatekeeper acceptance. Missing/Partial requirements remain in scope. No full-parity, zero-leak, universal latency or whole-device memory claim is made.
