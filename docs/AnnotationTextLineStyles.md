# Text outline and line styles

This original implementation adds opt-in glyph outlines, independent arrowheads at
both ends of lines and polylines, and configurable caps/joins. It does not add
comments, persistent presets, or toolbar customization.

## Model and rendering

`ImageAnnotation` owns the style values, so selected edits, copies, endpoint/vertex
moves, inline text commits, undo and redo use the same values as raster export.
Text outline has its own enable flag, color and bounded 0.5–8 pixel width. The
background keeps its existing independent fill flag/color, radius and opacity.
CoreText receives negative stroke-width percentages to preserve glyph fill;
NSTextView receives the matching AppKit attributes, including when typing at a
zoomed canvas scale. CoreText still controls wrapping, clipping and rotated canvas
and export output. Active inline input retains the existing unrotated editing UI.

Each line end has an enable flag and an open, filled triangle, hollow triangle,
diamond or circle form. The optional end-enable value defaults to one open end
arrow for the arrow tool and no arrow for line/polyline. Original default arrow
commands and dash phase are deliberately retained, including short, reversed and
degenerate arrows. New closed heads are bounded by the endpoint segment and do
not cross on a short two-ended line. Polyline heads follow the nearest distinct
endpoint segment. Caps are round, flat or square; joins are round, miter or bevel,
with CoreGraphics' miter limit explicitly set to 10. Fill geometry participates
in hit testing; painted stroke bounds include miters for eraser intersection.
Filled heads and stroked shafts are combined as one vector union before painting,
so translucent caps do not double-compose opacity at the head junction. Plain and
open-head defaults retain their original stroke operation.

Opaque redaction still bypasses annotation/color opacity. New line and text
properties do not alter its fill path.

## Compact native controls

Text outline controls sit beside typography/background in the text row. Arrow,
line and polyline rows expose small independent start/end toggles and forms.
Cap/join controls sit in the existing details row. The polyline finish/cancel
controls remain available during a draft. All controls write through the existing
inspector closure; no preview-only style state or raster history is introduced.
The inspector displays in-progress inline text values and selected arrow/line/text
values while those tools remain active.

## Verification interface

The opt-in entry point is:

`await AnnotationTextLinePreviewFixture.verify(evidenceDirectory: directory)`

It returns a JSON-compatible dictionary and writes
`annotation-text-line-preview.json`. On a WindowServer display of at least
760×600 points, it creates one owned editor at a time from authored white pixels:

- Light/dark native line, committed text and inline text palette PNGs
- Native endpoint forms, cap/join edits and a four-point polyline
- Draft cancel, selected vertex cancellation preserving redo, and repeated
  pixel-identical undo/redo
- Multilingual continued inline edits, outline color/width, background, rotation,
  cancellation preserving original text/style and the redo branch
- Native save callbacks and actual PNG decode equality with the flattened pixels
- Four edge-placement PNGs checking required controls inside the palette,
  toolbar/palette non-overlap, anchored source pixels and owned UI cleanup

The fixture does not capture the screen, use external input, TCC, network,
recognition, the general clipboard or standard preferences. Screenshots are
1× caches of its owned AppKit hierarchy. They are not physical-input or Retina
acceptance, and reference cleanup is not a process-memory/leak measurement.

`AnnotationTextLineStyleTests` adds frozen pre-change renderer comparisons,
short/reversed/zero-length paths, endpoint direction and hit testing, actual
cap/join/head pixels, multilingual rotated/wrapped outlines, bounded properties
uniform translucent head/shaft opacity, and an opaque-redaction regression. `AnnotationTextLinePreviewTests` executes the
native fixture and checks inline style attributes at 0.5×/1×/2× zoom.

These tests and the native fixture were authored in a Linux workspace without
Swift or AppKit. They have not been compiled or run there. macOS CI must establish
native build, test and installed-artifact evidence before acceptance.

## Primary references

- https://pixpin.cn/docs/mark/text
- https://pixpin.cn/docs/mark/arrow
- https://pixpin.cn/docs/mark/line
- https://developer.apple.com/documentation/coretext/kctstrokewidthattributename
- https://developer.apple.com/documentation/coregraphics/cgpath/union(_:using:)

The reference documentation informed the behavior; geometry and controls here are
original PicShot code.
