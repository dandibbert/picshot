# PicShot feature and acceptance ledger

**Target: an original native macOS equivalent of the complete PixPin feature set, including premium capabilities. This is not a completed parity claim.**

Baseline: [PixPin 3.5.5.1, released 11 September 2026][release]. Research and code review date: 6 October 2026. The release is the version boundary; linked living manuals were consulted for behavior. Later manual changes do not silently expand or shrink that boundary. This ledger is a requirements and acceptance plan, not a reproduction of PixPin source, artwork, models, credentials, or services.

Implementation snapshot: checkout based on `1ae873bd896d8c1c838f8b39addbe00c00ccc4b8`, including work-in-progress source inspected on the review date. Source can change after this snapshot. Reconcile rows against the final commit before release.

## Status rules

- **Code**: a reachable implementation was found for the narrowly stated row. This does not mean a build, test, or real-device acceptance run passed.
- **Partial**: some implementation exists, but the row's full behavior is incomplete or materially constrained.
- **Missing**: no implementation was found in the inspected source. A menu label, placeholder, API type, or proposed dependency does not count.
- **Platform**: vendor documents the behavior as Windows-specific; a macOS adaptation is separately identified, never quietly counted as implemented.
- **Unverified source**: explicitly requested scope retained, but the consulted primary documents do not yet substantiate that exact variant.
- **Test state is independent of code state.** The test inventory below records authored coverage only. No passed test, CI, installer, interactive workflow, sustained recording, or leak claim is established by this review. Attach commit-specific evidence in [VERIFICATION.md](VERIFICATION.md).

All acceptance checks below are **pending**, including rows marked Code. They are original proposed tests, not assertions that PixPin or PicShot passed them. A row can be closed only with a final implementation reference, exact commit, relevant automated result, and the required real-device evidence. Missing and Partial rows remain in scope until completed or the user explicitly changes the goal.

### Current main gaps

Advanced selection; editable annotation geometry/style/text and the missing annotation families; persistent multi-type pins and groups; complete multilingual OCR interaction; automatic/reversible scrolling; recording pause/replay/effects/camera/recovery; WebP/AVIF/BMP exports and advanced save controls; structured table recognition; image-to-math recognition and interchange; translation and configuration sync.

The editor currently has **13 modes, including Select and Crop**. That is not 13 PixPin annotation families. Text pins currently reuse the OCR result window and do not participate in the image-pin lifecycle. GIF export currently defaults to the first 30 seconds. Microphone recording currently requires macOS 15+ and a suitable Xcode 16+ build.

## Implementation reference key

Paths are relative to the repository root. These are code evidence, not test results.

| Key | Inspected implementation |
| --- | --- |
| C | `Sources/PicShot/CaptureService.swift`: `CaptureService`, `ScreenshotCommand`, region selection |
| A | `Sources/PicShot/AppMain.swift`: app menus, workflows, clipboard dispatch, history UI |
| E | `Sources/PicShot/ImageEditor.swift`: tools, raster renderer, canvas, controller, export |
| P | `Sources/PicShot/PinController.swift`: floating static image panel |
| O | `Sources/PicShot/RecognitionService.swift`: Apple Vision OCR/barcodes, text result window |
| L | `Sources/PicShot/ScrollCaptureController.swift`, `Sources/PicShotCore/ScrollStitcher.swift` |
| R | `Sources/PicShot/RecordingService.swift`, `Sources/PicShot/RecordingPanelController.swift` |
| G | `Sources/PicShot/GIFExporter.swift`: bounded sequential MP4-to-GIF export |
| H | `Sources/PicShot/HistoryStore.swift`, `Sources/PicShotCore/HistoryIndex.swift` |
| K | `Sources/PicShot/HotKeyService.swift`, `Sources/PicShot/SettingsController.swift` |
| I | `Sources/PicShot/ImageUtilities.swift`: ImageIO first-frame import and PNG clipboard |

## 1. Capture and selection

Requirement sources: [static capture][capture], [capture configuration][capture-config], [3.5 release][release], [FAQ][faq].

