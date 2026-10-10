# Unused PNG preview: predeclared native comparison

This diagnostic overlay accompanies the narrow still-source PNG staging candidate. Its code base is accepted build 180, with documentation ancestry checkpoint `61c1aa9923ad3f1d3ffbc636b2d75c66b18b0400`. It does not publish an installer or change acceptance. The initial plan was frozen before native results; the bounded results and remaining acceptance requirements are recorded below.

The same signed app and helper execute both arms in separate fresh app processes. An explicit fixture-owned `CodecProcessConfiguration` selects `legacyPreview` for control or `verifiedBytesOnly` for candidate. The original two-format diagnostic candidate defaulted both formats to bytes-only. After the bounded AVIF latency rejection, the current production candidate resolves WebP to bytes-only and AVIF to the legacy preview route; production does not read the diagnostic environment selector. Both arms use the identical PNG encoder/options and preserve the legacy staging-preview lifetime through the old source write. Per-job diagnostics identify the actual staging mode, staged SHA-256, launched helper path and PID, confirmed exit, and cleanup. The shell preflight writes `identity.json` with canonical bundle/main/helper paths, the main executable and helper SHA-256 hashes, and Info.plist source/hash before any cell. Every cell must match that source/bundle/helper identity and the launcher must report the exact main executable path. Both executables and Info.plist are rehashed outside measured app processes before and after each phase, including the final post-matrix promotion check. Helper signature/path/hash preparation inside each app occurs before the measured cycles; entry and post-preparation memory plus preparation time remain in the report.

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

## Build 181 fixture correction

Source `f15eacbccdfb9eef2cd874f85ec3cd8f6e72e3f4`, run `38040932781`, compiled the signed release app, native test bundle and debug executables. The normal Python group then failed its identity-capture test because a macOS temporary-directory alias was supplied to the intentionally strict canonical-path guard. Twelve other Python tests passed; optimized Python, native regressions and every memory cell were unreached. No candidate memory result or installer acceptance follows from this run.

The follow-up resolves the temporary roots in this test module and explicitly verifies rejection of an aliased app path before accepting the canonical path. The product, identity guard, workload, native test IDs and predeclared comparison criteria are unchanged.

## Build 182 bounded results

[Build 182 / run 38041753943](https://github.com/dandibbert/picshot/actions/runs/38041753943), source `c625e309d39326541db1c4c4756e16fcd7e1eb6b`, passed all **79 exact targeted native IDs**, with zero skips, omissions or duplicates. All four export-only cells and all twelve product cells completed, covering 170 independently confirmed helper exits/cleanups. Full discovery and installer acceptance were not run by this diagnostic.

Both WebP export-only pairs passed every fixed guard. Each reduced post-warmup volatile growth by **20.25 MiB**; RSS-growth reductions were **19.1875 / 21.0625 MiB**. Candidate sampled RSS peaks were **81.422 / 81.281 MiB**, versus **101.500 / 103.391 MiB** control; kernel peaks were **81.438 / 81.281 MiB**, versus **104.875 / 106.781 MiB**. Candidate p95 was **0.578 / 0.594 s**, versus **0.685 / 0.732 s** control. The entry/cold/warmup/footprint/peak/latency guards all passed. Source, actual staged PNG and final WebP digests matched exactly.

Both real-controller pairs and both 2048×1536 export/controller comparisons also passed every guard. The 66 actual controller draws matched current image identity, 34 same-byte saves and 32 native closes released every controller. Small-controller candidate post-warmup RSS growth was still **3.421875 / 3.546875 MiB**, versus **23.609375 / 24.171875 MiB** control. Its volatile growth at the declared settled endpoint was zero; separate half-second tails contained **0.40625 / 0.28125 MiB** volatile residency. Candidate final RSS was **91.640625 / 92.265625 MiB**, sampled peaks **97.90625 / 99.046875 MiB**, and cold-to-warm RSS costs **13.921875 / 14.28125 MiB**. These finite observations do not establish a global plateau or zero leaks.

The single bounded AVIF pair failed warm p95, **0.669911 s** against its **0.588558 s** limit. Product phase therefore exited 3 and fidelity was skipped. Combined corroboration also missed its latency p95 guard but was not a promotion gate; it retained **26.890625 MiB RSS growth / 20.234375 MiB volatile growth**, including its separate ImageIO decode/raster workload. Neither combined growth nor its attribution can be generalized to ordinary export. The one permitted reversed AVIF confirmation and resulting WebP-only production decision are recorded in [CodecAVIFConfirmation.md](CodecAVIFConfirmation.md).

Independent terminal receipt SHA-256: `f65e4b3b6387bc74085801e65e2afcb2c1cfcec0a95afdafa32961a37095b33f`. This app-only diagnostic does not supersede accepted ARM 0.19/build180 or qualify an installed replacement.
