# Native still-image export

## Implemented scope

The shared `ImageExportController.present(image:from:suggestedName:sourceURL:onSaved:)` sheet provides PNG, JPEG, TIFF, BMP, PDF, WebP and AVIF. The first five retain their original native path; WebP/AVIF require the separately signed bundled codec helper. JPEG quality is configurable from 1–100%, default 94%. PNG/TIFF preserve alpha; JPEG/BMP explicitly composite transparency on white. PDF pages have a white paper background.

The editor freezes its already-flattened/redacted image before opening the sheet. Pin/history/original routes can use the same API, passing the intended raster and an optional original URL. No source annotation objects, hidden layers, OCR text or file metadata are serialized. Changing the editor after snapshot creation cannot change an export in progress.

The preview is decoded from a completed native encoding. Its displayed byte count is the exact encoded data length, not an estimate. Save publishes those same bytes without re-encoding. Thumbnails are bounded previews, not full-resolution proof of every pixel; output tests separately reopen full rasters and check pixels, alpha and dimensions.

### PDF

- Original-image-sized single page remains the compatibility default
- A4 and Letter, portrait/landscape, equal margins of 0/12/24/36/54/72 points
- Vertical pagination fits image width; horizontal pagination fits image height
- Source boundaries advance in integral rows or columns and cover each source pixel exactly once
- The last partial page is top/left aligned at the same scale and is not stretched
- Paper previews come from `CGPDFDocument` reopening encoded PDF bytes, with actual page navigation

This is raster PDF export. It does not promise searchable OCR, vectors, PDF/A or accessibility tagging.

### Save-new-copy policy

The destination picker is explicitly titled “保存新副本” and explains that existing files cannot be overwritten. Its validation rejects occupied destinations before successful completion; final exclusive publication independently rechecks races. Original URLs, ordinary existing files and symlinks are protected. Replace-in-place is deliberately not implemented in this batch, even if an OS filename workflow presents an intermediate replacement question.

A private mode-0600 staging file is written in the destination directory, synchronized, then published with exclusive `link(2)`. The link never replaces an existing path. Staging files are removed on success, error and cancellation. A lock orders final publication versus cancellation: cancellation before commit prevents publication; a file committed before cancellation is already a complete successful export. Unsupported filesystems or directory permissions produce an error rather than unsafe overwrite fallback.

## Bounds and lifecycle

- Source: 100,000,000 pixels maximum, checked before snapshot allocation
- Encoded output: 128 MiB maximum, enforced by the ImageIO/PDF data consumer while receiving output
- PDF: 200 pages maximum, checked before allocating the page list
- Preview: 1024 maximum dimension and 4 MiB decoded bytes/page
- Cache: first page plus at most one additional PDF page, 8 MiB retained decoded preview budget
- Sessions: at most two production sheets, at most one per parent window
- In-process encoding uses one serial ImageIO/PDF queue; an isolated GIF/WebP/AVIF child has a separate shared lease and may overlap that queue. PNG source staging also happens in the parent. This is not one global encoder or a total-RSS bound
- Format changes cancel stale work and clear queued inputs. Bundled admission waits cancellably for at most 300 seconds for the previous child cleanup or another sheet/GIF job, with visible waiting text and Retry after failure. Closed/stale results cannot re-enable Save
- Closing or cancelling a sheet or its parent cancels pending work and suppresses stale completion

Native codecs may retain their own internal scratch buffers. These bounds do not establish a process RSS ceiling, absence of leaks or preemptible cancellation inside a native codec call. Cancellation is checked before/after native calls and at consumer writes, so a native call already executing may finish before releasing its resources. No partial file can be published by that cancelled job.

## Verification and installed evidence

Run `swift test --filter ImageExport` on macOS. Existing `ImageEditorTests.testRasterExportsCanBeReopenedWithoutSourceLayers` continues exercising legacy PNG/JPEG/TIFF/PDF indices.

New coverage includes integer contiguous row/column coverage, last-page boundaries, media boxes/margins, complete PDF pixel seams, independently decoded raster type/dimensions/alpha, actual JPEG quality changes, native control actions, deterministic in-flight stale/close completion barriers, cancelled pending-input release, mutable-provider snapshot isolation, page navigation, exact saved bytes, source/destination protection, racing collisions, cancellation immediately before publication, and source/output/preview/job caps.

The installed launcher can call:

