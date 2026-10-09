# Actual product lifecycle and installed-default observation

Run on macOS with the signed app extracted from the actual release ZIP and an unused absolute evidence directory. The packaging gate separately binds the extracted ZIP app to the packaged binary, plist and build metadata:

```sh
bash scripts/editable-product-installed-default.sh /absolute/zip-installed/PicShot.app /absolute/fresh-default-evidence EXPECTED_40_HEX_SOURCE
```

The closed `editable-product-installed-default-v1` protocol runs exactly one measured app with `PICSHOT_DRAWING_RASTER_STRATEGY` absent. Both the native parser and checker require the compiled `owned-srgb8` production default. The independent product golden process explicitly selects `reference`; absent override is never interpreted as reference certification. Its current certificate uses `editable-product-resource-v2`. A selected candidate process, an old certificate, or paired evidence cannot be relabeled as installed-default evidence.

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

Frozen experiment133 remains immutable historical `editable-product-resource-v1` evidence and must be replayed with its frozen source/checker. Current v2 and installed-default checks intentionally reject its old compiled-default/certification contract rather than accepting multiple production defaults or rewriting old reports.

## Bounds and verification

Native work remains bounded to 300 seconds per app; each owned launcher remains bounded to 600 seconds, with the existing 620-second process-group wrapper. Raw product reports are bounded to 8 MiB to retain all required scalar/backing observations; metadata inputs and documents remain at 128 KiB, encoded PNGs at 40 MiB, evidence at 256 source/unique files and 640 MiB unique bytes, streamed source evidence at 2 GiB, and logs at 2 MiB. No report deadline is relaxed to accommodate instrumentation.

Portable tests are contract and mutation tests, not evidence that macOS execution passed:

```sh
python3 -m unittest discover -s scripts/tests -p test_check_editable_product_resource.py
python3 -O -m unittest discover -s scripts/tests -p test_check_editable_product_resource.py
python3 -m unittest discover -s scripts/tests -p test_editable_product_source_binding.py
python3 -O -m unittest discover -s scripts/tests -p test_editable_product_source_binding.py
python3 -m unittest discover -s scripts/tests -p '*source_binding.py'
```

The existing launcher fingerprints remain checked after removing only four literal, exactly counted product-route insertions. The existing complete correctness/failure fixtures and their source contracts remain required for installed release qualification.
