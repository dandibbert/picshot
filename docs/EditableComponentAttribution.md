# Full-size editable component attribution proposal

Status: implemented as an opt-in diagnostic patch; **native compilation and execution have not run**. No measurements, remedy, plateau, release acceptance, or installer are produced by this change. The held 0.16 end-to-end fixture and its gates remain unchanged.

## Why these controls

The completed build113 experiment certified all 35 actual small/4K RGBA inputs but did not remedy retained backing. Candidate entry-to-final RSS/footprint grew 517.20/88.22 MiB versus reference 481.73/44.11 MiB. Candidate 2+8 resources added 132.22 MiB RSS and 108.67 MiB volatile resident after warmup. The largest correlated intervals still include history PNG work, restore, pin creation/apply, and fresh render. Object/FD cleanup is distinct from native backing release.

This proposal splits operations while preserving the actual full-size pixels. The earlier source-cache removal, no-cache drawing, allocator relief and 1024-pixel helper-preview experiments are not repeated or claimed as fixes. In particular, the existing helper preview is not a full-size original replacement.

## Immutable prepared inputs and independent validation

A separate `prepare` process copies the six fixture generator blocks verbatim from held owner source `c80e94de9cf712e118009700feacbd707356e0a3`, tree `694e4fc5c9e98ea12f23885ec544f90250c6d268`. Their combined source SHA256 is `fa69a1f70ee2397b7aaf6de4c6810c1401ffec5a5cf63987403496bdc8ac42b3`. It uses existing full-stack render, crop, decoration and document encoding APIs. It produces the actual distinct original/base at 3840×2160, cropped/decorated current at 2414×1574, all three complete canonical RGBA files, PNGs, the editable document, and a source/binary/process/metadata manifest. Crop remains (480,240,2400,1560); the seven original layers remain intact.

Preparation must match the actual, independently completed build113 full-RGBA hashes, including every alpha byte:

- Original: `c7819513b71c4ad1675665feece59747ff9a518db5766c5a8de973f65fdf19c6`
- Base: `b41f79800dd04476e3381aa6fa9da0a2e4f61034729dce3551909a383be83fc9`
- Current: `b8362e485bb0bfc04471d4a9de1eaf01be470fb66f419193fa41966cdcaaaff5`

