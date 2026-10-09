# Actual product lifecycle and installed-default observation

Run on macOS with the signed app extracted from the actual release ZIP and an unused absolute evidence directory. The packaging gate separately binds the extracted ZIP app to the packaged binary, plist and build metadata:

```sh
bash scripts/editable-product-installed-default.sh /absolute/zip-installed/PicShot.app /absolute/fresh-default-evidence EXPECTED_40_HEX_SOURCE
```

The closed `editable-product-installed-default-v2` protocol runs exactly one measured app with `PICSHOT_DRAWING_RASTER_STRATEGY` absent. Both the native parser and checker require the compiled `owned-srgb8` production default. The independent product golden process explicitly selects `reference`; absent override is never interpreted as reference certification. Its current certificate uses `editable-product-resource-v3`. A selected candidate process, an old certificate, or paired evidence cannot be relabeled as installed-default evidence. The checker explicitly rejects the preceding resource-v2 and installed-default-v1 protocols: their release-boundary contract is different.

For a fresh paired diagnostic on the same current binary, use:

```sh
bash scripts/editable-product-resource.sh /Applications/PicShot.app /absolute/fresh-evidence EXPECTED_40_HEX_SOURCE
```

These fixtures complement the complete editable correctness and failure fixtures. They do not replace either fixture or provide a universal memory acceptance threshold. The compiled product default has been promoted to `owned-srgb8`; `fixtureMutatedProductionDefaults: false` states only that these observations do not mutate that compiled choice. Unsupported layouts, 16-bit images and non-sRGB profiles retain the existing reference fallback. No normalization or algorithm changes are made here.

## Fixed process and workload contract

Both runners launch separate preparation, input certification and explicit reference product golden certification processes, then compile an independent ImageIO decoder outside measured processes. The installed-default runner launches one unselected app and confirms its exact LaunchServices-owned PID has exited before output decoding. The paired runner explicitly selects one reference-drawing process and one `owned-srgb8` process sequentially; both exit before either output decoder runs. Final renderer storage stays `native`, effects stay `reference`, and no other diagnostic axis is selected.

Each measured process executes exactly two warmups and eight measured cycles at 3840×2160. Every cycle uses the actual editor/history/pin product path: open, native rectangle edit/undo, native crop, history save/close, AppDelegate history reopen, native edit/undo, pin/close editor, annotations hide/show, group hide/reload, Space editor, an eighth rectangle, Apply, and native pin close. History and pin retention quotas are one item. The same run-scoped app, history and session owners survive all cycles and retire only at final cleanup.

Installed-default acceptance requires actual owned work, not just a reported selector: additional owned presentations and seeded contexts in every cycle, monotonic cumulative counters, exact bytes for each observed decorated presentation and full/cropped context shape, balanced provider callbacks/deallocations, no unsupported/failure fallback in this sRGB8 workload, and a final tracker equal to the tenth released cycle. Native redraw scheduling can vary, so counts are observed rather than fixed to experiment133. That historical candidate observed forty providers and 607,941,760 allocated/released bytes, with one hundred seeded contexts. These are workload accounting totals, not process memory estimates. All five fixed run owners, controller graphs, known rasters, jobs, reservations and owned descriptors must also retire/drain through the unchanged lifecycle gate.

The seven-layer document is seeded programmatically from the certified input. History reopening and group hide/show use product entry points programmatically; canvas gestures and buttons/menus use owned native event handlers. This is not a physical-input latency test, history-grid double-click test, thumbnail-grid test, or general model of every user workflow. “Cold cycle” means the first cycle of a new process, not cold filesystem or system graphics caches. Action times end at semantic completion, and configured native settle intervals remain included.

## Exact provider-retirement boundary

The existing released checkpoints now require both weak-owner/job retirement and exact owned-drawing-provider balance. Reaching zero weak controller/window-graph counts alone is not the released endpoint. The fixture first records that original weak/job instant, even when drawing providers still have active bytes, and then waits at most two seconds for their callbacks and deallocations. Polling uses 10 ms suspension, stays inside the unchanged 300-second native deadline, and is charged to the existing seed, group-hide or release phase. Final fixed-owner retirement remains inside ordinary run cleanup. No redraw, cache purge, provider mutation, additional raster work or product-lifetime change is introduced by this observation.

