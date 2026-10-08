# Full native editable drawing pair diagnostic

This opt-in harness compares `reference` drawing with `owned-srgb8` drawing in four fresh processes of one signed installed application. Both measured arms use the same per-call `vimage` hash observer. It preserves the full native editable workflow, its assertions, source sizes, snapshots, warmups, measured cycles and deadlines. A passing portable test suite checks source and report contracts; it is not evidence of a native run or a memory improvement.

## Invocation and evidence

On the native macOS host, use the exact source commit embedded in the selected signed bundle. The application and evidence-root paths must be absolute; the evidence root must not already exist. Run from the matching source checkout:

```sh
bash scripts/editable-drawing-pair-diagnostic.sh \
  /absolute/path/PicShot.app \
  /absolute/path/new-drawing-pair-evidence \
  <40-character-lowercase-source-commit>
```

The runner verifies the bundle signature before launching, before each cell, and after both measured arms. It executes these cells sequentially:

1. `baseline-certification`: `reference` drawing, `certify` observation, functional-only workload
2. `candidate-certification`: `owned-srgb8` drawing, `certify` observation, functional-only workload
3. `baseline`: `reference` drawing, `vimage` observation, complete resource workload
4. `candidate`: `owned-srgb8` drawing, `vimage` observation, complete resource workload

Both certifications must validate before either measured arm starts. Each cell has its own directory, launcher log, bounded-command report, owned-launch lifecycle report and checked result. The native report (`editable-annotation-native.json`), hash-observation sidecar (`editable-annotation-observation.json`), drawing sidecar (`editable-drawing-pair.json`) and native PNG screenshots remain the raw evidence. `certification-check.json` records the certification gate; `comparison.json` records the final paired validation and observations. Failed or incomplete evidence must remain a failure rather than being treated as a partial passing pair.

Reports bind the exact source commit, installed executable SHA-256, architecture, selected application path and owned launch identity. Each sidecar hashes the actual native report bytes, not a parsed/re-serialized substitute. The installed bundle identity and original reports must be available when re-running validation. LaunchServices uses a fresh application instance, no application command-line operands, an explicit diagnostic environment, and confirmed exit of the application it launched. A lifecycle report does not claim an application exit code or a process-start memory reading.

Bounds are unchanged: 300 seconds for the native cooperative deadline, 600 seconds for the owned launcher, and 620 seconds plus a 5-second grace and bounded process cleanup for each command wrapper. Budget all four sequential wrappers, checking and packaging in outer orchestration. The wrapper log is bounded to 2 MiB. A timeout, unconfirmed owned exit, source mismatch, missing resource cycle or failed certification prevents acceptance; extending a deadline or omitting work is not a recovery strategy.

## Equal native work and actual pixels

Every cell retains small 640×360 and full 3840×2160 functional cases. Each measured arm additionally completes two 4K warmups and eight 4K measured cycles. Every resource cycle regenerates distinct original/base rasters, commits real PNG and document assets, closes and reopens history and pin editors, performs native edit/undo/cancel/apply operations, checks durable failure/retry, crop/uncrop, hidden preview and annotated/original export, and cleans up before its endpoint. Full-base and original costs are included; no fixed input raster is retained between resource cycles.

All 15 existing assertions remain required: native history save, history reopen, restored select tool, native edit/undo, cancel preservation, durable failure preservation, durable retry, pin Space reopen, pin Apply, crop full-stack pixels, uncrop undo, hidden geometry, hidden annotated export, separate original export and legacy raster behavior. The unchanged native checker also validates ownership inventories, detached window content graphs, descriptor cleanup, projection/export completion and the complete memory observations.

Each certification process performs 35 exact comparisons between the original CGContext observer and the vImage observer: 18 labeled hashes in the small case and 17 in the 4K case. It compares every normalized RGBA byte, including alpha, in tightly packed premultiplied sRGB RGBA8. Each certification therefore performs 70 conversions, and explicitly accounts for its simultaneous reference/candidate destinations. Both drawing strategies must pass their own 35-comparison certificate; these extra-work processes never enter memory ratios for the measured pair.

Each measured arm records 205 actual labeled hashes: 18 for the small case plus 17 for each of the 11 full-size cases, including warmups. The checker compares all 205 corresponding actual baseline/candidate hashes and dimensions against the appropriate certified workload. It also checks native persisted/reopened/export hashes and exact work counts. Success booleans, a replacement golden, a resized raster or merely matching work totals cannot substitute for the actual cross-arm pixels.

## Raw documents and narrow cross-process normalization

The drawing sidecar records the original and applied encoded document bytes as base64 at the existing native document comparison point. These are the bytes hashed by the native report's `documentSHA256` and `appliedDocumentSHA256`. The sidecar captures at most 12 document pairs, with at most 131,072 bytes per encoded document. It does not decode, canonicalize or rewrite documents inside the native process.

