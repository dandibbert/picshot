# PicShot

Original, local-first macOS screenshot, annotation, pinning and recording utility. Written in Swift/AppKit, with Apple Vision OCR and ScreenCaptureKit recording. macOS 14+, Apple Silicon and Intel.

**Development preview. Not full PixPin parity yet.** This project is not affiliated with PixPin and uses no proprietary source, assets, subscription bypasses, or hosted recognition credentials. See [feature ledger](docs/PARITY.md) for actual scope and [verification](docs/VERIFICATION.md) for the test boundary.

## Build

```sh
swift test
bash scripts/package.sh
bash scripts/smoke.sh
```

The `dist/` folder contains a `.app`, drag-to-Applications DMG, ZIP, checksums, native UI snapshots and launch/resource reports. Packages are ad-hoc signed and **not notarized**. No certificates or secrets are needed.

## Use

- Menu bar → region/window/display capture, scrolling capture, recording, paste pin
- New-install configurable shortcuts: ⌃1 region capture, ⌃2 clipboard pin, ⌃3 restore the last closed pin, ⌃⌘H history. Existing saved mappings are preserved
- Double-click a history item to annotate; right-click to pin, copy, OCR, star or trash
- The editor provides byte-derived PNG/JPEG/TIFF/BMP/PDF export previews and flattened outputs, solid redaction, blur and pixelation. Blur/pixelation are cosmetic; use opaque redaction for secrets
- Pins float over apps; the menu restores click-through pins. Image pins support selectable local OCR and multiple barcode regions
- Named region/delay presets are stored locally; changed displays invalidate stale presets. UI-element selection uses existing Accessibility access and otherwise falls back to manual selection
- Screen, microphone and camera permissions are requested only when those user-started features need them
- OCR/barcodes run locally. Images and text stay on the device; explicit optional-model and system-language downloads require network access, and no analytics code is included

Screenshot history defaults to 200 items, 30 days or 1 GiB. Starred items are protected and still count toward quota; a full protected quota rejects new history rather than deleting favorites. Recordings have separate duration/file-size bounds. No claim of zero memory leaks is made.
