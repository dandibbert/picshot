# PicShot

Original, local-first macOS screenshot, annotation, pinning and recording utility. Written in Swift/AppKit, with Apple Vision OCR and ScreenCaptureKit recording. macOS 14+, Apple Silicon and Intel.

**Development preview. Not full PixPin parity yet.** This project is not affiliated with PixPin and uses no proprietary source, assets, subscription bypasses, or hosted recognition credentials. See [feature ledger](docs/PARITY.md) for actual scope and [verification](docs/VERIFICATION.md) for the test boundary.

ARM 0.17.0/build159 is accepted within the bounded [verification scope](docs/VERIFICATION.md#build-159-recording-input-acceptance-record), adding [opt-in recording input effects](docs/RecordingInputEffects.md). Intel159 failed its bounded [installed long-capture resource gate](docs/Intel159InstalledFailure.md); accepted Intel stays 0.11.0/build69. ARM159 ZIP Library v16 and guide v24 were delivered on 9 October 2026 at 18:48:27 UTC; DMG v16 is saved only.

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
- The editor provides byte-derived PNG/JPEG/TIFF/BMP/PDF/WebP/AVIF export previews and flattened outputs, solid redaction, blur and pixelation. Blur/pixelation are cosmetic; use opaque redaction in a flattened output when sharing secrets. Editable history and pins retain original pixels and removable layers, so they are not secure deletion
- ARM supports offline same-size repeated-region matching with explicit review, manual correction, synchronized masks and undo; see [automatic mosaic](docs/AutomaticMosaic.md). Intel remains at verified 0.11 pending independent installer acceptance
- ARM 0.16 preserves editable layers and nondestructive crop in new history and managed image pins. Legacy flattened images cannot regain layers; annotation hiding affects display only, while Copy/Save/OCR use the annotated current image
- Save and Naming settings provide quick-save, exact-byte save-and-copy, collision-safe names and default-off final-action PNG copies; see [save workflows](docs/SaveWorkflow.md)
- Pins float over apps; the menu restores click-through pins. Image pins support selectable local OCR, optional default-off automatic recognition, source-linked text results and multiple barcode regions; see [pin OCR](docs/PinOCRWorkflow.md)
- Named region/delay presets are stored locally; changed displays invalidate stale presets. UI-element selection uses existing Accessibility access and otherwise falls back to manual selection
- Screen, microphone and camera permissions are requested only when those user-started features need them
- OCR/barcodes run locally. The app does not upload captures or recognized text; files saved into a user-selected cloud-backed folder may be synchronized by that provider. Explicit optional-model and system-language downloads require network access, and no analytics code is included

Screenshot history defaults to 200 items, 30 days or 1 GiB. Starred items are protected and still count toward quota; a full protected quota rejects new history rather than deleting favorites. Recordings have separate duration/file-size bounds. No claim of zero memory leaks is made.