Successful measured reports contain exactly 31 `retirementObservations`, in order: `seed-closed`, `group-hidden-released`, and `cycle-released` for cycles 1–10, then cycle 0 `fixed-run-released`. Each row preserves a scalar `weakJobDrained` snapshot and a scalar `providerRetired` snapshot, plus the fixed two-second cap, 0.01-second poll interval, status, poll count and elapsed delay. Both snapshots contain uptime, the existing six ownership counters, ten drained owner/job counters, and the complete drawing tracker. These observations contain no retained image/provider references. The checked summary also retains both snapshots; it does not replace the original active-byte observation with the later balanced one.

Every weak/job snapshot still requires zero app editors, pins, pin editors, live weak owners and attached window graphs, projection/export jobs, queue operations and reservations; completed projection work must equal started work. Drawing work must already be complete and successful, with eligible work equal to owned presentations plus seeded contexts, but provider callbacks/deallocation may still be outstanding. During the subsequent wait, ownership creation and all work/allocation counters remain unchanged. Only callback/deallocation counters can increase, active bytes can decrease, and detached window shells can disappear. Successful retirement requires zero active bytes, exact allocation/deallocation/callback counts and bytes, and the original successful-work equalities. Every prior released-state zero/count assertion, action, checkpoint, resource bound, document gate and pixel-fidelity gate remains required.

The checker rejects missing, reordered or extra observations, incomplete work, a still-active final provider, new work during waiting, backward counters, nonfinite/reversed times, fabricated delay/poll arithmetic, and delays reaching two seconds. Zero polls requires already balanced providers, identical first/final observations and zero delay. A positive poll count requires initially unbalanced providers and elapsed time covering every poll. Both observations must occur inside the named existing phase, before its checkpoint; the final scalar snapshot must exactly match that checkpoint and, for cycle release, the cycle endpoint. Fixed-run retirement is bounded after the last cycle phase and before final memory, with exact final drawing and ownership binding.

This is a measurement-contract correction, not evidence that the historical failure passed or that a product leak was fixed. Failed experiment138 remains failed under its recorded contract. A delay between weak-owner drainage and drawing-provider retirement does not identify the exact native holder, and even balanced tracked providers do not prove release of private framework backing. A fresh native run is required to establish the new endpoint and its timing.

The deterministic native unit tests retain the actual tracked CGDataProvider through a nonthrowing `providerObserverForTesting` supplied only to an explicitly constructed drawing configuration. Observation occurs once immediately after successful provider construction, before CGImage can eagerly copy it. The cache then follows its ordinary prepare/clear path. Process/environment configurations always set this observer to nil; no fixture report or diagnostic path retains providers. This inert test seam does not correct product ownership or change conversion, admission, failure or pixel semantics. A source-scope check reconstructs and hashes the complete prior drawing implementation after removing only the five exact test-observer insertions.

## Independent output fidelity

The measured app receives original/base PNG paths and metadata. Its production `CGImage.read` can retain compressed provider backing; a zero duplicate-fixture-raster count is not a zero compressed-backing claim. The measured fixture does not read raw RGBA goldens, decode a separate current golden, draw duplicate reference outputs or hash diagnostic pixels.

Before ordinary retention can retire a committed version, the fixture copies that version's index, document and original/base/current PNGs in 64 KiB chunks. There are four versions per cycle: history save, pin before apply, pin after apply, and pin closed. Content-addressed deduplication never skips reading/hash-checking the committed source version. Every copy and growing scalar report remains instrumentation cost inside the observed process; no cost is subtracted and the results are not “pure product RSS.”

The Python checker requires every archived byte count and SHA256, bounded safe regular paths without symlinks or hardlinks, exact catalog/asset/document relationships, complete state/action order, and exact owned process exit. PNG structure, CRCs, inflated-row bounds and metadata are checked before the independent helper converts them to full premultiplied sRGB RGBA8, including alpha. The helper performs `memcmp` against separately certified raw goldens and hashes every comparison byte. Its plan, source, executable, PID, command lifecycle and output report are bound back to the measured report and certificate. No measured output can become a golden.

