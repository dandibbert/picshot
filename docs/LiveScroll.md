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

## Automatic scrolling admission candidate after build234

Build234 was delivered as a separate opt-in ARM experimental ZIP after current-source native, model and installed-package checks. Stable214 remains separate. The failed227 warm/late scrolling RSS gates and unverified real ScreenCaptureKit acquisition remain unresolved; the delivered interactions do not establish full PixPin parity or overall memory stability.

The next narrow correction gates automatic input on a verified first/current viewport. Exactly one scroll input may be outstanding. Nil frames, duplicate pixels and frames already accepted by the producer before the post-input fence cannot release another input. A later matched forward change must advance both the event's original viewport and the immediately preceding accepted viewport. Partial forward movement is valid; reverse movement or a failed seam stops automation while preserving manual capture and the last good output.

The existing0.35-second minimum between inputs is unchanged. A3-second no-progress threshold is checked by the serial sampling loop, including idle returns; a pending read or assembly can delay the visible stop message. The UI says only that verified movement was not observed, since this cannot distinguish page end, slow rendering or intercepted input. The stop explanation survives duplicate frames. Pause, movement, Finish, Cancel, permission loss and capture limits do not silently rearm Auto. The producer fence bounds already-queued callbacks; it is not a claim of real SCK presentation-time causality.

Native verification will use the production session with intercepted input into an owned numbered AppKit scrolling document, plus deterministic source/clock regression cases. It neither posts global events nor requests Accessibility/Screen Recording permission. Current native results for this candidate are pending. No unchanged disputed memory cell is rerun.

### Focused build235 result and next qualification

Source `4af5ff3e8903058a701c4a6c8f9d26bd2399ba34`, run `38246728904`, completed the focused ARM native path. All131 distinct LiveScroll tests passed with no skips, missing IDs or bounded-runner cleanup failures. This includes15 automatic-session regressions and3 producer-watermark tests; the original2047-test baseline remains unchanged within the2178-method full inventory. Test execution took120.956seconds within the existing420-second cap.

The intercepted-input native Auto demonstration advanced nine67-pixel steps and one37-pixel tail, then issued one zero-motion endpoint input and stopped after3.055114seconds. Minimum input spacing was0.362378seconds. Native Stop/restart, later manual reverse/return and one Finish callback succeeded. Four independently decoded output/reference pairs were byte-identical: illustrated640×1896, plain-text640×1200, Auto640×1120 and moved-region640×1128. Session, owned window and launcher process cleanup completed.

The following qualification commit changes only this technical record and the workflow's descriptive comment. It reuses235's product and test bytes for the complete ordinary experimental package gates, including the stronger automatic-case receipt. It neither reruns the disputed227 scrolling-memory cell nor changes its failure classification. Full qualification and a new experimental installer remain pending;234 is still the delivered trial and214 the separate stable build. Real global event routing and ScreenCaptureKit acquisition are not established by the owned-window demonstration.

### Build 236 inventory-check correction

Run 38248890106 at source `ea8f5485023c073502d939ef56d56b72835d7d98` compiled the ARM application and native test bundle, then stopped in the portable planning regression. Its expected count still described the previous 2160-method/246-class inventory. The current source correctly adds 18 automatic-scroll methods, producing 2178 methods/247 classes. Actual Swift discovery, native execution and installed qualification did not run. The correction updates only five exact sentinel values: current method/class counts, the 131-method LiveScroll count and digest, full shard counts `[582,482,574,540]`, and 1646 focused methods. The preserved build 214 inventory of 2047 methods and its digest and original-shard inclusion checks remain unchanged. All 33 portable planning tests pass in normal and optimized Python locally.

Intel 236 stopped earlier at the unchanged 120-second Actions cap for the pin-evidence contract: both 15-test Python suites printed OK after 64.836 and 59.687 seconds respectively, but their combined duration exceeded the step cap. Later missing artifacts were consequential. No Intel native or package acceptance follows from this run. Neither limit is enlarged. The next ordinary qualification retains the exact build 235 product/native-test bytes, all resource limits and the explicit failed build 227 memory classification; it does not rerun the disputed resource cell.


## Build 237 experimental delivery and the next output transaction

Build 237 (`2f2171501663dc743c5ca0613dad432a3973daed`, run 38250436857) completed ARM functional and installed-package qualification. The exact native inventory contained 2,178 IDs: 2,175 ordinary full-suite passes plus three declared model prerequisites subsequently exercised in the 12/12 pinned-model stage; all 1,646 focused and 131 live-scroll cases passed. The installed ordinary-text, illustrated, automatic and movement outputs matched 3,420,160 reference pixels. Automatic input recorded 11 steps, minimum interval 0.372298 seconds and a 3.161019-second no-progress stop. These are owned-window acquisition and native-control observations, not physical ScreenCaptureKit/global-input validation.

The delivered experimental ZIP (20,376,143 bytes, SHA-256 `c4be9bafa865bfc7890af5de4dac89325e9e6e518ff8f26826e1b3030b7dc573`) uses lossless higher compression. All 70 entry contents, modes and metadata match the Mac-tested original archive; the recompressed container itself was not relaunched. Stable build 214 remains unchanged. The build 227 warm/late RSS failures are preserved and were not rerun. Installed default-workflow RSS was 71,303,168 bytes at entry, 443,711,488 at exit, sampled peak 712,048,640, post-warm growth 4,456,448. This does not establish overall memory stability.

The next bounded source change adds Quick Save PNG and Pin to the existing More menu and checks the live capture's clipboard recipient. Save reuses the existing bounded atomic output workflow and awaits actual publication; a dismissed dialog, failure or rejected pin/clipboard output retains the paused capture. Pin keeps the existing 32,000,000-pixel bound and preserves original dimensions. Only confirmed delivery becomes terminal. This source change requires fresh native action, cancellation, pixel and installed checks; the build 237 results do not qualify it.
