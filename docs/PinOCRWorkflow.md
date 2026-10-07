# Automatic and source-linked pin OCR

Prepared for the 0.11 candidate. Native compilation, installed interactions and resource measurements are pending; the accepted installers remain separately identified in [VERIFICATION.md](VERIFICATION.md).

## User flow

Settings → 贴图 and an image pin's 识别 submenu share the default-off **自动识别贴图文字** preference. Enabling it applies to live image pins without opening hidden groups. Opening or restoring an eligible pin schedules local Vision recognition. Background completion does not activate a window, change its first responder, open a result dialog or write the clipboard, including when the separate direct-copy preference is enabled.

Command-Shift-T explicitly enters word selection. Command-C retains the selected-text/image behavior; the displayed pin-local Command-Shift-C action copies the complete recognition result. Escape leaves selection and suppresses immediate automatic reentry. A later hide/show, image revision or explicit recognition action can resume it.

Selection, copy-all and the result dialog reuse one current recognition result for the pin's image revision and language/orientation. Selecting text in the result highlights matching source words. Selecting source words selects corresponding output text without changing window focus. Capture/history results can reveal a compact **原图** preview; pin-linked panels use the existing pin and need not retain another raster.

## Mapping and edits

The original recognized text and word geometry are kept together. Appended barcode/status text and newly inserted or replaced text have no source-text geometry. Untouched spans retain their exact UTF-16/grapheme correspondence through supported layout actions and edits. Equal-looking words are never relinked by searching; undo does not invent provenance for previously replaced text. A language rerun replaces text and geometry together.

Mapping is bounded to 131,072 editable UTF-16 units and 4,096 spans. Exceeding that budget leaves text editable/copyable but pauses source linking with a visible status; new recognition can restore it. Layout projection uses an ordered span sweep rather than a lines-by-spans scan. These mapping limits do not increase Vision's recognition limits.

## Ownership and admission

`PinOCRSession` retains one image-free result for a revision/options key. Waiting work holds weak session identities, not one task or captured raster per restored pin. `PinOCRScheduler` admits at most two jobs, at most one as automatic work, and queues at most 32 weak identities. Explicit requests take priority. Its production recognizer still passes through the unchanged global Vision admission of two active and four waiting requests.

An admitted job obtains its raster from a weak pin provider. Cancelled running work keeps its admission slot until the provider returns. A consumer's cancellation token cannot cancel a newer subscription of the same purpose. Generation/key checks reject late results after image edits, language changes or closure. Crop, annotation, export, barcode mode, hiding, click-through and closure suspend or close the session as appropriate; resuming alone does not start work.

The existing limits remain 32 million source pixels, 512 recognized lines, 32,768 recognized UTF-16 units and 8,192 geometry units. A cancelled native Vision call is cooperative; no claim is made that an arbitrary framework call can be forcibly interrupted mid-call. These admission limits are not a whole-process RSS quota.

## Verification scope

The authored session, projection and AppKit integration tests cover deduplication, consumer cancellation, generations, passive focus, clipboard isolation, layout/edit provenance, full-group queuing and lifecycle transitions. They are not execution evidence until the native gates pass.

`PinOCRWorkflowSmokeFixture` is intended for both installed formats. It uses actual Vision on an authored 1000 × 320 CoreText image, native controls, a private clipboard/defaults/store, bounded deterministic restoration races and a separate two-warmup/twelve-cycle actual-recognition resource phase. Screenshots are outside the measured interval and compose the native window background. The report distinguishes actual recognition from cached or injected results, RSS from footprint, and comparable cycle endpoints from final cleanup.

No screenshot upload, global input posting, TCC change or new model download is required by this flow. Physical Retina selection, real desktop capture, external-application drag/drop, arbitrary-document accuracy and sustained memory behavior remain separate acceptance work. Existing export-preview backing growth remains unresolved; this OCR work is not a general memory-fix claim.
