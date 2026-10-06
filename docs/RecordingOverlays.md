# Recording camera and live annotations

This is original PicShot implementation work for REC-09 and REC-10. It does not copy PixPin code or assets. Authored source/tests are not a native build or hardware acceptance pass.

## Reachable controls

The existing compact recording panel contains a Camera toggle and aperture/settings button. Enabling Camera is the only permission-request path. Device enumeration, application startup, opening the panel, and refreshing devices do not request camera permission. The settings popover selects a device, mirrors it, chooses a rounded rectangle/ellipse crop, resizes the overlay, and zooms/pans the crop. During recording, camera placement can be dragged and the bottom-right handle resized (Shift-drag also resizes).

The recording panel's Annotation toggle enables a transparent drawing surface over the selected capture region. Pen, arrow, rectangle, ellipse, highlighter, and brush eraser are available with color/width, undo, and clear. Escape exits interaction so normal desktop clicks resume. These marks are composited into encoded pixels. Undo/clear affect subsequent accepted frames only; already written frames remain unchanged. Annotations are cleared when starting a new take, because each take may use a different display, scale or region. Camera layout persists within the service; camera hardware is released at Stop, failure, cancellation and control-window close. Save-and-restart preserves the explicit camera opt-in, releases the session between takes, and restarts it for the next take.

## Capture and timing

`RecordingCameraController` owns generation-safe opt-in state; the injectable `RecordingCameraProviding` protocol supports permission/cancellation/disconnect tests without hardware. A synchronously revocable lease binds queued start/stop work to its own session; queued notifications and output callbacks also validate their generation/identity. `AVRecordingCameraProvider` serializes session configuration/start/stop, uses 640 × 480 video-only capture, discards late frames, and reports permission denial or device/session failure without stopping screen recording. Camera callbacks from old/disabled generations cannot repopulate the frame slot.

`RecordingCompositionState` retains one latest camera buffer and a bounded vector snapshot. `RecordingFrameCompositor` draws the camera and the shared annotation renderer directly into one BGRA destination. The pixel pool has a hard allocation threshold of three surfaces. Pool pressure drops a frame rather than allocating an ever-growing queue. No frame history is kept. At most 256 annotation operations and 4,096 points per operation are admitted; undo stores eight bounded vector snapshots, not screen images.

The Stop barrier freezes a composition snapshot before any slow stream/encoder cleanup; camera hardware is released immediately and post-stop frames cannot enter a pending-resume output frame. The frozen snapshot is released when finalization completes.

The existing ScreenCaptureKit stream and AVAssetWriter remain responsible for screen/audio sampling, shared-clock pause cuts, AAC, duration/file limits, durable save and export. A bounded encoder timer samples overlay changes against the same screen clock when a static desktop emits no complete frames. A separate raw-screen revision preserves a changed desktop whose callback arrives later than a refresh heartbeat. Raw screen frames and composed video frames stay separate so camera/annotation layers are never applied twice. Overlay sampling respects the selected frame-rate cap and stops while paused.

The ScreenCaptureKit filter excludes the PicShot application, including windows created after recording starts. Thus PicShot's preview, controls and interaction surface are excluded rather than baked in a second time. This also means other PicShot windows/pins are excluded from recordings. The transparent preview has sharing disabled as an additional precaution. Non-PicShot windows and the selected display/region keep the existing capture semantics.

## Verification authored

- `RecordingCameraTests`: enumeration without permission; denial; disable/cancellation during pending permission and suspended start; stale start/failure versus new session; selected device switch; disconnect/late callback rejection; constant-space latest frame replacement
- `RecordingCompositionTests`: actual synthetic pixel checks for placement, mirror, crop and ellipse clipping; vector drawing/eraser composition; pool backpressure; finite geometry/vector limits; real H.264 MP4 encode/decode with changed camera/annotations, static screen, pause removal, PTS and final duration; late real desktop callback after synthetic refresh; frozen pending-resume camera at Stop; asymmetric desktop/camera orientation through actual H.264
- `RecordingOverlayControlTests`: live draft publication, Escape/cancel, undo/clear, normalized camera dragging/resizing/crop and recoverable annotation limits
- Existing `RecordingPauseTests`, `RecordingControlTests`, `RecordingAndGIFTests`, `RecordingPreviewWindowTests`, and `VideoTrimTests` remain regression gates

These tests do not access a real camera, microphone or screen and do not grant TCC permissions or post user input. Native compilation, these tests and hardware/TCC acceptance are unverified in the Linux authoring workspace. Required real-device checks include permission denial/re-enable, USB/Continuity camera availability and unplug, actual overlay positioning on Retina/non-Retina/multiple displays and selected regions, source/preview/output color/orientation agreement, ScreenCaptureKit exclusion, repeated pause/restart/close/quit and camera indicator shutdown. The app bundle must include `NSCameraUsageDescription` before any hardware run. No full REC-09/REC-10 parity closure is claimed by this document.
