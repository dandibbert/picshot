# Effect-context memory-target diagnostic

This is an unproven diagnostic-only follow-up to build 126. The whole-render pool and owned final-storage candidates were rejected for adverse cold/final RSS. Production keeps the reference effect context. This experiment changes only `CIContextOption.memoryTarget` to 32 megabytes on one immutable process context, retaining `cacheIntermediates=false`, the existing effect operations, output formats and default rendering backend. Apple's [memoryTarget documentation](https://developer.apple.com/documentation/coreimage/cicontextoption/memorytarget) describes a per-context render-task budget and warns of a performance tradeoff for smaller values. It is not a total process RSS cap, and recording constructor inputs does not prove Core Image's internal physical allocation budget.

Both arms fix DrawingRaster to `owned-srgb8` and leave the renderer selector absent, selecting the actual production `native` storage path and `caller` autorelease scope. Actual renderer selection, stage counts and zero owned allocations/bytes are checked. No additional pool, cache clearing, decode change, pressure or purge is part of this experiment. Finite effect policies are `reference` (memory target unspecified) and `memory32` (32 MB); unknown selectors/options fail closed.

## Four fresh processes

From the matching checkout, use one exact signed relocated app and a fresh absolute evidence root:

```sh
bash scripts/effect-context-pair-diagnostic.sh /absolute/PicShot.app /absolute/effect-evidence SOURCE_SHA
```

The only optional fourth argument is `effect-context-memory-target`. The runner launches reference certification, memory32 certification, reference resources, then memory32 resources. Both certifications must pass before resource processes start. Each certification retains all 35 exact byte comparisons. Each resource arm retains 205 hashes/conversions, twelve original/applied document pairs, the full small+4K functional cases, two warmup and eight measured 4K workflows. All sixteen actual PNG screenshots across the four processes must independently verify. Certifications never enter memory comparisons. The original drawing and renderer commands/defaults remain unchanged; the renderer checker does not accept the new effect kind.

Native/owned-launch/wrapper deadlines remain 300/600/620 seconds. Reports bind raw native and drawing bytes, installed executable bytes/SHA, source, architecture, PID, fixed storage, finite effect policy, actual constructor options, context count and cumulative normal effect calls. The one valid effect context has exactly `cacheIntermediates=false`; memory32 adds exactly the 32-MB option. No image is retained by the bounded scalar sidecar. Its checkpoints follow the existing drawing checkpoints and add no raster reads or task-memory samples.

The process context is first accessed after the earliest existing drawing memory sample and before the native entry sample. The first scalar checkpoint must have zero attempted, published and failed effect calls, rejecting an earlier effect warmup. Initialization is therefore visible from that earliest drawing endpoint, but excluded from native-entry-only deltas. The comparison explicitly includes `earliestDrawingEntryMemory`, `earliestDrawingToFinalAccountingDelta`, its candidate-minus-reference difference, owned-launch elapsed time and wrapper duration. Review these with the original native entry, cold functional work, warmups, every measured/late increment, snapshot-while-live, cleanup, sampled and kernel peaks. A smaller late slope cannot compensate for an adverse cold residual. Zero tracked renderer bytes and volatile/reusable classifications do not establish physical reclamation or private framework ownership.

## Independent unchanged output guards

```sh
bash scripts/effect-context-output-guard.sh /absolute/PicShot.app /absolute/effect-guards SOURCE_SHA
```

This launches two independent fresh processes, one per policy, with the same 620/600 wrapper/launch bounds. Each retains the original 24-case, 432-refused-output-attempt, 24-controller-release assertions, failed output/cache handling, exact draft/undo/redo/original/base preservation, prior safe file/document preservation and successful unchanged-draft retries. The original fixture remains byte-identical. The added scalar wrapper binds native/drawing report bytes and the executable and checks selected native/caller renderer counters, including zero owned renderer bytes. Both policy reports must pass independently and their process IDs and intervals must prove distinct sequential launches.

The original fixture supplies custom patch closures for its injected failures, cache controls and retries. Its 432 refusals are not 432 effect-context failures. The pre-control effect snapshot reports the calls that actually happened and may have zero normal calls. A separate bounded positive effect control, after the unchanged guard returns, exercises real blur and pixelation through the selected process context and compares exact pixels and metadata with a separately created legacy context. Its two process calls, independent reference context and before/after counters are reported separately; they add no refusal coverage and no memory qualification. This positive control is absent from the four-process paired workflows.

Individual checks and pair reproduction:

```sh
python3 scripts/check-effect-context-pair.py --app APP --expected-source SOURCE --root PAIR_ROOT --stage pair --output comparison.json
python3 scripts/check-effect-context-guard.py GUARD_ROOT/reference APP SOURCE --policy reference
python3 scripts/check-effect-context-guard.py GUARD_ROOT/memory32 APP SOURCE --policy memory32
python3 scripts/check-effect-context-guard.py GUARD_ROOT APP SOURCE --pair
```

Portable normal/optimized Python tests cover success fixtures and forged selectors, kinds, schemas, identities, options, raw bindings, paths, work, lifecycle and preserved output assertions. Producers canonicalize temporary roots before identity construction, including `/var` aliases on macOS. Strict evidence readers still reject aliased raw directories, linked files, stale data and changed byte bindings. Synthetic tests are not macOS execution, output correctness, memory stability or product-remedy evidence. Native qualification and review of the complete lifetime results are still required.
