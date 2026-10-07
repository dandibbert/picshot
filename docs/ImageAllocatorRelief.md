# Opt-in allocator-relief comparison

This is a separate diagnostic patch, not a production fix or a default PicShot 0.9 gate. Native ARM64 and Intel observations at source `971a786` are complete; neither demonstrated reclamation of the accumulated preview backing. See the [versioned result](ImageAllocatorRelief971.md). The existing [backing attribution results](ImageBackingAttribution.md) do not demonstrate reclamation of the accumulating preview backing.

## Run explicitly

Build and sign an app containing this diagnostic patch first, with its normal `PicShotSourceCommit` metadata. Then, on the matching native macOS architecture:

```sh
scripts/image-relief-attribution.sh --compare /absolute/PicShot.app /absolute/new-evidence-directory
```

The runner refuses an older app without the diagnostic protocol, verifies the signature/native architecture, and first **typechecks without executing** a direct Swift/Darwin import of `malloc_zone_pressure_relief` for macOS 14. Apple's [public header](https://github.com/apple-oss-distributions/libmalloc/blob/main/include/malloc/malloc.h) declares availability from macOS 10.7. The C-import spelling is used directly; there is no private symbol, `dlsym`, or manually declared ABI. The native typecheck must pass before any app launch; availability has not been falsely claimed as locally tested in the Linux authoring environment.

Three fresh processes prepare one synthetic PNG, run the wait-only control, and run the relief arm. Both arms use fixed **768×576, 2 warmups +12 production previews**, unchanged preview/resource limits, and the same immutable PNG. Raster validation does not contaminate those cycles.

After all image scopes and autorelease pools exit and an extra 0.5-second settle, the relief arm calls `malloc_zone_pressure_relief(nil, 33554432)` **once**. The control makes zero calls. The 32 MiB value is a best-effort goal, not a hard cap. This affects the process's malloc zones; it does not create global system pressure and may not reach framework-owned preview backing.

Each arm has a **45-second cooperative deadline**. The launcher kills its owned process at **60 seconds**, allowing up to three further seconds only to confirm exit. There are no retries or tunable cycle/goal/deadline overrides.

## Read the result

Named reports are `image-relief-wait-control.json` and `image-relief-allocator-relief.json`, with a `comparison.json` summary. Reports preserve:

- Actual allocator-reported bytes and call duration; wait-control has no fabricated return
- Raw self-Mach accounting before/immediately after and at least 0.5/2 seconds after API/no-op completion
- One subsequent preview's exact pixel match against separately prepared reference pixels, preview latency, and separate raster/digest latency
- Input hashes, source commit, architecture, fresh PIDs, fixed invocation counts, and partial error evidence

Default unit tests check selector rejection, bounds, and report semantics without invoking relief. The standalone script performs the live report checks only when explicitly requested. Normal build, package and smoke jobs never invoke this runner. The explicitly selected `[codec-attribution] [image-relief]` diagnostic CI job invokes `--compare` without publishing installers.

A decrease in accounting after the call needs comparison with the wait arm; the API return alone cannot identify reclaimed preview buffers. A zero return is also preserved alongside the actual accounting. Neither outcome proves zero cost, all-size behavior, or release readiness. No global `memory_pressure`, `VM_PURGABLE_PURGE_ALL`, huge allocation, permission/security change, or production allocator intervention is included.
