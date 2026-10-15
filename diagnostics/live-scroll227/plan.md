# Original227 allocation attribution: one diagnostic replay

Status: prepared before execution; native access, full-history operation and fixed-volume capacity remain unverified. This is not an installer qualification run. No product optimization is proposed by this plan.

## Preserved evidence and question

Product base: `e5a859a82b2a7a697e51a0a4d42f34ae4f5602d0`, tree `bee9ab45ee7770f2aab84565f392934f21903030`. Original run38130153505 remains failed: settled warm RSS growth10,780,672 bytes exceeds9,830,400; the last three RSS increments sum5,177,344 against4,915,200. Every original cycle completed218 frames, produced its exact output and retired tracked source providers and weak session/control owners.

The restored raw227 report has SHA256 `b79079c45046c04c22153e1d96359edf2e97983d11410fdb75b2fb9e770bb5d4`. Two4,177,920-byte reusable-counter steps are first visible during cycle5 capture and cycle9 PNG finalization. Cycle9 RSS is246,235,136 at both release+150ms and release+1000ms. These task totals establish neither a live allocation nor its allocating stack. Their numerical resemblance to four read chunks is not causal evidence.

The227 per-chunk autorelease scope is retained. LiveScrollDocument.swift is still byte-identical in294 (SHA256 `ee68710100c3c78a82199089968b83701eaef54345a62fb4327eca5639919665`). No Foundation/POSIX writer comparison, matcher change, cache flush or allocator-pressure call is part of this experiment.

## Exact scope and non-qualification

Check out original227 and apply an explicitly recorded diagnostic overlay to the resource fixture and NSWorkspace launcher only. Record all original and overlay hashes, product/workflow commits, final executable identity and signing receipt. Keep the Foundation writer, generated1280×960 opaque input,72-pixel fixed header,218 observations,12 reverse observations, final1280×7136 output, two warmup plus eight measured sessions, and the existing180-second session,590-second cooperative and600-second launcher deadlines. Keep the3GiB RSS/512MiB footprint watchdogs and all original ownership/pixel/growth checks.

Full stack logging and suspended snapshots perturb memory, timing and lifetimes. Report these costs and the original gate calculations unchanged, but never use this instrumented run to make original227 eligible, to claim an improvement, or to replace the delivered294 package. Calibration is additional diagnostic work before cycle1, explicitly recorded and included in the existing overall time budget.

## Access and storage gate before the workload

Use only generated inputs and the exact newly launched owned application. Preserve NSWorkspace launch, with a durable launcher-produced receipt independently binding PID, launch time, selected bundle, canonical executable and SHA256. Every request must match it and the current native process identity. Never select by process name or inspect an unrelated process.

Before app launch, verify installed tool documentation supports full `MallocStackLogging`, `MallocStackLoggingNoCompact`, a private log directory, heap addresses without object contents, and vmmap/malloc_history arguments. Check the installed vmmap resident-detail option within the same snapshot calls; if unavailable, explicitly limit any VM attribution to the fields actually observed. Create one unique fixed-size256MiB UDRW/HFS+ image using the existing native hdiutil capability, attach at an owned path, verify separate device and actual filesystem capacity, and prove that a generated fill sentinel receives ENOSPC without image growth. Remove only that owned sentinel. Refuse the probe if actual fixed capacity is not proved. A directory polling threshold alone is not a hard bound.

Check only the exact owned app with bounded lsof descriptor queries at calibration and checkpoints. Inspect the result in memory, retain only stack-log descriptor evidence, and require its canonical path and device to match the pinned volume. An outside-volume or ambiguous active log stops the replay; configured directory names alone are insufficient.

Explicitly forward the three logging variables through the diagnostic launcher allowlist. Do not assume shell inheritance or that `MallocStackLogging=1` means full history. Verify the actual requested mode in the app and use the installed manual as authority. On that same app, calibrate one known owned allocation while live and after free; vmmap, heap and malloc_history must identify it and provide usable allocating/freeing stacks. Allow two15-second calibration holds. A denial, missing free record, unresolvable identity or unexpected API behavior stops the full-history experiment, without sudo, entitlements, debugger grants, TCC, security settings or an alternate access route.

