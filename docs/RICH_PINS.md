# Managed rich pins (0.4 development milestone)

Rich pins share the image-pin catalog, groups, visibility, archive/reopen, launch-restore preference, presentation recovery, protected-group policy, and bounded disk retention. Closing archives; removing a saved item deletes only PicShot-owned payloads/posters. File references never cause deletion of their targets.

## Working entry points

- Clipboard pin: Finder file/folder selections; GIF/WebP clipboard data; safe HTML text; images; plain text; HEX/RGB/RGBA strings
- Clipboard GIF/WebP container headers are checked before choosing a still or animated pin. Genuine single-frame inputs use image pins; malformed/oversized inputs and decoder/container frame-count disagreement remain errors. RIFF ANIM/ANMF files are never silently flattened
- Image-only or unsupported HTML falls through to a valid image/plain-text clipboard representation; it is never loaded as a webpage
- Window/menu-bar menus: file/folder references, animated GIF/WebP import, and color entry
- Ordinary GIF/WebP import uses the same bounded container/frame-count classification as clipboard input; supported animations become managed pins, genuine still images retain the editor path, and decoder-incomplete animations are rejected instead of silently flattened
- File/folder selection can contain up to 64 items, in a single managed pin

## Content behavior

### Text and HTML

Selectable native text; copy the entire contents or a selection; a plain-text display toggle removes displayed formatting, and four font sizes are provided. The full-copy action places safe RTF plus plain text on the clipboard when formatted display is enabled. The display toggle is temporary; content and font scale survive session restoration.

HTML is parsed locally by a small whitelist reader, without a WebKit view or AppKit HTML importer. Supported text formatting includes bold, italic, code, paragraphs, basic lists and table separators. Scripts, style/head/template contents, embedded documents and external images are omitted; URLs are never resolved. There is no CSS layout, interactive hyperlink activation, remote image loading, or arbitrary rich-document rendering. The window states this limitation explicitly.

### File and folder references

The session stores bounded absolute local paths, names and a directory flag. It does not copy target contents, read custom icons, traverse folders, resolve cloud content, create persistent security-scoped bookmarks, or open files during restoration. Opening, revealing in Finder, copying references, or dragging rows happens only in response to user interaction. Missing/moved references remain visible and report an error when opened; re-add them after moving files. Copy/drag transfers references, not a bundled copy or upload.

### Color

sRGB values support #RGB, #RGBA, #RRGGBB, #RRGGBBAA, rgb(r,g,b), and rgba(r,g,b,a), with alpha normalized to an 8-bit channel. Pins show a color swatch and selectable HEX/RGB values with separate copy buttons. Named colors, HSL/CMYK and color-profile conversion are not implemented.

### Animated GIF and WebP

ImageIO header validation precedes import. Timing uses Apple’s documented [WebP sequence-delay keys](https://developer.apple.com/documentation/imageio/kcgimagepropertywebpdelaytime). A serial decoder produces one frame per tick, with no decoded-frame array; displayed and incoming frames are the only frame-sized application allocations. Source caching is disabled and each decoded index is evicted from ImageIO's cache. Decode work runs on a dedicated actor; cancellation guards prevent late frames from reappearing after hide/close. Hiding, switching groups, closing and termination clear the player, decoded image and compressed source ownership. Pausing retains the current image/source until hide or close.

Playback loops until paused/closed and is capped at 25 fps (delays below 40 ms are clamped). Finite-loop metadata, frame stepping, animation editing/export, speed adjustment and exotic partial-frame decoder output are not implemented. The latter reports a clear decode error instead of displaying incorrect frames. WebP animation support depends on the operating system's ImageIO decoder; unsupported animated sources are rejected by the explicit animation importer, not advertised as playable.

## Hard bounds

- All saved pins: 20 total; protected/active entries cannot be silently evicted
- All saved assets: 512 MiB, counting original/current image PNGs once each, rich payloads and posters
- Shared working-pixel budget: 100 million pixels, counting original/current image rasters, rich posters, and **two full animation frames** for each saved animation
- Live animations: at most four, within the shared 20-window limit
- Animation input: 16 MiB, 300 frames, 4 million pixels/frame, 120 million aggregate frame-pixels
- Native text: 256 KiB UTF-8 and 4,096 safe runs; serialized document payload: at most 1 MiB
- File pin: 64 references, 4,096 UTF-8 bytes/path and 1,024 UTF-8 bytes/name
- Rich posters: 480 × 280 for documents; animation posters: at most 512 pixels on the long edge
- Existing thumbnail cache remains bounded at 24 previews / 12 MiB

## Persistence and migration

Image-only sessions continue writing schema 1, with unchanged original/current PNG semantics. Adding the first rich pin upgrades the manifest to schema 2 and adds an optional typed payload descriptor. Current builds read schemas 1 and 2. Older builds reject schema 2 instead of silently flattening/rewriting rich content. Rich payload filenames must be a canonical UUID plus `.pinjson`, `.gif`, or `.webp`; raster filenames retain the UUID + `.png` restriction. Traversal, duplicate identities/filenames, symbolic-link assets and mismatched payload types are rejected. Transactions save poster/payload before atomically committing metadata and roll back both files on failure. Healthy-load cleanup includes orphan payloads and abandoned writes; malformed/unsafe manifests are not overwritten.

## Verification boundary

New source tests cover legacy/rich metadata, path and type validation, animation integer-overflow/frame/working-pixel bounds, text/HTML parser limits, safe HTML omission, color conversions, transaction rollback, mixed pin quotas, file-reference restoration without target access, cleanup, archive/reopen/repeated group switches, single-frame GIF/WebP clipboard routing, malformed/oversized container rejection, image-only HTML fallback, sequential GIF decode/release, an original animated WebP fixture (explicitly skipped when the OS lacks that decoder), and the four-animation live limit.

These tests require macOS AppKit/ImageIO for native coverage. Linux-side review and whitespace checks do not establish a successful native compile, WebP decoder behavior, drag interactions, or measured RSS. Run the full Swift suite and native UI validation before calling this milestone verified.
