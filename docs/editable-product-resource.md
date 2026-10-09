# Actual product lifecycle memory observation

Run on macOS with a fresh installed, signed bundle and an unused absolute evidence directory:

```sh
bash scripts/editable-product-resource.sh /Applications/PicShot.app /absolute/fresh-evidence EXPECTED_40_HEX_SOURCE
```

This opt-in fixture complements the complete editable correctness and failure fixtures. It does not replace either fixture, change production defaults, or provide a universal memory acceptance threshold.

## Fixed process and workload contract

The runner launches separate preparation, input certification and product golden certification processes. It then compiles an independent ImageIO decoder, launches one reference-drawing process and one `owned-srgb8` drawing process sequentially, and confirms each exact LaunchServices-owned PID has exited. Both measured apps exit before either output decoder runs. Final renderer storage stays `native`, effects stay `reference`, and no other diagnostic axis is selected.

Each measured process executes exactly two warmups and eight measured cycles at 3840×2160. Every cycle uses the actual editor/history/pin product path: open, native rectangle edit/undo, native crop, history save/close, AppDelegate history reopen, native edit/undo, pin/close editor, annotations hide/show, group hide/reload, Space editor, an eighth rectangle, Apply, and native pin close. History and pin retention quotas are one item. The same run-scoped app, history and session owners survive all cycles and retire only at final cleanup.

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

`checked-product-resource.json` reports independently derived entry, new-process cold, sampled peak, kernel peak, per-cycle released endpoints, measured growth, late increments and action/checkpoint latency. All eight counters and full standard/purgeable task backing dictionaries remain in the raw reports. Scalar owner, raster stride/identity, undo, preview, job, queue, reservation, cache and descriptor accounting accompany checkpoints. Native ImageIO private allocations and WindowServer/GPU memory are not directly owned/accounted by these probes. The history cache's observed byte cost is explicitly unavailable; its limit and zero requested thumbnails are recorded.

The two task-info calls are not atomic, counters overlap, and 50 ms sampling can miss transients. Retired Swift/AppKit owners and balanced owned providers do not prove that private framework backing has been returned. A single reference-then-candidate pair is preliminary for close performance differences; a reversed-order replication is needed before drawing a stronger conclusion. No RSS cap, stabilization verdict, cache purge, normalization promotion, pool intervention, or product default change is made by this fixture.

## Bounds and verification

Native work remains bounded to 300 seconds per app; each owned launcher remains bounded to 600 seconds, with the existing 620-second process-group wrapper. Raw product reports are bounded to 8 MiB to retain all required scalar/backing observations; metadata inputs and documents remain at 128 KiB, encoded PNGs at 40 MiB, evidence at 256 source/unique files and 640 MiB unique bytes, streamed source evidence at 2 GiB, and logs at 2 MiB. No report deadline is relaxed to accommodate instrumentation.

Portable tests are contract and mutation tests, not evidence that macOS execution passed:

```sh
python3 -m unittest discover -s scripts/tests -p test_check_editable_product_resource.py
python3 -O -m unittest discover -s scripts/tests -p test_check_editable_product_resource.py
python3 -m unittest discover -s scripts/tests -p '*source_binding.py'
```

The existing launcher fingerprints remain checked after removing only four literal, exactly counted product-route insertions. The existing complete correctness/failure fixtures and their source contracts remain required for installed release qualification.
