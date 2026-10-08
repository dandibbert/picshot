# Verification evidence and release boundary

## Accepted ARM 0.15.1 reported-effect-failure hotfix

**ARM [0199b9c6e5c16610b78b072945e45f8183d730c2](https://github.com/dandibbert/picshot/commit/0199b9c6e5c16610b78b072945e45f8183d730c2), tree `4ce96bd120197a2812d78f9d7924c986c4bc74e7`, version 0.15.1/build 111 is accepted for this bounded urgent output-failure correction.** [ARM job 113285943782](https://github.com/dandibbert/picshot/actions/runs/37769699261/job/113285943782) finishes success; [Intel job 113285944083](https://github.com/dandibbert/picshot/actions/runs/37769699261/job/113285944083) independently fails the focused deadline. The run-level failure does not erase the ARM-specific completed gates. No Intel acceptance transfers from ARM, and no 0.16 feature or row is promoted. ARM remains **60 Code / 55 Partial / 9 Missing**, Intel **50 / 61 / 13** across the original 124 behavior rows, with all nine context rows and all 133 original IDs retained.

### Exact ARM 0.15.1 package bytes

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `PicShot-0.15.1-macos-arm64.zip` | 18,694,244 | `c89f8b050f8f6fae36639d6aee47ec4ca59963469a0a28ab07258f4a1f0134c0` |
| `PicShot-0.15.1-macos-arm64.dmg` | 21,548,977 | `d08f568af6802caeda55b25a20f2baccbf0072f31416b3657117068c840123f4` |
| `PicShot.app/Contents/MacOS/PicShot` | 19,178,272 | `e2adbd84739385705cd99f7aa984361e6ca021d0855987c3cf671cf5c65f2629` |

Actual downloaded package bytes match; the 70-entry inner ZIP passes safe-path/CRC checks. Info.plist and external/embedded build metadata bind the exact source, arm64 and 0.15.1/111. Native deep/strict signing checks pass for packaging and both relocated installs; independent inspection verifies the Mach-O signature blob and 39 SHA-256 resource seals. Runtime executable hashes in the manual-scroll/launcher/multi-window evidence match the delivered candidate executable. Signing remains **ad-hoc, not notarized**; this is not Developer ID, publisher identity, Gatekeeper or macOS 14 physical-device acceptance. **Library persistence is now confirmed on 8 October 2026:** the same ARM ZIP and DMG identities are **version 14**, and the same complete guide is **version 22**, **180,644 bytes**, SHA-256 `b6e44be2eacb7d0dd7c56d0e1ef8301412c5fec061c8cd1e2d9ffcd1f022b596`, with local identity metadata applied. **ZIP version 14 and guide version 22 were delivered at 12:21:51 UTC on 8 October 2026**. **DMG version 14 is saved only and was not delivered.** This format-specific delivery receipt is separate from saved-file persistence and native/package acceptance.

### Exact-source native and model gates

The complete discovered selection is **1,586 IDs: 1,583 passes + 3 expected pre-weight model skips**, zero failures, across disjoint processes of **784 selected (783 pass + 1 skip), 251.254 seconds**, and **802 selected (800 pass + 2 skips), 205.421 seconds**. Both exit 0 under the unchanged **420-second** per-process cap. The focused selection independently completes **1,108/1,108**, zero skips, in **558 / 254.964 seconds** and **550 / 187.077 seconds**. All nine `EditorOutputProjectionEffectFailureTests` pass in both ordinary and focused selections; the two additional diagnostic cases pass. The subsequent pinned-weight model stage is **12/12 passes, zero skips**, including the three previously skipped formula/table/erase weight-dependent cases. These overlapping stages are not additive. They are disjoint-process test selections, not one shared-process suite or revised product-performance thresholds.

Ordinary log SHA-256 values are `4fba22af52a025761a2b9b5fb4dfa8bec84411e74c0a526537ca8ba47e0917cc` and `caaf46eda1fe6ea938b7768a6ff470e7da2e29e620a156a1d080a0341825b04b`; focused logs are `0b11c508149e6071edcc315dc27fa30e87ae4fd5284abc75798acc1e4a2987da` and `b50b0070b3344e65a91efc99bab5311c5cb714c7a8afeb1b88bd2d7a6e4d50f8`. The full raw ARM job log hashes to `8b27aad9e2806e0716d0c947623cd56b987d6c6419be05e5c6e13351c7cad2c5`.

### Installed failure guard and remaining semantic boundary

Each final actual ZIP and DMG passes **8 cases / 144 rejected attempts** through the production request-output path and **nine AppKit selectors per case**. The fixture injects nil for the second linked blur/pixelation patch on its own canvas. No private output sink is invoked and no save/export/projection work starts; previous private PNG bytes and committed editable draft/undo/redo remain unchanged. All eight fixture controllers retire and their temporary directory is removed. The prior file is removed during successful fixture cleanup; its exact bytes/hash are native-runtime assertions, not a later independent decoder inspection. The fixture does not use the user's general clipboard. Normal blur/pixelation/redaction files separately pass PNG signature/CRC, exact affected/exterior pixel, hash and visual inspection checks.

The main installed ZIP process **59421** exits after **318.23054099082947 seconds** and DMG process **72854** after **178.619362950325 seconds**. Exact source/build/package/Info.plist/PID binding and all **18 unchanged assertion/checker groups** pass; all **11 unique owned installed launches** confirm exit. Offline Linux replay maps only macOS `/var` and `/private/var` aliases to the same audited packaged binary/plist. No report field, pixel assertion, resource bound or acceptance threshold changes.

This corrects **reported required-snapshot/patch/recursive-draw failure**: an incomplete raster cannot be delivered as a successful final output. It does not detect every conceivable incorrect non-nil GPU result, reproduce a real GPU failure or establish Intel hang causality. Canvas draw still falls back to cached/base pixels on preview failure; output refusal is not universal safe on-screen concealment. Normal rendering defaults remain unchanged, and blur/pixelation remain cosmetic.

### Installed workload coverage

Both formats independently complete 40 lifecycle iterations, three real-model jobs with helper exit, three seven-frame recordings and 95 recording pixel assertions, save 2+8, OCR/mosaic/annotation/LaTeX 2+12 each and group transforms 3+20. Prior pin/capture/output/codec/recording and cleanup checks remain. ZIP additionally runs GIF 1+4 x360-frame exports plus 1080p 12-frame/cancellation checks, manual scrolling **8 warmups + 16 measured cycles with four accepted 4K/5K frames per cycle**, and multi-window **4+12** default-path cycles producing exact **4480x2520** pixels. These scopes and processes are separate; the ZIP-only workloads cannot be attributed to DMG or Intel. Separate abrupt recording recovery kills only its owned child, recovers five fragments/50 video frames/239,552 audio frames over five seconds, preserves source data and cleans temporary files.

### Current memory observations are not a memory remedy

All required owned-object/job/helper/descriptor/temp assertions pass. Positive RSS, footprint or native backing observations remain intact; neither cleanup nor a smaller footprint means RSS/backing was released. These are observational reports with no stability/plateau/zero-leak claim.

| Actual ZIP manual-scroll phase | RSS bytes | Physical footprint bytes |
| --- | ---: | ---: |
| Entry after prior combined fixtures | 915,374,080 | 38,080,384 |
| After 8 warmups | 804,044,800 | 40,881,664 |
| After 16 measured cycles and cleanup | 829,341,696 | 39,751,232 |

Manual post-warmup growth is **+25,296,896 / -1,130,432 bytes**, with last-three RSS intervals **+17,006,592 / -8,683,520 / +8,699,904** and footprint **+1,278,016 / +229,376 / -1,687,552**. Final cleanup changes both by zero. Measured sampled RSS/footprint peaks are **978,075,648 / 132,910,592 bytes**; warmup peaks are **1,016,152,064 / 129,994,304**. The entry is already a combined-workload process, not idle usage or isolated scroll cost. Entry-to-final decline does not erase positive post-warmup/late growth.

| Fresh actual ZIP multi-window phase | RSS bytes | Physical footprint bytes |
| --- | ---: | ---: |
| Entry before input preparation | 70,352,896 | 20,858,944 |
| Inputs prepared before warmup | 114,409,472 | 23,070,912 |
| After 4 warmups | 160,104,448 | 23,120,192 |
| After 12 measured cycles and cleanup | 161,349,632 | 21,662,016 |

Multi-window RSS grows **90,996,736 bytes entry-to-cleanup**: preparation **+44,056,576**, warmup **+45,694,976**, post-warmup **+1,245,184**. Post-warmup footprint is **-1,458,176**. Late measured 8→9 through 11→12 RSS intervals are **+49,152 / +65,536 / +409,600 / +114,688**, footprint **+32,768 / +65,536 / +393,216 / -278,528**. Sampled RSS/footprint peaks are **194,445,312 / 68,421,952**; sampling can miss transients. Production composition is `normalizedCandidate`, source `productionDefault`, with no diagnostic override; post-warmup and late actual volatile-resident/virtual/compressed growth is zero. This is not a total-app/GPU/WindowServer peak or universal memory plateau.

Actual ZIP image-export **1 warmup + 4 measured cycles x4 serial formats** retains post-warmup RSS **+33,914,880 bytes (32.34375 MiB)** and footprint **-7,258,048** despite **20/20 controllers released and zero sessions/jobs/temp files**. ZIP OCR has **+5,111,808 bytes (4.875 MiB)** settled footprint growth. Separate 768x576 backing/codec processes still retain ARM AVIF combined post-warmup RSS **+53,919,744 bytes (51.421875 MiB)** and Intel WebP combined settled RSS **+43,298,816 (41.29296875 MiB)** with positive tails. Different workload baselines and processes are not additive and do not establish a decoder/preview remedy. Earlier measurements remain source-qualified below.

### Intel 111 failure and held 0.16

Intel's early actual installed ZIP separately passes the **8/144** guard and normal mosaic evidence. Its first focused native shard later reaches **420.096 seconds**, exit **124 / SIGTERM -15**, after **506/1,108** selected IDs complete. **602 remain incomplete**, including the nine new fault cases assigned to unrun shard 1. No failed assertion or GPU-error line appears in that bounded process; the last named test is not proven to cause the timeout. Full/model/final ZIP/DMG gates are skipped and no Intel111 installer is accepted. Intel remains **0.11/build69/3f013417**.

The hotfix is built from the delivered 003cd44d code baseline and does not contain 0.16 editable persistence/crop/visibility/recovery or its new flattening labels. 0.16 remains held for its own incomplete/failed gates and unaccepted RSS/backing growth. The possible ANN-18/HIS-03 promotions remain proposals only; no row/count change is made. Physical TCC/Retina/multi-display/Spaces/external-application/minimum-OS acceptance and sustained behavior remain separate. The sections below preserve earlier acceptance, failures, package bytes and delivery receipts under their original source/version scope.

## Historical accepted ARM 0.15 and current Intel 0.11

**ARM source [003cd44d0b8618e8cf4e43a84b1ac155cfcac3bc](https://github.com/dandibbert/picshot/commit/003cd44d0b8618e8cf4e43a84b1ac155cfcac3bc) / 0.15.0 / build 102 is accepted for the bounded tested workload.** [ARM job 113186353975](https://github.com/dandibbert/picshot/actions/runs/37739399357/job/113186353975) completes **success at 07:32:11 UTC on 8 October 2026**. [Run 37739399357](https://github.com/dandibbert/picshot/actions/runs/37739399357) ends **failure at 07:32:12 UTC** because Intel independently failed early UI. ARM completes all **1,575 ordinary selected cases: 1,572 passed + 3 documented pre-model skips**, with **1,097 focused and 12/12 actual-model passes, zero model skips**. The suites overlap and their counts are not additive. Both actual installed ZIP and DMG pass functional/prior-feature/model/recording/cleanup gates; ZIP alone supplies the repeated production-default 4K measurement below.

ARM CAP-07/11/14 move narrowly to **Code**, making **60 Code / 55 Partial / 9 Missing** across 124 behavior rows. All 133 original requirements/checks/citations and nine macOS-context rows remain, and no complete-parity/physical-device claim is made. Intel remains accepted/delivered **0.11/build 69/source 3f013417**, **50 / 61 / 13**; its build-102 failure and unrun later stages are preserved below. **ARM 0.15 Library persistence is separately confirmed at 07:47 UTC on 8 October 2026**: both binaries are **version 13**, and the same complete guide is **version 21**, **168,811 bytes**, SHA-256 `978055cacc08e18e1950b655f21362612aeec7d9b60404a6f561ee07d09a978d`. **ZIP version 13 and guide version 21 were delivered at 07:47:54 UTC on 8 October 2026; DMG version 13 is saved only and was not delivered.** This format-specific delivery record is separate from saved-file and native/install acceptance.

### Early ARM installed-ZIP component evidence

ARM UI artifact **11533298109** verifies **7,590,541 bytes**, SHA-256 `fcf7ff537e65a26f20fb4ead2c35b2e384e74c085dd5bf0d4904238d6d9f1d59`. Its **16,769-byte** combined capture/output report verifies SHA-256 `611504bacc1a3c8965b504d2590248bb1c5c133a44672dcc66412d0beb0da59d` and binds **003cd44d / 0.15.0 / build 102 / installed bundle**. Ratio, decoration, multi-window and original/current pin components all pass. Exact source-crop comparison, all three element hit targets and frozen edge palette switching pass. The injected window fixture verifies **317,200 exact pixels**, **2 captures / 4 cancellations / 6 cleanup checks**; the callout maximum observed release is **922.207 ms** under the unchanged deadline.

This early owned synthetic native UI/pixel evidence is separate from the completed final native/model and installed gates recorded below. Physical TCC/foreign windows/Retina/multiple displays remain unverified; early UI alone is not resource or parity acceptance.

### Verified ARM focused production-default coverage

ARM focused artifact **11533034775** verifies **314,988 bytes**, SHA-256 `79fc9fe39be8f3c51d11b78ab37f4c193cf15208622e3232a919ececb89ec145`. The exact-source report records **1,575 discovered IDs / 1,097 selected and passed / zero skips**, across **556 + 541** disjoint native processes. Their bounded runners exit **0 in 259.532 / 195.603 seconds**, within the unchanged **420-second per-process caps**, without forced signal or log truncation. This is exhaustive focused selection, not an ordinary-suite pass or a shared-process execution; overlapping focused/full/model totals must not be added.

`MultiWindowNormalizedCompositionTests.testProductionDefaultAndDiagnosticParsing` and `testSequentialCaptureWithoutModeUsesProductionNormalization` both pass at **003cd44d**, verifying mode parsing and the no-mode production call path. This is native test coverage, not the required installed production-default 4K measurement. Report SHA-256 is `ef102eef213d6907bb6be600dbd4fffea0f0adc15396d7e3ee1c76a8ba5f424b`; plan is `1d1c066d92225d122603f05c7f465cc941c8c5666d4b60b192f17efeba7fac1c`; discovery log is `588a40689641c03d9bf36faeeea41aad236868c40d825bf0b653c9a5ed58cf4c`. Process log hashes are `e23dfcf9dc8418e0d946d75f335a95db348ac2f9ef1f004fcd6758585ce88132` / `0240b7201df6150e45d48023a3e3cc2f70e1fe5a2d6345c521d5b68265aa54d8`.

### Verified ARM ordinary and model coverage

ARM ordinary artifact **11534491476** verifies **399,413 bytes**, SHA-256 `d61f8185b60a95fe8ca3c6137a2c13510b7df3baad42d31bb02ef5c6d82ddd40`. Exact-source `test-report.json` selects all **1,575 discovered IDs** and records **1,572 passes + 3 documented pre-model skips**, zero failures. The **782 + 793** disjoint processes record **781 passes / 1 skip** and **791 passes / 2 skips**, exiting **0 in 266.866 / 221.314 seconds**, within the unchanged **420-second caps**, without forced signals or log truncation.

Ordinary report SHA-256 is `7a83ac65abe0cc1822f8f5fcca18750762e799e0b92d35b828d3c47434136813`; plan is `9b6bbea5cfbaeccf0469ea788d98259d8adc581fe916d073e37d8f6517a653cc`; discovery hash matches the focused inventory above. Process log hashes are `5dc15275fe3aa27104f532d4953f6bb2e7a127280df5177189254a7f972eeb3c` / `eec0bb1201c707172a4c7a3a468c88c8f6d7c51bde182ad8dd39294543c5ff60`.

The ordinary skips remain the actual-weight formula fixture, configured native table-weight fixture and real-CoreML smart-erase fixture, using the same exact IDs retained in earlier records. The subsequent actual pinned-model validation passes **12/12 with zero failures/skips**. Its **4,310-byte** `model-inference.log` verifies SHA-256 `9b066abc331ae8c3d5e691b08404ed1cd177456bf70cb1dbfe80e4ca99bf7051`. Ordinary skips remain skips; focused/full/model stages overlap and are not added as independent coverage. Both final installed formats and ZIP production-default resources pass their bounded contracts as recorded below.

### Independent Intel early callout failure

[Intel job 113186354189](https://github.com/dandibbert/picshot/actions/runs/37739399357/job/113186354189) starts at **06:45:42 UTC** and fails at **07:08:25 UTC on 8 October 2026**. Early UI artifact **11533463260** verifies **5,956,380 bytes**, SHA-256 `311003421784d72a95daa4663b24ef26eaeeb5b601daf7e60fa3874fd1b724f3`, with **143 CRC-safe entries**. Its **14,551-byte** `annotation-details.json` verifies SHA-256 `589a1e670885ea624a63442918f50bbb8007e980bec13e5eb1d32f1989ed8b5e`, binding exact **003cd44d / 0.15.0 / build 102 / relocated installed ZIP**. The unchanged **2,000 ms** callout native input/context observation contract fails before capture/output.

Five of six rapid retirement cycles are created. Cycles 1 and 2 are first observed nil at **1,988.912471 / 1,973.969780 ms**. Cycle 3 is last observed live at **1,036.194623 ms**, then first observed nil at **2,027.893572 ms**, across a **991.698949 ms sampling gap**. The exact deallocation time and cause are unknown; a sampled first-nil time is not exact release latency or CPU/scheduling attribution. The strict observation gate remains failed.

All sampled app-owned/text-system graph counts are zero. The stop record contains **11 closed controllers / 10 release-count increments**, with the append aborted; that counter difference alone is not proof of a surviving controller. Final native input/context counts are **2 / 2**, corresponding to cycles 4/5 aged **1,070.421443 / 83.532363 ms** at the stop. Neither is proved late. Their per-cycle rows are stale because the sweep throws while handling cycle 3; the reviewed stop state must not be silently replaced with those unfinished rows or read as completed retirement.

Capture/output components, focused/full/model, final installed formats and production-default 4K resources are **unrun on Intel**. This earlier callout observation failure does not establish a normalization-path regression, and build-101 diagnostic passes do not substitute for the missed current-source gates. Accepted Intel remains 0.11/build 69.

### Exact accepted ARM 0.15 packages and installed format gates

QA artifact **11535341580** verifies **23,830,417 bytes**, SHA-256 `74c70c0358cac205b6c46ae9771fc080981c6a3be0bd73e50ac6b0edac9d0f4a`. Both final actual installed formats bind **003cd44d / 0.15.0 / build 102**, pass the combined capture/output and full applicable prior-feature/model gates, and confirm owned app exit. ZIP/DMG combined capture/output report hashes are `45d3f79b9409713e1402830987bd7f0680c020f70f7c4e99e33c1a407b5ef9e8` / `ed5cf2966d3f9e9bcfdbc8ea287d0489d0932f3e33d745ad7b4c198b1c220f74`; launch-report hashes are `ef64dd04c0a4cb0a95c9e04074f3099864d97c7c1ee5610610e27a39cc50027d` / `369e35ab3100f50525f55959cd2982b49e77f7e9e38d4e96fd7fb84b4bd570ba`.

| Actual accepted ARM file | Bytes | SHA-256 |
| --- | ---: | --- |
| PicShot-0.15.0-macos-arm64.zip | 18,642,039 | `ac9b602553686e75c8ac830d542bfd456c686e0ef87aaf8709f3216e9066b787` |
| PicShot-0.15.0-macos-arm64.dmg | 21,495,277 | `b4d4cb40b4a4acf7c96431b9bf6a3a7c7cf65086153ec56b30a628e042890533` |

The ZIP has **70 CRC-checked entries**; embedded build/version/source metadata agrees. Its **19,035,184-byte executable** verifies SHA-256 `603a105cb2ef16b97da6ae8a03e9822f64bdf134db089a8339b5eb64dc96d84e`. Metadata declares arm64, macOS 14 minimum, ad-hoc signing and not notarized; this is not minimum-runtime, publisher identity or Gatekeeper acceptance. **Library replacements are confirmed at binary version 13 and guide version 21**, separately from these actual package identities. ZIP version 13 and guide version 21 delivery is confirmed at **07:47:54 UTC on 8 October 2026**; the DMG version 13 is saved only and was not delivered.

The original broad-order recording fixture independently passes **1 warmup + 3 measured cycles** in each installed format, **4/4 controller/pipeline releases**, at **3.520847792 seconds ZIP / 3.097648708 seconds DMG**. This does not imply real screen/camera/microphone or long-session acceptance. The separate installed editor/pin lifecycle workload completes **10 warmups + 40 measured cycles**, with zero tracked retained app/content/cycle-window objects and **7→7 windows**. RSS changes are **+98,304 ZIP / −114,688 DMG bytes**, with zero last-ten-cycle growth; these follow earlier broad work, not clean startup. Other export/preview backing observations remain unresolved; the multi-window normalization change is not a universal decoder/cache remedy.

### Actual installed ARM ZIP production-default 4K resource evidence

The **509,161-byte** raw `multi-window-resource.json` verifies SHA-256 `dfad22bec971af2f8cbc3eb3a54d83985309c32a0c7250f7ecefa05a233823a1`; the **2,296-byte** checked report verifies `95f1854620926cbbbb223dcf74d118fd90eeaa78068a072bf15fcdcb7d69ad01`. Executable/source/version/build/bundle provenance matches the actual installed ZIP above. The fresh arm64 process runs on macOS **15.7.9 (24G830)** and completes **4 warmups + 12 measured cycles in 4.301986958 seconds**: two fresh **3840×2160 PNG decodes** per cycle, production composition into **4480×2520 RGBA**, with one set of prepared paths/pixels reused.

The raw and checked reports explicitly state **`compositionMode=productionCompositionMode=normalizedCandidate`**, **`compositionModeSource=productionDefault`**, **null diagnostic override**, **`candidateImplementation=vimage-canonical-cgimage-quartz-strips-v1`**, and **tracing/tail-first false**. The three-argument installed runner clears inherited selectors; this is the actual production default, not an explicit diagnostic mode relabeled as installed behavior. All 16 output digests match `5b8033659faae766800872f3684782128355a46fc4603aa5718e3134b2ac941d`.

Each complete cycle accounts for **111,513,600 peak explicit raster bytes**, below the **192,000,000-byte** admission, with two source/decoder/canonical images and two normalization operations, one output and at most one source input at a time. At release, input/decoder/output/canonical probes and source/canvas/normalization allocation counters return to zero, with zero owned descriptors. Separate acquisition cancellation releases its single input/decoder without output; native tests separately cover cancellation after the first Quartz strip. Temporary-directory and inode-bound descriptor cleanup and owned app exit pass. These are tracked ownership proofs, not accounting for every native allocation.

Absolute process boundaries are **bytes**. Fixture entry follows app startup and is not process birth; setup/PNG preparation and warmup remain outside the measured interval:

| Boundary | RSS | Physical footprint | Actual volatile resident / virtual | Compressed / volatile-compressed ledger |
| --- | ---: | ---: | --- | --- |
| Fixture entry | 69,992,448 | 20,432,896 | 0 / 0 | 0 / 0 |
| After PNG preparation | 114,311,168 | 22,841,408 | 0 / 0 | 0 / 0 |
| Warmup 1 released | 159,956,992 | 23,038,080 | 0 / 0 | 0 / 0 |
| Warmup 2 released | 160,038,912 | 22,136,960 | 0 / 0 | 0 / 0 |
| Warmup 3 released | 160,071,680 | 22,169,728 | 0 / 0 | 0 / 0 |
| Warmup 4 released | 160,104,448 | 22,202,496 | 0 / 0 | 0 / 0 |
| Measured cycle 12 released | 161,366,016 | 21,907,584 | 0 / 0 | 0 / 0 |
| Final after cleanup | 161,447,936 | 21,907,584 | 0 / 0 | 0 / 0 |

RSS rises **44,318,720 bytes (42.265625 MiB)** during input preparation, **45,793,280 (43.671875 MiB)** during warmup and **1,343,488 (1.28125 MiB)** from post-warmup through final cleanup: total entry-to-cleanup **91,455,488 bytes (87.21875 MiB)**. Final RSS remains **161,447,936 bytes (153.96875 MiB)**. Post-warmup footprint changes **−294,912 bytes (−0.28125 MiB)**; its entry-to-final change remains **+1,474,688 bytes**. Actual volatile resident/virtual and compressed counters have **zero net growth after warmup**, and all released cycle endpoints have zero actual volatile resident/virtual. This removes the earlier continuing final-band growth in this completed installed workload; it is not zero allocation or a general RSS plateau.

Last four measured increments retain the remaining positive RSS changes:

| Measured interval | RSS change bytes | Footprint change bytes | Actual volatile resident / virtual change |
| --- | ---: | ---: | --- |
| 8 → 9 | +98,304 | +65,536 | 0 / 0 |
| 9 → 10 | +49,152 | +32,768 | 0 / 0 |
| 10 → 11 | +32,768 | +32,768 | 0 / 0 |
| 11 → 12 | +49,152 | +49,152 | 0 / 0 |

Final cleanup after measured cycle 12 adds **81,920 RSS bytes**, with no footprint/volatile/compressed change. The **50 ms** sampler records **221 observations, including 86 timer samples**, with no missing-field counts. Sampled peak RSS is **194,510,848 bytes (185.5 MiB)**, while kernel lifetime peak RSS is **194,707,456 (185.6875 MiB)**. Sampled and kernel-lifetime footprint peaks both happen to be **101,386,432 bytes (about 96.690 MiB)** in this run; their scopes remain different. Transient sampled actual volatile resident/virtual reaches **33,177,600 bytes (31.640625 MiB)** while work is live, despite zero released endpoints. Kernel peaks include the whole fresh process lifetime; sampled fixture peaks may miss transients, and different counter maxima must not be summed.

Separate `TASK_VM_INFO`/`TASK_VM_INFO_PURGEABLE` calls are non-atomic; absent fields are never zero-filled. No system pressure/purge, actual pressure reclamation, GPU/WindowServer/foreign-process cost, real screenshot/TCC acquisition or sustained/maximum-size workload is established. The report correctly remains **`observed`**, **`memoryStabilityAssessed=false`**, **`plateauAssessed=false`**, **`zeroLeakClaim=false`**. **Acceptance is for this exact bounded implementation/workload**, with residual RSS/setup/warmup costs and broader preview-backing caveats retained. DMG has its own functional gate, not this repeated ZIP measurement. Intel has no corresponding build-102 installed/resource result.

### Production selection and exact admission

`MultiWindowCompositionMode.production` now selects `normalizedCandidate`, with report identity **`vimage-canonical-cgimage-quartz-strips-v1`**. Each source is color-managed once by `vImageBuffer_InitWithCGImage` with `kvImageNoAllocate` into owned RGBA8 premultiplied sRGB storage. A `CGDataProvider`/canonical `CGImage` borrows that allocation directly; the original Quartz context, transform, nearest interpolation, 128-row clipping and source-over blending remain. No CPU emulation of Quartz's sampling rule is used, and no full-canvas finish copy is added.

The provider release callback retains/releases the normalization allocation. Both weak canonical-image probes and allocation counters must return to zero before the next source, so disappearance of an image wrapper alone cannot hide a provider retaining storage. One source and one normalization exist at a time. Cancellation is checked before/after native conversion and between strips; native calls are not interruptible, and late results are rejected. The new first-strip cancellation native test is separate from the resource fixture's acquisition-cancellation check.

Source limits remain **8 selected windows, 1,024 inventory entries, 16,000,000 pixels/input, 64,000,000 total input pixels, 32,000,000 output pixels and 16,384 pixels per side**. Explicit live-raster admission is at most **192,000,000 bytes**, counting all three simultaneously admitted rasters:

- Canvas: output width × output height × 4
- Original source: actual image bytes-per-row × height, including padding
- Normalization: source width × source height × 4

Maximum-density layout preflight happens before allocating the canvas; actual source-stride admission happens before normalization. Individual dimension/pixel maxima do not guarantee the combined layout fits: **32 MP output + 16 MP source + normalization = 256,000,000 bytes** for tight RGBA, so it rejects. Some layouts accepted by the old baseline are intentionally refused under the unchanged 192,000,000-byte ceiling. For the 4K two-window fixture, **45,158,400 canvas + 33,177,600 source + 33,177,600 normalization = 111,513,600 bytes**; old baseline accounting was 78,336,000 bytes.

This is explicit raster admission, **not process RSS or a total memory cap**. Private Quartz, vImage, ColorSync, ImageIO, mapped-file, kernel and system-capture storage remain separately measured costs; `kvImageNoAllocate` does not prove that native internals allocate nothing. Source immutability, sequential window revalidation, child-only 80 MiB write cap, process reaping, temporary cleanup, 180-second selection and 20-second acquisition deadlines remain. Physical TCC/foreign-window/occlusion/Retina/multiple-display/Spaces behavior remains unverified.

The three-argument installed resource runner clears inherited composition, tail-first and tracing selectors, then requires **`compositionModeSource=productionDefault`**, **null diagnostic override**, **`compositionMode=productionCompositionMode=normalizedCandidate`**, and the canonical-image implementation identifier. Explicit four-argument diagnostic comparisons must declare their matching override. Ordinary capture does not read the fixture's diagnostic mode key. Current-source complete native/focused/model/UI and both installed-format gates now pass, with the fresh ZIP 4+12 actual-default proof below. Build-101 diagnostic results remain separate and do not substitute for those installed measurements.

## Diagnostic build 100 — CPU sampling rejected

Source [83406c0d4b0b613bb9175aa03fc299ef99003e7b](https://github.com/dandibbert/picshot/commit/83406c0d4b0b613bb9175aa03fc299ef99003e7b), [run 37734878796](https://github.com/dandibbert/picshot/actions/runs/37734878796), **build 100**, fails on both architectures. [ARM job 113172037858](https://github.com/dandibbert/picshot/actions/runs/37734878796/job/113172037858) ends **06:03:20 UTC**, [Intel job 113172038053](https://github.com/dandibbert/picshot/actions/runs/37734878796/job/113172038053) **06:14:30 UTC on 8 October 2026**. Each executes **32 source-scoped native tests: 31 passed, 1 failed, zero skipped**. All **27 portable checker tests** pass, but do not override the native failure. `continue-on-error` makes the native step summary look successful; the raw runner **exit 1** is authoritative, and the aggregate diagnostic correctly fails.

`testFractionalBoundsMixedDensityOrientationZOrderAndGapsMatchExactly` fails at the unchanged fractional density-3 **RGBA byte 24: baseline 62 / CPU candidate 73**. In the examined 8-to-13-pixel scaling case, destination X=6 lands on source edge 4; Quartz chooses source pixel 3 while the CPU prototype chooses 4. This is a counterexample, not a universal tie rule. The CPU implementation is rejected; no tolerance, expected byte or required case is loosened.

Four baseline controls per architecture each complete **4 warmups + 12 measurements**; candidate and candidate-traced cells are **skipped with exit 125** because native equivalence failed. Baseline and tail-first traces each contain **1,446 validated records**. All 24 measured input appends per traced cell match residuals of **1,720,320 bytes/input with the final 112-row band** or **1,966,080 bytes/input with a final 128-row band**. This gives **3,440,640 / 3,932,160 volatile-resident bytes per two-window cycle**, matching 2 × 3,840 × band height × 4. Decode-before-to-return boundaries add zero volatile bytes in those controls. This associates the measured residue with the final draw band in this workload; it does not locate private allocation ownership or prove stable memory.

ARM memory artifact **11531656082**, **531,489 bytes**, verifies SHA-256 `877f9d76d5ede59a13f28cf50d3cf5ebb8719405e0bdb05afac2e5e1390d1e5d`; Intel **11531623954**, **534,541 bytes**, verifies `d916409006add318a0b9cd6c6219cc0f3c43280bb1471325b8bf3e58ed3f7f58`. Production remains `coreGraphicsBaseline` in this diagnostic, no candidate memory cell runs and no installer is published.

## Diagnostic build 101 — normalized source, original Quartz drawing

Corrected source [00a1b9973571d8cef23aca6ba934daf52f2ed2e9](https://github.com/dandibbert/picshot/commit/00a1b9973571d8cef23aca6ba934daf52f2ed2e9), [run 37737735045](https://github.com/dandibbert/picshot/actions/runs/37737735045), **build 101**, passes its diagnostic jobs independently: [ARM 113181034601](https://github.com/dandibbert/picshot/actions/runs/37737735045/job/113181034601) at **06:35:43 UTC**, [Intel 113181034477](https://github.com/dandibbert/picshot/actions/runs/37737735045/job/113181034477) at **06:40:21 UTC**. Each native source-scoped suite passes **33/33, zero failures/skips**, with raw exit 0, no timeout or truncated log. The exact fractional failure case, 65,536 alpha-pair grid, profiles/byte orders/padding/decode arrays, ownership and first-Quartz-strip cancellation retain their exact checks. This isolated source scope excludes full AppMain/editor/package acceptance.

The corrected candidate is **`vimage-canonical-cgimage-quartz-strips-v1`**, not the rejected CPU prototype under the same experimental mode name. Production still reports **`coreGraphicsBaseline` at build 101**; candidate measurements require explicit diagnostic selection. Do not relabel them as the subsequent build-102 installed default.

| Build-101 evidence artifact | Bytes | Verified SHA-256 |
| --- | ---: | --- |
| ARM native 11532562127 | 4,011 | `1840d33c22a9b4db1e62ea56cca5d53a96ff3e9f7991882e020d85f397f07a44` |
| Intel native 11531659364 | 3,980 | `0579a789750aef7923b424b6be83b6727e8c01578e376ec2ea4cbc01aa18385d` |
| ARM memory 11532747489 | 863,757 | `4b6a49502351d9604047aaf4785bcb9fa77366bccfd1ab32eb4c45f4eb78be3b` |
| Intel memory 11532474513 | 873,815 | `58658b1be9b65542b7dd02b8fc55b666ae0487913ddcea8017a752a507d7687c` |

Both independently audited matrices complete **six distinct fresh, exited processes per architecture**, each with **4 warmups + 12 measured cycles**, matching input/output hashes and work: two fresh 3840×2160 PNG decodes and a 4480×2520 output each cycle. Baseline/tail-first traced cells validate **1,446 records**; candidate-traced validates **1,574** with complete topology and required counters. Canonical wrappers, normalization/provider allocations, source/decoder/output probes, descriptors and temporary roots clear; all **24 measured candidate traced input scopes** have zero ending volatile residual. Resource cancellation after one decoded input is distinct from the native first-strip cancellation test.

The following are **bytes**, post-warmup to final cleanup. Cells are separate processes and cannot be added or treated as a single lifecycle run:

| Architecture / cell | RSS change | Footprint change | Actual volatile-resident change | Volatile-virtual change |
| --- | ---: | ---: | ---: | ---: |
| ARM / baseline | +42,844,160 | +98,432 | +41,287,680 | +42,074,112 |
| ARM / tail-first | +49,037,312 | -884,672 | +47,185,920 | +47,972,352 |
| ARM / candidate | +1,261,568 | +540,672 | 0 | 0 |
| ARM / candidate-traced | +1,327,104 | +491,520 | 0 | 0 |
| Intel / baseline | +43,089,920 | +1,646,592 | +41,287,680 | +42,074,112 |
| Intel / tail-first | +48,922,624 | +1,654,784 | +47,185,920 | +47,972,352 |
| Intel / candidate | +1,167,360 | +1,019,904 | 0 | 0 |
| Intel / candidate-traced | +1,306,624 | +1,175,552 | 0 | 0 |

Candidate RSS boundaries, also bytes, retain setup and warmup rather than hiding them:

| Architecture / candidate cell | Entry | After PNG preparation | After four warmups | Final cleanup |
| --- | ---: | ---: | ---: | ---: |
| ARM / candidate | 69,763,072 | 114,098,176 | 159,891,456 | 161,153,024 |
| ARM / candidate-traced | 70,860,800 | 115,785,728 | 161,480,704 | 162,807,808 |
| Intel / candidate | 46,727,168 | 89,370,624 | 135,266,304 | 136,433,664 |
| Intel / candidate-traced | 48,328,704 | 89,436,160 | 135,307,264 | 136,613,888 |

The untraced ARM candidate still rises **91,389,952 bytes (87.15625 MiB) entry-to-cleanup**: **44,335,104 preparation + 45,793,280 warmup + 1,261,568 measured/cleanup**. The untraced Intel candidate rises **89,706,496 bytes**: **42,643,456 preparation + 45,895,680 warmup + 1,167,360 measured/cleanup**. Candidate final actual volatile resident/virtual are **16,384 / 16,384 bytes on ARM** and **0 / 0 on Intel** in both traced and untraced cells. Post-warmup and late volatile-resident/virtual changes are zero, while RSS/footprint remain positive. Baseline adds **41,287,680 volatile-resident bytes (39.375 MiB)** and tail-first adds **47,185,920 (45 MiB)** independently on each architecture.

Last four measured candidate increments are **RSS / footprint bytes**; volatile-resident/virtual changes are zero in every listed interval:

| Architecture / candidate cell | 8→9 | 9→10 | 10→11 | 11→12 |
| --- | --- | --- | --- | --- |
| ARM / candidate | +65,536 / +32,768 | +196,608 / +49,152 | +32,768 / +32,768 | +114,688 / +81,920 |
| ARM / candidate-traced | +65,536 / +65,536 | +65,536 / +65,536 | +65,536 / +49,152 | +49,152 / +32,768 |
| Intel / candidate | +77,824 / +77,824 | +90,112 / +57,344 | +69,632 / +69,632 | +69,632 / +69,632 |
| Intel / candidate-traced | +221,184 / +221,184 | +102,400 / +86,016 | +90,112 / +73,728 | +90,112 / +73,728 |

Sampled maxima and kernel lifetime high-water marks are different observations. Kernel peaks cover the entire fresh process lifetime; sample peaks cover captured fixture observations and may miss transients. They cannot be added or silently substituted:

| Architecture / candidate cell | Sampled RSS peak | Kernel RSS peak | Sampled footprint peak | Kernel footprint peak |
| --- | ---: | ---: | ---: | ---: |
| ARM / candidate | 194,232,320 | 194,428,928 | 83,396,928 | 99,666,240 |
| ARM / candidate-traced | 195,887,104 | 196,050,944 | 102,959,488 | 102,959,488 |
| Intel / candidate | 169,459,712 | 169,619,456 | 72,400,896 | 95,236,096 |
| Intel / candidate-traced | 169,697,280 | 169,848,832 | 72,769,536 | 96,763,904 |

Transient sampled actual volatile peaks remain **33,193,984 bytes on ARM / 33,177,600 on Intel** in candidate cells, despite zero measured endpoint growth. Candidate untraced/traced sampler totals are **207/204 observations (72/69 timer)** ARM and **273/275 (138/140 timer)** Intel, with no missing fields; phase counts are included in those totals. The untraced ARM candidate completes **3.647758708 seconds** versus baseline **5.429 seconds** in this fixed-order diagnostic; this is not a general product speed guarantee. Separate Mach calls are non-atomic; private graphics/decoder storage, actual pressure reclamation, GPU/WindowServer and long sessions remain outside the conclusion. Zero compressed fields and zero net volatile growth do not establish leak freedom or an overall RSS plateau.

The optional small sampling probe completes **1,211 cases / 141,304 axis positions on each architecture**. Both lower and upper tie choices occur, none of 21 arithmetic hypotheses matches all observations, and translation/clip-partition differences are zero in that finite probe. It explains why CPU sampling was not promoted; it is not a parity item, universal Quartz contract or installed acceptance evidence.

This comparison supports testing the production replacement for the observed final-band accumulation. **The later build-102 actual installed default has its own bounded acceptance above; this build-101 comparison remains diagnostic evidence.** Earlier build-99 growth and prior export/preview and physical-device caveats remain unchanged. ARM 0.14/Intel 0.11 were the accepted baselines at this diagnostic checkpoint; later ARM 0.15 acceptance is recorded separately above. See [MultiWindowNormalizationCandidate.md](MultiWindowNormalizationCandidate.md) for implementation and diagnostic procedure.

## Historical 0.15 build 99 — held for backing growth

Source [03cae2a31e5a37f32ca224d422b6690e25c6d7bb](https://github.com/dandibbert/picshot/commit/03cae2a31e5a37f32ca224d422b6690e25c6d7bb), **0.15.0/build 99**, belongs to [run 37727497419](https://github.com/dandibbert/picshot/actions/runs/37727497419), which ends **cancelled at 05:27:07 UTC on 8 October 2026**: ARM succeeds, while Intel is cancelled during final smoke. **0.15 acceptance, CAP promotion and delivery are held for continuing multi-window backing growth, despite ARM CI success.** Both architectures independently pass early actual installed-ZIP UI, all four capture/output components, **1,083 focused tests with zero skips** and separate abrupt recording recovery. Each architecture completes **1,561 ordinary cases: 1,558 passes + 3 documented pre-model skips**. Each architecture then passes **12/12 actual pinned-model tests with zero skips**. ARM passes both final actual ZIP/DMG functional gates. Its actual ZIP resource measurement completes with continuing RSS/volatile growth, as recorded below; exit-0 `observed` status is not resource acceptance. Intel's partial ZIP subreports pass, but overall launch/owned-exit/checker completion is absent; DMG and 4K resources are unrun. The accepted packages stay ARM 0.14 and Intel 0.11, with all prior counts unchanged. Build 98's **1,555 ordinary passes / 2 failed cases containing 4 assertions / 3 skips**, its separate focused and ARM child-bound passes, and Intel's early callout failure remain exact-source history below. No previous pass, package or measured resource result is relabeled as a build-99 result.

### Verified early ARM actual-ZIP scope

UI artifact **11528288761** verifies **7,589,097 bytes**, SHA-256 `59c0cab22070380fe5610fe853ea98d36d68c071c7d538456ccfe97581793f83`, with **207 CRC-safe entries**. Exact-source **16,767-byte** `capture-output/capture-output-workflow.json` verifies SHA-256 `dcb504400d0892332620add6e4b7ed7079d5122ac418860f1f98c6f1e6b399b7`, binding **03cae2a3 / 0.15.0 / build 99 / actual installed bundle**. Ratios, decoration, injected multi-window capture and original/current pin components each pass independently in this early run.

Independent source-crop comparison remains exact at **432 × 243**, and the saved ratio-file hashes match. All three element controls pass actual hit-target checks. Frozen **edge-light and edge-dark** decoration cases verify ratio/palette switching and immediate disappearance of the old decoration window; the non-frozen light/dark cases do not claim those boundary controls. Sampled native pixels show no repeat of the earlier cited control-layout issue. The existing ARM callout lifecycle fixture also passes in this process. These are owned synthetic native controls/source pixels, not real desktop/TCC/physical Retina or multiple-display proof. The later ARM focused results for idle layout and AnnotationEditing are recorded below. Complete native/model and final installed/resource gates remain required; none is replaced by this early UI pass.

### Independent early Intel actual-ZIP scope

Intel UI artifact **11528896466** verifies **7,761,386 bytes**, SHA-256 `dd4956253c85253bf5c90aa35eb53c9702e01732ce06146f94d8de9ee45b8b93`. Its **16,772-byte** combined capture/output report verifies SHA-256 `ff9dfcc5e9c65b4f90fa49f3addec74fa4577b99c60bf3479c6c27a8f24da82c`, binding exact **03cae2a3 / 0.15.0 / build 99 / installed bundle**, and records all four component passes independently of ARM.

The unchanged **2,000 ms** callout native-retirement gate completes **6/6 rapid cycles**. Maximum first-observed release is **1,778.051 ms**, largest sampling gap **873.679 ms**; app-owned graph and final native input/context counts are zero, and **12/12 controllers release**. These are sampled upper bounds in this early Intel process, not exact release latency, CPU attribution, a memory plateau or a final installed result. Build 98's failed 2,207.692 ms observation and unknown actual release time/cause remain intact below; the new pass does not retroactively clear that failed run. Intel's later independent native/model results and interrupted final smoke are recorded below.

### Verified ARM focused geometry correction

Focused artifact **11528971729** verifies **311,670 bytes**, SHA-256 `3713b760d173a7e1159c9a9212cd4e62fd09f60f0fbe81abf6a81f68c10a43cc`. Exact-source `critical-tests-report.json` records **1,561 discovered tests**, **1,083 selected/passed**, **zero skips**, across two disjoint processes of **555 + 528 cases**, exiting **0 in 226.575 / 170.029 seconds**. The original **420-second per-process cap** remains, with no forced signals or log truncation. Discovery is inventory, not an ordinary-suite pass; this is not a single shared-process suite, and overlapping focused/full/model totals are not additive.

Report SHA-256 is `ac937e3bc762a8a2dac593d9014bf48f74ad9f388c46b04cf00e8438ead6ae62`; plan is `a36844976c566c276e4a991fdb41e887bf834904f44734cde88c359389664edd`; discovery log is `61e32b0d0debee79f9d13c4ff29efe070b53527600982bc50ab22e3b15f3278a`. Process log hashes are `3acfd8d928f2fbee24838bad49ef09a24bad6ee1a62fd938e876fd8d842d1683` / `73d4e8220f7c02cd9c93cfcdcf40d153f32e7acc6f51510d75d06e1fab924799`.

All **15 AnnotationEditing cases** pass, including the formerly failing endpoint/nudge case (**0.165 seconds**) and zoomed resize/rotation/duplicate/undo case (**0.401 seconds**), with the original assertions unchanged. The new idle-cancellation geometry regression passes in **0.140 seconds**. The actual production **80 MiB** child-write test and initial-POSIX **2 KiB** test pass again at this source in **0.228 / 0.182 seconds**. These are ARM results; no current Intel native result is inferred. Separate abrupt installed-app recording recovery has passed its stage, and the later ordinary/model-stage results are recorded below. The later installed functional results and resource hold are recorded below.

### Independent Intel focused geometry and file-bound proof

Intel focused artifact **11528644501** verifies **312,715 bytes**, SHA-256 `8111c2ec8def07744d59c167d5a4f8a23af8444c744e79f178f921828e3712af`. Its exact-source report separately records **1,561 discovered / 1,083 selected and passed / zero skips**, in **555 + 528** disjoint processes that exit **0 in 381.420 / 319.629 seconds** under the original **420-second caps**, without forced signals or truncation. The annotation gesture expectations, idle-cancellation coordinate regression and actual **2 KiB / 80 MiB** child-shell byte-bound tests all pass on Intel; ARM results are not reused as Intel evidence. Separate abrupt installed-app recording recovery also passes its Intel stage. The later verified ordinary/model results and interrupted final smoke follow below.

Intel focused report SHA-256 is `b62805b32816bff9c2961b8aa098a9cb76c7b76ee5540ee9f6e705ad604bcc4b`. Its plan and discovery hashes match the same source inventory stated above; independent process log hashes are `580d51bd2e8094459e2237d27e477d6446cd6b74a04f003baeb5cb9a9b993e3f` / `033a938fc4c22db1f727d15ba2ebb1dae5160b45fbb97b29dd846626cfa55a8f`. These two native processes are not a shared-process suite or installed-resource/stability acceptance.

### Verified ARM ordinary coverage

Ordinary-test artifact **11529402198** verifies **395,913 bytes**, SHA-256 `6bac73f49385b257da0a338812705dc467444455c05c21334226c8f8d6bcd7a5`. Exact-source `test-report.json` selects all **1,561 discovered IDs** and records **1,558 passes + 3 documented pre-model skips**, zero failures, across disjoint **781 + 780** processes. Process 0 has **780 passes / 1 skip**; process 1 has **778 passes / 2 skips**. Their bounded runners exit **0 in 236.518 / 186.844 seconds**, under the unchanged **420-second per-process caps**, with no forced signal or log truncation. IDs are complete and disjoint; this does not turn them into a single shared-process suite or add focused/model totals as new coverage.

Ordinary report SHA-256 is `fec8728f8b389c34fe09b0083ed40ed2a1757ce17c5cf35ced61c00b56d7651a`; ordinary plan is `c6d073748b8e6c9e3a3de33c0094b8d5ee1ab0190ab9fec712d6b1564059c1c7`; discovery hash matches the focused inventory above. Process log hashes are `70311ba505b7e429c6711a69338012884952e990dc981ce4d562155c60d8ef33` / `ef406e572086f69e93d29518a62afadef53d69f2f0b037293513b562ed65683f`.

The three skipped IDs remain `PicShotMLHelperTests.FormulaEngineTests/testActualWeightsRecognizeFormulaFixtures`, `PicShotTableEngineTests.RecordedModelOutputTests/testNativeHelperWithRealWeightsWhenConfigured` and `PicShotEraseHelperTests.SmartEraseEngineTests/testRealCoreMLRemovesMarkedObjectAndPreservesOutsidePixels`. The subsequent configured actual pinned-model validation passes **12/12 cases with zero failures/skips**; `model-inference.log` verifies **4,310 bytes**, SHA-256 `71c4d17157b4d0fffcf224b815e746f856c018dce97446ceb7c9613d121323c7`. That later stage does not relabel ordinary skips as passes or add its overlapping cases to the ordinary total.

ARM's final actual ZIP/DMG functional smoke passes and the ZIP-only 4+12 fresh 4K PNG measurement completes, with exact evidence below. **Acceptance and delivery remain held for its continuing backing growth.** Intel's pinned-model step passes 12/12, but its final installed smoke is interrupted and its repeated-resource gate is unrun. CAP-07/11/14 and accepted architecture counts stay unchanged; completed CI/cleanup is not evidence that the resource issue is resolved.

### Independent Intel ordinary coverage

Intel ordinary artifact **11529129314** verifies **397,204 bytes**, SHA-256 `95255bce2560259f17e099c993f290bbc7f9d0627a8f237da93573d270734672`. Exact-source `test-report.json` covers all **1,561 selected/discovered IDs**: **1,558 passed, 3 documented pre-model skips, zero failures**, in **781 + 780** disjoint processes. Process 0 has **780 passes / 1 skip** and process 1 **778 passes / 2 skips**. The independent Intel runners exit **0 in 403.525 / 327.889 seconds**, each within the original **420-second cap**, without forced signals or log truncation. These passes do not borrow ARM's execution or establish installed-resource acceptance.

Intel ordinary report SHA-256 is `bc33cefa3c4c77db332a69039bd9b8cc98e496e7e4dc4f1464f0b06f1b7be5b7`; the plan/discovery hashes match the source inventory already recorded. Intel's process log hashes are `96d25628cd2b3a640b2d9fd825d1b603a7c7fed49a60575c9ab887a673a0827f` / `511f8042eb7fd0e8640b116e61184bd97f190107604429bb02a64aee2e338a25`. The same three specifically named model-fixture tests remain skipped in this ordinary stage. Its subsequent real pinned-model validation passes **12/12 with zero skips** at **05:19:26 UTC**. The **4,316-byte** `model-inference.log` verifies SHA-256 `98ef399af146b33c6d609c938055e27ff0296f9552b5a49a436cd74f197dd549`. Final Intel installed smoke starts at that same time but is later cancelled; the partial evidence and missing gates are recorded below. The ARM backing-growth release hold remains unchanged.

### ARM final installed functional evidence and candidate bytes

[ARM job 113148895818](https://github.com/dandibbert/picshot/actions/runs/37727497419/job/113148895818) starts at **04:26:41 UTC** and completes **success at 05:06:31 UTC on 8 October 2026**. This is terminal ARM CI success, with resource acceptance and delivery separately held. [Intel job 113148895900](https://github.com/dandibbert/picshot/actions/runs/37727497419/job/113148895900) starts at **04:26:37 UTC** and ends **cancelled at 05:27:06 UTC**. Its final smoke step is cancelled at **05:26:50 UTC**, **60 minutes 13 seconds** after job start; the overall run is cancelled at **05:27:07 UTC**. This timing is consistent with the unchanged **60-minute whole-job budget**. The log reports operation cancellation, without a product cooperative-deadline failure; it does not establish a narrower cause. The job-level interruption is separate from the successful **420-second native-test processes**.

ARM QA artifact **11529746938** verifies **23,821,187 bytes**, SHA-256 `6542deb81d80cbabf1a6dfe64350000c9fdc0814cfe6b35d984e92e2a998b9d3`, with **738 CRC-safe entries**. Both actual installed ZIP and DMG launch reports pass at **03cae2a3 / 0.15.0 / build 99** with confirmed owned exit. ZIP/DMG launch-report SHA-256 values are `d04d79cceaeb8345c5ba83c6da815716ac3f4148884b5dba5dad4f54eb759ba7` / `cf61f2410e1aa062541ae02fc02b81c5a0f3640cb697a010f7721c1f1cde8fa6`.

The broad recording fixture passes in its original installed ordering for each format, retaining **1 warmup + 3 measured cycles**, **4/4 pipelines/controllers released**, and **162 trace events / zero dropped**, with `fixture.end` passed. Elapsed fixture time is **2.907 seconds ZIP / 2.788 seconds DMG**. This is current-source ARM broad-context evidence, distinct from the earlier isolated 03e7080 diagnostic and the historical af11 Intel failure; no Intel broad-recording result is inferred.

| Actual ARM candidate file | Bytes | SHA-256 |
| --- | ---: | --- |
| PicShot-0.15.0-macos-arm64.zip | 18,625,171 | `31a605e11b819ed36a0689d3f9261e98a2829d16a64e37bcf01984a1f13adb25` |
| PicShot-0.15.0-macos-arm64.dmg | 21,473,448 | `dfbf0a43fb53a0bbfad69273c6ab123d2ef834a91789567faecb07c051a79e14` |

The actual ZIP's **70 entries** pass CRC, and embedded version/build/source metadata agrees. Its **18,959,808-byte executable** verifies SHA-256 `8e7370586e1e05824f1e32af2abf02747d5ee644097f3e1e7e949a8b8634395d`. Metadata identifies arm64, macOS 14 minimum, ad-hoc signing and not notarized; those are not Developer ID, Gatekeeper or minimum-runtime acceptance. These are verified **candidate bytes**, not accepted/delivered replacements. There is no 0.15 Library save or delivery claimed.

### Intel final-smoke interruption and partial ZIP evidence

Intel QA artifact **11530781319** verifies **15,978,837 bytes**, SHA-256 `3e155fba26ddb68d31837ab1475e701db0f0427886c9546c2cf4bc926b2f1b68`, with **483 verified entries**. The partial actual-ZIP **16,782-byte** `capture-output-workflow.json` binds **03cae2a3 / 0.15.0 / build 99 / installed ZIP bundle** and records all four components passed; its SHA-256 is `0d120da39d03f9f96242d2bd4eef2e8dcbb0a98bfeeb0f051b29f2de56694b2e`. This is separate from the earlier UI-only ZIP launch.

The original broad-order recording component also passes in **4.268478372 seconds**, completing **1 warmup + 3 measured cycles**, with **4/4 pipeline and controller releases**, zero retained writer frame references/latest camera slots, and owned recording-root cleanup. Its **12,377-byte** recording report verifies SHA-256 `04a20d2c2cb8c792740ee7a3f6f2fa6ad85a093db184c03ba199e52908738e8d`. The **63,940-byte** trace verifies SHA-256 `2c1039cf9b09bd691c613ea1ea0db94343cae97e9b1c79cab0cc6b30bfa1b06c`, recording **162 events / zero dropped** and completed fixture end. This current-source Intel component pass does not identify the historical af11 failure's cause or replace complete launch acceptance.

**Overall ZIP launch completion and owned app exit are absent.** The aggregate final gate and later checker steps are incomplete. **DMG evidence and the 4K repeated multi-window report are absent/unrun**, and installer uploads are skipped. Do not convert successful component reports or whole-job cancellation into either complete installed acceptance or a product-specific timeout diagnosis. Accepted/delivered Intel remains 0.11/build 69; no ARM measurements or installer result are transferred to it.

### Actual ARM ZIP 4K multi-window measurements — release held

`multi-window-resource.json` verifies **514,491 bytes**, SHA-256 `a3c5f80ff8d25ce70cece0e6f0b46b8e80ca783f3f0ec4dfd5c4240ff2e4a488`; `checked-resource.json` is **2,181 bytes**, SHA-256 `677ddda2585abfa2119b3ddacac505cb8901806d4a3f6ed5d087746d80491144`. Provenance binds the actual installed ZIP executable above, **03cae2a3 / 0.15.0 / build 99**, arm64 macOS **15.7.9 (24G830)**, in a fresh resource process distinct from broad smoke. The fixture completes **4 warmups + 12 measured cycles in 4.947847458 seconds**, two fresh **3840 × 2160 PNG decodes** per cycle, production sequential composition into **4480 × 2520 RGBA**, with the same two prepared PNG paths/pixels reused. No system screenshot command or live/TCC acquisition runs.

All 16 output digests equal `5b8033659faae766800872f3684782128355a46fc4603aa5718e3134b2ac941d`. Every cycle creates two input images, two ImageIO decoders and one output, observes at most one input at a time, then releases every probed object and leaves zero owned open descriptors. Separate cancellation releases its one acquired input/decoder and creates no output. Final private-directory and inode-bound descriptor cleanup pass, and owned app exit is confirmed. The workload's one-source-plus-canvas bound is **78,336,000 owned raster bytes**; these checks do not account for all ImageIO/CoreGraphics/kernel backing.

Absolute boundary values below are **bytes**, from separately sampled process counters. Fixture entry follows app startup and is not process birth. Input preparation includes PNG generation/encoding; its source scopes have exited before the pre-warmup boundary.

| Boundary | RSS | Physical footprint | Actual volatile resident | Volatile virtual |
| --- | ---: | ---: | ---: | ---: |
| Fixture entry, before input preparation | 70,041,600 | 20,695,232 | 0 | 0 |
| After input preparation, before warmup | 113,475,584 | 22,120,768 | 0 | 0 |
| Warmup 1 released | 162,660,352 | 22,415,744 | 3,457,024 | 3,522,560 |
| Warmup 2 released | 166,248,448 | 22,497,664 | 6,897,664 | 7,028,736 |
| Warmup 3 released | 169,738,240 | 22,546,816 | 10,338,304 | 10,534,912 |
| After warmup 4 / measured baseline | 173,228,032 | 22,595,968 | 13,778,944 | 14,041,088 |
| Measured cycle 12 released | 216,268,800 | 23,202,176 | 55,066,624 | 56,115,200 |
| Final after cancellation and cleanup | 216,350,720 | 22,874,496 | 55,066,624 | 56,115,200 |

Preparation adds **43,433,984 RSS / 1,425,536 footprint bytes**, with zero volatile growth. The four warmups then add **59,752,448 RSS / 475,200 footprint / 13,778,944 actual volatile-resident bytes**. Post-warmup-to-final changes are **+43,122,688 RSS (41.125 MiB), +278,528 footprint (0.265625 MiB), +41,287,680 actual volatile resident (39.375 MiB), and +42,074,112 volatile virtual bytes**. Final RSS is **206.328125 MiB** and actual volatile resident **52.515625 MiB**. Process compressed and compressed volatile-ledger counters stay **zero at all recorded boundaries and sampled peaks**; that does not prove release or account for the positive volatile growth.

Every one of the 12 measured cycles adds **3,440,640 actual volatile-resident bytes (3.28125 MiB)** over the prior released endpoint. The last four exact increments remain positive:

| Measured interval | RSS change bytes | Footprint change bytes | Actual volatile-resident change bytes | Volatile-virtual change bytes |
| --- | ---: | ---: | ---: | ---: |
| 8 → 9 | +3,538,944 | +81,920 | +3,440,640 | +3,506,176 |
| 9 → 10 | +3,457,024 | −49,152 | +3,440,640 | +3,506,176 |
| 10 → 11 | +3,538,944 | +98,304 | +3,440,640 | +3,506,176 |
| 11 → 12 | +3,932,160 | +475,136 | +3,440,640 | +3,506,176 |

After the last measured endpoint, cancellation/cleanup changes RSS **+81,920**, footprint **−327,680**, and volatile resident/virtual **zero**. The accumulated backing therefore remains at final cleanup. This is continuing growth in a short bounded workload, not a demonstrated long-session plateau or a native allocator diagnosis.

The **50 ms** sampler records **233 aggregate samples, including 98 timer samples**, with no missing-field counts. Whole-fixture sampled peaks are **247,873,536 RSS / 102,123,968 footprint / 64,159,744 actual volatile-resident / 64,749,568 volatile-virtual bytes**. Setup/warmup/measured/cancellation/cleanup are included; their phase counts must not be added again to whole-run totals. Maxima occur at potentially different moments and must not be summed. Timer sampling may miss transients; separate `TASK_VM_INFO` and `TASK_VM_INFO_PURGEABLE` calls are non-atomic. Missing fields are not zero-filled, and observed zero compression is not backing-reclamation evidence.

The report/checker say **`status=observed`, `observationsComplete=true`**, with **`memoryStabilityAssessed=false`, `plateauAssessed=false`, `zeroLeakClaim=false`**. No memory pressure or purge was requested; actual pressure reclamation, total native allocation ownership and whole-system/GPU/WindowServer effects were not measured. This measurement-completeness contract passed while **release remains held after review of the continuing growth**. **0.15 delivery and all CAP/count promotions stay held; ARM 0.14 and Intel 0.11 remain accepted.** The fresh attribution/caller-owned conversion comparison is separate pending diagnostic work and supplies no demonstrated remedy yet. This ZIP result does not establish a repeated DMG measurement.

### Source correction and remaining gates

`ImageEditorController.cancelDecorationWork()` now records whether a projection ticket or decoration palette existed before cancellation, and calls `updateStatus()` only when work existed and the editor remains open. An idle cancellation still invalidates stale generation state but does not trigger layout between mouse-down's recorded window coordinates and source-pixel conversion. Active cancellation continues to cancel the worker/palette and hold its reservation until operation/completion drain. This scoped implementation change does not claim to solve every interaction or memory issue.

`EditorOutputProjectionTests.testIdleCancellationDoesNotMoveZoomedCanvasBeforeMouseCoordinateConversion` records canvas geometry and a window-space point at **0.5× and 2× zoom**, calls idle cancellation, and requires exact unchanged frame/coordinate conversion with no pending projection. The existing `AnnotationEditingTests` are added to the early focused selection, including the two cases that failed in build 98. Their expected resize/endpoint geometry is unchanged; no tolerance, native callout-retirement proof or deadline is relaxed. The authored regression and all 15 AnnotationEditing cases now have independent current-source ARM and Intel focused results above; their addition to the test plan alone was not execution evidence.

All acceptance decisions remain held: **ARM 0.14 / Intel 0.11**, **CAP-07 Partial / CAP-11 and CAP-14 Missing**, and all accepted counts are unchanged. Current-source complete ordinary/focused/model and actual ZIP/DMG gates must pass independently, with real screenshots reviewed and skipped/failed/unrun stages kept separate. The ZIP-only 4+12 fresh 4K PNG phase now supplies those ARM measurements above, including continuing late growth; Intel and any proposed remedy require independent complete measurements. `observed` means complete resource measurements, not a plateau, reclaimability or leak-free/stable-memory acceptance. No accepted 0.15 package, saved replacement or delivery exists at this checkpoint.

## Historical 0.15 build 98 — final acceptance failed

Source [9ac2e02cb5e9a4ea4fecd1e60a2f28a711c56d26](https://github.com/dandibbert/picshot/commit/9ac2e02cb5e9a4ea4fecd1e60a2f28a711c56d26), **0.15.0/build 98**, has failed verification in [run 37724473381](https://github.com/dandibbert/picshot/actions/runs/37724473381). The run completed **failure at 04:21:43 UTC on 8 October 2026**. ARM passed early actual installed-ZIP UI, backing/debug stages, the complete **1,067-test focused selection**, and abrupt installed-app recording recovery, then failed ordinary native tests as detailed below. Model and final actual installed ZIP/DMG/resource gates and installer uploads were not reached. Intel failed early UI on the existing callout native input/context deadline before its capture/output components; all later native/model/final installed/resource gates are unrun. Build 96's early failures and build 97's ARM focused failures/Intel interrupted suite remain source-qualified history below. No result transfers between those binaries, and accepted ARM 0.14/Intel 0.11, CAP-07/11/14 states and counts remain unchanged.

### Early actual ARM ZIP evidence and corrected UI scope

The fresh ARM UI artifact **11527647423** verifies **7,590,899 bytes**, SHA-256 `737eb915be8b2753b0d54db7e035a5ce67f930828e69ac715d4c2bc90ec06069`, and **207 entries**. Its **16,767-byte** `capture-output/capture-output-workflow.json` verifies SHA-256 `871149629a42c4d5ae43ea61bd611f264cf1775cbcd72b617aadf36d5f41ddc4`, binds exact **9ac2e02c / 0.15.0 / build 98 / installed bundle path**, and records all four components passing. No desktop pixels, permission request, general-pasteboard change or standard-defaults change occurs. The verified archive/report identity is separate from complete later gate metadata; this combined report is not final installed acceptance or a repeated 4K resource result.

Owner and independent fresh-screenshot review confirm that `capture-elements-native.png` now places three distinct element-selection buttons along the bottom row. The updated fixture checks their real hit targets and lack of overlap, rather than relying on programmatic action alone. `capture-presets-elements.json` is **1,533 bytes**, SHA-256 `ae6d1a75e6692663c74ec734591403d1df22c7a9be31e3c707f1cf79ff6e3b8e`. Its passed synthetic native controls do not establish foreign-app AX/TCC, physical Retina/multiple displays or live delayed capture.

Both frozen **edge-light and edge-dark** decoration cases record **`ratioDecorationSwitchVerified=true`**. The installed fixture asserts that switching to ratio controls immediately hides the old decoration window. The non-frozen light/dark cases record this switch flag false because frozen capture-boundary ratio controls do not apply to those cases; they are not silently counted as two more switch checks. Each decoration case retains exact **666 × 426 output**, metadata undo/cancel, original pixels/annotation anchors, original-aware pin callback and PNG round-trip checks. UI fixture input and snapshots remain owned/synthetic; no physical-device claim follows.

### Verified ARM focused selection and child file bound

Focused artifact **11527024323** verifies **309,288 bytes**, SHA-256 `e7f7da8d70b72317eb219c5109b7d0a8344d2a610d309f69329c50da1746ecf9`. Exact-source `critical-tests-report.json` records **1,560 discovered tests**, **1,067 selected and passed**, **zero skips**, across **two disjoint native processes of 554 and 513 tests**. The bounded processes exit **0 in 245.765 / 197.260 seconds**, each under the original **420-second limit**, without forced signals or log truncation. This is exhaustive coverage of the focused selection, not execution of all 1,560 discovered tests or a single shared-process suite. Focused/full/model coverage overlaps and is never added into a distinct-test total.

Report SHA-256 is `ba64819063e862ac2781f168b74792d3666fe6e42d2e1020f7fc1f07531a1362`; plan is `35093268f8f6f8b2896a9453def95d02720a1b365a6f93780c3ce5f72ae7935d`; discovery log is `117b57db7ae2431b5673f2ef55245f8afffe822e61fa06f6cb1dbfd5aaa434de`. Process log hashes are `30f3a45a87a6452dc2ea96d980e6440e9c7ab7344890d9075a468023bee015e4` / `783928ad8631993a86b412601d07c67a168076edb37c41a9c451c60bbfbd567c`.

The actual native `testNativeShellEnforcesProduction80MiBFileLimit` passes in **0.230 seconds**: a finite attempted **81 MiB** write stops at exactly **80 MiB**, and the child cannot raise its soft limit above the configured hard limit. The initial-POSIX **2 KiB** test passes in **0.277 seconds**. `testRatioAndDecorationPalettesAreMutuallyExclusiveAndRatioEditCancelsDraft` passes in **0.400 seconds**. These are current-source ARM fixes for the specific earlier failures. Intel did not reach native tests, so no Intel byte-bound/palette pass is inferred. Abrupt installed-app recording recovery also passed its separate stage. Exact-source `recovery.json` is **532 bytes**, SHA-256 `ff5c8d1a6dccb6e49a7236c1588907e1970e7853284dae480063f0c8fd676dc9`: **5 seconds / 5 fragments / 50 decoded video frames / 239,552 decoded audio frames** recover after terminating the owned synthetic child with **SIGKILL 9**. Its exit, source preservation, preview-journal recovery and temporary-directory cleanup pass, with no screen/camera/microphone capture started. This does not replace final broad recording or installed-format/resource gates.

### ARM ordinary native failure and unreached final gates

[ARM job 113139577329](https://github.com/dandibbert/picshot/actions/runs/37724473381/job/113139577329) executes **two 780-case ordinary processes**, covering all **1,560 selected IDs**: **1,555 passed, 2 failed test cases containing 4 failed assertions, and 3 documented pre-model skips**. Process 0 records **one documented pre-model skip and zero failures**; process 1 records **two documented pre-model skips and four failed assertions across two tests**. Their bounded runners exit **0 / 1 in 248.091 / 220.803 seconds**, respectively, each under the unchanged **420-second cap**, without forced signals or log truncation. The stage is failed, despite complete selected-ID coverage. The three skips remain `FormulaEngineTests.testActualWeightsRecognizeFormulaFixtures`, `RecordedModelOutputTests.testNativeHelperWithRealWeightsWhenConfigured` and `SmartEraseEngineTests.testRealCoreMLRemovesMarkedObjectAndPreservesOutsidePixels`; the later actual-model stage never ran, so none becomes a pass.

Final ARM QA artifact **11528735153** verifies **9,390,041 bytes**, SHA-256 `8d9be21cdda0f3db1d014f791272f20e6d01f890d7fa73556ce29045ae353bb0`, with **311 CRC-safe entries**. The ordinary plan hash is `34cc9109b81a2425f217cecf215e33adfd6045d301893262f98ed48bd1ee350d`; ordinary process log hashes are `37250b0ab08278b5b9a443d31f38a2e280a925a1050bd9b70c270553632ce03a` / `b38536516a595f84912b897bef223e52d1eb73a380c5096464ad2d0deba99f8f`.

The failures are `AnnotationEditingTests.testNativeZoomedResizeRotationDuplicateAndRepeatedUndoRedo` at line **146**, and `AnnotationEditingTests.testNativeLineEndpointGestureAndNudgeUseImagePixels` at lines **177, 179 and 181**. The resized rectangle is **(120, 130, 60, 37.5)** instead of **(40, 40, 140, 90)**. The endpoint's initial source coordinate is **(0, 0)** instead of **(40, 40)**, with corresponding nudge/resize expectation mismatches. These are source-qualified synthetic native gesture assertions; the report does not independently establish a physical-input cause. Four assertion failures are not four failed test cases.

The actual-model stage, final broad installed ZIP/DMG smoke, full-context recording trace, repeated 4K multi-window resource measurements and installer uploads are **unrun**. The focused pass, abrupt recovery, early UI corrections and ARM shell-cap proof remain useful partial evidence, but they do not override the ordinary gate failure or justify a 0.15 package acceptance, CAP promotion or count change.

### Independent Intel early callout failure

[Intel job 113139577511](https://github.com/dandibbert/picshot/actions/runs/37724473381/job/113139577511) fails its early installed-ZIP UI gate before the new capture/output fixture and all downstream gates. UI artifact **11528035688** verifies **5,956,371 bytes**, SHA-256 `bc164f63dfadb56723f579cfd4e24647d20ffd586c391edc1b4e77a26095b3b8`. The existing callout native input/context contract retains its **2,000 ms deadline**. In cycle 1 the last retained sample is **757.032 ms after close**, and the first observed released sample is **2,207.692 ms**, leaving a **1,450.660 ms sampling gap**. Actual release occurred somewhere within that interval; its exact time and the failure cause are unknown. This is a failed deadline observation, not proof of the exact deallocation time or a measured CPU/scheduling diagnosis.

The fixture creates **3 of the intended 6 rapid cycles** before stopping. App-owned/text graph counts are zero, while **2 native input objects and 2 native contexts** remain pending at stop; later retirement is not established by this failed report. The callout source is unchanged from build 97, whose early Intel maximum observed release time was **1,406.505 ms**, but that earlier pass cannot replace current-source/current-process evidence. No automatic retry or timeout expansion is used to call this run passing. Intel remains accepted at 0.11 until its own complete exact-source gates pass.

### Corrected implementation and outstanding native gates

The source correction defers the initial selector layout until all element controls exist and strengthens the owned hit-target/nonoverlap assertions. Decoration cancellation closes the owned window immediately, while its queued/running worker still retains the projection reservation until operation and completion drain; immediate visual dismissal is separate from final memory/object release.

The screenshot child prelude now explicitly disables POSIX mode and sets **both hard and soft file-size limits in 1,024-byte units**, only inside the owned child before exec. It does not modify PicShot's or the system's persistent limits. `testNativeShellFileLimitUses1024ByteBlocks` first enables POSIX mode, then invokes the production prelude for a **2,048-byte** limit and attempts one finite **4,096-byte** write. `testNativeShellEnforcesProduction80MiBFileLimit` uses the unmodified live prelude and attempts **81 × 1 MiB**, requiring a failed child and exact **80 MiB** file. These finite writes remain bounded even if the limit breaks. Both current-source native byte-bound tests are now verified on ARM as recorded above; Intel remains unrun. This establishes the owned child limit for that ARM runtime, not a system-wide/process-RSS bound or real screenshot/TCC acquisition. The independent post-capture accepted-file limit remains a separate check.

Acceptance of a corrected candidate still requires exact-source passing ordinary/focused/model stages with discovery/shard/skip accounting, prior feature and recording/recovery gates, both installed formats and ZIP-only **4 warmups + 12 measured fresh 4K PNG production-composition cycles**. This failed run does not satisfy that complete gate set. Complete resource observations must preserve setup/warmup/final values, late increments, sampler counts/failures, workload/process/format provenance and distinct RSS/physical-footprint/actual-volatile/compressed fields. `observed` does not establish a plateau, zero leaks, pressure reclamation or sustained stability. No current-source final resource figures or 0.15 acceptance/persistence/delivery exist for this failed run.

## Historical 0.15 build 97 — ARM failed, Intel interrupted

Corrected source [4c892ae94e23c62bdf60f00b5c756ed6d5d3da95](https://github.com/dandibbert/picshot/commit/4c892ae94e23c62bdf60f00b5c756ed6d5d3da95), **0.15.0/build 97**, was tested in [run 37721821786](https://github.com/dandibbert/picshot/actions/runs/37721821786). Build 96's two terminal early-UI failures, exact artifact hashes and unreached gates are retained below. Both architectures passed the **early actual installed-ZIP UI stage**, including the source-bound capture/output checker; ARM did so at about **03:25:57 UTC on 8 October 2026**. ARM then failed its first focused native shard, as detailed below; later complete native suites/model and final installed ZIP/DMG/repeated-resource gates were not reached. The overall run ended **cancelled at 03:49:20 UTC on 8 October 2026**. Intel had passed early UI/backing/debug/native-test compilation, then recorded the same palette assertion before cancellation during focused execution; its suite did not complete. This early ARM result cannot replace either architecture's final gates or establish 0.15 acceptance, persistence or delivery.

Early ARM UI artifact **11526700449** verifies **7,537,964 bytes**, SHA-256 `e5c6466dc67b36d085eeb4388bc52178326e37aa8b4efc2606b6cf28dcb200fe`; all **205 archive entries** pass CRC and safe extraction. Its **16,573-byte** `capture-output/capture-output-workflow.json` has SHA-256 `cc18e29579d89f610e3ab119d9131237c3a1f4eb0ed263c88d440347c20780db` and binds source **4c892ae9**, version **0.15.0**, build **97** and the actual installed bundle path. All four component reports pass. The independent review decodes **28 component PNGs**, checks **11 ratio PNG hashes** and confirms the exact **432 × 243 source crop**. These are early actual-ZIP synthetic results:

- Ratios: selector/editor/multi-region/four-edge checks, immutable source digest and **7 closed/released owned windows**, at most one concurrent fixture window. The **1397 × 911** source over **1000 × 700 logical points** exercises independent fractional X/Y source densities. The actual native display/snapshot remains **1×**, so this is not physical Retina evidence.
- Decoration: four light/dark/edge cases each produce exact **666 × 426 PNG** output, with source/annotation anchors retained, metadata Apply/undo/redo, draft cancel and original-aware pin callbacks. Across the fixture **9 projections start and complete**, leaving zero active jobs, reserved bytes and queued operations. These bounded small-image UI/output and cleanup checks do not establish a process-memory plateau or the large-image admission ceiling at runtime.
- Multiple windows: **2 completed captures and 4 cancellations** reuse the owned controller; **6 cleanup checks**, zero retained selectors/visible retired panels and no late permission-provider call. The report checks **317,200 exact RGBA pixels**, including **62,000 overlap**, **5,120 translucent** and **56,976 transparent pixels**. Providers are injected; the system screenshot command, live capture and TCC are not exercised.
- Original/current pins: separate immutable assets restore exact current/source pixels after the temporary store/controllers are recreated; **2 controllers release**, and the private storage directory is removed. This is a fixture-level store recreation, not an application restart or physical user workflow.

**Visual review at 4c892ae9 found a regression:** `capture-elements-native.png` shows legacy element-selection buttons overlapping at the top left. The early fixture's programmatic button calls did not check their clickable layout, so its functional pass is not clean UI acceptance. The later 9ac2e02c correction has its own early visual verification above; it does not erase this failed 4c892ae9 layout. No final visual or release gate is waived, and no repeated multi-window resource measurement ran at 4c892ae9.

**ARM focused native failure at 4c892ae9:** [job 113130974140](https://github.com/dandibbert/picshot/actions/runs/37721821786/job/113130974140) completes its first selected shard with **553 tests and 2 failures, zero unexpected failures**, in **245.968 seconds** of XCTest time. Its bounded process exits **1 after 250.512 seconds**, under the unchanged **420-second cap**, with no forced signal or log truncation. This is an assertion failure, not a timeout or a complete focused-suite pass. ARM discovery contains **1,559 tests**; its focused plan selects **1,066 IDs across 553 + 513 disjoint shards**. Discovery and selection counts are not executed passes, and the second shard is unrun. The second focused shard, ordinary/full suite, actual-model stage, abrupt recovery, final installed ZIP/DMG/broad recording and repeated 4K multi-window resources are unrun on ARM.

- `EditorOutputProjectionTests.testRatioAndDecorationPalettesAreMutuallyExclusiveAndRatioEditCancelsDraft` fails the `XCTAssertFalse` at line 231. The intended ratio/decorations palette exclusivity flow is therefore not fully verified, despite the early component fixture pass.
- `MultiWindowScreenshotCommandTests.testNativePOSIXShellFileLimitIsBytesNotAddressSpace` fails at line 33: the actual installed shell and production prelude allow **2,048 bytes**, versus the expected **1,024 bytes** for two configured units. This disproves the code's **512-byte shell-unit assumption** on this runtime. The intended **80 MiB OS-enforced file-write cap must not be claimed as established** at this source. Post-capture file-size validation retains its 80 MiB admission check, but that is distinct from the subprocess write limit. A corrected implementation and native assertion are required; the existing test is not weakened or converted into a pass.

The failed first ARM shard separately passes all **6 `EditorOutputPinRecoveryTests`**, with zero failures in **2.949 seconds**: decorated count and pixel-quota rejection, undecorated count rejection, raster-write failure and retry, manifest-commit failure with rollback of both staged PNGs, and legacy callback completion before the frozen editor closes. These verify source-qualified native exceptional pin paths without converting the containing failed shard into a pass or replacing final installed checks.

These failures and the independent visual-layout issue hold candidate acceptance. Early successful components remain valid only for their stated source/workload; they do not override the failed focused gate.

`CapturePresetsElementsSmokeFixture` now sends the actual **Tab key** to hide selector controls, verifies that the original manual gesture point hits `RegionSelectionView`, then uses the existing gesture and unchanged exact expected **origin (300, 120), size 50.5 × 40.5 logical rectangle**. This retains the source-pixel/Retina geometry requirement while exercising a real user route to pixels under the controls. `RegionSelectionView.refreshRatioControls()` hides numeric dimensions and Use-selection confirmation until precision editing has a valid selection. The initial picker still presents the ratio choice and help. The new `CaptureRatioInteractionTests.testInitialPickerHidesUnusedDimensionsAndConfirmationUntilSelection` checks initial visibility and native hit testing, then selects 16:9, drags and requires visible/enabled precision controls. Authored regression source and the unchanged assertion are not an executed native pass.

The new run must independently establish release/debug/test compilation as configured; exhaustive/focused/model results with original discovery/shard/skip accounting; early owned synthetic light/dark/edge UI review; final actual ZIP/DMG component, prior-feature/model and cleanup gates; and the ZIP-only fresh-process **4 warmup + 12 measured 4K PNG production-composition workload**. No threshold, deadline, pixel expectation or measurement contract is relaxed. The current full smoke retains opt-in recording tracing in the original broad ordering, with the old af11 Intel recording failure still unresolved by the separate 03e7080 recording-only pass.

**Accepted ARM 0.14 and Intel 0.11, CAP-07/11/14 classifications and all counts remain unchanged.** The implementation inventory and required measurement contract below are inherited candidate scope, not transferred execution evidence. Preserve RSS, physical footprint, actual volatile resident/virtual and compressed backing separately; record actual pre-warmup/post-warmup/final values, warmup growth and late increments when available. `status=observed` remains measurement completeness with stability/plateau/zero-leak claims false. Native fixtures use owned synthetic input, so physical Retina, TCC, real windows, multiple displays/Spaces and sustained resources still require separate acceptance.

## Historical 0.15 build-96 candidate at e48e21c — early gates failed

Candidate source [e48e21c2ffd747a6dd864c0f2074a97853890740](https://github.com/dandibbert/picshot/commit/e48e21c2ffd747a6dd864c0f2074a97853890740), **0.15.0/build 96**, failed its early installed UI gates in [run 37720419126](https://github.com/dandibbert/picshot/actions/runs/37720419126), attempt 1. The run completed **failure at 03:11:15 UTC on 8 October 2026**. [ARM job 113126543469](https://github.com/dandibbert/picshot/actions/runs/37720419126/job/113126543469) and [Intel job 113126543687](https://github.com/dandibbert/picshot/actions/runs/37720419126/job/113126543687) each passed **140 harness tests (25 + 36 + 58 + 21)** and packaged native 0.15.0 successfully. ARM DMG image CRC verification also succeeded. These are harness/packaging results, not completed native test suites. At **03:04:34 UTC on ARM / 03:11:02 UTC on Intel**, the early actual installed-ZIP UI gate stopped on the same **“Capture presets/elements fixture: Manual rectangle fallback did not preserve Retina geometry.”** Backing/debug/test compilation, focused/full/model, abrupt recovery, broad recording, final installed/resource and installer-upload stages were skipped on both architectures.

Both UI evidence archives passed exact size/SHA-256, all **54 ZIP entries per architecture** passed CRC and safe-path checks, and each `preview.json` records the same failure:

| Architecture | UI artifact | Bytes | Verified archive SHA-256 |
| --- | --- | ---: | --- |
| ARM | 11526415187 | 3,206,248 | `d29c32a4115a6bc1531567d4f31a604b80cb8f52163e7267859bb7a207fce937` |
| Intel | 11526197081 | 3,372,670 | `c57a05d9e68da5f859b49682460e4720d3ff29abe9b7f82a372855e02e42e7cd` |

**Neither archive contains capture/output component directories or reports:** the early UI sequence stops inside `CaptureExportRecognition` before `CaptureOutputWorkflowFixture`. The new ratios/decoration/multi-window/original-current-pin components and their checker are **unrun**, rather than failed. The assertion concerns an owned synthetic geometry fixture, not a physical Retina capture result. QA artifacts **11525692430 ARM / 11525907856 Intel** were also published; evidence upload does not establish the skipped gates or acceptance.

Final ordinary/focused/model counts, complete synthetic visual review, installed ZIP/DMG functional checks and installed ZIP repeated measurements remain unestablished for this source. Authored tests, a packaged app and passing script checks do not supply those results.

**The accepted/delivered boundaries below remain ARM 0.14/build 94/af11 and Intel 0.11/build 69/3f013417.** There is no 0.15 acceptance, Library save or delivery claimed. CAP-07/11/14 and the accepted architecture counts remain unchanged. All original 133 requirements, citations, checks and earlier evidence are retained. New evidence must bind the exact source, version, build, architecture, installed format, executable and report/artifact hashes; early, diagnostic and final installed stages cannot substitute for each other.

### Candidate implementation and authored checks

- **Source-pixel ratios:** `CaptureAspectRatio`, `CaptureRatioControls`, frozen/editor boundary integration and rectangular multi-region controls use exact multiples of reduced integer ratios, independent X/Y source density, all eight handles and numeric rounding/refusal. The frozen source/time remains authoritative; undo/redo/cancel include the lock and boundary without applying it to annotations. `CaptureAspectRatioTests` and `CaptureRatioInteractionTests` are authored checks. `CaptureRatioNativeFixture` supplies owned selector/editor/multi-region events, exact pixel comparisons, light/dark and four-edge screenshots, source identity during drag and window-release checks. These descriptions are code inventory, not executed results.
- **Output decoration:** `ImageOutputDecoration`, `ImageOutputDecorationRenderer`, `ImageOutputDecorationPalette`, `EditorOutputProjection` and editor output routes preserve captured pixels, crop and annotation coordinates until output projection. Rounded corners, an inside border and an alpha-following bounded shadow are metadata with one Apply undo entry and draft Reset/Cancel. Alpha-capable formats preserve transparency under their existing options; JPEG/BMP/PDF use the explicit white-flattening boundary. `ImageOutputDecorationTests`, palette tests and `EditorOutputDecorationNativeFixture` cover authored renderer/output, history, controls, light/dark/edge screenshots and PNG round-trip checks. Preview is scaled; final lengths use source pixels.
- **Projection admission:** one global final job is reserved before flattening. Flattened input plus owned renderer allocations and queried native scratch must fit **512 MiB**; dimensions also obey **100 MP/32,768 per side**, often reduced by the memory admission. Palette preparation and final rendering use the same serial worker queue. Cancel clears queued input and rejects stale results, while a started reservation remains occupied until operation and main-actor completion drain. Source changes/close/crop/undo/new palette work cancel pending output. The reservation is also included in editor admission while draining; this does not cap unrelated encoders, framework backing or process RSS.
- **Original/current pins:** `PinSessionStore`, `PinSessionCoordinator`, editor callbacks and `CaptureOutputWorkflowFixture` preserve separate immutable original/current assets and publish their index transaction atomically. Failed persistence rolls back staged assets. Copy/save original and reset retain their original-source meaning; applying output to an existing pin retains its earlier original. The success-bearing callback leaves the frozen editor/source/history open on capacity or write failure. The combined fixture is authored to recreate the store/controllers, compare both assets exactly and check release/temporary-directory cleanup; it does not establish a native run here.
- **Multiple windows:** `MultiWindowCaptureInventory`, `MultiWindowSelectionController`, `MultiWindowCaptureController`, `MultiWindowCompositeRenderer` and `MultiWindowScreenshotCommand` implement compact in-place selection, relative desktop order, transparent composition, identity/geometry/display revalidation and scoped cancellation/process reaping. Layout, native capture/command and resource test sources exist. `MultiWindowCaptureNativeFixture` uses real owned AppKit controls and injected inventory/displays/pixels/permission, including native WindowServer hit testing. Its light/dark snapshots and pixel/cleanup assertions do not exercise real acquisition, occluded-window reliability, TCC, ScreenCaptureKit, physical Retina/multiple monitors or Spaces.

[CAPTURE_OUTPUT.md](CAPTURE_OUTPUT.md), [CaptureAspectRatio.md](CaptureAspectRatio.md) and [MultiWindowCapture.md](MultiWindowCapture.md) retain the detailed behaviors, limitations and bounds. Production multi-window limits are **8 selected windows, 1,024 inventory entries, 16 MP/input, 64 MP total input, 32 MP/output, 16,384 per side, an intended 80 MiB/temporary PNG limit, 180-second selection and 20-second acquisition/composition**. The later build-97 native test above disproves the source's shell-unit assumption: the 80 MiB accepted-file check and intended OS write cap must be distinguished, and a working 80 MiB hard write bound is not verified here. One canvas plus one source is at most **192,000,000 owned raster bytes**; no retained input-image array is permitted. Framework/decode buffers, capture subprocess, WindowServer and whole-process memory are outside that accounting. Sequential frames are not an atomic multi-window snapshot.

### Required final-source gates and actual measurement meaning

`CaptureOutputWorkflowFixture` and `scripts/check-capture-output-report.py` are wired into early installed-ZIP UI evidence and each final **actual installed ZIP and DMG**. Required component reports are ratios, decoration, multiple windows and original/current pin persistence. Source/version/build/bundle-path must match the installed app; temporary pin assets must preserve exact original/current bytes, and owned controller/file cleanup must complete. The checker requires no real desktop capture, permission request, general-pasteboard mutation or standard-defaults mutation. Native light/dark/edge images still require visual review; fixture source and generated screenshots alone do not prove satisfactory layout.

`scripts/multiwindow-resource-smoke.sh` is wired **only for the actual installed ZIP**, in a fresh installed process. It runs `MultiWindowCaptureResourceFixture` with **4 warmup + 12 measured cycles**, two fresh **3840 × 2160 PNG decodes per cycle**, the production sequential compositor and a **4480 × 2520 RGBA output**. The same two PNG paths/pixels are reused, while each frame creates a fresh ImageIO source/image; there is no decoded-image array. Digest comparison reads the actual owned output-provider bytes, with possible readback allocation labeled separately. The production raster bound for this workload is **78,336,000 bytes** (one 33,177,600-byte source plus a 45,158,400-byte canvas), below the general admission limit. Two prepared PNG files are fixture input, not an assertion that production captures two files concurrently.

Every completed cycle must match the independently prepared output digest, create two source images/two ImageIO decoders/one output, observe at most one live source at a time, release all probed objects and leave no owned open file descriptor. Separate cancellation after one decoded input must release ownership. Final cleanup removes the private PNG directory and checks device/inode-bound descriptors even after unlink. These are app-owned object/file observations, not proof that all native backing was reclaimed.

The fixture has an unchanged **180-second cooperative total / 20-second per-composition deadline** and the installed launcher's independent outer bound. It records input-generation and PNG-encoding setup before warmup, all four warmup boundaries, all twelve measured boundaries, cancellation and final cleanup. Preserve actual completed/remaining cycle counts and failure phase if incomplete. The fresh process is not a process-birth measurement: app startup and fixture input preparation precede its relevant boundaries. Do not merge these observations with the earlier broad installed-smoke process or other workload measurements.

The report and checker deliberately emit **`status=observed`, `observationsComplete=true`** only when the entire measurement/cleanup contract completes. **`memoryStabilityAssessed=false`, `plateauAssessed=false`, `zeroLeakClaim=false`** remain mandatory. An exit-0 measurement checker means complete observations, not a stable-memory result. Retain absolute pre-warmup, post-warmup and final values; setup and warmup growth; measured-to-cleanup deltas; every late measured increment; sampled peaks/counts/missing fields; and source/process/format provenance. **RSS (`resident_size`), physical footprint (`phys_footprint`), actual volatile resident (`purgeable_volatile_resident`), volatile virtual and compressed/volatile-ledger fields are separate measurements.** They must not be substituted, added as independent memory pools or described as ownership attribution. Available Mach fields are process-wide, separately sampled observations; timer peaks can miss transients. No memory-pressure/purge request, actual pressure reclamation, general plateau, zero leaks or sustained use is established by completing this workload. No current-source resource measurement ran in this failed attempt.

Full ordinary test discovery and complete disjoint-shard execution, focused/model results and original per-process limits remain required per architecture. Focused, ordinary and model suites overlap; do not add their totals as distinct coverage. Prior recording/recovery, GIF/codec, OCR, pins, annotations, automatic/manual scrolling, startup and cleanup gates remain required. A failed or unreached prior gate holds acceptance even if new component fixtures pass. Both final installed formats require their functional gates; repeated multi-window resources are ZIP-only and must not be claimed for DMG.

### Separate 03e7080 recording diagnostic and retained af11 failure

[Run 37697840669](https://github.com/dandibbert/picshot/actions/runs/37697840669), attempt 1, source **03e7080ef0d0baafcd9e42dbcddd697ee943aa64 / build 95**, is a separate recording-only diagnostic with terminal success on both architectures. Each passes **77 selected native tests, zero failures**. Four recording fixture cycles per architecture each decode seven frames and perform 95 pixel checks; tracked retained objects end at zero, temporary roots are removed and owned app exit is confirmed. ARM/Intel total fixture times are **4.144190 / 4.241720 seconds**, warmup **1.339395 / 1.649238 seconds**, with **162 trace events and zero dropped per architecture**.

Warmup refresh-camera-crop requires 26 attempts over 0.080856 seconds on ARM and 38 over 0.085371 seconds on Intel; all measured-cycle append/refresh operations accept on their first attempt. Intel's longest overall append/refresh boundary is warmup append-screen-0 at 0.120325 seconds. These timings include tracing work and do not identify the guard behind the earlier failure. All writers report completed status and tracked frame release; no screen/camera/microphone capture or permission request occurs.

This run produced no ZIP/DMG installer. It **does not clear the af11 Intel first-installed-ZIP broad-smoke failure**, whose precise failing wait remains unknown. No production correction, retry, timeout expansion or installer acceptance follows from the isolated pass. The current e48e21c `scripts/smoke.sh` enables `PICSHOT_RECORDING_COMPOSITION_TRACE=1` in the original broad-smoke ordering, keeping the original limits; that full-context observation was not reached in this failed attempt. [RECORDING_WAIT_DIAGNOSTIC.md](RECORDING_WAIT_DIAGNOSTIC.md) retains the source-qualified diagnostic detail. The accepted ARM af11 and rejected Intel af11 evidence below remain independent.

## Historical accepted ARM 0.14 and current Intel 0.11

**ARM 0.14.0/build 94 at [af11ec5aec87f6ce72ff30664cd05c3782d19f83](https://github.com/dandibbert/picshot/commit/af11ec5aec87f6ce72ff30664cd05c3782d19f83) is accepted for the bounded tested workload**, with terminal-success [ARM job 113019779514](https://github.com/dandibbert/picshot/actions/runs/37687734898/job/113019779514) in [run 37687734898](https://github.com/dandibbert/picshot/actions/runs/37687734898). All **1,456 ordinary discovered/selected tests complete: 1,453 passes + 3 documented pre-model skips**, zero failures; **963 focused and 12 actual-weight model tests pass**. These overlapping stages are not additive distinct-test totals. Both actual installed ZIP and DMG pass their functional, applicable prior-feature/model and cleanup gates. ZIP alone completes the manual **8 warmups + 16 measured 4K/5K/both-axis resource cycles in 160.167772 seconds** using the actual production vImage default; DMG runs manual functional/two-large-frame checks without a repeated-resource phase.

The actual installed ZIP's post-warmup-to-final changes are **+21,168,128 RSS / +622,592 physical footprint / +7,995,392 actual volatile-resident bytes**. Final RSS is **825,065,472 bytes**, footprint **39,735,104**, and actual volatile resident **81,985,536**. Measured actual volatile-resident endpoints range **64,585,728–81,985,536 bytes**, with zero compressed backing. The final volatile maximum was already observed at warmup cycle 2; some same-profile RSS intervals still increase. This is bounded observed resource behavior, not zero growth, a general plateau, leak freedom or a real ScreenCaptureKit measurement. The earlier 6d274 zero-net diagnostic retains its own source/workload scope. Ordinary-export/preview backing growth remains separately unresolved; the decoder experiment is not promoted.

**Only ARM LONG-02 moves narrowly to Code**, for passive continuous observation of settled user-scrolled viewports, conservative stability/overlap admission and pause/retry/stop. ARM's 124 behavior rows are **57 Code / 56 Partial / 11 Missing**; Intel remains independently accepted **0.11/build 69 at 3f013417a4bc4e88faa70f0db2ceb61ad2a82b20, 50 / 61 / 13** after its af11 installed gate failed. LONG-04/05/08/09 remain Partial with their concrete gaps. All **133 original IDs, requirements, acceptance checks and citations** remain, including nine macOS-context rows (**4 Partial / 4 Platform / 1 permissions note**). Code is a source classification, not complete PixPin parity or physical-device acceptance.

**ARM 0.14 persistence and ZIP/guide delivery are separately confirmed.** ARM DMG and ZIP were saved to their existing Library identities at **version 12**; the same complete guide was saved at **version 20**, **142,850 bytes**, SHA-256 `dc755532acaedc855800d615f52019107a4bad8368c69c83c2442383a700bc00`. **ZIP and guide were delivered at 22:14:06 UTC on 7 October 2026.** The DMG was saved, but its attachment was rejected for size and **was not delivered**. Intel remains delivered 0.11/build 69. These persistence and format-specific delivery records are separate from native/package acceptance. Every older source/version/result below remains historical evidence. Live TCC, third-party scrolling/input/capture, physical Retina/mixed/multiple displays/Spaces, broad page quality, full-resolution active preview, resized-region continuation, giant mode, fixed-content masking, crash recovery and sustained stability remain open within the full PixPin-equivalent goal, including premium features.

## Historical accepted/delivered ARM 0.13 and current Intel 0.11

**ARM 0.13.0/build 85 at [fa4cb0ad742e89c9235cfea2eef6b5d7840a78a9](https://github.com/dandibbert/picshot/commit/fa4cb0ad742e89c9235cfea2eef6b5d7840a78a9) has passed native and actual installed ZIP/DMG acceptance**, with terminal-success [ARM job 112836654128](https://github.com/dandibbert/picshot/actions/runs/37634321240/job/112836654128) in [run 37634321240](https://github.com/dandibbert/picshot/actions/runs/37634321240). All 1,391 discovered/selected ordinary tests complete: **1,388 passed + 3 documented pre-model skips**, zero failures. Two disjoint ordinary processes cover 684/707 cases in 227.110/169.333 s; focused processes pass 462/440, **902 total**, in 218.953/160.274 s. Each retains the original 420-second cap. **12 actual-weight model tests pass** after weights are supplied. Full/focused/model suites overlap and are not an additive distinct-test total.

Both installed formats independently pass exact-source startup/visible UI, annotation modules and separate 2+12 annotation resources, prior applicable feature/model and cleanup gates. Narrow ARM ANN-03/04/05/07 classifications become Code; ANN-06 lacks standalone-arrow comments and ANN-08 lacks a cross-document global counter, so both stay Partial. ARM's 124 behavior rows are **56 Code / 57 Partial / 11 Missing**. Intel remains independently accepted **0.11.0/build 69/source 3f013417: 50 Code / 61 Partial / 13 Missing**. Intel fa4 fails the existing synthetic GIF readiness assertion in its first 462-test focused process; the second focused, ordinary/full, model and final installed stages are unrun. Early Intel annotation success does not replace those missing gates. The nine macOS-context rows remain **4 Partial / 0 Missing / 4 Platform / 1 permissions note**, and all **133 original IDs, requirements, acceptance checks and citations remain**. Code is a source classification, not a complete-parity or physical-device acceptance claim.

**ARM 0.13 persistence and delivery are separately confirmed.** ARM DMG and ZIP were saved at Library version 11 and the same complete guide at version 19 (116,686 bytes; SHA-256 `3ba567e3116035cac00720fb6219eab78edd89b4e6a779a5e5b7a092b57d1cf7`). DMG and guide were delivered at **15:02:56 UTC on 7 October 2026**; the ZIP save is confirmed, but that message did not deliver the ZIP. This persistence/delivery record is distinct from native/package acceptance. Intel remains the previously accepted/delivered 0.11/build 69. The 0.12 and earlier records below retain their historical source/workload scope. Production decoding is unchanged; ordinary-export backing growth remains unresolved, with final installed existing-format RSS growth +12,976,128 ZIP / +16,564,224 DMG bytes and positive final intervals. Physical Retina/multiple displays/Spaces/TCC/external applications, broad-input quality, sustained stability and full PixPin parity remain open.

## ARM 0.14 continuous manual capture — accepted; Intel installed gate failed

**ARM source af11ec5aec87f6ce72ff30664cd05c3782d19f83 / 0.14.0 / build 94 passes terminal native/model and installed ZIP/DMG gates in run 37687734898, job 113019779514.** Its actual installed results come first below; prior diagnostics remain source-qualified history. Intel af11 ordinary/focused gates now pass, but job 113019779306 failed at the installed ZIP/DMG step and package uploads were skipped; the first ZIP broad recording-composition launch failed before manual-scroll/DMG gates, as detailed below; accepted Intel stays 0.11/build 69 at 3f013417a4bc4e88faa70f0db2ceb61ad2a82b20. ARM 0.14 DMG/ZIP persistence and ZIP/guide delivery are confirmed above; the DMG attachment was not delivered. All prior versioned records are preserved. The separate 2207cf05 GIF-readiness diagnostic is not installer acceptance.

The candidate wires `ManualScrollCoordinator`, `ManualScrollScreenDriver`, `ManualScrollControls`, `ScrollCaptureController`, `ScrollPreviewGeometry`, `ScrollSequencePreview` and `ScrollSequencePreviewRenderer`. It observes user scrolling without input/AX emission and requires two consecutive matching dimensions/full-color SHA-256 observations over normalized premultiplied sRGB RGBA pixels. Separate conservative overlap matching preserves the accepted anchor and immutable PNGs on rejection. Pause/retry/stop drain work; fixed-size movement retains display/window identity and needs explicit resume. Sampled navigation/latest-viewport bands do not become a full-resolution preview; the main preview is hidden while active. [ManualScrollCapture.md](ManualScrollCapture.md) describes flow and limits; its d011 passages are early history, not a current absence of later evidence.

### Exact accepted ARM 0.14 artifacts and native gates

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `PicShot-0.14.0-macos-arm64.zip` | 18,201,204 | `8f4df23793f0f4c8d7d7d1505b7e63fbbe03efb0f5295df3dae517d011365632` |
| `PicShot-0.14.0-macos-arm64.dmg` | 21,011,624 | `b982ac170db6937e6ed85044e74b3deb5e6404a08084529705c1b75c210873fe` |
| Each matching release metadata file | 177 | `e85ccb44cf810af30c2660964e4772d5bbdf9ed6e4620d9cfaf4d21dd59fafc8` |

Actual ZIP metadata/Info.plist identify 0.14.0/build 94, arm64, source af11ec5aec87f6ce72ff30664cd05c3782d19f83 and minimum macOS 14. Packages are ad-hoc signed and not notarized; native CI ran on macOS 15.7.9, so minimum-version acceptance is still unverified. Actual ZIP executable SHA-256 is `f0be19f4673677a2055cd0ef864e383e5dc49101d48dca349133855af1d6f35b`; its separate manual functional report is `2d64a581aa782a1221d2e14bae2c29345f7d5bb29722d0d7b5d4e2d61b4c7764`. Artifact/container hashes are not substituted for these installer/executable/report identities.

Ordinary disjoint native processes cover **724/732 cases in 238.367/180.000 seconds**, totaling 1,453 passes and three documented missing-weight skips for formula, table and erase real-model tests. Focused processes pass **498/465 cases in 247.829/168.982 seconds**, 963 total with no skips. Each keeps the original **420-second per-process cap**. Configured real-model rerun passes **12/12, zero skips/failures**. `picshot-final14-af11/arm-verification-summary.json` retains discovery/shard/log bindings and the terminal source/job identity. Native/macOS executables were not run in the Linux review workspace.

Both installed formats pass their broad owned functional cycles and manual native controls, separate 4K-horizontal/5K-vertical exact outputs and cleanup. Reported light/dark snapshots depict paused compact controls and stopped sampled preview of owned synthetic content; no third-party display, global input or TCC grant is exercised. The owner visually inspected the source-identical early light/dark paused controls and final installed ZIP dark / DMG light stopped-preview images, finding no clipping or contrast blocker. This review is limited to owned synthetic **1×** content; it does not establish physical Retina/multiple-display, third-party capture or TCC acceptance.

### Actual installed ARM ZIP manual resources at af11

The strict schema-2 report was independently rechecked against the **actual ZIP executable**, source/version/build and separate functional-report hash, with only CI-to-local bundle-path relocation for review. Installed smoke clears overrides and verifies `manualHashStrategy=vimage-full-frame`. Ordinary resource workspace sampling/bounds and all seven drained-release/close assertions are unconditional in this source, independent of diagnostic JSON. The complete loop retains **8 warmups + 16 measured cycles, 13 captures/observations and 4 accepted sources per cycle**, identical PNG hashes before/after, zero late-capture increments, zero reset/close/provider state and removed spool directories. Resource time is **160.167772 seconds**, within unchanged 240-second inner/600-second launch caps. DMG does not run this repeated phase.

| Actual installed ZIP boundary | RSS bytes | Physical footprint bytes | Actual volatile resident bytes | Volatile resident ledger bytes |
| --- | ---: | ---: | ---: | ---: |
| After functional | 913,473,536 | 37,965,952 | Not sampled at this scalar boundary | Not sampled at this scalar boundary |
| Pre-resource warmup | 919,748,608 | 42,930,304 | 228,065,280 | 227,278,848 |
| Post-warmup baseline | 803,897,344 | 39,112,512 | 73,990,144 | 73,728,000 |
| Final cleanup | 825,065,472 | 39,735,104 | 81,985,536 | 81,723,392 |
| Post-warmup → final change | +21,168,128 | +622,592 | +7,995,392 | +7,995,392 |

Functional work precedes resource warmup in the same process; these are not cold-process figures. Volatile virtual grows **+8,011,776 bytes**, from 74,416,128 to 82,427,904; volatile pmap grows **+16,105,472**, from 62,062,592 to 78,168,064. Actual volatile-resident endpoints range **64,585,728–81,985,536** during measured cycles; the resident ledger range is **64,323,584–81,723,392**. Compressed bytes and volatile-compressed ledgers remain zero. The final actual volatile maximum was present already at warmup cycle 2, but that fact does not erase positive final installed growth.

There are **1,172 warmup + 2,058 measured RSS/footprint sample pairs**, zero failed samples; timer ticks are 1,162/2,040 and explicit boundaries 10/18. Measured sampled peaks are **965,148,672 RSS / 133,304,128 footprint bytes**. Warmup sampled peaks are 1,019,871,232 / 129,732,544. Final three global RSS intervals are **+8,994,816 / −655,360 / +8,781,824**; footprint intervals are **+1,097,728 / −1,114,112 / −114,688**. Final cleanup adds zero to both. These interleaved profile intervals are not independent per-profile trends.

| Profile | Four measured actual volatile-resident endpoints (bytes) | Three same-profile RSS increments (bytes) |
| --- | --- | --- |
| 4K vertical | 65,044,480 / 73,039,872 / 73,039,872 / 73,039,872 | +8,257,536 / +4,128,768 / +163,840 |
| 4K horizontal | 73,990,144 / 64,585,728 / 81,985,536 / 73,990,144 | −5,275,648 / +17,563,648 / +475,136 |
| 5K vertical | 65,028,096 / 65,028,096 / 73,023,488 / 73,023,488 | +4,177,920 / +8,142,848 / +8,470,528 |
| 5K horizontal | 73,990,144 / 81,985,536 / 73,990,144 / 81,985,536 | +12,173,312 / −7,880,704 / +16,515,072 |

`arm-per-profile-memory.json` retains all endpoint/increment vectors. Same-profile points include the other profiles' intervening work; some RSS sequences rise even where volatile backing has one step or oscillates. Acceptance is for this bounded completed fixture, **not** a plateau, zero-growth, zero-leak, maximum-length or whole-system claim. Main-process 50 ms samples/150 ms settles can miss transients and exclude WindowServer/GPU/other processes. Native ScreenCaptureKit full-display/crop backing is unmeasured by injected providers. Other ordinary-export/preview backing growth remains unresolved.

### Intel af11 final installed blocker: recording composition, before manual capture

[Intel job 113019779306](https://github.com/dandibbert/picshot/actions/runs/37687734898/job/113019779306) is terminal failure in the same exact af11/build 94 run. Ordinary native discovery completes **1,456 cases = 1,453 passes + 3 pre-model skips**, focused **963/963** passes, and the configured actual-weight model rerun passes **12/12 with zero skips**. Ordinary shards take 338.660/213.012 seconds; focused shards 321.518/203.465 seconds, retaining the original 420-second per-process cap.

Verified QA artifact **11514303092** records failure in the **first installed ZIP broad launch**, recording-composition **measured-cycle-1**, with error **“Recording smoke exceeded its cooperative deadline”** at **21.385380 seconds**. Its warmup passed in **11.238898 seconds**, decoding seven frames and 95 pixel checks, with zero retained tracked objects/frame references and confirmed temporary-file cleanup. The overall 120-second deadline was not exhausted: the same error text also covers bounded 10-second append/refresh and 3-second release waits, and the exact suboperation was not recorded. No narrower cause is asserted. The failure report confirms temporary-root removal.

**Installed manual-scroll gates and the DMG launch were never reached; installer uploads were skipped.** This is an earlier recording-composition blocker, not an observed af11 Intel manual-scroll failure or a completed resource comparison. `picshot-final14-af11/verification-result.json` binds source, terminal jobs, native/model reports, failure phase and unreached stages. ARM acceptance remains valid independently. Intel remains accepted/delivered 0.11/build 69 until a later exact-source full native/installed result qualifies it.

### Production vImage integration: verify the actual default

At af11, `ManualScrollObservationStrategy.productionDefault` resolves to **vimage-full-frame** in the production driver/controller and ordinary functional/resource fixtures. `scripts/manual-scroll-smoke.sh` clears the diagnostic override and asserts `manualHashStrategy == vimage-full-frame` from the actual installed functional report. Explicit legacy/context controls remain diagnostic options. Earlier 8cb0/6d274 binaries retain their source-scoped full-frame production-default labels; they are not relabeled as post-switch installers.

`ScrollManualResourceFixture` samples and enforces normalization ownership in every run, even without `diagnosticHashComparison`. One owned fixed-extent destination is bounded by viewport pixels × 4, at most **96,000,000 bytes** under the 24 MP cap. All seven drained pause/recovery/cancel/reset checkpoints and close require zero workspace. Close also verifies weak objects, workers/providers and spool cleanup. Diagnostic JSON is optional; these checks are not. The bound excludes native conversion scratch, ImageIO/CoreGraphics backing/caches, full-display capture backing and total RSS. The final ARM af11 installed ZIP executes these assertions; Intel failed its installed gate and still requires independent complete installed evidence.

The normalization change does not alter production decoder defaults. The earlier decoder experiment is not promoted, and ordinary-export/preview backing growth remains unresolved. None of the findings below establishes framework allocation ownership, reclamation, zero leaks or unlimited/sustained stability. [ManualHashComparison.md](ManualHashComparison.md) and [ScrollMemoryAttribution.md](ScrollMemoryAttribution.md) retain detailed algorithms, source bindings and diagnostic scope.

### Early ARM installed-ZIP checkpoint at d0114762, build 87

ARM source [d0114762](https://github.com/dandibbert/picshot/commit/d011476234c8d732d0d72b1bff3e858c0ed44d0c) compiles and passes the **early actual installed-ZIP UI/functional gate** in [run 37646855331](https://github.com/dandibbert/picshot/actions/runs/37646855331). The downloaded UI-evidence artifact is **11494514647**, SHA-256 `ea95f94c0a316e11a4314bbcce01e02a47c2f5b8a090ccecefe20f6a1a9c5653`; this is an evidence-artifact hash, not an installer hash. Both `preview.json` and `manual-scroll/scroll-manual-continuous.json` report `status=passed` and the exact d0114762 source. Vertical/horizontal stable capture, stationary suppression, pause/drain, resume without countdown, same-size injected movement/source preservation, uncertain-seam retry, exact synthetic output and close/release checks pass. Color-digest distinction, separate mover native events, late capture-close and pause/stop/close rejection/removal of uncommitted PNGs also pass.

The four inspected native PNGs show light/dark paused controls and the stopped sampled preview; the readable fixture composes three frames into **640 × 920** exact-reference output. This is owned synthetic content. No screen capture, Accessibility/TCC request or global input occurs. The early report has **no large-frame or repeated-resource phase**. At this early checkpoint, full native ordinary/focused/model, both-format installed 4K/5K and ZIP-only 8+16 results were not established; later source-scoped evidence follows below. No row/status/count, accepted installer or delivery changes on this early result.

The same d011 run's later ARM focused attempt passed its first 498-test process. The second reported four fractional-cut mismatches in `ScrollSequencePreviewTests.testLongSampledTilesMatchIndependentEditedPixelsBothAxesAndFractionalScale`, then exited with signal 11 after an owned-window test started. No symbolicated stack established the signal's cause. Ordinary/model and final installer gates were unrun. Integer pixel-center strip ownership and explicit ARC-window release-on-close handling were corrected subsequently; the early UI pass does not override the failed native gate.

### ARM 0361a7eb: full native pass, repeated growth and checker-blocked installers

Exact source `0361a7eb1fe9c9ab39732853852b50a6d690a15a`, archived `picshot-qa14-0361-arm`, records **947 focused passes**, **1,436 ordinary discovered/selected tests = 1,433 passes + 3 documented pre-model skips**, and **12 actual-weight model passes**. Ordinary disjoint processes cover 720/716 cases in 242.097/178.627 seconds; focused processes cover 498/449 in 232.468/156.526 seconds. Original 420-second per-process caps remain. Ordinary/focused/model suites overlap and are not additive distinct-test totals. Corrected fractional edited-preview pixels, owned-window interaction/close and inspector layout pass at this source.

ZIP functional/two-large-frame work and complete **8 warmups + 16 measured resource cycles** ran. Resource elapsed time is **138.891 seconds**; post-warmup RSS increases **714,358,784 bytes (about 681 MiB)** and footprint **771,520 bytes**. Final RSS intervals are +42,565,632 / +49,643,520 / +68,403,200 bytes. All explicit cleanup counters are zero. The 1,759 measured RSS/footprint pairs have zero failures; sampled peaks are 2,011,627,520 RSS / 157,143,680 footprint bytes. This source did not record `TASK_VM_INFO_PURGEABLE`; the RSS/footprint gap establishes neither purgeability nor a leak verdict.

The old resource checker incorrectly expected one latest-viewport range instead of the valid four adjacent source bands. It stopped the installer script before DMG: **ZIP work executed, the final ZIP resource checker rejected it, DMG was unrun, and acceptance/delivery remained held**. Correcting the checker does not retroactively accept the installers or erase the repeated-memory result.

### fda0e7e5: matched split attribution and full E2E observations

[Run 37661169415](https://github.com/dandibbert/picshot/actions/runs/37661169415), source `fda0e7e5c5fbec02f0bd434f3e4811205a12322f`, supplies archived `picshot-memory14-fda0-arm` and `picshot-memory14-fda0-intel`. Both architectures pass **59 selected native tests**. ARM completes **13 matched split cells**, each 8+16 cycles, totaling 312 cycles and 12,024 successful sampled pairs. The matrix matches architecture, macOS 15.7.9 (24G830), release configuration, source hashes and prepared PNGs. The instrumented fa4cb0ad baseline is production code plus a diagnostic overlay, not the delivered 0.13 binary. Current cells precede baseline cells; order remains a timing confound.

ARM capture-hash acquires **1,474,560,000 additional volatile-resident bytes during warmup normalization/hash intervals**; subsequent pool exits release none of that observed backing. This localizes the interval without proving which draw/context/conversion/cache owns it. The baseline hash diagnostic ends near the same volatile total; its +235,388,928 resident change is offset by −235,388,928 compressed volatile ledger bytes with unchanged virtual size. That is residency/compression redistribution, not proof of new logical allocation. The baseline hash is an added diagnostic algorithm, not shipped continuous capture in 0.13. Unchanged shared-accept code finishes at 8.75 MiB volatile resident and no measured volatile growth in either version; current/baseline RSS increments are 17.297/9.125 MiB. Current detail alone retains 228.375 MiB volatile resident after warmup. Stages differ from E2E; their deltas are not additive attribution.

Separate ARM full E2E completes unchanged 8+16 work in **145.2964 seconds**, four accepted sources and 13 observations per cycle. Functional work occurs first in the same process: pre-resource RSS is already 818,085,888 bytes and actual volatile resident 228,720,640. Warmup adds 238,764,032 RSS / 206,766,080 actual volatile-resident bytes. Post-warmup-to-final changes are **+730,906,624 RSS (about 697 MiB), +713,687,040 actual volatile resident (680.625 MiB), and +575,040 footprint bytes**. Final actual volatile resident is 1,149,173,760. Compressed volatile/nonvolatile ledgers stay zero; volatile virtual grows 714,244,096 bytes. Final RSS intervals are +42,565,632 / +49,577,984 / +68,452,352 and actual volatile-resident intervals +42,827,776 / +49,315,840 / +68,648,960 bytes. Zero explicit owners and 892 warmup/2,040 measured successful sample pairs do not establish harmlessness, reclamation or stability. Measured sampled peaks are 2,012,938,240 RSS / 157,438,400 footprint bytes.

Intel completes current source-create, capture-hash and PNG-spool. Stitch-overlap reaches the unchanged **240-second cap at 240.1166 seconds after 8 warmups + 13/16 measured cycles**. Its 4,822 successful samples remain below sampled ceilings. Later current stages, every baseline stage and Intel full E2E are unrun. This is incomplete time-limited evidence, not a memory-watchdog failure or installer acceptance.

### 8cb0c700: pools and reused CGContext did not remove backing growth

[Run 37676118472](https://github.com/dandibbert/picshot/actions/runs/37676118472), source `8cb0c7003bc2e75859f2b41ba687bd6e937f5ae3`, passes **70 selected native tests per architecture**. Archived `picshot-hash14-8cb0-arm` completes three same-executable ARM 8+16 cells with matching capture-count vectors, captured PNG/large-output digests and runtime identity. Exact post-warmup-to-final deltas are:

| ARM strategy | RSS bytes | Volatile resident ledger bytes | Compressed volatile ledger bytes | Combined volatile ledgers bytes |
| --- | ---: | ---: | ---: | ---: |
| full-frame | +527,515,648 | +670,351,360 | +43,335,680 | +713,687,040 |
| pooled-full-frame | +691,814,400 | +713,687,040 | 0 | +713,687,040 |
| reusable-full-frame | +417,366,016 | +520,470,528 | +193,216,512 | +713,687,040 |

Actual volatile-resident changes equal resident-ledger changes here; all cells add 714,244,096 volatile-virtual bytes. Reusable's lower RSS accompanies compressed backing, not a demonstrated memory remedy. Footprint increments are +1,525,440 / +1,263,168 / +1,459,840 bytes; resource times are 124.0254 / 123.2584 / 120.3770 seconds. Pooling/reuse are rejected as backing-growth fixes on this evidence; one fixed-order run is not a general timing result.

Archived `picshot-hash14-8cb0-intel` passes all three functional fixtures, but each resource cell reaches the original 240-second cap: **8 warmups + 4/2/3 of 16 measured cycles**, at 240.03252045 / 240.026264247 / 240.035119159 seconds. Errors “First source not accepted,” “Moved source not accepted” and “Stable source 4 not accepted” mark interrupted stages at the global deadline. The old checker obscured them as unexpected object keys; later failure handling preserves actual reasons and partial counts without accepting them. Separate cells ran only after prior owned exits. No complete matched Intel resource comparison or installer acceptance exists at this source.

### 6d274ecf: complete ARM direct-conversion comparison; Intel partial

[Run 37684339137](https://github.com/dandibbert/picshot/actions/runs/37684339137), source `6d274ecf0dfff8776a2711e8043720045d9390eb`, passes **72 selected native tests per architecture, including all 13 hash/workspace tests**. ARM evidence artifact **11512015113** verifies SHA-256 `410b986257ef4af19c1812e80b4daf702463e29ff08d7d87a611297d7a0c985b`; `picshot-vimage93-watch-arm64/verified-summary.json` and raw `evidence/manual-hash/` supply the observations. This is diagnostic app evidence, not installed-release acceptance.

Both ARM cells pass functional checks, separate exact-output **3840 × 2160 horizontal / 5120 × 2880 vertical** cases and complete **8 warmups + 16 measured interleaved 4K/5K/both-axis E2E cycles**. Each cycle has 13 captures/observations and four accepted sources. Both use executable SHA-256 `9b815647cc6ac5b48607bdc63c5e325928554d2e390b7ea77da3274a1c64b572`, release arm64 on macOS 15.7.9 (24G830), matching source/PNG/output hashes, separate PIDs/invocations and confirmed owned exits. All 24 owned cleanup, late-capture and normalization-release records pass per cell. Work counts and pixels are unchanged; neither deadline is relaxed.

These are **absolute bytes**. Smoke entry follows AppDelegate startup; **process-birth memory was not captured**. Functional work precedes resource warmup, which is not a cold-process boundary.

| ARM strategy / boundary | RSS | Physical footprint | Actual volatile resident | Volatile resident + compressed ledger sum |
| --- | ---: | ---: | ---: | ---: |
| Legacy / smoke entry | 69,500,928 | 21,072,064 | 0 | 0 |
| Legacy / after functional | 817,872,896 | 38,063,744 | 228,851,712 | 227,278,848 |
| Legacy / pre-resource warmup | 820,592,640 | 40,701,568 | 228,851,712 | 227,278,848 |
| Legacy / post-warmup | 1,064,796,160 | 39,342,080 | 445,054,976 | 444,137,472 |
| Legacy / final cleanup | 1,427,439,616 | 40,785,344 | 954,515,456 | 1,148,387,328 |
| vImage / smoke entry | 69,599,232 | 20,842,624 | 0 | 0 |
| vImage / after functional | 915,603,456 | 37,670,720 | 228,065,280 | 227,278,848 |
| vImage / pre-resource warmup | 921,288,704 | 43,274,048 | 228,065,280 | 227,278,848 |
| vImage / post-warmup | 800,718,848 | 39,063,040 | 74,252,288 | 73,728,000 |
| vImage / final cleanup | 801,898,496 | 39,554,560 | 74,252,288 | 73,728,000 |

vImage post-warmup-to-final changes are **+1,179,648 RSS / +491,520 footprint bytes**, with **zero net change in actual volatile resident/virtual/pmap, resident and compressed volatile ledgers, and their sum**. Volatile virtual ends at 74,678,272; compressed backing is zero at both endpoints. Final RSS remains **801,898,496 bytes (about 765 MiB)**, with **74,252,288 actual volatile-resident bytes**. Legacy's combined volatile ledgers grow **704,249,856 bytes**. vImage's improvement is not explained by a compensating compressed-volatile increase.

The vImage volatile resident ledger still cycles between **65,028,096 and 81,723,392 bytes**, with final increments **+16,678,912 / −16,695,296 / +8,699,904**. These are bounded observations in this workload, not zero change in every interval. Profiles are interleaved; same-profile endpoints include intervening work. The combined ledger sum is a derived field, not an extra kernel field or ownership attribution.

vImage records **1,093 warmup + 2,269 measured RSS/footprint sample pairs**, zero failures, with measured sampled peaks **958,513,152 RSS / 131,567,168 footprint bytes**. Warmup/measured timer ticks are 1,083/2,251 and explicit boundaries 10/18. Resource time is **166.753466 seconds versus legacy 152.471865**: vImage is slower in this fixed-order run. The result supports testing the integrated default, without a universal speed, zero-leak, reclamation, global-pressure, real ScreenCaptureKit or sustained-memory claim.

Intel's independent diagnostic is terminal and incomplete. Artifact **11512247176** verifies SHA-256 `e271703af46f38f78de0edd9d8747c43bf1d0ba25d53116660127b4b75a4d9f6`; `picshot-vimage93-watch-x86_64/verified-partial-summary.json` preserves partial results. Both functional fixtures and the 72 selected/13 hash tests pass. Legacy reaches **240.025878 seconds after 8 warmups + 4/16 measured cycles**; vImage reaches **240.165822 seconds after 8 warmups + 1/16 measured cycle**. Native errors are “Uncertain seam did not pause recoverably” and “Resource fixture deadline exceeded” at the unchanged 240-second cap. Owned exits are confirmed; neither hits the 600-second launcher timeout. There is **no complete matched Intel resource comparison or installer acceptance**. Partial endpoints cannot substitute for complete-work deltas. Accepted/delivered Intel remains 0.11/build 69, independent of af11 final gates.

### Accepted ARM functional scope; independent Intel gate remains

`ManualScrollCoordinatorTests`, `ManualScrollIntegrationTests`, `ManualScrollSequenceTests`, `ScrollPreviewGeometryTests`, `ScrollSequencePreviewTests` and existing automatic/sequence/matcher/editing suites have final ARM source-specific native results above; Intel final installed acceptance remains unestablished after its failed installer step. Authored tests alone are not executed evidence. Preserve ordinary test discovery, disjoint-shard completeness, skip reasons, overlapping focused/model scope, unchanged process caps and terminal workflow/job links for each architecture independently.

`ScrollManualCaptureSmokeFixture` and `scripts/manual-scroll-smoke.sh` are wired for each **actual installed ZIP and DMG**. Earlier source-scoped fixtures supply functional proof for their own binaries; accepted ARM af11 full both-format gates repeat both-axis stable observation/stationary suppression, native owned pause/resume/stop, recoverable seam retry, immutable PNG bytes, separate mover mouse/Return/Escape handling, late capture/late source-write rejection after pause/stop/close, exact synthetic output and cleanup. Light/dark snapshots show the paused compact panel and stopped preview using an owned synthetic readable page. They are not third-party screenshots. Separate large injected cases are **3840 × 2160 horizontal** and **5120 × 2880 vertical** with output digests and release checks. Native mover events and injected controller movement do not prove live target-window repositioning or TCC behavior.

Expected reports under each format's `manual-scroll/` evidence directory are `launch.json` and `scroll-manual-continuous.json`, plus the named PNG snapshots. These files must actually exist, identify the exact installed app/source and pass their checks before any corresponding claim changes from not-run to passed. Existing startup, prior feature/model, signature/architecture and cleanup gates remain required.

### Installed repeated-resource scope: ZIP only

`ScrollManualResourceFixture` has four ordered profiles: **3840 × 2160 vertical/horizontal and 5120 × 2880 vertical/horizontal**. Two warm-ups/profile and four measured cycles/profile produce **8 + 16 cycles total**, each accepting **four** procedural viewports. It exercises the real passive driver, RGBA hash, matcher, PNG spool, sampled preview, stationary suppression, pause/drain, same-size injected movement, uncertain-seam refusal/retry, cancellation during an injected provider call, reset and close. The resource loop uses direct setup and does **not** perform native control events, full-output raster composition or giant master-page allocation; those functional boundaries have separate evidence.

The inner resource deadline is **240 seconds** and the installed-launch outer timeout is **600 seconds**, including functional work. `scripts/manual-scroll-smoke.sh` enables this repeated workload only for ZIP. DMG runs the functional/two-large-case checks without a repeated resource phase; do not copy ZIP observations into DMG or ARM observations into Intel. Failed, timed-out and unrun phases remain explicitly distinct.

`scripts/check-scroll-manual-resource-report.py` validates `scroll-manual-resource.json` against the actual installed release bundle's source/version/build/executable hash and the separate functional-report hash. It enforces exact schema, source identities, byte totals, workload, caps, endpoint ownership and memory arithmetic. The Python hostile-schema tests use fabricated reports; they do not establish native execution or a plateau.

For each actual architecture/ZIP report, record pre-warm-up, post-warm-up baseline, all 16 post-close endpoints, final cleanup, global and per-profile last-three intervals, RSS/physical-footprint growth, sampled maxima, timer/boundary counts, failures, elapsed time and object/spool release. Sampling is **50 ms**, settling **150 ms**. **The final ARM af11 installed-ZIP results above are observed; Intel installed manual resource work was not reached after the broad ZIP recording-composition failure.** The early functional report's before/after memory snapshots are not this repeated workload. Main-process samples exclude WindowServer/GPU/other processes and can miss transients. `memoryIsObservational=true`, `stabilityAssessed=false` and `zeroLeakClaim=false` must remain explicit even if all assertions pass.

One pending capture raster, one accepted grayscale anchor, bounded overview/tile/job counts and zero owned state after close do not bound total framework backing. Native capture takes a full-display image then crops; that crop can retain full-display backing, and the full display must fit the 24 MP admission cap. Injected viewports do not measure that ScreenCaptureKit path. ImageIO may retain volatile decoded backing beyond lexical release. This milestone changes no existing ordinary-export memory conclusion.

### Final architecture decisions and remaining fields

| Field | ARM af11/build 94 | Intel af11/build 94 candidate |
| --- | --- | --- |
| Exact source/version/build and terminal job | af11ec5aec87f6ce72ff30664cd05c3782d19f83 / 0.14.0 / 94; job 113019779514 success in run 37687734898 | Same candidate source/run; job 113019779306 failed at installed ZIP/DMG step 21; package uploads skipped |
| Full native/focused/actual-weight models | 1,456 ordinary = 1,453 passes + 3 pre-model skips; 963 focused passes; actual-weight rerun 12/12 passes | Ordinary 1,453 passes + 3 same pre-model skips and focused 963 passes verified; configured models 12/12 pass with zero skips; first installed ZIP recording-composition gate failed before manual-scroll/DMG |
| Both actual installed formats | ZIP and DMG functional, applicable prior-feature/model, source/architecture/signature and cleanup gates pass; bytes/hashes above | Failed installed step; complete independent acceptance absent |
| Actual default/manual pixels and resources | Both functional reports assert vImage default and exact synthetic output/two-large-frame checks; ZIP 8+16 resource gate passes in 160.167772 seconds; DMG intentionally has no repeated phase | Installed manual-scroll gates unrun because ZIP broad recording-composition failed first; DMG unrun; old 6d274 partial resources do not pass |
| Memory conclusion | Bounded completed workload accepted with actual positive RSS/volatile growth and per-profile qualifications above; ordinary-export/preview growth unresolved | Recording-composition failed at measured-cycle-1; other unreached installed workloads remain unrun; accepted 0.11 caveat remains |
| Row decision | LONG-02 only becomes Code; 57 Code / 56 Partial / 11 Missing | Keep accepted 0.11 counts 50 / 61 / 13 |
| Final native screenshot review | Fixture/pixel assertions verified; owner inspected source-identical early paused light/dark controls and final ZIP dark / DMG light stopped previews with no clipping/contrast blocker, owned synthetic 1× only | Final installed manual snapshots unrun after earlier broad ZIP failure |
| Installer/guide Library identity/version and delivery message/time/attachments | DMG/ZIP saved to existing identities at Library v12; guide v20, 142,850 bytes, SHA-256 `dc755532acaedc855800d615f52019107a4bad8368c69c83c2442383a700bc00`; ZIP+guide delivered 7 October 2026 at 22:14:06 UTC; DMG attachment rejected for size and **not delivered** | **Pending new-version acceptance/persistence/delivery** |

LONG-02's narrow ARM Code classification covers reachable passive observation of settled user-scrolled viewports, conservative stable/overlap admission, stationary suppression and pause/retry/stop. Real steady/intermittent page behavior, skipped-content/accidental-UI checks and broad dynamic-page quality remain open. LONG-04 remains Partial because sampled preview is hidden during active observation and is not full resolution. LONG-05 cannot resize a continued region. LONG-08 does not implement the vendor's giant/very-long mode. LONG-09 lacks animation masking and automatic fixed-header/sidebar removal. LONG-01/03/06/07/10 retain previous classifications/evidence; LONG-10 still lacks crash recovery.

All **133 original IDs, requirements, acceptance checks and citations** remain, with nine unchanged macOS-context rows (**4 Partial / 4 Platform / 1 permissions note**). No evidence closes live TCC, third-party input/capture, physical Retina/multiple/mixed displays/Spaces, maximum-length sustained work, broad page quality or complete PixPin parity including premium capabilities. Production limits remain **24 MP/source; 60 MP/32,768/output; 100 sources; 512 MiB spool; three minutes per explicit manual run including pauses**. Native full-display backing remains unmeasured. Package acceptance and Library persistence are confirmed separately for ARM 0.14; delivery is confirmed for the ZIP and guide only. The saved DMG was not delivered because its attachment was rejected for size.

## Historical accepted ARM 0.12 at 2754b779 build 77

**ARM 0.12.0/build 77**, full source [2754b77954415a8273c14a7fe5245330bec39996](https://github.com/dandibbert/picshot/commit/2754b77954415a8273c14a7fe5245330bec39996), passes terminal-success [job 112730667449](https://github.com/dandibbert/picshot/actions/runs/37602641265/job/112730667449) in run 37602641265. Intel remains accepted 0.11.0/build 69 at 3f013417; do not transfer ARM evidence. These historical 0.12 records supplement the preserved older measurements/requirements. Acceptance is separate from Library persistence/user delivery. ARM DMG/ZIP replacements are confirmed at Library version 10 and the same guide at version 18, 92,739 bytes, SHA-256 `77c28c90b6cbe0ba3efc5f9fff072ca3d90b4daa56d2ac9df72afd791c6fe0c8`. All three files were saved; delivery was confirmed at 10:22:57 UTC on 7 October. Intel's original main job 112730667468 reached the unchanged 420-second ordinary-suite cap after 1,157 cases without an assertion failure. Unchanged-source main-job rerun 112745231497 in run 37602641265 failed with a GIF readiness assertion and a focused-suite 420-second timeout after 514 completed cases. The separate diagnostic retry 112745231096 had 134 tests, one GIF readiness failure and no timing matrix. Both retries failed; neither is pending or establishes Intel 0.12 acceptance.

Downloaded QA artifact **11475281086** contains ordinary/focused/model logs and `evidence/zip` plus `evidence/dmg`. Ordinary tests: **1,321 total, 1,318 passed, 3 intentional pre-model skips, zero failures**. Focused: **850 passed**. Actual-model stage: **12 passed**, zero failures. Wrapper durations **338.553/311.747 seconds**, exit 0, original **420-second** caps, no forced signal or truncated logs. Suites overlap. Runtime: **macOS 15.7.9 (24G830), Xcode 16.4, SDK 15.5**; minimum macOS 14 runtime remains unverified.

### Exact ARM package bytes

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `PicShot-0.12.0-macos-arm64.zip` | 17,544,811 | `911bb785a133f7edeb1f5f919f7c465067cc2ec1dada1689f927edd14ba064a2` |
| `PicShot-0.12.0-macos-arm64.dmg` | 20,291,019 | `ecc4f7885934836696e6d9354237a5131a26688dcb5a51fcd100f3ae773b02fe` |
| `PicShot-0.12.0-macos-arm64.build-info.json` | 177 | `d387e3b0e392641eb12489064a8c25e0ac052111548fb2e9c12084fff78b2f6b` |

Actual sidecars match downloaded bytes; ZIP CRC passes, embedded/external build-info are byte-identical, Info.plist is 0.12.0/build 77, source matches, and main Mach-O is arm64. Packaging and both installed gates pass. Ad-hoc signing remains distinct from Developer ID/notarization/Gatekeeper/publisher identity. ZIP artifact is 11475211247, DMG is 11474957329.

Both actual installed formats independently pass no-argument LaunchServices/visible windows, automatic mosaic, capture/recognition, Save/Retry/owned panels, signed codecs and actual models, managed formula pins/group transforms/desktop policy, pin OCR/source links, recording composition and animated WebP. Own-child recording recovery passes separately. Actual own-app AX remains `skipped-no-existing-accessibility-permission`. Full GIF stress is ZIP-only. Physical desktop/TCC/foreign apps are not implied.

### Automatic mosaic functional and independent pixel scope

Each installed `automatic-mosaic/automatic-mosaic-workflow.json` identifies the exact source/version/build and has **12 real functional matches plus 14 separate resource matches**. The full independent checker passes for each artifact; all eight PNG hashes were checked. Authored 720×480 premultiplied sRGB source uses actual CoreText name/icon/color/alpha. Top-left seed `(31,37,144,48)`, exact repeat `(287,123,144,48)`, small color variant `(497,301,144,48)`, glyph-change decoy `(59,329,144,48)`. Source pre/post hash is `51dcb18f5d893c33659a6cd21d19a65d5f8eb6f4bab39a6d81cc253847afa311`.

Seed/select/Find and direct menu entry, candidate navigation/exclusion/reinclusion/manual correction, untouched model before Apply, synchronized/local additions/deletion, one-step Apply undo/redo, linked IDs/history, crop/edit/cancel/close invalidation, native control target-action/hit testing, four-corner geometry, current-candidate visibility and pending-output protection/restoration pass. Light/dark/edge evidence accompanies each actual format. Four stale callbacks contain real completed matches held until invalidation; **active scan cancellation was not established here** (`activeScanCancellationVerifiedHere=false`). No global events, general pasteboard, live capture, network or new permission is used.

Independent actual PNG checks use authored rectangles, decode/CRC/hash and recompute pixels rather than trusting reported masks. Redact/redact-excluded approve 20,736/13,824 pixels, opaque `(0,0,0,255)`; blur changes 20,736 and pixelate 7,757 approved pixels. **All four outputs have zero exterior mismatches in each install**, including decoy/exclusion. Blur/pixelation remain cosmetic. Original editor raster and undo survive until close; saved originals are separate.

### Automatic mosaic small resources

Each install independently performs **2 warmups + 12 measured** native seed/select/match/review/Apply/flatten/Close cycles; one fixed 720×480 raster/matcher/counter persists at comparable endpoints, zero live editors/jobs, no measured-loop PNG or screenshot, 150 ms settling. Baseline belongs to a combined acceptance process after earlier fixtures, not idle app cost or mosaic-only total RSS.

| Install | RSS baseline → end / delta bytes | Last three single-cycle RSS deltas | Footprint baseline → end / delta bytes | Last three footprint deltas | RSS / footprint sampled peaks bytes | Measured seconds |
| --- | --- | --- | --- | --- | --- | ---: |
| ZIP | 595,935,232 → 595,968,000 / +32,768 | +0 / +32,768 / +0 | 136,515,584 → 135,221,248 / -1,294,336 | +0 / +32,768 / +0 | 601,292,800 / 141,889,536 | 5.398079 |
| DMG | 590,217,216 → 590,364,672 / +147,456 | +32,768 / +0 / +65,536 | 141,119,360 → 139,939,712 / -1,179,648 | +0 / +32,768 / +98,304 | 595,574,784 / 146,493,312 | 5.465267 |

ZIP/DMG each has zero failed RSS/footprint observations: **122/124** successful samples per metric, **107/109** timer ticks and **15/15** boundary samples. All 14 weak release probes per format have zero retained controller/canvas/content/review; all endpoints have zero active wrappers/jobs. Additional final cleanup changes RSS and footprint by zero. **RSS still grows +32,768/+147,456 bytes; final DMG RSS interval +65,536. `stabilityAssessed=false`.** 50 ms samples may miss transients and exclude WindowServer/GPU; no plateau, zero leaks or sustained stability is established. No allocator purge or pressure/system-setting change is used.

All twelve settled endpoints, raw bytes:

| Cycle | ZIP RSS | ZIP footprint | DMG RSS | DMG footprint |
| --- | ---: | ---: | ---: | ---: |
| 1 | 595,935,232 | 135,303,168 | 590,217,216 | 139,808,640 |
| 2 | 595,935,232 | 135,303,168 | 590,217,216 | 139,775,872 |
| 3 | 595,935,232 | 135,303,168 | 590,217,216 | 139,775,872 |
| 4 | 595,935,232 | 135,303,168 | 590,217,216 | 139,775,872 |
| 5 | 595,935,232 | 135,270,400 | 590,217,216 | 139,759,488 |
| 6 | 595,935,232 | 136,564,736 | 590,217,216 | 139,792,256 |
| 7 | 595,935,232 | 135,254,016 | 590,217,216 | 139,792,256 |
| 8 | 595,935,232 | 135,221,248 | 590,266,368 | 139,841,408 |
| 9 | 595,935,232 | 135,188,480 | 590,266,368 | 139,808,640 |
| 10 | 595,935,232 | 135,188,480 | 590,299,136 | 139,808,640 |
| 11 | 595,968,000 | 135,221,248 | 590,299,136 | 139,841,408 |
| 12 | 595,968,000 | 135,221,248 | 590,364,672 | 139,939,712 |

### Separate one-shot 4K and 5K Release matches

After small-cycle measurement, each artifact performs one real match at 3840×2160 and one at 5120×2880. Seed `(31,47,144,48)`; exact `(1919,1081,144,48)`; other target `(3681,2089,144,48)` in 4K or `(4961,2809,144,48)` in 5K; decoy `(113,157,144,48)`. Each returns exactly two expected targets, scores 1 and 0.9132862288722637, no decoy/truncation, source byte identity unchanged and original 8-second deadline preserved. Source bytes 33,177,600/58,982,400, template 27,648, examined origins 7,811,761/14,099,841. Scratch budget is 100,663,296 bytes (96 MiB), excluding original source, CGContext internals and UI/WindowServer allocations.

| Install / input | Construction seconds | Admission/conversion/full search seconds |
| --- | ---: | ---: |
| ZIP / 4K | 0.026702208 | 0.125831625 |
| ZIP / 5K | 0.045696458 | 0.224045833 |
| DMG / 4K | 0.027111708 | 0.121826125 |
| DMG / 5K | 0.047249917 | 0.226947625 |

4K source pre/post SHA-256 is `8765bbe00a7777a47398aa3d3e4d268fa4055c76ad1f7eed3455a59e952caf5e`; 5K is `1aefa60a203e5fcd27cc2ae2aa337b69297da58f20bda2df21a4002cafc75699`. These allocations are outside the 2+12 small loop. **One-shot timings are not sustained throughput, maximum-size acceptance or a large-image leak test.**

### Other exact-source resources and unresolved growth

| Workload / comparable scope | ZIP RSS change bytes | DMG RSS change bytes | Boundary |
| --- | ---: | ---: | --- |
| OCR 2+12 actual-Vision cycles | +1,753,088 | +4,358,144 | 14 resource Vision calls/cache reuses; zero live pin/result/job endpoints |
| Formula 2+12 hide/show/close/restore | +147,456 | +196,608 | same one-live-pin endpoint; zero measured renders |
| Group 3+20 numeric transform/undo/inspector/hide/show | +98,304 | +229,376 | same four live pins; assets unchanged |
| Editor/pin 10+40 lifecycle | -49,152 | -163,840 | last ten +16,384/+32,768; windows 7→7; tracked objects release |
| Save 2+8 small real jobs | +360,448 | +393,216 | jobs/input/controller/owned temporary cleanup |
| Static WebP/AVIF 768×576, three per format | +26,984,448 | +23,625,728 | combined encode/preview/decode/quality/save/cancel; no separate warmup/phases |
| PNG/JPEG/BMP/PDF 1440×900, 1+4 | +11,354,112 | +21,250,048 | observed; final RSS intervals −11,223,040/+7,815,168; no stability claim |
| Full GIF export plus decode 1+4 | +16,384 | Not run | ZIP only; 30 seconds/360 frames at 480×270; last interval 0; exit/cancel/cleanup |

ZIP OCR RSS late increments **+65,536 / +98,304 / +65,536**, footprint change **+1,196,032**, extra cleanup footprint **-16,384** (RSS 0). Formula late RSS **+0 / +147,456 / +0**, footprint **+131,072**; group late RSS **+0 / +0 / +0**, footprint **+344,064**. Final group cleanup RSS **-17,383,424** is separate from the live four-pin endpoint. Save footprint change **+245,760**; static-codec footprint **+737,344**; existing-format footprint **+2,162,688**.

ZIP model-child parent-polled sampled RSS peaks, formula/table/smart erase: **393,396,224 / 219,955,200 / 1,683,423,232 bytes**. Each exits 0 and confirms temporary cleanup; 100 ms sampling may miss transients, excluding system services/GPU.

DMG OCR RSS late increments **+81,920 / +458,752 / +196,608**, footprint change **+1,884,224**, extra cleanup footprint **-1,703,936** (RSS 0). Formula late RSS **+0 / +0 / +147,456**, footprint **+212,992**; group late RSS **+0 / +0 / +0**, footprint **+311,296**. Final group cleanup RSS **-17,383,424** is separate from the live four-pin endpoint. Save footprint change **+294,912**; static-codec footprint **-1,114,112**; existing-format footprint **+114,752**.

DMG model-child parent-polled sampled RSS peaks, formula/table/smart erase: **305,348,608 / 200,671,232 / 1,909,293,056 bytes**. Each exits 0 and confirms temporary cleanup; 100 ms sampling may miss transients, excluding system services/GPU.

**Known ordinary-export preview backing growth remains unresolved:** net retained RSS +11,354,112 ZIP / +21,250,048 DMG bytes; DMG's final interval is +7,815,168. Application-owned cleanup and a negative last ZIP interval do not establish native allocation ownership, a plateau or zero leaks. OCR also retains positive RSS and positive late intervals. Metrics from unlike source/process/workload/phase cannot be added or averaged. Production decoder default is unchanged; separate timing diagnostics do not become an app memory remedy. GIF's separate 1920×1080/12-frame case remains a short sample, not maximum area/frame count or sustained evidence.

### Classification and retained scope

ARM ANN-15/16 become Code only for the complete stated same-size/orientation matching, review/manual correction, linked synchronization and undo behavior with exact-source installed proof. ARM behavior counts **52 Code / 61 Partial / 11 Missing**; Intel current 0.11 remains **50/61/13**. Nine macOS rows remain 4 Partial / 4 Platform / 1 permissions note. All 133 IDs, original requirements/checks and official citations remain. Code categories and test states are independent, not completion percentages.

Limits remain 20 MP and 8192 pixels per side, 3–512 pixels per seed side, 24 results plus seed with a 25-region review cap, 512 raw candidates, 384 million reserved comparisons, 200 linked marks, one admitted worker with no raster-retaining queue, an eight-second cooperative conversion/search/publication deadline, and 96 MiB algorithm-owned scratch excluding source/CoreGraphics/total RSS. Raw/work/time overflow visibly refuses; completed-search truncation is flagged. Blur/pixelation are cosmetic; solid redaction flattens approved pixels opaque, editor original/undo remain until close. No semantic OCR or arbitrary scale/rotation/font/subpixel/compression/overlap guarantee is made. Both physical backings are 1×; actual Retina/multi-monitor/Spaces/desktop/TCC/external apps and sustained stability remain open.

### Earlier candidate and diagnostic boundary

69f0c4d3 compiled/packaged both architectures but failed strict native geometry. ARM 6579 diagnosed synthetic pointer 31→30.999999999999996 expansion to 145×49; direct matcher geometry was correct. Later interior-pixel gestures/strict seed assertion preserve matcher/export tolerances; stale linked-correction deletion has its own regression. Efeae716/3c898422 early ARM UI/export/control passes were partial, not full acceptance. Complex sorting/CGFloat.infinity test compiler fixes retained assertions; 5ab01891 is an earlier candidate, not current accepted bytes. Independent 6529 / run 37596012807 creates no installers; independent ARM timing 134 tests passed and Intel diagnostic failed, with retry outside this accepted application boundary. These separate diagnostics are not required to delay accepted ARM 0.12 or promote untested Intel packages.

## Retained accepted 0.11 and earlier versioned history

ARM 0.11 below is historical; Intel 0.11 is still the current independently accepted Intel baseline. Every earlier version/hash/run/resource scope remains intact and does not substitute for the current ARM 0.13 evidence.


Reviewed **7 October 2026**. **Accepted ARM and Intel are 0.11.0/build 69 at [3f013417](https://github.com/dandibbert/picshot/commit/3f013417a4bc4e88faa70f0db2ceb61ad2a82b20)**, with independent terminal-success [ARM job 112669106502](https://github.com/dandibbert/picshot/actions/runs/37583758175/job/112669106502) and [Intel job 112669106178](https://github.com/dandibbert/picshot/actions/runs/37583758175/job/112669106178) in run 37583758175. Both architectures have their own exact-source 1,239 ordinary/781 focused/12 real-model and actual ZIP/DMG evidence below. Both architectures’ DMG/ZIP replacements are confirmed at Library version 9, and the combined guide is confirmed at version 17, SHA-256 045b8e5a7254f044eb705619969e658109a039b13c5fb5bd153492398ee88fa3. All saves succeeded with local metadata applied; saving was verified separately from native/package gates. Historical ARM/Intel 0.10, b44c1fb and undelivered ac8 records remain preserved. Native/package acceptance is not full parity, real-device acceptance or leak freedom. All **133 requirements** remain in [PARITY.md](PARITY.md).

The earlier ARM 0.5 delivery at [87eaedf16aaf6c2df2001d35ce08af2762ac33c2](https://github.com/dandibbert/picshot/commit/87eaedf16aaf6c2df2001d35ce08af2762ac33c2), delivered at 15:57 UTC, passed [run 37489170662](https://github.com/dandibbert/picshot/actions/runs/37489170662), [build/package job 112357029365](https://github.com/dandibbert/picshot/actions/runs/37489170662/job/112357029365) and [attribution job 112357029582](https://github.com/dandibbert/picshot/actions/runs/37489170662/job/112357029582). Intel 2043254 changes only `.github/workflows/macos.yml` from that application source. Its annotation effects, camera/live annotations, recovery and corrected isolated GIF export remain included in 0.6. [04999d0](https://github.com/dandibbert/picshot/commit/04999d0fd92a00e11bcbbfd2c9fe813f8ea9f11d), [run 37471951304](https://github.com/dandibbert/picshot/actions/runs/37471951304), remains an earlier both-architecture functionality checkpoint. Results and measurements apply only to their identified source, artifact, process and fixture; identical application code does not make differently packaged bytes or measurements interchangeable. Current ARM 0.7 evidence is recorded separately below; older measurements retain their original provenance.


## Accepted ARM 0.11 at 3f013417, build 69

Application source is **3f013417a4bc4e88faa70f0db2ceb61ad2a82b20**, version **0.11.0/build 69**, terminal-success [ARM job 112669106502](https://github.com/dandibbert/picshot/actions/runs/37583758175/job/112669106502), [run 37583758175](https://github.com/dandibbert/picshot/actions/runs/37583758175). Downloaded logs independently verify **1,239 ordinary tests: 1,236 passed, 3 intentional pre-weight model skips, zero failures; 781 focused and 12 actual-model tests**, zero failures. Actual-model tests run after optional weights are supplied. Stages overlap and must not be added. Bounded-process elapsed times are **323.938 seconds ordinary / 333.212 focused**, both exit 0 under the unchanged **420-second** limits. Native environment is **macOS 15.7.9 (24G830), Xcode 16.4 / macOS SDK 15.5**; minimum macOS 14 runtime is untested.

Both actual installed ZIP and DMG reports identify the exact source and pass architecture/signature, no-argument LaunchServices/visible windows, new pin-OCR and prior capture/recognition, Save/Retry/owned export panels, actual codecs, signed models, managed pin/group/desktop workflows, recording composition and animated WebP. Separate own-child recording recovery also passes. Actual own-app AX remains skipped-no-existing-accessibility-permission; physical Spaces/Retina/TCC/external-app acceptance is not implied. ARM and Intel 0.11 installer saving is confirmed at DMG/ZIP Library version 9, with the combined guide at version 17. Intel has its own final gates and byte verification below; delivery confirmation is not inferred from the ARM results.

### Exact ARM 0.11 bytes

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `PicShot-0.11.0-macos-arm64.build-info.json` | 177 | `060db2d19ca8e77e1fb59ce0c2b003d5c13f6606dab47db79ea2758ae01212ff` |
| `PicShot-0.11.0-macos-arm64.dmg` | 19,824,610 | `34876fdbd59d238907370bb34c4cce30bfc084d80fd09b31e21826bb39d4fc2c` |
| `PicShot-0.11.0-macos-arm64.zip` | 17,122,245 | `12bb4c449ec7fe2a9a9b27d663c86886030ab1dddca36bda75293f51f99f6ffe` |

Actual downloaded bytes match the stated hashes; ZIP CRC passes, embedded build-info is byte-identical to external metadata, and Info.plist agrees on 0.11.0/build 69. Metadata identifies exact source, arm64, macOS 14 minimum, ad-hoc signing and not notarized. The native packaging log verifies DMG internal checksum. These checks are not Developer ID, publisher identity, notarization or Gatekeeper acceptance.

### Functional OCR and restoration evidence

Each installed format makes **two actual functional local Vision calls** over an authored **1000 × 320 CoreText raster**, including a native-menu **en-US rerun**. Automatic completion preserves the sentinel key window/first responder and private clipboard even with direct-copy preference enabled; no result window opens automatically. Selection, copy-all and result consumers reuse one revision/options cache. Bidirectional result/source links, compact optional original preview, unchanged edit spans, new/replaced unmapped text, barcode appendix exclusion and join-lines mapping pass. Source-link controls reuse the caller's recognized document; they do not make extra recognition calls themselves.

The separate coordinator race replays that actual document through a deterministic gate; **no actual Vision runs in this race phase**. It restores **20 pins**, observes **one automatic active + 19 metadata-only waiters**, then explicit copy promotion to **two active / one automatic / 18 waiting**. Initial source reads are one and become two after explicit promotion; queued metadata retains no rasters. Hide, switch-group, click-through, recovery and closure safely cancel, preserving focus and pending-copy clipboard. Its **60 release probes** retain zero tracked controllers/content/overlays/sessions/providers/results and jobs settle to zero. Functional and resource release probes are separately reported; none is whole-process leak evidence.

Historical early native UI reports on both architectures still explicitly have `includeResourceCycles=false`, zero resource calls and `resourceEvidence.status=not-run`. The following **final ARM installed** measurements were separately executed; they do not retroactively turn the early phases into resource passes. Intel's earlier focused group independently passes 781 tests in 332.045 bounded-process seconds. Its early UI/focused results alone were not final acceptance; the subsequently completed Intel final gates and bytes are separately recorded below.

### Installed ARM OCR resources and comparable endpoints

Each format completes **2 warm-ups + 12 measured actual-Vision show/result/close cycles**, **14 actual resource recognition calls and 14 cache reuses**, plus two functional calls outside that phase. Comparable endpoints retain **one fixed authored raster and zero live pins/results/active jobs**. Screenshots are outside the measured loop. **Absolute RSS baselines are observations within the combined installed acceptance process after earlier fixture phases, not clean idle-app memory or OCR-only total cost.**

| Install | RSS baseline → measured end bytes | RSS change bytes / MiB | Last three single-cycle RSS increments bytes | Footprint change bytes | Sampled RSS / footprint peak bytes |
| --- | --- | --- | --- | ---: | --- |
| ZIP | 563,183,616 → 564,494,336 | +1,310,720 / +1.25 | -32,768 / +212,992 / +131,072 | -884,736 | 567,574,528 / 134,451,136 |
| DMG | 585,842,688 → 589,266,944 | +3,424,256 / +3.26562 | +65,536 / +65,536 / +65,536 | +884,736 | 594,411,520 / 150,835,136 |

ZIP footprint is **127,438,784 → 126,554,048 bytes**, last three increments **+180,224 / +868,352 / −704,512**. DMG is **143,544,256 → 144,428,992**, last three **+1,048,576 / 0 / −49,152**. Measured phase elapsed times are **14.548 / 11.197 seconds ZIP/DMG**. Both complete all observations with zero failed RSS/footprint samples, zero retained tracked objects across 14 resource probes, and zero final active/waiting jobs. Extra final cleanup changes RSS by zero in both; footprint by **0 / −1,720,320 bytes**, kept separate from the measured growth. Continuous 50 ms sampling may miss transients and excludes WindowServer/GPU totals. **RSS still grows +1.25/+3.265625 MiB, with positive final intervals; stabilityAssessed=false. No plateau or zero-leak conclusion is supported.**

### Other exact-source ARM resources

| Workload | ZIP RSS change bytes | DMG RSS change bytes | Scope and remaining boundary |
| --- | ---: | ---: | --- |
| Formula pins | +114,688 | +163,840 | 2+12 hide/show/close/restore; zero renders in measurement; same live formula endpoint |
| Group transforms | +704,512 | +786,432 | 3+20; four live pins at comparable endpoints; unchanged assets |
| Editor/pin lifecycle | +294,912 | +131,072 | 10+40; last ten +65,536/+81,920; windows 7→7, no tracked retained controller/content/window |
| Save jobs | +475,136 | +360,448 | 2+8 small real jobs; jobs/input/controllers/owned temporary files released |
| Static WebP/AVIF | +26,034,176 | +24,756,224 | 768×576, three per format with preview/decode/quality/save/cancel; no separate warm-up/phases |
| PNG/JPEG/BMP/PDF | +13,058,048 | +33,849,344 | 1440×900, 1+4; final RSS intervals +2,211,840/+16,384; status observed, not stable |
| Full GIF export plus decode | +114,688 | Not run | ZIP-only 1+4, 30 seconds/360 frames, 480×270 output; last RSS interval 0; real child exit/cancel/cleanup pass |

Formula late RSS increments ZIP/DMG are **0/−49,152/0** and **0/0/+147,456**; footprint changes **+147,456/+147,456**. Group late increments are **0/0/+32,768** and **0/0/0**; footprint **+425,984/+180,224**. Final cleanup has zero live tracked pins and is separate. Save footprint changes **+311,296/+229,376** bytes. Static-codec footprint changes **−1,081,344/+278,528**, while existing-format footprint changes **−5,849,024/+114,688**. Different workloads/phases cannot be combined or attributed to one encoder.

Model-child parent-polled sampled RSS peaks, ZIP/DMG bytes: **350,240,768 / 306,741,248 formula; 225,689,600 / 213,106,688 table; 1,665,515,520 / 1,852,014,592 smart erase**. Every listed child exits 0 with confirmed temporary cleanup; 100 ms samples may miss transients and exclude system services/GPU. The high-resolution 1920×1080/12-frame GIF sample is not maximum area/frame-count or sustained-use evidence.

**Existing export-preview backing growth remains unresolved**: the installed existing-format workload retains **+12.453125/+32.28125 MiB ZIP/DMG**, including positive final intervals, despite application-owned cleanup. The OCR changes are not a general memory fix. The later **da8dde5 diagnostic-only experiment is outside 3f013417**, provides no available 0.11 feature, and changes no production preview default. Earlier 696b/14c and every historical measurement below keep their own source/process/workload provenance.

### Narrow parity decision and remaining scope

`OCR-07` moves to **Code for accepted ARM/Intel 0.11**, covering default-off visible-pin automatic local recognition, passive completion/cache reuse and explicit quick-copy routes. Each accepted 0.11 architecture has **50 Code / 61 Partial / 13 Missing**; historical ARM/Intel 0.10 retains **49 / 62 / 13**. `OCR-04` remains **Partial**: linked source highlighting exists but complete layout/columns/punctuation controls and quality acceptance remain incomplete. Nine macOS-context rows remain **4 Partial / 0 Missing / 4 Platform / 1 permissions note**; all **133 original IDs, requirements, acceptance checks and official citations remain**. Source categories are not completion percentages.

Physical Retina/multi-display/Spaces, real desktop capture and TCC, external-application drag, arbitrary-input/multilingual accuracy, sustained memory and complete PixPin parity remain open. The OCR fixture uploads no screenshots, posts no global input, changes no TCC and downloads no new model. Native Vision cancellation is cooperative; bounded admission is not a process RSS quota. Successful native/installed gates and zero tracked references do not close those acceptance boundaries.

## Accepted Intel 0.11 at 3f013417, build 69

Exact source **3f013417a4bc4e88faa70f0db2ceb61ad2a82b20**, version **0.11.0/build 69**, terminal-success [Intel job 112669106178](https://github.com/dandibbert/picshot/actions/runs/37583758175/job/112669106178) in [run 37583758175](https://github.com/dandibbert/picshot/actions/runs/37583758175). Independent downloaded logs verify **1,239 ordinary tests: 1,236 passed, 3 intentional pre-weight model skips, zero failures; 781 focused and 12 actual-model tests**, zero failures. The native ordinary/focused bounded processes exit 0 in **388.316 / 332.045 seconds**, under the original **420-second** limit. No source or threshold change is used to call the run passing; suites overlap and are not an additive total. Native runtime is **macOS 15.7.9 (24G830), Xcode 16.4 / macOS SDK 15.5**; macOS 14 runtime is untested.

### Exact Intel 0.11 bytes and installed gates

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `PicShot-0.11.0-macos-x86_64.build-info.json` | 178 | `830f07663e5caaba715e355e3122af1e7b0dc1e426d3ae2e9f0d3b0955053fd7` |
| `PicShot-0.11.0-macos-x86_64.dmg` | 23,018,012 | `5c6a2e7f065687c5d2e1b5219aea3237672d359b4afaeb8d1ceb5485790589b4` |
| `PicShot-0.11.0-macos-x86_64.zip` | 19,699,038 | `debe52995f91fb2de78960aae58f005bc6d4e1d2d5307efbe4747e84b9d93bd3` |

Actual downloaded files match the hashes and sidecars. ZIP CRC passes, embedded build-info is byte-identical to external metadata, and Info.plist confirms 0.11.0/build 69/full source; the main Mach-O header is x86_64. Packaging logs verify DMG internal checksum. Ad-hoc signing is not Developer ID, notarization, publisher identity or Gatekeeper acceptance. Native/package acceptance is established here; Intel DMG/ZIP replacements are separately confirmed saved at Library version 9, and the complete combined guide at version 17. ARM packages also remain version 9.

Each actual installed ZIP and DMG independently passes no-argument LaunchServices, visible windows, new automatic pin OCR/source links/restoration, prior capture/recognition, Save/Retry/owned panels, signed codecs, models, managed formula/group/desktop workflows, recording composition and animated WebP. Each OCR functional phase makes two actual local Vision calls including native en-US rerun; cache/focus/clipboard/result/source behavior passes. The separate deterministic 20-pin race replays the actual document with no extra Vision, and 60 probes show no tracked retained objects. Own-child recording recovery passes; actual own-app AX remains skipped-no-existing-accessibility-permission. Physical Retina, Spaces, multiple displays, TCC and external applications are not established by those synthetic AppKit gates. ARM results are not reused as Intel evidence.

### Intel installed OCR resource observations

ZIP and DMG independently complete **2 warm-ups + 12 measured actual-Vision show/result/close cycles**, **14 resource Vision calls and 14 cache reuses**, separate from the two functional calls. Same-workload endpoints retain **one fixed authored raster and zero live pins/results/active jobs**. The absolute RSS baseline belongs to the **combined installed acceptance process after earlier fixtures**, not a clean idle app or OCR-only total cost. Screenshots remain outside the measured loop.

| Install | RSS baseline → measured end bytes | RSS change bytes / MiB | Last three single-cycle RSS increments bytes | Footprint change bytes | Sampled RSS / footprint peak bytes |
| --- | --- | --- | --- | ---: | --- |
| ZIP | 505,561,088 → 504,963,072 | -598,016 / -0.5703125 | +0 / +53,248 / -20,480 | +180,224 | 525,312,000 / 253,730,816 |
| DMG | 511,016,960 → 510,291,968 | -724,992 / -0.69140625 | +8,192 / +36,864 / +8,192 | +114,688 | 538,071,040 / 247,513,088 |

ZIP footprint is **240,496,640 → 240,676,864 bytes**, last three increments **0/+40,960/−20,480**; DMG is **229,421,056 → 229,535,744**, last three **+53,248/−49,152/+8,192**. Measured elapsed times are **13.026/13.121 seconds ZIP/DMG**. Every measured cycle completes, with zero failed RSS/footprint samples, zero tracked retained objects across 14 resource probes and zero final active/waiting jobs. Extra final cleanup changes RSS and footprint by zero in both formats. Sampling is 50 ms, excludes WindowServer/GPU totals and may miss transients. **Net RSS declines do not establish a plateau: DMG's final three RSS intervals and both cumulative footprints are positive. `stabilityAssessed=false`; no zero-leak claim is supported.**

### Other exact-source Intel resources

| Workload | ZIP RSS change bytes | DMG RSS change bytes | Scope and remaining boundary |
| --- | ---: | ---: | --- |
| Formula pins | +131,072 | +57,344 | 2+12 hide/show/close/restore, zero renders during measurement, same one-live-pin endpoint |
| Group transforms | +720,896 | +593,920 | 3+20 numeric transform/undo/inspector/hide/show, same four-live-pin endpoint |
| Editor/pin lifecycle | +978,944 | +270,336 | 10+40; windows 7→7, zero tracked retained controller/content/window |
| Save jobs | +401,408 | +409,600 | 2+8 small real jobs; input/controller/owned temporary cleanup |
| Static WebP/AVIF | +28,057,600 | +27,426,816 | 768×576, three per format; includes preview/decode/quality/save/cancel, no separate warm-up/phases |
| PNG/JPEG/BMP/PDF | +22,884,352 | +24,563,712 | 1440×900, 1+4; observed, not memory-stability acceptance |
| Full GIF export plus decode | +212,992 | Not run | ZIP-only 1+4, 30 seconds/360 frames at 480×270; last RSS interval -16,384; real-child exit/cancel/cleanup |

Formula late RSS increments ZIP/DMG are **+36,864/+4,096/0** and **0/0/0**; footprint **+98,304/+49,152**. Group late increments are **+69,632/−69,632/+4,096** and **0/+8,192/−45,056**; footprint **+327,680/+172,032**. Assets remain unchanged, final tracked objects release, and cleanup is separate from the comparable live-workload endpoints. Editor last-ten changes are **+86,016/+65,536**. Save footprint changes **+61,440/+61,440**. Static-codec footprint changes **−1,703,936/−3,063,808**; mixed phases do not identify a single owner or establish overall stability.

The existing-format preview workload still retains **+22,884,352/+24,563,712 RSS bytes ZIP/DMG (+21.82421875/+23.42578125 MiB)**, with positive final intervals **+28,672/+61,440** and footprint **−2,494,464/+1,232,896**. Its reports say **observed**, not stable. Sessions/queues/owned temporary cleanup does not resolve **known production preview-backing growth**. The net decline in separate OCR measurements is not a fix for that different workload.

Model-child parent-polled RSS peaks, ZIP/DMG bytes: **301,248,512/300,580,864 formula; 184,782,848/185,294,848 table; 1,036,345,344/1,038,028,800 smart erase**. All three actual jobs per format exit 0 and confirm temporary cleanup. 100 ms samples may miss peaks and exclude system services/GPU. Full GIF stress is ZIP-only; 1920×1080/12-frame high-resolution samples do not establish maximum area/frame-count or sustained use.

Both architectures now support the narrow OCR-07 Code classification; OCR-04 remains Partial. Every one of the 133 requirements/citations and all prior versioned evidence remain. Neither architecture establishes broad OCR quality, real-device/TCC/external-app behavior, a plateau, zero leaks or complete PixPin parity. Diagnostic-only da8dde5 remains separate from both 3f013417 app packages and changes no production preview default.

## Historical accepted ARM 0.10 at 03cf310, build 67

[03cf310](https://github.com/dandibbert/picshot/commit/03cf310c4228bdbfdc3f9a81ceec810651552f81), [run 37575644941 / ARM job 112643816594](https://github.com/dandibbert/picshot/actions/runs/37575644941/job/112643816594), passes **1,190 ordinary tests: 1,187 passed, 3 intentional pre-weight model skips, zero failures; 732 focused and 12 actual-model tests passed**. The three ordinary skips require explicitly supplied formula/table/smart-erase weights; the later real-weight stage passes. Stages overlap and are not additive independent totals. Native runtime is **macOS 15.7.9 (24G830), Xcode 16.4 / macOS SDK 15.5**. Embedded metadata identifies 0.10.0, build 67, arm64, macOS 14 minimum, ad-hoc signing and no notarization; macOS 14 runtime is untested.

Both installed ZIP/DMG independently pass expected architecture/signature, no-argument LaunchServices, visible native windows, Save/Retry/owned export panels, actual codecs, signed models, capture/export/recognition, pin sessions/groups, interaction, recording composition and recording WebP. Actual own-app Accessibility remains `skipped-no-existing-accessibility-permission`; no TCC grant or foreign-app acceptance is inferred. Separate own-child SIGKILL recovery passes with five fragments, five seconds recovered, 50 video / 239,552 audio frames decoded, unchanged source and confirmed cleanup; no live devices were started.

### Exact ARM 0.10 bytes and integrity

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `PicShot-0.10.0-macos-arm64.build-info.json` | 177 | `9e9aff7b0a2ba9f5f197fef1f697efbf3ca6280cba726b75eed6bc14671b4b51` |
| `PicShot-0.10.0-macos-arm64.dmg` | 19,656,613 | `ba488d73805e35e2fc48ca641d10bab44c0b471848d4d51ed2b9832b6d07a2d6` |
| `PicShot-0.10.0-macos-arm64.zip` | 16,960,876 | `d71c84a3dd4331f7dafccad9279db59b2727e15280efeee48ac32579352910e4` |

All sidecars match actual downloaded bytes. ZIP CRC checks pass; embedded build-info is byte-identical to external metadata, and Info.plist agrees on version/build/source. The bundled formula runtime checksum and 78 CodeResources file digests match; all 166 application sourceCommit fields in the inspected JSON artifacts identify 03cf310. The native package log verifies the DMG internal checksum and relocated renderer/missing-resource rejection. These checks do not establish notarization, publisher identity or Gatekeeper acceptance.

### New pin functionality and exact scope

- **LaTeX:** actual bundled renderer, retained source/options, atomic edit/invalid-draft/cancel, source copy, ten-source/options undo, restore using stored PNG without automatic rendering, and actual .tex/MathML/SVG/PNG/PDF exports pass in both installs. Recognition uses the same prepared route, but the pin fixture itself does no OCR/model inference. White backing is presentation-only; exported PNG alpha is unchanged
- **Owned Save chooser:** native bounds/visibility/ownership checks keep the same edge-positioned pin exactly 180 × 72 screen points before showing, while open and after real Cancel. Controller/content/source remain intact; callbacks release and no orphan panel remains. The chooser is not a sheet. Remote chooser pixels were not captured; physical Retina/multi-display placement is unverified
- **Group:** shown native manager/context selection, Escape, numeric move/scale Apply, six alignments, undo/redo and constrained-window atomic rollback pass for image, rotated fixed-zoom image and text plus an unselected sentinel. Rollback preserves all live presentations, manifest/index/assets and history. Sizes stay unchanged by alignment; center origins use the destination pixel grid, with possible half-grid residuals. Direct collective drag/resize is absent
- **Desktop policy and dismissal:** public flags, menus, Settings and synthetic lifecycle pass. Same-mode draft preservation and actual-change editor teardown regressions pass in both ordinary and focused tests. `physicalSpacesVerified=false`; global all/assigned-Space selection does not establish named/per-pin placement, active-Space following or original-Space restart restoration

### Installed pin resources: comparable endpoints

All values are **ARM 03cf310**, with independent ZIP/DMG baselines. Formula uses 2 warm-ups + 12 hide/show/close/reopen cycles, **zero fixture-requested renders in the measured phase**; actual render/edit/export occurs outside it. Group uses 3 + 20 transform/undo/inspector/hide/show cycles. Comparable endpoints retain one formula or four group pins; final cleanup has zero and is reported separately.

| Install / workload | RSS baseline → measured end bytes | RSS change bytes | Last three single-cycle RSS increments bytes | Footprint change bytes |
| --- | --- | ---: | --- | ---: |
| ZIP / latex | 104,120,320 → 104,218,624 | +98,304 | +0 / +0 / +0 | +163,840 |
| ZIP / group | 122,372,096 → 122,650,624 | +278,528 | +49,152 / +0 / +0 | -491,520 |
| DMG / latex | 103,268,352 → 103,415,808 | +147,456 | +147,456 / +0 / +0 | +147,456 |
| DMG / group | 122,142,720 → 122,208,256 | +65,536 | +0 / +32,768 / -32,768 | +180,224 |

All four reports complete their observations with zero failed RSS/footprint samples, unchanged asset hashes, zero final live pins and zero retained tracked controllers/content; formula source models also release. Continuous 50 ms sampling includes asset validation/cleanup and can miss transients. Parent measurements exclude WindowServer/GPU/helpers. Bounded releases and flat/negative intervals do not establish a plateau, zero leaks, repeated-render memory behavior or a preview-memory remedy.

### Other installed ARM resources and unresolved preview growth

| Workload | ZIP RSS change MiB | DMG RSS change MiB | Scope / late interval |
| --- | ---: | ---: | --- |
| Editor/pin lifecycle | +0.6875 | +0.34375 | 10 + 40; last ten +0.0625/+0.03125; windows 7 → 7, zero tracked retained content/windows |
| Save jobs | +0.375 | +0.453125 | 2 + 8 small real jobs; footprint +0.328125/+0.28125; jobs/input/controllers/owned temporary files released |
| Static WebP/AVIF | +25.71875 | +24.8125 | 768 × 576, three per format plus encode/preview/independent decode/quality/save/cancel; no separate warm-up or phases |
| PNG/JPEG/BMP/PDF | +25.671875 | +25.890625 | 1440 × 900, 1 + 4; final interval +7.515625/+2.109375 MiB despite session/job/temp cleanup |
| Full GIF export plus decode | +0.015625 | Not run | ZIP-only 1 + 4, 30 seconds/360 frames at 480 × 270; last RSS interval 0; exit/cancel/cleanup pass |

**Existing preview-resource growth remains unresolved.** Static-codec and existing-format measurements have different work/stage scopes; they do not establish an encoder owner or a production memory fix. Model-child parent-polled peak RSS bytes, ZIP/DMG respectively: **354,320,384 / 411,058,176 formula; 193,757,184 / 209,616,896 table; 1,633,583,104 / 1,852,456,960 smart erase**. All exit 0 with confirmed cleanup. GIF's four child self-RSS peaks are 74,694,656 / 74,809,344 / 75,530,240 / 74,956,800 bytes; its separate 1920 × 1080/12-frame self-peak is 179,355,648 bytes. Sampled peaks are not whole-system or kernel lifetime maxima; the short high-resolution case is not maximum square area/frame count or sustained use.

## Historical accepted Intel 0.10 at 03cf310, build 67, attempt 2

Exact source **03cf310c4228bdbfdc3f9a81ceec810651552f81**, [run 37575644941, attempt 2 / Intel job 112653589644](https://github.com/dandibbert/picshot/actions/runs/37575644941/job/112653589644), reached terminal success. Independent downloaded logs report **1,190 ordinary tests: 1,187 passed, 3 intentional pre-weight model skips, zero failures; 732 focused and 12 actual-model tests passed**. The formula/table/smart-erase skips require optional weights; actual-model tests passed after weights were provided. Suites overlap and must not be added into an independent-test total. The bounded ordinary process exited 0 in **363.298 seconds** and focused process in **310.311 seconds**, both under the original **420-second** limits; no source or threshold was changed for this rerun. This supersedes the pending Intel status without converting attempt 1 into a pass.

Native runtime is **macOS 15.7.9 (24G830), Xcode 16.4 / macOS SDK 15.5**. ZIP Info.plist confirms **0.10.0, build 67 and the exact source**; embedded build-info is byte-identical to external metadata and identifies **x86_64, macOS 14 minimum, ad-hoc signing, not notarized**. The main Mach-O CPU type is x86_64. macOS 14 runtime remains untested.

### Exact Intel 0.10 bytes and installed gates

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `PicShot-0.10.0-macos-x86_64.build-info.json` | 178 | `4667672ca5c45c03926a0be66bbe5787acf6e63d8864ace879a8d768131ffc3a` |
| `PicShot-0.10.0-macos-x86_64.dmg` | 22,845,927 | `c4a0a52cfbf757cc962549ce082e2cc736adfb29f1eed92a048f0054f3f01d10` |
| `PicShot-0.10.0-macos-x86_64.zip` | 19,522,397 | `3c5d85ee3f8e076d1b7ffd1c15ebfb57bf97402d665778d7505b8611e7b2b451` |

All three actual downloaded files match their sidecars. Package logs verify the DMG internal checksum and relocated bundled renderer/missing-resource rejection. ZIP and DMG independently pass no-argument LaunchServices and visible native windows, existing Save/Retry/owned panels, actual codecs, signed models, capture/export/recognition, pin sessions/groups, interaction, recording composition and recording WebP. Each installed source-qualified gate identifies 03cf310; ARM output is not Intel execution evidence. Installer replacements are confirmed at Library version 8, with the combined guide at version 15. File checks are not notarization, publisher identity or Gatekeeper acceptance.

Both installed new-pin routes pass actual bundled LaTeX rendering, source/options edits, invalid/cancel/undo/restore and five native export formats. The native owned chooser preserves the same **180 × 72** edge pin before display, while open and after Cancel; content/source remain intact, callbacks release and no orphan panel remains. It is not an AppKit sheet; remote chooser pixels were not captured. Group numeric Apply, six alignments, undo/redo and constrained-window rollback restore all four live presentations and preserve index/manifest/assets/history. Direct collective gestures remain absent; destination-grid center alignment can have a half-grid residual.

Desktop-policy reports independently pass **25 context actions and 27 in-place toggles per installed copy**, unchanged session bytes, no activation-follow flag, closed-controller and original-raster-provider release. Same-mode formula/group draft preservation and actual-change dismissal regressions pass in ordinary/focused tests. `physicalSpacesVerified=false`; these synthetic local AppKit results do not establish actual Spaces/fullscreen/Retina/multi-display behavior. Actual own-app AX remains `skipped-no-existing-accessibility-permission`; TCC and external apps remain untested. Separate own-child SIGKILL recovery passes with five fragments, five seconds recovered, 50 video / 239,552 audio frames decoded, unchanged source and confirmed cleanup; no live devices were started.

### Installed Intel pin resources: comparable endpoints

All values below come from **Intel 03cf310 attempt 2**, with independent ZIP/DMG baselines. Formula uses **2 warm-ups + 12** hide/show/close/reopen cycles and requests **zero renders during measurement**; real render/edit/export occurs in a separate functional phase. Group uses **3 + 20** transform/undo/inspector/hide/show cycles. Comparable endpoints retain one formula or four group pins; final cleanup has zero and its decrease is separate.

| Install / workload | RSS baseline → measured end bytes | RSS change bytes | Last three single-cycle RSS increments bytes | Footprint change bytes | Sampled RSS peak bytes |
| --- | --- | ---: | --- | ---: | ---: |
| ZIP / latex | 70,148,096 → 70,164,480 | +16,384 | 0 / 0 / 0 | +16,384 | 70,217,728 |
| ZIP / group | 106,496,000 → 107,433,984 | +937,984 | +36,864 / −45,056 / +266,240 | +540,672 | 107,499,520 |
| DMG / latex | 70,578,176 → 70,627,328 | +49,152 | 0 / 0 / 0 | +49,152 | 70,696,960 |
| DMG / group | 108,195,840 → 108,613,632 | +417,792 | 0 / +16,384 / +4,096 | −950,272 | 108,904,448 |

All four reports complete every measured cycle with zero failed RSS/footprint samples, unchanged asset hashes, zero final live pins and zero retained tracked controllers/content; formula source models also release. Continuous **50 ms** sampling includes asset validation/cleanup and may miss transient peaks. Parent measurements exclude WindowServer/GPU/helpers. No plateau, zero-leak, repeated-render memory result or production preview fix is established.

### Other installed Intel resources and unresolved preview growth

| Workload | ZIP RSS change MiB | DMG RSS change MiB | Scope / late interval |
| --- | ---: | ---: | --- |
| Editor/pin lifecycle | +0.9921875 | +0.9453125 | 10 + 40; last ten +0.05078125/+0.3046875 MiB; windows 7 → 7 and zero tracked retained content/windows |
| Save jobs | +0.28515625 | +0.375 | 2 + 8 small real jobs; last RSS interval −0.015625/+0.05078125 MiB; footprint +0.02734375/−0.05859375 MiB; jobs/input/controllers/owned temporary files released |
| Static WebP/AVIF | +23.41015625 | +26.3125 | 768 × 576, three per format with encode/preview/independent-decode/quality/save/cancel; no separate warm-up/phases; footprint −1.171875/−2.11328125 MiB |
| PNG/JPEG/BMP/PDF | +25.421875 | +25.44921875 | 1440 × 900, 1 + 4; final RSS interval −0.02734375/+0.0234375 MiB; footprint −0.32421875/+1.12890625 MiB; sessions/jobs/owned temporary files cleaned |
| Full GIF export plus decode | −0.08203125 | Not run | ZIP-only 1 + 4, 30 seconds/360 frames at 480 × 270; final RSS interval −0.03125 MiB; actual children exit, cancellation leaves no destination/partial files, cleanup confirmed |

The final two measured static-codec runs differ by **+8,192/+16,384 RSS bytes ZIP/DMG**, followed by cancellation checks; this is not the final aggregate change. Existing-format reports explicitly use **`status: observed`**, not a memory-stability pass. Their cumulative RSS changes from post-warm-up are **11,583,488 / 21,430,272 / 26,685,440 / 26,656,768 bytes ZIP**, and **10,489,856 / 21,340,160 / 26,660,864 / 26,685,440 bytes DMG**. **Preview-backing growth remains unresolved** despite cleanup and the final flat/negative interval; mixed-codec phases do not identify a single owner or establish a fix.

Actual-model child parent-polled peak RSS bytes, ZIP/DMG respectively: **301,051,904 / 300,511,232 formula; 180,035,584 / 188,461,056 table; 1,022,590,976 / 1,019,252,736 smart erase**. Every recorded model child exits 0 with confirmed temporary cleanup; those peaks use 100 ms sampling, may miss transients and exclude system services/GPU. They cannot substitute for parent measurements or maximum-memory guarantees. Full GIF stress was not repeated from DMG; the separate 1920 × 1080/12-frame case is not maximum square area/frame count or sustained-use evidence.

### Source-qualified candidate history and Intel boundary

- e8209a8 / run 37559437370 compiled on both architectures and passed public desktop flags, but failed LaTeX raster display and group Apply; no release was accepted
- 761c423 / run 37566701405 passed the new early UI on both, then retained one focused assertion: the formula editor view after policy dismissal. Its early resource figures are not final 03cf310 figures
- [Intel ac8a93e / run 37572456117, job 112633899835](https://github.com/dandibbert/picshot/actions/runs/37572456117/job/112633899835) passed 1,190 ordinary (3 intentional pre-weight skips), 732 focused, 12 actual-model and both installed formats at its own source, including the corrected dismissal regression. It is an **undelivered historical candidate**, not current Intel 0.10
- Intel 03cf310 attempt 1 reached the aggregate 420-second ordinary-suite budget. Completed-test runtime increased about 63.1 seconds across suites relative to the prior run; no assertion failure or blocked GIF/Scroll case is established. GIF pre-frame/collision cases returned. Unchanged-source [attempt 2/job 112653589644](https://github.com/dandibbert/picshot/actions/runs/37575644941/job/112653589644) subsequently passed ordinary/focused/actual-model and both installed-format gates under the same limits. It is the accepted, delivered Intel 0.10 result above; attempt 1 remains an unsuccessful historical run

The separate 696b2286 / run 37567338578 decode/draw-helper diagnostic is not a production preview change: at 768 × 576, 2 + 12, the old 40.5 MiB volatile accumulation disappears, but parent RSS still grows 8.484375 MiB ARM / 0.5859375 MiB Intel and median operation time is about 266/572 ms versus 4/20 ms controls. Larger inputs, UI responsiveness and parent-loss orphan cleanup remain open. Existing 0.9 preview-memory caveats remain historical evidence of the unresolved problem, not a claimed 0.10 fix.

## Accepted ARM and Intel 0.9 at b44c1fb

### Historical review status before ARM 0.10

Reviewed **7 October 2026**. **ARM and Intel 0.9.0 build 52 are independently accepted at [b44c1fb0ecc71fbe652ed3c74e377e8f3ea8ba27](https://github.com/dandibbert/picshot/commit/b44c1fb0ecc71fbe652ed3c74e377e8f3ea8ba27)** in [run 37547871044](https://github.com/dandibbert/picshot/actions/runs/37547871044), with terminal-success [ARM job 112556128669](https://github.com/dandibbert/picshot/actions/runs/37547871044/job/112556128669) and [Intel job 112556128799](https://github.com/dandibbert/picshot/actions/runs/37547871044/job/112556128799). Both architecture installer replacements are confirmed; Intel's confirmation is 00:28 UTC. Each result uses its actual ZIP/DMG and own measurements. Earlier candidate failures and diagnostics remain source-labeled history. The **133-row scope** remains in [PARITY.md](PARITY.md); native/package acceptance is not full parity, whole-device acceptance or leak freedom. Diagnostic-only follow-up source 7c3e76c does not replace these accepted installers or change their app source.

Downloaded final logs on each architecture independently report **1,080 ordinary tests: 1,077 passed, 3 intentional pre-weight model skips and zero failures; 635 focused passed; 12 actual-model tests passed**. The selected groups overlap and are not additive distinct-test totals. Both installed ZIP/DMG on each architecture pass architecture/signature, no-argument LaunchServices, visible owned UI, save/naming/Retry, codecs, signed models, interaction, recording composition/recovery and cleanup gates. **Full GIF resource/cancellation runs from ZIP only.** Native evidence is macOS 15.7.9 (24G830); macOS 14 runtime remains untested. Packages remain ad-hoc signed and not notarized.

### Exact ARM 0.9 bytes

Downloaded sidecars match both actual installers and both build-info copies. Metadata identifies 0.9.0, arm64, exact source b44c1fb, macOS 14 minimum, ad-hoc signing and `notarized: false`; package build is 52.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `PicShot-0.9.0-macos-arm64.dmg` | 18,724,951 | `b0d3f8c170d10fe39699a5ebb848b02e3737c8d9457651b81695a504a26ea136` |
| `PicShot-0.9.0-macos-arm64.zip` | 16,184,932 | `956bd7aaa906307ad7fc3b3d1a3d3da63502694e66f3aa1f36304036e721ad8d` |
| `PicShot-0.9.0-macos-arm64.build-info.json` | 176 | `3cc3049cec51954f29167b416bb9f5100ba889d51953a26f3ff40e1cf77979a8` |


### Exact Intel 0.9 bytes and independent gates

The independent Intel logs report **1,080 ordinary tests: 1,077 passed, 3 intentional pre-weight skips, zero failures; 635 focused passed; 12 actual-model passed**. Both installed formats pass startup and source-specific owned-panel, Save/Retry, codecs, models and existing feature/recovery gates. Final Intel focused logs independently pass frozen export bytes, parent movement/close and real-child late-exit/cross-format recovery; ARM is not used as Intel execution evidence.

Every downloaded Intel installer/build-info sidecar matches actual bytes, and duplicate metadata copies match. Metadata identifies source b44c1fb, 0.9.0, x86_64, macOS 14 minimum, ad-hoc signing and no notarization. Tests run on macOS 15.7.9 (24G830), not macOS 14.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `PicShot-0.9.0-macos-x86_64.dmg` | 21,913,370 | `9cdb5ee2ae1cae1b77ddd263f6e8bfc27a10d3c5f149a7d458164fdf0b64d387` |
| `PicShot-0.9.0-macos-x86_64.zip` | 18,689,723 | `5cd57817a28a7aaa5036e4c7b4a8f44bfc6bea847fd875a4230a04e1beddcb1e` |
| `PicShot-0.9.0-macos-x86_64.build-info.json` | 177 | `8607d650dba9799aef6f3995943afedc36db9e2767fd8a27a3d19f1377e0fd48` |

### Final ARM/Intel UI, save and exceptional GIF scope

Production export UI now uses **owned child panels rather than AppKit sheets**. Native tests verify frozen export bytes despite later editor edits, panel placement after parent movement, parent-close cancellation/release, cancel preserving the parent and toolbar hierarchy/alignment. Both installed save reports pass light/dark settings, template rejection/preview, folder/picker cancellation, actual flattened quick-save pixels, Keep Both/Cancel, source preservation, quiet finalized-action copies, exact saved PNG bytes on a private pasteboard and injected copy-failure file preservation. This is source-specific synthetic/native evidence, not general external-app clipboard or physical-user acceptance.

The final focused log passes `testUnconfirmedGIFExitRemovesOuterStageWhileSiblingSurvivesUntilCrossFormatRecovery`. It uses a real test child with injected stop actions to simulate late exit: caller trim is removed while the sibling child retains its independent source; after exit, a WebP/AVIF attempt recovers admission and owned cleanup. Source/old target preservation and ownership/link/race refusal cases also pass. This addresses the specified 0.8 residue scenario. Unknown/replaced entries still deliberately block deletion; **all crashes, power loss and storage removal are not thereby guaranteed clean**.

### Final installed ARM resources, separated by workload

All values below identify b44c1fb installed bytes. They are sampled observations, not maximum-resolution, whole-system or zero-leak acceptance. ZIP and DMG have separate baselines; negative/flat intervals do not establish a plateau.

| Workload | ZIP RSS change MiB | DMG RSS change MiB | Scope and final interval |
| --- | ---: | ---: | --- |
| Editor/pin lifecycle | +0.203125 | −1.000000 | 10 warm-ups + 40 measured; final 10 cycles +0.140625 / 0; windows 7 → 7, zero tracked controllers/content/cycle windows |
| Save workflow | −1.812500 | −1.921875 | 2 warm-ups + 8 small actual jobs; footprint +0.265625 / +0.140625; active jobs/retained input/owned temporary files zero |
| Static WebP/AVIF combined | +20.046875 | +22.281250 | 3 repeated exports per format plus alpha/quality, independent parent decode, preview/save/cancel; no separated warm-up/phases; footprint −9.171875 / −2.296875 |
| Existing PNG/JPEG/BMP/PDF | +10.500000 | +23.546875 | 1440 × 900, 1 warm-up + 4 measured; last RSS interval −12.968750 / +0.015625; sessions/jobs/temporary cleanup confirmed |
| Full GIF export plus decode | +0.109375 | Not run | ZIP: 1 warm-up + 4 measured; final RSS interval 0; actual child exit/cancel/cleanup confirmed |

The combined codec sample does not attribute its retained RSS to encoder, decoder or UI, nor prove a production memory fix relative to differently scoped older runs. Volatile PNG/WebP/PDF preview/raster backing remains a separate unresolved concern. Model helper parent-polled peaks, ZIP/DMG respectively, are **321,110,016/304,037,888 bytes formula**, **223,805,440/225,116,160 bytes table**, and **1,627,324,416/1,840,103,424 bytes smart erase**; all exit 0 and cleanup is confirmed. Sampling can miss transient peaks and excludes framework/GPU/other processes. These child peaks must not replace main-process workload measurements.


### Final installed Intel resources: separate evidence, continuing growth

Each Intel workload has its own baseline and must not inherit ARM deltas. Parent samples and child samples remain separate scopes; the complete GIF resource profile is **ZIP-only**.

| Intel workload | ZIP RSS change MiB | DMG RSS change MiB | Scope and final interval |
| --- | ---: | ---: | --- |
| Editor/pin lifecycle | +0.80078125 | +0.82421875 | 10 warm-ups + 40 measured; final 10 cycles +0.078125 / +0.1875; windows 7 → 7 and zero retained tracked content/windows |
| Save workflow | −1.8359375 | −1.80078125 | 2 warm-ups + 8 small actual jobs; footprint +0.12109375 / +0.03125; tracked jobs/input and owned temporary files cleaned |
| Static WebP/AVIF combined | +23.81640625 | +16.13671875 | No separated warm-up or encode/preview/independent-decode phases; footprint −2.35546875 / −3.1875 |
| Existing PNG/JPEG/BMP/PDF | +29.7421875 | +43.1015625 | 1 warm-up + 4 measured; final RSS interval +10.69140625 / +6.390625; footprint +0.90234375 / +2.84375 |
| Full GIF export plus decode | +0.16015625 | Not run | ZIP: 1 warm-up + 4 measured; last RSS interval +0.01953125; real helper exits/cancellation/cleanup pass |

The existing-format RSS deltas across the four cycles are **2,719,744 / 10,608,640 / 19,976,192 / 31,186,944 bytes ZIP**, and **15,491,072 / 28,176,384 / 38,494,208 / 45,195,264 bytes DMG**, each relative to its post-warm-up baseline. Growth continues through both final intervals despite sessions/jobs/owned-file cleanup. **This remains unresolved; successful cleanup, small footprint changes, or source14c's distinct AVIF delayed drop do not establish stable memory or zero leaks.**

Intel model parent-polled peaks, ZIP/DMG respectively, are **300,613,632/300,126,208 bytes formula**, **185,884,672/186,892,288 bytes table**, and **1,031,409,664/1,020,493,824 bytes smart erase**. All report child exit/cleanup confirmed. GIF children self-sample **47.46484375–47.578125 MiB** during the four-cycle ZIP profile; the separate 1920 × 1080/12-frame child self-peak is **133.00390625 MiB**. Different sampling schedules/process scopes cannot be added as a simultaneous system peak. This short high-resolution case is not maximum square area/frame count or sustained-use acceptance.

### Earlier de4/e4 checkpoints remain history

The prior de4b24a run stopped ARM before app compilation in the bounded-command Python stage (`wrapper_error` hid its underlying report), while Intel exposed a Swift/Darwin API-name collision. [e4e41ba30b0c0d2bfff9cfe14fcf70eeeb0fcf4d](https://github.com/dandibbert/picshot/commit/e4e41ba30b0c0d2bfff9cfe14fcf70eeeb0fcf4d), [run 37545701554](https://github.com/dandibbert/picshot/actions/runs/37545701554), used kevent64 and exposed fuller runner diagnostics. Its earlier compiling/packaging snapshot was not an accepted release and is not the current accepted app state. Final acceptance belongs only to b44c1fb; failed/incomplete candidates are not retroactively changed to passes.

### Earlier 14c: early successes and failed focused suites

[14c09d510247ae700ccdf143994d75b0cbb5f057](https://github.com/dandibbert/picshot/commit/14c09d510247ae700ccdf143994d75b0cbb5f057), [run 37541917737](https://github.com/dandibbert/picshot/actions/runs/37541917737), compiled on both architectures and passed early UI/backing-control stages. [ARM job 112536699632](https://github.com/dandibbert/picshot/actions/runs/37541917737/job/112536699632) then reported **631 focused tests, 35 failures (11 unexpected)**; [Intel job 112536699321](https://github.com/dandibbert/picshot/actions/runs/37541917737/job/112536699321) reported **631 tests, 34 failures (10 unexpected)**. These are failure counts, not a count of failed tests. Neither focused stage passed; final b44c1fb corrections now have their own independent ARM/Intel results, without changing this history.

The inspected ARM `preview.json` identifies 14c and `uiPreviewOnly=true`. Its save-workflow report records light/dark settings preview, invalid-template/folder-cancel checks, flattened quick-save pixels, Keep Both/Cancel collision behavior, source preservation, private PNG clipboard equality, injected copy-failure preservation and quiet final-action automatic copies. Two warm-ups and eight small measured jobs end without tracked active jobs/retained input, with controller release/temporary cleanup observed. No general clipboard, live desktop, network or user preferences are used. These narrow early checks are not full acceptance, sustained resources or a zero-leak result. Intel is not assigned uninspected per-field results from the ARM artifact.

### Accepted ARM/Intel SaveWorkflow scope and remaining gaps

Implemented routes: editor **Quick Save PNG**, **Save PNG and Copy**, **Save and Naming settings**; export-sheet **Quick Save** and **Save and Copy** for the prepared actual format, including current/original pin export routes. Settings drafts require **Save Settings**. A manual first-use folder selection can establish one remembered base directory; it is not per-destination profiles or general picker history.

Folder/filename templates support **{date}, {time}, {width}, {height}, {counter}**, and use the actual encoder extension. Date/time are save-job time in the current timezone with a fixed Gregorian/POSIX formatter, not capture/window/app metadata. Unicode-safe bounded names reject malformed/unknown variables and traversal; the persisted monotonic counter can leave gaps after cancellation. Window/app variables, arbitrary date-format expressions and replacement remain absent.

Automatic copies are **off by default**, require a folder and only follow explicit editor **Copy, Pin or Save-to-history** actions, writing the final flattened PNG. Immediate Copy does not wait for save admission. Capture acquisition, opening history, preview updates, ongoing editing, cancel and OCR do not trigger this path. It is neither continuous autosave nor retention of every raw capture. Application-owned jobs can outlive the editor.

Publication remains **save-new-copy**. Ask collisions offer Keep Both, another name or Cancel; bounded Keep Both suffix searches never replace existing files. An explicitly approved folder resolves once to its physical path; later jobs validate retained descriptors/identities rather than follow substituted ancestors. Source paths, occupied files and link aliases are protected by native-tested b44c1fb checks; unknown/replaced staging is not recursively deleted. Save and Copy commits the file before copying its same encoded bytes/type. Copy failure/cancellation preserves the file; copy failure offers Retry Copy. WebP/AVIF/PDF have no generic PNG fallback, per-type clipboard settings or general drag-out. Private-pasteboard evidence does not prove external-app compatibility.

Configured limits: **two jobs/controllers, 256 MiB estimated retained inputs/artifacts, 128 MiB encoded artifact, eight relative folder levels, 1,024-byte full path, 180-byte rendered component and 10,000 Keep Both attempts**, with a five-minute cooperative deadline. Native calls can finish after cancellation while queued inputs are cleared. These are safeguards, not whole-process RSS ceilings. See [SaveWorkflow.md](SaveWorkflow.md) for reachability, privacy and remaining acceptance.

### Accepted ARM/Intel Retry and scoped GIF cleanup

Accepted ARM/Intel b44c1fb adds visible Retry and cancellable shared GIF/WebP/AVIF-child admission waiting up to **300 seconds**, with stale-generation/close suppression. Delayed-cleanup doubles test scheduling, not actual codecs; genuine-helper and repeated/interrupted native UI evidence must remain separate. Independent final ARM/Intel acceptance is b44c1fb, not e4e41ba.

The verified 0.8 `exitUnconfirmed` outer-trim residue remains historical. Accepted ARM/Intel `OwnedVideoExportStage` separates caller trim from sibling helper jobs with identity-bound ownership; a surviving child keeps its independent source while caller staging can be cleaned. Unknown/replaced entries deliberately block deletion. The real-child late-exit test injects stop actions and exercises subsequent WebP/AVIF admission, source preservation and cleanup; it passes in the final b44c1fb focused suite. The assertion is limited to that workload and ownership scope; earlier failures remain history.

### Source71b diagnostics remain independent evidence

Completed [71b2f4e32cf99508e3efef69d6b5b30ae396b424](https://github.com/dandibbert/picshot/commit/71b2f4e32cf99508e3efef69d6b5b30ae396b424) controls use fresh processes with **two warm-ups plus twelve measured cycles**. Export-only, decode-only and combined modes on both architectures retain positive growth in their final three RSS intervals. Export-only excludes independent WebP/AVIF validation but still includes production PNG staging/preview and helper-preview decoding; decode-only reuses a separately prepared immutable input.

| Architecture / format | Export-only final RSS change | Decode-only final RSS change | Combined final RSS change |
| --- | ---: | ---: | ---: |
| ARM WebP | +28,950,528 B | +28,016,640 B | +50,036,736 B |
| ARM AVIF | +24,608,768 B | +25,919,488 B | +50,413,568 B |
| Intel WebP | +20,045,824 B | +21,319,680 B | +41,746,432 B |
| Intel AVIF | +19,927,040 B | +21,491,712 B | +41,963,520 B |

Footprint is mostly flat relative to RSS growth. No tracked controllers/queued jobs and confirmed fixture cleanup identify neither backing allocation nor owner. Later backing-control results require their own exact-source measurement analysis; **no plateau, purgeability, reclamation, no-leak or whole-system guarantee is inferred here**. These source71b observations do not become measurements of corrected 0.9 code.

### Independent 14c backing diagnostics are not final-artifact measurements

[ImageBackingAttribution.md](ImageBackingAttribution.md) records source14c controls: each architecture has 27 fresh-process controls, normally 2 warm-ups + 12 measured cycles, plus separately labeled 2+48 AVIF comparisons. Direct `TASK_VM_INFO_PURGEABLE` observations identify late **1.6875 MiB/cycle volatile-resident accumulation** in affected preview/native-export/PDF-render and decoded-WebP-raster paths; source creation/snapshot and several full-decode controls do not show that pattern. This is a measured accounting class, not proof that memory has been reclaimed or has zero cost.

ARM AVIF's distinct 48-cycle nonvolatile ledger adds 6.75 MiB early and loses that extra amount during the final 0.5-second settle; Intel is nearly flat. That delayed decrease is not reclamation evidence for accumulating PNG/WebP/PDF preview backing. Source-local cache removal did not demonstrate such reclamation. These diagnostic checkpoints remain separate from b44c1fb installed workloads and do not establish a production remedy, unlimited stability or a no-leak verdict.

### Ledger consequence

No category changes: **48 Code / 61 Partial / 15 Missing** across 124 behavior rows plus nine unchanged adaptation notes, preserving **133 IDs**, original requirements/acceptance checks and official citations. EXP-05/06 now have independently accepted ARM/Intel implementation and native evidence but retain material feature gaps. EXP-04 keeps Code status with b44c1fb Retry/owned-panel evidence. Both architecture results are now independently verified.

## Historical accepted ARM and Intel 0.8 at 7df562b

Downloaded source-labeled logs on each architecture report **986 ordinary tests (983 passed, 3 intentional pre-weight model skips), 541 focused tests and 12 actual-model tests**, all with zero failures. Focused/model selections overlap ordinary coverage; these are not additive distinct-test totals, and ordinary skips are not model passes. Both installed ZIP/DMG on each architecture pass normal startup/LaunchServices, signed helper/runtime checks, new static/animated codec fixtures and the existing capture, interaction, model, composition and recovery gates. Full GIF resource/cancellation remains ZIP-only. Reports identify macOS **15.7.9 (24G830)**; minimum deployment is macOS 14, whose runtime acceptance is still open.

### Exact ARM 0.8 installer bytes

All downloaded installer/build-info sidecars were checked against the actual files, and duplicate build-info copies match. Metadata identifies version 0.8.0, arm64, source `7df562b5c75830b6328d28c585667c761d38f5a2`, macOS 14 minimum, ad-hoc signing and `notarized: false`. These hashes identify exact bytes, not any later build sharing the version label.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `PicShot-0.8.0-macos-arm64.dmg` | 18,260,556 | `a65c9b6e1108fb18323227ddc2baba847dbb8b9a41bf729b3aea8839982725dc` |
| `PicShot-0.8.0-macos-arm64.zip` | 15,763,219 | `ddee7c4bf675c7dddc2518e3f1a6eeaa3b5f7d9445f97af02d73abfab6557dc4` |
| `PicShot-0.8.0-macos-arm64.build-info.json` | 176 | `9d7880245ad2c3b145d0c10cfe070100d84602d9d7b1f584626e500d34055238` |

### Exact Intel 0.8 installer bytes

The independent Intel job passes the same 986/541/12 stage counts with zero failures. Both installed static-codec and recording-WebP fixtures pass, along with prior native/model gates. All installer/build-info sidecars were checked against actual bytes; duplicate build-info copies match. Metadata identifies x86_64, version 0.8.0 and exact source 7df562b, with ad-hoc signing and no notarization.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `PicShot-0.8.0-macos-x86_64.dmg` | 21,403,348 | `1042a2377b3c579d8f3f2284ca61ea7a75e340312125bcff963158b91a9ffb03` |
| `PicShot-0.8.0-macos-x86_64.zip` | 18,232,106 | `8efbfb8a989f39d9c9e2ed1314defe9d87dcadfe3a416ba94d43bc99a605cb33` |
| `PicShot-0.8.0-macos-x86_64.build-info.json` | 177 | `3e9607eb814b7de28f26022d2e831d46a172f03867bb9aa87256d6aebfee08f7` |

### Real bundled still WebP/AVIF, not an ImageIO writer claim

An original C bridge links source-built **libwebp 1.6.0, libavif 1.4.2 and libaom 3.15.0** inside the separately signed on-demand codec helper. These are exact approved upstream pins, with full source/build/license provenance and system-only dynamic linkage documented in [WEB_CODECS.md](WEB_CODECS.md). The dependency-only ARM/Intel checkpoint [51260f2](https://github.com/dandibbert/picshot/commit/51260f2d4122fc9cdba1ad5bdc6f6a6c21677d8b), [run 37521945118](https://github.com/dandibbert/picshot/actions/runs/37521945118), is separate from whole-app acceptance. Codecs are not downloaded on export, and the still writer does not rely on missing ImageIO WebP/AVIF destinations.

At 7df562b, reachable native WebP/AVIF choices provide quality, lossless, preserve-alpha and alpha-quality controls with byte-derived preview and exclusive same-byte save. The original first five formats retain their existing paths. Native UI evidence includes genuine signed helpers, light/dark and regular/compact layout, independent decoded pixels/alpha, explicit alpha-off white composition, source preservation and no-overwrite. The synthetic 160 × 112 UI fixture produces WebP **288 bytes lossless / 422 bytes lossy** and AVIF **1,130 / 574 bytes**, with actual quality 0.37 and alpha quality 0.61 in its lossy cases. These sizes characterize one fixture, not general compression performance.

Both installed formats on each architecture repeat **three lossless WebP and three lossless AVIF exports** of original **768 × 576** pixels. Each output is decoded by the helper for preview and separately by parent ImageIO, with dimensions/type, every premultiplied color/alpha channel and saved-byte checks (pixel comparison tolerance 2). Alpha-off output is checked against white-composited reference pixels. Separate low/high quality runs change both actual bytes and decoded pixels: WebP **7,546 → 12,032 bytes**, AVIF **4,475 → 12,096 bytes ARM / 4,474 → 12,096 bytes Intel**. Collision preservation and ordinary cancellation confirm no published cancelled destination, observed child exit and owned cleanup. These results support **EXP-02 Code** for the integrated formats; broad visual quality, maximum-size and independent target-app workflows remain open.

Still-codec input is bounded to **16 million pixels, 8,192 pixels per side and 80,000,000 encoded input bytes**, with output at **128 MiB**. This is narrower than the existing ImageIO/PDF path's 100-million-pixel source limit. The helper uses a **300-second deadline** and **1 GiB sampled RSS abort threshold**, neither an instantaneous kernel quota nor whole-device ceiling. AVIF encoding is synchronous and internally buffers its native output before bounded forwarding; it is not a streaming/one-chunk-memory claim. One native-export child is shared by GIF/WebP/AVIF, independently of model-helper admission; an in-process ImageIO/PDF operation may still overlap it. Save-new-copy remains mandatory: no existing destination or source is overwritten.

### Static-codec resource observations: combined workload, no warm-up separation

`codec-export-resource.json` reports successful functional/process checks, but its parent memory observations cover the **combined** workload: the six repeated still exports plus alpha-off, low/high-quality and cancellation cases, helper previews and parent independent ImageIO decoding. A frozen source snapshot exists before baseline. There is **no separate warm-up, fresh-process export-only comparison or decoder/UI phase separation**. The word “settled” in per-run fields does not establish a plateau.

| Architecture / install | Parent baseline → final RSS bytes | RSS change | Footprint change |
| --- | --- | ---: | ---: |
| ARM ZIP | 466,157,568 → 505,184,256 | +39,026,688 (37.219 MiB) | −556,928 |
| ARM DMG | 468,959,232 → 508,084,224 | +39,124,992 (37.313 MiB) | −1,556,480 |
| Intel ZIP | 401,805,312 → 443,678,720 | +41,873,408 (39.934 MiB) | +1,187,840 |
| Intel DMG | 407,224,320 → 447,877,120 | +40,652,800 (38.770 MiB) | −3,715,072 |

Each recorded repeated-export child exits 0 with confirmed process exit and owned-directory cleanup. Real cancellation children report `cancelled`, exit 1 and cleanup; all four final fixture directories are removed. Parent RSS/footprint, parent-polled child RSS and child-reported samples are separate scopes; peaks can miss transients and exclude framework services/GPU/other helpers. **Footprint falls in three copies and rises in Intel ZIP; neither pattern nor successful child cleanup explains the retained parent RSS or establishes leak freedom.** These data identify neither allocation owner nor encoder/decoder attribution, and do not demonstrate a plateau, sustained-use bound or whole-system peak. The roughly 37.2–39.9 MiB retained parent RSS remains a specific follow-up investigation on both architectures.

### Animated recording WebP and its input boundary

The production recording preview exports the selected contiguous clip through a signed helper with lossy/lossless, quality, FPS and dimension choices. It is silent, loops indefinitely and writes sequential full-canvas frames, with rounded cumulative millisecond timing. The accepted source remains a regular local self-contained **H.264 MP4/optional AAC**, capped at **1 GiB**. Output limits are **60 seconds, 600 frames, 1,920-pixel maximum dimension, 8 MiB encoded frame and 64 MiB complete file**, with request validation up to 30 FPS. Reaching the frame cap reduces sampling rather than silently shortening selected duration.

All four installed copies pass lossless and lossy selected-range outputs of **12 frames, 1,200 ms, 160 × 90**: ARM files are respectively **5,068/3,028 bytes**, Intel **5,806/3,078 bytes**. These are independent architecture-specific results, not byte-identical output claims. The helper independently demuxes and fully decodes every composited canvas; parent checks container rectangles, positive durations, frame count and full size. Separately, **ImageIO on macOS 15.7.9 independently decodes all 12 frames with all delays totaling 1,200 ms** in each installed result. This compatibility probe is successful runtime evidence, not a universal animation-reader guarantee or a substitute for the helper verifier. Original MP4 bytes and racing destinations remain unchanged. Cancellation at first observed frame progress and after helper publication confirms cancellation fences, child exit and cleanup.

Native animation/container tests cover source-boundary sampling, variable millisecond timing, odd dimensions, lossless/lossy frames and transparent replacement at the low-level writer. **The public H.264 input route does not provide transparent-animation input.** Consequently **REC-03 is Partial**, not Missing, and the original transparency/motion acceptance requirement remains intact. Low-level alpha tests cannot stand in for that reachable end-to-end workflow. Live screen input, broad video formats, real external viewers across OS versions, maximum-size and long-running resource acceptance remain open.

### Historical 0.8 cleanup gap and later source boundary

At 7df562b, the inherited exceptional GIF path remained unresolved: after stop escalation returns **`exitUnconfirmed`**, the outer `.picshot-trim-*` directory is deliberately preserved. Eventual helper recovery removes its nested owned GIF job but does not own the outer selected clip, which can remain on disk. Ordinary confirmed cancellation passes and does not prove cleanup of this condition. The WebP path uses an independently copied private helper input, allowing outer trim cleanup without deleting a still-running helper's files. No complete exceptional-GIF-cleanup claim is made.

Save/queued-child/explicit-Retry and owned GIF-stage changes were not part of accepted 7df562b. Final ARM/Intel b44c1fb now have their own acceptance recorded above; those passes do not change this older build or its measurements. Both architecture results are now independently verified. The tested outer-trim fix does not imply all-crash or foreign-file cleanup guarantees.

### Existing lifecycle and ledger boundary

After 10 warm-ups, 40 measured editor/pin cycles report **+688,128/−2,080,768 bytes ARM ZIP/DMG** and **+1,183,744/+581,632 bytes Intel ZIP/DMG** main RSS, zero retained tracked controllers/content/windows and **7 → 7 windows**. These are separate phases from the combined static-codec measurements and must not replace them. Older GIF attribution remains source-specific history.

The 124 behavior rows now contain **48 Code / 61 Partial / 15 Missing** at verified ARM/Intel 0.8: EXP-02 moves Partial → Code; REC-03 moves Missing → Partial with transparent-input limitations explicit. The nine macOS notes remain three Partial, one Missing, four Platform and one permissions note, preserving **all 133 IDs**, original requirements/acceptance checks and official citations. Both architecture pipelines pass; installer delivery is confirmed separately from CI. Actual AX/TCC, real devices, broad quality, sustained resources and all other incomplete requirements remain open; full parity is not claimed.


## Historical available ARM and Intel 0.7 at a8600a3

[Source a8600a3a4739ec3663a5929d13154a55463ebcbf](https://github.com/dandibbert/picshot/commit/a8600a3a4739ec3663a5929d13154a55463ebcbf) passes both complete architecture jobs in run 37516561276. Downloaded ARM and Intel logs each report **934 ordinary tests (931 passed, 3 intentional model skips), 488 selected critical and 12 actual-model tests**, with zero failures. The selected stages overlap; these are not additive distinct-test totals. The ordinary skips are not model passes. Both actual installed ZIP and DMG on each architecture pass signature/architecture, no-argument LaunchServices, native windows, models, new capture/export/barcode fixtures, existing interaction/composition/recovery and cleanup gates. The full GIF resource/cancellation profile remains **ZIP-only**.

Native reports identify **macOS 15.7.9 (24G830), arm64 and x86_64**. The minimum remains macOS 14, whose runtime acceptance is untested. The packages are ad-hoc signed and not notarized. Native/package gates do not establish publisher identity, Gatekeeper acceptance, physical TCC interaction, foreign-app capture or full parity. Intel 0.7 now passes its independent exact-source pipeline; older 0.6 evidence remains unchanged as history below.

### Exact ARM 0.7 installer bytes

All downloaded ZIP/DMG and build-info sidecars were checked against the actual files; duplicate build-info copies match. Metadata identifies source a8600a3, version 0.7.0, arm64, macOS 14 minimum, ad-hoc signing and `notarized: false`. Installer replacements are confirmed; these hashes identify exact bytes rather than every build sharing the version label.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `PicShot-0.7.0-macos-arm64.dmg` | 14,623,506 | `b6fbdc36fcc6ef785f9476fc9f4a90f8519bec28f7fb5d0e32f40c4ea830234a` |
| `PicShot-0.7.0-macos-arm64.zip` | 13,138,304 | `adca2c077b180fb3b2f5feebf12d127715e2ed77415348d0abbf7fe08940f9a4` |
| `PicShot-0.7.0-macos-arm64.build-info.json` | 176 | `d8431170cc0d3a13c2b6674c96c50a7d6a12edee08d138e51700c4d30bb29b67` |

### Exact Intel 0.7 bytes and independent installed observations

Intel ZIP/DMG and both build-info sidecar copies were checked against the downloaded bytes. Metadata identifies the same source a8600a3, version 0.7.0, x86_64, macOS 14 minimum, ad-hoc signing and `notarized: false`.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `PicShot-0.7.0-macos-x86_64.dmg` | 17,991,358 | `b213b6ae6328df253456eb4b8ad92e98104285d118254506381e071e24a52b47` |
| `PicShot-0.7.0-macos-x86_64.zip` | 15,208,927 | `423fbbcbc9356a4a9f4a8a99a543dfed4b12b10aee221b68fc9084beb570f230` |
| `PicShot-0.7.0-macos-x86_64.build-info.json` | 177 | `d78918f9210c8103eca5a5a04b69cc6f4f76cfe4dd39e08ba29556c9479f3ea6` |

Intel independently passes **934 ordinary tests (931 passed, 3 intentional skips), 488 critical and 12 actual-model tests**, zero failures. Both installed formats pass startup, new capture/export/barcode fixtures and all earlier corresponding feature/model/recovery gates. Actual own-app AX remains skipped for missing existing permission; both codec probes list WebP/AVIF readers but no writers. Seven clean barcode fixtures pass without unsupported skips. The same-source code does not make architecture-specific bytes, timings or memory observations interchangeable.

One installed LaMa fixture completes in **58.132986 seconds ZIP / 87.762908 seconds DMG**, with sampled child RSS peaks **1,025,245,184 / 1,039,495,168 bytes**, respectively (554/813 parent samples at 100 ms). Both exit 0 with process exit and temporary cleanup confirmed. These total fixture timings are not child-only time or general latency guarantees; samples omit transient/system/GPU peaks. The unchanged Intel helper limit is 300 seconds/2 GiB.

The Intel ZIP GIF resource profile records **253,952 bytes parent RSS growth**, with successful child exits/cleanup and cancellation. This is the ordinary four-cycle installed profile, not a new eight-cycle attribution result; the latter remains labeled with original source 87eaedf. DMG does not inherit a separately executed full GIF profile.

### Presets and AX: distinguish executed fake-provider checks from skipped real AX

`CapturePreset`/store/controller and capture/menu/settings routes implement up to **32 metadata-only presets** in a versioned **128 KiB** catalog: name, integral source-pixel rectangle, stable display UUID/configuration and a 0/3/5/10-second delay. Native tests and both installed fixtures pass two-preset persistence/recreated-store, manager create/rename/delay/delete/invoke/cancel callbacks, frozen-pixel geometry and rejection paths. Missing, ambiguous or changed display position/resolution/scale/rotation is rejected rather than silently relocating the region. Actual app restart, delayed live acquisition and physical monitor changes remain acceptance work. This supports the narrow **CAP-06 Code** promotion, not those real-device checks.

The read-only AX provider requests role/geometry rather than labels, values or document text. Its serial worker bounds traversal to **80 nodes, 12 levels, 240 calls and 200 ms**, with **25 ms per-message timeout**; a deadline can overrun by one in-flight AX call. Both installed fake-provider fixtures pass parent/child/undo, stale cancellation, frozen-pixel selection and rectangle fallback. Actual own-app AX reports **`skipped-no-existing-accessibility-permission`** in each format. The aggregate fixture's pass is not an AX pass. Neither permissions nor TCC are changed, no foreign application is tested, and AX geometry sampled after screenshot freeze cannot prove that moving controls still match those pixels. **CAP-05 and MAC-02 remain Partial.**

### Encoded preview, corrected on-screen layout, BMP and paged PDF

The editor, current/original image pins and history route through an owned frozen raster snapshot and PNG/JPEG/TIFF/BMP/PDF sheet. Native tests pass requested-type independent decoding, pixel/dimension/alpha checks, mutable-provider/source-layer isolation, JPEG quality changes, PDF media boxes and exact integral-row/column seams, generation/close cancellation, destination/source/symlink protection and exclusive publication races. PNG/TIFF preserve alpha; JPEG/BMP flatten on white and PDF uses white paper.

Both installed native control/preview/save fixtures report JPEG quality **0.31 / 93,957 bytes**, with saved bytes exactly matching the preview artifact; Letter PDF with **36-point margins / three pages / 246,564 bytes** also saves identical bytes. PDF source row ranges are **[0,816), [816,1632), [1632,1711)**, without a repeated or omitted boundary. BMP has `BM` magic and **3,141,450 bytes**. The PDF bytes/hash may differ between runs; same-byte assertions compare each saved file with its own preview artifact, not a historical PDF hash. These are original synthetic fixture results, not universal codec/interoperability guarantees.

The earlier intrinsic-image window bug is corrected. Final JPEG/PDF content screenshots are **620 × 550**, window frames **620 × 578**, and every action stays inside the native visible frame. A constrained **580 × 480** visible-frame case yields **556 × 428** content / **556 × 456** window, preserving aspect ratio and all controls. Native attached-sheet and compact-layout tests pass. Pixel review of final ZIP JPEG and DMG PDF agrees with the report; broader screen/font/Retina permutations remain unverified.

PDF includes image-sized single page, A4/Letter, portrait/landscape, equal margins and vertical/horizontal pagination with actual encoded-page navigation. It is raster PDF, without searchable OCR, vectors, PDF/A or accessibility tagging. **EXP-03 and EXP-04 move narrowly to Code** for paged output and actual encoded preview. Crop is performed in the editor; the preview is bounded, not a full-resolution pixel display. Independent target-viewer and large/real-image workflows remain acceptance work.

**Save-new-copy only:** both picker validation and final exclusive publication reject existing files, original paths and symlink collisions. A private staged file is synchronized and published without replacement, with cancellation ordered against commit. There is no overwrite/replace-in-place workflow; unsupported filesystems fail rather than weaken that rule. Bounds remain **100 million source pixels, 128 MiB encoded bytes, 200 PDF pages, 1024-pixel/4 MiB decoded preview per page, first-plus-one-page cache up to 8 MiB, two sheets total/one per parent and one serial encoder**. A native codec already running can finish before cancellation releases its resources; these caps are not a measured process-RSS ceiling.

**At 0.7, WebP/AVIF were unintegrated.** All four installed macOS 15.7.9 architecture/format probes list readers but no writers (`not-in-native-destination-list`), so no native encoding/alpha pass is established. There are no format buttons or codec dependencies that add export support. This runtime observation is not a claim about every macOS version/architecture. **EXP-02 remains Partial** despite verified BMP. [ImageExport.md](ImageExport.md) retains implementation limits and official-source research.

### Multiple barcode evidence and limits

Both installed formats run actual Apple Vision and pass all seven original clean-label fixtures with exact text/source geometry: **QR, Code128, EAN13, UPC-A via zero-prefixed EAN13, Code39, DataMatrix and PDF417**, with **no unsupported fixture skips**. Multiple/rotated labels, near-miss rejection, duplicate-location semantics, list/source selection, keyboard copy, transformed geometry and stale/edit/hide/close invalidation pass. Twelve release cycles leave **zero retained barcode surfaces and zero active/waiting recognition jobs**. **OCR-05 and OCR-06 move to Code** for multiple QR browsing and the specifically listed local formats; this does not establish broad industrial recognition quality.

Typed results preserve each complete decoder string and polygon; equal values at separate regions remain separate. Unlocalized values remain available in the list; binary/no-text values and cap omissions are disclosed. Bounds remain **128 results, 4,096 UTF-16 units per value, 65,536 total, 32-million-pixel source and shared two-active/four-waiting recognition admission**. UPC-A equivalence is a separate checked alias; copy retains the native zero-prefixed EAN13 text. Configurable detection modes, damaged/GS1 labels, broad industrial/camera quality and automatic new-pin OCR remain outside these checks.

The HTTP(S) action validates the URL and requires explicit invocation. Recognition, selection and copy do not auto-open payloads. Isolated-pasteboard and injected-opener tests do not prove general clipboard use, real URL opening or physical interaction with an external app. No user screen, TCC database, preference or network state is changed by these fixtures.

### Separate installed export-resource and editor/pin measurements

`image-export-resource.json` is **`status=observed`**, not a threshold-based memory pass. Each installed copy completes one warm-up and **four measured 1440 × 900 cycles**, each serially previewing/encoding/saving/closing PNG, JPEG, BMP and PDF. Main-process Mach RSS/physical footprint are sampled every **50 ms plus explicit boundaries** during source creation through cleanup. These sampled maxima can miss short peaks and exclude WindowServer, GPU and other processes. The separate 160 × 100/two-cycle unit profile is not substituted for this installed workload.

| Architecture / format | Settled RSS change from post-warm-up baseline, cycles 1–4 (bytes) | Final interval RSS change | Final settled footprint change |
| --- | --- | ---: | ---: |
| ARM ZIP | +1,851,392 / +1,867,776 / +2,277,376 / +1,867,776 | −409,600 | −5,029,888 |
| ARM DMG | −262,144 / +2,359,296 / +2,359,296 / +2,359,296 | 0 | −933,824 |
| Intel ZIP | +2,224,128 / +2,306,048 / +106,496 / +2,297,856 | +2,191,360 | −176,128 |
| Intel DMG | −1,527,808 / +2,105,344 / +5,853,184 / +6,111,232 | +258,048 | +3,600,384 |

After every cycle, owned temporary files, active sessions and queued/running jobs are zero; weak controller release is observed. All four final temporary workspaces are removed. These are short fixed-workload observations with no new resource threshold; ARM has a final flat/decreasing RSS interval, while Intel ends with positive intervals and its DMG grows across the last three intervals. Neither pattern is **a plateau, zero-leak, maximum-resolution or long-running claim**. The installed launcher's outer timeout covers non-preemptible native calls.

Separately, the established **10-warm-up plus 40-measured editor/pin lifecycle** phase reports **147,456/98,304 bytes ARM ZIP/DMG** and **520,192/966,656 bytes Intel ZIP/DMG** main-process RSS growth, zero retained tracked controllers/content or cycle windows and **7 → 7 windows**. Earlier model/GIF phases can affect its baseline. These editor/pin figures must not replace the export-resource measurements, helper RSS or whole-system memory.

### Counts and remaining release boundaries

The 124 behavior rows now contain **47 Code / 61 Partial / 16 Missing**. Five narrow Partial-to-Code promotions are CAP-06, OCR-05, OCR-06, EXP-03 and EXP-04. The nine adaptation notes remain **three Partial, one Missing, four Platform and one permissions note**. All **133 IDs**, original requirements/acceptance checks and official citations remain preserved. Code status does not close real-device or full-quality acceptance.

Source-labeled `capture-export-recognition.json`, `capture-presets-elements.json`, `image-export-preview.json`, `image-export-resource.json`, barcode reports/images, codec results, logs and installer hashes underpin these findings. Early UI-only reports still explicitly skip export resource cycles; full installed a8600a3 reports are separate. Actual AX/TCC, foreign-app capture, physical displays/restart, independent export interoperability and sustained resources remain open on both architectures. Existing model/GIF/recovery behavior passes its corresponding source-specific architecture gates without granting OS permissions.

### Historical 0.7 compile and visual failures

Initial [791f2dd9a7e4aac5c15d5e98f6f1ccea5a9578d0](https://github.com/dandibbert/picshot/commit/791f2dd9a7e4aac5c15d5e98f6f1ccea5a9578d0) failed ARM compilation because `BarcodeResultController.document` collided with inherited `NSWindowController.document`. Renamed-property [8e43f67ac223071c1b5870ba30d1f0cb203e3abd](https://github.com/dandibbert/picshot/commit/8e43f67ac223071c1b5870ba30d1f0cb203e3abd), [run 37513586696 / job 112440697858](https://github.com/dandibbert/picshot/actions/runs/37513586696/job/112440697858), compiled/packaged and passed an **early UI-only** stage, including seven real-Vision barcode fixtures, exact-byte JPEG/PDF save and fake-provider/preset controls. Real own-app AX was skipped and repeated export resources were explicitly not run.

That attempt then failed test compilation at `CapturePresetTests.swift:64` on ambiguous `.infinity`. Pixel review also found export content **620 × 1185 JPEG / 648 × 1001 PDF**, too tall for the **1024 × 768** fixture display. Thus it had no ordinary/critical/model suite pass or full visual acceptance. The explicit-CGFloat and non-intrinsic/on-screen layout corrections now pass at final a8600a3; the older failed stages are not retroactively relabeled as passes.

## Historical 0.6: ARM 6a154fb and Intel b0b0eab

[Final ARM source 6a154fb09beb72845a03c2bc68d643901e3bb6ba](https://github.com/dandibbert/picshot/commit/6a154fb09beb72845a03c2bc68d643901e3bb6ba) passed [run 37503402218 / job 112405849837](https://github.com/dandibbert/picshot/actions/runs/37503402218/job/112405849837). Downloaded native logs report **836 ordinary tests: 833 passed, 3 intentional model-dependent skips; 390 selected critical tests; and 12 genuine-model tests**, all with zero failures. Critical/model groups overlap the ordinary suite and are not additive distinct-test counts. Both signed installed ZIP and DMG pass startup/LaunchServices, visible native UI, model exit/cleanup, editor/pin/composition and `interactionParityEvidence`, recorded in `evidence/{zip,dmg}/interaction-parity.json`; recording recovery and the ZIP-only GIF resource/cancellation profile pass. The final scroll reports identify source 6a154fb, Chinese captions and composition of cached transparent content over the effective NSWindow background. This verification-window rendering does not change capture/output raster pixels.

**Release boundary:** the earlier [9b63ddf810a05160dd746750307119cbc1b361e7](https://github.com/dandibbert/picshot/commit/9b63ddf810a05160dd746750307119cbc1b361e7) functionality checkpoint passed **both architecture pipelines** in [run 37498347869](https://github.com/dandibbert/picshot/actions/runs/37498347869), including [ARM job 112388583473](https://github.com/dandibbert/picshot/actions/runs/37498347869/job/112388583473), with the same 836/390/12 counts. Its transparent-window snapshot predates the final composition/localization change. Final `6a154fb` Intel was cancelled without a useful diagnostic log; that establishes neither a successful pipeline nor an identified application defect. Its unchanged-application retry at [b0b0eab9b6db9379a08340119f1e1658d16f20f7](https://github.com/dandibbert/picshot/commit/b0b0eab9b6db9379a08340119f1e1658d16f20f7), [run 37510990742 / job 112431773788](https://github.com/dandibbert/picshot/actions/runs/37510990742/job/112431773788), now reaches terminal success: **836 ordinary tests (833 passed, 3 intentional skips), 390 critical and 12 genuine-model tests**, zero failures, and both installed formats pass all prior feature/model/composition/recovery gates. ZIP alone runs the full GIF resource/cancellation profile. Installer replacements are confirmed; this exact-source result, rather than an inherited pre-final pass, establishes Intel 0.6 availability.

### Exact ARM 0.6 installer bytes

The three downloaded SHA-256 sidecars were independently checked against the actual files. Build metadata records version 0.6.0, arm64, exact source `6a154fb09beb72845a03c2bc68d643901e3bb6ba`, macOS 14 minimum, ad-hoc signing and `notarized: false`. The native run is macOS 15.7.9; it does not establish macOS 14 runtime acceptance. A matching version label alone does not identify these bytes.

| File | SHA-256 |
| --- | --- |
| `PicShot-0.6.0-macos-arm64.dmg` | `5cb298dc2f5cade58d57e5cd9d78e39f6d7d6c54fef352577e5f4cd001fec2a4` |
| `PicShot-0.6.0-macos-arm64.zip` | `83aa56c6dc95e04a84f59baee02754ad1f44f3dcb2eabcd9524a6db2d8ecb580` |
| `PicShot-0.6.0-macos-arm64.build-info.json` | `0a55aee1a3239cea2e3a37b9d40a43ac062659e581137887263f9387e6017fb8` |

The interaction details below were first verified at the 9b63ddf checkpoint and repeated from both delivered ARM 6a154fb and Intel b0b0eab installed formats. They describe original synthetic input and native controls, with separate actual local Vision inference where explicitly stated. They are not user-desktop, physical input or TCC tests.

### Exact Intel 0.6 bytes and bounded installed observations

All three downloaded sidecar hashes were checked against the actual files. Metadata identifies version 0.6.0, x86_64, exact source `b0b0eab9b6db9379a08340119f1e1658d16f20f7`, macOS 14 minimum, ad-hoc signing and `notarized: false`.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `PicShot-0.6.0-macos-x86_64.dmg` | 17,569,678 | `9fefbf7917fc644fc7a8d48619f079321322bb184840bac88a4c1bc5000ac952` |
| `PicShot-0.6.0-macos-x86_64.zip` | 14,823,918 | `53a49bb6bf4e537e0911efcd6344272a15df12097747ecc85807b2a5b733af22` |
| `PicShot-0.6.0-macos-x86_64.build-info.json` | 177 | `063d089760ccc3045810d9c67e7516f9e84645ad537985b933365ba2e7ff93c6` |

Both installed copies pass the 10-warm-up/40-measured-cycle editor/pin workload with **507,904 bytes ZIP / 249,856 bytes DMG** main-process RSS growth, zero retained tracked controllers/content or cycle windows and **7 → 7 windows**. ZIP baseline/final RSS is 410,669,056 → 411,176,960 bytes; DMG is 384,978,944 → 385,228,800 bytes. Each installed actual LaMa path completes in approximately 50 seconds, with parent-polled sampled child RSS peaks **1,034,031,104 bytes ZIP / 1,020,973,056 bytes DMG** and confirmed child exit/cleanup. These are workload observations, not universal latency or whole-system peaks.

The Intel ZIP four-export GIF workload retains **229,376 bytes of parent RSS**, with successful child exits, temporary cleanup and cancellation checks. This is the ordinary installed resource profile, not a new eight-cycle attribution comparison. The independent eight-cycle measurements below retain their original source 87eaedf. DMG does not inherit ZIP's full GIF resource run. Product timeouts, memory bounds and fidelity assertions are unchanged.

### Editable arcs, sectors and bounded polylines

The installed path fixture uses an original **1024 × 760 synthetic desktop at 1×** and native AppKit controls/canvas NSEvents. It verifies editable open arcs and filled sectors, negative sweeps, angle/rotated-endpoint edits preserving the opposite endpoint, correct fill pixels, repeated undo/redo and canceled-drag preservation. Four-node click-built polylines support vertex edits, Return/Finish/double-click commit, Backspace/Command-Z vertex removal and Escape/tool-switch cancellation. Drafts stay out of exports; the 256-point limit auto-finishes with a single undo state. Four-edge toolbar/palette placement and owned UI/cache release pass.

This supports **ANN-01 Code** for the stated geometry row. **ANN-07 remains Partial**: arrow toggles and configurable joins/end caps are still absent. Synthetic 1× pixels do not establish Retina acquisition, physical input, all fonts/scales or real captured-desktop acceptance.

### Real Vision image-pin text selection and native payload paths

The installed fixture runs **actual Apple Vision** on locally authored Latin text and an observational mixed-text image. It verifies word geometry, explicit image orientation, source-coordinate mapping through zoom/scroll, image-edit invalidation, Unicode keyboard/phrase selection and exact copy. It exercises the production native mouse/keyboard handlers and `NSDraggingItem` writer, then has an owned `NSTextView` consume the exact payload on an isolated pasteboard. Drag cancellation, Escape and disabled-overlay pass-through pass. **A physical drag/drop into an external application is not tested.** The user's general clipboard, preferences and permissions are unchanged.

Twelve repeated mode/hide/close cycles retain zero tracked controllers/overlays; all recognition jobs settle. Admission remains bounded to two active/four waiting recognition jobs, 32,768 document UTF-16 units and 8,192 geometry units. These checks support **PIN-18 Code** for its reachable overlay/selection/drag path, not broad OCR/layout accuracy or a zero-leak result. **OCR-07 remains Partial** because new-pin recognition/selection requires explicit enablement rather than running automatically. The separate OCR result window still lacks a complete linked source/layout model.

### Bidirectional scroll projection, reverse Auto-Crop and middle-band edits

Native scroll-controller controls and original coordinate-hashed source pixels exercise signed placement in **both axes and both initial directions**. Reverse Auto-Crop removes the correct edge, supports explicit/mode/minimum-extent direction reset, and restores captured coverage without duplicating sources. Arbitrary selected/numeric middle bands can cross source boundaries, reconnect retained content and survive forward restoration. Undo/redo/apply/cancel restore intervals and cuts; original disk-source bytes remain unchanged. The fixture verifies 25-pixel reverse removal and 80-pixel arbitrary removal crossing two source boundaries in each direction/axis case, plus conservative repeated/ambiguous-content rejection, disk-limit refusal and in-flight cancellation cleanup.

Small-fixture preview/export pixels match, and editor→pin pixels plus an isolated PNG clipboard round-trip pass. **The direct system Copy button is not invoked, and equality of previews scaled from inputs longer than 800 pixels remains unverified.** Final ARM 6a154fb separately verifies the effective-background composition and Chinese labels in its window screenshots; this does not expand the small-fixture edited-raster pixel checks or establish scaled-preview equality. These findings support **LONG-06 and LONG-07 Code**, while continuous manual monitoring, adjustable live capture regions, physical app routing, Retina, real dynamic/fixed page content and maximum-size/long-session resources remain open.

### Installed lifecycle scope and ledger counts

Both delivered ARM 6a154fb installed copies complete **10 warm-up plus 40 measured editor/pin lifecycle cycles**: main-process RSS grows **131,072 bytes ZIP / 589,824 bytes DMG**, with zero retained tracked controllers/content or cycle windows and **7 → 7 windows**. ZIP baseline/final RSS is 490,717,184 → 490,848,256 bytes; DMG is 461,930,496 → 462,520,320 bytes. The earlier 9b63ddf ARM results remain **458,752 bytes ZIP / 344,064 bytes DMG**, also zero retained tracked references and 7 → 7 windows; these are separate measurements, not relabeled final-source results. These bounded synthetic observations exclude whole-system/GPU/helper peaks and do not prove leak freedom.

The **0.6** behavior ledger contains **42 Code / 63 Partial / 19 Missing** rows; only ANN-01, PIN-18, LONG-06 and LONG-07 changed status in that batch. The early source-only 0.7 inventory was 42/66/16. Final native-verified ARM/Intel 0.7 now has **47 Code / 61 Partial / 16 Missing**, with its five narrow promotions described above. Counts identify implementation scope, not full acceptance. All **133 IDs**, original requirements, acceptance checks and official source citations remain intact.

## Verified 0.5: ARM 87eaedf and Intel 2043254

Native evidence is from macOS 15.7.9 (24G830); the package minimum remains macOS 14, whose runtime acceptance is still open. `test.log`, `critical-tests.log`, `model-inference.log`, `recording-recovery.log`, package/UI/smoke logs and `evidence/` identify the exact source. Independent GIF jobs retain their focused-test and attribution logs.

| Stage | ARM 87eaedf | Intel 2043254, with earlier independent 87eaedf GIF evidence labeled |
| --- | --- | --- |
| Ordinary native suite | **764 reported: 761 passed, 3 intentional model skips, zero failures** | Same counts/skips, zero failures |
| Selected critical suite | **287 passed, zero failures** | 287 passed, zero failures |
| Genuine-model suite | **12 passed, zero failures** | **12 passed, zero failures** |
| GIF-focused suite | **123 passed, zero failures** | 123 passed at app-identical 87eaedf in its independent GIF job |
| Installed ZIP/DMG and LaunchServices | **Both pass**, including native UI/model/pin/editor/composition checks | **Both pass** at 2043254, including model exits/cleanup and composition |
| Abrupt recording recovery | **Pass** | Pass |
| GIF resource/cancellation profile | **Pass from ZIP only** | **Pass from ZIP only** at 2043254 |
| Eight-cycle GIF attribution | **Completed with helper exit/cleanup evidence** | Completed at app-identical 87eaedf; not relabeled as a new 2043254 measurement |

The selected critical, model and GIF-focused stages overlap the ordinary suite and each other; these are not additive distinct-test totals. Intentional model skips in the ordinary suite are not model passes.

The ARM ZIP and DMG both pass signature/architecture validation, no-argument LaunchServices activation and visible native windows. Synthetic native annotation effects, signed models, pin/editor cycles, recording composition and recovery are rechecked at 87eaedf. The full GIF/cancellation profile is **ZIP-only**; DMG does not inherit a separately executed GIF profile. ARM recovery again reports its own child SIGKILL (9), five recovered fragments/five seconds, 50 decoded video frames and 239,552 audio frames, with original bytes unchanged and child/temporary cleanup confirmed. Real camera/TCC, Retina acquisition, live screen/audio and visible-preview force-kill remain untested.

### Exact ARM installer bytes

All three downloaded SHA-256 sidecars below were checked against the actual files. Build metadata records version 0.5.0, arm64, exact source `87eaedf16aaf6c2df2001d35ce08af2762ac33c2`, macOS 14 minimum, ad-hoc signing and `notarized: false`. These hashes do not identify another build with the same version label.

| File | SHA-256 |
| --- | --- |
| `PicShot-0.5.0-macos-arm64.dmg` | `10d2c3a2e4b00f88d8d55e7809d51ec1c64601ce2f77a5804c86685cdea8200a` |
| `PicShot-0.5.0-macos-arm64.zip` | `8054c7791c65e5a6c89a532e6042caf77649bd675fd9d124d645daa330fcd536` |
| `PicShot-0.5.0-macos-arm64.build-info.json` | `2bec7a2e75bab9de8cea24e9f4e2a454291224a8e5efdf8ab58d5c3facaf65a4` |

### Exact Intel installer bytes and installed evidence

All three Intel SHA-256 sidecars were checked against downloaded bytes. Build metadata records version 0.5.0, x86_64, exact source `204325409123a07dc8a1bd472817a0ca38664092`, macOS 14 minimum, ad-hoc signing and `notarized: false`.

| File | SHA-256 |
| --- | --- |
| `PicShot-0.5.0-macos-x86_64.dmg` | `f92de567db034ecb986f11e9447390f096cb60f55b8200a8f5ca43e952b08f16` |
| `PicShot-0.5.0-macos-x86_64.zip` | `3f7cd767c96632ab89a8b4eb5ce172514a235fcf41acaaa2e1f6fcfee9a3078a` |
| `PicShot-0.5.0-macos-x86_64.build-info.json` | `e181a7187a1736124d985b6d29ab77a6f276d4e1d7ef1dbfd479379e0a275f11` |

Both Intel installed formats pass normal startup/LaunchServices, visible native windows, signed formula/table/smart-erase model paths, confirmed model-child exit 0 and temporary cleanup, recording composition and lifecycle checks. The installed smart-erase fixture reports **53.5869 seconds ZIP / 50.6499 seconds DMG** for one successful production-helper job in each copy, retaining all outside-mask/alpha bytes. These fixture elapsed times are not a universal inference-latency guarantee or the child-only timing field.

After ten warm-ups, **40 measured editor/pin lifecycle cycles** retain **987,136 bytes ZIP / 827,392 bytes DMG** of main-process RSS. Both end with zero retained tracked controllers/content or cycle windows and **7 → 7 windows**. This is a bounded main-process observation, not whole-device memory or a zero-leak result. Intel recovery again confirms own-child SIGKILL (9), five fragments/five seconds, 50 decoded video frames and 239,552 audio frames with source preservation and cleanup. The full GIF/cancellation profile passes from ZIP only: cancellation confirms child exit 1, `cancelled`, destination absent and cleanup; DMG explicitly records that profile as not run.

### Isolated GIF export: measured improvement with residual parent growth

At source **87eaedf**, each architecture compares its own **same installed binary** in fresh-process in-process-baseline and isolated-helper modes: one warm-up, then eight 30-second/360-frame exports from authored 640 × 360 media to 480 × 270 GIFs. These attribution measurements predate the workflow-only 2043254 Intel packaging run and retain their original provenance. There are zero GIF decoder validations before/during measured export cycles, followed by one final full-file validation. AVFoundation video decoding is still part of export. Independent decode-only runs warm up and read one immutable GIF eight times with no intervening exports.

| Architecture | Baseline export-only retained RSS bytes | Isolated-helper parent retained RSS bytes | Baseline / helper-prepared same-file decode-only retained RSS bytes |
| --- | ---: | ---: | ---: |
| ARM | 102,678,528 (97.922 MiB) | 1,720,320 (1.641 MiB) | 360,448 / 622,592 |
| Intel | 225,280 (0.215 MiB) | 159,744 (0.152 MiB) | 1,110,016 / 1,454,080 |

ARM helper-parent final physical-footprint growth is **0 bytes**, but **all eight settled RSS intervals are positive** and the final three add **491,520 bytes (0.469 MiB)**. The report key `lastFourObservationGrowthBytes` is the difference between four observations, meaning three intervals. This is substantial containment of retained parent RSS relative to the same-binary baseline, **not a demonstrated plateau or zero leak**. Same-file decode reuse may benefit from OS/framework caches and does not exclude new-file or cross-export decoder retention. The underlying native allocation owner remains unidentified.

For the ARM isolated export sequence, **all nine helpers including warm-up exit 0**, with child exit and owned temporary-directory removal confirmed. Child-reported sampled RSS peaks range **72,613,888–75,005,952 bytes (72.6–75.0 MB decimal)**; the parent's independently polled child RSS peaks range **58,376,192–65,732,608 bytes (58.4–65.7 MB decimal)**. They observe the same child at different sampling boundaries and must not be added together. Parent RSS/footprint, child self-samples and parent-polled child samples are separate scopes; none is a synchronized whole-app/system peak. Sampling can miss transient peaks and excludes other helpers, framework-service processes and GPU memory. One GIF job may overlap one model job because their admission gates are separate.

The ZIP cancellation fixture requests cancellation after 36 parent-observed frame-progress messages. It confirms `cancelled`, **child exit 1**, destination absent, no partial files and child/staging cleanup. Queued progress does not establish an exact child-frame stop count. Existing codec, output/input, time and resource envelopes remain unchanged; neither this bounded workload nor cleanup success establishes sustained recording, maximum-resolution or real-device acceptance.

### Intel failure history and final resolution

[Intel build job 112357029587](https://github.com/dandibbert/picshot/actions/runs/37489170662/job/112357029587) first failed because `testRealCoreMLRemovesMarkedObjectAndPreservesOutsidePixels` took **314.905896243 seconds**, exceeding the unchanged **300-second** assertion. Its image/preservation checks passed, but that attempt remained a real-model gate failure and skipped installed smoke. The same-source 87eaedf retry passed the model gate, then reached the outer CI time window during smoke; it was not a complete pass either.

Workflow-only 2043254 introduced an independent **40-minute Intel CI lane** and completed the full pipeline in [run 37496626993 / job 112382709941](https://github.com/dandibbert/picshot/actions/runs/37496626993/job/112382709941). **No application timeout, memory envelope or fidelity threshold was weakened**; the application implementation is identical to delivered ARM 87eaedf. Both 0.5 architectures are now available. Earlier failed/incomplete attempts remain recorded rather than being relabeled as successful.

## Historical functionality checkpoint at 04999d0

Both architecture jobs in run 37471951304 passed on macOS 15.7.9 (24G830). This is not a macOS 14 runtime result. Evidence is in that run's architecture-specific QA artifacts, including `test.log`, `critical-tests.log`, `model-inference.log`, `ui-preview.log`, `package.log`, `smoke.log`, `recording-recovery.log` and `evidence/`.

| Stage | arm64 and x86_64 result | Boundary |
| --- | --- | --- |
| Ordinary native suite | **689 tests reported, 3 intentional model-dependent skips, zero failures** | The skipped cases are not model passes |
| Selected critical stage | **204 tests passed, zero skips/failures** | Overlaps the ordinary suite |
| Genuine-model stage | **12 tests passed, zero skips/failures** | Also overlaps; do not add these stages into a distinct-test total |
| Native annotation/UI | **Passed**, including all four effects and their flattened outputs | Original 1× synthetic desktop, native AppKit controls/synthetic events; no real desktop capture, physical input or TCC |
| Installed ZIP and DMG | **Passed on both architectures** | Launch/signature/architecture, model, pin, editor and recording-composition checks for this exact source |
| Installed recording composition | **One warm-up plus three measured cycles passed per ZIP/DMG install** | Synthetic camera/screen, production compositor/controller/writer and actual H.264 decode; no hardware capture |
| Installed abrupt recovery | **Passed on both architectures** | A signed installed app killed only its own unfinished writer child, then recovered and decoded the bounded synthetic media |
| Existing GIF resource profile | **Passed from ZIP only** | The in-process writer's configured regression envelope; not helper isolation or proof of a plateau |

### Annotation effect evidence

ANN-11–14 have reachable native controls and verified pixel paths at 04999d0. `evidence/ui/annotation-effects-preview.json` reports `status=passed`, all owned editors closed and original raster preserved:

- Brush/rectangle eraser removes preceding ink without erasing the captured base or later marks. Native gestures, Escape/cancel, clear and repeated pixel-identical undo/redo pass
- Spotlight varies shape, dimming and border; its interior remains unchanged, exterior dims and light/dark appearance does not alter export. Native tests also check stacking and transparent-base alpha
- Watermark supports tiled/anchored text, opacity/spacing and frozen date/timezone substitution. Native controls and repeated undo/redo preserve the timestamp. Imported images are labeled with editing-start time rather than an invented capture time
- Magnifier moves source and lens independently, with shape/scale/connector/smoothing/shadow controls. Export tests preserve redactions even when ordinary annotation visibility changes or a redaction is added after the lens

The main fixture desktops are 1024 × 768 ARM and 1920 × 1080 Intel, both 1×. The earlier ARM preview set at source `535833a` contains the same annotation code; it is also an **original 1× synthetic desktop**, not user-screen or Retina evidence. The 04999d0 artifacts provide an exact-batch repeat. Raster bounds and released fixture windows are not a sustained-memory or leak measurement. These tests support Code status for the narrow ledger rows, not complete parity acceptance.

### Installed recording composition and color

Each `evidence/{zip,dmg}/recording-composition.json` reports three measured cycles after one warm-up. Each cycle encodes and decodes seven H.264 frames at 640 × 360 / 10 FPS for 0.7 seconds, with 95 decoded pixel checks. Synthetic quadrants and gray/color ramps verify placement, resize, mirror/crop, live pen/eraser, static-screen updates, pause removal and the frozen Stop snapshot. The source/compositor input is sRGB; encoded properties are BT.709, with decoded ramps checked in sRGB against a 12-channel-value tolerance. Frame packets are adjacent with positive durations; the synthetic one-second pause is absent from output.

Four production pipelines and four overlay controllers are created and released per installed copy, with no tracked objects, retained writer-frame references, camera slots or temporary files left after each cleanup. Resource samples cover the **main process only**, including composition, encode, decode and cleanup: a 50 ms timer plus explicit boundaries, not kernel peaks. They exclude GPU and AVFoundation service memory.

| Architecture / format | Sampled peak RSS / footprint MiB | Settled RSS / footprint growth MiB |
| --- | ---: | ---: |
| arm64 ZIP | 129.594 / 66.049 | -5.078 / +7.297 |
| arm64 DMG | 127.703 / 65.830 | -4.266 / +0.125 |
| x86_64 ZIP | 86.094 / 41.066 | -7.375 / -2.281 |
| x86_64 DMG | 91.629 / 45.527 | -7.297 / -2.031 |

These short fixed-resolution observations pass the configured envelope; falling RSS is not a zero-leak result. The fixture directly calls production overlay-controller methods and invokes the refresh handler on a deterministic encoder clock. It creates no overlay window, posts no physical input, and does not exercise timer scheduling, camera provider/hardware, TCC, Retina placement, actual ScreenCaptureKit window exclusion or live screen/audio sync. The source behavior and remaining device checks are described in [RecordingOverlays.md](RecordingOverlays.md); its authored-test inventory is not itself execution evidence.

### Installed journaled recovery

Both `evidence/recording-recovery/recovery.json` reports identify 04999d0 and `status=passed`. Each confirms its own child exited from **SIGKILL (signal 9)**, discovers one interrupted capture, and recovers **five complete fragments into a five-second MP4**, fully decoding **50 video frames and 239,552 non-silent audio frames**. Expected synthetic video colors pass. Original source bytes remain unchanged; child exit and temporary-directory cleanup are confirmed. Screen, camera and microphone started flags are all false.

Saved-preview journal reopening and explicit dismissal also pass, preserving the movie. This models reopening a fresh store; **the visible preview window was not force-killed**. Recovery remuxes only complete owned journaled fragments to a new file; it does not resume devices/capture, reconstruct missing fragments or adopt arbitrary legacy MP4s. Native tests separately cover real writer cancellation, protected-file survival, torn tails, malformed inputs and source preservation. Power loss, storage removal and real hardware/permission timing remain open. [RecordingRecovery.md](RecordingRecovery.md) records the transaction, limits and remaining acceptance gates.

## GIF helper chronology: failures, diagnosis and corrected 87eaedf result

The initial candidate [f65f4749cd00972c8e539aea7e856118ded5e06b](https://github.com/dandibbert/picshot/commit/f65f4749cd00972c8e539aea7e856118ded5e06b), [run 37474097686](https://github.com/dandibbert/picshot/actions/runs/37474097686), compiled, packaged and passed synthetic UI. Its first ARM focused stage instead reported **276 tests with 17 failures (7 unexpected)**. `critical-tests.log` showed legitimate production-style MP4s rejected as `invalidSource`, preventing successful export/cancellation/collision paths, alongside a child-readiness timeout and orphan-cleanup assertion failure. This remains historical evidence, not the latest failure count.

Subsequent native source [01d8951ea5c16c473ad2e8e287055a1dd8f45706](https://github.com/dandibbert/picshot/commit/01d8951ea5c16c473ad2e8e287055a1dd8f45706), [run 37484485789](https://github.com/dandibbert/picshot/actions/runs/37484485789), **compiled, packaged and passed synthetic UI on both ARM and Intel**. Each architecture's focused stage reported **285 tests, exactly four authored decoded-pixel assertion failures and zero unexpected failures**. Genuine signed-helper exports, admission, short-line progress, cancellation/orphan cleanup, protocol and output-verifier tests passed. Successful export and process cleanup did not turn the incorrect boundary frames into a semantic pass; that commit's focused stage failed.

The cause was isolated with production-identical, test-only instrumentation at [0b5f997835ee5ba1d265874678454c19a602461c](https://github.com/dandibbert/picshot/commit/0b5f997835ee5ba1d265874678454c19a602461c), [run 37487357552](https://github.com/dandibbert/picshot/actions/runs/37487357552). Raw timing logs and parsed/reconstructed JSON record compressed/decoded source timestamps, requested/actual generator times, GIF pixels and independent nearest-tick probes. Independent source decoding has the correct boundary content. In both architectures, binary Double values just below the intended boundary truncate during CMTime conversion:

| Intended time | Production request at timescale 600 | Selected preceding source time | Nearest-tick probe request / actual |
| --- | --- | --- | --- |
| 0.2 s | 119/600 | 60/600 | 120/600 / 120/600 |
| 0.8 s | 479/600 | 420/600 | 480/600 / 480/600 |
| 1.6 s | 959/600 | 900/600 | 960/600 / 960/600 |

Nearest-tick probes return the intended boundary frames on ARM and Intel, while the original production requests select preceding frames. Matching GIF/source-generator pixels further localize these failures to request-time construction rather than GIF palette/LZW assembly. These are targeted diagnostic observations on authored fixtures, not a corrected production run or a universal codec-fidelity claim.

The narrow shared-rounding correction is present in **87eaedf**, with unchanged-threshold boundary-pixel regressions passing in its critical/GIF-focused stages on both architectures. The ARM final pipeline, app-identical Intel 2043254 final pipeline and both architectures' source-labeled eight-cycle isolated attribution have results above. The original failures and diagnostic probes remain history rather than being relabeled as passes. Both 0.5 architectures are available; real-device, broad-quality and sustained-resource acceptance remain open.

[GIFExport.md](GIFExport.md) describes the production process boundary at 87eaedf: one on-demand same-executable child, with a **regular local self-contained H.264 MP4/optional AAC input cap of 1 GiB** and no silent in-process fallback. This is narrower than general video input or the recording/recovery maximum; larger otherwise valid recordings are not silently accepted for GIF. One GIF job has a separate admission gate from the ML gate, so one GIF job may overlap one model job. Recorded evidence separates parent RSS/footprint, parent-polled child RSS, child-reported RSS/footprint, child exit and cleanup; those scopes exclude other helpers, framework services and GPU allocations. Bounded measurements do not remove those limits or establish a system-wide resource guarantee.

## Delivered 0.4 run and artifacts

Both jobs ran on GitHub-hosted macOS 15.7.9 (24G830), Xcode 16.4 / macOS 15.5 SDK. The package minimum is macOS 14; this run does not establish macOS 14 runtime compatibility.

| Stage | arm64 and x86_64 result | Boundary |
| --- | --- | --- |
| Ordinary native suite | **561 tests reported, 3 intentional weight-dependent skips, zero failures** | A skipped case is not a model pass |
| Selected critical stage | **87 tests passed, zero skips/failures** | Overlaps the ordinary suite |
| Genuine-model stage | **12 tests passed, zero skips/failures**, using original-source SHA-256-verified optional weights | Also overlaps; do not claim 660 distinct tests |
| Streaming GIF writer | **9 new tests passed** within the suites above | Parser/truncation, native palette/LZW preservation, alpha rejection, caps, cancellation and cleanup; not nine extra tests |
| Native UI | **Revised installed-AppKit fixture passed** | Synthetic desktop at 1×, no TCC, screen capture or OCR inference |
| Installed packages | **ZIP and DMG passed on both architectures** | Signature/architecture, no-argument LaunchServices, visible native windows, signed model paths, pin sessions and editor cycles |
| GIF resource profile | **Passed from each architecture's ZIP install** | Not repeated from DMG; residual growth remains below the configured regression envelope |

All six accompanying SHA-256 files (four installers and two build-info files) were checked against downloaded bytes. Build metadata identifies `6c808a5edc2b36ba12a38706239a965386edb03b`, version 0.4.0, architecture, ad-hoc signing and `notarized: false`.

| Installer | SHA-256 |
| --- | --- |
| `PicShot-0.4.0-macos-arm64.dmg` | `672b80ecc749f8fa788d9c928977c454864731a860af33c7253c2f12528018bf` |
| `PicShot-0.4.0-macos-arm64.zip` | `3dfa9067f99c98f16657a93ebdf7d0dae160993ad4b048ff836dffe021244fe0` |
| `PicShot-0.4.0-macos-x86_64.dmg` | `6eeadfad7b59bef934c34af5be9970b7fa894e7e6ee48b5a0fa9a5e5b0398da1` |
| `PicShot-0.4.0-macos-x86_64.zip` | `56d4264020a666e7ab41688d81a54f2896ac885bf233c880d9e19a0ba563c295` |

QA artifacts contain `test.log`, `critical-tests.log`, `model-inference.log`, `package.log`, `ui-preview.log`, `smoke.log` and `evidence/{ui,zip,dmg}`. They include `launch.json`, `model-evidence.json`, `pin-session.json` and ZIP-only `gif-resource.json`. GitHub artifact retention is 14 days. These hashes identify exact bytes, not a later build sharing the version label.

## Delivered 0.4 native UI and functional fixture scope

- The frozen-desktop fixture is **1024 × 768 on ARM and 1920 × 1080 on Intel, both 1×**. Actual AppKit toolbar/canvas events exercise rectangle drawing, inline text accept/cancel, styled text, light/dark surfaces, capture-boundary resize/undo/Escape/redo, preserved annotation placement, pin Space-open/cancel and dark OCR-result presentation. It uses original synthetic pixels; no user screen, TCC database, OCR inference or system preference is modified
- Genuine formula recognition passes three authored image fixtures. Installed formula recognition returns `E = m c ^ { 2 }`; local MathJax produces the preview plus SVG/MathML/PNG/PDF. This does not establish multi-formula segmentation, editable Office OMML, Typst/AsciiMath or broad recognition accuracy
- The native table helper uses real SLANet-plus structure and Apple Vision text. Installed results retain four rows/three columns. Structured editing and OOXML/ZIP tests pass; the known high-confidence rowspan misprediction remains a rejection case, and independent Excel/LibreOffice UI acceptance remains open
- All four installed smart-erase fixtures change 12,302 masked pixels, preserve every outside-mask RGB byte and alpha byte, and leave no new job directory. Masked RGB MAE falls from 98.8802269 to about 1.5883. This covers one successful 800 × 800 production-helper job per installed copy, not arbitrary images or forced timeout/crash/cancellation
- Translation request/state tests and weak framework linkage pass. Actual Apple language download, successful/offline translation and macOS 14 launch remain untested

Weights remain optional external data from pinned original publisher locations, verified by exact size/SHA-256, never committed or bundled as model weights. Model provenance/licenses are in [MODELS.md](MODELS.md), [TABLE_MODEL.md](TABLE_MODEL.md) and [SmartErase.md](SmartErase.md); the recording-GIF architecture and limits are in [GIFExport.md](GIFExport.md).

## Delivered 0.4 main-process lifecycle measurements

Each installed copy performs **10 warm-up plus 40 synthetic editor/pin create-render-close cycles**. All end with 7 → 7 windows, zero retained cycle controllers/content and zero retained cycle windows. RSS below is the main process during that phase, not whole-app-plus-helper or peak inference memory; earlier model/GIF phases may affect its baseline.

| Architecture / format | Baseline → final RSS bytes | Delta MiB | Sampled peak RSS MiB |
| --- | ---: | ---: | ---: |
| arm64 ZIP | 268,632,064 → 269,008,896 | +0.359 | 256.656 |
| arm64 DMG | 153,255,936 → 154,091,520 | +0.797 | 147.031 |
| x86_64 ZIP | 110,010,368 → 110,817,280 | +0.770 | 105.684 |
| x86_64 DMG | 114,003,968 → 115,261,440 | +1.199 | 109.922 |

A separate **3-warm-up plus 20-cycle pin-session fixture** exercises hide/show, archive/reopen, group switching, saved original/current presentation, new-store restoration guards and explicit removal in a temporary store. All four pass 54 weak release probes with zero retained pin controllers/content or empty panels; temporary directories are removed and user defaults stay unchanged.

| Architecture / format | Pin-session RSS delta MiB |
| --- | ---: |
| arm64 ZIP | -1.312 |
| arm64 DMG | -1.375 |
| x86_64 ZIP | -1.152 |
| x86_64 DMG | -1.289 |

These bounded synthetic observations are not a sustained-use or zero-leak result. File-reference drag behavior, every rich-pin decoder, physical monitor removal and real restart scenarios still require broader acceptance.

## Delivered 0.4 signed model-child resource evidence

All recorded formula/table/inpainting children exit with status 0, confirmed process exit and confirmed temporary-directory cleanup. The service samples **child RSS every 100 ms** while the child runs. Values below are maximum successful samples; transient peaks between samples and separate system/GPU-service allocations are not included. They are not kernel lifetime peaks or complete device memory use. Counts in parentheses are actual successful RSS samples.

| Architecture / format | Formula peak MiB (samples) | Table peak MiB (samples) | Erase peak MiB (samples) | Erase child runtime s |
| --- | ---: | ---: | ---: | ---: |
| arm64 ZIP | 360.188 (12) | 203.609 (13) | 1872.219 (150) | 16.295 |
| arm64 DMG | 316.031 (9) | 228.375 (14) | 1482.062 (181) | 19.517 |
| x86_64 ZIP | 287.012 (24) | 175.781 (23) | 965.914 (758) | 77.800 |
| x86_64 DMG | 286.738 (17) | 177.543 (24) | 971.996 (698) | 71.637 |

Configured caps remain formula/table **1 GiB / 120 seconds**, smart erase **2 GiB / ARM 150 seconds or Intel 300 seconds**. Those are limits, not observed peaks. The largest sampled erase value here is about 1,872 MiB on ARM; passing this fixture does not guarantee headroom for every input or machine. The table covers three inference helpers, not every process or a formula-render-helper RSS peak. Main-process lifecycle results above must not be substituted for these child measurements.

## Delivered 0.4 streaming GIF and subsequent attribution

The published writer replaces the old multi-frame ImageIO destination with **one native still-frame encode at a time plus file-backed GIF89a assembly**. Native palettes/LZW payloads are preserved. The encoded frame buffer is capped at 8 MiB and final output at 64 MiB. Screen-recording export supports **opaque frames only**: actual transparent/fractional-alpha frames fail explicitly rather than being flattened or incorrectly composited. Alpha-capable storage with genuinely opaque pixels remains supported. This restriction does **not** change animated GIF/WebP pin decoding.

On each architecture, ZIP runs one warm-up then **four measured exports** from an authored changing 640 × 360, 30-second, 12-FPS source, exporting 360 frames at 480 × 270. All output frames decode serially with ImageIO caching disabled, distinct thumbnail fingerprints and approximately 30-second playback. Fingerprints check diversity, not full fidelity. Cancellation at frame 36 is observed without publishing the destination or leaving partial files. A separate one-shot 1920 × 1080 / 12-frame export also passes; it is not a maximum-square-area, maximum-frame-count or plateau test. No live recording/audio or external download occurs in this fixture.

Measurements cover the **main process only**, excluding AVFoundation services and GPU memory. Export-only peaks are sampled before validation with a 50 ms timer plus frame-progress boundaries, including single-frame ImageIO finalization. Successful export sample counts range from 692 to 978, with no missing RSS/physical-footprint samples in the measured four-export runs. These remain sampled maxima, not kernel peaks. The report separately records immediate/settled pre-validation readings, validator peaks and post-validation readings.

| Architecture | Peak export RSS MiB | Peak export footprint MiB | Four-cycle combined settled RSS growth MiB | Combined footprint growth MiB |
| --- | ---: | ---: | ---: | ---: |
| arm64 | 195.031 | 133.159 | +49.000 | +49.094 |
| x86_64 | 82.945 | 35.816 | +0.504 | +0.445 |

The unchanged repeated-run regression envelopes are **384 MiB sampled peak growth, 96 MiB final settled growth and 32 MiB last-interval growth**; both architectures pass. Relative to their own post-warm-up baselines, export RSS peak growth improved from about 417.0 → 55.8 MiB on ARM and 392.0 → 7.48 MiB on Intel versus `c0adee4`. This is a fixture comparison, not a universal performance promise.

**ARM still grows 49.0 MiB across four combined export/validation/cleanup cycles; it is not a plateau or a zero-leak result.** Intel's corresponding growth is 0.504 MiB. Settled combined readings include validation and cannot be attributed solely to the encoder. Separate fresh-process export-only and decode-only experiments completed successfully in [diagnostic run 37458401335](https://github.com/dandibbert/picshot/actions/runs/37458401335). The production-default export-only workload (one warm-up plus eight 30-second/360-frame exports, with zero GIF decoder calls during measurement) retained **98.03 MiB RSS on ARM** and **0.19 MiB on Intel**. Decode-only repeated eight full reads of one immutable GIF after warm-up: **0.59 MiB ARM / 1.11 MiB Intel**. ARM export-only readings increased from 109,379,584 to 212,172,800 bytes; the final three intervals added 38,502,400 bytes. This reproduces the growth inside the export pipeline without GIF validation; it does **not identify a specific allocation owner or prove a framework leak**. Same-file decoder caching and framework/GPU service allocations are outside that conclusion. All diagnostic media cleanup was confirmed. A same-binary comparison completed in [run 37462393497](https://github.com/dandibbert/picshot/actions/runs/37462393497), source `d810984`: ARM async export-only retained 102,891,520 bytes (98.13 MiB), scoped synchronous extraction retained 102,793,216 bytes (98.03 MiB). Their final three intervals added 38,486,016 and 38,453,248 bytes. Intel retained 77,824 and 274,432 bytes respectively. All 11 extraction-fidelity/cancellation/diagnostic tests passed on each architecture, all four fresh-process reports per architecture completed, and temporary cleanup was confirmed. **The synchronous candidate was rejected as ineffective; it was not promoted to the production default.** At that checkpoint, the bounded export-process boundary was not yet verified. Final 87eaedf parent/child measurements and remaining limits are recorded above; they do not retroactively change this earlier in-process result. Output limits and acceptance thresholds have not been relaxed. Remaining ARM growth is open investigation despite the configured envelope passing. DMG reports explicitly mark this full GIF profile `not-run` because it is run from ZIP only.

## Historical boundary

| Commit / run | Result and how it applies |
| --- | --- |
| [c0adee4e26d52315b0fe5c154c1ccc3ec23cf49f](https://github.com/dandibbert/picshot/commit/c0adee4e26d52315b0fe5c154c1ccc3ec23cf49f), [run 37450349815](https://github.com/dandibbert/picshot/actions/runs/37450349815) | Both passed 551 ordinary tests (3 intentional skips), 39 selected critical and 12 genuine-model tests, plus revised UI. Installed ZIP then failed the old GIF memory envelope; DMG launch was not reached. Peaks were sampled before validation, establishing an export-path resource problem. The 6c808a5 profile passes, with residual growth disclosed above |
| [ccb70f897df31232f604a8d25848d7d348b21dd9](https://github.com/dandibbert/picshot/commit/ccb70f897df31232f604a8d25848d7d348b21dd9), [run 37446248077](https://github.com/dandibbert/picshot/actions/runs/37446248077) | Both ordinary suites reported 544 tests, 3 intentional skips and 14 failures (2 unexpected); packaging/early UI success did not make it installer-ready |
| [caf71931e5c622d7ee0d7d6d549a902c00a6658f](https://github.com/dandibbert/picshot/commit/caf71931e5c622d7ee0d7d6d549a902c00a6658f), [run 37429201431](https://github.com/dandibbert/picshot/actions/runs/37429201431) | Delivered 0.2 passed its then-complete pipeline: 184 ordinary tests (3 intentional skips), 12 genuine-model tests and both installed formats. Its exporter was byte-identical to c0adee4's old implementation, suggesting shared-path risk. The new stress test was not run against 0.2; do not report a demonstrated 0.2 failure |
| [199566dd87af4f79ade76795bd21eb250e7e5ae7](https://github.com/dandibbert/picshot/commit/199566dd87af4f79ade76795bd21eb250e7e5ae7), [run 37427240555](https://github.com/dandibbert/picshot/actions/runs/37427240555) | ARM packaged erase output lost pixels after temporary cleanup; Intel produced correct pixels but exceeded the old 150-second cap. These were fixed before delivered 0.2 |
| [104e42e181eabac60a1df9c81cc6d85424a60314](https://github.com/dandibbert/picshot/commit/104e42e181eabac60a1df9c81cc6d85424a60314), [run 37426021201](https://github.com/dandibbert/picshot/actions/runs/37426021201) | Native/real-model stages passed on both; smoke failed compiling the launcher before app launch. No accepted installer |
| [0143e58d5a576a3def256267ac53cda5d5618e31](https://github.com/dandibbert/picshot/commit/0143e58d5a576a3def256267ac53cda5d5618e31), [run 37420240366](https://github.com/dandibbert/picshot/actions/runs/37420240366) | First delivered 0.1: 65 tests and both installed formats passed per architecture; later model features were absent |

## Still requires real-device and full-scope acceptance

User-TCC grant/deny/revoke/relaunch; real application capture; physical multi-monitor/mixed Retina/negative-origin/display-removal flows; complete capture → annotate → copy/export → pin → OCR → history paths; system/microphone audio sync and sustained recording; real camera selection/disconnect/indicator shutdown and overlay exclusion; Retina/user-desktop annotation effects; visible-preview force-kill, power loss and storage-removal recovery; long scrolling and prolonged resource use; broad multilingual/table/formula/inpainting/barcode quality; real Apple language download/translation; independent Office/export interoperability; sustained isolated-GIF resource behavior and every remaining parity-row requirement. Historical 0.6 introduced the narrow arcs/polylines, image-pin text selection and scroll-editing evidence above, with the final localized/composited window snapshots. App-identical Intel 0.6 passed its own final pipeline and both installed formats; physical external-app drag, direct Copy and >800 px scaled-preview equality remain unverified. ARM and Intel 0.7 presets/export/barcode work now pass their independent native and both-format installed gates; actual AX/real-device acceptance remains open. Click/scroll/keystroke effects, transparent/broader animation input, broader exceptional GIF cleanup and sustained codec resources remain open alongside all other Missing/Partial features; the specific outer-trim regression has source-qualified b44c1fb evidence. ARM/Intel 0.8 adds verified still WebP/AVIF and bounded recording WebP as qualified above; ARM/Intel b44c1fb Save/Retry and scoped GIF-stage changes now have independent native acceptance; broader real-device/exceptional cases and sustained resources remain open.

CI does not grant the user's OS permissions or modify permission databases. Packages are ad-hoc signed and **not notarized**; integrity checks do not establish publisher identity or Gatekeeper acceptance. Missing/Partial requirements remain in scope. No full-parity, zero-leak, universal latency or whole-device memory claim is made.

## Accepted ARM 0.13 verification at fa4cb0ad

This local documentation proposal records completed exact-source ARM native/package acceptance and the separately confirmed Library saves and DMG/guide delivery above. Every older version/source/resource record remains intact except the explicitly corrected Intel 0.12 retry outcome. Current application source is [fa4cb0ad742e89c9235cfea2eef6b5d7840a78a9](https://github.com/dandibbert/picshot/commit/fa4cb0ad742e89c9235cfea2eef6b5d7840a78a9), 0.13.0/build 85. Earlier 7c2f/build 84 observations below retain their historical source boundary. Terminal-success ARM job 112836654128, run 37634321240, macOS 15.7.9 (24G830), Xcode 16.4/macOS SDK 15.5. The preceding confirmed delivery was ARM 0.12/build 77 at 2754b779 and Intel 0.11/build 69 at 3f013417.

### Exact artifacts and independent final gates

| Architecture | ZIP filename/bytes/SHA-256 | DMG filename/bytes/SHA-256 | Metadata filename/bytes/SHA-256 |
| --- | --- | --- | --- |
| ARM | PicShot-0.13.0-macos-arm64.zip; 17,868,864 bytes; SHA-256 cd09788278f67166824a5047d630a4ba72f4e4a9b601fe785bbfd1eb673a223e | PicShot-0.13.0-macos-arm64.dmg; 20,648,215 bytes; SHA-256 dcce2c0e948949e454876b4f6b41ca073a9efaa18c9a6977b88872249571729c | PicShot-0.13.0-macos-arm64.build-info.json; 177 bytes; SHA-256 a70f9931654a020cce9fce302512de9dfaaae900a3226d204d38f2b701f671bf |
| Intel | No accepted 0.13 package; current accepted 0.11 bytes retained above | No accepted 0.13 package; current accepted 0.11 bytes retained above | No accepted 0.13 artifact identity |

Actual bytes/sidecars, ZIP CRC, DMG verification, embedded/external metadata equality, Info.plist full source/version/build, Mach-O and signing: Actual ARM files recomputed to the stated bytes/SHA-256; ZIP CRC passes; ZIP embedded metadata equals external 177-byte metadata; Info.plist agrees on full source, version 0.13.0/build 85 and macOS 14 minimum. Native packaging log verifies the DMG checksum and the successful smoke workflow checks installed architecture/ad-hoc signature/startup. These are integrity/source checks, not Developer ID, notarization or Gatekeeper acceptance. Minimum macOS 14, Developer ID/notarization/Gatekeeper and real-device acceptance require direct evidence. Library persistence/delivery is separate from all native/package checks.

Full and focused selections each use two deterministic disjoint class-grouped processes from actual `swift test list --skip-build` discovery, each bounded at 420 seconds; overall job 60 minutes. It is not one shared-process whole-suite run. Preserve discovery/plan hashes, exact selected IDs, filters, unique start/completion coverage, untruncated logs, unchanged limits and only the three explicitly permitted pre-model skips. Failed/partial shards do not form a pass. Full/focused overlap, so totals are not additive.

| Architecture/suite | Discovery/plan | Process 0 count/skips/failures/time/exit | Process 1 count/skips/failures/time/exit | Exact coverage |
| --- | --- | --- | --- | --- |
| ARM full | fa4: 1,391 discovered/selected. Discovery SHA-256 `34f3ba02decce880bce9af3ff2c016c665a01ad0897cf6ee84889dc4347641af`; full plan SHA-256 `08887742d48f84743b0b7299e14fa35dfb3b3f1e2842a111ab3de121d4a50fab` | 684 selected: 683 passed, 1 named pre-model skip, 0 failures; 227.110 s; exit 0; original 420 s cap; no forced signal/truncation | 707 selected: 705 passed, 2 named pre-model skips, 0 failures; 169.333 s; exit 0; original 420 s cap; no forced signal/truncation | 1,391/1,391 selected IDs completed once: 1,388 passed and exactly 3 approved pre-model skips, zero failures; two disjoint processes |
| ARM focused | fa4: 1,391 discovered; 902 selected. Discovery SHA-256 `34f3ba02decce880bce9af3ff2c016c665a01ad0897cf6ee84889dc4347641af`; plan SHA-256 `577b1bac6b0e81664acb248d8096606a7ba3f1962cd7b04bad4c6d456626fd35` | 462 passed, 0 skipped/failed; 218.953 s; exit 0; original 420 s cap; no forced signal/truncation | 440 passed, 0 skipped/failed; 160.274 s; exit 0; original 420 s cap; no forced signal/truncation | 902/902 selected IDs passed once across disjoint processes; no skips. Discovery count is not ordinary-suite acceptance |
| Intel full | Unrun after first focused-process failure | Unrun | Unrun | No ordinary/full acceptance |
| Intel focused | First 462-case process reached an existing synthetic GIF readiness failure | Failed; no replacement or relaxed threshold counted as a pass | Unrun | No full focused acceptance |

Actual-weight models: ARM model-inference.log records 12 tests passed, zero failures/skips, 32.234 s Selected tests elapsed; real formula/table/smart-erase weights were supplied. These overlap ordinary/focused suites; Intel model stage unrun. Each actual ZIP/DMG's startup/visible UI/LaunchServices, prior annotation/recognition/OCR/mosaic/save/codec/pin/group/recording/model/recovery/cleanup gates: ARM actual ZIP and DMG each have source-bound launch.json status passed and native checker success for OCR, automatic mosaic, annotation inventory/native assertions and prior evidence fields, including models/save/codec/pin/group/recording/cleanup. Own-child recovery is separately passed. Own-app AX remains skipped for missing existing Accessibility permission; full GIF stress remains ZIP-only. Preserve architecture-specific evidence, existing AX/no-permission skips and ZIP-only full GIF stress.

### Early ARM and Intel annotation evidence and their limits

The supplied early combined report binds source 7c2f7e71481e8da2bdcace4353268aba67c922cd, version 0.13.0/build 84 and its child reports. Freehand, text/line and callout status are passed; `includeResourceCycles=false`, resource status is not-run and measured/render cycles are zero. This is an early functional result only. The callout report is 12,083 bytes, SHA-256 `03f3d7ccaab8d8a6df9ed49e56b9c35955adbbecf7e5231f4d7def8b1dcb081a`, also bound by the combined report's hash inventory. Twelve controllers close/release. Save-active-comment, owned-window text focus/undo/copy, zoom geometry, source preservation, native Apply/PNG, four edges and repeated cleanup checks are true. No screenshot visual review is newly claimed by this documentation recovery.

Contract identity is `owned-graph-prompt_native-input-deadline-v2`, with scheduled owner check 10 ms, poll interval 10 ms and separate strict per-input/context deadline 2,000 ms. All six rapid-cycle reports track required owner/text backing and a context; TextKit 2 is tracked, TextKit 1 is not. All synchronous and prompt owner/backing survivor counts are zero. Times below are milliseconds after the corresponding close, computed from raw monotonic fields; first-observed nil is an observation bound, not exact destruction latency.

| Cycle | Actual prompt time | Last observed retained | First observed nil |
| --- | --- | --- | --- |
| 1 | 53.311625 | 865.111167 | 1210.922167 |
| 2 | 34.721458 | 770.775125 | 1117.224083 |
| 3 | 34.678750 | 726.938708 | 1144.222458 |
| 4 | 35.407542 | 799.140250 | 811.650750 |
| 5 | 36.450708 | 500.929083 | 513.058417 |
| 6 | 37.494208 | 492.573458 | 503.677750 |

Peak pending inputs/contexts are three each, final counts zero, with zero retained owned-graph objects in all aggregate samples. New cycles overlap earlier retirement; observed close-to-close intervals include editor construction/typing, so nominal 10 ms polling does not mean a new editor every 10 ms. The six-cycle workload is a fixture bound, not an application-wide quota. `zeroLeakClaim=false`; resource cycles are absent.

Historical boundary: e981/build 81 failed both combined annotation gates, with ARM dark-blend failure and both typed-close failures after six initial editors. 906 corrected reversal/teardown ordering and passed ARM highlighter but still failed early input lifetime. 307e824ac4654931f7c4caeb0a8e33a961f2e685/run 37626674223 failed both old scheduled-10-ms all-object gates. Its 12 cases × 3 samples per architecture showed owners gone first, native input/context alive at nominal 10/100 ms and gone by nominal 1,000 ms even for plain AppKit/untyped controls; only isolated/combined container disconnection released the storage/TextKit-2-layout/container graph from the first sample. The last nominal-one-second observations were 1,059.996625 ms ARM / 1,052.013021 ms Intel. The 20-second diagnostic neither identifies a native retainer nor establishes indefinite graph leakage or whole-process stability. Later release never converts that failed old contract into a pass. [AnnotationCalloutClose307.md](AnnotationCalloutClose307.md) preserves the original source/artifact boundary.

At 7c2f terminal comment close captures accepted text/geometry before disconnecting the text container. The two-phase contract is intentionally different: prompt application-owner/backing lifetime versus separately bounded framework input/context retirement. Final native regression, external checker and each actual installed-format result must agree on its name, object graph, actual monotonic times and deadlines; never hide the change as a longer old sleep. Early ARM success does not transfer to Intel or final ZIP/DMG.

- Final identity/source/checker/architecture/install agreement: Both final installed ARM reports pass owned-graph-prompt_native-input-deadline-v2; combined launch reports bind the same callout child reports and 40-file inventory. The external installed checker validates native flags, contract/timing/resource fields and integrity; it is not a second renderer
- Final synchronous/prompt owner/backing probes and actual elapsed times: Every final ZIP/DMG synchronous and actual prompt sample has zero retained owners/text-system objects; exact per-cycle actual elapsed times appear in the final lifecycle table below. Nominal scheduled delay remains 10 ms, not an exact physical elapsed promise
- Final per-input/context close/deadline/last-retained/first-nil samples and strict result: Every input/context first-nil observation is below its own strict 2,000-ms deadline; exact close/deadline/last-retained/first-nil fields appear below. First-observed nil bounds sampled retirement, not exact destruction latency
- Final six-cycle cadence/pending identities/overlap/peak/end-zero evidence: Both formats complete six rapid typed closes with overlapping pending identities, 12 total closed/released controllers; ZIP peak input/context 3/3, DMG 4/4, both final 0/0. Cadence and pending identities are separately tabulated below; six is a fixture bound, not an application-wide quota

### Latest source and superseded native stages

7c2f ARM's first focused process executed 462 tests and failed two assertions in one invalid-cycle test because the emitted `1 through 6` wording did not match the expected `1...6`. Remaining focused/full/model/final-installed stages did not run. The 7c2f Intel job was superseded during debug compilation. These source-qualified stage outcomes do not invalidate the separately recorded early functional observations, and those observations do not establish acceptance.

Latest candidate [fa4cb0ad742e89c9235cfea2eef6b5d7840a78a9](https://github.com/dandibbert/picshot/commit/fa4cb0ad742e89c9235cfea2eef6b5d7840a78a9), [run 37634321240](https://github.com/dandibbert/picshot/actions/runs/37634321240), applies the one-line message correction to `Close fixture requires 1...6 cycles`. It does not change the deadline or weaken the assertion. Current-source ARM focused coverage and both early UI modules now pass as recorded in the verified partial-evidence section. ARM ordinary/full coverage now passes as recorded below. Its ARM actual-model and both final installed gates subsequently passed, as recorded above. Intel failed its first focused process; only the four source-qualified ARM row classifications change.

### Independent Intel early 7c2f lifecycle observations

Intel's supplied combined report independently binds the same 7c2f source/version 0.13.0/build 84, all three passing modules and `includeResourceCycles=false`. Its callout report is 12,193 bytes, SHA-256 `c671fb5f7f8a17c66dfe68158eb0dc38c807ca995fc78f5df927fea9ab633f77`, bound by the combined 40-file hash inventory. All 12 controllers close/release, six rapid cycles satisfy the same explicitly named v2 contract, all synchronous/prompt owner and text-backing counts are zero, peak pending inputs/contexts are two each, and final counts are zero. This is independent early Intel functional evidence, not final installer, full native or resource acceptance.

| Cycle | Actual prompt after close ms | Last observed retained ms | First observed nil ms |
| --- | --- | --- | --- |
| 1 | 48.103685 | 632.377935 | 1184.727924 |
| 2 | 52.157932 | 604.507921 | 1070.760687 |
| 3 | 50.458258 | 516.711024 | 1001.291005 |
| 4 | 43.785482 | 528.365463 | 996.217224 |
| 5 | 42.109911 | 509.961672 | 520.538153 |
| 6 | 43.390088 | 494.484535 | 504.854736 |

Actual prompt observations span 42.109911–52.157932 ms and first-observed nil spans 504.854736–1184.727924 ms. The same sampling, framework-retirement, cycle-cadence and zero-leak limitations apply independently. Source-qualified early results are never transferred to fa4cb0ad or final actual ZIP/DMG.

### Required final functional evidence

Final 40-file inventory/child report binding/SHA-256/PNG integrity/native flags/checker: Both final reports pass with includeResourceCycles=true, all three native modules passed, exactly 40 file hashes per format, byte-exact nested child binding and verified PNG integrity. Combined/callout/launch hashes are tabulated below; native checker success appears twice in smoke.log. Inventory and hash integrity are not an independent renderer or independent semantic image comparison; semantics are asserted natively.

Freehand final tests, visuals, mouse-up/Shift/zoom/smoothing/limits/legacy/redaction/eraser/cancel and PNG results: Both final ARM freehand modules pass pencil/highlighter/point-limit/four-edge controls and PNG checks: draft exclusion, mouse-up endpoint, mid-stroke Shift, smoothing history, visible tiny marks, two undo/redo rounds, reversal ink/blending, bounds/disclosed simplification, cancel/tool-switch and release. Full native suite covers analytic reversal, zoom/legacy/redaction/eraser behavior; physical strokes and broad readability remain unverified. Text/line continued multilingual input/outline/background/wrap/rotation/zoom/cancel/redo, five endpoint forms/caps/joins/short or degenerate paths/opacity/eraser bounds/PNG: Both final ARM text-line modules pass continued multilingual inline editing, independent outline/background, identity/rotation, native endpoint/stroke controls, four-node edits, draft/cancel/redo preservation, once-composited opacity and exact PNG roundtrip in light/dark/edges. Native suite covers five endpoint forms/caps/joins/short or degenerate paths and eraser bounds. Active input remains unrotated; physical Retina/broad typography remain open. Numbered manual values/decimal-alpha-Roman/document independence/renumber/delete-gap/undo/exhaustion/comment-leader association/move-resize-rotate/cancel/save pixels: Both final ARM callout reports pass manual seven, per-document numbering, alphabetic/Roman values, multilingual comments, exhaustion, renumber/delete/undo, associated leader move/resize/rotate/cancel, Apply and exact PNG/canvas checks; standalone-arrow comments and global cross-document numbering remain absent.

Save-active-comment/text-focused copy-undo/anisotropic zoom geometry: Both final formats set activeCommentSaveAndCommandSPreparedPixelsPreserveMosaicGate, windowTextUndoRedoCopyAndCancelStayWithTextResponder and resizedCommentPreservesImageGeometryAcrossZoomAndResize true. Three reversal and two typed-close regressions, actual discovered IDs and results: All five discovered regressions pass in exact-source ARM native logs: AnnotationFreehandTests/testSmoothedReversalDarkPixelsBlendOnceAndPreserveOutside, testSmoothedReversalRetainsAnalyticTurnAcrossAxesAndDirections, testUnequalCollinearReturnUsesQuadraticExtremumAndNotControlPoint; NumberedCalloutInteractionTests/testTypedCommentCloseReleasesFrozenAndNormalEditorsRepeatedly and testTypedCommentCloseReleasesInputWithWindowAndUndoManagersStillOwned. They are suite members, not additional totals. Light/dark/four-edge geometry and actual screenshot review: Light/dark/four-edge native geometry assertions and screenshot PNG/hash integrity pass. This ledger finalization does not add an independent human-style visual-review claim; screenshot semantics are asserted by native fixtures. Controlled clipboard responders do not establish external-app interoperability. Physical input/Retina/TCC remains untested.

### Final installed ARM annotation resource workload

Final ZIP and DMG each complete two warmups plus twelve measured show/direct-vector-inject/preview/flatten/close cycles on one immutable 720×480 source, five marks and 45 points. Resource injection is not native-gesture/input evidence. Limits: one owned editor, 128 points/mark, 256 points total, 128 UTF-16 units/mark, fixed raster and cooperative 120 seconds. These are small-fixture bounds, not maximum product-capacity tests.

Equal endpoints retain one source and zero editors/output rasters/active jobs; no measured-loop PNG or screenshots, 150 ms settle. Preserve two warmups, all twelve settled endpoints, 14 render hashes/release probes, source before/after hashes, sample failures/successes/timer ticks/peaks/duration and separate final cleanup. Recompute deltas; never combine unlike phases.

| Install | RSS baseline → measured end; delta bytes | Last three RSS increments bytes | Footprint baseline → end; delta; late increments bytes | Sampler / elapsed / separate cleanup |
| --- | --- | --- | --- | --- |
| ZIP | 800,473,088 → 798,769,152; -1,703,936 | 0 / 0 / 0 | 136,614,720 → 136,598,336; -16,384; late 0 / 0 / 0 | 106/106 successful RSS/footprint, 91 timer + 15 boundary; peaks 801,554,432/138,154,816; measured 4.410971667 s, total 5.363016625 s; cleanup RSS/footprint 0/0 |
| DMG | 801,832,960 → 800,030,720; -1,802,240 | -884,736 / 0 / -245,760 | 155,406,976 → 155,259,520; -147,456; late 0 / 0 / -98,304 | 97/97 successful RSS/footprint, 82 timer + 15 boundary; peaks 803,487,744/156,996,224; measured 3.940179667 s, total 4.765176083 s; cleanup RSS/footprint 0/0 |

Intel 0.13 installed annotation resource gates were unrun after its native failure; no ARM values are transferred to Intel.

Full raw resource evidence: All two warmup and twelve measured settled readings, format-specific sampling/cleanup, 14 render hashes/probes, immutable source and lifecycle fields are retained in the final tables and source-bound reports below. Baseline includes earlier combined-process work, not idle application/annotation-only total. The 50 ms sampler retains counts/peaks/endpoints and may miss transients; it excludes WindowServer/GPU. Renderer/CoreText/AppKit caches are not fixture-owned object retention. No pressure/purge/global-setting intervention; `stabilityAssessed=false`. Zero weak references or declining RSS is not plateau, leak freedom, high-resolution or sustained-use proof.

Other exact-source workload/resource/cancellation/cleanup observations, including known ordinary-export backing growth: See the separate exact-source installed workload table below; existing PNG/JPEG/BMP/PDF growth remains positive in both formats and must not be replaced by the negative annotation delta. All older resource measurements retain their source/process/workload/version scope. Production image decoder default is unchanged. fa72569b/run37611362395 has validated matrices but three failed assertions in one lifetime test per 152-test native group; later test-only correction result: ARM native validation at fa4cb0ad: all 14 ImageDecodeTerminationLatchTests pass, including testUnlaunchedAndFailedLaunchReleaseWithoutCallback. This source/architecture-specific result neither retroactively passes fa72569b nor validates Intel or promotes the production decoder. Fixed order/cache/signature timing confound latency attribution and candidate whole-UI peak footprint is higher on both architectures; no universal win or production memory fix. The 37.791 ms late Intel callback does not prove strict three-second readiness.

Final source-qualified row decisions/counts with all 133 original requirements/checks/citations: ARM ANN-03/04/05/07 narrowly become Code: 56 Code/57 Partial/11 Missing behavior rows. ANN-06/08 remain Partial. Intel accepted 0.11 remains 50/61/13. All 133 IDs and original requirements/checks/citations survive. Final Library persistence/delivery, preserving the existing guide identity: Confirmed ARM DMG/ZIP Library version 11; same complete guide identity version 19, 116,686 bytes, SHA-256 3ba567e3116035cac00720fb6219eab78edd89b4e6a779a5e5b7a092b57d1cf7. DMG and guide delivered at 15:02:56 UTC on 7 October 2026. ZIP saved, but not included in that delivery message. This ledger proposal itself has not been published. No full PixPin parity, broad-input quality, physical Retina/multiple displays/Spaces/external-app or sustained-resource claim is implied.




### Final installed report bindings and annotation lifecycle derivation

Every value in this section belongs to ARM fa4cb0ad, 0.13.0/build 85, and its named installed format. Evidence paths are `qa/evidence/{zip,dmg}/annotation-details/annotation-details.json`, the referenced module files, and each format's `launch.json` in the exact-run artifact. Recomputed 40-file inventories and child-report equality pass independently for each format. PNG integrity is not a second renderer or a semantic visual review.

| Install | Combined annotation report SHA-256 | Callout report SHA-256 | Launch report SHA-256 |
| --- | --- | --- | --- |
| ZIP | 6351eb010ea0a6cade28aac44fb21ed07e268678ad39cc5791d449a2f6d6915b | dc520b4c37a31c98ada69b9af5543689ba33a590c7931aa5c131c152caa1848c | 565a70c7d4ca520d6ebda80cf80a721ab88eff8334b5506e89e3892e7ae8d1bd |
| DMG | 258ae3bf033ec812a4f8d611179829f77d742d2d33f14eb6e2ca40639c781d89 | 208506fadcc261a80fa8f408f1e0f028e00989c60829c97fd366b07b1d59e1bd | dc3224bd6a0617e43b0ca56db9981cf5033b47d5783f3f51e23b92bcbdd76c25 |

The callout contract remains `owned-graph-prompt_native-input-deadline-v2`: synchronous and scheduled-10-ms application owner/text-backing checks; separately polled native input/context retirement under each close's strict 2,000-ms monotonic deadline. Every cycle tracks the required owner/backing graph and context, including TextKit 2 (not TextKit 1). All synchronous/prompt survivors are zero. Both installed modules close/release twelve controllers. Times below are derived from the raw monotonic fields; “first nil” is a sampling bound, not exact destruction time.

| Install | Cycle | Close, fixture clock ms | Deadline, same clock ms | Synchronous check after close ms | Actual prompt after close ms | Last retained after close ms | First observed nil after close ms |
| --- | --- | --- | --- | --- | --- | --- | --- |
| ZIP | 1 | 357.324292 | 2357.324292 | 12.523000 | 28.290375 | 654.483250 | 969.673708 |
| ZIP | 2 | 677.274833 | 2677.274833 | 9.987000 | 22.937917 | 649.723167 | 1010.955875 |
| ZIP | 3 | 970.951667 | 2970.951667 | 15.478542 | 40.855875 | 717.279042 | 1012.093708 |
| ZIP | 4 | 1292.408542 | 3292.408542 | 18.307708 | 34.589458 | 690.636833 | 703.156042 |
| ZIP | 5 | 1651.483708 | 3651.483708 | 16.950958 | 36.747000 | 491.182083 | 507.100542 |
| ZIP | 6 | 1959.637625 | 3959.637625 | 8.982625 | 23.407750 | 499.230000 | 515.921792 |
| DMG | 1 | 236.859833 | 2236.859833 | 9.107833 | 20.624417 | 473.683917 | 693.890125 |
| DMG | 2 | 463.200375 | 2463.200375 | 11.003875 | 23.186250 | 467.549583 | 698.524917 |
| DMG | 3 | 690.166917 | 2690.166917 | 8.241167 | 20.376833 | 727.104500 | 740.232958 |
| DMG | 4 | 910.244500 | 2910.244500 | 9.901667 | 20.505458 | 507.026917 | 520.155375 |
| DMG | 5 | 1141.286750 | 3141.286750 | 8.285333 | 20.438542 | 496.288542 | 507.996333 |
| DMG | 6 | 1392.388792 | 3392.388792 | 11.348625 | 24.882625 | 489.679625 | 502.557375 |

ZIP: close-to-close intervals 319.950542, 293.676833, 321.456875, 359.075167, 308.153917 ms; peak pending inputs/contexts 3/3, final 0/0. Prompt pending cycle identities are 1; 1,2; 1,2,3; 2,3,4; 3,4,5; 4,5,6; final sample 2475.559417 ms has empty input/context sets. Every aggregate sample retains zero owned-graph objects.

DMG: close-to-close intervals 226.340542, 226.966542, 220.077583, 231.042250, 251.102042 ms; peak pending inputs/contexts 4/4, final 0/0. Prompt pending cycle identities are 1; 1,2; 1,2,3; 2,3,4; 3,4,5; 3,4,5,6; final sample 1894.946167 ms has empty input/context sets. Every aggregate sample retains zero owned-graph objects.

The new editor's construction/typing contributes to each interval; nominal 10-ms polling never means one new editor every 10 ms. Six rapid cycles are a bounded fixture, not a global live-input quota. No retainer attribution or whole-process stability follows. Historical 307 failures remain failures under their older contract.

### All settled annotation resource endpoints

One immutable 720×480 / 1,382,400-byte source remains at each baseline/end; five marks/45 points are directly injected, not entered through native gestures. Limits are one owned editor, 128 points/mark, 256 points total, 128 UTF-16 units/mark and a cooperative 120-second fixture deadline. Preview/flatten/close runs use 150-ms settling, no PNG encodes/screenshots in the measured loop. The functional/native-input phase is separate.

| Install | Settled endpoint | RSS bytes | Footprint bytes |
| --- | --- | --- | --- |
| ZIP | warmup 1 | 800,473,088 | 139,154,240 |
| ZIP | warmup 2 | 800,473,088 | 136,614,720 |
| ZIP | measured 1 | 800,473,088 | 136,614,720 |
| ZIP | measured 2 | 800,489,472 | 136,614,720 |
| ZIP | measured 3 | 799,801,344 | 136,614,720 |
| ZIP | measured 4 | 798,916,608 | 136,614,720 |
| ZIP | measured 5 | 798,916,608 | 136,614,720 |
| ZIP | measured 6 | 798,769,152 | 136,598,336 |
| ZIP | measured 7 | 798,769,152 | 136,598,336 |
| ZIP | measured 8 | 798,769,152 | 136,598,336 |
| ZIP | measured 9 | 798,769,152 | 136,598,336 |
| ZIP | measured 10 | 798,769,152 | 136,598,336 |
| ZIP | measured 11 | 798,769,152 | 136,598,336 |
| ZIP | measured 12 | 798,769,152 | 136,598,336 |
| DMG | warmup 1 | 801,832,960 | 161,059,456 |
| DMG | warmup 2 | 801,832,960 | 155,406,976 |
| DMG | measured 1 | 801,832,960 | 155,406,976 |
| DMG | measured 2 | 801,849,344 | 155,357,824 |
| DMG | measured 3 | 801,849,344 | 155,357,824 |
| DMG | measured 4 | 801,849,344 | 155,325,056 |
| DMG | measured 5 | 801,849,344 | 155,357,824 |
| DMG | measured 6 | 801,849,344 | 155,357,824 |
| DMG | measured 7 | 801,849,344 | 155,357,824 |
| DMG | measured 8 | 801,849,344 | 155,357,824 |
| DMG | measured 9 | 801,161,216 | 155,357,824 |
| DMG | measured 10 | 800,276,480 | 155,357,824 |
| DMG | measured 11 | 800,276,480 | 155,357,824 |
| DMG | measured 12 | 800,030,720 | 155,259,520 |

Each format has 2 warmup +12 measured release probes, all zero retained controllers/canvases/content, and all 14 end states retain exactly one fixed input with zero editors/output rasters/jobs. Source pre/post SHA-256 is `8742f3effbae16bd19fa1fe568aae9dcf12b0d0c2f7e0a40559a92cbc7743800`; all 14 render hashes per format are `a0909abfa68d6f9c378d9cd2001254b4f091e963dd0246f48e70da66b3f49e6f`. Final cleanup RSS/footprint deltas are zero in both. Warmup sampler counts are separately 19/19 RSS/footprint, 15 timer +4 boundary ZIP; 17/17, 13+4 DMG. Warmup peaks are 801,980,416/152,441,664 ZIP and 803,373,056/165,139,072 DMG bytes. Measured counters/peaks appear above; sample failures are zero in all four sampling phases.

The 50-ms sampler retains counts/peaks, not raw timer samples, and may miss transients. Absolute baselines follow earlier combined acceptance work, not clean idle-app or annotation-only total memory. Renderer/CoreText/AppKit caches are outside fixture-owned weak-reference accounting. No pressure, purge or system-setting intervention occurred. `stabilityAssessed=false`, `zeroLeakClaim=false`; negative net values and zero tracked objects do not prove a plateau, native allocator ownership, large-image acceptance or sustained leak freedom.

### Other final-source installed resource scopes and continuing backing growth

All deltas below are bytes at the stated comparable endpoint. Different phases/processes/workloads cannot be added, averaged or attributed to a common allocator. Save uses the first measured job's before-state through the last measured after-state; each warmup remains outside that interval.

| Install | Workload | RSS delta bytes | Late RSS scope / bytes | Footprint delta bytes | Workload boundary |
| --- | --- | --- | --- | --- | --- |
| ZIP | Automatic mosaic | +16,384 | +16,384 / +49,152 / -98,304 | -1,228,800 | 2+12 actual matcher/Apply/close; one input, zero editors/jobs; extra cleanup RSS/footprint 0/-1,310,720 |
| ZIP | Pin OCR | +212,992 | -98,304 / +196,608 / -32,768 | +1,540,096 | 2+12 actual Vision; 14 calls/cache reuses; zero pins/results/jobs; extra cleanup RSS/footprint 0/0 |
| ZIP | Pin group | +737,280 | 0 / 0 / 0 | +65,536 | 3+20 transforms/undo/inspector/hide/show; four live pins; asset digests unchanged; extra cleanup RSS/footprint -17,285,120/-180,288 |
| ZIP | Formula pins | +114,688 | -49,152 / 0 / 0 | +163,840 | 2+12 hide/show/close/restore; same live formula endpoint; zero renders in measured loop; cleanup separate |
| ZIP | Editor/pin lifecycle | +65,536 | last ten 0 | not recorded in this lifecycle metric | 10+40; windows 7→7; zero tracked retained app/content/window objects |
| ZIP | Save jobs | +327,680 | separate 8 small jobs | +262,144 | 2 warmups +8 measured; jobs, retained input, controllers and owned temporary files clear |
| ZIP | Static WebP/AVIF | +22,822,912 | no separated phases/warmup | +245,760 | 768×576; 3 cycles/format plus quality/cancel; combined encode/preview/independent-decode/publication |
| ZIP | PNG/JPEG/BMP/PDF | +12,976,128 | last interval +2,621,440 | -851,968 | 1440×900; 1+4 combined encode/preview/save/cleanup; observed, no stability assessment |
| ZIP | Full GIF | +16,384 | last interval +16,384 | +229,376 | 1+4, 30 seconds/360 frames at 480×270; export plus serial independent decode; separate cancellation/cleanup. DMG full stress unrun |
| DMG | Automatic mosaic | +98,304 | 0 / 0 / 0 | -1,638,400 | 2+12 actual matcher/Apply/close; one input, zero editors/jobs; extra cleanup RSS/footprint 0/0 |
| DMG | Pin OCR | +2,031,616 | +163,840 / +65,536 / +65,536 | +3,194,880 | 2+12 actual Vision; 14 calls/cache reuses; zero pins/results/jobs; extra cleanup RSS/footprint 0/-2,080,768 |
| DMG | Pin group | +770,048 | -16,384 / 0 / 0 | +327,680 | 3+20 transforms/undo/inspector/hide/show; four live pins; asset digests unchanged; extra cleanup RSS/footprint -17,285,120/-131,072 |
| DMG | Formula pins | +16,384 | 0 / 0 / 0 | +163,840 | 2+12 hide/show/close/restore; same live formula endpoint; zero renders in measured loop; cleanup separate |
| DMG | Editor/pin lifecycle | -98,304 | last ten 0 | not recorded in this lifecycle metric | 10+40; windows 7→7; zero tracked retained app/content/window objects |
| DMG | Save jobs | +360,448 | separate 8 small jobs | +360,448 | 2 warmups +8 measured; jobs, retained input, controllers and owned temporary files clear |
| DMG | Static WebP/AVIF | +23,789,568 | no separated phases/warmup | +212,992 | 768×576; 3 cycles/format plus quality/cancel; combined encode/preview/independent-decode/publication |
| DMG | PNG/JPEG/BMP/PDF | +16,564,224 | last interval +4,358,144 | +4,440,064 | 1440×900; 1+4 combined encode/preview/save/cleanup; observed, no stability assessment |

Final existing-format RSS baselines/endpoints are 475,660,288→488,636,416 ZIP and 469,090,304→485,654,528 DMG; growth is +12,976,128 / +16,564,224 bytes (+12.375 / +15.796875 MiB). Last intervals still add +2,621,440 / +4,358,144 bytes. Footprint changes are −851,968 / +4,440,064 bytes, with last intervals −2,834,432 / +2,080,768. Status is observational. Application-owned cleanup and negative annotation changes do not resolve ordinary-export preview/backing accumulation. The separate current-source 33-process diagnostic below narrows operations but identifies no native allocation owner or demonstrated pressure reclamation; production decoding is unchanged.

| Install | Model child | Parent-polled sampled RSS peak bytes | 100 ms RSS samples | Exit | Temporary cleanup |
| --- | --- | --- | --- | --- | --- |
| ZIP | formula | 392,790,016 | 10 | 0 | confirmed |
| ZIP | table | 211,648,512 | 12 | 0 | confirmed |
| ZIP | smartErase | 1,645,985,792 | 172 | 0 | confirmed |
| DMG | formula | 320,585,728 | 14 | 0 | confirmed |
| DMG | table | 231,964,672 | 15 | 0 | confirmed |
| DMG | smartErase | 1,882,783,744 | 181 | 0 | confirmed |

Every listed model child exits 0 with confirmed temporary cleanup. Parent 100-ms sampling may miss transients and excludes GPU/WindowServer/system services. ZIP-only full GIF stress includes a separate short 1920×1080/12-frame sample, which is not maximum-area/frame-count or sustained evidence; DMG's full GIF resource profile is explicitly not run. Formula pin resource cycles do not perform rendering; group resources retain four live pins until separate cleanup. Physical 1× native displays and synthetic owned events do not establish Retina, multi-monitor/Spaces, TCC or external-app interaction. No full PixPin parity or broad-input quality is claimed.


## Additional source-qualified fa4cb0ad evidence and diagnostic boundaries

All observations in this section belong to source `fa4cb0ad742e89c9235cfea2eef6b5d7840a78a9`; annotation packages report 0.13.0/build 85. These results are separate from earlier 7c2f/build 84 and all historical installed measurements. Final ARM acceptance is recorded above. These early/diagnostic observations remain separately scoped and do not substitute for installed evidence or establish persistence.

### ARM discovery-bound focused pass

`critical-tests-report.json` records **902 selected / 902 passed / zero skipped**, from **1,391 discovered tests**. Two disjoint native processes pass: **462 in 218.953 seconds**, then **440 in 160.274 seconds**. Both bounded-runner reports exit 0 at the original 420-second limit, without forced signal or log truncation. Discovery exits 0 in 5.086 seconds under its 60-second limit. The report, plan, raw discovery and both shard-log hashes agree. The discovered total is inventory, not an ordinary-suite pass or an additive focused-plus-full count.

- Focused report SHA-256: `2a7bcd83b35fe06e81d5e56c8fe6d0307c98f79eb5fd26d0f908a13e6896c30e`
- Discovery log SHA-256: `34f3ba02decce880bce9af3ff2c016c665a01ad0897cf6ee84889dc4347641af`
- Focused plan SHA-256: `577b1bac6b0e81664acb248d8096606a7ba3f1962cd7b04bad4c6d456626fd35`
- Process 0/1 log SHA-256: `b495bc3f01f7eff93ccb52615ef024601c0a0d820a4df457ed876b8bbff630b6` / `3eaa3f96566339d765795263dac4fa03a81026ccea285b13d47580921eb094c3`

### Independent build-85 early annotation results

Both current-source early combined reports pass freehand, text/line and callouts, bind their respective 40-file hash inventories, and record `includeResourceCycles=false` with resources not run. Their callout reports each record 12 closed/released controllers and six rapid cycles under `owned-graph-prompt_native-input-deadline-v2`. All synchronous/prompt owner and text-system survivor counts are zero. Contract polling remains 10 ms, the scheduled owner check remains nominally 10 ms with actual times recorded, and native input/context retirement has the separate strict per-cycle 2,000 ms deadline. Final installed ZIP/DMG results are separately recorded above; these early modules performed no resource cycles.

| Architecture | Actual prompt after close range ms | First observed nil range ms | Peak input/context | Final input/context | Callout report SHA-256 |
| --- | --- | --- | --- | --- | --- |
| ARM | 20.300958–34.286500 | 504.005542–912.717042 | 3 / 3 | 0 / 0 | `3765e82831accec881e049f6d2b1bb839c75e9caae9d99f0f926daabbcb68b16` |
| Intel | 37.440164–65.332363 | 511.345398–1478.849134 | 3 / 3 | 0 / 0 | `007cba7620ee7c8c01b57384d6cecec40f5056fb251297144790b3e920318d54` |

ARM and Intel callout reports are 12,413 and 12,489 bytes respectively. Their combined-report SHA-256 values are `d790a165188708c700537529c98ef31d53b46c856ef757ccd89f440a7ce2b4a6` and `3e9418a4a286fb19aaf9bf12cee4d61b203142f5c42a1a67150d9edb3ad862c0`. Per-cycle close/prompt/last-retained/first-nil values remain in the copied reports and the derived partial-evidence manifest. Observed nil times are sampling upper bounds, not exact deallocation latency; cycle construction/typing prevents interpretation as one new editor per 10 ms. Neither bounded object release nor an early gate proves process-memory stability.

### ARM backing attribution remains unresolved

The independent diagnostic artifact is **11489506659**, archive SHA-256 `5b6ab8bf626c42b561d6f742c35cc6fbb0f6ce9335dd375c2aa0c4a3c8a87ffb` (archive identity verified by the parent). The reviewed derived metrics bind all 33 source fields and duplicate launch reports. These are **27 image-backing plus 6 codec controls in 33 fresh app processes**, each with two warmups; 31 controls have 12 measured cycles and two extended AVIF controls have 48: **66 warmups + 468 measured invocations**. Every reported image is **768×576**, using 3,072-byte rows and 1,769,472-byte RGBA stride/reference storage where applicable, **1.6875 MiB**, not a 4K/5K/full-screen or maximum-size workload.

Runtime is ARM64 macOS 15.7.9 (24G830). The 50 ms sampler records 3,121 RSS and 3,121 footprint samples across whole runs, zero recorded failures, 65–228 samples/control and approximately 3.20–11.32 seconds/control. Whole-run counts include warmup and final waits; per-cycle counters must not be added again. This is not Intel evidence or final installed ZIP/DMG resource acceptance.

The following values are **RSS / physical-footprint / volatile-resident growth in MiB after two warmups, at the last measured settled cycle**. RSS/footprint use the fixture's recorded trends; volatile resident uses explicit `TASK_VM_INFO_PURGEABLE` boundaries. These are separately timed, non-atomic observations. Codec recorded trends differ slightly from separately timed backing snapshots; both remain in the derived data rather than silently substituting one for the other.

| Format | Production preview | Independent full decode / PDF page render |
| --- | --- | --- |
| PNG | +20.515625 / +0.265686 / +20.250000 | −3.171875 / −0.078125 / +0.000000 |
| JPG | +20.546875 / +0.296936 / +20.250000 | −3.140625 / −0.046875 / +0.000000 |
| BMP | +20.437500 / +0.140625 / +20.250000 | +0.156250 / +0.109375 / +0.000000 |
| PDF | +20.593750 / +0.343811 / +20.250000 | +17.281250 / +0.140686 / +20.265625 |
| WebP | +23.562500 / +0.234436 / +20.250000 | +0.359375 / −0.062500 / +0.000000 |
| AVIF | +0.515625 / +7.093750 / +0.000000 | +0.531250 / +7.093750 / +0.000000 |

Native export includes metadata verification and production preview from a persistent snapshot, excluding independent validation/publication. PNG/JPG/BMP/PDF export respectively retains **+22.328125/+20.546875/+25.640625/+24.250000 MiB RSS**, **+1.734436/+0.296936/+3.640625/+0.671936 MiB footprint**, and **+20.25 MiB volatile resident in every format**. Every non-AVIF preview/native-export final-three interval adds exactly **1.6875 MiB volatile resident**. Independent PDF page rendering, fresh-Data PDF preview and WebP decoded-pixel rasterization have the same continuing late growth; accumulated volatile memory survives the additional 0.5-second wait. Volatile classification is observed accounting; actual reclamation under memory pressure was not measured.

Source-create, snapshot-only and persistent synthetic-source raster/digest have zero volatile growth, with RSS growth +0.140625/+0.171875/+1.609375 MiB respectively. WebP full decode with fresh Data adds +3.3125 MiB RSS and zero volatile growth; adding decoded-pixel raster/digest gives +20.25 MiB volatile growth for either fresh or reused Data. This distinguishes materialization from fresh-buffer allocation in this fixture without identifying the allocator owner. PNG/WebP source-local cache removal each runs 14 times including warmup; immediate volatile/nonvolatile-ledger changes are zero, immediate RSS/footprint changes are zero or +16 KiB, and cumulative +20.25/+20.265625 MiB volatile growth remains. No cache-removal remedy is demonstrated.

Codec controls have broader operations than the backing decoder controls: decode-only builds a synthetic reference, reads fresh immutable bytes, full-decodes, rasterizes both rasters and compares every channel at ≤2 tolerance. Export-only retains production PNG staging/preview and helper-preview PNG decode. Combined runs both; export/combined publish, read identical bytes and remove the output.

| Codec workload | RSS / footprint / volatile resident MiB |
| --- | --- |
| WebP export-only | +21.421875 / −0.109314 / +20.250000 |
| WebP decode-only | +28.406250 / +0.281311 / +20.250000 |
| WebP combined | +49.140625 / −0.171875 / +40.484375 |
| AVIF export-only | +23.203125 / +0.234375 / +20.250000 |
| AVIF decode-only | +25.968750 / +6.578125 / +20.250000 |
| AVIF combined | +45.140625 / −3.031189 / +40.484375 |

Export-only/decode-only each adds 1.6875 MiB volatile in every last-three interval. Combined late increments are WebP [3.375, 3.359375, 3.375] / AVIF [3.375, 3.375, 3.359375] MiB, and +40.484375 MiB persists at the delayed sample. These workloads must not be described as independent backing decode alone.

In four backing AVIF controls, nonvolatile ledger starts at 7.484375 MiB after warmup, rises to 10.859375/14.234375 in measured cycles 1/2, stays 14.234375 through cycle 12 or 48, then falls **6.75 MiB** at the final wait to 7.484375 with matching footprint decline and no RSS decline. Delayed footprint growth remains +0.34375 MiB for the two 12-cycle controls, +0.875 preview / +0.890625 full-decode for 48 cycles; volatile-resident growth is zero in these backing AVIF controls. Codec AVIF decode-only also loses 6.75 MiB footprint/nonvolatile ledger during the final wait but retains +20.25 MiB volatile growth. That temporary nonvolatile decrease does not reclaim preview/PDF or codec raster accumulation.

All 450 image-backing invocations report fixture/autorelease-scope exit and matching work counts; final controller/queue/helper/temp-media counts are zero, while declared persistent source/snapshot/input references intentionally remain. All 84 codec invocations release the weak fixture payload and end with zero controller/queue/task/files and inactive helper. All 56 export invocations confirm child exit/temp-directory removal; all 56 independent decodes compare every pixel/alpha. These are service-level controls with **zero UI controllers created**, not additional UI lifetime proof or ownership accounting for all native allocations.

Serialized Mach records return status 0 and 93 requested natural fields with 16 KiB pages. Ordinary `TASK_VM_INFO` lacks the unqueried volatile fields; explicit `TASK_VM_INFO_PURGEABLE` adds them but does not separately expose its internal query status. Calls are separate and counters process-wide; unavailable values stay missing. This does not locate allocation ownership, prove a plateau or zero leaks, measure actual pressure reclamation, or include GPU/WindowServer/other processes/instantaneous peaks/different images/large inputs/other OS versions/long sessions. Production decoding is unchanged; optional child experiments remain diagnostic.

The complete source/process/format-qualified review and byte-exact derivations are retained under the proposal's reference/evidence files. The installed resource tables above use their own actual ZIP/DMG reports; these independent diagnostics do not fill or replace them.


### ARM full native pass and current Intel failure

At fa4cb0ad, ARM's complete native report selects all 1,391 discovered IDs: **1,388 passed, exactly three documented pre-model skips, zero failures**. Process 0 completes 684 tests (683 passed plus the formula-weight skip) in **227.110 s**; process 1 completes 707 (705 passed plus the smart-erase/table-weight skips) in **169.333 s**. Both original 420-second bounded processes exit 0 without forced signals or truncation. Selected IDs are disjoint/complete and discovery/plan/shard hashes agree. Ordinary and focused stages overlap and their totals must not be added.

The three permitted skipped IDs are PicShotEraseHelperTests.SmartEraseEngineTests/testRealCoreMLRemovesMarkedObjectAndPreservesOutsidePixels; PicShotMLHelperTests.FormulaEngineTests/testActualWeightsRecognizeFormulaFixtures; and PicShotTableEngineTests.RecordedModelOutputTests/testNativeHelperWithRealWeightsWhenConfigured. The later detailed model-inference.log independently records 12 actual-weight tests passed, zero failures/skips; both final installed gates are separately verified above. Pre-model skips remain skips and are not retroactively relabeled passes.

Full report SHA-256 is `ec6b460de0455002c7fdcc84efdeb8358ebcbaae4447cf459b1ef216e60ef56d`; full plan is `08887742d48f84743b0b7299e14fa35dfb3b3f1e2842a111ab3de121d4a50fab`. Process 0/1 log hashes are `99785e3ed178c9c130dbcf702e3ad9bec0e4a67046ade3ab353c1dcf0e51c097` / `5aebf0da9257cfafcff583c7f125104d74ca5d39c0c91432ff7cbaf3632b9f3c`. The discovery hash matches the focused plan's earlier recorded inventory.

The raw ARM process-1 log records **all 14 ImageDecodeTerminationLatchTests passed**, including `testUnlaunchedAndFailedLaunchReleaseWithoutCallback`. This establishes current ARM native validation for the later cleanup correction; fa72569b still has its historical three failed assertions in that case. It establishes no Intel latch pass, production-default decoder change, universal latency/memory improvement or backing-growth fix.

Intel fa4cb0ad fails only the existing synthetic GIF readiness assertion in its first 462-test focused process, according to the verified parent status update. The second focused, ordinary/full, model and final-installed stages are unrun. The independently passing Intel early UI report remains partial evidence; it cannot substitute for this failed native gate or borrow ARM's coverage. Latest accepted Intel remains 0.11.0/build 69/source3f013417. ARM final actual ZIP/DMG, model detail, exact bytes and resources have passed. ARM DMG/ZIP saves at version 11 and guide version 19 are confirmed separately; DMG and guide delivery at 15:02:56 UTC on 7 October 2026 is confirmed, with no ZIP delivery claimed for that message.