| ID | Required behavior | Code state / evidence and remaining work | Acceptance check to record |
| --- | --- | --- | --- |
| CAP-01 | Rectangular region capture | **Code**, C/A: Apple's interactive `screencapture -i -s`, then history/editor | Capture a known pixel grid at 1× and 2×; Escape and repeat; compare exact output dimensions |
| CAP-02 | Individual window capture | **Code**, C: `-i -w -o`; window shadow is forcibly omitted | Capture normal, overlapping, and partially off-screen windows; confirm chosen content and cancellation |
| CAP-03 | Current or explicitly selected display | **Code**, C/A: ScreenCaptureKit display ID, pointer display, per-screen menu | On two physical monitors, select each; verify no fixed 2× scale or swapped monitor |
| CAP-04 | All-screen composite | **Missing**; current Full Screen captures one display | Compare monitor arrangements with negative origins, gaps, rotations, and mixed scales |
| CAP-05 | UI element detection and parent/child traversal | **Missing**; no Accessibility hierarchy selection. Vendor explicitly supports fine-grained macOS elements [capture] | Select a button then its parent panel and child; inaccessible custom controls must fall back cleanly |
| CAP-06 | Delayed/custom rectangle capture and saved presets | **Missing** for screenshots; A's fixed 180 ms delay and L's three-second delay are not presets | Save two named rectangles/delays, relaunch, invoke each, cancel countdown without capture |
| CAP-07 | Pixel nudging, numeric dimensions, ratio constraints | **Missing** in screenshot selection; E's square drawing constraint is an editor-only feature | Enter exact dimensions; nudge and resize one pixel at a time on a Retina screen |
| CAP-08 | Capture magnifier and pixel coordinates | **Missing** | Check a one-pixel checkerboard at selection edges and across monitor boundaries |
| CAP-09 | Color sampling and RGB/HEX/HSV/HSL copy | **Missing**; a standard annotation color well is not screen sampling | Sample reference swatches and verify clipboard values including conversion rounding |
| CAP-10 | Screenshot cursor visibility option | **Missing**; C disables the display cursor; no screenshot toggle | Capture the same position with cursor enabled/disabled and compare only intended pixels |
| CAP-11 | Rounded regions, configurable shadows/borders | **Missing**; C removes system window shadows | Export translucent corners and colored border to alpha/non-alpha formats; document flattening |
| CAP-12 | Multiple regions with add/subtract and one merged result | **Missing** [release] | Combine disjoint and overlapping selections; subtract interior area; compare mask and output |
| CAP-13 | Freehand closed-area and polygon selection | **Missing** [release] | Draw concave polygon/freehand masks, cancel incomplete polygon, verify outside alpha |
| CAP-14 | Multiple-window selection in one capture | **Missing** [release] | Select and deselect three windows on separate screens, then verify combined result |
| CAP-15 | Selection refresh and region/image recall | **Partial**, H has saved raster history; no in-selector refresh or region history | Recall prior geometry independently from prior pixels; refresh after app content changes |
| CAP-16 | Integrated copy/save/pin/OCR actions | **Partial**, A/E provide these after entering editor, not within the capture overlay | Exercise every destination after capture; verify no stale result or accidental second capture |

## 2. Annotation and editing

The full target includes more than thirteen annotation families, not merely thirteen toolbar entries. [Annotation overview][mark] documents object re-editing and undo/redo. Individual manuals below define the richer tools.

| ID | Required behavior | Code state / evidence and remaining work | Acceptance check to record |
| --- | --- | --- | --- |
| ANN-01 | Rectangle/ellipse drawing | **Partial**, E draws outlines with color/width and square/circle constraint; missing fills, stroke styles, rounding, arc/sector variants [geometry] | Render and reopen examples with each required geometry/style at multiple zoom levels |
| ANN-02 | Editable object geometry | **Partial**, E selects, moves, deletes objects; no resize handles, rotation, endpoint edits, or duplication gesture [geometry][mark] | Draw once; resize/rotate/move/duplicate; undo each mutation without raster damage |
| ANN-03 | Text with continued editing and typography | **Partial**, E adds single-line text through a dialog using fixed font; no text re-edit, wrapping, font selection, outline/background, rotation [text-mark] | Edit an existing multilingual paragraph, resize wrapping, change style, export and compare |
| ANN-04 | Pencil/freehand | **Partial**, E records points and renders lines; smoothing and constrained-angle modes missing [pencil][mark-config] | Draw slow/fast strokes, constrain angles, undo; compare preview and saved pixels |
| ANN-05 | Highlighter | **Partial**, E has translucent rectangular fill; freehand strokes and alternate blend behavior missing [highlighter] | Highlight dark and light screenshots without losing underlying text readability |
| ANN-06 | Arrows and attached comments | **Partial**, E has one simple arrow; missing endpoint/style editing, angle constraints, and attached comments [arrow] | Reposition endpoints and comment; change arrowheads and line style; maintain association |
| ANN-07 | Straight line and polyline | **Partial**, E has straight line; no click-defined editable polyline, arrow toggling, line/join/end styles [line] | Create four-node polyline, modify a middle node, toggle arrows, finish/cancel correctly |
| ANN-08 | Numbering/sequence callouts | **Partial**, E increments numeric circles; missing manual value, alphabet/Roman modes, comments, arrows, renumbering/global counter [serial][release] | Start at 7, remove a middle item, undo, switch sequence style and test separate documents |
| ANN-09 | Opaque redaction | **Code**, E forces alpha 1 and rasterizes; this is an added privacy-safe primitive | Pixel-test covered area and reopen every export; ensure source layers/text are absent |
| ANN-10 | Mosaic and blur | **Partial**, E uses rectangular Core Image effects; no brush mode or post-draw strength/type editing [mosaic] | Inspect affected region and unchanged exterior; test export; never label cosmetic blur secure redaction |
| ANN-11 | Annotation eraser | **Missing**; deleting a whole selected object is not a brush/rectangle eraser [eraser] | Remove only half a stroke, then undo; retain base screenshot and unaffected annotations |
| ANN-12 | Spotlight | **Missing** [spotlight] | Highlight a region; vary outside dimming, border and size; verify stacking/export |
| ANN-13 | Watermark | **Missing**; ordinary text is not tiled/anchored watermark with timestamp variables [watermark] | Test tiled and corner placements, opacity, resize and capture-time substitution |
| ANN-14 | Magnifier annotation | **Missing**; editor zoom does not create a magnified inset [magnifier] | Move source and lens independently; test connector, clipping, scaling and final exported inset |
| ANN-15 | Automatic matching mosaic | **Missing**; no repeated-content matching [mosaic] | Use repeated names/icons with a similar nonmatch; review additions/removals |
| ANN-16 | Synchronized repeated mosaic edits (premium) | **Missing** [mark-config] | Add/delete one matching target and verify synchronized peers plus undo behavior |
| ANN-17 | Smart offline erase/inpainting (premium) | **Missing**; no model or image-inpainting implementation [mosaic] | With network disabled, remove content against simple/textured backgrounds and inspect edges |
| ANN-18 | Undo/redo and editing history | **Partial**, E stores up to 100 in-memory snapshots, including crop; history stores flattened images, not editable sessions [mark] | Undo/redo mixed object edits and crop; reopen history and verify retained edit state once implemented |
| ANN-19 | Pin annotation, hiding annotations, element/text snapping | **Missing**; P has no editor launch or overlay. Premium text snapping remains required [pin][pro] | Annotate an existing pin, hide/show marks, snap to detected text without modifying source |
| ANN-20 | Tool styling, presets, palette, custom toolbar and shortcuts | **Partial**, E has one color/width control for new objects; no per-tool persistence or toolbar configuration [mark][toolbar] | Configure tool order and styles, relaunch, switch tools and edit an existing object |
| ANN-21 | Crop and editor zoom | **Code** for rectangular destructive crop and preset/fit zoom, E; crop flattens annotations | Crop each edge at noninteger zoom, undo, export; compare exact image-space coordinates |
| ANN-22 | Image transforms and adjustments | **Missing** for rotation/flip/grayscale/invert/brightness controls [pin-image] | Apply transformations, reset, compare dimensions and pixels, preserve expected alpha |

