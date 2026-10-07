# Managed pin desktop visibility

**Accepted and delivered ARM/Intel 0.10.0 build 67** is [03cf310](https://github.com/dandibbert/picshot/commit/03cf310c4228bdbfdc3f9a81ceec810651552f81), with independent terminal-success [ARM job 112643816594](https://github.com/dandibbert/picshot/actions/runs/37575644941/job/112643816594) and [Intel attempt 2 / job 112653589644](https://github.com/dandibbert/picshot/actions/runs/37575644941/job/112653589644) in run 37575644941. Each architecture passes **1,190 ordinary tests (1,187 passed, 3 intentional pre-weight model skips), 732 focused and 12 actual-model tests**, zero failures, plus both actual ZIP/DMG installed startup, native pin and existing feature/cleanup gates. Stages overlap and are not additive distinct-test totals. Both architecture installer replacements are confirmed; Intel DMG/ZIP Library version 8 and guide version 15 are saved, with ARM bytes unchanged. Physical Spaces/Retina/TCC, all remaining feature gaps and sustained-use evidence remain open. Full GIF stress is ZIP-only on each architecture. Acceptance is limited to 03cf310/build 67; no 0.11 acceptance is claimed. See [VERIFICATION.md](VERIFICATION.md) for exact bytes and process/workload-qualified measurements.

## Implemented scope

Settings → 贴图 → 桌面显示 and each managed pin's context menu → 所有贴图的桌面 select **所有桌面** (all desktops) or **当前桌面** (current/assigned desktop). This is one global, persisted preference for all managed pin content kinds, not a per-pin Space destination. Saving Settings applies it to live pins; Cancel has no effect. Context selection applies immediately. Image, text, file-reference, color and animation pins share the same policy; formula pins that use `RichPinController` use the same content-agnostic route.

Missing, malformed or unknown `pinDesktopVisibility` preferences resolve to `allDesktops`, preserving old installs' behavior. Reading defaults does not write a migration. The pin-session schema is unchanged. Group switching, reopen, recovery and launch restoration all connect new controllers through the current policy before showing them. Hidden/inactive groups are not reopened by preference changes.

A mode update changes existing `NSWindow.collectionBehavior` flags only. It does not recreate controllers, change geometry/opacity/lock/click-through/zoom, invoke image decoding or rendering, restart animation, update PNGs or rewrite the pin-session manifest. Independently stored pending presentation changes are left alone. The service owns only the preference value and optional defaults, not windows, images, observers or tasks. Managed menu callbacks are weak and invalidated at close.

## Exact public AppKit semantics

- **All desktops** adds `canJoinAllSpaces`, while removing `moveToActiveSpace`.
- **Current/assigned desktop** removes both flags, using AppKit's default one-Space-at-a-time participation. It deliberately does **not** request activation-follow with `moveToActiveSpace`. Activating a window already on another desktop can switch the user back to that assigned desktop, depending on macOS settings.
- Other flags, including the existing `fullScreenAuxiliary`, are preserved. Window level/topmost is independent. Existing fullscreen auxiliary compatibility does not establish visibility in every unrelated full-screen app or Stage Manager layout.
- Mode changes do not activate, order, relocate or duplicate a window. macOS owns the actual assignment, including which desktop an existing all-desktops window remains on after its flag is cleared. “Current desktop” denotes single-desktop participation, not a promise to move every existing pin onto the desktop where Settings happened to open.
- New/restored windows get the selected policy at creation. No active Space IDs are read or stored. Reopening/restarting cannot promise the original Space or an arbitrary chosen desktop. Display coordinates in the pin session are screen-point geometry, not Space identities.

Primary Apple sources, checked 2026-10-07:

- [Default: one Space at a time](https://developer.apple.com/documentation/appkit/nswindowcollectionbehavior/nswindowcollectionbehaviordefault?language=objc)
- [canJoinAllSpaces](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallspaces)
- [moveToActiveSpace: activation-time movement](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/movetoactivespace)
- [CollectionBehavior: window-management preferences and mutually exclusive groups](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct)

## App-owned surfaces

Image annotation replacement panels receive the mode before showing. Live annotation, OCR/barcode results, export children and attached sheets are updated with the pin. New export children inherit their parent's Space/fullscreen flags before showing. Parent-linked Settings similarly inherit and restore their previous behavior on detach, and close with the parent. Pin close/hide/group teardown retains the existing cancellation and resource-release paths.

Formula editor integration: dismiss an open `NSPopover` only when the mode actually changes, before assigning the new mode, using the formula worker's `dismissLaTeXEditor()` hook. This closes the owned draft/preview rather than leaving a popover detached from its moved panel. Same-mode application must not discard its draft. A new content kind must use the managed controller connection; it must not create its own always-all-Spaces window.

## Automated evidence versus physical acceptance

ARM and Intel 03cf310 independently pass native XCTest, shown controls/snapshots and both installed-app public-policy fixtures. Same-mode formula-draft preservation and actual-change dismissal/teardown pass in ordinary and focused tests. The original Linux authoring checkpoint had no native result; it is superseded only for the identified ARM/Intel 03cf310 source and its architecture-specific results. `physicalSpacesVerified` remains **false**: no synthetic result establishes actual multi-Space placement.

New tests cover preference defaults/migration/fallback, policy preservation, real AppKit parent/child flags, actual context target/action controls, Settings save/cancel/smoke isolation, repeated in-place toggles, controller/pixel identity, unchanged session files, annotation ownership, hide/show, group switching, close/restore, recovery, restart, weak-reference controller/content teardown and a public CGDataProvider release callback for the original image backing. The shown-window fixture emits a JSON report and two native content-view PNG snapshots, with `physicalSpacesVerified: false` hard-coded.

On a native macOS build, run:

```sh
swift test --filter PinDesktopVisibility
scripts/pin-desktop-visibility-smoke.sh /absolute/PicShot.app /absolute/evidence-directory EXPECTED_COMMIT
```

The smoke wrapper is opt-in. It verifies the existing bundle signature, launches the installed bundle, checks the embedded source commit when supplied, validates the report and PNG signatures, and does not alter default CI, package versions, signing settings or releases.

### Independent Intel acceptance and remaining physical boundary

Intel 0.10 build 67 at 03cf310 passed run 37575644941 attempt 2/job 112653589644. Each actual ZIP/DMG desktop launch report identifies the exact source and records **25 context actions, 27 in-place toggles, unchanged session bytes, no activation-follow flag, released closed controllers and released original raster provider**. Synthetic content kinds in this desktop fixture are image/text/files/color/animation; managed LaTeX integration is checked separately. Same-mode formula/group draft preservation and actual-change dismissal regressions pass in Intel ordinary/focused tests. Neither installed desktop fixture reads/writes user preferences or requests screen capture.

Both reports retain **`physicalSpacesVerified: false`** and explicitly mark real two-desktop/fullscreen/two-display/Stage Manager acceptance **NOT RUN**. Intel acceptance does not resolve named/per-pin placement, active-Space following, original-Space restore or the interactive checklist below. Exact installer hashes and the separate formula/group/resource workloads are in [VERIFICATION.md](VERIFICATION.md); no parent-memory or preview-stability conclusion is derived from public-flag lifecycle passes.

### Required interactive acceptance, not run by the fixture

Record macOS version, architecture, app source commit, Mission Control settings (including display-separate Spaces), fullscreen/Stage Manager state, and screenshots or a short recording:

1. With two ordinary desktops, create each pin kind on desktop A. All mode: switch A/B and record visibility. Current mode: repeat and record actual one-desktop assignment, including an all→current change initiated on B. Confirm activation does not silently turn on follow-to-active-space.
2. Repeat current→all→current at least ten times with pins on both monitors. Observe frames, opacity, click-through, locks and active app; confirm no duplicate or orphan surfaces.
3. Open an annotation/editor, OCR/barcode result, export child and formula popover, then change mode. Close/hide/switch groups while each is open. Verify teardown, no hidden interactive child, and whether macOS switches desktop on activation as described.
4. Close/restore, hide/show, switch groups, recover click-through/low-opacity pins, quit/relaunch with restore enabled, then repeat with restore disabled. Record actual desktop assignment; do not expect original-Space restoration.
5. Repeat with a full-screen app, Stage Manager on/off, separate-Spaces displays, a display removal, and a return from sleep. Verify usability, not merely flag values.

Until this evidence exists, MAC-07 remains partial: mode selection is implemented, real Mission Control/Spaces behavior is an explicit pending acceptance gate. Named desktop targeting and exact Space restoration are not implemented.