```swift
try await ImageExportPreviewFixture.verify(evidenceDirectory: directory)
// Early UI-only evidence may skip the repeated resource workload explicitly:
try await ImageExportPreviewFixture.verify(evidenceDirectory: directory, includeResourceCycles: false)
```

Full installed smoke also writes `image-export-resource.json`: one warm-up plus four measured 1440×900 cycles, each exercising PNG/JPEG/BMP/PDF encoding, actual decoded preview, save, close and deletion serially. The existing Mach sampler measures main-process RSS and physical footprint every 50 ms plus explicit boundaries. Each cycle records sampled peaks/counts, three settled observations, growth from post-warm-up baseline, actual weak-controller release, active sessions, queued/running jobs and temporary-file cleanup. Only one resource-loop output exists at a time. The dedicated unit profile is separately labeled 160×100 with two measured cycles. No new memory threshold is introduced and the report deliberately calls these observations, not proof of a plateau or zero leaks. Native synchronous calls remain subject to the installed launcher's outer timeout.

It writes `image-export-preview.json`, two native export-sheet screenshots, actual JPEG/BMP files, a multipage PDF, SHA-256 values and the runtime codec probe. Screenshots are fixed 1× cached native content composited over the effective window background; this evidence-only compositing does not alter exported pixels. Visual controllers, source rasters and encoded artifacts leave their helper scope, and weak controller release plus queue drain are checked before resource sampling. Each run saves production outputs into a fresh private temporary directory, verifies them and the no-overwrite collision, then atomically refreshes only the exact fixture evidence filenames; reusing an evidence directory does not weaken production collision protection. The fixture is synthetic and does not capture the live desktop, request TCC permissions, access user files or use the network. Exact PDF pixels/seams are tested in unit tests, while the installed fixture tests the real controls/worker/publication route. Native execution is required; Linux source inspection is not a passing macOS result.

## WebP / AVIF: bundled isolated codecs (0.8 source)

The compact 620×550 sheet exposes genuine WebP/AVIF quality, lossless, preserve-alpha and alpha-quality controls. Lossless disables lossy quality sliders; disabling alpha composites white. The source is the frozen, flattened editor snapshot. These formats admit at most 16,000,000 pixels (8192 maximum dimension), an 80,000,000-byte staged PNG, and 128 MiB of encoded output. The helper independently decodes the actual encoded bytes and returns a bounded PNG preview (1024px / 4 MiB, with a 1000px fallback for incompressible PNG). The parent verifies the encoded SHA-256, strict file identities, container magic, PNG type/dimensions/decoded size and aspect ratio before offering save. Saving exclusively publishes the same bytes.

Production resolves only `Contents/Helpers/PicShotCodecHelper` under the current signed app and validates both the app's nested code seal and the helper. No environment-selected executable or ImageIO writer fallback is permitted. One process-wide native export lease is shared with GIF and animated WebP. The lease remains held until exit and owned job cleanup are confirmed, including cancellation/error paths. Each child receives a strict path-free JSON request, private 0700 job, fixed 0600 filenames, scrubbed environment, bounded stdout/stderr, a 300-second deadline, and sampled 1 GiB RSS abort threshold. Cancellation requests are followed by terminate then kill. The sampled threshold is not a hard kernel memory quota; in particular AVIF can allocate a final buffer internally before the next observation. This source does not by itself establish native build, performance, memory plateau or runtime acceptance.

`CodecExportResourceFixture.verify(evidenceDirectory:)` writes `codec-export-resource.json`. It runs three genuine lossless encodes per format, separate alpha-off and low/high lossy-quality checks, independent ImageIO full-image decode and pixel/alpha comparisons, same-byte save/collision protection, real progress-triggered cancellation, child-exit/cleanup checks, and parent/child RSS/footprint samples. Missing codecs/readers or evidence fail explicitly. `CodecExportProcessTests` also covers signed path/tamper rejection, malformed protocol bounds, forced timeout/RSS termination and shared GIF admission. The original `ImageExportResourceFixture` workload remains separate and unchanged. Run both helper/core and parent/macOS tests against the packaged official-codec build; Linux source checks cannot pass these native gates.

`CodecExportUIPreviewFixture.verify(evidenceDirectory:)` separately exercises the real signed-helper controls on an original 160×112 fixture. It writes light WebP and dark AVIF cached native-window snapshots, real encoded outputs, compact regular/small-desktop layout checks, byte-derived preview comparisons and exact-byte save evidence in `codec-export-ui.json`. Screenshots resolve the window background in its effective appearance and never capture the live desktop. Native execution is still required before claiming these visual gates passed.

