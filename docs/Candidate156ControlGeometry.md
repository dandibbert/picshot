# Recording-control candidate 156: not accepted

Source `d03ff5ede69d3d98db27ad7e61f78741c885cff4`, tree `6cb07b876816e820684e04c39baa92667ba0e169`, [run 37958186954](https://github.com/dandibbert/picshot/actions/runs/37958186954). No 0.17 package acceptance follows from compilation or the portable checks.

## ARM

Release compilation and packaging passed. Early installed-ZIP UI failed at the first denied-permission geometry check in the isolated light input row: `Native control frames overlap: recording-input-status`. The strict gate stopped before the denied-state screenshot, help/refresh, complete recording panel, dark appearance, representable reuse or weak cleanup checks. Only the default-off recording-input PNG was written and visually inspected as legible.

The failed-state rectangles and pixels were not retained. Consequently the exact overlapping edge, amount and visual appearance cannot be reconstructed from this run. Source control flow reaches this check after nine native toggle assertions, but no partial action report was saved; those actions are not presented as a completed interaction acceptance result. Debug/test compilation, native discovery and all later native/model/installed/default-resource gates were unrun.

## Intel

Release compilation and packaging passed. The exact job log records the same `Native control frames overlap: recording-input-status` failure at 2026-10-09 16:44:16 UTC; job 113913969767 ended in failure at 16:44:34 UTC. Later native and installed acceptance stages were not reached. This log does not establish exact failed-state rectangles or pixels, and ARM artifact details are not borrowed as Intel evidence.

## Prepared 157 correction

Only the recording-input buttons and status field use frame-equal AppKit alignment geometry, matching an existing editor-control pattern. SwiftUI alignment expansion is a source-supported hypothesis for the failure, not an observed cause. The correction must demonstrate its effect in a fresh native run.

The strict complete-control frame overlap, hit-test, full-panel bounds and lifecycle checks remain unchanged. State PNGs and bounded native frame/alignment/inset/cell-drawing/intersection measurements are now saved before checking them. A failed exercise also preserves completed action progress and its current synthetic pixels/geometry. These diagnostics do not transform a failed check into a pass. The exact 37 recording-input native methods and all original 1,799 methods remain; portable source checks are not native execution.

Latest accepted ARM remains 0.16/build154 and Intel remains 0.11/build69. Real OS permission and external-application input behavior, physical displays, broad quality and sustained memory remain outside this synthetic UI evidence.
