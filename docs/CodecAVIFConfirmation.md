# One reversed AVIF confirmation

This is one additional observation after build 182, not another qualification matrix. It rebuilds the unchanged native product source pinned to `c625e309d39326541db1c4c4756e16fcd7e1eb6b` (tree `009df062cd6439f967f1ce33ac6eef7dfd014f05`). No signed build 182 app was retained, so cross-build binary reuse or equality is not claimed. Only the two new cells use the same newly signed main executable and helper; their new hashes and Info.plist identity are recorded and rechecked outside the measured app processes.

The original control→candidate AVIF pair remains failed. Its warm p95 was 0.5350528750000194 s for control and 0.669911083333318 s for candidate, exceeding the unchanged 0.5885581625000214 s limit. The original product report SHA-256 is `b84cef481dbd6472faf31bb2482b3246d186ec4dac708447a8658d4887e2bb81`; the terminal receipt SHA-256 is `f65e4b3b6387bc74085801e65e2afcb2c1cfcec0a95afdafa32961a37095b33f`.

The new phase launches exactly candidate then control, in separate fresh app processes, each with AVIF export-only, 768×576, two warmups and three measured exports. It reuses the existing launcher, fixture, signature checks, memory sampler, source/staged/final byte binding, per-launch PID/confirmed exit/cleanup evidence, and the existing comparison function. Every memory and latency threshold is unchanged. In this three-sample workload, nearest-rank p95 is the maximum observed measured latency. The full diagnostic's existing phases remain unchanged.

The new pair gets its own result. A passing reversed pair leaves the original failed pair recorded and the overall AVIF result inconclusive/order-sensitive. A repeated p95 failure is a consistent gate excess. Missing or conflicting evidence is inconclusive. Every outcome keeps `avifQualificationHold=true` and `promotionReady=false`; a successful command means only that this new pair met its unchanged gates. Do not pool the pairs or use the new result to turn the original failure into acceptance. AVIF must retain its legacy staging path before a WebP-only candidate proceeds to its remaining fidelity and installed acceptance gates. This observation does not change the production route itself.

The source guard checks exact filesystem bytes and path sets against the pinned commit for all `Sources`, native `Tests`, `Package.swift`, and build/launcher scripts. Only the declared shell/checker confirmation edits are allowed. It runs before packaging and before/after the pair. Consequently the already passing 79 native tests are not recompiled or rerun for this shell-only observation. The original 13 portable checker tests remain byte-identical and are rerun; separate portable tests cover phase selection, exact order/profile/counts, identity and source guard failures, fixed gates, and nonpromotion.

Use the dedicated `[codec-avif-confirmation]` job marker. It suppresses ordinary installer work and does not select the full `[codec-staging]` job. Its ARM runner has a finite 55-minute envelope: app-only packaging retains the existing 1440 s cap and the two-cell phase gets 1300 s, preserving each existing 300 s helper, 480 s fixture, 600 s launcher and 6 s close-grace bound. Timeouts preserve failed/incomplete evidence, not relaxed acceptance.

Equivalent commands in the exact checkout are:

```
python3 scripts/check-avif-confirmation-source.py --report dist/avif-confirmation-source-before.json
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -p test_check_codec_staging_comparison.py -v
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -p test_avif_confirmation.py -v
PICSHOT_PACKAGE_APP_ONLY=1 bash scripts/package.sh
python3 scripts/check-avif-confirmation-source.py --report dist/avif-confirmation-source-after.json
bash scripts/codec-staging-comparison.sh --phase avif-confirmation "$PWD/dist/PicShot.app" "$PWD/dist/evidence/avif-confirmation"
```

The evidence root must be new, so original failed reports cannot be overwritten. Available JSON/logs are preserved on failure in `upload/avif-confirmation-reports.zip`, with the existing aggregate 28 MiB cap. Source/package/outer-command evidence is uploaded separately. No installer or app binary is published by this job. Full product fidelity and installed acceptance remain later work for the actual chosen format scope.
