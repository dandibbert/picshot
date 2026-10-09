# Input-effect derived-export verification

This additive REC-18 fixture reuses the unchanged candidate159 authored input
movie. It adds no region motion, event monitoring, permissions, user-media access,
production exporter behavior, package dependency, or app-side WebP decoder.

## Owner integration

Call `RecordingInputExportSmokeFixture.verify(evidenceDirectory:)` on the main
actor immediately after the existing
`RecordingInputSmokeFixture.verify(evidenceDirectory:)` has passed in the same
evidence directory. Keep all original159 assertions. The new fixture refuses
existing derived evidence and requires the original passing report and MP4.

The new fixture returns `status = exported-awaiting-independent-validation`.
That is deliberately **not** an all-formats acceptance pass. After the installed
application exits, run this command from the same source-bound checkout, using
its existing architecture-matched pinned native-codec build:

```sh
python3 scripts/verify-recording-input-exports.py "$EVIDENCE_DIRECTORY" "$EXPECTED_SOURCE_COMMIT"
```

The expected source must be the final integrated 40-character Git revision, as
used for the installed app's `PicShotSourceCommit`. Keep the owner's existing
source/package/architecture binding checks; the argument alone does not prove
the checkout's provenance. The runner compiles a temporary separate validator
against `CPicShotCodecs.c`, the existing header and pinned static libraries.
It never fetches or installs a dependency. Compilation has 60/120-second child
deadlines; the native reader has a 60-second cooperative and 90-second outer
deadline. Existing production helper deadlines/RSS limits remain unchanged.
Use the existing installed-app process watchdog, without increasing it to hide
a stalled fixture. The app fixture has a separate 120-second cooperative budget.

The runner runs the native reader and then the fail-closed join gate. An exit of
zero plus its JSON `status: passed` is the new combined gate. Re-check already
retained evidence without rerunning/replacing it with:

```sh
python3 scripts/check-recording-input-exports.py "$EVIDENCE_DIRECTORY" "$EXPECTED_SOURCE_COMMIT"
```

The Python checker validates evidence, hashes and coverage. It does **not** decode
media, and cannot replace the native reader. The independent JSON refuses
replacement; use a fresh evidence directory for a new installed run.

Files retained in addition to the original159 three witnesses:

- `recording-input-selected.mp4`
- `recording-input-selected.gif`
- `recording-input-lossless.webp`
- `recording-input-lossy.webp`
- `recording-input-export.json`
- `recording-input-export-independent.json`

Each media file is capped at 4 MiB and each report at 128 KiB. Each decoded RGBA
frame is 320×180×4 bytes. Reads are sequential; only the current decoded raster,
its current reference and bounded scalar observations are retained. Codec-owned
compositing buffers and framework allocations are additional; these object
bounds do not establish a total RSS ceiling. Reports include cold, first-trim,
late and final app RSS/footprint, parent sampler statistics and separately
attributed helper metrics. They do not claim sustained leak acceptance.

## Interval and pixel contract

The source remains 320×180, 10 fps, 22 frames, 2.2 seconds. The interior selected
interval is `[0.100, 2.150)`, lasting 2.05 seconds. It includes source frames
1…21, including the initial clear frame, click, scroll directions, shortcut,
expiry, input reappearance, post-pause clear and Stop-frozen effects. It excludes
the first source frame and clips final playback halfway through the final source
frame. MP4 packet PTS, positive durations, adjacency and playback duration are
checked separately: a container edit may clip the last nominal compressed packet.
The report retains its actual packet endpoint rather than falsely claiming every
last packet is physically rewritten to 50 ms.

GIF and both WebP paths request 20 fps, yielding 41 samples. Both production
writers append each frame separately and do not merge identical samples. The
checker uses nearest 600-Hz request ticks and actual AVFoundation sample times,
not an animation-index-to-MP4-index assumption. GIF cumulative centisecond and
WebP cumulative millisecond rules produce 50 ms each here, totaling 2050 ms.
Every stored frame, positive delay, end-of-decoder result and infinite loop
setting is checked. Required sampled source indices include 1, 2, 4, 6, 9, 13,
18, 19, 20 and 21. The final sample therefore observes frozen Stop, while the
preceding samples observe the clear post-pause frame.

