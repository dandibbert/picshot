# Named local capture chains

This is the first bounded action-chain implementation and still requires native qualification. It is not scripting support or a claim of complete PixPin action parity. The current delivered experimental package remains build 241 until a fresh package is qualified.

## Workflow

Open **截图动作链 → 管理截图动作链…** from the existing capture menu. Create a name, choose Region or an existing saved preset, select one to three distinct outputs, and reorder them with the existing up/down controls. **保存更改** commits only the definition; **取消更改** discards the draft. Running a chain captures once and gives every output the same immutable selected image. A missing preset is explicitly unavailable and never falls back to another source. Existing managers refresh after preset creation, rename and deletion.

Available outputs are **快速保存 PNG**, **复制**, and **贴图**. Save uses the existing destination/naming/collision workflow and atomic bounded writer. Copy checks encoding and the pasteboard recipient. Pin uses the existing durable session coordinator and its 32,000,000-pixel per-pin and aggregate session bounds. It does not fall back to an unsaved transient pin. A failed output retains the capture for **重试未完成操作**; a committed earlier output is shown in the receipt and never replayed.

**取消运行** and window Close stop subsequent actions and wait for their owned operation to drain. A file already committed before cancellation remains successful and visible in the receipt. Cancellation before a commit, a failed write, and completed publication are distinct outcomes. Successfully completed runs release their capture automatically and leave only a value-only receipt. A failed acquisition can be run again; it has no captured image to retry. The app admits only one active chain and blocks another capture or Quit while that retained capture is still in use.

The selected-chain global shortcut starts unassigned. Set a saved chain as current explicitly, then assign a chord in the existing shortcut settings. No selection means guidance, never an implicit first chain. Existing six-action settings remain readable by older builds: the additional chord uses a separate validated local preference. Portable v1 export/import retains its existing six-action schema and does not export the chain definitions or extra chord. Import conflict checks include the retained local chord before committing any settings.

## Persistence, ownership and limits

At most 32 definitions are stored in a version-1 manifest capped at 128 KiB. Names are limited to 64 characters and 256 UTF-8 bytes with no controls/newlines. Stable UUIDs identify definitions and preset references. Definitions contain source reference and output order only: no screenshot bytes, output paths, receipts, clipboard data, secrets or executable content. File corruption, unsupported versions, unknown fields and invalid selections fail closed without replacing the prior catalog. Disk failures leave both the existing saved definition and the current draft intact.

The runtime retains only the detached selected raster, capture time and bounded current receipt, not the frozen full-desktop presentation. Existing capture recovery/editor admission, image export and pin limits still apply. Runtime errors replace one bounded status string; they are not appended to persistent history. Chains do not automatically add a separate history entry or editor window. Save and pin outputs are deliberately persistent results and are not deleted when the transient chain closes.

## Verification scope

Focused tests cover all 15 ordered nonempty output subsets, exact image reuse, commit/cancel ordering, retry of only unfinished work, stale and duplicate commands, manifest corruption/write rollback, provider release, app admission and old settings compatibility. The native demonstration uses an isolated numbered image and actual app manager controls, the existing PNG writer, a deliberately rejected first private clipboard write followed by successful retry, durable Pin publication and reload. It also closes a run after Save succeeds and Copy fails, requiring the file to remain while Pin never executes. Independent output decoding, light/dark full-frame layout, native route and bounded owner drainage are required. No physical screen acquisition, global key event routing, real ScreenCaptureKit permission, overall memory improvement or full installer acceptance is implied by this fixture.

Independent source review identified and corrected synchronous Cancel/Close delivery before progress/release could discard the command, real region-Escape cancellation classification, and live preset-picker refresh. These corrections still need native execution. The existing build 227 warm/late RSS failures remain preserved.