## 3. Pins, content types, and workspaces

Sources: [pin operations][pin], [images][pin-image], [text][pin-text], [files][pin-file], [colors][pin-color], [LaTeX pins][pin-latex], [groups][pin-group], [settings][pin-config], [release][release].

| ID | Required behavior | Code state / evidence and remaining work | Acceptance check to record |
| --- | --- | --- | --- |
| PIN-01 | Static image pins from capture, clipboard and files | **Code**, A/P/I; files can be imported then pinned; always centered | Pin images through all three routes, copy back, close repeatedly; preserve source resolution |
| PIN-02 | Animated GIF and WebP pins | **Missing**; I decodes frame zero and P stores one CGImage [release] | Play multi-frame files with unequal delays, transparency and loops; verify pause/lifecycle behavior |
| PIN-03 | Plain-text pins | **Partial**, A creates a floating O text-result window; it is not an image-pin controller | Select/copy/edit text, hide/restore all pins, switch desktops and close/reopen consistently |
| PIN-04 | Rich-text/HTML pins and ignore-format toggle | **Missing**; O sets `isRichText = false` [pin-text] | Paste styled content from browser/editor; switch plain/rich view without losing original text |
| PIN-05 | File/folder and multiple-file pins | **Missing**, A dispatches only image or string. This is supported on vendor macOS, not a Windows exclusion [pin-file] | Paste files/folders, open/reveal/copy paths, drag to another app; handle a moved/missing file |
| PIN-06 | Color pins with format conversion | **Missing** [pin-color] | Paste HEX, RGB and a named color; compare swatch and round-trip copy values |
| PIN-07 | Rendered LaTeX pins and retained source | **Missing**; literal text pins do not render mathematics [pin-latex] | Paste nested fractions/matrices; re-copy source, resize without clipping; reject invalid input visibly |
| PIN-08 | Move/zoom/opacity and reset controls | **Partial**, P resizes window, offers 0.15–1 opacity and reset size; no wheel zoom, pixel nudge or previous zoom state | Repeatedly zoom/reset on mixed-scale screens; copy current versus original image once supported |
| PIN-09 | Lock modes and state indication | **Partial**, P prevents moving/resizing; opacity/closing remain available and no state feedback | Lock each supported operation category; confirm only permitted interactions remain |
| PIN-10 | Click-through and recovery | **Code** for image pins, P/A: `ignoresMouseEvents`, menu restore; restore recenters and resets opacity | Click an underlying control through a pin; recover without quitting; test multiple pins |
| PIN-11 | Topmost toggle and fullscreen/desktop visibility | **Partial**, P is always floating on all Spaces; no topmost toggle or per-desktop scope | Verify selected Spaces/fullscreen behavior on two displays after toggling visibility |
| PIN-12 | Hide/show and isolate selected pins | **Partial**, A hides/restores image pins; does not cover text windows; no isolate action | Hide all types, create another pin, isolate one, then restore prior layout |
| PIN-13 | Multi-select, collective transforms and alignment | **Missing**; no shared selection or left/right alignment [release][release-249] | Select three pins, move/scale as a group and align edges without altering unselected pins |
| PIN-14 | Named/color-tagged pin groups | **Missing** [pin-group] | Create/switch/reorder groups, move pins, reject duplicate names, verify per-group closed history |
| PIN-15 | Restart restoration and closed-pin history | **Missing**; A retains controllers only in memory; H is screenshot history, not pin sessions [pin-config] | Quit with several pin types, relaunch, restore positions/content/group/visibility accurately |
| PIN-16 | Thumbnail/viewport crop and original/current copy | **Missing**; P copies original pixels irrespective of display opacity/size [pin][pin-image] | Pan a cropped viewport, export current view and original separately; restore full image |
| PIN-17 | Pin titles, drag-out, focus cycling and color sampling | **Missing** beyond a generated title [pin] | Rename, cycle among pins, drag content to another app, sample pixel from transformed image |
| PIN-18 | Image OCR selection overlay and drag recognized text | **Missing**; OCR exists in a separate result window [pin-image] | Select one word directly on a pin and drag it to a text field; compare selection coordinates |
| PIN-19 | Capacity and off-screen recovery | **Partial**, A limits image pins to 20 and approximately 400 MB, restore centers them; no persisted recovery | Hit limit cleanly; unplug a monitor with pins on it; verify reachable recovery and no lost content |