## Eight synchronized checkpoints

Retain original scalar memory observations and add allocator blocks_in_use, size_in_use, max_size_in_use and size_allocated at existing boundaries. These fields are corroboration, not RSS or a leak counter. Obtain at most these eight vmmap/heap snapshot sets:

1. Cycle4, released-plus-1000ms
2. Cycle5, pre-finish-pending-edge
3. Cycle5, released-plus-1000ms
4. Cycle8, released-plus-1000ms
5. Cycle9, finish-image-alive-before-png
6. Cycle9, png-finalized-image-alive
7. Cycle9, released-plus-1000ms
8. Cycle10, released-plus-1000ms

The comparison at each boundary is declared in advance:

1. Establish the settled heap/VM address baseline before the historical cycle 5 step
2. Identify allocations live at the accepted capture edge before Finish; compare their addresses and sizes with boundary 1
3. Determine which boundary 2 allocations remain live after full release and which have recorded frees
4. Establish the immediate settled baseline before cycle 9, retaining any survivors from boundaries 1–3
5. Identify allocations present with the final image alive before PNG encoding, distinct from boundary 4
6. Identify PNG-boundary additions or frees while the same final image remains alive; compare with boundary 5
7. Check whether boundary 5/6 additions survive image/session release or are freed into mapped capacity
8. Distinguish survivors through the next session from released allocations and quantify remaining supported heap/VM changes

An absent step, an address reuse ambiguity or missing address/stack support leaves that comparison inconclusive. Do not select only allocations matching the historical numeric step, and do not infer per-region resident/reusable ownership from task-wide totals.

Post-release holds occur after the original150ms and1000ms observations and ownership checks. Each snapshot set has a10-second deadline; malloc_history extraction has a30-second cumulative budget including calibration, all within the unchanged overall deadlines. Capture probe start/end timestamps and scalar readings around holds. Limit retained tool text to64MiB with bounded pipe drainage and explicitly record truncation. Full stack logs remain on the fixed-capacity volume; out-of-space or missing history is an incomplete diagnostic, not a successful negative finding. Confirm every owned probe child exits; the original launcher owns app teardown. Detach only the exact owned volume after owned app/probe exit is verified.

Join live allocation addresses/sizes and histories to VM region ranges. Select candidate changes by measured deltas and lifetime, not solely an allocation of4,177,920 bytes. No custom malloc-zone pointer enumerator and no full memory dump are introduced. Raw log files alone are not sufficient: resolve relevant histories while the owned process still exists.

## Outputs and decision rules

After the instrumented application exits, verify every complete produced PNG in a separate decoder process against the generated full BGRA oracle, including when memory or diagnostic collection fails. Missing cycles stay missing; no fabricated completion or reduced-workload pass. Preserve each available artifact with hashes and bounded archive parts.

- New allocations remain live after release and into cycle10 with matching stacks: identify their allocation paths. A stack alone does not establish a retaining owner or retain cycle
- Histories contain corresponding frees, live heap usage returns toward its preceding level, and mapped allocator regions retain reusable capacity: attribute only those supported regions to retained allocator pages
- Both kinds contribute: report a mixed result with measured quantities
- Growth lies outside malloc regions: report that VM/framework boundary and only supported VM stack attribution
- Growth disappears/moves beyond observation, output/history is truncated, access fails, symbols or mapping are inadequate, or instrumentation exceeds a bound: inconclusive; no guessed fix and no identical repeat for a green gate

## Primary references

- Apple memory tools: https://developer.apple.com/library/archive/documentation/Performance/Conceptual/ManagingMemory/Articles/FindingPatterns.html
- Current libmalloc modes: https://github.com/apple-oss-distributions/libmalloc/blob/main/man/malloc.3
- Public malloc statistics: https://github.com/apple-oss-distributions/libmalloc/blob/main/include/malloc/malloc.h
- Observation overhead: https://developer.apple.com/videos/play/wwdc2024/10173/

The installed macOS documentation and actual calibration decide support; these references do not establish runtime access in advance.
