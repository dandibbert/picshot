# Pencil and highlighter annotations

The compact floating palette provides pencil smoothing and Shift straight-line choices (free angle, 45°, 30°, 15°, 10° or 5°). Press Shift during a stroke to anchor one straight section at the last sampled position; release Shift to continue drawing. Snapped sections shorten along the same angle at the image boundary. Single clicks and tiny strokes produce visible round ink. Mouse-up always contributes the final point.

Highlighter offers brush and rectangular selection modes, with multiply and translucent blending. Multiply preserves dark text on light backgrounds; translucent blending is clearer on dark backgrounds. Both apply 32% ink alpha multiplied by the annotation opacity. A stroke is painted once, so retracing within the same stroke does not repeatedly darken the overlap. Separate annotations still compose in order.

New canvas strokes enable smoothing and use brush/multiply highlighting. Existing model defaults remain unsmoothed pencil and rectangular/translucent highlighting. Selecting a mark exposes the same editable style used in its flattened export. Style changes and geometry edits use existing undo/redo; Escape, changing tools or changing palette settings during a stroke discards its draft. Drafts are excluded from export. Closing the editor releases the pending gesture and presentation cache.

Smoothing uses quadratic midpoint segments inside the sample hull. Before long-stroke simplification, stroke endpoints and Shift joins stay exact. There are no generated bitmap layers in annotation history. Each gesture retains at most 2,048 points and 2,048 hard-join indexes; very long gestures progressively remove alternating samples while preserving the first point and current endpoint. The status strip reports this simplification. Brush width is bounded to 1–256 image pixels. These are per-stroke vector bounds, in addition to the editor's existing raster and history limits.

The renderer shares stroke geometry with hit testing and output. It retains the existing annotation order, eraser clipping and opaque-redaction handling. Blending does not bypass redaction; redacted source pixels are already replaced before a subsequent highlighter blends against them. Blur, pixelation and highlighting remain cosmetic effects, not privacy redaction.

## Verification entry points

- `AnnotationFreehandTests`: geometry, all angle choices, reversed strokes, legacy raster equivalence, click/tiny marks, self-overlap, blend pixels, redaction/eraser order, bounded samples and exact PNG appearance
- `AnnotationFreehandInteractionTests`: synthetic native events, nonuniform zoom, mouse-up-only endpoint, repeated release, Escape/tool-switch/content replacement, Shift paths and palette-mode cancellation
- `AnnotationFreehandPreviewTests`: two bounded installed-style fixture passes with exact output hashes and owned-window/cache cleanup
- `@MainActor AnnotationFreehandPreviewFixture.verify(evidenceDirectory:) async throws -> [String: Any]`: opt-in native fixture, seven result PNGs, six light/dark/edge native palette screenshots and `annotation-freehand-preview.json`; reports failures rather than claiming partial completion

The fixture uses original synthetic pixels and owned AppKit windows. It does not access the general pasteboard, capture the desktop, request permissions, write preferences or use the network. It requires a macOS WindowServer display of at least 760 × 600 points. Native tests and screenshots must be run on macOS; authoring these checks on Linux does not establish a native pass. Synthetic events are not evidence of physical mouse routing or Retina capture.

Behavior references: [PixPin pencil documentation](https://pixpin.cn/docs/mark/pencil), [PixPin highlighter documentation](https://pixpin.cn/docs/mark/mark-pencil). Implementation and fixtures are original PicShot code and artwork.
