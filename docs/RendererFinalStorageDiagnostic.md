# Renderer final-storage diagnostic

This experiment builds on the complete [build 121 drawing comparison](EditableObservation121.md). Both arms explicitly keep `PICSHOT_DRAWING_RASTER_STRATEGY=owned-srgb8`. The original `renderer-final-storage` experiment is a combined final-storage and autorelease-scope intervention: `PICSHOT_RENDERER_STORAGE_STRATEGY=native` uses the prior native bitmap context and final `makeImage`; `owned-srgb8` uses a checked, zero-initialized caller allocation, the same drawing operations, and final immutable provider ownership after the private context has finished, with its legacy draw-only autorelease pool. Native has no renderer-owned pool. This original comparison does not isolate storage alone. Production remains native renderer storage and reference input drawing. Native qualification of the matched controls is pending.

## Preserved work and semantics

Only eligible integer sRGB8 inputs enter the new storage route. P3, 16-bit and other unsupported inputs retain the prior native renderer path; originals, base objects, source files and metadata remain unchanged. Crop, export snapshot detachment, pin/export presentation providers and their allocators are separate unchanged mechanisms. The renderer retains all intermediate `makeImage` snapshots, effect order, grouped mosaic sampling and magnifier behavior. A final image never aliases a still-mutable context exposed to callers.

The helper checks dimensions, row/product/sum overflow, full padded source bytes plus final destination and aggregate live owned bytes before calloc. Existing renderer pixel admission remains. Limits are 32,768 per dimension, 400,000,000 bytes per owned result and 800,000,000 source-plus-destination and active-owned budgets. These are scoped accounting limits, not a bound on process RSS, CoreGraphics scratch, effect snapshots, other providers or GPU storage.

An eligible allocation, context, conversion, annotation, provider, image or cancellation failure publishes no result and releases its ownership. It does not silently switch to native rendering. Native tests cover independent pixels, output metadata, source mutation/detachment, surviving immutable effect snapshots, actual blur/pixelation/group/magnifier behavior, unsupported formats, overflow/admission, concurrent ownership and failure/cancellation fences. Portable checks cannot establish those native outcomes.

## Matched autorelease controls

The diagnostic-only policies now have explicit boundaries:

- `native`: original native bitmap context and final `makeImage`; renderer autorelease scope `caller`
- `owned-srgb8`: original owned allocation/provider storage with the legacy draw-only pool; scope `draw-only`
- `native-pooled`: native storage inside a whole-render pool; scope `whole-render`
- `owned-pooled`: owned storage inside the same whole-render pool; scope `whole-render`

Both pooled policies enter one shared outer pool before renderer allocation and leave after final image creation, including failure unwinding and owned-policy unsupported-format fallback. `owned-pooled` uses the existing private `Void` drawing helper without the legacy nested draw-only pool. The returned final image survives the outer pool. Scope labels describe renderer-owned pool boundaries, not framework-internal pools or cache reclamation.

Choose exactly one finite comparison kind per invocation:

- `renderer-final-storage` (default): `native` versus `owned-srgb8`; preserves the original combined intervention and calls
- `renderer-autorelease-scope`: `native` versus `native-pooled`; isolates the renderer's whole-render pool under native storage
- `renderer-final-storage-scoped`: `native-pooled` versus `owned-pooled`; compares final storage under matched whole-render pools

DrawingRaster stays `owned-srgb8` in every renderer comparison. These are separate four-process experiments with separate new directories; there is no shared certification or loosely validated six-cell matrix.

## Four fresh processes

Run from the matching checkout with one exact signed relocated application and a new absolute evidence directory:

```sh
# Original default invocation remains supported.
bash scripts/renderer-storage-pair-diagnostic.sh /absolute/PicShot.app /absolute/original-evidence SOURCE_SHA
# Use the same signed app, with distinct fresh directories for each comparison.
bash scripts/renderer-storage-pair-diagnostic.sh /absolute/PicShot.app /absolute/pool-evidence SOURCE_SHA renderer-autorelease-scope
bash scripts/renderer-storage-pair-diagnostic.sh /absolute/PicShot.app /absolute/storage-evidence SOURCE_SHA renderer-final-storage-scoped
```

For the chosen kind, the four cells are baseline certification, candidate certification, baseline resources and candidate resources. Both certifications must pass before measured cells. Every process retains the unchanged small and 4K functional workflow; each resource process additionally completes two warmups plus eight measured 4K cycles. The original 35 exact-byte comparisons per certification, 205 corresponding measured hashes, twelve original/applied document pairs per measured arm, sixteen actual screenshots and original native assertions remain required. The prior build 121 runner and default checker semantics remain available; the bounded comparison-kind argument fixes its policy pair. The renderer checker accepts `--comparison-kind KIND`; the launcher accepts an optional trailing `KIND`. Omission preserves the legacy kind. Unknown kinds, disallowed policy/kind combinations, forged scope fields, unbound wrapper commands and invalid lifecycle reports fail closed.

Native, owned-launch and outer wrapper deadlines stay 300/600/620 seconds. Provenance binds raw native and drawing report bytes, renderer sidecar bytes, source, installed executable, actual selected renderer policy, comparison kind, exact renderer autorelease scope, PID and sequential confirmed ownership of each process. Scalar renderer snapshots reuse existing fixed checkpoint boundaries and add no raster reads or task-memory polls. They do not retain images.

All cold setup, functional, warmup, each late-cycle, final cleanup, sampled and kernel peaks remain visible for all eight memory counters and complete backing classifications. A checkpoint is taken before its named phase: use both endpoints and enclosed source operations when interpreting an interval. A small late slope cannot erase cold retention, and reusable/volatile classifications do not prove physical reclamation or private allocation ownership.

## Independent output-failure guards

Run the unchanged installed 24-case / 432-rejected-attempt guard separately for each requested renderer policy. Always keep `PICSHOT_DRAWING_RASTER_STRATEGY=owned-srgb8`; set `PICSHOT_RENDERER_STORAGE_STRATEGY` to the same explicit policy passed to the checker. Each invocation gets a distinct evidence directory. The original checker invocation still defaults to renderer `owned-srgb8`:

```sh
python3 scripts/check-renderer-storage-guard.py EVIDENCE_DIRECTORY APP_PATH SOURCE_SHA
python3 scripts/check-renderer-storage-guard.py NATIVE_POOLED_EVIDENCE APP_PATH SOURCE_SHA --strategy native-pooled
python3 scripts/check-renderer-storage-guard.py OWNED_POOLED_EVIDENCE APP_PATH SOURCE_SHA --strategy owned-pooled
```

The guard is an independent fixture, so its legacy `comparisonKind=renderer-final-storage` label remains fixed; the requested/selected policy and exact scope fields distinguish guard runs. The checker reuses the original native and drawing validators and binds the additional renderer sidecar to their actual bytes and installed executable. Intentional effect failure can free an allocation before it ever has a provider; a provider callback can also occur after failed image construction. Counts and byte partitions must therefore reconcile without assuming every failed destination receives a provider callback. Native policies must perform actual native seeded, drawn, published and failed work with zero tracked owned allocations or bytes, covering at least all fixture-reported rejected and successful output requests. Zero ownership alone cannot pass a native guard. Every final owned allocation must free; actual guard success, no escaped output, retained draft/prior safe output and controller release still come from the unchanged native fixture.

No source default, memory-remedy claim, 0.16 feature row or installer acceptance is promoted by authoring this experiment.
