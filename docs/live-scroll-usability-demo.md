# Native live-scroll usability demo

Entry: `LiveScrollUsabilityDemoFixture.verify(evidenceDirectory:)` from the installed application smoke route. The current route uses the actual `LiveScrollSessionController`: its acquisition loop, matching/assembly, compact controls, status, Pause/Resume and Finish callback run unchanged. The fixture supplies original owned-window pixels, continuous native wheel input and read-only observations. It does not implement another session sampling loop.

The first native viewport PNG is saved before source setup or later assertions. All content is an original numbered document or PicShot controls. The fixture never requests or grants OS permissions, posts global input, uses the network, reads personal content or opens unrelated applications.

## Owned-source product sessions

A borderless AppKit window contains a 640 × 480 viewport, a 36-pixel sticky heading and a real `NSScrollView`. An independent task delivers 450 pixel-wheel `NSEvent`s through the native scroll view over at least 15 seconds. It scrolls down, reverses over captured content, and extends beyond the previous frontier. The product session receives frames while input continues, without a settle detector.

The rich-document case uses numbered text, small illustrations and distinct row accents. The independent output check renders a fresh numbered document from its origin, reuses only the original header, and compares every text, illustration and row pixel plus exact output height. Both rasters are normalized to the same explicit sRGB premultiplied RGBA byte-order context, with copy blend and no interpolation. The reference's initial 480-pixel viewport must first reproduce the original capture, so a reference-rendering error cannot be mistaken for seam acceptance. The separate six-second, 180-event ordinary-text case removes illustrations, accent stripes and colored row fills. Its actual completed image is compared against a separately rendered native text document; dimensions, exact equality, mean channel error and changed-channel fraction are reported. The fixture preserves an ordinary-text failure rather than adding alignment texture to force success.

Pause, Resume and Finish use `PortableSettingsUIPreviewFixture.click`, the accepted native hit-test and owned mouse-event route. Pause must stop provider calls and preserve the accepted viewport. A deliberate non-overlapping jump must produce the product warning while preserving the actual thumbnail bytes and accepted document dimensions/offset; returning to known content must reconnect. Finish gets its image exclusively through the real session's completion callback. Light and dark controls, the shrinking viewport marker and growing preview are rendered from the actual native views.

The injected frame provider is paced at approximately 15 fps. If existing Screen Recording permission permits it, the owned-window provider can use `SCScreenshotManager`; otherwise it explicitly uses AppKit `cacheDisplay` pixels. This acquisition is reported as `ownedFrameAcquisitionMode` and is never treated as proof of production `SCStream` capture. Session cleanup is observed after bounded retirement. An unclosed session blocks the next case.

## Separate real-stream phase

After both owned-source scrolling sessions and the movement session confirm cleanup, `LiveScrollRealStreamFixture.run` records a distinct `realStream` result. A false `CGPreflightScreenCaptureAccess()` is explicitly blocked before starting a helper, stream or permission request. With existing permission, the phase launches a separate original AppKit target and uses production `LiveScrollScreenSource`, the normal product session, and the native Finish action. The separate process is necessary because real capture correctly excludes PicShot's own windows.

Top-level `realScreenCaptureClaimed` comes only from that real-stream result. `realScreenCaptureValidated` requires the real-stream phase to pass. Owned-window screenshots or rendered injection cannot set either claim. A failed real-stream attempt fails the overall demo. Blocked permission may retain separately passed owned-source sessions, with the exact blocker recorded; it does not claim real capture validation.

## Artifacts and checks

Main outputs include:

- `live-scroll-native-first-viewport.png`, saved before source setup
- `live-scroll-native-first-window.png`, actual compact controls and document
- `live-scroll-frame-*.png`, a bounded native UI frame sequence
- `live-scroll-interaction.gif` and `live-scroll-contact-sheet.png`
- `live-scroll-native-finished-window.png` and `live-scroll-native-dark-controls.png`
- `live-scroll-gap-recovery.png`
- `live-scroll-finished.png`, the image delivered by product Finish
- `live-scroll-product-session.json`, main case observations and cleanup result
- `live-scroll-plain-text-*`, the separate ordinary-text frames, completion image, reference image and product-session report
- `live-scroll-usability.json`, combined results and explicit acquisition boundaries
- `real-stream/live-scroll-real-stream.json` and any real-stream output/reference evidence when capture is permitted

Failure PNGs retain the actual native status and preview. Reports include first-pixel and first-preview latency, first growth latency, continuous duration/event count, observed and actual update counts, reversal and extension, detected header size, native button routing, pause and gap behavior, completed-image coverage, sampled-frame/provider counts and confirmed session closure. GIFs and contact sheets are composites of owned native window snapshots, not desktop recordings.

The original HUD-plus-assembler prototype is retained as `verifyAssemblerDemo` only to interpret earlier frozen evidence. It uses fixture-owned sampling and is not the current main route. Its older artifact names and acceptance boundary should not be applied to the product-session report.

This focused usability demo does not replace installation qualification, resource limits, Retina/multiple-display acceptance, general third-party-app acceptance, or a real human-input demonstration.

## Native movement case

`verifyMovement(evidenceDirectory:)` runs after the two owned-source scrolling sessions. Its forwarding method reuses the existing accepted native menu route with an explicit visible nonactivating-panel expectation; existing pin-menu calls keep their key-window requirement. Both modes retain exact owned button/window/current-event identity, the two-second menu deadline and forty-event limit. Read-only hooks expose the actual active Move view. No new menu harness is introduced. A failed movement case fails the overall demo, and unconfirmed cleanup blocks the later real-stream phase.

This case uses a header-free inner 640 × 480 crop of a taller owned native text viewport. It activates the actual Move menu item, sends a drag with both x/y deltas to the active `ManualScrollRegionMoveView`, verifies the running capture constrains the move to its scroll axis, and confirms with Return through the actual key window. A weak source reference makes the frame provider crop its current region, so moving the capture changes source pixels and the matching offset. The source retains the original owned target identity. After more native scrolling, actual product Finish is compared with an independent native reference for the exact original document range. This tests moving within ordinary content; moving a crop across a sticky-header boundary is explicitly outside this case.
