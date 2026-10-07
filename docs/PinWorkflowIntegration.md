# Managed pin workflow integration: ARM 0.10 verified, scope still partial

**Accepted ARM 0.10.0 build 67** is [03cf310](https://github.com/dandibbert/picshot/commit/03cf310c4228bdbfdc3f9a81ceec810651552f81), with terminal-success [run 37575644941 / ARM job 112643816594](https://github.com/dandibbert/picshot/actions/runs/37575644941/job/112643816594): **1,190 ordinary tests (1,187 passed, 3 intentional pre-weight model skips), 732 focused and 12 actual-model tests**, zero failures. Both actual ZIP/DMG pass their installed startup, native pin and existing feature/cleanup gates. Stages overlap and are not additive distinct-test totals. ARM installer replacements are confirmed; **delivered Intel remains 0.9 b44c1fb**. Physical Spaces/Retina/TCC, all remaining feature gaps and sustained-use evidence remain open. Full GIF stress is ZIP-only. See [VERIFICATION.md](VERIFICATION.md) for exact bytes and process/workload-qualified measurements.

Originally integrated against 7c3e76c with b44c1fb application base on a Linux host; the source-only statements from that checkpoint are superseded for ARM by the exact-source evidence above. Intel delivery and physical-device acceptance remain separate.

## Integrated behavior and review corrections

- Existing managed image/text/file/color/animation pins and new LaTeX pins share
  desktop policy and group selection. Current/assigned mode removes both
  `canJoinAllSpaces` and `moveToActiveSpace`; all-desktops remains the default
- Formula drafts survive same-mode Settings saves/context selection. A genuine
  mode change cancels the formula editor/render/save chooser or queued save and
  dismisses the group inspector. The inspector inherits current policy on reopen
- Group transforms perform one metadata transaction, no raster rewrites, and
  roll back all live frames on failure. Native callbacks after rollback read the
  rolled-back frame; equal-to-store callbacks remove pending values instead of
  reapplying an intermediate frame. Debounced saves update the current index
- Formula source/raster replacement and presentation writes change disjoint fields
  in the latest store index. Group undo/redo cannot replace newer formula assets
- The group controller is authoritative for transform selection. Manager reloads
  never replay stale table rows into it; context deselection and coalesced hide/show
  reset remain authoritative. Archived-row previews stay separate from selection
- Formula editor/render/save activity blocks group participation. Close, hide,
  group changes and termination retain existing controller/content cleanup
- Managed formula Save uses a retained asynchronous chooser and create-only raw
  publication. The chosen physical directory is bound before render/queue delays,
  using the existing descriptor-chain/private-stage implementation. Later changed
  ancestors, occupied files, symlink/hardlink targets and cancellation refuse
  publication. Only identity-matching owned staging is removed. Unknown/replaced
  staging deliberately remains untouched. Once exclusive commit wins, the complete
  new file is kept even if cancellation arrives afterward
- Native source/SVG/MathML/PNG/PDF extensions and byte contracts are preserved.
  No fake PNG/PDF artifact is used for vector or source bytes. The accepted
  `ImageExportService` is byte-for-byte unchanged; existing standalone formula
  preview export behavior is outside this managed-pin change
- At most two formula save jobs retain a slot until actual render/publication drain;
  each encoded payload is bounded to 24 MiB. Cancellation clears queued bytes
  immediately. Inline Stop/Cancel also cancels a queued disk save
- Formula source undo remains ten source/options values; group history remains
  32 operations of at most 20 metadata pairs. Neither retains raster arrays
- The formula content view draws a white presentation backing so transparent black
  glyphs are readable in light/dark appearances and native cached-view screenshots.
  This is labeled in the pin tooltip and never flattened into exported PNG alpha

Historical integration scope: that initial patch did not change package version, default CI, dependencies, permissions or allocator diagnostics. Subsequent owner integration/package changes produced accepted ARM 0.10 build 67; no production preview-memory fix is inferred.

## Remaining interaction limits

Direct collective drag/resize gestures remain absent. Group movement and uniform
window scaling use the numeric inspector; alignment uses manager controls.
Dragging a selected pin individually still moves only that pin. This is explicit
in the existing manager/context help and `PIN_GROUP_TRANSFORMS.md`.

Current fractional/mixed-scale coverage includes `testPositiveSmokeLayoutFitsVisibleFrameBeforeAndAfterFractionalScale`, destination-grid/negative-origin cases, mixed-scale seam selection, size-preserving alignment and actual AppKit backing conversion. Proposed target frames are explicitly canonicalized to the destination pixel grid; transaction verification still requires exact equality to those targets. A constrained or unrepresentable member rejects and rolls back the whole operation. Center alignment may have a half-grid residual without resizing the pin. These native/synthetic passes do not establish physical Retina or display-removal behavior.

Public collection flags are not proof of physical desktop assignment. No private
Space IDs, activation-follow, named desktop placement or original-Space restart
restoration are implemented. Run the physical checklist in
`PinDesktopVisibility.md` independently of automated flag/snapshot fixtures.

## Native gate commands and remaining physical acceptance

ARM 03cf310 completed the automated/native and both installed-format routes below; Intel 03cf310 remains pending. The commands remain reproducible checks, and physical/device requirements remain open.

1. Compile and run `swift test` on each architecture. Focused coverage includes
   `PinWorkflowIntegrationTests`, `LaTeXPinExportTests`, `LaTeXPinTests`,
   `PinLaTeXContentTests`, `PinGroupTransformTests`, `PinGroupNativeTransformTests`,
   `PinDesktopVisibilityPolicyTests` and `FormulaRenderContractTests`. Then run the
   full suite, including session/store/compact-pin/recognition/export/save/GIF tests
2. Run normal package and installed ZIP/DMG smoke for each architecture. The normal
   smoke route adds `pin-group-transforms.json` and `pinGroupTransformEvidence`;
   inspect real `pin-group-multiselect.png` and `pin-group-transform.png`
3. Run desktop scope explicitly with
   `scripts/pin-desktop-visibility-smoke.sh APP ABSOLUTE_EVIDENCE EXPECTED_COMMIT`.
   It emits native context/Settings snapshots, but keeps `physicalSpacesVerified`
   false. Physically test all six content kinds, multiple Spaces/displays,
   fullscreen/Stage Manager, restore, display removal and sleep separately
4. Run LaTeX explicitly with `PICSHOT_LATEX_PIN_VERIFY=1` and
   `swift scripts/launch-smoke-app.swift APP ABSOLUTE_EVIDENCE/latex-launch.json`.
   Set only one opt-in fixture selector per process. Check the source hash, actual
   bundled renderer, source/options edits, invalid/cancel/undo/restore, exports,
   two warm-ups plus twelve measured lifecycle cycles, and all six real PNG snapshots including
   `latex-managed-pin-light.png`, `latex-managed-pin-dark.png`,
   `latex-inline-editor-light.png`, and `latex-inline-editor-dark.png`
5. Inspect native Save chooser placement on compact formula pins, same-mode
   preservation, real-mode/close/hide cancellation, queued-save Stop/Cancel, no
   orphan sheet/editor/inspector, readable tooltip/source controls, and both
   appearances. Use native pixels, not generated UI mockups
6. Repeat installed lifecycle/resource gates, separating workloads, warm-up and
   measured phases, and checking final intervals, helper exit, temporary ownership
   and controller/content release. Existing pixel/disk/geometry/admission limits
   are unchanged. Bounded ownership is not proof of a process-RSS plateau

The integration and export tests use actual AppKit controllers, store APIs and
filesystem publication with small explicitly synthetic PNG/source data. They do
not replace genuine MathJax, signed-helper, interactive Spaces or installed-byte
acceptance. The separate LaTeX native fixture uses the actual bundled renderer.

## Follow-on fixture resource evidence

The new group and LaTeX fixtures now share the `resourceEvidence` schema, using the
existing continuous RSS/physical-footprint sampler. Group runs 3 warm-ups + 20
measured cycles; LaTeX runs 2 + 12. The sampler continues through final asset-hash
validation and teardown. Functional UI/render helpers return first, so their
strong images/render arrays/controllers are not intentionally retained during the
resource phase. Only bounded scalar endpoints, counts, digests and weak probes
are recorded. Missing samples fail; no zero substitute, growth envelope or
stability verdict is introduced.

Both reports expose `baselineAfterWarmup`, `settledAfterCycles`,
`afterMeasuredCycles`, `finalAfterCleanup`, `warmupSampledMemory`, `sampledMemory`,
growth/cleanup/late-interval deltas and `observationsComplete`. Comparable endpoints
retain four group pins or one LaTeX pin; cleanup has zero. Group controller/content
probes count 15 warm-up, 100 measured, 4 final; LaTeX controller/content/model probes
count 4, 24, 1. Every probe starts non-nil and must release. Asset fingerprints
exclude mutable index.json. No proof of no same-byte rewriting is inferred.

The actual compact-edge formula chooser gate records native bounds/visibility/
parent/cancellation in `formulaSaveChooserGeometry`; remote-panel pixels are not
cached or fabricated. Both fixture coordinators use isolated desktop preferences.
The existing group-manager restore toggle still reads its saved preference, and
that read is explicitly disclosed rather than represented as no preference access.
These follow-on fixtures have now executed in both accepted ARM 03cf310 installations. Formula 2+12 comparable RSS grows +98,304/+147,456 bytes ZIP/DMG; group 3+20 grows +278,528/+65,536 bytes. Last intervals, source limits and unchanged asset/release evidence are in [VERIFICATION.md](VERIFICATION.md). Formula measured cycles do not render. Physical Spaces and sustained resources remain unverified; existing preview-backing growth is unresolved.
