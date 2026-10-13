# One matched Save PNG preparation comparison

Status: diagnostic candidate, not a changed production default or a memory qualification. The accepted experimental package remains build263; stable build214 remains separate.

## Source-backed scope

Fresh-image Save uses the ordinary PNG export encoder, which also creates a thumbnail. Save displays its textual outcome and file path, not that thumbnail. The candidate adds an immutable encoded payload and invokes the existing native PNG encoder with `includePreview:false`. The encoder, PNG options, metadata validation, cancellation checks, encoded-byte limit, queue and atomic publication writer remain shared. Ordinary Export still requires its real preview. Supplied JPEG/TIFF/PDF/WebP/AVIF artifacts retain their existing bytes, metadata and admission accounting.

The production default remains `legacyPreview`. The matched control retains its genuine `ImageExportArtifact`, including `firstPreview`, through the existing prepared-value lifetime and collision/retry flow. Converting the control immediately into a payload would invalidate the comparison. The init-only preparation callback records scalar observations and is nil in ordinary use.

## Frozen workload and interpretation

Run one ARM pair from the same signed application: control first, candidate second, each in a fresh process. Each creates the same generated 3840 × 2160 source for two warmup and eight measured Saves. Both use real visible Save controllers, identical snapshot, queue, writer, output directory policy, ordinary completion button, bounded native drain and settling. Each source includes opaque, semitransparent and transparent pixels. No personal screenshots or capture contents are inputs.

Record absolute entry, setup, source creation, source hash, controller creation, PNG preparation, saved, closed, settled, warmup baseline, final and late observations. Report RSS, physical footprint and volatile backing separately. Per-cycle and whole-run sampling uses the existing 50 ms sampler; cumulative kernel RSS/footprint peaks are retained. Volatile accounting overlaps resident memory and is not added to RSS. Source generation, hashing, AppKit startup and scalar receipt I/O remain visible costs. Weak owner release does not establish backing reclamation.

Measurement has a 300-second cooperative deadline, 360-second owned launcher deadline and 420-second outer process bound. Native owner drainage remains four seconds. The existing five-minute product Save timeout and all image/resource limits are unchanged. A separate validator has 180/240/300-second cooperative/launcher/outer bounds.

All twenty outputs are retained. Only after both measured producers have exited does a third process regenerate the reference, independently decode every PNG and compare complete canonical pixels/alpha, dimensions, options, metadata and exact encoded bytes. Validation still runs after an unsuccessful measurement when producer exit is confirmed; an unconfirmed surviving owner prevents later cells. Before/after bundle manifests, executable hashes and strict signatures bind the processes to the same application.

Complete evidence is distinct from a useful result. The report provides candidate-minus-control differences without a new numeric memory pass threshold. Review preparation cost, per-cycle sampled peaks, cold/warm/late/final residency, footprint and latency together. An isolated final-counter decrease, conflicting metrics or a negligible difference is inconclusive. Do not repeat an unchanged pair to obtain a favorable result. A production change requires meaningful relevant benefit, exact output and cancellation/collision/retry correctness, followed by actual package qualification.

This single ordered pair does not establish statistical significance, long-run stability, whole-application improvement, a cause for build227's retained memory failure, or real ScreenCaptureKit behavior. No build227 memory cell is rerun and no failed threshold is changed.

## Preserved scrolling recovery evidence

Build264 failed release compilation on a duplicate local witness name; its native stages did not run. The name-only correction in source `6ff42dd88f544ce27cd9dc745f7c56a73a2223e7`, [build265](https://github.com/dandibbert/picshot/actions/runs/38346597072), completed all 163 focused native methods once, with no skips or failures. XCTest took 164.493 seconds; the bounded command exited normally after 170.818 seconds. All four final outputs match reference pixels and all eight new light/dark recovery images were independently decoded and visually reviewed. The one stationary preview recovery preserves accepted content and does not start Auto; failed movement recovery leaves the active Pause action truthful. The full 2382-method source inventory and distribution were not executed in that focused run. Actual desktop acquisition remains unverified.
