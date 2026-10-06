# All-display screenshots and screenshot options

This milestone adds user-started single/all-display screenshots with optional cursor inclusion and screenshot start delay (0, 3, 5, or 10 seconds). Region/window delay occurs before the system selector opens; cursor inclusion is intentionally scoped to display captures. The existing interactive selector has not been verified to support this option.

## Geometry and resource policy

- Display frames use global Quartz logical coordinates, including negative X/Y origins. ScreenCaptureKit returns already-oriented pixels; portrait/rotated displays are positioned with their oriented bounds, without applying a second rotation.
- The desktop bounding rectangle is rendered at the largest participating display density. Lower-density displays are enlarged using nearest-neighbor sampling; this does not create native detail. Relative logical sizes and positions remain consistent. Rounded shared edges avoid seams on fractional-density layouts.
- Desktop gaps are transparent black. Displays are drawn in stable display-ID order; the later ID wins in an overlap, including active software-mirrored arrangements. Non-drawable hardware-mirrored secondaries are represented by their active primary; a missing primary fails the capture.
- A 64,000,000-pixel and 32,768-pixel-per-side limit is enforced before any composite or frame allocation. Empty gaps count toward this budget. Each source frame is also bounded. The composite is 8-bit sRGB RGBA; HDR preservation is not claimed.
- Capture is sequential, retaining one output canvas and at most one incoming frame. Frames are released before requesting the next. This is not a simultaneous multi-display snapshot. Moving content or the cursor can therefore appear at different moments.
- Core Graphics display-change callbacks and fresh system snapshots reject connection, bounds, scale, pixel-size, rotation, or mirroring changes, including a change that reverts during capture. Returned frame dimensions must match the original plan. Partial composites are discarded.

## Delay and cancellation

The calling UI owns its screenshot Task. Cancelling it stops the delay before permission or image access, terminates the interactive selector, and discards an in-flight SCK result. macOS 14 SCScreenshotManager has no stop API: a request already running may finish internally before the cancelled Task unwinds; a second frame, history insertion, or editor must not start afterward. Keep the UI busy until that task returns.

CaptureService.capture(mode:options:) and captureDisplay(displayID:options:) accept a ScreenshotCaptureOptions value. User menu entry points pass ScreenshotPreferences.options. Capture-service defaults remain immediate/cursor-free so advanced and scrolling capture do not unexpectedly inherit user screenshot delay. Advanced screenshot entry points can explicitly await the preference's delay before freezing their source. A Cancel Screenshot menu action cancels the retained Task.

## Verification boundary

Synthetic tests cover negative origins, vertical placement, transparent gaps, mixed density, portrait/rotation metadata, asymmetric pixel patterns, overlap ordering, allocation/overflow rejection, missing/changed frames, pre/during/post-operation cancellation, repeated sessions, preference defaults/round trips, and the SCK configuration's cursor flag. Frame-lifetime fixtures verify that sequential composition does not retain a source-frame array.

These tests do not grant screen permissions or perform real screen capture. Real multi-monitor hardware, physical rotation changes, Retina/non-Retina combinations, TCC prompts/denials, and visual cursor placement still require manual on-device verification. Build/test execution results belong in the release verification record; source tests alone are not evidence they passed.
