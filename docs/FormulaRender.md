# Local formula preview and export

This module is integrated for the next milestone after 0.2. It adds an editable native window,
real MathJax LaTeX layout, semantic MathML, self-contained SVG, and native PNG/PDF
export. It does not use PixPin code or assets. Recognition and rendering are
separate: a recognized LaTeX string or any user-edited formula can open the window.

## Capabilities and honest boundaries

- Genuine MathJax 3.2.2 `base` + `ams` mathematical layout: fractions, roots,
  superscripts/subscripts, matrices, sums, common Latin/math text, boxed equations,
  stretched overlines/underlines and other supported TeX glyph outlines
- PNG, self-contained SVG, vector PDF, LaTeX `.tex` and semantic MathML `.mml`
- Font size 12–96 points, PNG 1×/2×/3× scale, white or transparent background
- Native editable text and image preview; manual Update Preview avoids spawning
  a renderer on every keystroke; Command-Return renders
- Editing source/options immediately invalidates all old image/export formats
- Office-friendly image insertion using PNG/SVG. Target software decides whether
  MathML can be pasted as an editable formula. There is **no OMML converter**
- **No Typst or AsciiMath converter**; these remain explicit missing capabilities
- This is mathematical LaTeX, not a full TeX distribution/document processor.
  Custom macro definitions, resource loading, HTML/link commands and unbundled
  extensions are disabled. Glyphs absent from the bundled MathJax TeX font,
  including most CJK text, fail explicitly rather than silently becoming blank
- Unsupported SVG constructs/styles fail closed. The native reader is intentionally
  not a general SVG/HTML importer. All exported SVG is rebuilt from vetted paths,
  rectangles, lines and local clipping regions

## Architecture / memory

`FormulaRenderController(latex:)` owns a SwiftUI editor and an ordinary `NSImage`
preview. `FormulaRenderService.shared` admits only one job globally, creates a
private 0700 temporary directory, launches the signed native
`PicShotFormulaRenderHelper`, monitors it, reads bounded output, and removes the
job directory once the process exits. Closing the window clears its image/result.

The helper runs a fresh JavaScriptCore context without exposing Objective-C
objects, DOM, filesystem, network, timers, Node or browser APIs. LaTeX enters as a
JSON object argument to a fixed function, never as JavaScript source. A narrow
MathJax bundle generates real glyph paths and MathML; native CoreGraphics draws
those same paths and clips into PNG and a single-page vector PDF. No WebKit,
Electron, browser process, Python, Node or persistent JS heap is used at runtime.

Limits: 8 KiB UTF-8 LaTeX; 500 MathJax macro substitutions; 16 KiB expanded TeX
buffer; 128 tree levels; 8 nested clips; 8192 drawing items; 200,000 SVG path
segments; 4096 pixels per axis and 4,194,304 output pixels; 2 MiB SVG; 256 KiB
MathML; 24 MiB total encoded result; 10-second parent wall clock; 256 MiB helper
RSS watchdog; 8/9-second CPU rlimits; independent 12-second helper alarm.
Cancellation sends termination immediately and escalates to SIGKILL after 0.5 s
if needed. Only one helper remains admitted until it exits. A replacement render
in the same editor waits for its cancelled job to unwind. Another window may
briefly report busy while the globally admitted job exits.

The parent validates both app and helper signatures including nested resources,
refuses symlinked executable paths and does not inherit DYLD, proxy credentials or
other ambient shell environment. The helper verifies the JS asset SHA-256 before
loading. There are no runtime URL loaders, remote fonts, remote rendering services
or telemetry. SVG fragment-only clip references (`url(#clipN)`) refer only to
self-contained definitions. JS errors never log user LaTeX. A force-killed parent
can leave its private OS temporary directory until OS/user cleanup; the helper's
independent deadline still ends rendering.

## Integrated targets and package layout

`Package.swift` now includes the render core, helper executable/product and both
native test targets. The PicShot and PicShotTests targets depend on the render
core. The recognition window's “公式预览与更多导出…” button opens its current
editable LaTeX in one retained preview window. Repeated clicks reuse that window
and update it from the current recognized/editor text. Closing either window
cancels rendering; closing the recognition window also closes/releases its
preview. This does not download recognition models. `AppMain.swift` is unchanged
by this module.

