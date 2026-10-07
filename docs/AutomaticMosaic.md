# Automatic matching mosaic

This 0.12 candidate implements local repeated-region matching and an editable review flow for ANN-15/16. Native compilation, installed interaction and resource acceptance are pending. The accepted installers remain 0.11 at 3f013417; this document is not a new release or full-parity claim.

## Flow

Use the mosaic subtool menu's automatic action and draw a target, or select an independent axis-aligned pixelate, blur or solid-redaction rectangle and choose Find matching content. Matching reads the immutable original screenshot on this Mac. It does not upload images, use OCR semantics or download a model.

The compact review shows included and excluded outlines. Navigate candidates, click an outline or its checkbox, and add a missed same-sized region manually. Apply commits the chosen regions as one undo operation. Cancel leaves existing annotations unchanged. Copy, Save, Pin, OCR and translation are blocked during seed drawing, search and review, so pending masks cannot silently disappear from output.

The synchronization checkbox controls corresponding additions, deletion and style edits. Original target exclusions are retained; removing a local correction does not remove an unrelated original target. With synchronization off, a geometric edit detaches that mark, so later group changes do not use stale coordinates. A linked mark cannot start another Find; create a fresh independent selection instead. Undo/redo includes link metadata and manual exclusions.

Solid redaction renders opaque flattened pixels even if its color or style opacity is lower. Blur and pixelation are cosmetic effects and do not promise secure removal of information. The editor's original raster and undo history still exist until the editor closes.

## Matching and limits

The matcher visits every integer translation origin, filters by informative color/edge anchors, then verifies full-resolution pixels, alpha, edges and local tiles. Candidate similarity is a deterministic score, not a calibrated probability. It matches the same size and orientation; changed fonts, scaling, rotation, subpixel placement, compression and strongly overlapping repeats may be missed or refused. Review and manual correction remain necessary.

Inputs are limited to 20 million pixels and 8192 pixels per side. The seed is 3–512 pixels per side. There is one admitted matching job per process, with no raster-retaining queue. Cancellation is cooperative; a running job holds its permit until exit. The 8-second conversion/search/publication budget refuses late results, but cannot forcibly interrupt a synchronous CoreGraphics drawing call.

The declared 96 MiB scratch bound accounts for the canonical RGBA raster, template and bounded matcher metadata. It excludes the existing source image, CoreGraphics internal allocations and total process RSS. Work is capped at 384 million reserved comparisons, 512 raw candidates and 24 returned candidates plus the seed. Raw/work/time overflow is a visible failure. Result truncation after a completed search is flagged explicitly. Manual review shares the 25-region cap; linked annotations are capped at 200 per editor, with atomic refusal before an undo snapshot is added.

Contiguous regions of one matching addition use a single pre-group raster for filtering. Ordinary annotations retain their previous sequential rendering behavior. The matcher result stores only geometry and scores. Generation, image identity and revision checks reject callbacks after cancellation, edits, crop, undo, tool changes or closure.

## Acceptance

[AutomaticMosaicWorkflowVerification.md](AutomaticMosaicWorkflowVerification.md) defines the native controls, independent PNG pixel checker, cancellation boundaries, 2+12 small-resource cycles and separate one-shot 4K/5K release timings. The ordinary/focused/model and actual ZIP/DMG gates from previous versions remain required. Exact source-specific results will be added after execution; authored tests and Python checker passes alone do not establish macOS correctness, physical Retina coverage, broad matching quality or leak freedom.
