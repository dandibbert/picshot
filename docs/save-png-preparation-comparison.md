# One matched Save PNG preparation comparison

Status: the single build267 comparison is complete and independently audited. A narrow fresh-image Save default promotion is undergoing full experimental package qualification; it is not a memory qualification. The delivered experimental package remains build263 until that qualification and handoff complete; stable build214 remains separate.

## Source-backed scope

Fresh-image Save uses the ordinary PNG export encoder, which also creates a thumbnail. Save displays its textual outcome and file path, not that thumbnail. The candidate adds an immutable encoded payload and invokes the existing native PNG encoder with `includePreview:false`. The encoder, PNG options, metadata validation, cancellation checks, encoded-byte limit, queue and atomic publication writer remain shared. Ordinary Export still requires its real preview. Supplied JPEG/TIFF/PDF/WebP/AVIF artifacts retain their existing bytes, metadata and admission accounting.

The compared build267 production default was `legacyPreview`. The matched control retains its genuine `ImageExportArtifact`, including `firstPreview`, through the existing prepared-value lifetime and collision/retry flow. Converting the control immediately into a payload would invalidate the comparison. The init-only preparation callback records scalar observations and is nil in ordinary use.

## Frozen workload and interpretation

Run one ARM pair from the same signed application: control first, candidate second, each in a fresh process. Each creates the same generated 3840 × 2160 source for two warmup and eight measured Saves. Both use real visible Save controllers, identical snapshot, queue, writer, output directory policy, ordinary completion button, bounded native drain and settling. Each source includes opaque, semitransparent and transparent pixels. No personal screenshots or capture contents are inputs.

Record absolute entry, setup, source creation, source hash, controller creation, PNG preparation, saved, closed, settled, warmup baseline, final and late observations. Report RSS, physical footprint and volatile backing separately. Per-cycle and whole-run sampling uses the existing 50 ms sampler; cumulative kernel RSS/footprint peaks are retained. Volatile accounting overlaps resident memory and is not added to RSS. Source generation, hashing, AppKit startup and scalar receipt I/O remain visible costs. Weak owner release does not establish backing reclamation.

Measurement has a 300-second cooperative deadline, 360-second owned launcher deadline and 420-second outer process bound. Native owner drainage remains four seconds. The existing five-minute product Save timeout and all image/resource limits are unchanged. A separate validator has 180/240/300-second cooperative/launcher/outer bounds.

All twenty outputs are retained. Only after both measured producers have exited does a third process regenerate the reference, independently decode every PNG and compare complete canonical pixels/alpha, dimensions, options, metadata and exact encoded bytes. Validation still runs after an unsuccessful measurement when producer exit is confirmed; an unconfirmed surviving owner prevents later cells. Before/after bundle manifests, executable hashes and strict signatures bind the processes to the same application.

Complete evidence is distinct from a useful result. The report provides candidate-minus-control differences without a new numeric memory pass threshold. Review preparation cost, per-cycle sampled peaks, cold/warm/late/final residency, footprint and latency together. An isolated final-counter decrease, conflicting metrics or a negligible difference is inconclusive. Do not repeat an unchanged pair to obtain a favorable result. A production change requires meaningful relevant benefit, exact output and cancellation/collision/retry correctness, followed by actual package qualification.

This single ordered pair does not establish statistical significance, long-run stability, whole-application improvement, a cause for build227's retained memory failure, or real ScreenCaptureKit behavior. No build227 memory cell is rerun and no failed threshold is changed.

## Preserved scrolling recovery evidence

