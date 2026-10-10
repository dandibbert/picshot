# Annotation appearance defaults and local tool shortcuts

This is the bounded 0.20.0 candidate scope. The accepted installer remains 0.19.1/build185 until native and installed acceptance completes. The full parity ledger remains in [PARITY.md](PARITY.md); this batch does not implement scripts, action chains or a library of named presets.

## Saved appearance

The compact annotation palette has a **样式** menu: save the current tool's appearance, restore its saved appearance, or reset that tool to its original appearance. These commands affect future marks. They do not rewrite a selected annotation, an active draft or undo history. Saving is explicit and survives cancellation of the image editor. Unsaved tools retain their existing in-session behavior.

Each drawing tool has at most one saved appearance. The schema contains only that exact tool's allowed visual fields. Annotation text, comments, watermark text, coordinates, identifiers, capture timestamps, source regions and document metadata are excluded. Opaque redaction cannot acquire transparent color or opacity through this schema. Corrupt stored data falls back to defaults without rewriting the original bytes.

## Local tool selection

Settings → **标注快捷键** contains a draft list of tool bindings. They start unassigned. A letter or number, optionally with Shift, can select a tool only while the editor canvas owns keyboard focus. Existing edit, navigation and number-comment commands remain reserved. Duplicate or reserved combinations show an error without replacing the draft binding. Save commits the draft; Cancel discards it. New editors read saved bindings, while an already open editor retains its initial binding map.

Text fields, inline annotation text, marked IME text, sheets, menus, other windows and active drawing/selection workflows do not dispatch these tool-selection bindings. This adds no global event monitor or accessibility permission.

## Portable preferences

The version-1 portable configuration optionally includes `annotationStyles` and `annotationShortcuts`. Older files that omit them preserve the destination settings; explicit empty sections reset them. The import preview shows changes before applying them. Nested keys, versions, field types, ranges, duplicate keys and shortcut conflicts are validated. Stale previews are rejected, and a failed write restores the prior persistent values, including previously absent keys. Only validated settings are exported.

## Verification plan and current boundary

Authored coverage adds 44 native test methods, preserving all 1,954 prior IDs. The expected native inventory is 1,998 methods across 225 classes. The installed fixture exercises owned keyboard/mouse events, both appearance themes, saved/reset drawing pixels, text/IME focus, settings Cancel/Save, portable review and rollback. These claims require execution against the exact packaged app; authored tests or Linux checker tests alone are not native acceptance. Physical keyboard layouts, user TCC permissions, Retina/multiple displays and long-duration use remain outside the synthetic fixture evidence.
