# Native live-scroll usability demo

Entry: `LiveScrollUsabilityDemoFixture.verify(evidenceDirectory:)` from the installed app smoke route. This fixture adds no global input monitor, never requests or grants Screen Recording permission, does not use the network, and never opens other apps or reads personal content.

The owned borderless AppKit window contains a 640 × 480 native viewport: a 36-pixel sticky heading and a real `NSScrollView` displaying numbered text and small abstract illustrations. A separate task delivers 450 pixel-wheel `NSEvent`s through the scroll view's native `scrollWheel(with:)` implementation over at least 15 seconds. It scrolls down, reverses over existing content, then extends beyond the previous frontier. Capture and matching run while that input task continues; there is no settle detector.

The actual `LiveScrollCaptureController` presents its compact HUD, growing thumbnail, and viewport marker beside the document. The demo clicks its Finish action, renders light and dark controls, introduces a non-overlapping jump, checks the last valid output is byte-identical, and returns to known content before extending again.

`CGPreflightScreenCaptureAccess()` decides the evidence mode. Existing permission enables ScreenCaptureKit's owned-window screenshot path. Without existing permission (or if setup fails), the fixture explicitly reports `injected-rendered-owned-window`: real AppKit `cacheDisplay` viewport pixels are fed to the same assembler. That validates native scrolling, preview updates, and stitching but is not a claim of live desktop capture, TCC acceptance, or third-party-app acceptance. The contact sheet and animation are composites of native owned window snapshots in either mode.

Artifacts, all synthetic owned content:

- `live-scroll-native-first-window.png` and first viewport, saved before long-running assertions
- `live-scroll-frame-*.png`, at most 36 intermediate native UI frames
- `live-scroll-interaction.gif` and `live-scroll-contact-sheet.png`
- `live-scroll-native-finished-window.png`, `live-scroll-native-dark-controls.png`
- `live-scroll-gap-recovery.png`, `live-scroll-last-good-before-gap.png`
- `live-scroll-finished.png`, the assembler's actual finished raster
- `live-scroll-usability.json`, bounded event/matching trace and capture-mode disclosure

Coverage independently checks every output scanline against each numbered row's distinct native accent, plus the exact expected height. The header must be detected as 36 pixels. The report records first native-pixel and first-preview latency, first growth latency from input start, preview/growth counts, matching that overlapped further input, accepted reversal observations, gap preservation and recovery, and start/end viewport marker presence.

The current fixture drives the real HUD and assembler with fixture-owned acquisition/input tasks. It does not exercise `LiveScrollSessionController` acquisition, pause, auto-scroll or finish routing; clicking the actual HUD verifies its injected action callback only.

This is a focused usability demo. It does not replace algorithm acceptance, resource qualification, installation, Retina/multiple-display validation, or a real user-input demonstration in another app.

A separate six-second ordinary-text pass removes illustrations, accent stripes, and colored row fills. It continuously dispatches another 180 wheel events under the same sticky heading. Its start/end/final/reference PNGs and `live-scroll-plain-text.json` report are preserved independently. The final image is compared with a separately rendered native text document, recording exact equality, dimensions, mean channel error, and changed-channel fraction. A text-case failure remains a failure and changes the top-level status to partial; the fixture does not add texture to make that case pass.