The historical canonical hashes are:

- Original: `c7819513b71c4ad1675665feece59747ff9a518db5766c5a8de973f65fdf19c6`
- Distinct base: `b41f79800dd04476e3381aa6fa9da0a2e4f61034729dce3551909a383be83fc9`
- Cropped/decorated seven layers: `b8362e485bb0bfc04471d4a9de1eaf01be470fb66f419193fa41966cdcaaaff5`
- Applied eight layers: `901d625dd2b57188f0d6228ab9ecfbdc1ceee7d2e297d85d42a03bcdf751f621`

The full metadata recipe is pinned in `scripts/fixtures/editable-product-recipe.json`, derived from the source129 audited 4K native/drawing reports with their hashes preserved. The fixture explicitly uses epoch capture time and UTC. Only declared UUID paths are normalized while preserving their equality topology, and only the new eighth mark's session-bounded frozen date is normalized. First-seven dates, styles, geometry, linked pixelation relationships, capture metadata, unknown fields and all other values remain exact. Stored originals/bases may be re-encoded between stores; canonical identity and each committed file's own encoded identity are checked separately. An existing pin's original remains immutable through Apply.

## Reading the result

`checked-product-installed-default.json` reports the unselected installed app; `checked-product-resource.json` reports the explicit pair. Both retain independently derived entry, new-process cold, sampled peak, kernel peak, per-cycle released endpoints, measured growth, late increments and action/checkpoint latency. All eight counters and full standard/purgeable task backing dictionaries remain in the raw reports. Scalar owner, raster stride/identity, undo, preview, job, queue, reservation, cache and descriptor accounting accompany checkpoints. Native ImageIO private allocations and WindowServer/GPU memory are not directly owned/accounted by these probes. The history cache's observed byte cost is explicitly unavailable; its limit and zero requested thumbnails are recorded.

The two task-info calls are not atomic, counters overlap, and 50 ms sampling can miss transients. Retired Swift/AppKit owners and balanced owned providers do not prove that private framework backing has been returned. A single reference-then-candidate pair is preliminary for close performance differences; a reversed-order replication is needed before drawing a stronger conclusion. The installed-default observation makes no paired comparison. Neither fixture applies an RSS cap, auto-claims memory stability, requests cache purges, normalizes unsupported inputs or changes pool behavior.

Frozen experiment133 remains immutable historical `editable-product-resource-v1` evidence and must be replayed with its frozen source/checker. Current resource-v3 and installed-default-v2 checks intentionally reject the earlier compiled-default/certification and release-boundary contracts rather than accepting multiple contracts or rewriting old reports.

## Bounds and verification

Native work remains bounded to 300 seconds per app; each provider-retirement wait must complete strictly before its two-second cap, within that same deadline. Each owned launcher remains bounded to 600 seconds, with the existing 620-second process-group wrapper. Raw product reports are bounded to 8 MiB to retain all required scalar/backing observations; metadata inputs and documents remain at 128 KiB, encoded PNGs at 40 MiB, evidence at 256 source/unique files and 640 MiB unique bytes, streamed source evidence at 2 GiB, and logs at 2 MiB. No report deadline is relaxed to accommodate instrumentation.

Portable tests are contract and mutation tests, not evidence that macOS execution passed:

```sh
python3 -m unittest discover -s scripts/tests -p test_check_editable_product_resource.py
python3 -O -m unittest discover -s scripts/tests -p test_check_editable_product_resource.py
python3 -m unittest discover -s scripts/tests -p test_editable_product_source_binding.py
python3 -O -m unittest discover -s scripts/tests -p test_editable_product_source_binding.py
python3 -m unittest discover -s scripts/tests -p '*source_binding.py'
```

The existing launcher fingerprints remain checked after removing only four literal, exactly counted product-route insertions. The existing complete correctness/failure fixtures and their source contracts remain required for installed release qualification.
