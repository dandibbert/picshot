# Save and naming workflows

## Version boundary

This guide describes candidate **0.9 e4e41ba30b0c0d2bfff9cfe14fcf70eeeb0fcf4d**, with final native/package acceptance pending. The latest accepted installers remain 0.8. Earlier 14c early UI success does not erase its focused failures or transfer a pass to corrected code. See [VERIFICATION.md](VERIFICATION.md).

## Entry points

- **Settings → Save and Naming (保存与命名)** configures the base folder, subfolder/filename templates, collisions and optional automatic copies. Use **Save Settings (保存设置)** to commit; previews are drafts until then
- Editor save-options chevron/overflow: **Quick Save PNG (快速保存 PNG)**, **Save PNG and Copy (保存 PNG 并复制)** and the settings page
- Export sheet: **Quick Save** and **Save and Copy**, preserving the already prepared current format and bytes. Current/original pin export sheets share this route; the pin action determines which image is supplied
- Manual quick-save asks for a folder if none is configured. Confirming it records its physical path. Automatic saving requires a configured folder

Editor quick-save and automatic copies write flattened PNG. Export-sheet quick-save preserves the selected encoder format, including JPEG/TIFF/BMP/PDF/WebP/AVIF. Editable annotation objects and intermediate previews are not saved.

## Names and folders

One configuration stores a base directory, optional relative subfolder template and filename stem. The encoder adds its actual extension. Supported variables are **{date}** (yyyy-MM-dd), **{time}** (HH-mm-ss), **{width}**, **{height}** and **{counter}**. Time is generated for the save job using the current timezone and Gregorian/POSIX formatting; it is not capture time or window/app metadata. The persisted counter can leave gaps after cancellation.

Example subfolder: `{date}`. Filename: `PicShot-{time}-{width}x{height}-{counter}`. Unknown/malformed variables fail visibly. Names retain bounded Unicode graphemes while sanitizing unsafe characters; absolute paths and traversal are rejected. Window/app variables, arbitrary date-format expressions, per-destination profiles and general remembered picker histories remain absent.

## Default-off automatic final-action copies

Enabling this setting schedules a final flattened PNG after explicit editor **Copy**, **Pin** or **Save-to-history** actions. Immediate Copy does not wait for save admission. Application-owned jobs can continue after the editor closes.

Capture acquisition, history opening, preview updates, ongoing edits, cancellation and OCR are not triggers. This is not continuous autosave, recording autosave or automatic raw-capture retention. Collisions, admission and filesystem errors may require a visible decision.

## Collision and publication policy

Choose **Ask** or **Keep Both**. Ask offers Keep Both, Choose Another Name or Cancel. Keep Both tries numbered suffixes with exclusive creation. Existing files are never replaced by this workflow, even when an OS filename panel presents an intermediate replacement question.

An explicitly selected folder is resolved once to its physical path. Later jobs validate descriptor-relative components and identities rather than silently follow substituted paths. Candidate publication protects sources, occupied destinations and link aliases, checks private staged bytes and publishes exclusively. Unknown/replaced entries are not recursively deleted. These are source safeguards awaiting final acceptance, not a universal filesystem-race guarantee.

## Save and Copy

The file is committed first. Copy uses those same encoded bytes under their actual format type. Copy failure or cancellation after commit preserves the file; copy failure offers **Retry Copy** without re-encoding.

WebP/AVIF/PDF paste support depends on the destination app. There is no generic PNG fallback, per-type clipboard preference or general drag-out. A private-pasteboard fixture is not broad external-app interoperability. The existing ordinary PNG Copy action remains separate.

## Privacy and limits

Only finalized flattened pixels or the prepared encoded artifact enter this workflow. Naming reads no window/app identity and the workflow performs no upload. Files go to the chosen folder; synchronization of a cloud-backed folder remains that service's behavior. Clipboard actions deliberately expose the chosen output through the system clipboard.

- At most two jobs/controllers and 256 MiB estimated retained input/artifact admission, checked before a new snapshot
- At most 128 MiB encoded artifact, subject to narrower selected-encoder limits
- Eight relative folder levels, 180 bytes per rendered component and 1,024 bytes per full path
- At most 10,000 Keep Both attempts
- Five-minute cooperative save deadline; bundled-codec admission waiting is separately capped at 300 seconds

Cancellation clears queued work where possible; a synchronous native call may finish before resources drain. Cancellation after publication leaves the saved file intact. These limits are not a total-RSS ceiling, sustained-use result or zero-leak claim.

## Acceptance still needed

Final-source tests, native settings/toolbar/preview and both installed formats must pass, including repeated invocation, picker/collision cancellation, copy failure, queued cancellation and owned cleanup. Real target-app paste, physical workflows and broad filesystems remain separate from synthetic fixtures. This guide does not claim 0.9 release readiness.
