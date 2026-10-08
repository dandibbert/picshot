# Capture and output workflow candidate

This is a development candidate for 0.15. Native compilation, pixel review and installed ZIP/DMG acceptance must be recorded against the final source before these additions are called verified. The accepted ARM package remains 0.14 until then; the accepted Intel package remains 0.11. The complete feature ledger is [PARITY.md](PARITY.md).

## Selection ratios

The compact selector and frozen capture editor offer free selection, common ratios, custom positive integer ratios, width/height swap and source-pixel dimensions. Exact ratios use integer multiples of the reduced numerator and denominator. Numeric edits show the actual snapped dimensions; an impossible size is refused. A ratio changes capture boundaries, not annotation geometry. Undo, redo and cancellation preserve both boundary and lock state.

The immutable frozen screenshot and its captured time remain authoritative. Ratio calculations use independent source X/Y density rather than an assumed Retina factor. See [CaptureAspectRatio.md](CaptureAspectRatio.md) for rounding, anchors, limits and the separate physical-device acceptance boundary.

## Rounded corners, border and shadow

The editor's rounded-rectangle icon opens a small draft palette with a preview, Apply, Reset and Cancel. Applying decoration records one undo entry. The original screenshot, annotation coordinates and crop geometry remain undecorated. Current-image output is projected only when copying, saving, pinning, exporting, applying to a pin or recognizing/translating the current result.

The border is inside the original bounds. Corner radius clamps to half the shorter side. Shadow follows actual alpha, including disconnected content, and adds a bounded transparent margin. Positive offsets go right/down; the palette shows the resulting output dimensions. A translucent shadow can enter transparent gaps within its finite support. It is a visual effect, not redaction.

PNG and alpha-enabled TIFF/WebP/AVIF preserve the projected transparency under their existing format options. JPEG/BMP/PDF use the existing explicit white flattening boundary. The preview is a scaled approximation; the exported projection uses source-pixel sizes. No editable source layer or undecorated source is embedded in a flattened exported image.

New managed pins retain separate immutable original and current rasters. Their two assets publish in one atomic session transaction; failed persistence rolls back staged assets. Copy/save original and reset intentionally refer to that initial source. An existing pin keeps its prior original when an editor result is applied.

Decorated output reserves one global job before flattening, rejects simultaneous final requests, and runs the projection away from the main thread. Palette normalization and final projection share one serial worker queue. Cancellation clears queued input and suppresses stale results, while the final reservation stays occupied until the operation and completion drain. Close, source edits, crop, undo and new palette interactions cancel pending work. This serialization is specific to these decoration workers, not a global cap on all app encoding or image work.

The final flattened input plus renderer allocations/scratch must fit a 512 MiB admission budget. It is not a total-process RSS limit. Input/output dimensions are bounded at 32,768 pixels per side and 100 million pixels, subject to that stricter combined memory test. Large shadowed images can therefore be refused below 100 MP; existing undecorated output retains its prior limits. Radius is at most 4,096 px, border 128 px, blur 64 px, offsets ±128 px and padding at most 512 px per edge. Original image rasters and any active projection reservation are counted during editor admission, including a canceled job still draining after its editor closes.

## Multiple windows

“多窗口合成…” uses one in-place selector with a compact count/capture/cancel strip. Selected windows are acquired sequentially and composited in desktop order onto one transparent canvas. No background screenshot is included. A move, closure, display change, incomplete raster or ambiguous identity aborts the whole result. It is not an atomic snapshot of animated windows.

At most eight windows, 16 MP per input, 64 MP total input, 32 MP output and 16,384 pixels per side are admitted. Only one source frame is held beside the final canvas, at most 192,000,000 owned raster bytes. Decoder/framework buffers, the system capture subprocess and WindowServer are outside that accounting. One temporary PNG has an 80 MiB file-size limit. Cancellation terminates/reaps the owned system command and cleans its private temporary directory before capture admission is released.

The native injected fixture verifies selection events, overlap ordering, RGBA/alpha pixels and cleanup. The repeated resource fixture separately uses fresh 4K PNG decodes and the production compositor. Neither proves real TCC, occluded-window capture, physical Retina, multiple-monitor acquisition or Spaces behavior. See [MultiWindowCapture.md](MultiWindowCapture.md).

## Required acceptance

- Final-source native compilation and complete ordinary/focused/model suites
- Real native light/dark/edge palette and in-place selector screenshots over labeled synthetic content
- Exact source and projected pixels, undo/cancel, original/current pin persistence and cleanup
- Installed ZIP/DMG functional gates; repeated large multi-window cycles from installed ZIP with RSS, physical footprint and volatile-backing counters retained separately
- All previous recording, GIF/codec, OCR, pin, annotation and manual-scroll gates remain required

Test source is not runtime evidence. Resource reports must preserve warmup totals, late increments and incomplete cells; no general memory plateau or leak-free claim is made.
