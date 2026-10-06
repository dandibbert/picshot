# Verification boundary

Each architecture is compiled and tested on a GitHub-hosted macOS runner. The CI installs ZIP and DMG into separate temporary folders, verifies ad-hoc signatures and architecture, launches with LaunchServices without app arguments, confirms the actual native window, renders AppKit view snapshots, and records RSS across 40 synthetic editor/pin create-render-close cycles.

This does **not** establish user-TCC grant/deny behavior, interactive screen capture of real apps, multiple physical monitors/mixed Retina scaling, sustained video/audio recording, OCR quality across languages, or production memory leak freedom. Those require real-device acceptance tests. No permission database is modified and no user's OS permissions are granted in CI.

Tests cover pure retention/search rules, raster annotation/crop/export behavior, conservative stitching fixtures, and recording/export option validation. Passed/failed evidence must be tied to an exact commit. A successful unit suite is not proof that all screen workflows work.
