# Source-pixel selection ratios

The frozen region selector offers Free, 1:1, 4:3, 3:2, 16:9, 9:16 and Custom, with Swap and source-pixel width/height fields. Custom numerator and denominator must each be whole numbers from 1 through 10,000; values are reduced before use. A ratio that cannot fit the current display at the minimum size is refused.

Choosing a ratio enters precision selection: drag, refine with the fields or eight handles, then use Return or Use selection. Choosing Free unlocks it. The ordinary initial free drag still opens the editor immediately. Tab hides the selector controls to reach pixels underneath them; Escape and right-click cancel the capture, including during a drag. In a view too small to display the controls (below 320 × 180 points), the selector omits its floating controls.

The frozen editor has a selection-ratio button in its existing floating toolbar, also available from More and the context menu. Its compact palette controls the capture boundary. Annotation rectangles, ellipses and other drawing tools do not inherit the ratio. The separate free crop tool unlocks the resulting capture boundary; undo restores the previous lock and image. Imported images and pinned-image editors do not expose frozen-display boundary controls.

Rectangular multi-region capture has the same ratios in its existing floating strip. A new rectangle, cutout, handle resize, Option-arrow resize or numeric edit honors the current ratio. Clicking an earlier rectangle keeps its shape until edited; feedback says “Next resize ratio” if that existing shape does not match. Ratios do not constrain polygon/freehand capture or the composite bounding box, transparent gaps and cutouts.

## Exactness and rounding

Ratios describe original source pixels, using the source image's independent X/Y pixels-per-point values rather than an assumed Retina factor. For reduced N:D, permitted dimensions are exactly kN × kD source pixels. Dimensions are never independently rounded while labeled exact. Numeric width or height edits round k to the nearest integer (halfway upward) and display the actual resulting width and height. For example, width 97 at 16:9 becomes 96 × 54. The most recently edited dimension drives Set px/Apply px. Positive requests that are too small or whose nearest multiple cannot fit are refused; dimensions are not silently clipped. The feedback states the N × D pixel step.

Drags snap the anchor to the nearest source pixel, use the larger ratio-normalized pointer extent and snap the common multiplier. They shrink by whole ratio steps at display/output bounds. Corner handles retain the opposite corner and do not flip through it. Side handles retain the opposite edge and preserve the other-axis center within half a pixel, shifting that center only when display bounds require it. Enabling or swapping a lock uses the nearest width-based size that fits and keeps the origin unless a shift is required to remain inside the same display. Each dimension remains at least two logical points.

Arrows move one source pixel, Shift moves ten, and Option resizes by one exact ratio step (ten with Shift). Without a lock, Option resizes by single pixels. The frozen editor's boundary arrow controls are active while its ratio palette owns focus. Existing annotation keyboard behavior is unchanged. Command-Z and Shift-Command-Z include ratio changes and precision edits. Canceling an editor boundary drag leaves both the ratio and existing redo state intact.

## Pixel and resource boundary

The immutable frozen source, original screen origin, captured timestamp and display-change rejection remain authoritative. Integer selections use the exact-pixel crop path through capture and boundary commits, avoiding a second floor/ceil conversion at fractional densities. Near-integer numerical epsilon is stabilized in multi-region conservative bounds checks so an exact 32M selection does not gain a false extra column. Ratios are scalar state in undo snapshots; pointer movement reuses the frozen image and existing crop preview. Only a committed boundary size change materializes the new crop, and annotations are translated by the source-pixel origin offset.

Geometry obeys existing 32,768-pixel dimensions, 64M source and 32M output limits. This is a bound on the ratio/selection geometry, not a total-process memory claim.

## Verification status

`CaptureAspectRatioTests` covers pure geometry, all drag quadrants and eight handles, invalid and extreme custom values, numeric refusal/rounding, tiny and edge selections, 1×/2×/fractional/independent densities, exact-pixel replacement and the 32M preflight edge case. `CaptureRatioInteractionTests` supplies native owned-window events for the selector, multi-region controls and editor boundary, including ratio state undo/redo, cancel, immutable source pixels, screen origin, annotation anchoring and raster identity during drag. Existing frozen capture, advanced capture, boundary and toolbar fixtures remain applicable.

These XCTest fixtures are authored but have not been executed in the Linux authoring environment, which has no Swift executable or macOS SDK. Static review and independent scalar arithmetic checks do not establish native compilation, actual UI layout, installed-app acceptance, physical Retina/multiple displays, or a memory plateau. Those remain release gates for the integrating owner.
