# Opt in large PNG and native preview diagnostic

Prepared diagnostic only. Native compilation and execution of this v2 route are pending. The [completed 696b comparison](ImageDecodeHelper696.md) demonstrated small-input process isolation with substantial latency; it did not establish a production memory remedy. V1's 768×576 route and the normal WebP/AVIF protocol remain available with their existing defaults.

## Run and fixed scope

After applying the documented owner entry hooks and building the existing signed app/helper:

```sh
scripts/image-decode-large-attribution.sh --compare /absolute/PicShot.app /absolute/new-evidence-directory
```

The standalone runner prepares one immutable synthetic PNG/reference per profile, then runs four fresh parent cells: `4k` and `5k`, each with `production-control` and `isolated-decode`. Each cell performs 2 warmups +12 actual draw/exact-pixel cycles. Only after all four validate does it run `native-ui-control` and `native-ui-isolated` on the 5K input, each in another fresh parent.

Source dimensions are fixed at **3840×2160** or **5120×2880**. Both return a **1024×576 premultiplied sRGB RGBA preview, 2,359,296 bytes**. The child uses the production thumbnail options, including maximum dimension 1024, transform handling and immediate caching; it does not expand the old no-cache full-image decoder to full-resolution RGBA. Complete PNG admission, actual child rasterization, byte/hash verification and exact parent pixel comparison remain required. Reference pixels never enter the child job.

Parent selectors are `PICSHOT_IMAGE_DECODE_LARGE_MODE`, `PICSHOT_IMAGE_DECODE_LARGE_PROFILE`, and `PICSHOT_IMAGE_DECODE_LARGE_INPUT_DIRECTORY`; mode `prepare` omits the input directory. The separate helper entry is `--image-draw-decode-diagnostic-v2`, with contract `image-decode-helper-v2`. Arbitrary dimensions, counts, executables and mixed diagnostic selectors are rejected.

## Native UI observations

The UI route uses the real ImageExportController encoder-injection seam, cancellation/generation logic, native controls, and ImageExportPreviewView. Its diagnostic adapter consumes prepared PNG and returns the independently decoded preview; complete image encoding and saving are excluded. Full-source construction and each controller's snapshot/interface construction are separately timed and sampled.

Each native window cell completes 2 warmups +4 measured previews. A batch of three real native control callbacks exercises the existing debounce before its tasks can run. Three additional scenarios cover active Cancel, window close at post-decode readiness, and a real completed result held briefly until after cancellation to test stale-result suppression. At most four controllers are constructed, one visible at a time, with a maximum 16 worker records. Native draw completion is observed through a nil-default value-only callback that clears on window detachment; it retains no image or controller. A single evidence PNG is captured after the repeated memory interval.

A background timer allows at most one outstanding main-queue acknowledgement. Counts, a fixed histogram, maximum delay and real native action times are recorded. Delays above 100 ms set a diagnostic responsiveness flag; this is an observation, not a new production acceptance threshold. Physical user input and monitor scanout are not measured.

If a verifier finishes before Cancel arrives, the signature race is marked unobserved rather than called a cancellation pass. Inspect `allRequestedCancellationRacesObserved` before claiming that coverage. `highDPIBackingObserved` reports actual window backing/conversion evidence; a 5K input does not turn a 1× runner into a Retina display test. Neither flag is silently upgraded by the checker.

## Validation and lifetime

Every child launch still resolves the same signed bundle-relative executable and performs the unchanged path/identity, app-signature and helper-signature checks. A nil-default timing observer records their five phases with actual Security status codes. It adds no cache, fast path, helper reuse, relaxed flag or alternate executable. The existing shared one-child admission lease remains held until exit and owned private cleanup are confirmed.

V2 records parent boundaries after staging, launch return, child exit, raw read and cleanup, plus child helper-entry, PNG read/hash and response-prepared times. Child entry is not labeled process start. Full lifecycle includes validation, staging, process lifetime, transport, actual parent drawing, pool exit and cleanup. UI request-to-draw additionally includes the controller's existing debounce and publication scheduling. Separate process peaks/receipt pairs remain non-atomic; shared pages, file cache, WindowServer and GPU prevent a unique-total-RAM claim.

`parentLossVerified=false` remains explicit. Early parent death or a hard-backstop exit without a live parent can strand a job; no orphan reaper is proven. Ordinary fixture errors cancel controllers, release held results and allow bounded worker-queue cleanup, but do not infer cleanup if it remains unconfirmed.

## Bounds and evidence

Encoded PNG is capped at 8 MiB; decoded preview remains below the existing 4 MiB ceiling. Private request/event/stdout/stderr limits remain 4/16/128/8 KiB. Diagnostic JSON remains capped at 2 MiB; the maximum scalar-width UI shape has a portable rehearsal of approximately 1.44 MiB and a native XCTest assertion. No per-cycle image or decoded-Data arrays are stored.

Child work/backstop/exit-confirmation bounds remain 5/6/9 seconds, with the existing 256 MiB sampled child watchdog. Preparation uses 60/70-second cooperative/outer bounds; repeated cells use 180/200 seconds; UI cells use 120/140 seconds. The large diagnostic samples parent RSS/footprint against 512 MiB, and the launcher separately polls its owned parent's RSS. These sampled watchdogs are not instantaneous quotas or changes to production resource gates. The launcher caps logs and never infers child cleanup from parent termination.

Named reports are `image-decode-large-<mode>.json`; `headless-comparison.json` gates entry into UI observations, and `comparison.json` summarizes all six cells. Keep raw reports for exact boundaries, signature statuses, cancellation coverage and ownership counts. The runner is opt-in and needs no installer, model download, screen-capture permission, pressure operation or OS setting change.
