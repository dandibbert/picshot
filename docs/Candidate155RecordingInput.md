# Recording-input candidate 155: not accepted

Source `9fb09ac26dc08a145a90eb83fb0b27faae1adc38`, tree `cf0914ff14c3c09aac769d05ab0f0480b736c825`, [run 37954396810](https://github.com/dandibbert/picshot/actions/runs/37954396810). Both architecture jobs ended in failure; no 0.17 installer was accepted or delivered.

## ARM

Release, debug app and native test compilation passed. Actual discovery contains 1,836 methods in 208 classes, retaining every one of the previous 1,799 methods plus exactly 37 recording-input methods. Canonical inventory SHA-256 is `1b5d454926a5ad3d3408ad8827e5fcec619755d284d208d9c13b0e144627cf9b`; full groups are 481/422/469/464 and the focused selection is 1,296.

The early pin regression preflight still asserted the previous 1,799-method inventory and stopped before either regression process. Its cells list is empty. The focused/full/model/installed/default-resource gates and new 22-frame recording witness did not run. Compilation or discovery is not test execution.

Early UI rendered the recording-input row, but SwiftUI did not expose the toggle through the supported in-process accessibility route. The report explicitly recorded layout-only/pending interaction. This was insufficient for control or full recording-panel acceptance, despite the early UI job succeeding.

## Intel

Release packaging passed. Early UI failed the existing numbered-callout retirement check. Cycle 1 was last observed retained at 629.422 ms and first observed released at 2,007.512 ms, outside the unchanged 2,000 ms acceptance bound. The 1,378 ms sampling gap leaves the actual deallocation time unknown; this is not proof of retention beyond the deadline or a diagnosed leak. Only three of six cycles started; later cycle observations remained incomplete. Debug/test compilation, native discovery and later acceptance stages did not run.

## Following correction

Candidate 156 updates only the current production inventory guard and report to audited discovery, with portable negative/drift checks. Historical diagnostics pinned to older source keep their original inventories. The input row uses AppKit-backed checkboxes/actions with refreshed SwiftUI bindings, and its preview requires actual target/actions, hit targets, complete light/dark panel geometry, state restoration and weak teardown. Missing interaction evidence no longer qualifies as layout-only acceptance. The existing callout deadline, native process limits and product resource limits are unchanged.

These are prepared corrections, not native acceptance. New source requires its own complete gates. Synthetic permission/input fixtures do not prove real event delivery, TCC behavior, secure-field semantics or physical Mac layout. Latest accepted ARM remains 0.16/build154; Intel remains 0.11/build69.