GIF canvas dimensions come from its bounded logical-screen header, followed by
each indexed ImageIO property dictionary before decoding and every decoded raster.
Global ImageIO PixelWidth/PixelHeight are optional observations, not a canvas
requirement. Installed and independent reports retain bounded `gifMetadata`
with those actual global values, the image count and loop count, and the indexed
and decoded dimensions reached before success or failure. A failing scalar
comparison includes its GIF frame/request and actual/reference values. This
changes no frame, delay, color, pixel, helper or report limit; native execution
must still establish the missing-metadata hypothesis and all remaining checks.

The original source is independently decoded first. Trim pixels are compared
with decoded original H.264 pixels; GIF/WebP pixels are compared with decoded
selected H.264 samples. Positive/expired masks, feature counts and centroids,
camera/annotation anchors, scroll-direction points, post-Stop exclusion and
whole-canvas error are checked. Identity orientation is established through
track metadata plus asymmetric cyan/magenta anchors. This does not claim general
rotated-track acceptance beyond this authored witness.

Authored thresholds are deliberately reported and fail closed: source-to-trim
and lossless-WebP ROI mean RGB error ≤9/255 and canvas mean ≤3/255; GIF/lossy-WebP
ROI mean ≤18/255 and canvas mean ≤6/255. Single anti-aliased scroll-direction
pixels retain the original source witness's 65-level allowance; surrounding
scroll masks/centroids/ROI still use the tighter tests. Region color means,
counts and ≤4-pixel centroid checks supplement pixel error, so small missing or
misplaced glyphs cannot hide in a whole-canvas average. Lossless WebP is only
lossless relative to its prepared raster, not the pristine desktop. These
thresholds are authored and require native calibration evidence; a failure is
not itself evidence of a production defect or permission to raise a cap.

WebP is decoded through `PSCodecWebPAnimationOpen` and every
`PSCodecAnimationNext` result in the separate process. ImageIO is used for GIF,
never as proof that all WebP animation frames decoded. Original source hashes,
all output hashes, source commit and the installed report hash bind the results.

The installed fixture also rejects four existing destination sentinels and
checks ten cancellations: trim-start for all four routes, plus first helper
progress and after helper output/before publication for GIF and both WebP modes.
Trim-start is explicitly the pre-native-start cancellation checkpoint, not a
claim of mid-encode interruption. Existing exporter tests continue to cover
active trim cancellation, destination races, identity-checked replacement and
stranded helper ownership. No existing tests or cleanup safeguards are changed.

## New native test IDs

`PicShotTests.RecordingInputExportTests`:

- `testInteriorSelectionAndSamplingIncludeExpiryResumeAndFrozenStop`
- `testPixelOracleUsesTopDownRGBAAndDetectsEffectRelocationAndExpiry`
- `testScalarTimelineRejectsFirstFrameOnlyWrongBoundaryAndMissingResume`
- `testPixelComparisonRejectsChangedGlyphShapeAndOutOfRegionArtifacts`
- `testFixtureRefusesExistingDerivedWitnessBeforeReadingOrExportingSource`
- `testFixtureRequiresAcceptedOriginalReportBeforeLaunchingHelpers`
- `testBoundedEvidenceRejectsSymlinksAndOversizedFiles`
- `testAuthoredInputTrimPreservesAllSelectedPixelsAndPacketBoundaries`

`PicShotCodecHelperTests.RecordingInputExportPlanTests`:

- `testDerivedInputPartialFinalFrameUsesFortyOneRequestsAndExactMilliseconds`

Run focused native tests with the existing pinned native build available:

```sh
swift test --filter 'RecordingInputExportTests|RecordingInputExportPlanTests'
```

Keep the existing input, composition, pause, trim, GIF compatibility and WebP
regressions in the owner's full/focused inventory. The signed animation helper
paths are exercised by the installed fixture; the source XCTest's real-media
case covers actual RecordingWriter/compositor → AVAssetExportSession → MP4 decode.

## Local verification status

Authored in Linux without Swift or macOS frameworks. Native compilation,
XCTest, signed installed exports and independent pixel decoding have **not run**.
Nine portable mutation/negative gate tests passed under normal Python and `-O`:

```sh
python3 -m unittest discover -s scripts/tests -p test_recording_input_export_contract.py -v
python3 -O -m unittest discover -s scripts/tests -p test_recording_input_export_contract.py -v
```

These tests use explicit non-media byte stubs and make no native acceptance
claim. Python syntax compilation passed. The native runner's Linux refusal was
checked and produced no evidence. Source comparisons confirmed all preexisting
files, including original159 fixtures, exporters, workflow and package metadata,
remain byte-for-byte unchanged.
