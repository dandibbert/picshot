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

`verifyMovement(evidenceDirectory:)` runs after the two owned-source scrolling sessions. It exercises the persistent handle through owned `NSWindow.sendEvent` mouse events after a real hit-test. The handle temporarily becomes key for Escape; no global input monitor or fullscreen movement overlay is involved. The original menu/Return mover remains available as a fallback and retains its separate native tests. A failed movement case fails the overall demo, and unconfirmed cleanup blocks the later real-stream phase.

This case uses a header-free inner 640 × 480 crop of a taller owned native text viewport. A drag with both x/y deltas proposes a32-point movement along the active capture axis, then mouse release supplies the final48-point position. During the gesture, the HUD, outline, handle and last accepted preview remain visible in light and dark native scenes. The source region remains unchanged until pause/drain succeeds and release commits it. The position marker stays amber and its accessibility description says the current position is unverified. Acquisition pauses during the movement; this case does not claim an uninterrupted stream.

A weak source reference makes the provider crop its current region, so applying the48-point move must change source pixels and the matching offset while preserving the original owned target identity. A second drag followed by native Escape and a trailing mouse-up must retain the accepted source region, output height, offset and preview pixels, then resume matching. After more native scrolling, actual product Finish is compared with an independent native reference for the exact original document range. This tests moving within ordinary content; moving a crop across a sticky-header boundary remains outside this case.

The illustrated session separately requires a non-overlapping gap to preserve accepted pixels but turn the position marker amber with an unverified accessibility label, then return to green only after a verified recovery. These authored candidate checks require actual macOS execution before any pass claim. They do not resolve the retained227 memory failures or validate real ScreenCaptureKit acquisition when permission is unavailable.

## Stationary preview and rejected-move recovery witnesses

The illustrated case now induces one preview-generation failure after one additional native 48-pixel wheel event. It records the actual retained thumbnail, amber unverified marker and Auto-off controls in both appearances, then leaves the source document stationary. Only the next owned acquisition is paced for at most two seconds to preserve the visible failure for capture; the production sampling and duplicate-recovery path perform the retry. Recovery must restore the green marker at the accepted viewport without another wheel event, accepted observation, source strip or spool write, and without starting Auto. The existing final Finish/reference comparison covers the extra accepted viewport independently. The four new `live-scroll-preview-{failed,recovered}-{light,dark}.png` files preserve the native failure and recovery pixels.

The existing movement case also sends one rejected proposal through its owned native handle mouse-down/drag/up route. A verification-only wrapper strongly owns the existing frame source and delegates its frame identities, target, bounds, watermark, sampling, movement and lifetime; only the explicitly armed proposal throws. After the production session resumes the original source, actual controls must show Pause while the error status remains visible. Light/dark images precede a native Pause click, which must drain the source, stop provider calls and preserve accepted height, offset, observations and thumbnail pixels. Native Resume must reconnect before the existing further scroll and independent Finish/reference comparison. The four `movement/live-scroll-rejected-move-{active,paused}-{light,dark}.png` files preserve both states. The wrapper's next owned raster is paced for at most two seconds to observe this transient error and remains cancellable through normal source drain.

The existing experimental checker requires every recovery observation, both appearance pairs and their file hashes, and rejects changed accepted coordinates/counts, automatic restart, Retry on an active source, missing drain or missing image files. Portable mutations are contract checks only. These authored extensions need native macOS execution before they provide pixel or interaction evidence; they do not change deadlines, retained baseline cases, memory qualification or the real-ScreenCaptureKit limits above.

### Build264 compilation failure retained

Source `c9ebc527ff19513188219f6907d3a68b3c677255`, [run38345791739](https://github.com/dandibbert/picshot/actions/runs/38345791739), failed during release compilation after 203.688 seconds, with normal exit code 1 rather than a timeout. The added preview witness redeclared `recoveredLabel` in the same scope as the existing gap-recovery witness (`LiveScrollUsabilityDemoFixture.swift:367`). Native demonstrations and the 163-method focused suite did not run; there is no new installer or interaction acceptance. Retained artifact11789400447 is 29,085 bytes, SHA-256 `ab410dcb5193266a55ac4a9b36aa9af98c62aca8120cda96331925b85a9f3706`.

The correction renames only the added local declaration and its accessibility observation to `recoveredPreviewLabel`. Existing gap checks, product behavior, output comparisons, exact native inventory, deadlines and resource classification remain unchanged. The same focused native gate must run before any further qualification claim.