## 4. Local OCR and code recognition

Sources: [offline OCR][ocr], [premium languages/barcodes][pro], [image recognition interaction][pin-image], [release][release].

| ID | Required behavior | Code state / evidence and remaining work | Acceptance check to record |
| --- | --- | --- | --- |
| OCR-01 | Offline OCR from captured/imported/history images | **Code**, O uses local `VNRecognizeTextRequest`; A/E expose actions | Disable network; recognize controlled Chinese/English fixtures and verify no outbound request |
| OCR-02 | Full multilingual OCR and language controls | **Partial**, O requests Simplified Chinese, Traditional Chinese and English with auto-detection; no language UI or corpus evidence | Test Japanese, Korean, French, German, Spanish and Portuguese as well; record per-language accuracy |
| OCR-03 | Editable result, copy and text export | **Code**, O has editable plain text, copy-all and UTF-8 export | Correct recognition, export/reopen with emoji and combining characters, check clipboard |
| OCR-04 | Layout/punctuation options, linked source highlight | **Missing**; O returns line-sorted strings without bounding-box result UI [release][ocr] | Select output text and compare source highlight; test columns and punctuation preservation |
| OCR-05 | QR recognition with multiple-result browsing | **Partial**, O runs `VNDetectBarcodesRequest`, appends payload strings; no per-result overlay/link controls or detection modes | Recognize multiple rotated QR fixtures; never auto-open payload; copy exact bytes/text |
| OCR-06 | Industrial barcode formats (premium) | **Partial**, Vision request exists but symbologies/quality are not pinned or individually validated | Test Code128, EAN13, UPCA, Code39, DataMatrix and PDF417 fixtures, including near-misses |
| OCR-07 | Automatic recognition on pins and quick-copy routes | **Missing** for automatic pin overlays and capture-local actions | Pin once, select a phrase without extra dialog, invoke copy-all shortcut with correct focus |
| OCR-08 | Search recognized history text | **Code**, A/H persist explicitly recognized text and search it; no background indexing | OCR a saved item, relaunch, search Unicode text and title; test removed/missing files |

## 5. Long/scrolling capture

Sources: [long capture][long], [automatic scrolling introduction][release-238], [middle-block removal][release-343].

| ID | Required behavior | Code state / evidence and remaining work | Acceptance check to record |
| --- | --- | --- | --- |
| LONG-01 | Vertical and horizontal stitching | **Partial**, L supports down/right translation of equal-sized frames with conservative matching | Use deterministic overlapping fixtures and real pages on both axes; check seams pixel-by-pixel |
| LONG-02 | Continuous manual scrolling capture | **Partial**, L requires explicit next-frame action and three-second pause; not continuous scroll monitoring | Scroll steadily and intermittently; detect no duplicates, skipped content or accidental UI capture |
| LONG-03 | Automatic scrolling | **Missing**; L explicitly requires manual scroll [release-238] | Start/stop auto-scroll on a page and a table; reach boundary; preserve normal app controls |
| LONG-04 | Stitched live preview and viewport indicator | **Partial**, L displays only the latest frame thumbnail plus total dimensions, not the accumulated panorama | After three frames inspect beginning/middle/end in preview and identify current viewport |
| LONG-05 | Crop start/end and resume with adjusted region | **Partial**, completed image can be cropped in E; no live trimming or movable/adjustable capture box | Trim either end mid-session and continue capture without a jump or lost retained content |
| LONG-06 | Reverse-scroll automatic crop (premium) | **Missing**; L accepts only positive advances [long][pro] | Capture downward then scroll back upward; verify exact tail removal and direction reset |
| LONG-07 | Delete a middle block and reconnect remaining image | **Missing**; ordinary rectangle crop does not satisfy this [release-343] | Remove an internal advertisement band; verify upper/lower content directly meets and undo restores |
| LONG-08 | Very long capture limits and usable export | **Partial**, L caps 60 MP output, 100 frames, 512 MB temporary files and 24 MP per frame; vendor describes a much longer mode [long] | Exercise declared limits and low-disk failures; preserve accepted frames; measure peak memory |
| LONG-09 | Duplicate/ambiguous/fixed-content handling | **Partial**, L rejects uncertain matches and retains accepted frames; requires excluding fixed headers/sidebars | Try repeated rows, flat colors, dynamic content and fixed headers; reject rather than corrupt output |
| LONG-10 | Pin/copy/save/OCR and imported-frame recovery | **Partial**, L imports frames and completes into E; no capture-state direct outputs/recovery after crash | Import ordered frames, cancel an operation, retry, finish to each destination without leaked temp files |

