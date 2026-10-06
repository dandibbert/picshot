# Verification evidence and release boundary

Reviewed 6 October 2026. **Both ARM and Intel 0.5.0 are verified and available.** ARM at [87eaedf16aaf6c2df2001d35ce08af2762ac33c2](https://github.com/dandibbert/picshot/commit/87eaedf16aaf6c2df2001d35ce08af2762ac33c2) was delivered at 15:57 UTC: [run 37489170662](https://github.com/dandibbert/picshot/actions/runs/37489170662), [build/package job 112357029365](https://github.com/dandibbert/picshot/actions/runs/37489170662/job/112357029365) and [attribution job 112357029582](https://github.com/dandibbert/picshot/actions/runs/37489170662/job/112357029582) passed. Intel at [204325409123a07dc8a1bd472817a0ca38664092](https://github.com/dandibbert/picshot/commit/204325409123a07dc8a1bd472817a0ca38664092) reached terminal success in [run 37496626993 / job 112382709941](https://github.com/dandibbert/picshot/actions/runs/37496626993/job/112382709941); its installer updates were confirmed at 16:53 UTC. That source changes **only `.github/workflows/macos.yml`** from ARM 87eaedf; app implementation is identical. The full **133-row scope, source-qualified status counts and outstanding requirements** remain in [PARITY.md](PARITY.md). These are development previews, not full parity or zero-leak acceptance.

The common 0.5 app implementation includes the four annotation effects, camera/live annotation composition, journaled recording recovery and corrected isolated GIF export. The earlier full ARM/Intel functionality pass at [04999d0](https://github.com/dandibbert/picshot/commit/04999d0fd92a00e11bcbbfd2c9fe813f8ea9f11d), [run 37471951304](https://github.com/dandibbert/picshot/actions/runs/37471951304), remains a historical checkpoint. Results and measurements apply only to their identified source, artifact, process and fixture; identical application code does not make differently packaged bytes or measurements interchangeable. The newer three-module interaction batch now has ARM runtime evidence below, but is not part of delivered 0.5 and no 0.6 installer has been delivered.

## ARM 0.6 functionality candidate at 9b63ddf, not delivered

[Source 9b63ddf810a05160dd746750307119cbc1b361e7](https://github.com/dandibbert/picshot/commit/9b63ddf810a05160dd746750307119cbc1b361e7) reached terminal ARM success in [run 37498347869 / job 112388583473](https://github.com/dandibbert/picshot/actions/runs/37498347869/job/112388583473). Native logs report **836 ordinary tests: 833 passed, 3 intentional model-dependent skips; 390 focused tests; and 12 genuine-model tests**, all with zero failures. Focused/model groups overlap the ordinary suite; they are not additive distinct-test counts. Both signed installed ZIP and DMG pass their new `interactionParityEvidence`, recorded in `evidence/{zip,dmg}/interaction-parity.json`, alongside native annotation-path and scroll-sequence reports.

**Release boundary:** Intel 9b63ddf is still running. The scroll-window snapshot at 9b63ddf had transparent-background composition; a later snapshot-composition/Chinese-label patch is authored and awaits a final rerun. The functional source pass is not a pass for that later patch, final visual acceptance or a delivered 0.6 installer. Both verified 0.5 architectures remain the available release.

### Editable arcs, sectors and bounded polylines

The installed path fixture uses an original **1024 × 760 synthetic desktop at 1×** and native AppKit controls/canvas NSEvents. It verifies editable open arcs and filled sectors, negative sweeps, angle/rotated-endpoint edits preserving the opposite endpoint, correct fill pixels, repeated undo/redo and canceled-drag preservation. Four-node click-built polylines support vertex edits, Return/Finish/double-click commit, Backspace/Command-Z vertex removal and Escape/tool-switch cancellation. Drafts stay out of exports; the 256-point limit auto-finishes with a single undo state. Four-edge toolbar/palette placement and owned UI/cache release pass.

This supports **ANN-01 Code** for the stated geometry row. **ANN-07 remains Partial**: arrow toggles and configurable joins/end caps are still absent. Synthetic 1× pixels do not establish Retina acquisition, physical input, all fonts/scales or real captured-desktop acceptance.

### Real Vision image-pin text selection and native payload paths

The installed fixture runs **actual Apple Vision** on locally authored Latin text and an observational mixed-text image. It verifies word geometry, explicit image orientation, source-coordinate mapping through zoom/scroll, image-edit invalidation, Unicode keyboard/phrase selection and exact copy. It exercises the production native mouse/keyboard handlers and `NSDraggingItem` writer, then has an owned `NSTextView` consume the exact payload on an isolated pasteboard. Drag cancellation, Escape and disabled-overlay pass-through pass. **A physical drag/drop into an external application is not tested.** The user's general clipboard, preferences and permissions are unchanged.

Twelve repeated mode/hide/close cycles retain zero tracked controllers/overlays; all recognition jobs settle. Admission remains bounded to two active/four waiting recognition jobs, 32,768 document UTF-16 units and 8,192 geometry units. These checks support **PIN-18 Code** for its reachable overlay/selection/drag path, not broad OCR/layout accuracy or a zero-leak result. **OCR-07 remains Partial** because new-pin recognition/selection requires explicit enablement rather than running automatically. The separate OCR result window still lacks a complete linked source/layout model.

### Bidirectional scroll projection, reverse Auto-Crop and middle-band edits

Native scroll-controller controls and original coordinate-hashed source pixels exercise signed placement in **both axes and both initial directions**. Reverse Auto-Crop removes the correct edge, supports explicit/mode/minimum-extent direction reset, and restores captured coverage without duplicating sources. Arbitrary selected/numeric middle bands can cross source boundaries, reconnect retained content and survive forward restoration. Undo/redo/apply/cancel restore intervals and cuts; original disk-source bytes remain unchanged. The fixture verifies 25-pixel reverse removal and 80-pixel arbitrary removal crossing two source boundaries in each direction/axis case, plus conservative repeated/ambiguous-content rejection, disk-limit refusal and in-flight cancellation cleanup.

Small-fixture preview/export pixels match, and editor→pin pixels plus an isolated PNG clipboard round-trip pass. **The direct system Copy button is not invoked, and equality of previews scaled from inputs longer than 800 pixels remains unverified.** The transparent window-background snapshot issue is separate from verified edited-raster pixels; its later composition/Chinese-label fix has no inherited pass. These findings support **LONG-06 and LONG-07 Code**, while continuous manual monitoring, adjustable live capture regions, physical app routing, Retina, real dynamic/fixed page content and maximum-size/long-session resources remain open.

### Installed lifecycle scope and ledger counts

Both 9b63ddf installed copies complete 40 editor/pin lifecycle cycles: main-process RSS growth is **458,752 bytes ZIP / 344,064 bytes DMG**, with zero retained tracked controllers/content or cycle windows and **7 → 7 windows**. These bounded synthetic observations exclude whole-system/GPU/helper peaks and do not prove leak freedom.

The 124 behavior rows now count **42 Code / 63 Partial / 19 Missing**, plus the unchanged nine macOS adaptation notes, preserving all **133 IDs**. Only ANN-01, PIN-18, LONG-06 and LONG-07 change status in this batch. Code denotes reachable implementation with the stated fixture evidence; it does not close the original acceptance column or promote the pending Intel/UI-patch work.

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

User-TCC grant/deny/revoke/relaunch; real application capture; physical multi-monitor/mixed Retina/negative-origin/display-removal flows; complete capture → annotate → copy/export → pin → OCR → history paths; system/microphone audio sync and sustained recording; real camera selection/disconnect/indicator shutdown and overlay exclusion; Retina/user-desktop annotation effects; visible-preview force-kill, power loss and storage-removal recovery; long scrolling and prolonged resource use; broad multilingual/table/formula/inpainting quality; real Apple language download/translation; independent Office/export interoperability; sustained isolated-GIF resource behavior and every remaining parity-row requirement. The four annotation effects, camera/live annotations, recovery and GIF helper are now in both verified 0.5 architectures; passing pipelines do not establish complete acceptance or full parity. Click/scroll/keystroke effects, animated WebP and the other Missing/Partial features remain unfinished scope. The subsequent 9b63ddf arcs/polylines, image-pin text selection and scroll-editing modules have the narrow ARM implementation evidence recorded above. Intel, the later UI patch, physical external-app drag, direct Copy and >800 px scaled-preview equality remain pending or unverified; no 0.6 delivery or full-parity claim is made.

CI does not grant the user's OS permissions or modify permission databases. Packages are ad-hoc signed and **not notarized**; integrity checks do not establish publisher identity or Gatekeeper acceptance. Missing/Partial requirements remain in scope. No full-parity, zero-leak, universal latency or whole-device memory claim is made.
