# Large input and native UI decode experiment proposal

Design baseline, 2026-10-07. A separate [opt-in v2 implementation](ImageDecodeLargeDiagnostic.md) is now prepared for native verification after the accepted 0.10 pin milestone. It changes no production preview default; native compilation and experiment results remain pending. The [696b small-input result](ImageDecodeHelper696.md) removed a parent volatile-buffer slope while adding approximately 0.27 / 0.57 seconds median full latency on ARM64 / Intel; it did not establish a production remedy.

## Fixed large-input comparison

Start with four fresh parent cells per architecture: two fixed source profiles, each comparing the unchanged production PNG preview plus actual draw against a disposable-child preview plus owned-RGBA parent draw. Use **2 warmups +12 measured cycles** per cell.

| Profile | Source pixels | Logical example at 2× | Expected bounded preview |
|---|---:|---:|---:|
| 4K | 3840×2160 | 1920×1080 points | 1024×576 RGBA, 2.25 MiB |
| 5K | 5120×2880 | 2560×1440 points | 1024×576 RGBA, 2.25 MiB |

These are input-pixel profiles, not evidence of an actual 2× display. Both remain below the separate codec helper's 16-million-pixel source cap; they do not exercise the general image export service's much larger source limit.

Prepare each synthetic PNG and canonical production-preview reference in its own bounded process. Use one deterministic structured alpha/edge/text-like pattern per size, disclose encoded size and pattern scope, and retain the **8 MiB encoded diagnostic cap**. Reject an oversized fixture rather than silently increasing it. Create one source at a time; bound preparation to 60 seconds cooperative /70 seconds outer and a 512 MiB sampled RSS/footprint watchdog. Report its own peak; full-source buffers are excluded from repeated decode measurements but never presented as costless.

For these larger sources, the child must use **the production thumbnail operation and options**, including maximum pixel dimension, transform handling and immediate caching, before actual raster drawing. Do not expand the 768×576 full-image no-cache path to full-resolution RGBA. Keep the existing **1024-pixel maximum dimension and 4 MiB preview ceiling**; report source and returned dimensions/stride separately and admit only exact predefined profiles. Apple's [thumbnail limit is expressed in pixels](https://developer.apple.com/documentation/imageio/kcgimagesourcethumbnailmaxpixelsize). The fixed raw transport for these two profiles is 2,359,296 bytes, not the old 1,769,472-byte layout.

Use a separate versioned diagnostic profile/contract so the 696b fixture remains comparable. Check complete PNG framing/type/count/depth/orientation before decode, exact reference pixels after child rasterization, exact parent-drawn pixels, provider callbacks, child exit and owned cleanup. Never send reference RGBA to the child. Retain per-launch signed bundle-relative validation, one-child admission and no next job before exit plus cleanup. Preserve the five/six/nine-second child work/backstop/exit bounds, 256 MiB sampled child watchdog, and 180/200-second parent arm bounds. Add a 512 MiB sampled parent RSS/footprint watchdog for this large-input diagnostic, explicitly separate from unchanged production gates; sampled watchdogs are not instantaneous quotas. If a profile exceeds a bound, report that result; do not auto-retry with looser limits. Keep bounded metadata/log caps and test the revised deterministic maximum.

## Latency attribution before optimization

Add timestamps around the existing work without changing its checks or ordering:

- Signature path/inode checks, app code-object creation/strict validation, and helper code-object creation/strict validation, separately on **every launch**
- Process.run entry/return, child entry before diagnostic initialization, PNG read/hash, image creation, actual draw/readback, raw write/sync, last response write and observed process exit
- Parent first/last response receipt, raw read/hash/copy, actual draw, pool exit and cleanup
- Cancellation request, child cancellation observation, UI acknowledgement, child exit, cleanup and admission release

Use monotonic timestamps and report residual intervals explicitly. Child work overlaps the parent launch interval; do not add both as independent costs. Preserve per-cycle observations and report median/max with sample counts. Warmups remain visible; no filesystem cache flush or signature-cache manipulation is introduced.

