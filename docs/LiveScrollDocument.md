# Live scroll document integration contract

`LiveScrollDocument` is a new actor in the AppKit target. It has no dependency on the legacy stitching controller, source-image store, or editor. The matcher is responsible for verifying motion and guarding changed/repeated content before calling it.

## Coordinates and creation

Create it off the main actor using:

```swift
let document = try await LiveScrollDocument.create(
    firstImage: firstImage,
    scrollingContentRect: fixedContentRectangle,
    axis: .vertical,                // .horizontal is also supported
    viewportCrop: nil,             // explicit crop only when the caller requests one
    generation: sessionGeneration
)
```

Rectangles are integer pixel coordinates in the original captured image, with a top-left origin. The scrolling rectangle must span the entire cross-axis of the viewport crop. Without an explicit viewport crop, it must span the entire image width for vertical scrolling or height for horizontal scrolling. No sidebar is removed implicitly. All future candidates must have the same original image dimensions; content/crop bounds remain fixed for the session.

The initial body occupies document interval `0..<viewportLength`. An absolute `viewportOffset` moves that interval along the document. Fixed header/left-edge pixels come from the first image. The footer/right edge comes from the latest candidate that durably extends coverage. Revisited body content and the initial leading edge are immutable. Export order is always initial leading edge, ordered full body union, latest committed trailing edge.

The owner should retain its first original image until content bounds are confidently inferred and initial creation plus the first verified append have succeeded. The document does not retain any full source CGImage. On failure the owner can still display/export that original capture.

## Durable and observed frames

```swift
let update = try await document.append(
    image: candidate, viewportOffset: verifiedAbsoluteOffset,
    generation: sessionGeneration
)
```

Any nonzero amount of new coverage can be committed, including the final small remainder. The controller may wait for 64–128 pixels of new coverage between durable commits. It should not wait past a full viewport: each durable candidate must overlap or touch the existing union. A disconnected candidate is rejected rather than inventing missing pixels.

`Update.addedPixels` is an axis length, not area. Zero is a revisit and causes no new file, footer replacement, or source-count increment. Every extending candidate consumes one durable source slot regardless of strip direction or observed-frame count. The initial candidate counts as one source.

`updateViewport(offset:generation:)` changes only tracking metadata, with no source write/count change. It can describe pending verified movement outside committed coverage, provided the candidate remains continuous and within output limits.

## Incremental display

`preview()` returns the durable image with its most recently tracked viewport, clipped to durable coverage. To display verified sub-threshold movement immediately, use:

```swift
let preview = try await document.preview(
    image: latestCandidate, viewportOffset: verifiedAbsoluteOffset,
    generation: sessionGeneration
)
```

The transient overload composes cached committed tiles with only the candidate's newly exposed leading/trailing body strip and current footer. It never writes files or modifies durable coverage, source count, viewport metadata, or stored samples. `isTransient` distinguishes it. `outputWidth` and `outputHeight` describe the displayed full-resolution extent. `snapshot` always describes durable state, even when transient display extends it.

`viewportFraction` is a normalized top-left CGRect of the visible scrolling body, excluding the fixed edges. It has full cross-axis extent. It is clipped to displayed coverage.

Preview output has at most 1,024 pixels per edge and 1,048,576 pixels total. Retained preview tiles have a hard 4 MiB aggregate bound. Preview scale has at most 512 cross-axis pixels and 1,024 along-axis pixels. With at most 100 body strips and two fixed-edge samples, retained samples actually stay below 2.31 MiB even with per-tile rounding. Downsampling touches only these cached small tiles, never historical files. Transient output and temporary resampling add a bounded number of small bitmaps; no full-document preview raster is allocated.

## Snapshot fields

| Field | Meaning |
| --- | --- |
| `width`, `height` | Durable full-resolution output, including the fixed edges |
| `lowerBound`, `upperBound` | Durable body interval in original document coordinates |
| `viewportOffset`, `viewportLength` | Most recently committed/tracked body viewport |
| `sourceCount` | Durable extending candidates, including the first |
| `diskBytes` | All currently owned/reserved strip bytes, including any failed-to-unlink retired file |
| `generation` | Immutable owner-supplied session generation |
| `stripCount` | Durable body strips, excluding fixed edges |
| `cachedPreviewBytes` | Retained sample bitmap storage |
| `sourceReadCount` | Source-file opens for explicit final rendering; appends/previews do not read them |

Default safeguards are 60,000,000 output pixels, 32,768 pixels per edge, 512 MiB disk use, and 100 durable sources. Limits can be tightened but not raised. Disk checks include the temporary old/new footer overlap during a transaction. Output pixels use canonical premultiplied RGBA in sRGB. Sources are raw cropped strip files; no full-frame PNG encoding occurs.

## Export and cancellation

`try await document.render()` returns the full current durable CGImage. Call it only for explicit completion/export. It allocates one output bitmap and streams raw strips in chunks of at most 1 MiB. It does not reconstruct or decode source frames. Horizontal output copies bounded row batches into their document x positions. Export blocks other actor operations while reading; the cancellation token can still interrupt it.

`document.cancel()` is nonisolated and immediately invalidates the session, including running writes/export. `await document.close()` also drops all sample references and removes only files created by this instance. Close is idempotent; unrelated files and parent directories are preserved. ARC cleanup provides the same file ownership boundary if the owner drops the document without closing it.

Each append stages unique `.partial` files, synchronizes them, and atomically renames them to immutable `.rgba` files before committing metadata. It checks generation and task/session cancellation at entry, during I/O, and immediately before the small locked commit. Rejection removes staged files and preserves the prior body, edges, viewport, and source count. An unlink failure leaves the file owned and conservatively accounted for, rather than losing track of disk usage. Task cancellation cancels only that operation; explicit document cancellation permanently invalidates the instance.

## Validation boundary

`LiveScrollDocumentTests` covers both scroll axes, exact reverse union pixels, initial header/latest committed footer semantics, read-free cached/transient preview, durable-source accounting, small final commits, geometry/generation/gap/overflow rejection, output/peak-disk limits, cancellation at the commit boundary, task cancellation, explicit crop, failed initialization cleanup, ownership-safe close, and corrupted strip rejection.

The development executor for this change is Linux without Swift/AppKit. Native compilation and these tests must run in the project's macOS qualification environment before integration is accepted. The 300 ms display goal and actual process peak/cold memory require native workload measurements; the source bounds above are not measured latency or RSS claims.