### Native ImageIO capability remains separate

Native writer availability does not enable these UI formats; bundled helper verification and native ImageIO probe results are separate fields. The following earlier native-only investigation remains relevant to the absence of a universal native writer guarantee.

## Historical native-only capability investigation

Import or browser display support is not export support. The implementation does not offer dummy WebP/AVIF bytes, silently substitute another format or install a codec at runtime. The runtime `ImageExportCapabilityProbe.report()` separately records source and destination listings and, only when a writer is listed, attempts an actual synthetic encoding. It verifies container magic, independently detected type, image count, dimensions, decoded pixels and alpha separately, along with macOS version/build and architecture. A success establishes only that runtime/configuration's capability. The probe alone does not add either format to the product's supported export UI.

Read-only official research on 2026-10-06 found no Apple guarantee of native ImageIO WebP/AVIF encoding across macOS 14/15. This is an evidence gap, not a claim that every Apple runtime lacks either encoder. Native macOS 14 and 15 results must be attached before making runtime-specific capability claims.

Primary Apple references:

- [Image I/O basics: read and write identifier lists are distinct](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/ImageIOGuide/imageio_basics/ikpg_basics.html)
- [CGImageDestination writing API](https://developer.apple.com/documentation/imageio/cgimagedestination)
- [Safari 14 WebP display support](https://developer.apple.com/documentation/safari-release-notes/safari-14-release-notes)
- [WebKit Safari 16.4 AVIF support](https://webkit.org/blog/13966/webkit-features-in-safari-16-4/)
- [WebKit AVIF system-framework loading discussion](https://bugs.webkit.org/show_bug.cgi?id=277578)

### Official codec provenance recorded before integration

These versions were originally researched read-only and are now the explicitly approved 0.8 native codec batch. The build manifest and packaging verification own exact source hashes, linked dependencies and binary-distribution notices; the parent export/UI implementation performs no dependency acquisition or installation.

| Purpose | Official version / immutable commit | License and notices |
| --- | --- | --- |
| WebP encoder+decoder | [libwebp v1.6.0](https://chromium.googlesource.com/webm/libwebp/+/refs/tags/v1.6.0), `4fa21912338357f89e4fd51cf2368325b59e9bd9` | [Pinned BSD-3-Clause COPYING](https://raw.githubusercontent.com/webmproject/libwebp/4fa21912338357f89e4fd51cf2368325b59e9bd9/COPYING), [pinned PATENTS](https://raw.githubusercontent.com/webmproject/libwebp/4fa21912338357f89e4fd51cf2368325b59e9bd9/PATENTS) |
| AVIF container/API | [libavif v1.4.2](https://github.com/AOMediaCodec/libavif/releases/tag/v1.4.2), `c5240fc79fe5c2407e10afd35f5505ef6333ea49` | [Pinned complete LICENSE](https://raw.githubusercontent.com/AOMediaCodec/libavif/c5240fc79fe5c2407e10afd35f5505ef6333ea49/LICENSE): BSD-2-Clause core plus file-specific notices |
| AV1 encoder+decoder backend | [libaom v3.14.1](https://aomedia.googlesource.com/aom/+/refs/tags/v3.14.1), `03087864cf4bea6abb0d28f95cf7843511413d8f` | BSD-2-Clause / AOM Patent License 1.0 according to upstream current [LICENSE](https://aomedia.googlesource.com/aom/+/refs/heads/main/LICENSE) and [PATENTS](https://aomedia.googlesource.com/aom/+/refs/heads/main/PATENTS). The read-only web tool could not retrieve release-commit copies; verify those exact copies before vendoring |

libavif requires an AV1 backend. Its [v1.4.2 README](https://raw.githubusercontent.com/AOMediaCodec/libavif/v1.4.2/README.md) identifies libaom as encoding+decoding; dav1d/libgav1 are decoding-only and cannot establish AVIF export. Its [v1.4.2 LocalAom.cmake](https://raw.githubusercontent.com/AOMediaCodec/libavif/v1.4.2/cmake/Modules/LocalAom.cmake) selects libaom v3.14.1. These license observations are not a security certification or a completed distribution-license audit.

Deterministic Retry tests use the production retry loop with explicitly labeled delayed-cleanup doubles; genuine signed-helper UI evidence separately changes format/quality from real progress, under a bounded fixture dispatch barrier. No new native pass is inferred from these source changes.
