# Bounded signed helper decoding diagnostic plan

Design proposal, 2026-10-07. An opt-in [diagnostic prototype](ImageDecodeHelperDiagnostic.md) is now authored; **native compilation and execution remain pending**. The [completed ARM64 and Intel draw comparison](ImageRasterMaterialization59.md) makes an end-to-end process-isolation control useful: ImageIO drawing accumulated volatile backing in the long-lived app, whereas drawing already-decoded owned RGBA did not. The question is whether moving actual PNG decoding into one short-lived signed child per cycle avoids parent accumulation at an acceptable, explicitly measured process and transport cost.

## Smallest initial matrix

Reuse a separate preparation process to create the immutable 768×576 PNG and canonical premultiplied RGBA reference. Use four fresh parent processes:

1. **Production control:** unchanged production PNG preview followed by actual drawing, 2 warmups +12 measured cycles
2. **Isolated decode:** one new signed bundle helper per cycle actually decodes/draws the PNG, writes bounded raw RGBA, and exits; the parent verifies the returned bytes and actually draws an owned-provider image, 2 +12 cycles
3. **Cancellation control:** one child performs actual decoding/drawing, then reaches an explicit diagnostic hold before output publication; the parent cancels it and verifies exit, no accepted output, cleanup and admission release
4. **Deadline control:** the same one-shot bounded hold reaches the fixed deadline; record termination actions, confirmed exit, cleanup and admission state

The two fault controls are separately labeled lifecycle checks, not extra measured cycles. The existing raw-only arm supplies the initial rendering control; do not expand into another format or dimension matrix yet.

## Entry points and compatibility

Proposed parent selectors are `PICSHOT_IMAGE_DRAW_HELPER_MODE` and `PICSHOT_IMAGE_DRAW_HELPER_INPUT_DIRECTORY`, with modes `production-control`, `isolated-decode`, `cancel-after-decode`, and `timeout-after-decode`. Reject mixed diagnostic selectors and bounds overrides. A standalone opt-in runner prepares inputs and launches these cells; it is not added to default release CI.

The existing `Contents/Helpers/PicShotCodecHelper` is a suitable executable: its target already uses ImageIO/CoreGraphics, bounded file I/O, and a disposable-process lifecycle. Add one explicit diagnostic entry argument, `--image-draw-decode-diagnostic-v1`, dispatched to a separate implementation. Leave the existing no-argument WebP/AVIF protocol, response ceilings, export limits and production service unchanged. Resolve and validate only the app's signed bundle-relative helper through `CodecHelperExecutable.verified()`; no environment-supplied executable or shell command.

New diagnostic contract/file types belong in PicShotCodecCore, the decode implementation in PicShotCodecHelper, and the supervisor/fixture in PicShot. Only the helper entry dispatch and attribution-fixture routing need existing-source hooks. Existing `ImageDrawDestination` and the owned-provider constructor can be reused without changing preview defaults. Add focused parser/file/lifecycle tests and a standalone launcher.

## Decode and transport contract

- The child receives **only the PNG**, never the reference RGBA. Validate its SHA256, byte count, PNG type, image count, 768×576 dimensions, 8-bit depth and orientation 1 before image creation
- Use the tested full-image no-cache options, then **actually draw** into an owned 1,769,472-byte destination. Output exactly packed 8-bit premultiplied-last, byte-order-32-big, sRGB RGBA. Record creation and draw/readback separately
- Do not reuse `CodecRaster` unchanged: it normalizes premultiplied pixels to straight alpha. That would introduce another conversion and compromise the exact-layout comparison
- Use a private, identity-checked diagnostic job directory with fixed allowlisted names such as `input.png` and `decoded.rgba`, restrictive modes, no symlinks/hard links, exclusive output creation, and bounded reads/writes. Use a distinct diagnostic prefix/cleanup contract; do not extend the production codec temporary-file allowlist casually
- Keep raw pixels out of JSON/stdout. A versioned bounded control protocol carries input identity, status, timings, memory samples and raw output SHA256. Drain bounded stderr/stdout concurrently and keep cancellation/parent-loss detection active during native work
- **Confirm child exit before reading the raw output into the parent.** Verify exact size, layout, identity and digest. The simplest first version reads bounded Data, then uses the already-tested owned-provider copy. Account for both buffers and their latency; a later zero-copy optimization is a different experiment
- Compare child output and actual parent-drawn bytes exactly with the separate reference; report the actual maximum channel difference on failure. Retain one destination per parent process and no per-cycle image/decoded-Data arrays