## 6. Recording and animated export

Sources: [recording manual][recording], [recording guide][recording-guide], [release recovery changes][release], [premium recording features][pro]. GIF is silent; audio parity is judged on MP4. The vendor's trimming requirement is endpoint selection of a contiguous clip, not arbitrary removal of internal video segments [recording].

| ID | Required behavior | Code state / evidence and remaining work | Acceptance check to record |
| --- | --- | --- | --- |
| REC-01 | Display/region MP4 recording | **Code**, R uses ScreenCaptureKit plus AVAssetWriter; target is one selected display or contained region | Record motion and a clock; decode MP4 and verify crop, orientation, duration and usable final frame |
| REC-02 | GIF output | **Partial**, G converts MP4 sequentially; defaults to first 30 s, 12 FPS, 1280 px, 360 frames, 64 MiB; UI does not expose full options | Decode all GIF frames; verify timing, loop, frame cap, dimensions, cancellation and clean failure |
| REC-03 | Animated WebP output | **Missing** | Export transparency/motion fixture; decode frame delays and loop behavior in independent viewer |
| REC-04 | Ordinary editable recording versus quick MP4 mode | **Partial**, R writes MP4 live, without an editable intermediate timeline or mode choice | Verify both workflows, content parity and expected export latency on a reference clip |
| REC-05 | System audio | **Code**, R sets ScreenCaptureKit audio output with a separate writer input; real audio untested | Record known stereo tones with video clock; verify levels, sync, silence and interruption handling |
| REC-06 | Microphone with system audio | **Partial**, R gates microphone to macOS 15+/compiler 6; macOS 14 lacks implementation | On each supported OS, validate grant/deny, correct device, combined audio synchronization and messaging |
| REC-07 | Pause/resume and elapsed-time correctness | **Missing**; no pause state or sample-time retiming | Record 5 s, pause 5 s, resume 5 s; output and timer must exclude paused duration |
| REC-08 | Restart/discard and delayed start | **Partial**, R has service cancellation; no explicit restart/discard/countdown UI | Cancel startup, restart mid-recording, decline discard, then stop twice without duplicate finalization |
| REC-09 | Camera picture-in-picture (premium) | **Missing**; no camera capture/compositing [recording-guide] | Select camera, resize/crop/mirror overlay, disconnect device; confirm export and permission-denial behavior |
| REC-10 | Recording-time annotations | **Missing**; E is still-image only | Draw, erase and update annotation during recording; verify exact appearance/timing in exported frames |
| REC-11 | Click/scroll visualization (premium) | **Missing**; recording shows cursor but does not record click/scroll events | Record left/right click and horizontal/vertical scroll; replay correct position and timing |
| REC-12 | Keystroke visualization (premium) | **Missing** | Capture modifiers and text shortcuts, filter categories, stop monitoring when recording ends |
| REC-13 | Replay, seek, playback speed and progress overlay | **Missing**; R only reveals MP4 in Finder and offers GIF conversion | Seek at boundaries, vary speed, preview progress labels; compare resulting duration and frame timing |
| REC-14 | Endpoint trimming (premium) | **Missing**; G truncating to a duration cap is not selectable trimming | Choose an internal 4–9 s interval and export; verify endpoints/audio without unrelated footage |
| REC-15 | FPS/quality/export settings and audio levels | **Partial**, R UI has 5/16/24/30/60 FPS; no export quality selector, audio mixing controls, or remembered export presets | Change quality/FPS, relaunch, verify chosen settings and independently measure output |
| REC-16 | Crash recovery of recording/preview | **Missing**; a partial MP4 on disk is not resumable recovery [release] | Force terminate during capture and preview; relaunch and recover/discard via explicit prompt |
| REC-17 | Bounded resource use and failures | **Partial**, R/G implement queue, duration, byte and frame limits; runtime resource claims unproven | Record to configured duration/size bound, provoke low-disk/device removal, verify cleanup and readable result |
| REC-18 | Region motion, hotkeys and toolbar repositioning | **Missing** during active recording; no pause/stop action remapping beyond opening panel | Move recording region and toolbar, invoke control hotkeys repeatedly, ensure overlays are excluded as intended |

## 7. Export, history, configuration, and automation

Sources: [capture output][capture], [save configuration][save], [premium preview/PDF options][pro], [actions][actions], [script API][script], [mouse configuration][mouse], [global mouse][global-mouse], [custom toolbar][toolbar].

