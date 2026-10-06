# Native still-image export

## Implemented scope

The shared `ImageExportController.present(image:from:suggestedName:sourceURL:onSaved:)` sheet provides PNG, JPEG, TIFF, BMP and PDF. JPEG quality is configurable from 1–100%, default 94%. PNG/TIFF preserve alpha; JPEG/BMP explicitly composite transparency on white. PDF pages have a white paper background.

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
- Encoding: one shared serial worker; format/quality changes debounce and cancel obsolete operations. Queued work owns a lock-protected input holder, cleared immediately on cancellation, so cancelled queue entries do not retain closed-session snapshots or artifacts
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

## WebP / AVIF: explicit unimplemented gap

Import or browser display support is not export support. The UI does not offer dummy WebP/AVIF format choices, silently substitute another format or install a codec. The runtime `ImageExportCapabilityProbe.report()` separately records source and destination listings and, only when a writer is listed, attempts an actual synthetic encoding. It verifies container magic, independently detected type, image count, dimensions, decoded pixels and alpha separately, along with macOS version/build and architecture. A success establishes only that runtime/configuration's capability. The probe alone does not add either format to the product's supported export UI.

Read-only official research on 2026-10-06 found no Apple guarantee of native ImageIO WebP/AVIF encoding across macOS 14/15. This is an evidence gap, not a claim that every Apple runtime lacks either encoder. Native macOS 14 and 15 results must be attached before making runtime-specific capability claims.

Primary Apple references:

- [Image I/O basics: read and write identifier lists are distinct](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/ImageIOGuide/imageio_basics/ikpg_basics.html)
- [CGImageDestination writing API](https://developer.apple.com/documentation/imageio/cgimagedestination)
- [Safari 14 WebP display support](https://developer.apple.com/documentation/safari-release-notes/safari-14-release-notes)
- [WebKit Safari 16.4 AVIF support](https://webkit.org/blog/13966/webkit-features-in-safari-16-4/)
- [WebKit AVIF system-framework loading discussion](https://bugs.webkit.org/show_bug.cgi?id=277578)

### Licensed codec options, not installed

These are upstream provenance candidates for a separately approved dependency batch. They were researched read-only. No download, install, execution or package change was made for them. Pin exact source hashes and audit all actual linked dependencies and binary-distribution notices before integration.

| Purpose | Official version / immutable commit | License and notices |
| --- | --- | --- |
| WebP encoder+decoder | [libwebp v1.6.0](https://chromium.googlesource.com/webm/libwebp/+/refs/tags/v1.6.0), `4fa21912338357f89e4fd51cf2368325b59e9bd9` | [Pinned BSD-3-Clause COPYING](https://raw.githubusercontent.com/webmproject/libwebp/4fa21912338357f89e4fd51cf2368325b59e9bd9/COPYING), [pinned PATENTS](https://raw.githubusercontent.com/webmproject/libwebp/4fa21912338357f89e4fd51cf2368325b59e9bd9/PATENTS) |
| AVIF container/API | [libavif v1.4.2](https://github.com/AOMediaCodec/libavif/releases/tag/v1.4.2), `c5240fc79fe5c2407e10afd35f5505ef6333ea49` | [Pinned complete LICENSE](https://raw.githubusercontent.com/AOMediaCodec/libavif/c5240fc79fe5c2407e10afd35f5505ef6333ea49/LICENSE): BSD-2-Clause core plus file-specific notices |
| AV1 encoder+decoder backend | [libaom v3.14.1](https://aomedia.googlesource.com/aom/+/refs/tags/v3.14.1), `03087864cf4bea6abb0d28f95cf7843511413d8f` | BSD-2-Clause / AOM Patent License 1.0 according to upstream current [LICENSE](https://aomedia.googlesource.com/aom/+/refs/heads/main/LICENSE) and [PATENTS](https://aomedia.googlesource.com/aom/+/refs/heads/main/PATENTS). The read-only web tool could not retrieve release-commit copies; verify those exact copies before vendoring |

libavif requires an AV1 backend. Its [v1.4.2 README](https://raw.githubusercontent.com/AOMediaCodec/libavif/v1.4.2/README.md) identifies libaom as encoding+decoding; dav1d/libgav1 are decoding-only and cannot establish AVIF export. Its [v1.4.2 LocalAom.cmake](https://raw.githubusercontent.com/AOMediaCodec/libavif/v1.4.2/cmake/Modules/LocalAom.cmake) selects libaom v3.14.1. These license observations are not a security certification or a completed distribution-license audit.