Apple documents [decoded caching](https://developer.apple.com/documentation/imageio/kcgimagesourceshouldcache) and [provider release callbacks](https://developer.apple.com/documentation/coregraphics/cgdataproviderreleasedatacallback). Callback completion ends Core Graphics' need for the supplied bytes; it does not measure physical-memory reclamation. Actual child draw/readback prevents lazy decoding from escaping the measured route.

## Bounds and lifecycle

Proposed fixed limits: 8 MiB PNG, exactly 1,769,472 raw bytes, 4 KiB request, 16 KiB event, 128 KiB total stdout, 8 KiB stderr, and a 2 MiB parent diagnostic report. Verify deterministic maximal report encoding in tests; none of these relaxes production protocol/resource gates.

Use a five-second per-child work deadline, an independent six-second child hard backstop, and bounded parent cancellation/termination/kill handling with exit confirmation by nine seconds from launch. Give the measured parent arm a 180-second cooperative and 200-second external deadline. Check deadlines throughout staging, reads and cleanup as well as the child wait. A sampled child RSS/footprint watchdog remains a watchdog, never an instantaneous allocation guarantee.

Acquire the existing shared native-export admission lease for each job. Admit at most one diagnostic child, and retain admission until confirmed exit **and** private-job cleanup. An unconfirmed exit fails the cell, retains admission and stops further cycles; do not delete a directory while its child may still write. Parent loss must trigger bounded child exit and owned-file cleanup. Fault controls use explicit diagnostic holds, not giant inputs, allocation pressure or timing races.

## Measurement and interpretation

Parent boundaries: before staging, after staging, while the child is live, after confirmed exit, after bounded raw read/hash, before/after actual draw and readback, after pool exit, after cleanup and settled. Also record destination/provider callbacks and final destination close.

Child boundaries: before PNG read, after metadata/image creation, after actual raster draw/readback while objects are live, after source/context/pool release, after output close, and before exit. Collect periodic constant-space RSS/footprint maxima and exact self `TASK_VM_INFO` plus `TASK_VM_INFO_PURGEABLE` boundary fields with status/count checks. The existing helper's RSS/footprint-only response is insufficient for volatile attribution.

Record parent and child peaks separately, with sample counts, timestamps and any permitted parent polling of its owned child's RSS. Report maximum observed child concurrency. Sums of independent sampled maxima may be shown only as a **sampled envelope**, not a simultaneous peak, hard upper bound, or unique physical RAM measurement. Shared pages, kernel file cache and unobserved instantaneous peaks remain outside that conclusion. Never fabricate a zero-byte child sample after process exit.

Start full-lifecycle timing before signature validation/input staging; stop after child exit, pipe drainage/protocol validation, raw read/hash/copy, actual parent drawing/pixel validation, pool exit and owned-file cleanup. Report time to validated pixels separately. Include subprocess startup, child decode, raw write, IPC/read/copy and cleanup subphases; label deliberate settle waits separately. Give the production control the same full-lifecycle timing boundary, because the earlier draw timing stopped inside its image operation before pool cleanup.

The desired evidence is exact pixels, confirmed sequential child exits/cleanup, complete child and parent accounting, and a parent late-cycle trend without the previous volatile slope. Even if observed, that establishes a bounded isolation candidate only. Lower parent retention can coexist with higher concurrent peak, file-cache use, launch latency or CPU cost. Large-image preview limits, AppKit display, cancellation under real UI workloads and end-to-end export behavior require later validation before any production recommendation.

## Prototype limits found in review

The first authored prototype does not yet satisfy two parts of this plan: abrupt parent-loss/orphan cleanup is unverified and can strand a private job if the parent dies before startup or before a hard-backstop exit; and separate parent memory boundaries after staging, exit and raw read/cleanup are absent. Its four-cell comparison covers normal sequential decoding and cooperative post-decode cancellation/deadline with a live parent. Aggregate retention and full-lifecycle timing can be measured, but neither blanket parent-loss cleanup nor per-transport-phase memory attribution may be claimed.
