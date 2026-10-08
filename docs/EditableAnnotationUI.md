# Editable annotation UI contract

This change restores a persisted editable document into the existing AppKit editor and compact in-place pin surface. It does not recover layers from older flattened images.

## Current image, original image, and temporary visibility

- A pin's ordinary copy/save/export always uses its saved current annotated projection. Original-copy and original-save stay in their separate submenu
- “临时隐藏标注（仅显示）” replaces only the pin's display raster with the saved base projected through the same crop viewport and output decoration. It does not replace pixels, erase layers, rewrite the store, or change export inputs
- Visibility is temporary. Closing/reopening/restarting starts with saved annotations visible. Opening the editor shows editable layers; cancelling without a commit restores the prior hidden preview. Successful Apply reveals the newly committed annotated result
- OCR or barcode selection reveals the saved annotated image first, keeping visible selection coordinates consistent with the recognition source
- Missing/corrupt editable assets produce an explicit failure. A pin's saved current raster remains usable; the controller does not silently recreate an empty document for a declared editable entry

## Crop and image processing

Editor crop is a nondestructive integer viewport into the full base. Layers, IDs, sequence values, mosaic associations, styles, magnifier sources and coordinates remain unchanged. Rendering composites the full stack before cropping and then applies output decoration. Blur at crop edges, off-viewport magnifier sources, spotlight and erasure therefore sample the same pixels as before the crop. Nested crop is restricted to the current viewport; crop undo/redo changes metadata and shares the original base raster. After a fresh reopen, “取消裁剪（恢复完整底图）” in the context or More menu restores the full retained base, and that action is itself undoable.

AppKit canvas bounds carry the viewport origin with separate horizontal/vertical scaling. Canvas hit coordinates, inline text and numbered comments remain in full-base pixel coordinates. Frozen boundary expansion rebases all geometry, including mosaic association rectangles, while keeping the full preexisting sampling base if a crop viewport is active.

Automatic mosaic searches only the current visible base crop. Its seed and results are converted between local search pixels and unchanged full-base annotation coordinates. The full-base identity, content revision and viewport gate late results.

Pin crop opens the nondestructive editor crop tool for editable entries. Existing rotate/flip/grayscale/invert commands explicitly say “（合并标注）” when applicable. These raster operations save a new derived-raster base with no falsely editable old layers; original-copy/reset stay available. Ordinary legacy raster processing retains its previous behavior.

## Commit and resource boundaries

The optional appended onSaveEditable/onPinEditable/onApplyEditable callbacks throw on failure and must return only after the store durably commits source/base/document/current assets together. Failed commit leaves the prior pin content and editor draft/undo intact. Old image-only callbacks remain supported for existing callers.

Pin sessions lazy-load editable assets only when needed and reuse the live pin's original image. Store decode admission receives the remaining editor raster budget after live image-pin accounting. Hiding keeps at most one projected preview; showing releases it. Decorated hidden previews use the existing single-job output-projection lease and cancellation. Editors retain no full-raster history for crop, and close clears undo, cached previews and native view ownership.

These are explicit ownership/admission bounds, not total-process RSS, framework-cache, WindowServer or GPU bounds.

## Verification boundary

New native tests: EditableAnnotationUITests (5), EditableAnnotationPinTests (6), EditableAnnotationMosaicTests (2). They cover exact complex-effect crop/reopen pixels, fractional independent-axis native canvas hit coordinates, actual toolbar clicks, Space/Escape/undo/redo, durable-write refusal/retry, hidden copy/original semantics, restart/cancel/apply, actual cropped matching and stale results, and repeated lifecycle/resource ownership.

The isolated Linux workspace verified the build102 input blob hashes and patch application/whitespace, but has no Swift or AppKit toolchain. These 13 tests and existing native suites have not run here. The separate existing-checks patch updates three old assertions to test output viewport dimensions and retained layers instead of destructive source resizing. Native macOS compilation, both architecture gates, physical TCC, physical multi-display/Retina behavior and installed-package acceptance remain unverified at this handoff.