Build264 failed release compilation on a duplicate local witness name; its native stages did not run. The name-only correction in source `6ff42dd88f544ce27cd9dc745f7c56a73a2223e7`, [build265](https://github.com/dandibbert/picshot/actions/runs/38346597072), completed all 163 focused native methods once, with no skips or failures. XCTest took 164.493 seconds; the bounded command exited normally after 170.818 seconds. All four final outputs match reference pixels and all eight new light/dark recovery images were independently decoded and visually reviewed. The one stationary preview recovery preserves accepted content and does not start Auto; failed movement recovery leaves the active Pause action truthful. The full 2382-method source inventory and distribution were not executed in that focused run. Actual desktop acquisition remains unverified.

## Build266 preflight failure retained

Source `6a1f31dfd1b10ea322feeb0a778b9f003f28e7a3`, [run38350552219](https://github.com/dandibbert/picshot/actions/runs/38350552219), stopped in the first portable preflight. All fourteen reader test setups failed before their assertions because `SyntheticPair` passed the macOS temporary directory alias to the strict canonical bundle check (`test_save_png_comparison.py:56`, `bundle_manifest`: "bundle must be a canonical existing app directory"). Product compilation, native tests and both measured cells were unrun. The final generic artifact collection also reported no files because the package had not been created; the original job log retains the preflight failure.

The correction resolves only the owned synthetic fixture root before creating its evidence and mock app. A symlink-root regression verifies the fixture now produces canonical paths while the production reader still rejects an aliased app path. Product sources, measurement workload, signatures/identity requirements, deadlines and all original assertions remain unchanged. This is a test-setup correction, not a measured product or memory improvement.

## Build267 single-pair result and scoped promotion

Source `ee86428ad57ab9200754ef225bb590fc8474361a`, [run38350967221](https://github.com/dandibbert/picshot/actions/runs/38350967221), completed the one control-first ARM pair. Both arms used the same signed application and generated 3840 × 2160 input, two warmup and eight measured visible Saves. The exact 165 scrolling and 93 Save methods passed, with 12 overlapping methods (258 executions, 246 distinct IDs); the full 2407-method inventory was not executed in this diagnostic run. The existing failure/cancel/collision/retry assertions passed. All twenty retained PNGs are byte-identical, 209735 bytes each (SHA256 `340a0eb6c821aba0645c2f69f5df6f6e63e740c154c2b5995faf6d1e322f47be`). Independent full decoding reproduces the native regenerated premultiplied RGBA source hash `abf8e5bc5506ad495e3dfe98ab09b97e82258e6e212a68275c3055ae6159e416`, including transparent and semitransparent pixels.

The table reports absolute MiB (1048576 bytes), except rows explicitly labelled growth or milliseconds. These are one ordered pair's observations, not statistical estimates.

| Observation | Legacy preview control | Encoded-payload candidate |
| --- | ---: | ---: |
| Entry RSS | 67.594 | 67.469 |
| After two warmups RSS | 91.500 | 75.672 |
| Final RSS | 120.422 | 77.688 |
| Late RSS | 120.328 | 77.625 |
| Entry-to-warm RSS growth | 23.906 | 8.203 |
| Eight measured cycles RSS growth | 28.922 | 2.016 |
| Last three measured RSS increments, sum | 8.797 | 0.672 |
| Whole-run sampled RSS peak | 159.969 | 108.578 |
| Kernel cumulative RSS peak | 162.234 | 109.125 |
| Entry footprint | 19.861 | 19.846 |
| After two warmups footprint | 22.627 | 24.330 |
| Final footprint | 23.565 | 23.721 |
| Late footprint | 23.408 | 23.580 |
| Kernel cumulative footprint peak | 70.627 | 56.362 |
| Final volatile resident backing | 22.500 | 0.000 |
| Late volatile resident backing | 22.531 | 0.031 |
| Median measured preparation milliseconds | 105.127 | 77.001 |
| Median measured Save callback milliseconds | 107.336 | 79.065 |

The control's volatile resident backing rises by 2.25 MiB for each Save, consistent with the otherwise-unused 1024 × 576 × 4-byte thumbnail; the candidate has no such per-Save increase in this run. The size correspondence supports a boundary-level inference, not proof of each backing allocation's ownership. The 50 ms whole-run sampler recorded 45 complete samples in the control and 40 in the candidate, with no failed RSS/footprint/backing samples. Kernel peaks supplement those samples and may capture work between timer ticks. All twenty controller/window/content/source weak-owner sets drained within the existing four-second deadline; final controller/job/input-admission counters are zero and no staging entries remain. These ownership observations do not establish reclamation of every framework allocation.

The candidate's final footprint is 0.156 MiB higher and its late footprint is 0.172 MiB higher. Its entry-to-warm footprint increase is also larger (4.484 versus 2.766 MiB), and individual warm-cycle footprint peaks are mixed. The measured benefit is therefore scoped to this Save path's unnecessary preview work, Save latency, RSS and peak cost; it is not a blanket footprint decrease, a long-run stability result, or a remedy for build227.

Before/after 70-entry application manifests and executable/plist hashes match, strict signature checks passed, and three distinct owned ARM processes ran in order (control, candidate, independent validator). This is receipt-backed CI identity verification; the local independent auditor did not execute macOS codesign. Original build266 preflight failure remains recorded above.

The next production candidate selects `encodedPayload` only for fresh-image Save defaults. Explicit legacy comparison mode, supplied artifacts and their required preview/admission accounting, ordinary Export previews, encoded options, cancellation, collision handling and the single atomic writer remain intact. The actual omitted-argument presenter and direct-controller Save paths are covered by the extended native default test. Historical v1 comparison invocations reject before emitting identity once the production default changes, preventing a false claim that a later application still has build267's legacy default. Archived build267 reports and the v1 reader are retained; the pair is not repeated. Full native/model/actual ZIP-DMG qualification is required before another experimental handoff.