Provenance: [build113 run37785905941](https://github.com/dandibbert/picshot/actions/runs/37785905941), native `functional-4k` inputs `source`, `base`, `decorated-reference`, with paired persistence/replay equivalence. These are actual prior results, not fabricated expected hashes or values learned from this diagnostic's candidate output. A mismatch fails; never update expectations merely to pass. The prepared document gets its own immutable hash because its legitimate UUIDs are generated once.

A second, fresh `certify` process hashes all files, fully decodes each PNG at original size, independently uses the same complete CGContext reference layout/draw operations (without weak CF instrumentation) to draw and memcmp every byte against the prepared raw file, and restores the document through an actual editor to flatten/project current pixels. The preparation's direct renderer route and certification's restored controller route must agree. This is independent process/path and prior-reference validation; both native paths still use CoreGraphics, so this is not an independent graphics implementation.

Every consumer loads the same PNG/raw/document bytes once, validates immutable file/manifest/certificate hashes, exact dimensions, packed RGBA8 premultiplied-last sRGB metadata/ICC identity and actual decoded metadata, plus source/executable/bundle/architecture/OS identity. No masks, tolerances, previews or resized assets are permitted. Preparation and certification are excluded from consumer comparison. The Python checker independently rehashes actual files and checks the full certificate; a claimed `exact` boolean alone is insufficient.

## The four deliberately unequal cells

Each fresh process runs exactly two warmups and eight measured cycles:

1. `raw-draw`: copy three owned raw providers, create original/base/current images, draw each 1:1 and compare full RGBA. This controls provider and validation overhead
2. `png-write`: the same three raw-provider draws/validations, then exact production `CGImage.writePNG(to:)` for all three full-size images. It never reads, hashes or decodes any written output in that process
3. `png-decode-draw`: create three full-size ImageIO images from already retained PNG Data, using the full-decode cache options of `EditableCaptureAssetStore.read`, then actually draw and compare all three. The input source is Data rather than URL specifically to exclude fixture file reads; this does not claim to exercise the complete persistence API
4. `editable-render-pin`: copy and validate the same three raw providers; restore the prepared payload in an editor, flatten/decorate and compare current; create a pin, load the same in-memory payload, reopen annotations and invoke its native Apply button; compare actual newly applied current; fresh full-stack render/crop/decorate and compare again. All production admission/projection checks remain active

The editable cell applies the **unchanged** document. It has two restores, one native apply callback, one additional fresh render, six full validations, and zero persistence commits per cycle. It does not claim the changed-annotation gesture, history transaction/reopen, injected durable failure, export, screenshot or full end-to-end work. The other cells each have three full validations; raw and write allocate three provider copies while decode creates three ImageIO images. Their total memory/time is not an equal-work speed/remedy comparison, and subtracting cells does not prove isolated allocator ownership.

## PNG output validation cannot contaminate writer baselines

The writer moves each completed PNG from its per-cycle temporary directory into a separate retained evidence directory, preserving exactly 30 files with source-raw hash, role, extent and encoded byte count. Every cycle removes its temporary directory and checks owned descriptors, including the immutable input directory. The encoded evidence files are explicitly retained; they are not reported as deleted temporary files.

Only after the owned writer process exits does a fresh `verify-writes` process read all 30 actual PNGs, record actual file SHA256 values, fully decode/draw and memcmp against the bound raw references. Its report binds the exact writer report, input manifest and certificate. Matrix completion requires the verifier's actual 30 matching records plus file hashes and owned exit. The writer's own status remains `observed-pending-output-validation`; it cannot independently establish output correctness. Verifier costs are separate and excluded from write-cell totals.

## Allocation baselines, lifecycle and accounting

All consumers retain the same complete PNG/raw/document bytes and the same three explicitly owned validation contexts from a reported preparation baseline. There are no per-cycle snapshots of those destinations. Each fixed destination is cleared, copy-blend drawn 1:1 with no interpolation, flushed, and read in full with `memcmp` and SHA256. A borrowed no-copy Data view hashes bytes without retaining another full raster. All reports retain bounded scalar records only.

Entry is the first fixture boundary after app startup, not process birth. The report separates entry, input load, destination preparation, each cycle's work/draw/compare and release, warmup baseline, measured end, destination release and final input release. The checker independently derives entry→preparation, preparation→warmup, warmup→measured, the final three measured increments, entry→final, and cleanup changes. These deltas remain signed and distinct.

Owned raw provider and destination allocations have release callbacks and exact active-byte/count checks. Every cycle scopes image references, closes/detaches controllers/windows, drains the autorelease/run-loop boundary, and requires zero retained non-window AppKit/Swift weak probes, zero attached closed-window graphs, zero fixture FDs, zero export jobs/controllers and zero projection reservations. Direct weak CGImage/CGDataProvider/CGContext probes are deliberately absent: a separate build114 test demonstrated an Objective-C weak-registration abort involving CF image/provider probes, without identifying which CF object or proving product over-release. The canonical comparison also avoids the existing reference helper's hidden weak CGContext registration. Newly applied pin pixels are validated, but CF object liveness is not claimed from a weak probe. ImageIO and rendered native object/backing lifetime remain unproved. ImageIO's private provider callbacks are not instrumented; zero owned counters do not prove physical backing release.

All eight counters are preserved: resident size, physical footprint, volatile resident/virtual/pmap, volatile and volatile-compressed ledgers, and compressed bytes. The existing 50 ms sampler records per-phase/all-run observed peaks, minima, field availability and sample counts without retaining unbounded sample arrays. Native boundary records preserve both full Mach flavors and kernel RSS/footprint lifetime peaks. Calls are not atomic; overlapping ledgers are never added as separate causes. Account scope excludes WindowServer/GPU/other processes. `measuredDiskReads=0` means the fixture code does no input/output file-content reads in cycles; it is not system-wide I/O instrumentation.

No global cache, default changes, pressure, purge, allocator relief or helper is used.

## Bounds and running later

Hard limits are fixed in source: 40 MiB per encoded PNG, 210 MiB prepared bundle, 320 MiB aggregate retained writer outputs, 30 output files, 2 MiB per report, 10 cycles per consumer, native 300 seconds and LaunchServices 600 seconds per process. The existing bounded-command wrapper adds a 620-second launcher-process bound and caps each launcher log at 2 MiB; it does not relax native/owned-launcher deadlines. Failed/malformed/partial evidence fails completion. No environment variable can override dimensions, counts, tolerance or deadlines.

After independently reviewing and integrating the patch into a separately packaged/signed/relocated macOS diagnostic app:

`bash scripts/editable-components-diagnostic.sh /absolute/PicShot.app /absolute/fresh-evidence-root EXPECTED_SOURCE_COMMIT`

The script verifies signing, launches preparation and certification, runs the certificate checker, launches each fresh component process sequentially, launches the post-exit output verifier, then runs the complete checker. The same executable is required throughout. It creates no workflow and performs no packaging, version change, signing mutation, publication or installer delivery.

Integration points are limited to the new source file automatically included by SwiftPM, one early opt-in `runSmoke` route, a dedicated launcher/runner/checker, request-admission tests, checker tests, and this document. Merge the tiny `SmokeVerification.swift` insertion carefully with any separate output-guard route. Keep original `EditableAnnotationNativeFixture`, production renderer/persistence/guard semantics, existing smoke launcher, CI workflows, release gates and production defaults byte-for-byte unchanged.

Before any execution, compile and run the focused native tests on macOS, then execute the source-bound installed diagnostic on each intended architecture and inspect actual reports. Portable checker tests only validate rejection/contract logic; they are not native pixels, execution, cleanup, memory evidence or 0.16 acceptance. The unchanged complete end-to-end fixture remains the ultimate product acceptance workload.
