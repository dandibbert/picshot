# Pin management candidate

This is the authored 0.21 candidate scope. Accepted ARM remains 0.20.0/build191 until the new exact-source native and installed gates pass. Accepted Intel remains 0.11.0/build69. No parity promotion follows from this document or authored tests.

## Plain-text drafts

Managed plain-text pins expose an explicit context action to edit their contents in a compact owned sheet. Save commits before changing the displayed text or clipboard source. Cancel, Escape outside input-method composition, owner hide/close, or closing the sheet discards the draft. A failed save leaves the draft open and the previously persisted/displayed text unchanged. The text and name are separate metadata; updating one retains the other, group membership, visibility and presentation.

Imported HTML and styled runs remain read-only. This batch does not strip their formatting or silently convert rich content. Existing plain-text UTF-8 and document-size limits remain. The text draft has a small custom undo/redo history; AppKit typing undo is disabled for this owned editor. IME text is provisional until committed and cannot be saved while composing. Draft and provisional-input bounds are checked independently from the saved content limit.

The storage operation requires the original expected content. A stale draft cannot overwrite a newer document. A new JSON payload and bounded 480×280 poster are prepared at fresh owned paths before the manifest commit; prior payload/poster bytes remain available on validation, capacity, write, or manifest failure. Every other saved pin is retained, with capacity overflow refused instead of evicting unrelated entries. This atomic manifest workflow is not a guarantee against every filesystem, hardware or cross-process failure.

## Names and group order

Image and text pin context menus expose an explicit rename sheet with Save/Cancel. Names use the existing 120-character validation and do not modify pixels, text content, annotations or presentation. The expected saved name is checked to reject a stale rename after another window changes it. The live name changes only after the durable callback succeeds; manager changes are reconciled by stable pin ID. Image pins retain their image-only appearance.

The existing group manager adds a compact order menu. Earlier/later actions move the current group by one position, preserving IDs, active group, protection flags, membership and selected pins. Boundary and zero moves do not write. Default and protected groups remain reorderable; the default group remains undeletable. Picker and destination items carry UUIDs so display labels and reload timing cannot redirect an action to another group. No new dashboard, account, cloud sharing, global input listener or permission is added.

## Required evidence

- Native storage tests inject payload/poster/manifest failures, capacity errors, corrupted content and stale drafts, then compare prior safe files and entries
- Native interaction tests cover multiline/CJK/emoji, committed/provisional text bounds, bounded undo, Save reentrancy, cancellation and sheet/owner retirement
- Group tests cover repeated reorder, reload/reopen, default/protected groups, exact selection and membership, stale actions, failure/retry and minimum-window hit targets
- The actual installed fixture must verify light/dark draft, rename and group-order pixels, real owned AppKit action routing, persistence/reopen, unchanged rich content and bounded repeated retirement
- Complete prior native inventory, model, media, fail-closed output and installed resource gates remain required

Synthetic AppKit events and runner snapshots do not establish physical-Mac keyboard/IME, Retina, Spaces, TCC, external clipboard interoperability or sustained memory stability. Existing cold/final/peak resource costs remain explicit. The inherited Intel GIF threshold failure is a separate unresolved gate and is not repaired or relaxed by this batch.
