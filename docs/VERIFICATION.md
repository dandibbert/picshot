# Verification evidence and release boundary

Reviewed 6 October 2026. This records **commit-specific results**, not complete PixPin parity. The full 133-row target remains in [PARITY.md](PARITY.md).

The **0.2 development preview is verified at [caf71931e5c622d7ee0d7d6d549a902c00a6658f](https://github.com/dandibbert/picshot/commit/caf71931e5c622d7ee0d7d6d549a902c00a6658f)**. [Run 37429201431](https://github.com/dandibbert/picshot/actions/runs/37429201431) completed successfully on arm64 and x86_64, including native tests, actual-model inference, signed packaging and installed ZIP/DMG LaunchServices smoke. Formula, table and inpainting helpers succeeded from all four installed copies. This resolves the earlier packaged image-lifetime and Intel time-bound failures for this commit. It remains a development preview with incomplete parity and untested real-device paths.

The first delivered 0.1 preview is commit `0143e58d5a576a3def256267ac53cda5d5618e31`. Historical failures below remain evidence about their own commits; they are not current release blockers.

## Exact runs

All eight jobs below ran on GitHub-hosted macOS 15.7.9 (24G830), using Xcode 16.4 / the macOS 15.5 SDK. This is not a macOS 14 runtime test or an exhaustive supported-OS matrix.

| Source commit / run | Native test stage | Real-model stage | Package / installed-app result |
| --- | --- | --- | --- |
| [caf71931e5c622d7ee0d7d6d549a902c00a6658f](https://github.com/dandibbert/picshot/commit/caf71931e5c622d7ee0d7d6d549a902c00a6658f), [run 37429201431](https://github.com/dandibbert/picshot/actions/runs/37429201431), [arm64 job](https://github.com/dandibbert/picshot/actions/runs/37429201431/job/112155823185), [Intel job](https://github.com/dandibbert/picshot/actions/runs/37429201431/job/112155823406) | **Passed** on each architecture: 184 tests reported, including 3 intentional weight-dependent skips, zero failures | **Passed** on each: 12 selected real-model tests, zero skips/failures after original-source, SHA-256-verified provisioning | **Passed** on both architectures and both ZIP/DMG copies: signatures/architecture, LaunchServices, visible native window, snapshots, signed formula/table/erase helpers, output pixel/cleanup checks and synthetic lifecycle/RSS. Installer and QA artifacts uploaded |
| [0143e58d5a576a3def256267ac53cda5d5618e31](https://github.com/dandibbert/picshot/commit/0143e58d5a576a3def256267ac53cda5d5618e31), [run 37420240366](https://github.com/dandibbert/picshot/actions/runs/37420240366), [arm64 job](https://github.com/dandibbert/picshot/actions/runs/37420240366/job/112127743956), [Intel job](https://github.com/dandibbert/picshot/actions/runs/37420240366/job/112127744181) | **Passed**: 65 tests, zero failures on each architecture | Not present in this preview; it predates the formula/table/inpainting engines | **Passed** on both architectures: build/signature/architecture checks, ZIP and DMG installation into separate clean temporary directories, LaunchServices launch without app arguments, visible native window, view snapshots and synthetic lifecycle/RSS checks. Installer artifacts uploaded |
| [104e42e181eabac60a1df9c81cc6d85424a60314](https://github.com/dandibbert/picshot/commit/104e42e181eabac60a1df9c81cc6d85424a60314), [run 37426021201](https://github.com/dandibbert/picshot/actions/runs/37426021201), [arm64 job](https://github.com/dandibbert/picshot/actions/runs/37426021201/job/112145744179), [Intel job](https://github.com/dandibbert/picshot/actions/runs/37426021201/job/112145744528) | **Passed**: 180 tests reported, including 3 explicitly skipped weight-dependent tests, zero failures on each architecture | **Passed** on both: after original-source, SHA-256-verified fixture provisioning, 12 selected tests, zero skips/failures, including the 3 previously skipped actual-model cases | Signed app, ZIP and DMG packaging **passed** on both. Installed smoke **failed before app launch** compiling `launch-smoke-app.swift`: optional chaining on non-optional `configuration.environment`. This is a launcher-harness failure, not a failed inference result; it blocked acceptance of that commit. Installer upload skipped |
| [199566dd87af4f79ade76795bd21eb250e7e5ae7](https://github.com/dandibbert/picshot/commit/199566dd87af4f79ade76795bd21eb250e7e5ae7), [run 37427240555](https://github.com/dandibbert/picshot/actions/runs/37427240555), [arm64 job](https://github.com/dandibbert/picshot/actions/runs/37427240555/job/112149577246) | **Passed**: 181 tests reported, including 3 explicit model skips, zero failures | **Passed**: 12 selected tests, zero skips/failures with real weights | Packaging **passed** and installed signed-app formula/table calls succeeded. Smoke **failed** in packaged smart erase: output lost pixel/alpha content after temporary-file cleanup. The run did not complete both-format installed acceptance or upload an accepted installer |
| Same [199566d run](https://github.com/dandibbert/picshot/actions/runs/37427240555), [Intel job](https://github.com/dandibbert/picshot/actions/runs/37427240555/job/112149577120) | **Passed**: 181 tests reported, including 3 explicit model skips, zero failures | **Failed**: 12 selected tests, one failure. Formula/table passed; real CoreML output passed pixel checks but took 182.048 seconds against a 150-second assertion | Packaging and installed smoke **skipped** after the model-stage failure. No accepted installer |

The selected 12-test model stage reruns tests from the regular suite with weights configured; it is not 12 additional unique tests: the final run does not represent 196 distinct tests. A skipped model test is not an inference pass. QA artifacts contain logs and, where reached, `dist/evidence` reports; GitHub artifact retention is 14 days. Installer checksum files belong to the exact successful artifact, not to another build with the same version label.

## What native execution has established

- **Annotation and selection:** native AppKit tests dispatch mouse/key events through the real editor canvas and controls for drawing, movement, deletion, Shift/zoom, crop confirmation, undo/redo, selected style changes and a text re-edit request. Capture tests check multi-region/subtraction, polygon/freehand masks, asymmetric pixel geometry, transparency and cancellation against synthetic images. These are stronger than model-only drawing tests, but do not exercise user-TCC or selection over real apps on physical displays
- **Structured tables:** genuine SLANet-plus ONNX inference plus native Apple Vision OCR and the bundled helper passed the merged-header fixture. Recorded genuine tensor fixtures also cover 3 × 3 and three-column merged-header layouts. Cell edit/span rules, cancellation/late-result handling and real OOXML/ZIP XLSX structure have separate tests. A known high-confidence rowspan misprediction remains documented and rejected; this is not general recognition-quality or Excel/LibreOffice UI acceptance
- **Formula recognition:** actual Pix2Text-MFR-1.5 weights passed three authored native fixtures: x²+y²=z², E=mc² and a fraction. These are genuine ONNX outputs, not fixed strings or text OCR relabeled as math. They establish the native tensor/tokenizer path for those fixtures only. Single-formula output is editable LaTeX; multi-formula segmentation, rendered preview and interchange remain incomplete
- **Inpainting engine and installed helper:** actual CoreML LaMa passed native tests and the production signed-helper path for both architectures/formats at `caf7193`. All four installed 800 × 800 fixture runs changed 12,302 masked pixels, with zero outside-mask RGB-byte mismatches, zero alpha mismatches and zero new job directories remaining. Masked RGB mean absolute error fell from 98.8802269 to about 1.5883. Returned pixels remained valid after temporary-job cleanup. Installed-helper times were ARM 22.29–22.69 seconds and Intel 52.38–69.59 seconds; these fixture measurements are not general latency guarantees. Cancellable wall limits are ARM 150 seconds / Intel 300 seconds. The 2 GiB helper RSS value is a configured cap, **not a measured inference peak**
- **Local translation:** Apple Translation API integration and request/state/error tests compile and pass. Real language-pack download, successful translation, subsequent offline translation and the complete cancellation/retry UI have **not** been runtime-validated. The feature requires macOS 15+; weak Translation framework linkage was verified in both architecture packages, but is not itself a macOS 14 launch test

Optional model weights come from their pinned original publisher locations, with exact size/SHA-256 verification. They remain external optional data, never committed or bundled as weights in the installer. Provenance, licensing and contracts are in [MODELS.md](MODELS.md), [TABLE_MODEL.md](TABLE_MODEL.md) and [SmartErase.md](SmartErase.md). The native results above supersede older reference-only validation statements; they do not remove documented accuracy limits.

## Verified 0.2 resource evidence

At `caf7193`, all four installed copies completed **10 warm-up plus 40 synthetic editor/pin create-render-close cycles**, with no live screen capture or recording. The exact launch reports are in the run's QA artifacts at `evidence/{zip,dmg}/launch.json`.

| Architecture / format | Baseline → final RSS (bytes) | Delta (MiB) | Baseline → final windows | Retained cycle controllers/content | Retained empty cycle windows |
| --- | ---: | ---: | ---: | ---: | ---: |
| arm64 DMG | 139,100,160 → 137,379,840 | -1.641 | 6 → 6 | 0 | 1 |
| arm64 ZIP | 130,842,624 → 129,220,608 | -1.547 | 6 → 6 | 0 | 1 |
| x86_64 DMG | 92,606,464 → 93,384,704 | +0.742 | 5 → 5 | 0 | 0 |
| x86_64 ZIP | 94,203,904 → 95,412,224 | +1.152 | 5 → 5 | 0 | 0 |

The retained ARM window was an invisible AppKit-cached utility panel with its controller and content released. These are bounded app lifecycle/RSS observations, **not a zero-leak claim**, a sustained-load result or a measurement of peak model-inference memory. Each installed erase fixture covers one successful production-helper job; forced timeout/crash/cancellation and general helper-leak testing remain separate acceptance work.

## Verified installer checksums

These SHA-256 values were checked against the downloaded `caf7193` artifact bytes and accompanying build metadata. They identify these exact 0.2.0 files, not any later rebuild with the same version label.

| File | SHA-256 |
| --- | --- |
| `PicShot-0.2.0-macos-arm64.dmg` | `03f92238f6617bd854eeb084b50b52fd58b0bda40775012a0b420c8c06eb87f4` |
| `PicShot-0.2.0-macos-arm64.zip` | `3b281030c59db9c890144e394757047a85eb6f9125f713d37a6269659fb5a985` |
| `PicShot-0.2.0-macos-x86_64.dmg` | `f43480e219e40c62308c6796c12117e6ccccf47f61b5936050472c7f2ac4687a` |
| `PicShot-0.2.0-macos-x86_64.zip` | `3f7f124b4b5f68bd7145603252d7c6092020da5315416d7c2f35e89227561ee5` |

## Remaining acceptance boundary

- The final run validates the fixed image-lifetime path and architecture-aware runtime limits for its fixtures. It does not validate all failure/recovery paths or every image size/content
- Any later source change needs its own complete pipeline and exact-commit evidence; this successful run cannot be carried forward automatically
- Unpublished pin-session/group, recording-preview/trim, capture-precision and formula-SVG work is outside this 0.2 snapshot. Local files, wiring or authored tests do not establish native/runtime parity

## Still requires real-device acceptance

User-TCC grant/deny/revoke/relaunch; capture of real app content; two physical monitors with mixed Retina scales, negative origins and display removal; complete capture → annotate → copy/export → pin → OCR → history paths; real system/microphone audio and synchronization; long recording/scrolling and resource use; broad multilingual/table/formula quality; native language-download/translation flow; independent document/export interoperability; interruption/recovery and full parity-row acceptance.

CI does not modify permission databases or grant the user's OS permissions. Packages are ad-hoc signed and **not notarized**: integrity checks do not establish publisher identity or Gatekeeper acceptance. Missing or partial features in the ledger remain in scope.
