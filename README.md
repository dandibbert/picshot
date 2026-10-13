# PicShot

Original, local-first macOS screenshot, annotation, pinning and recording utility. Written in Swift/AppKit, with Apple Vision OCR and ScreenCaptureKit recording. macOS 14+, Apple Silicon and Intel.

**Development preview. Not full PixPin parity yet.** This project is not affiliated with PixPin and uses no proprietary source, assets, subscription bypasses, or hosted recognition credentials. See [feature ledger](docs/PARITY.md) for actual scope and [verification](docs/VERIFICATION.md) for the test boundary.

ARM **0.21.0/build 214 is accepted** within the bounded [verification scope](docs/VERIFICATION.md#build-214-pin-management-acceptance). It adds explicit plain-text pin drafts with Save/Cancel and bounded undo, persistent image/text pin names, and ordering existing named groups. Rich text stays read-only. Prior accepted annotation styles, local shortcuts, settings, capture, OCR, exports and recording remain. Only the plain-text pin ledger row is promoted; full PixPin parity is still incomplete. Accepted/delivered Intel remains **0.11.0/build 69**.

ARM 214 ZIP version 21 and guide version 29 were sent as native attachments on **11 October 2026 at 01:59:50 UTC**. ZIP/DMG v21 and corrected guide v30 are saved; **DMG v21 is saved only**. The guide-only correction keeps PIN-14 Partial for missing duplicate-group-name rejection; guide v30 was sent on 11 October 2026 at 02:06:51 UTC, and installer bytes are unchanged. Exact package identities and the archive-only recovery checkpoint are in the [package record](docs/VERIFICATION.md#build-214-packages-and-delivery-boundary).

Cold/final/peak resource costs remain material. The actual ZIP-only production-default 4K workload reports main-app RSS **67.734375 MiB at entry, 418.968750 MiB after its first cycle, 424.218750 MiB at final cleanup and 700.609375 MiB kernel peak**, including **+4.265625 MiB over eight measured cycles**. Separate broad synthetic loops end near 906/883 MiB ZIP/DMG RSS and are not a combined process peak. This is finite evidence, not a plateau, zero-leak or global stability claim. Physical Mac/TCC, keyboard layouts/IME, Retina/multiple displays/Spaces, macOS 14 runtime and broad quality remain open; packages are ad hoc signed and unnotarized.

Historical ARM **0.20.0/build 191** added one explicitly saved appearance default per supported tool, configurable canvas-only keys for 20 modes and optional validated portable style/shortcut sections. Its feature and resource boundaries remain in the [191 record](docs/VERIFICATION.md#build-191-annotation-preferences-acceptance).

Historical ARM **0.19.1/build 185** acceptance covers static WebP's removal of an unused intermediate PNG staging preview; AVIF retains its legacy route. ZIP version 19 and guide version 27 were delivered on 10 October 2026 at 12:40:39 UTC; DMG version 19 was saved only. Intel 185 timed out during debug compilation. The [185 record](docs/VERIFICATION.md#build-185-webp-only-acceptance) retains its exact scope and measurements.

Historical ARM **0.19.0/build 180** added local preference/hotkey JSON import/export and ordering of 14 toolbar families; per-tool presets and local tool remapping were absent from that build. ZIP version 18 and guide version 26 were delivered on 10 October 2026 at 08:43:13 UTC; DMG version 18 was saved only. Intel 180 failed its early GIF gate. The [current ledger](docs/PARITY.md#current-arm-0210-and-retained-intel-011-acceptance) preserves these historical boundaries separately from build 191.

## Experimental capture workflow

ARM **0.22.0/build278**, source `827f2e73465832b8d2d118b82126a969403a9eb3`, qualifies only for the user-opted experimental distribution. Its new [current-long-capture chain route](docs/CaptureChains.md#build278-current-long-capture-chain-qualification) sends the already captured image to an explicitly chosen saved PNG Save / checked Copy / durable Pin chain. It captures nothing again, renders one frozen image, preserves committed receipts across cancellation and retries only unfinished outputs. Selecting a definition or opening its manager does not execute it. Explicit abandonment or choosing a new chain warns that earlier outputs remain and later processing may repeat them.

It retains direct axis drag, active capture timing, stale-position feedback, matched-frame-gated Auto, duplicate-preview recovery and checked transactional outputs. The [single matched Save experiment](docs/save-png-preparation-comparison.md) supports omission of the unused fresh-image Save thumbnail; required Export/supplied previews, encoder, writer and limits remain unchanged. Named region/preset chains and [local OCR → isolated text transformation → checked Copy](docs/TextScripts.md#build263-experimental-installed-qualification) remain available. The current-image route does not run scripts. No callable PicShot/file/network/process script APIs, external import or arbitrary action graph are provided.

Current coverage is **2,440 methods / 272 classes**: 2,437 ordinary passes and exactly three model deferrals subsequently passed among 12/12 actual-model tests. All 1,908 focused and 189 scrolling methods pass; selections overlap. Both actual ZIP/DMG installations pass their complete scrolling parents, child transactions, exact output pixels, UI and ownership checks. The owned native source fixture now aligns its window before construction; the earlier 276 failed final parents remain recorded, and the smoke path now rejects failed parents even when a child passes. Production matching thresholds and deadlines did not change.

Original227 repeated-scroll memory still fails its unchanged warm/late limits and was not rerun. The separate current default 4K observation reaches **451,608,576 B final RSS / 741,425,152 B kernel peak**, with **12,566,528 B warm→measured growth** and a late 8,765,440 B increment. Its owner cleanup passes, but it explicitly does not assess memory stability or prove private backing release. Generated native frames do not establish real ScreenCaptureKit/TCC, Retina/multidisplay, window exclusion, third-party scrolling quality or full PixPin experience. Stable214, Intel69 and stable ledger counts remain unchanged; no Intel278 package is accepted.

Download the [original ARM build278 ZIP artifact](https://github.com/dandibbert/picshot/actions/runs/38417935484/artifacts/11830841553) while retained, currently through **27 October 2026 at 16:30:12 UTC**. Unzip the downloaded artifact, then unzip its `PicShot-0.22.0-macos-arm64.zip` to obtain the app. The original inner ZIP is 22,030,658 B, SHA-256 `f825a092b31176b49a81f92e76af6eb0f3c185e554fe022d27b0d0849650fd32`. It exceeds the conversation attachment cap, so the prior263 native ZIP stays unchanged. The artifact link was sent at 16:45:10 UTC on13 October 2026; the current guide is saved as version10. This records link/guide preparation, not proof of user download or launch. See [exact qualification and memory figures](docs/VERIFICATION.md#build278-experimental-current-long-capture-chain-qualification).

The next source candidate adds [explicit saved text-script processing of the current long image](docs/LiveScrollTextScripts.md), while correcting two clipped automatic-recovery messages found in build279. Its new native/installed qualification is pending; build278 remains the delivered experimental package.

## Build

```sh
bash scripts/package.sh
swift build --product PicShot
swift build --product PicShotCodecHelper
swift test
bash scripts/smoke.sh
```

Builds need macOS, Xcode and preinstalled CMake 3.22+. `package.sh` explicitly fetches and builds the pinned official WebP/AVIF/AOM sources before Swift compilation; upstream build commands are network-denied and full notices are bundled. Codec versions, limitations and verification status are in [the codec document](docs/WEB_CODECS.md).

The `dist/` folder contains a `.app`, drag-to-Applications DMG, ZIP, checksums, native UI snapshots and launch/resource reports. Packages are ad-hoc signed and **not notarized**. No certificates or secrets are needed.

## Use

- Menu bar → region/window/display capture, scrolling capture, recording, paste pin
- New-install configurable shortcuts: ⌃1 region capture, ⌃2 clipboard pin, ⌃3 restore the last closed pin, ⌃⌘H history. Existing saved mappings are preserved
- Double-click a history item to annotate; right-click to pin, copy, OCR, star or trash
- ARM 0.20: use the editor’s 「样式」 menu to save/restore/reset one appearance default per drawing tool; text, notes and watermark content are excluded. Settings → 「标注快捷键」 configures canvas-only tool switches, all unassigned by default; Save affects newly opened editors and text/IME input keeps its normal behavior
- The editor provides byte-derived PNG/JPEG/TIFF/BMP/PDF/WebP/AVIF export previews and flattened outputs, solid redaction, blur and pixelation. Blur/pixelation are cosmetic; use opaque redaction in a flattened output when sharing secrets. Editable history and pins retain original pixels and removable layers, so they are not secure deletion
- ARM supports offline same-size repeated-region matching with explicit review, manual correction, synchronized masks and undo; see [automatic mosaic](docs/AutomaticMosaic.md). Intel remains at verified 0.11 pending independent installer acceptance
- ARM 0.16 preserves editable layers and nondestructive crop in new history and managed image pins. Legacy flattened images cannot regain layers; annotation hiding affects display only, while Copy/Save/OCR use the annotated current image
- Save and Naming settings provide quick-save, exact-byte save-and-copy, collision-safe names and default-off final-action PNG copies; see [save workflows](docs/SaveWorkflow.md)
- ARM 0.21: right-click a plain-text pin to edit with explicit Save/Cancel; rename managed image/text pins from their context menus, and reorder existing groups in the compact group manager. Rich/HTML content retains its original format and stays read-only
- Pins float over apps; the menu restores click-through pins. Image pins support selectable local OCR, optional default-off automatic recognition, source-linked text results and multiple barcode regions; see [pin OCR](docs/PinOCRWorkflow.md)
- Named region/delay presets are stored locally; changed displays invalidate stale presets. UI-element selection uses existing Accessibility access and otherwise falls back to manual selection
- Screen, microphone and camera permissions are requested only when those user-started features need them
- OCR/barcodes run locally. The app does not upload captures or recognized text; files saved into a user-selected cloud-backed folder may be synchronized by that provider. Explicit optional-model and system-language downloads require network access, and no analytics code is included

Screenshot history defaults to 200 items, 30 days or 1 GiB. Starred items are protected and still count toward quota; a full protected quota rejects new history rather than deleting favorites. Recordings have separate duration/file-size bounds. No claim of zero memory leaks is made.
