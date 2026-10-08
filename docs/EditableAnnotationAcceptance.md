# Installed editable-annotation acceptance

## Owner integration

The standalone entry point is:

```swift
try await EditableAnnotationNativeFixture.verify(
    evidenceDirectory: evidenceDirectory,
    includeResources: ProcessInfo.processInfo.environment["PICSHOT_EDITABLE_ANNOTATION_RESOURCES"] == "1")
```

Add an early smoke-only AppMain route for `PICSHOT_EDITABLE_ANNOTATIONS_ONLY=1`. Its evidence directory is the directory containing `PICSHOT_SMOKE_REPORT`; preserve the existing launch/source report and owned process exit behavior. Do not execute the broad unrelated smoke suites in this dedicated process.

Add `PICSHOT_EDITABLE_ANNOTATIONS_ONLY` and `PICSHOT_EDITABLE_ANNOTATION_RESOURCES` to the launcher's environment forwarding list. Include `PICSHOT_EDITABLE_ANNOTATIONS_ONLY == "1"` in the condition that writes the `.launcher.json` owned-lifecycle sidecar. No change to the existing 600-second launcher cap is needed; the new fixture has its own 300-second cooperative deadline.

Example installed calls, with fresh evidence directories:

```sh
bash scripts/editable-annotation-smoke.sh /absolute/PicShot.app /absolute/evidence-functional SOURCE_COMMIT functional
bash scripts/editable-annotation-smoke.sh /absolute/PicShot.app /absolute/evidence-resources SOURCE_COMMIT resources
```

The wrapper verifies ad-hoc bundle signatures, launches a new owned instance, verifies its confirmed exit and PID, and runs the strict checker against that exact bundle/executable/source/version/build. Functional mode runs the two native cases. Resource mode runs those cases and the additional repeated workload. Run the resource mode only where the package gate intends it; the fixture does not claim independent Intel or ARM acceptance from the other architecture's report.

## Native scope

Each functional case uses distinct synthetic original and derived-base rasters. Dimensions are 640×360 and 3840×2160. Seven authored layers include rotated opaque redaction, crop-edge blur, a magnifier with source outside the crop, spotlight, erasure, and linked pixelation regions.

Actual owned AppKit buttons, menu items, canvas hit tests, drags, Space, and Command-Z drive crop, save-to-history, edit/undo, cancel, pin, hide/show, export, and apply. Every explicit history save adds a new record and the prior record is checked for survival. History reopen uses the production public HistoryStore→restoreEditablePayload APIs. The SwiftUI history-grid double-click inside AppMain is not exercised by this fixture and is reported as such.

A fresh store reads real PNGs and metadata. Exact canonical RGBA hashes compare full-stack→crop→decoration output with saved current pixels and re-rendered restored layers. Uncrop after reopen and its undo are exercised. A before-index-commit failure records staged file identities and checks unchanged durable file hashes plus a preserved draft, followed by a successful retry. Pin Space restores the saved layers; cancel preserves the saved result and prior temporary visibility. Every native rectangle gesture must create exactly one new ID, expected geometry and changed document bytes before an undo/cancel assertion can pass. Apply commits a distinct eighth visible layer, then a fresh pin store must return its changed metadata/current pixels and an exact re-rendered result while original/base pixels stay unchanged.

While annotations are hidden, the real pin Save menu opens the shared export controller. The encoded PNG artifact is decoded and compared with the saved annotated output. The separate original-save action is compared with the original raster. No file picker is submitted and no general pasteboard is used. Legacy raster history remains without invented editable layers.

## Resource scope

Resource mode performs two warmups and eight measured cycles. Each repeats the entire native 4K functional path with actual PNG/metadata writes and reads, native export encoding, failure/retry, close/reopen and cleanup. It creates and releases its own original/base inputs per cycle; no input raster is retained at endpoints. Original and base are distinct 4K images, so a small viewport cannot substitute for full-base memory accounting.

Weak role probes cover original/base/current rasters, canonical CGContext normalization, controllers, canvases, content views, window shells, pins and stores. Known row-byte costs and peak simultaneous tracked objects are retained. Closed NSWindow shells may be cached by AppKit; their count remains visible and their content/delegate graphs must be detached. This is not an assertion that every AppKit window allocation disappears.

A single 50 ms sampler records bounded per-phase aggregates for RSS, physical footprint, compressed bytes, actual volatile resident/virtual/pmap values, and volatile resident/compressed ledgers. Every settled endpoint also retains the raw standard and purgeable task-info responses. Entry, warmup, baseline, each measured cycle, late increments and final cleanup remain visible. The report is checkpointed before and after each resource cycle, so a later failure preserves completed endpoints and the active cycle's entry rather than discarding the observations. Missing fields are failures; missing readings never become zero. Positive RSS or backing growth is preserved, not rejected or hidden by comparing only physical footprint. These are observations, not a plateau, zero-leak, allocation-attribution or whole-system conclusion.

Own-process FD checks match device/inode and owned directory paths, including files unlinked during rollback or cleanup. Temporary paths and live output reservations must be gone. The loop does not use system memory pressure, allocator purges, security changes, TCC, screen capture, external application input, user files, clipboard, or network.

## Checker and execution boundary

`check-editable-annotation-report.py` rejects duplicate JSON keys, nonfinite values, booleans used as counts, oversized or symlinked reports, mismatched installed identities/PIDs, missing workload phases, incorrect pixel/cleanup assertions, missing memory fields, misleading stability flags and changed growth arithmetic. It verifies the thin Mach-O CPU header against the reported architecture.

The Python test module covers valid synthetic schemas and hostile mutations. Passing those tests validates the checker, not native Swift execution. The Linux authoring environment has no Swift/AppKit toolchain. Native compilation, real installed report production, screenshot-based visual review, minimum-macOS support, physical Retina/multi-display/TCC and both independent architecture package gates remain pending owner execution.
