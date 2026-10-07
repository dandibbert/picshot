# Automatic mosaic installed native acceptance

`AutomaticMosaicWorkflowSmokeFixture.verify(evidenceDirectory:includeResourceCycles:)`
is an opt-in, `@MainActor`, asynchronous installed-app fixture. The default for
`includeResourceCycles` is `true`. It uses the production matcher, editor canvas,
native controls, linked annotation model, history, and flattened renderer.

ARM 0.12.0/build 77 at **2754b77954415a8273c14a7fe5245330bec39996** passes
[native and actual installed ZIP/DMG acceptance](https://github.com/dandibbert/picshot/actions/runs/37602641265/job/112730667449).
Its 1,321 ordinary tests include 3 intentional pre-model skips, and all 850
focused and 12 actual-model tests pass; stages overlap. Both installed formats
pass this full fixture and the independent PNG checker. Intel 0.12 remains
unaccepted pending its own complete gates. Source-specific resource observations
and limits are recorded in [VERIFICATION.md](VERIFICATION.md).
AppKit, CoreText, CoreGraphics, WindowServer, and a macOS SDK are required for the
native fixture. The Linux checker and nine tamper tests also pass, but synthetic
Python reports are only checker inputs and are never native evidence.

## Entry points and ownership

- New fixture: `Sources/PicShot/AutomaticMosaicWorkflowSmokeFixture.swift`
- Native tests: `Tests/PicShotTests/AutomaticMosaicWorkflowSmokeTests.swift`
- Independent checker: `scripts/check-automatic-mosaic-report.py`
- Checker tests: `scripts/tests/test_check_automatic_mosaic_report.py`
- Installed-app routing: `Sources/PicShot/SmokeVerification.swift`,
  `scripts/launch-smoke-app.swift`, `scripts/ui-preview.sh` and `scripts/smoke.sh`

Existing smoke launch setup isolates normal history/preferences and launches
the asynchronous smoke router. Its focused `PICSHOT_AUTOMATIC_MOSAIC_ONLY=1` mode
can run this workflow independently. In that mode,
`PICSHOT_UI_PREVIEW_ONLY=1` explicitly disables resources and large-image phases;
without it, the focused installed run performs full acceptance.

The early installed ZIP UI preview calls the fixture with resources **false**.
The final installed ZIP **and** DMG smoke calls it with resources **true**, and
the external checker runs with `--full`. Early UI evidence is not a substitute
for either final installed artifact. The optional focused route is useful for
debugging but is not a replacement for the final installer checks.

## Exact authored workload

The immutable source is 720×480, premultiplied sRGB RGBA8. A 144×48 tile contains
the CoreText name “Mika Chen,” a colored circular icon, a small contrasting inset,
an opaque background, and an alpha-0.5 strip. Source coordinates below have a
top-left origin; the fixture converts them at the editor's bottom-left boundary.

| Case | Top-left rectangle | Expected result |
| --- | --- | --- |
| Seed | 31,37,144,48 | Included |
| Exact repeat | 287,123,144,48 | Included |
| Small color variant | 497,301,144,48 | Included; RGB +2 only for opaque pixels |
| Close nonmatch | 59,329,144,48 | Excluded; two actual dark glyph pixels replaced by background |

The source has a deterministic light patterned exterior. It is never captured
from a desktop, supplied by another application, downloaded, or recognized with
OCR. Text is actual rasterized glyph content, not an empty placeholder rectangle.

Four functional export runs use the native redact, blur, and pixelate paths.
The fourth mode, `redact-excluded`, excludes the last repeat before Apply and
exports only the seed and first repeat. Native candidate navigation and checkbox
actions exclude and reinclude known regions. Review must leave the annotation
model unchanged until Apply. Apply must create one undo transaction, and redo
must restore the exact committed annotation IDs.

Opaque redaction must write RGBA 0,0,0,255 at every pixel in the approved regions.
Every exterior pixel, including the close nonmatch and an explicitly excluded
candidate, must remain byte-identical. Blur and pixelate must change some approved
pixels and preserve every exterior pixel. They are explicitly cosmetic; neither
the report nor checker treats them as secure redaction.

The independent checker decodes the actual PNGs, validates CRCs and row filters,
and recomputes pixel comparisons using fixed authored rectangles. It does not
trust masks supplied by a report. It also checks filenames, file hashes, bundle
path, source commit, version/build, and resource/large-image scope. No Pillow or
other external Python package is needed. Supported output is native noninterlaced
8-bit RGB/RGBA/gray/gray-alpha PNG; another encoder format fails explicitly.

## Native controls and interruptions

The fixture uses native mouse/key event dispatch to the app's own canvas and
AppKit target/action controls. It never posts global events or needs Accessibility
permission. It verifies:

- Native obscure-region drag, select, and inspector Find action
- The direct automatic-mode native menu followed by seed drawing
- Candidate navigation, exclusion/reinclusion, and Apply
- Synchronized correction addition/deletion on and off
- Exact one-step Apply undo/redo, synchronized delete undo/redo, and local delete undo
- Actual review control frames, enabled state, target/action, and native hit testing
- The selected candidate is fully visible and does not intersect the review panel
- Review controls within screen bounds at all four window corner placements
- Light/dark native PNGs and a bottom-right edge PNG
- Cancel before Apply, crop/edit invalidation, and Close cleanup
- Disabled output controls and blocked copy shortcut/direct selector during
  review; Apply/Cancel restore the production copy callback. The callback is
  private to this fixture and does not read or write any pasteboard

For deterministic stale-callback checks, the injected function calls the exact
production `AutomaticMosaicMatcher.findMatches` and waits only **after that real
result has completed**. Cancel, crop, edit, or Close then invalidates the review.
Releasing the gate returns the actual result; the production cancellation and
generation/revision checks must discard it. No invented result or replacement
pixel matcher is supplied. These four gated interruption runs are separated from
the ordinary resource cycles. The gate is never used for memory measurement.

## Resource observations

Full runs perform two warmups and twelve measured cycles, each with a native
editor, real seed/select/match/review/Apply/flatten/Close sequence. The one constant
720×480 input raster and one matcher/counter are held across equal endpoints.
Each cycle ends with zero active wrapper calls and zero weakly observed editor,
canvas, content view, or review surface objects. There is no PNG encoding or
screenshot capture within the measured loop. There is a 150 ms settling interval.

The existing 50 ms self-process RSS/physical-footprint sampler reports successful
and failed sample counts, timer ticks, boundary samples, sampled peaks, warmup and
measured boundaries, all twelve settled endpoints, three individual late-cycle
increments, final cleanup deltas, and weak-reference release counts. The checker
recomputes all deltas and rejects missing or failed observations. Measurements
are observational: they do not prove a plateau, zero leaks, or WindowServer/GPU
resource totals, and sampled peaks may miss transients. The fixture does not
purge allocators, simulate memory pressure, or change system settings.

## Separate full-only 4K and 5K release timings

After small resource measurement completes, full acceptance performs one actual
production match at 3840×2160 and one at 5120×2880. Source construction is timed
separately. Matching duration includes service admission, canonical raster
conversion, and the full search. The production eight-second limit is unchanged;
a refusal, cancellation, deadline, wrong geometry, or missing candidate fails the
fixture. Debug builds cannot pass this phase.

The seed is 31,47,144,48. Exact and color-variant repeats are at
1919,1081,144,48 and `(width−159),(height−71),144,48`. The glyph-change nonmatch is
113,157,144,48. Each result must contain exactly the two expected candidate
rectangles and no decoy, with no truncation and unchanged source backing hashes.
The report records size, source/template bytes, architecture, construction and
conversion/search durations, exact candidate geometry/confidence, origin count,
and the 96 MiB algorithm-owned scratch limit. That limit excludes original image
backing, native CGContext internals, and UI/WindowServer allocations.

These are two one-shot timings, not sustained large-image throughput or a large
image leak test. Their allocations do not enter the 2+12 small-cycle series.

## Evidence and commands

The fixture writes `automatic-mosaic-workflow.json` plus eight PNGs: source,
light review, dark review, edge review, redaction, redaction with one exclusion,
blur, and pixelate. It records source byte identity before and after the entire
workload, and SHA-256 for each delivered PNG.

```sh
python3 -m unittest discover -s scripts/tests -p test_check_automatic_mosaic_report.py -v
swift test --filter AutomaticMosaicWorkflowSmokeTests
python3 scripts/check-automatic-mosaic-report.py \
  EVIDENCE/automatic-mosaic-workflow.json INSTALLED/PicShot.app \
  EXPECTED_COMMIT EXPECTED_VERSION EXPECTED_BUILD --full
```

The native smoke test uses `includeResourceCycles:false`; the installed release
router and checker own the full resource/timing gate. A report is meaningful only
for the exact tested bundle/commit and launch. Passing checker unit tests does not
mean Swift compiled, native controls rendered, matching completed, or the ZIP/DMG
passed. Native screenshots should also be visually inspected after a successful
run; machine geometry and pixel checks do not establish every visual detail.
