# PIN-13: bounded native group transforms (Partial; ARM/Intel 0.10 verified)

**Accepted and delivered ARM/Intel 0.10.0 build 67** is [03cf310](https://github.com/dandibbert/picshot/commit/03cf310c4228bdbfdc3f9a81ceec810651552f81), with independent terminal-success [ARM job 112643816594](https://github.com/dandibbert/picshot/actions/runs/37575644941/job/112643816594) and [Intel attempt 2 / job 112653589644](https://github.com/dandibbert/picshot/actions/runs/37575644941/job/112653589644) in run 37575644941. Each architecture passes **1,190 ordinary tests (1,187 passed, 3 intentional pre-weight model skips), 732 focused and 12 actual-model tests**, zero failures, plus both actual ZIP/DMG installed startup, native pin and existing feature/cleanup gates. Stages overlap and are not additive distinct-test totals. Both architecture installer replacements are confirmed; Intel DMG/ZIP Library version 8 and guide version 15 are saved, with ARM bytes unchanged. Physical Spaces/Retina/TCC, all remaining feature gaps and sustained-use evidence remain open. Full GIF stress is ZIP-only on each architecture. Acceptance is limited to 03cf310/build 67; no 0.11 acceptance is claimed. See [VERIFICATION.md](VERIFICATION.md) for exact bytes and process/workload-qualified measurements.

PIN-13 remains **Partial**: direct collective drag/resize is absent. Independent ARM/Intel native and installed numeric Apply, six alignments, undo/redo and constrained rollback pass; original authoring on Linux was not itself native evidence.

## User path

- Open the existing “贴图组与历史” manager and Command/Shift-select live rows
- The small “移动 / 缩放…” inspector translates screen-point positions and uniformly
  scales the selected windows about their collective bottom-left corner
- Positive X moves right; positive Y moves up. Scale input is 25–400%; native minimum
  window sizes still apply. Window resizing preserves the existing per-pin zoom,
  opacity, text size, original/current pixels and typed rich source
- Six alignments are available in the same manager: left/right/top/bottom and horizontal/
  vertical center. Alignment uses the selected windows' collective bounds, preserves
  each size and canonicalizes origins/anchors to the destination pixel grid; center
  placement can retain a half-grid residual
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

## Verification coverage (ARM/Intel 03cf310 native and installed)

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

Actual ARM and Intel 03cf310 fixtures and native view snapshots independently pass in ZIP and DMG. The installed mixed fixture uses image, rotated fixed-zoom image and text; broader mixed animation/LaTeX interactions and physical multi-display/Spaces movement remain separate acceptance work.

## Installed ARM resource evidence and measurement scope

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
or zero leaks. Accepted ARM 03cf310 ZIP/DMG comparable RSS grows +278,528/+65,536 bytes; the final three increments are [+49,152, 0, 0] / [0, +32,768, −32,768] bytes. Assets remain unchanged; final live pins and tracked retained controllers/content are zero. This does not resolve existing preview-backing growth. Exact baselines, footprint and other workloads remain in [VERIFICATION.md](VERIFICATION.md).


## Independent installed Intel resource evidence

Accepted Intel 03cf310/build 67, run 37575644941 attempt 2/job 112653589644, uses its own 3 + 20 workload. ZIP RSS baseline → comparable measured end is **106,496,000 → 107,433,984 bytes**, growth **+937,984 bytes**, final three single-cycle increments **[+36,864, −45,056, +266,240]** and footprint change **+540,672 bytes**. DMG is **108,195,840 → 108,613,632 bytes**, growth **+417,792 bytes**, final three **[0, +16,384, +4,096]** and footprint change **−950,272 bytes**. Sampled parent RSS peaks are **107,499,520/108,904,448 bytes** ZIP/DMG.

Both Intel reports complete all samples without failures, preserve asset hashes and finish with zero live pins and zero retained tracked controllers/content. Four live pins are retained at comparable baseline/measured endpoints; final-cleanup decreases are separate. Native constrained-window rollback restores all four presentations and preserves manifest/index/assets and undo/redo. These results do not fill direct collective drag/resize, broader mixed-content, physical Spaces/Retina/multi-display or sustained-resource gaps, and do not resolve preview-backing growth. [VERIFICATION.md](VERIFICATION.md) contains exact Intel installer hashes and the other independent workloads.
