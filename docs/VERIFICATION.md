# Verification evidence and release boundary

Reviewed 6 October 2026. **The last delivered installer remains 0.4.0 at [6c808a5edc2b36ba12a38706239a965386edb03b](https://github.com/dandibbert/picshot/commit/6c808a5edc2b36ba12a38706239a965386edb03b).** [Run 37454104537](https://github.com/dandibbert/picshot/actions/runs/37454104537) completed successfully on [arm64](https://github.com/dandibbert/picshot/actions/runs/37454104537/job/112237360074) and [x86_64](https://github.com/dandibbert/picshot/actions/runs/37454104537/job/112237360447). The ARM DMG and guide were delivered; verified Intel artifacts are available. This is a development preview with incomplete parity, remaining real-device work and unresolved ARM GIF export retention. The full **133-row scope and status categories** remain in [PARITY.md](PARITY.md).

**The not-yet-delivered 0.5 functionality batch at [04999d0fd92a00e11bcbbfd2c9fe813f8ea9f11d](https://github.com/dandibbert/picshot/commit/04999d0fd92a00e11bcbbfd2c9fe813f8ea9f11d) separately passed its full ARM/Intel pipelines in [run 37471951304](https://github.com/dandibbert/picshot/actions/runs/37471951304).** It verifies the four annotation effects, synthetic recording composition and journaled recovery described below. Later GIF helper source has a failed focused gate and no isolated-helper memory result. Full 0.5 delivery is held for those helper gates and remaining final integrated checks. Results and resource measurements apply only to their explicitly identified source, process and fixture; a version label or earlier passing run does not cover subsequent changes.

## Verified 0.5 functionality batch at 04999d0, not delivered

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

## Pending GIF helper: failed native gate, no isolation result

The later candidate [f65f4749cd00972c8e539aea7e856118ded5e06b](https://github.com/dandibbert/picshot/commit/f65f4749cd00972c8e539aea7e856118ded5e06b), [run 37474097686](https://github.com/dandibbert/picshot/actions/runs/37474097686), compiled, packaged and passed synthetic UI. Its first ARM focused stage instead reported **276 tests with 17 failures (7 unexpected)**. `critical-tests.log` shows legitimate production-style MP4s rejected as `invalidSource`, preventing successful export/cancellation/collision paths, alongside a child-readiness timeout and orphan-cleanup assertion failure. Packaging and UI success do not override this failed gate.

Validation/diagnostics fixes are in progress. No isolated-helper memory measurement or helper-isolation success is available for this candidate, and neither its presence in source nor the earlier 04999d0 full pass makes it production-verified. Required next evidence is the corrected final source's full native and installed ARM/Intel gates, production recording/trim input compatibility, semantic/cancellation/cleanup checks and explicit eight-cycle `isolated-helper` attribution with unchanged envelopes.

[GIFExport.md](GIFExport.md) describes the proposed process boundary: one on-demand same-executable child, with a **regular local self-contained H.264 MP4/optional AAC input cap of 1 GiB** and no silent in-process fallback. This is narrower than general video input or the recording/recovery maximum; larger otherwise valid recordings are not silently accepted for GIF. One GIF job has a separate admission gate from the ML gate, so one GIF job may overlap one model job. Evidence must separately identify parent RSS/footprint, parent-polled child RSS, child-reported RSS/footprint, child exit and cleanup; those scopes exclude other helpers, framework services and GPU allocations. None of these intended boundaries substitutes for the missing measured result.

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

**ARM still grows 49.0 MiB across four combined export/validation/cleanup cycles; it is not a plateau or a zero-leak result.** Intel's corresponding growth is 0.504 MiB. Settled combined readings include validation and cannot be attributed solely to the encoder. Separate fresh-process export-only and decode-only experiments completed successfully in [diagnostic run 37458401335](https://github.com/dandibbert/picshot/actions/runs/37458401335). The production-default export-only workload (one warm-up plus eight 30-second/360-frame exports, with zero GIF decoder calls during measurement) retained **98.03 MiB RSS on ARM** and **0.19 MiB on Intel**. Decode-only repeated eight full reads of one immutable GIF after warm-up: **0.59 MiB ARM / 1.11 MiB Intel**. ARM export-only readings increased from 109,379,584 to 212,172,800 bytes; the final three intervals added 38,502,400 bytes. This reproduces the growth inside the export pipeline without GIF validation; it does **not identify a specific allocation owner or prove a framework leak**. Same-file decoder caching and framework/GPU service allocations are outside that conclusion. All diagnostic media cleanup was confirmed. A same-binary comparison completed in [run 37462393497](https://github.com/dandibbert/picshot/actions/runs/37462393497), source `d810984`: ARM async export-only retained 102,891,520 bytes (98.13 MiB), scoped synchronous extraction retained 102,793,216 bytes (98.03 MiB). Their final three intervals added 38,486,016 and 38,453,248 bytes. Intel retained 77,824 and 274,432 bytes respectively. All 11 extraction-fidelity/cancellation/diagnostic tests passed on each architecture, all four fresh-process reports per architecture completed, and temporary cleanup was confirmed. **The synchronous candidate was rejected as ineffective; it was not promoted to the production default.** A bounded, on-demand export-process boundary is being implemented with explicit parent/child resource accounting; it is not yet a verified fix. Output limits and acceptance thresholds have not been relaxed. Remaining ARM growth is open investigation despite the configured envelope passing. DMG reports explicitly mark this full GIF profile `not-run` because it is run from ZIP only.

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

User-TCC grant/deny/revoke/relaunch; real application capture; physical multi-monitor/mixed Retina/negative-origin/display-removal flows; complete capture → annotate → copy/export → pin → OCR → history paths; system/microphone audio sync and sustained recording; real camera selection/disconnect/indicator shutdown and overlay exclusion; Retina/user-desktop annotation effects; visible-preview force-kill, power loss and storage-removal recovery; long scrolling and prolonged resource use; broad multilingual/table/formula/inpainting quality; real Apple language download/translation; independent Office/export interoperability; verified GIF helper isolation and every remaining parity-row requirement. The four annotation effects, camera/live annotations and recovery exist in verified 04999d0 source but remain absent from the delivered 0.4 installer. Click/scroll/keystroke effects, animated WebP and the other Missing/Partial features remain unfinished scope.

CI does not grant the user's OS permissions or modify permission databases. Packages are ad-hoc signed and **not notarized**; integrity checks do not establish publisher identity or Gatekeeper acceptance. Missing/Partial requirements remain in scope. No full-parity, zero-leak, universal latency or whole-device memory claim is made.