The offline checker first verifies each raw document's native hash binding. Within one process, the first seven layers and every non-annotation document value must remain exact, including IDs and generated dates; Apply adds exactly one rectangle. For cross-process comparison it canonicalizes only declared ephemeral identity fields and their linkage, plus narrowly identified session-generated dates. Document, original/base asset and annotation identities must retain their relationships across original and applied documents; dropping all UUID-shaped values or independently renumbering unrelated references would conceal corruption. Annotation order, the seven retained layers and the one added applied layer remain meaningful.

`sessionDateBounds` records the pair session's beginning and ending seconds since the Foundation reference date. The checker can normalize top-level `capturedAt` only when `captureTimestampKnown` is false and the value is verified inside those session bounds. The added applied annotation's `frozenTimestamp` can be normalized only when `timestampIsCaptureDate` is false and its value is verified inside those bounds. The first seven fixture annotations' fixed epoch timestamps stay exact. Known capture timestamps, capture-date annotation timestamps, date flags, time-zone identifiers and every other document field stay exact. This policy is specific to this saved fixture; it is not permission to erase date fields from arbitrary documents.

All other document semantics must match: full source/base dimensions, original/base distinction and provenance, crop, layer geometry and ordering, styles, text, callout state, effects, output decoration and capture metadata. Any undeclared structural change, identity-link break or date change outside the allowed session-generated fields fails the pair.

## Four native screenshots per cell

Every cell retains the original four small-profile screenshots: `editable-reopened-light.png`, `editable-reopened-dark.png`, `editable-hidden-pin.png` and `editable-restored-pin.png`. The native code captures owned AppKit view content; it does not capture the desktop or request TCC access. Each screenshot must independently pass its own PNG file hash, decoded RGBA hash, file-size and pixel-size bounds, window/content/image/viewport/crop geometry, and native image hit-test checks. Reopened editor screenshots also retain all six enabled, visible, unobscured toolbar-control hit checks.

Cross-process comparison checks screenshot work, kind, appearance and geometry. It does not require native window chrome to have identical PNG or RGBA bytes across fresh processes. Each screenshot's own file and pixel hashes remain mandatory and tied to its report; avoiding cross-run native-chrome byte equality does not permit missing or fabricated visuals. Snapshot-before, snapshot-after and while-snapshot-live observations remain included.

## Memory and drawing attribution

Each drawing checkpoint captures the actual full `O.memory()` result plus a scalar drawing-tracker snapshot. At most 256 checkpoints are retained; the final sidecar is bounded to 2 MiB. It owns no product raster, CGImage, snapshot buffer or source provider. Sidecar JSON serialization occurs after the native final endpoint, while bounded metadata collection and checkpoint polling remain part of both arms' measured overhead.

All eight established counters remain visible: `resident_size`, `phys_footprint`, `compressed`, `purgeable_volatile_resident`, `purgeable_volatile_virtual`, `purgeable_volatile_pmap`, `ledger_purgeable_volatile` and `ledger_purgeable_volatile_compressed`. Full returned backing accounting remains attached, including standard and purgeable task-info flavors, kernel status, requested/returned counts, observation uptime, page size, region count, byte fields and signed ledgers. The paired checker requires the complete declared dictionaries, including internal, external, reusable, device, compressed, all graphics/media tags and kernel lifetime peaks. A short kernel response missing these required fields cannot form a passing pair; missing or failed fields are never converted to zero.

Keep cold entry, functional, before-warmup, warmup, every measured endpoint, late measured increments, snapshots, after-measured and final cleanup costs separate. Whole-process 50 ms sampled peaks can miss transients; they are not kernel lifetime peaks and exclude WindowServer/GPU memory. The two task-info calls are separate and non-atomic. Overlapping kernel categories and ledgers must not be summed as independent allocation causes.

The drawing strategy is chosen once from the explicit launch environment through the immutable process configuration. The harness does not create a user setting, rewrite public production defaults, replace the original component experiment, add a pressure/purge intervention or alter the native workflow. Scalar copy results and public provider-release callbacks describe caller-owned work; existing native CoreFoundation weak probes remain unchanged and are not proof that private framework backing was released.

A successful pair supports diagnostic attribution for this exact binary, architecture and run. It does not establish memory stability, zero leaks, a plateau, allocator ownership, a production memory remedy, general source-format fidelity or release acceptance. Positive growth and adverse counters remain reportable even when every native functional and equivalence check passes.

## Portable checks

```sh
python3 -m unittest discover -s scripts/tests \
  -p 'test_editable_drawing_pair_source_binding.py' -v
python3 -m unittest discover -s scripts/tests \
  -p 'test_check_editable_drawing_pair.py' -v
```

Source preservation checks remove only the four literal pair hooks in the existing native fixture and the one literal observation checkpoint hook, then compare the complete remaining files with fixed SHA-256 fingerprints from the preserving-decode 119 integration. They do not require an external baseline checkout. Existing native and observation validators, storage/document contracts, public smoke routing and the prior component experiment are separately pinned. This catches weakened assertions or reduced workloads that could otherwise make synthetic schema tests pass. Native compilation, installed execution, all actual screenshots and complete raw reports are still required to establish a native outcome.
