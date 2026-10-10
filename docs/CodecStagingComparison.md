# Unused PNG preview: predeclared native comparison

This diagnostic overlay accompanies the narrow still-source PNG staging candidate. Its code base is accepted build 180, with documentation ancestry checkpoint `61c1aa9923ad3f1d3ffbc636b2d75c66b18b0400`. It does not publish an installer or change acceptance. No native memory, latency, or fidelity result has yet been obtained from this overlay.

The same signed app and helper execute both arms in separate fresh app processes. An explicit fixture-owned `CodecProcessConfiguration` selects `legacyPreview` for control or `verifiedBytesOnly` for candidate. The shared product default stays bytes-only; production does not read the diagnostic environment selector. Both arms use the identical PNG encoder/options and preserve the legacy staging-preview lifetime through the old source write. Per-job diagnostics identify the actual staging mode, staged SHA-256, launched helper path and PID, confirmed exit, and cleanup. The shell preflight writes `identity.json` with canonical bundle/main/helper paths, the main executable and helper SHA-256 hashes, and Info.plist source/hash before any cell. Every cell must match that source/bundle/helper identity and the launcher must report the exact main executable path. Both executables and Info.plist are rehashed outside measured app processes before and after each phase, including the final post-matrix promotion check. Helper signature/path/hash preparation inside each app occurs before the measured cycles; entry and post-preparation memory plus preparation time remain in the report.

## First decision, before any expanded workload

Run four WebP export-only cells in AB then BA order: control, candidate, candidate, control. Every cell uses the same original 768×576 source, quality 0.81, lossless and alpha enabled, two warmups and twelve measured exports. Native provider bytes bind source identity without an additional per-cycle source raster draw. All measured staged/final digests must match. The existing source generation/snapshot, native writer, real helper, helper-derived preview, publication/readback, release and settling still participate. No independent ImageIO WebP decode runs in these export-only parents.

The following criteria are fixed before results:

- The control must reproduce at least 16 MiB post-warmup volatile-resident growth. Otherwise the benefit is inconclusive
- Candidate reduces that growth by at least 16.2 MiB (80% of the approximately 20.25 MiB target), leaves at most 4.05 MiB, and its last-three signed interval sum is at most 1.0125 MiB
- RSS post-warmup growth falls by at least 12 MiB
- Independently, candidate may not exceed control by more than 2 MiB for entry/cold absolute RSS, footprint or volatile accounting; cold-to-warm change; final growth; last-three signed growth; whole-run sampled peaks; peaks above cold; or available kernel RSS/footprint lifetime peaks. Both volatile resident and volatile ledger are reported/gated
- Cold first-export latency and warm p50/p95 must each be no worse than control plus max(10% of control, 50 ms). Memory benefit cannot compensate for a latency or peak gate failure

The exact growth endpoint is the final `afterMainQueueDrainAndSettling.backing` minus `backingBaselineAfterWarmup`; controller cells use `backingSettled`. The late sum is cycle 12 minus cycle 9. Every signed increment is retained. The half-second tail is reported separately and cannot replace the declared endpoint. Warm p50 is the median; p95 is nearest-rank ceil(0.95×n), hence the observed maximum for twelve samples. Cold means the first export/draw in a fresh app process, not a claim of cold OS/filesystem caches.

2 MiB is a conservative acceptance margin, not a measured noise bound or proof of a causal regression. Both fresh-process pairs must pass. A nonreproducing control, missing observations or order-sensitive/disagreeing failures is inconclusive. The same gate failing in both pairs rejects this candidate benefit claim. Thresholds must not be relaxed after results. The initial phase exits nonzero on every nonpass and preserves its report; later phases refuse to start unless it passed.

## Remaining evidence required before promotion

The product phase repeats the small real-controller workload in AB/BA order, then runs one matched pair each for large export, large controller, AVIF export and combined attribution. Large means 2048×1536 (within the existing 16-million-pixel bound), two warmups and three measured cycles. AVIF uses 768×576, two warmups plus three measured cycles; it gets bounded no-regression evidence, not an inferred WebP benefit claim. Combined remains separately labeled: its independent ImageIO decode/full raster can add a second backing accumulation and cannot qualify export-only benefit.

