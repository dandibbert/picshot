# Managed pin desktop visibility

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

The code is implemented. This source-only Linux worktree has no Swift executable or macOS SDK; native XCTest, snapshots and installed-app fixture have **not been run here**. No synthetic result is evidence of actual multi-Space placement.

New tests cover preference defaults/migration/fallback, policy preservation, real AppKit parent/child flags, actual context target/action controls, Settings save/cancel/smoke isolation, repeated in-place toggles, controller/pixel identity, unchanged session files, annotation ownership, hide/show, group switching, close/restore, recovery, restart, weak-reference controller/content teardown and a public CGDataProvider release callback for the original image backing. The shown-window fixture emits a JSON report and two native content-view PNG snapshots, with `physicalSpacesVerified: false` hard-coded.

On a native macOS build, run:

```sh
swift test --filter PinDesktopVisibility
scripts/pin-desktop-visibility-smoke.sh /absolute/PicShot.app /absolute/evidence-directory EXPECTED_COMMIT
```

The smoke wrapper is opt-in. It verifies the existing bundle signature, launches the installed bundle, checks the embedded source commit when supplied, validates the report and PNG signatures, and does not alter default CI, package versions, signing settings or releases.

### Required interactive acceptance, not run by the fixture

Record macOS version, architecture, app source commit, Mission Control settings (including display-separate Spaces), fullscreen/Stage Manager state, and screenshots or a short recording:

1. With two ordinary desktops, create each pin kind on desktop A. All mode: switch A/B and record visibility. Current mode: repeat and record actual one-desktop assignment, including an all→current change initiated on B. Confirm activation does not silently turn on follow-to-active-space.
2. Repeat current→all→current at least ten times with pins on both monitors. Observe frames, opacity, click-through, locks and active app; confirm no duplicate or orphan surfaces.
3. Open an annotation/editor, OCR/barcode result, export child and formula popover, then change mode. Close/hide/switch groups while each is open. Verify teardown, no hidden interactive child, and whether macOS switches desktop on activation as described.
4. Close/restore, hide/show, switch groups, recover click-through/low-opacity pins, quit/relaunch with restore enabled, then repeat with restore disabled. Record actual desktop assignment; do not expect original-Space restoration.
5. Repeat with a full-screen app, Stage Manager on/off, separate-Spaces displays, a display removal, and a return from sleep. Verify usability, not merely flag values.

Until this evidence exists, MAC-07 remains partial: mode selection is implemented, real Mission Control/Spaces behavior is an explicit pending acceptance gate. Named desktop targeting and exact Space restoration are not implemented.
