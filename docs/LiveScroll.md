# Live scrolling capture candidate

This is the replacement product path under development after the 0.21.0/build214 delivery. It is not yet an accepted installer. The 216 pin-isolation/group-name work remains in its original commit and is deliberately parked; this candidate starts from the accepted214 product baseline and preserves its legacy import/precise-strip-editing entry.

## Intended interaction

Choose a region directly from the menu, or use Long Capture beside an existing screenshot selection. Scroll the underlying application normally. A nonactivating nearby toolbar and live thumbnail remain visible. Ordinary reverse scrolling changes the current viewport and reconnects the matcher without deleting captured coverage. Finish/Edit and Copy flush the last verified viewport and end capture. Pause preserves data. Uncertain alignment keeps the last good result and asks for a small reverse scroll without opening a large window or taking application focus.

Use the persistent “移动” handle to drag the selection directly while the nearby toolbar and last good preview remain visible. During active capture, movement pauses and drains acquisition, constrains dragging to the scrolling axis and preserves target-window identity and pixel extent. Mouse release applies the final position once draining completes; resumed observations must establish verified overlap before the preview marker turns green. Escape or focus loss restores the old region. A paused move may use either axis but must remain in the same target window and display, and it stays paused afterward. The More menu’s full-screen mover remains a fallback. Movement is not uninterrupted acquisition. An orange dashed preview marker describes the last known position while current alignment is unverified.

## Acquisition and ownership

`LiveScrollScreenSource` uses one region-configured ScreenCaptureKit stream at15fps, queueDepth3, own-application exclusion and one replaceable pending pixel buffer. Consumed CGImages own their copied bytes. No whole-frame equality or hashing gate is used. Serial matching has backpressure: an older pending observation may be replaced, never queued without limit. If a fast movement loses overlap, it must remain a recoverable failure rather than an invented seam.

`LiveScrollMatcher` obtains signed translation from distributed textured evidence, refines integer offsets and bounds local mismatch regions. Small stationary leading/trailing bars are identified separately and then locked. Ambiguous repeated/blank content, major replacement or incompatible fixed geometry fails conservatively. Arbitrary dynamic pages and large stationary sidebars are not claimed supported.

`LiveScrollDocument` stores only newly exposed immutable pixel strips. Fixed leading/trailing edges appear once. Cached reduced tiles create bounded incremental previews without repeatedly decoding the historical full-resolution sources. Intermediate verified movement may appear in a transient preview before a durable keyframe; Finish/Copy must commit that same final verified viewport before publishing it. Previous accepted coverage is never silently shortened.

Limits remain60MP output,32768-pixel maximum edge,512MiB private temporary storage and100 durable source additions. Screen observations are separately bounded to2400 samples and180seconds of active acquisition. Paused, draining and moving intervals do not consume that time budget; the sample cap is unchanged. Once either cap is reached, Continue and movement are disabled while Finish and Copy retain the accepted image. Cached preview tiles are capped at4MiB; the document preview is capped at1MP/1024 pixels per edge, and the displayed thumbnail independently owns at most262,144 pixels/1024 pixels per edge. These are component limits, not a whole-process RSS or GPU-memory guarantee.

## Verification scope

The first focused macOS job must compile the real app, run the new matcher/storage/source/geometry tests, and launch a native numbered scrolling document with visible live preview. It records whether Screen Recording permission was already available. Native-rendered injection remains explicitly distinct from real ScreenCaptureKit capture, and neither substitutes for a physical Mac's trackpad, Retina, multiple displays, Spaces, third-party pages or TCC transitions.

The real-app demonstration records continuous wheel movement, first-preview and update latency, ordinary reversals, a sticky header, last-good recovery and final output pixels. A separate plain-text case has no artificial alignment stripe or illustration. A successful illustrated fixture alone cannot establish ordinary article capture usability.

Full prior regression/model/installed/default-resource gates are still required before a replacement installer is accepted. No current native pass, general memory stability, full PixPin parity or physical-device validation is claimed by this source checkpoint.

The current requested order is live scrolling usability, action chains/scripts, video recording region movement, and evidenced memory reductions alongside those paths. Cloud configuration synchronization is no longer requested.

## Native verification boundary

The first focused build 217 stopped on an explicitly typed numeric-literal correction in a new test; it produced no runtime evidence. The next native demonstration uses the same production session callbacks for both controlled injected input and, separately, actual ScreenCaptureKit input from an owned helper application. The real-stream result must state permission preflight, received/consumed buffers, output comparison and cleanup. Missing permission is reported as blocked and never treated as a passed screen-capture test. No OS permission is requested by these verification phases.