| ID | Required behavior | Code state / evidence and remaining work | Acceptance check to record |
| --- | --- | --- | --- |
| EXP-01 | PNG and JPEG still-image export | **Code**, E/I: flattened ImageIO output; JPEG quality fixed at 0.94 | Reopen with an independent decoder; inspect dimensions, alpha flattening, extension and redacted areas |
| EXP-02 | BMP, WebP and AVIF export | **Missing**; system import ability does not establish export support | Encode each required format and inspect magic bytes, transparency/quality and decoded pixels |
| EXP-03 | PDF output | **Partial**, E writes one image-sized raster page; missing pagination/margins | Export a long image using page size/margins; compare page boundaries without missing/duplicated rows |
| EXP-04 | Live encoding preview and size/quality estimate (premium) | **Missing** | Change format/quality/crop, compare preview with reopened bytes and actual file size |
| EXP-05 | Naming templates, variables, remembered paths, quick/auto save | **Partial**, E defaults to `PicShot.png`; H uses UUID names; no configurable workflow/template engine | Test time/window/size variables, invalid filenames, duplicate handling, and separate save destinations |
| EXP-06 | Clipboard image/current-original options | **Partial**, I writes PNG; P copies original only; no per-type settings or drag-out | Paste into several native apps and compare transparency, resolution and edited versus original content |
| HIS-01 | Searchable persistent image history | **Code**, H/A: PNG files, JSON index, titles, recognized-text search, stars and Trash action | Relaunch after saves; search and reopen; remove underlying file; recover user-deleted image from Trash |
| HIS-02 | Retention and storage policy | **Partial**, H/K expose positive day/count/MB caps with protected stars; no history-disable zero setting or capture-region ledger | Test count/age/bytes simultaneously, protected quota, disk failure and clearly documented cleanup |
| HIS-03 | Editable capture/annotation history and pin history | **Missing**; H stores flattened screenshots only | Reopen an old capture with original objects and prior pin state, then edit without starting over |
| CFG-01 | Remappable global shortcuts | **Partial**, K registers three actions only (region, paste pin, history), persists combinations and detects duplicate bindings | Remap, relaunch, force OS conflict, unregister old combination; display conflict to user |
| CFG-02 | All local shortcuts and custom action chains | **Missing** beyond E's hardcoded copy/save/undo keys [actions] | Bind capture-to-copy/OCR/save/pin and local tool actions; verify context and focus isolation |
| CFG-03 | Script engine and callable actions | **Missing**; no JavaScript/native action scripting host [script] | Run a bounded capture/save preset, catch invalid script, cancel; ensure no hidden external execution |
| CFG-04 | Mouse gestures, global mouse and toolbar customization | **Missing** [mouse][global-mouse][toolbar] | Configure a gesture and toolbar order; test conflict/cancel and disabled behavior across apps |
| CFG-05 | Application appearance, startup/update preferences | **Partial**, native system styling exists; no comprehensive preference set, login-item control or updater | Persist preferences and test first launch, safe update checks, disabled startup and dark/light UI |
| CFG-06 | Configuration import/export and cloud synchronization (premium) | **Missing**; only local UserDefaults. Sync remains an external-service requirement [pro] | Sync two test devices with conflict/offline handling; exclude device-specific save paths and pin content |

TIFF export is present as an extra. It does not substitute for BMP, WebP or AVIF.

## 8. Structured table recognition (premium)

Sources: [membership/table export][pro], [image-table recognition][pin-image], [3.5 table editing changes][release]. Plain OCR lines, tabs or a guessed CSV do not satisfy structured table recognition.

| ID | Required behavior | Code state / evidence and remaining work | Acceptance check to record |
| --- | --- | --- | --- |
| TAB-01 | Detect cell/row/column structure from image | **Missing**; O returns strings, no table model | Use bordered/borderless tables with blank cells and merged headings; compare expected structure |
| TAB-02 | Editable preview with merge/split cells and row/column removal | **Missing** | Correct one OCR cell, merge/split a heading, remove a column and undo without corrupting neighboring data |
| TAB-03 | Excel workbook output and default-app open | **Missing** | Open generated `.xlsx` in Excel/LibreOffice; verify Unicode, types, merged ranges and dimensions |
| TAB-04 | Table recognition from capture, pins, imported images and long-image editor | **Missing** | Run the same fixture from every entry point; preserve original image and clear error/cancel behavior |

## 9. Mathematics recognition and interchange (premium recognition)

Sources: [formula recognition][formula], [LaTeX pins][pin-latex], [3.4 interchange additions][release-343]. Rendering an already supplied formula is distinct from recognizing a formula image. A text OCR call labeled “math” is not sufficient.

| ID | Required behavior | Code state / evidence and remaining work | Acceptance check to record |
| --- | --- | --- | --- |
| MATH-01 | Image-to-LaTeX recognition, including multiple formulas | **Missing**; no math recognition model, provider or structured result | Recognize fractions, superscripts, matrices and integrals from held-out images; compare rendered meaning |
| MATH-02 | Original/source comparison and editable formula preview | **Missing** | Select a recognized formula, correct a token, update preview, zoom original/result independently |
| MATH-03 | LaTeX copy and MathML conversion | **Missing** | Round-trip representative formulas through independent renderers; verify operators and grouping |
| MATH-04 | SVG/image export and editable Office math | **Missing** | Inspect SVG scaling and import a true editable equation into Word, not a raster picture |
| MATH-05 | Typst and AsciiMath output | **Missing**; both are explicitly documented in the 3.4 release [release-343] | Round-trip fractions, matrices and nested operators through each target; disclose unsupported constructs |
| MATH-06 | File/clipboard/capture/pin input and copy-and-close | **Missing** | Exercise each entry with one/multiple formulas, invalid input and cancellation; verify target clipboard |