**No validation optimization is proposed in this phase.** The same per-launch bundle/helper validity calls, flags, path restrictions and executable identity checks stay in place. Any later caching, verifier reuse or helper reuse needs a separately reviewed identity/invalidation design and tests for replacement, modification, symlink/hardlink substitution and cancellation. A fast stale verdict is unacceptable. Apple's [validity documentation](https://developer.apple.com/documentation/security/secstaticcodecheckvalidity(_:_:_:)) explicitly conditions the verdict on the code remaining unmodified.

## Bounded native-window comparison

Only after both large-input correctness routes pass, run two fresh native-window cells per architecture on the 5K profile, one per route. Use the actual ImageExportController scheduling/generation/cancel behavior and ImageExportPreviewView drawing through the existing encoder-injection seam, with a diagnostic adapter returning the separately prepared PNG and its independently decoded preview. This isolates preview delivery/display; it does **not** represent complete export encoding or saving. Record initial full-source/snapshot construction separately, including any main-thread pause it causes.

Per route, allow **2 warmups +4 completed measured previews**, then a fixed short sequence covering a three-change debounce burst, Cancel during active work, window close while a decoded result is held, and cancellation after child exit but before UI publication. Cap the whole cell at **16 request generations, one active child, 120 seconds cooperative and 140 seconds outer**. Run fault scenarios in fresh controllers, one visible at a time, separately from the four-preview retention/latency series. Use explicit, brief diagnostic barriers for race placement, label their delay separately, and never use huge inputs or pressure to force timing. For the isolated route, include cancellation requested while signature validation is running; acknowledge that the synchronous validation call itself is not made interruptible.

The existing cancellation token must reach the diagnostic supervisor; closing the window alone is insufficient. Require no stale image/result/save-enable after cancellation or close, a final preview belonging to the latest generation after the burst, confirmed child exit/cleanup before admission reopens, and bounded controller/provider lifetime. Keep request-to-UI acknowledgement separate from request-to-cleanup latency. No save picker, output publication or user screen capture is needed.

Measure actual native display rather than only assigning an image: observe completion of the preview view's normal AppKit draw with value-only diagnostics, verify the source-preview pixels exactly, and capture a small number of native-view evidence images outside the repeated memory interval. A nil-by-default draw observer, if required, needs explicit review; no swizzling or direct offscreen draw presented as on-screen proof. Do not take a new screenshot/raster every measured cycle and accidentally attribute its allocations to preview delivery.

Use a background-scheduled main-queue acknowledgement probe with at most one outstanding callback and bounded counters/histograms. Record queue delay, coalesced/missed ticks, actual native control-action handling, ready-to-draw delay and cancellation latency. A proposed diagnostic responsiveness flag is any acknowledgement/control delay above 100 ms; report baseline and maximum delays rather than treating this provisional flag as an existing product gate. Programmatic native actions are not physical-input latency or monitor scanout measurements.

Record the window's actual backing scale, logical bounds and backing-pixel conversion. Apple's [high-resolution guidance](https://developer.apple.com/library/archive/documentation/GraphicsAnimation/Conceptual/HighResolutionOSX/APIs/APIs.html) favors backing-coordinate conversion and warns that scale alone is not physical display density. If the runner only supplies 1× backing, label that limitation; do not fake 2× by changing NSImage size or OS display settings. A genuine 2× AppKit run remains a separate required observation before a high-DPI UI claim.

## Stop and interpretation rules

Stop on pixel mismatch, unexpected executable identity, malformed protocol, unconfirmed child exit/cleanup, retained admission, invalid preview bounds or a deadline. Preserve evidence immediately and keep the pin-release pipeline independent. There is no default CI hook or installer solely for observations.

Parent and child peaks, overlapping-process receipt pairs and independent-maxima envelopes remain separately labeled; neither process exit nor zero volatile growth proves system RAM reclamation. Continue to state **parentLossVerified=false**: early parent death or hard exit can strand owned jobs, and no orphan reaper has been demonstrated. These proposed cells do not close that gap. A result can support further diagnostic work only; production adoption still needs the unresolved lifecycle, real UI, large-input, latency and long-run evidence.
