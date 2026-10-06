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
- Default configurable shortcuts: ⌃⌘A region capture, ⌃⌘P clipboard pin, ⌃⌘H history
- Double-click a history item to annotate; right-click to pin, copy, OCR, star or trash
- The editor provides real flattened PNG/JPEG/TIFF/PDF outputs, solid redaction, blur and pixelation. Blur/pixelation are cosmetic; use opaque redaction for secrets
- Pins float over apps; the menu restores click-through pins
- Screen and microphone permissions are requested only when those user-started features need them
- OCR/barcodes run locally. No network or analytics code is included

Screenshot history defaults to 200 items, 30 days or 1 GiB. Starred items are protected and still count toward quota; a full protected quota rejects new history rather than deleting favorites. Recordings have separate duration/file-size bounds. No claim of zero memory leaks is made.