## 10. Translation and external services

Sources: [translation behavior][translate], [provider configuration][translate-config], [membership/sync scope][pro]. These are service-backed capabilities. “Local-first” must not be interpreted as “translation already runs offline.” The current source includes no translation or sync client.

| ID | Required behavior | Code state / evidence and remaining work | Acceptance check to record |
| --- | --- | --- | --- |
| NET-01 | Text and image-to-text translation | **Missing**; no provider, credentials flow or UI | Translate a known paragraph and OCR image; show original/target language and provider failures |
| NET-02 | Image-to-image translated overlay | **Missing**; cannot be claimed from a plain text response | Translate multi-block image and inspect layout, reading order, font fit and preserved background |
| NET-03 | Target/source language, temporary/default language and original display | **Missing** | Change one-shot target without altering default; compare original and translated content |
| NET-04 | Authorized provider integration and configuration | **Missing**; vendor documents Youdao/Baidu keys or membership-provided service | Use user-provided authorized service only; separate text/image capability errors, quotas and offline state |
| NET-05 | Secure storage, consent and secret-free export/logs | **Missing** because integration is absent; required design/acceptance gate | Check Keychain storage, explicit content disclosure, redacted logs, deletion and no accidental sync of secrets |
| NET-06 | External configuration sync | **Missing**, see CFG-06; no account or backend implementation | Verify two-device state and conflict resolution against a chosen authorized backend |

Do not borrow PixPin membership, bypass entitlements, reuse proprietary endpoints/keys, or mark service-backed rows complete with a placeholder button. The implementation may use a lawful alternative provider or a capable local model, but must disclose behavior, licensing, performance and network differences. User approval is required for setup or transmission where applicable.

## 11. macOS adaptation and explicit platform distinctions

| ID | Baseline difference | PicShot status and acceptance requirement |
| --- | --- | --- |
| MAC-01 | Vendor supports macOS 10.15+ [quick-start] | **Partial compatibility**: `Package.swift` requires macOS 14. This is a deliberate current implementation limit, not full version coverage. Validate the chosen minimum and state it on installers |
| MAC-02 | Vendor macOS supports UI-element and file pins [capture][pin-file] | These remain **Missing**, not platform exclusions |
| MAC-03 | Live window-content pins are explicitly Windows features [release-238] | **Platform; missing optional macOS adaptation**. Static window screenshots do not implement live pins. A native live-window adaptation needs its own capture/lifecycle test |
| MAC-04 | Explorer context-menu integration is Windows-specific [release-238] | **Platform**. A Finder Quick Action/Service would be a separate macOS adaptation; not implemented |
| MAC-05 | Launch-command scripting is Windows-only in vendor docs [script] | **Platform** for that entry point. The general in-app script/action capability CFG-03 still remains in macOS scope |
| MAC-06 | Fullscreen-game hotkey suppression is documented for Windows [release-238] | **Platform**. A macOS fullscreen/app exclusion setting is not currently implemented |
| MAC-07 | Fine-grained macOS per-desktop pin visibility [release] | **Missing**, distinct from P's unconditional `canJoinAllSpaces` |
| MAC-08 | Screen/system audio, microphone and Accessibility permissions | C/R request screen access on feature use; microphone is separately gated; no Accessibility integration yet. Test deny/grant/revoke/relaunch without editing TCC databases |
| MAC-09 | Packaging, architectures and trust | Source has arm64/x86_64 CI packaging, ad-hoc signing and ZIP/DMG scripts. No accepted build evidence in this review. Not notarized; never present bypassing OS security as ordinary installation |

## 12. Test inventory and release gates

### Authored tests inspected, not pass evidence

| Area | Existing test/source evidence | What it does not establish |
| --- | --- | --- |
| History | `Tests/PicShotCoreTests/HistoryTests.swift`: quota/stars, age/search, protected-over-quota cases | Filesystem failure recovery, UI, real long-running retention and editable-session history |
| Stitching | `Tests/PicShotCoreTests/ScrollStitcherTests.swift`: vertical/horizontal overlap, noise, pixel advance, duplicate/ambiguous/no-overlap rejection, limits, fixed-header case | Real app scrolling, mixed Retina screens, automatic scrolling, reverse crop or live stitched preview |
| Annotation/export | `Tests/PicShotTests/ImageEditorTests.swift`: raster extent, opaque redaction, highlighter, layer order, tool rendering, crop coordinates, filter locality, move model, reopening formats | Interactive object edits, missing tools, visual correctness of all fonts/styles, UI undo lifecycle |
| Image I/O | `Tests/PicShotTests/ImageUtilitiesTests.swift`: PNG round trip | BMP/WebP/AVIF encoding or animated pin playback |
| Recording/GIF | `Tests/PicShotTests/RecordingAndGIFTests.swift`: options/regions/dimensions, idle cancellation, synthetic sample-to-MP4 finalization, owned staging/publication, GIF timing/decoding/no-overwrite/cancellation | Real ScreenCaptureKit capture, audio/camera sync, TCC behavior, sustained output and crash recovery |
| App/package smoke | `.github/workflows/macos.yml`, `scripts/package.sh`, `scripts/smoke.sh`, `Sources/PicShot/SmokeVerification.swift` | A workflow definition is not a successful CI run; synthetic windows do not prove screen/audio workflows |