Target configuration:

```swift
// products
.executable(name: "PicShotFormulaRenderHelper", targets: ["PicShotFormulaRenderHelper"])
// targets
.target(name: "PicShotFormulaRenderCore"),
.executableTarget(name: "PicShotFormulaRenderHelper", dependencies: ["PicShotFormulaRenderCore"],
                  resources: [.copy("FormulaRenderResources")]),
.testTarget(name: "PicShotFormulaRenderCoreTests", dependencies: ["PicShotFormulaRenderCore"]),
.testTarget(name: "PicShotFormulaRenderHelperTests", dependencies: ["PicShotFormulaRenderHelper", "PicShotFormulaRenderCore"])
```

The existing `PicShotTests` target discovers `FormulaRenderCancellationTests.swift`
automatically. System frameworks autolink through Swift imports.

`scripts/package.sh` copies both the helper executable and its entire SwiftPM
resource bundle before signing the app, then runs the relocation verifier after
strict signature validation and before creating either archive. Its packaging
steps include:

```sh
cp "$bin/PicShotFormulaRenderHelper" "$app/Contents/Helpers/PicShotFormulaRenderHelper"
ditto "$bin/PicShot_PicShotFormulaRenderHelper.bundle" \
      "$app/Contents/Resources/PicShot_PicShotFormulaRenderHelper.bundle"
codesign --force --sign - --identifier local.picshot.formularenderhelper \
  "$app/Contents/Helpers/PicShotFormulaRenderHelper"
# Then the existing final app deep-sign + strict verify steps.
```

For Developer ID distribution, use the same signing identity as the enclosing
app instead of ad-hoc signing. Do not omit the SwiftPM resource bundle. In packaged mode the helper obtains its
actual executable path with `proc_pidpath`, requires `Contents/Helpers`, and loads
only the executable-relative `../Resources/PicShot_PicShotFormulaRenderHelper.bundle`.
The bundle and runtime directory must remain inside that validated nonsymlinked
path. `Bundle.main` is never used to identify the parent app. `Bundle.module` and
its generated absolute `.build` fallback are used only outside the packaged app
layout; missing installed resources fail closed and never try that fallback. Do not
copy `node_modules`, npm, esbuild or Node into the app.

Other entry points can retain/show `FormulaRenderController(latex:)` for manually
entered formulas. Its `onClose` callback allows the owner to release it. The
controller cancels and clears render data on closing. Neither opening this window
nor rendering requires any model download.

## Runtime provenance, build and attribution

- Engine: `mathjax-full` **3.2.2** (the final 3.x layout model is pinned deliberately;
  upgrading to 4.x requires an explicit font/runtime review, not a semver range)
- Official source: <https://github.com/mathjax/MathJax-src/tree/3.2.2>
- Exact published source revision: `ad8f5c21cb810236551da8c6512ba733e67357ee`
- Official tarball: <https://registry.npmjs.org/mathjax-full/-/mathjax-full-3.2.2.tgz>
- Registry integrity:
  `sha512-+LfG9Fik+OuI8SLwsiR02IVdjcnRCy5MufYLi0C3TdMT56L/pjB0alMVGgoWJF8pN9Rc7FESycZB9BMNWIid5w==`
- License: Apache-2.0; unmodified upstream license, copyright notice and adapter
  modification notice are bundled with the runtime
- `scripts/FormulaRender/package-lock.json` locks the complete build dependency
  tree, including `esbuild` 0.25.12. Only MathJax source and our adapter are bundled;
  the build refuses unexpected runtime dependencies
- Generated asset `FormulaRenderRuntime.js` is checked in and below 2 MiB. A normal
  release build requires **no npm or network access**. `FormulaRenderRuntime.sha256`
  and `FormulaRenderRuntime-provenance.json` accompany the signed resource

To regenerate using a build machine with Node 18+:

```sh
cd scripts/FormulaRender
npm ci --ignore-scripts --no-audit --no-fund
npm run build
npm test
```

No npm install scripts execute. Official esbuild platform binaries are selected
from the locked npm packages and used only during generation. Retain and review
all generated changes, digest and licenses together.

Primary API references:
- TeX configuration, restricted packages, `maxMacros`, `maxBuffer`, fail-on-error:
  <https://docs.mathjax.org/en/v3.2/options/input/tex.html>
- SVG glyph paths / `fontCache: 'none'`:
  <https://docs.mathjax.org/en/v3.2/options/output/svg.html>
- Semantic MathML visitor source:
  <https://github.com/mathjax/MathJax-src/blob/3.2.2/ts/core/MmlTree/SerializedMmlVisitor.ts>
- TeX font outline license/source:
  <https://github.com/mathjax/MathJax-src/blob/3.2.2/ts/output/svg/fonts/tex/normal.ts>
- JavaScriptCore isolation API:
  <https://developer.apple.com/documentation/javascriptcore/jscontext>

## Verification

Linux build-time verification: 17 tests pass against the actual checked-in bundle,
including fractions, superscripts, matrices, roots, sums, syntax errors, nonexecuted
JS-looking input, resource/HTML/custom-macro injection rejection, missing host IO
APIs, macro/input/pixel bounds, independent sequential equations, stroke-only boxes,
clipped stretched accents, phantom glyph suppression and transparency/size metadata.
These are genuine MathJax rendering checks, not mocked success fixtures.

Mac tests supplied but must be run by the integrating owner:

```sh
swift test --filter FormulaRender
```

Packaging automatically runs this relocation check; it can also be run manually
with no concurrent builds or tests in that build directory:

```sh
python3 scripts/FormulaRender-verify-packaged-runtime.py \
  --app "$app" --build-bundle "$bin/PicShot_PicShotFormulaRenderHelper.bundle"
```

It copies the app to an unrelated temporary location, temporarily renames the
original build resource bundle, launches the copied helper with `/` as its working
directory, verifies real fraction output, and verifies missing installed resources
fail closed. A `finally` block restores the build bundle, including on normal
SIGINT/SIGTERM interruption. Do not kill the verifier with SIGKILL while resources
are temporarily hidden. This check prevents a CI machine's absolute `.build`
fallback from masking a broken release package. The original packaged app remains
unchanged. Native tests also cover unavailable development fallbacks, symlinked
bundles and invalid executable layout.

They cover actual JavaScriptCore execution, PNG decoded dimensions/nonempty glyph
pixels, PDF page geometry, transparency, renderer digest failure, native path
commands/limits, helper cancellation before/during execution, stale-result removal,
option invalidation and window-close cancellation. This Linux environment has no
Swift toolchain or AppKit, so native compilation, real UI appearance and packaged
helper launch/signature checks remain unverified here.

Before release on macOS 14+, open a recognized fraction, a 2×2 matrix and a long
accent; inspect the native preview; copy and reopen each format; verify SVG/PDF
vector appearance; edit while rendering; cancel; close/reopen; try two windows at
once; and verify no PicShotFormulaRenderHelper process persists after jobs finish.

## Managed LaTeX pins (PIN-07 candidate, native gates pending)

The window/menu-bar “LaTeX 公式贴图…” action opens this same formula editor,
optionally seeded from a bounded text clipboard. “贴到屏幕” creates a managed
formula pin. The recognition window's current editable source reaches the same
button through “公式预览、贴图与导出…”. Recognition models remain optional and
are never downloaded by creating, restoring, editing or exporting a pin.

The pin itself is an image-first native floating panel. Its context menu edits
source/options in an owned compact popover, copies original LaTeX, copies or saves
PNG/SVG/MathML/PDF, and undoes a committed edit. The previous valid image and source
stay committed during editing, syntax errors, cancellation, renderer failure or a
failed storage transaction. Invalid drafts remain editable while the editor stays
open. Cancel/dismiss discards the uncommitted draft. Ten source/options undo entries
are retained while the pin is live; they are discarded on hide/close. Undo rerenders
on explicit request and does not mutate history if rendering/storage fails.

