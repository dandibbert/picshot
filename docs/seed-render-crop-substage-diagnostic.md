# Seed render/crop substage attribution

This opt-in diagnostic adds exactly two scalar memory checkpoints per existing workflow. It changes no production defaults, renderer implementation, crop operation, fixture image generation, hash conversion, document, screenshot, pool, settling pause, or cleanup. This is interval attribution, not an efficacy comparison or memory remedy.

Run on macOS against one signed, source-bound app:

```sh
bash scripts/seed-render-crop-substage-diagnostic.sh /absolute/PicShot.app /absolute/new-evidence-root EXPECTED_40_CHARACTER_SOURCE_COMMIT
```

The runner requires a new evidence directory, canonicalizes paths, and verifies the signature before and after launching. Exactly two fresh owned application processes run sequentially:

1. `certification`: complete small and 4K workflows, 35 normalized hashes, 70 conversions, four native PNG snapshots and two original/applied document pairs
2. `resources`: unchanged complete small and 4K workflows followed by two 4K warmups and eight 4K measured cycles, 205 hashes/conversions, four native PNG snapshots and 12 document pairs

A failed launch or certification check stops before resources. Native, launcher and wrapper deadlines remain 300, 600 and 620 seconds. The launcher accepts only app path, report path and `certify|resources`; it does not forward arbitrary environment values. It explicitly fixes drawing to `owned-srgb8`, effect context to `reference`, leaves renderer selection at `native/caller`, and sets `PICSHOT_SUBSTAGE_PROBE=seed-render-crop`.

The explicit reference effect selection preserves context initialization after the first existing drawing memory sample and before native entry. The probe validates actual immutable process selections. The two new source-order hooks are:

- `after-native-crop`: immediately after the production native editor apply-crop control returns, before the fixture-only full render
- `after-reference-full-render`: immediately after the fixture full render returns, before its reference crop is materialized

Each records one complete, unmodified `O.memory()` dictionary and scalar drawing, renderer and effect counters. Four records are required in certification and 24 in resources. Each logical memory reading includes non-atomic standard and purgeable task-info calls. Reports retain all backing bytes and signed ledger fields, not just RSS. Metadata observes the existing drawing checkpoints without adding sampling. The sidecar is capped at 256 KiB, and each memory metadata object at 16 KiB; there are no image/provider references, raster reads, closures retained for sampling, new pools, waits or pressure requests.

`check-seed-render-crop-substage.py` uses the existing native, hash observer, drawing and reference effect validators. A separate closed `observation_kind='seed-render-crop'` route adapts only launch validation; old public calls and explicit drawing/renderer/effect comparison-kind sets remain unchanged. It validates the actual app binary and Info.plist source identity, bound raw reports, owned PID and sequential exits, original eight-counter hash observations, PNG bytes/decoded pixels/geometry/hit targets, raw and canonical documents, full work counts, cumulative tracker states, and source-order timestamps. Every resource hash and canonical document maps to independently certified small or 4K work. Synthetic checker fixtures exercise acceptance rules and never attest native execution.

`attribution.json` contains both full process observations, raw report SHA-256 bindings, the earliest drawing/native entry and final readings, launch/wrapper elapsed time, cold and warmup endpoints, every measured increment, late-cycle changes, snapshots, cleanup, sampled peaks and kernel lifetime peak fields. It reports these intervals separately:

- Production editor creation/show/settling/crop, from the existing seed-stage drawing sample to `after-native-crop`
- Fixture-only full reference rendering, between the two added hooks
- Fixture-only materialized reference crop, from the second hook to the actual existing `reference-crop.before` hash observation

The last endpoint has exactly eight counters and no backing dictionary. Its delta is counter-only. The checker never substitutes an adjacent full-backing sample or invents backing deltas there. Existing normalization hash work remains visible separately.

The extra scalar dictionaries and serialization have observation cost, which remains in subsequent measurements. Final probe/effect/drawing sidecar serialization occurs after native `finalMemory` and is included only in the owned application and wrapper durations. No process-birth memory is captured. There is no cross-run subtraction, overhead subtraction, improvement ratio, threshold relaxation, private-framework ownership/release conclusion, leak/stability acceptance or memory-remedy claim.

Portable regression tests cover the exact two-process dispatch, failure gates, finite environment, schema/count/identity mutation, stale report bytes, full accounting dictionaries, source chronology, counter-only crop preservation, unchanged comparison APIs, canonical temporary roots and linked evidence refusal. Counted source-hook tests remove only the exact new hooks before enforcing prior source fingerprints and preserve the integrated SmokeVerification editable route.