### Required evidence before a release claim

1. Build and run the final commit's entire test suite on supported arm64 and x86_64 macOS runners. Record exact commit, OS/Xcode and complete logs, including any skipped tests.
2. Install both actual ZIP and DMG artifacts into clean destinations, check expected architecture/signature, launch through normal LaunchServices, and inspect native windows. Record artifact hashes and limitations.
3. Run real-device TCC grant/deny/revoke flows and capture tests with two monitors, mixed pixel scales, non-primary focus, display removal and fullscreen Spaces.
4. Exercise complete user paths: capture → annotate → copy/export → pin → OCR → history reopen. Test repeated invocation, Escape, close/cancel, dialog dismissal and reopening.
5. Independently decode export formats and recording streams. Verify colors/alpha, clip duration, frame timing and audio sync, not just file existence.
6. Measure memory/disk use over sustained capture, long images, repeated open/close and bounded recording; inspect retained resources. Synthetic RSS measurements do not establish leak freedom.
7. Validate each premium-equivalent feature with held-out fixtures, licensing and local/network behavior. Keep disabled/unimplemented functions visibly incomplete.
8. Reconcile every ledger row against the exact release commit. Do not replace missing features with “native alternative” unless the required outcome is actually equivalent and tested.

## Primary source index

All links below are official PixPin documentation or official team articles, consulted on 6 October 2026. Individual tables cite the relevant page. Vendor feature descriptions are summarized briefly; acceptance checks and PicShot code findings are original to this review.

[release]: https://pixpin.cn/docs/official-log/3.5.5.1
[pro]: https://pixpin.cn/docs/start/pro-features
[capture]: https://pixpin.cn/docs/capture/static-capture
[capture-config]: https://pixpin.cn/docs/configuration/screenshot
[long]: https://pixpin.cn/docs/capture/long-capture
[recording]: https://pixpin.cn/docs/capture/gif-capture2
[recording-guide]: https://pixpin.cn/blog/articles/record-gif-on-computer/
[pin]: https://pixpin.cn/docs/pin/base-use
[pin-image]: https://pixpin.cn/docs/pin/image
[pin-text]: https://pixpin.cn/docs/pin/text
[pin-file]: https://pixpin.cn/docs/pin/file
[pin-color]: https://pixpin.cn/docs/pin/color
[pin-latex]: https://pixpin.cn/docs/pin/latex
[pin-group]: https://pixpin.cn/docs/pin/pin-group
[pin-config]: https://pixpin.cn/docs/configuration/pin
[mark]: https://pixpin.cn/docs/mark/base-use
[geometry]: https://pixpin.cn/docs/mark/geo
[line]: https://pixpin.cn/docs/mark/line
[arrow]: https://pixpin.cn/docs/mark/arrow
[serial]: https://pixpin.cn/docs/mark/serial
[pencil]: https://pixpin.cn/docs/mark/pencil
[highlighter]: https://pixpin.cn/docs/mark/mark-pencil
[mosaic]: https://pixpin.cn/docs/mark/mosaic
[text-mark]: https://pixpin.cn/docs/mark/text
[eraser]: https://pixpin.cn/docs/mark/erase
[spotlight]: https://pixpin.cn/docs/mark/highlight
[watermark]: https://pixpin.cn/docs/mark/watermark
[magnifier]: https://pixpin.cn/docs/mark/magnifier
[mark-config]: https://pixpin.cn/docs/configuration/mark
[save]: https://pixpin.cn/docs/configuration/save
[actions]: https://pixpin.cn/docs/configuration/actions
[script]: https://pixpin.cn/docs/configuration/script
[mouse]: https://pixpin.cn/docs/configuration/mouse
[global-mouse]: https://pixpin.cn/docs/configuration/global-mouse
[toolbar]: https://pixpin.cn/docs/configuration/customized-toolbar
[ocr]: https://pixpin.cn/blog/articles/offline-ocr-and-text-copy/
[formula]: https://pixpin.cn/docs/other/formula
[translate]: https://pixpin.cn/docs/other/translate
[translate-config]: https://pixpin.cn/docs/configuration/translate-key
[release-238]: https://pixpin.cn/docs/official-log/2.3.8.0
[release-249]: https://pixpin.cn/docs/official-log/2.4.9.6
[release-343]: https://pixpin.cn/docs/official-log/3.4.3.2
[quick-start]: https://pixpin.cn/docs/start/quick-start
[faq]: https://pixpin.cn/docs/start/faq
