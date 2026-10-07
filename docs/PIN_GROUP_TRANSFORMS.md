# PIN-13: bounded native group transforms (candidate source)

This implements a focused PIN-13 candidate, not full PixPin parity. It is based on
b44c1fb0ecc71fbe652ed3c74e377e8f3ea8ba27. This worker ran on Linux without Swift or
AppKit; all new Swift tests and native interaction/resource fixtures are **not run**.
The owner must run macOS build, ordinary tests, both architecture gates, and installed
ZIP/DMG smoke before treating any native acceptance below as passed.

## User path

- Open the existing “贴图组与历史” manager and Command/Shift-select live rows
- The small “移动 / 缩放…” inspector translates screen-point positions and uniformly
  scales the selected windows about their collective bottom-left corner
- Positive X moves right; positive Y moves up. Scale input is 25–400%; native minimum
  window sizes still apply. Window resizing preserves the existing per-pin zoom,
  opacity, text size, original/current pixels and typed rich source
- Six alignments are available in the same manager: left/right/top/bottom and horizontal/
  vertical center. Alignment uses the selected windows' collective bounds
- Each managed pin also has a native context-menu selection toggle and a shortcut to
  the compact transform inspector. Selected windows receive only a 2-point outline;
  no permanent toolbar or dashboard is added to the image-first pin surface
- **Direct group drag / resize-handle gestures are not implemented.** Dragging or
  resizing an individually selected window still changes only that pin. Collective
  movement/resizing requires the numeric inspector; this remains an interaction-parity
  gap, and is disclosed in manager selection help and each pin's menu tooltip
- “撤销组合” and “重做” operate on complete committed operations, even if the current
  selection has changed. One group application is one undo entry

## Safety and lifecycle

- Selection is restricted to at most 20 live, visible, active-group pins. Hidden,
  archived, stale/deleted, locked and click-through entries cannot participate
- The manager can still preview archived rows with existing bounded thumbnails.
  Selecting them does not open a controller or decode a full-resolution image
- Metadata captures stable IDs, before/after presentation and group ID. Every member
  must still match before any transformation or undo/redo; no stale member is skipped
- A native frame constraint rejects the whole operation. Frames are applied without
  a run-loop yield and verified, then one atomic manifest replacement commits all
  presentations. Write failure restores every original live frame and leaves the
  in-memory index/history unchanged. No asset writes, resampling or quota evictions
  are performed by a group transform
- An inspector does not preview by mutating windows. Cancel/close/Escape are no-ops;
  changes to its selection or any captured frame make Apply fail without partial work
- Native individual move/resize/presentation changes invalidate history referencing
  that pin. Closing/removing a pin drops its selection and affected history. Group
  switches, hiding the group/all, and termination clear selection, inspector and undo
- Committed frames persist on restart. Selection and undo are intentionally transient
- Undo/redo retain at most 32 operations of 20 metadata pairs. They retain no controllers,
  rendered images, thumbnails or payload data. Existing 20-live-pin / 512 MiB session
  and 4-live-animation limits are unchanged
- Negative screen origins are supported. Finite metadata limits are enforced rather
  than silently clamping individual members and destroying collective geometry;
  existing current-group recovery remains available for off-screen pins

## Verification added (requires macOS)

- `PinGroupTransformTests` (PicShotCoreTests): three varied windows plus a sentinel;
  negative origins, all six alignments, scale/finite limits, stale/deleted/locked/
  click-through/hidden/archive checks, metadata history bounds, undo/redo, restart
- `PinGroupNativeTransformTests` (PicShotTests): image + rotated fixed-zoom image + native
  text selection, one store publication per group, unchanged pixel identities/assets,
  disk failure rollback including undo, actual inspector Cancel/invalid/stale Apply,
  native minimum dimensions, context action/table integration, group switch/restart
- `PinGroupTransformSmokeFixture`: real shown native manager, table and context actions,
  an actual Escape key event, Apply/Undo/Redo/alignment controls, two view-backed PNG
  snapshots, three warm-ups plus 20 transform/undo/hide/show cycles with weak controller/
  content checks. It writes `pin-group-transforms.json` and adds
  `pinGroupTransformEvidence` to installed launch JSON. RSS is observational, not a
  zero-leak claim. It requests no permissions or preference changes. Desktop-visibility preference
  service is explicitly isolated; the existing manager restore toggle still reads
  its saved preference, which is disclosed in the report

The fixture has not executed here and no generated UI image is offered as runtime
proof. Physical multi-display/Spaces movement and mixed animation/LaTeX acceptance
remain separate real-Mac checks after integration with the other pin workers.

## Follow-on resource evidence (authored, native execution pending)

Functional control/snapshot setup now returns before resource measurement, releasing
its strong source-image/manager/table/inspector locals. Asset comparisons retain
filename/byte-count/SHA-256 strings, not encoded image buffers. Exactly three
warm-up cycles precede twenty measured transform/undo/inspector/hide/show cycles.
Four pins are live at the post-warm baseline and each measured endpoint. A separate
final cleanup observation has zero live pins; its drop is not comparable growth
at the same workload state.

The existing `GIFResourceMemorySampler` records main-process RSS and physical
footprint continuously every 50 ms, including transitions, bounded release waits,
asset-hash validation and final cleanup. Warm-up and measured-phase statistics are
separate. Every boundary and both sampled peaks are required; any failed sample,
missing timer tick or inconsistent valid/failed count rejects the fixture instead
of substituting zero. No memory envelope or stability threshold is added.

`resourceEvidence` reports all twenty comparable endpoints, both growth deltas,
the last interval and last three one-cycle increments, cleanup deltas, sample/failure
counts and elapsed time. Probes must start with live controller/content: 15 warm-up,
100 measured and four final-teardown probes must release. Main-process accounting
is not a whole-system/WindowServer/GPU/helper total; sampled maxima can miss
transients. Released controllers and flat/negative readings do not prove a plateau
or zero leaks. This source-only work has not executed the native fixture.