Real controller cells dispatch native format/quality/alpha/lossless controls, coalesce rapid quality changes through normal debounce, observe completion of the actual visible `ImageExportPreviewView.draw`, and alternate exact-byte `savePrepared` publication with native window Close. Each draw must match the current displayed image identity after the final request; this is not a WindowServer-presentation timestamp. Request-to-draw and service export latency remain different metrics. Closed controllers/preview images are released before settling. No screenshots or independent output raster decode occur in these measured parents.

The fidelity phase uses separate nonmeasured producer and validator processes. Producers preserve the actual staged PNG through an explicit optional callback, actual final published bytes, actual helper-derived preview pixels and source provider bytes for both WebP and AVIF and both dimensions. Validators independently ImageIO-decode the real final bytes and actual staged PNG at full checked dimensions and compare all premultiplied pixels and alpha with the source (tolerance 2). The actual helper preview retains its recorded capped dimensions (1024/1000 plan) and is compared separately with independently scaled final decoded pixels using high interpolation and copy blend in RGBA8 sRGB (tolerance 2). Exact measured source/staged/final digests bind those specimens to every measured cycle. No re-encoded PNG is substituted for the actual stage.

Existing native WebP/AVIF UI fixtures separately verify active-helper format/quality replacement, lossy/alpha controls, lossless preview fidelity and Save. A real-helper-progress Close case waits for encoding completion, confirmed helper exit/cleanup and controller release, and rejects any late repaint. Existing controller and service cancellation/limit tests remain mandatory.

## Commands and ceilings

Build and sign the candidate app once using the ordinary app-only package path. Do not publish it. Run native structure/regression tests for `CodecStagingComparison|CodecExportAttribution|ImageExportPNGStaging|CodecExportProcess|ImageExportService|ImageExportController` with the existing bounded command runner. The native test filter must include the production owner's actual staging test name if it differs. Run the host checker tests:

```
python3 -m unittest discover -s scripts/tests -p test_check_codec_staging_comparison.py -v
```

Run each phase as its own workflow step so the first result can be uploaded immediately:

```
bash scripts/codec-staging-comparison.sh --phase export "$PWD/dist/PicShot.app" "$PWD/dist/evidence/codec-staging"
bash scripts/codec-staging-comparison.sh --phase product "$PWD/dist/PicShot.app" "$PWD/dist/evidence/codec-staging"
bash scripts/codec-staging-comparison.sh --phase fidelity "$PWD/dist/PicShot.app" "$PWD/dist/evidence/codec-staging"
bash scripts/codec-staging-comparison.sh --phase summary "$PWD/dist/PicShot.app" "$PWD/dist/evidence/codec-staging"
```

The existing launcher allows 600 s per cell plus up to 6 s owned-app close/kill grace. Product helper limits remain 300 s/1 GiB sampled memory; attribution cells retain 480 s cooperative deadlines. Honest outer phase ceilings are 2500 s for four export cells, 7350 s for twelve product cells and 6120 s for ten fidelity cells, including small orchestration allowance. Typical runtime is expected to be much smaller; a timeout is failed/incomplete evidence, never a skip or pass. An outer kill does not prove child cleanup; only actual helper reports do.

Upload `upload/<phase>-reports.zip` after every phase with `if: always()`. EXIT handling preserves failing exit codes and packages available JSON/logs, never the app. Specimens are three separate aggregate archives: `upload/small-specimens.zip`, `upload/large-control-specimens.zip`, and `upload/large-candidate-specimens.zip`. Upload each as a separate artifact; do not combine them into one retrieval. Every archive is checked below 28 MiB; any excess fails rather than silently dropping evidence. Available regular specimens are packaged even on fidelity failure, retaining the original failing exit status. Raw files stay local for review. Parent/child Mach accounting excludes WindowServer/GPU/other processes; 50 ms sampled peaks can miss instantaneous peaks. Kernel lifetime peaks complement but do not repair a missing sample stream.

## Local verification boundary

This patch's Python gate tests and shell syntax can run on Linux. Swift/AppKit compilation, signed-helper tests, actual native draw, installed memory/latency and pixel validation require macOS and remain unrun here. Historical build 180 numbers motivated the experiment but are not candidate measurements or proof of causality.
