# Annotation detail candidate for 0.13

This source adds pencil smoothing/angle constraints, freehand and rectangular highlighter modes, text outline, line/arrow/polyline endpoint styles, and editable numbered callouts. **The combined source is awaiting native compilation, visual review and actual ZIP/DMG gates.** Accepted delivery remains ARM 0.12 at 2754b779 and Intel 0.11 at 3f013417. No parity row is promoted by this document.

The compact floating palettes edit the same annotation values used by canvas, export and undo. Programmatic legacy defaults retain the old strokes and rectangular highlighter. New pointer strokes retain their final endpoint and visible single-point ink; progressive simplification bounds retained samples/corners at 2,048 and is reported in the editor. New closed arrowheads paint with their shaft in one vector union so their opacity does not accumulate at the junction. See [freehand behavior](FreehandAnnotations.md) and [text/line styles](AnnotationTextLineStyles.md).

Numbering uses a document-local snapshot-backed next value. Decimal, alphabetic and Roman modes share values 1–3999; at most 512 numbered marks, 2,048 UTF-16 units per attached comment, a bounded inline undo manager and bounded comment/badge geometry are permitted. Explicit renumber and optional gap-closing deletion preserve normal undo/redo. An exhausted counter refuses new marks until reset or undo. Comments and leader arrows remain editable; they are not standalone-arrow comments or a cross-document counter.

Review found and corrected three input paths before native testing: Save now commits the active comment before flattening; text-focused key equivalents are left to AppKit rather than canvas undo/copy; and resized comments retain their original image scales across zoom/layout changes. Their executable fixtures cover owned-window routing and prepared export pixels. A controlled text-copy responder avoids changing the general pasteboard, so physical external-app clipboard interoperability remains outside this proof.

## Installed acceptance

`AnnotationDetailAcceptanceFixture` runs the freehand, text/line and numbered-callout fixtures sequentially. Early ZIP evidence skips resources; final installed ZIP and DMG each include a separate two-warmup/twelve-measured render/close phase using direct representative vector injection and one fixed 720×480 source. Functional fixtures cover native controls/events, cancellation/history, exported pixels, light/dark and edge palettes; resource injection does not establish those gesture semantics by itself.

The external checker binds source/version/build/app identity, embedded child reports, exact file inventories, SHA-256/PNG integrity, native check flags, tracked cleanup and resource sample/delta consistency. PNG integrity and hashes are not independent semantic proof of a renderer; semantic pixel assertions run in native code. RSS and physical footprint remain observations with late intervals and scope limits, never a plateau or zero-leak claim. Physical Retina, TCC capture and long-term behavior remain unverified.

## Exhaustive native inventory

The growing native suite is planned from actual `swift test list --skip-build` discovery. Full and focused selections each run in two deterministic, disjoint processes, grouped by test class. Each keeps the original 420-second process deadline; the overall CI job remains 60 minutes. This is explicitly a process-isolation change, not one shared-process full-suite run or a changed product timeout.

The checker binds the plan to the original discovery log, requires one start and one successful/approved-skipped completion per selected ID, rejects missing/extra/duplicate cases, changed filters/deadlines and truncated logs, and permits only the three named pre-model skips. Each shard's logs, bounded-runner report, plan and aggregate totals are retained. This new execution path itself still requires native verification. The real-model and both installed-format gates remain separate and required.