Persistence uses the existing schema-2 typed document plus its original=current
PNG. The formula document is still below the existing 1 MiB cap, with an 8 KiB
UTF-8 source bound. The PNG is the real renderer raster, bounded to 4096 per axis
and 4,194,304 pixels, and is counted once in the ordinary shared 100-million-pixel
and 512 MiB disk quotas. Edits write fresh source and raster assets, then atomically
commit their references before deleting the old pair. Failed edits remove only
the new assets. No arrays of render results or vector caches are persisted.

Restoration reads native PNG plus inert source/options only; no renderer, external
file, web resource, recognition model or vector document executes automatically.
SVG/MathML/PDF exports are freshly generated from the committed source through the
same signed offline helper on explicit request. PNG and LaTeX copy work directly
from the restored content. Format regeneration errors are shown in the inline
editor. Rendering is cancellable, shares the existing single-helper gate, and is
cancelled on close, hide, group switches and editor dismissal. Source typing and
paste are bounded before insertion; the native editor has no unbounded text undo
stack. Resizing/moving the panel never rerenders the formula.

Still missing: multi-formula/page recognition, broad recognition accuracy evidence,
Office OMML, Typst, AsciiMath, arbitrary TeX packages/fonts and cross-application
editable-formula round-trip acceptance. Source undo is live-session-only. This is
candidate code, not a native/macOS or memory-leak pass.

Native acceptance entry (installed signed app, no capture permission): set
`PICSHOT_SMOKE_REPORT` to an isolated report JSON path and
`PICSHOT_LATEX_PIN_VERIFY=1`. The fixture exercises the actual bundled renderer,
native source control, update/copy/options/error/undo/cancel, atomic saved content,
new-store restore, stale close, twelve hide/archive/reopen cycles and exports. It
writes actual `latex-managed-pin.png` and `latex-inline-editor.png` view snapshots,
plus `latex-managed-pin.json` and exported formula files. Do not manufacture these
images on Linux. Run the full native Swift suite as well, including
`LaTeXPinTests`, `PinLaTeXContentTests` and `FormulaRenderContractTests`.

### Managed-pin resource and chooser follow-on (native execution pending)

The LaTeX fixture separates actual renderer/edit/export/snapshot checks from the
lifecycle resource phase. Functional strong references to the old pin, source model,
editor and PNG/PDF/SVG/MathML result leave scope before measurement. Two explicit
warm-ups precede twelve measured hide/show/close/reopen cycles. The baseline and
all twelve endpoints have one restored pin; final cleanup has zero. The original
renderer requests/source characters are unchanged. No renderer is explicitly
requested by the lifecycle loop, and restored models must not be working/saving.

Existing 50 ms `GIFResourceMemorySampler` statistics cover main-process RSS and
physical footprint continuously through measured transitions, asset-hash validation
and final cleanup. Both fields at every boundary, real timer ticks, peaks and
consistent successful counts with zero failed samples are required. Missing data
fails rather than becoming zero. Per-cycle scalars, last-three one-cycle increments,
comparable growth and separate cleanup deltas are retained. No resource threshold,
plateau verdict or zero-leak conclusion is introduced. Helper process memory and
whole-system/WindowServer/GPU totals are not established by these parent readings.

Each hide and close probes actual live controller/content/source-model references:
four warm-up probes, twenty-four measured probes and one final-teardown probe must
release. Editors are tested in functional setup, not claimed as opened in each
resource cycle. Source/raster filenames, byte counts and SHA-256 must remain equal;
that establishes unchanged contents, not an independent proof against same-byte
rewrites or uninstrumented activity. Desktop visibility uses an isolated service.

`formulaSaveChooserGeometry` records real NSSavePanel frame, visibility and owned
sheet observations from a compact formula pin near a screen edge. It requires
complete on-screen placement, an unchanged pin frame, and cancellation with no
remaining sheet. It captures no remote-panel pixels and supplies no fabricated
screenshot. Native failure must be investigated without changing production code
or widening geometry requirements just to pass this fixture.
