import AppKit
import CoreGraphics
import ImageIO
import Foundation
import XCTest
@testable import PicShot

/// The oracle is a new CGContext drawing the ORIGINAL image exactly once.
/// Read candidate provider bytes directly: redrawing the candidate as an oracle
/// would hide extra color/alpha conversion and loss of low-alpha samples.
final class DrawingRasterTests: XCTestCase {
    private let intents: [CGColorRenderingIntent] = [
        .defaultIntent, .absoluteColorimetric, .relativeColorimetric, .perceptual, .saturation
    ]
    private let rgbaLayouts: [CGImageAlphaInfo] = [
        .first, .last, .premultipliedFirst, .premultipliedLast, .noneSkipFirst, .noneSkipLast
    ]

    func testAllEligibleAlphaLayoutsByteOrdersPaddedRowsAndIntentsMatchFreshDrawExactly() throws {
        for alpha in rgbaLayouts + [.none] {
            let orders: [CGBitmapInfo] = alpha == .none ? [.byteOrderDefault]
                : [.byteOrderDefault, .byteOrder32Big, .byteOrder32Little]
            for order in orders {
                for intent in intents {
                    for interpolate in [false, true] {
                        let known = try fixture(depth: 8, alpha: alpha, order: order,
                            color: sRGB(), intent: intent, interpolate: interpolate)
                        let expected = try referenceBytes(known.image)
                        let config = DrawingRasterConfiguration(strategy: .ownedSRGB8)
                        let prepared = try DrawingRaster.prepare(known.image, configuration: config)
                        XCTAssertFalse(prepared.image === known.image)
                        try assertSRGB8(prepared.image, equals: expected)
                        let context = try bitmap(width: known.image.width, height: known.image.height)
                        _ = try DrawingRaster.seedFreshSRGB8Context(context, from: known.image, configuration: config)
                        XCTAssertEqual(try bytes(context), expected)
                        try assertSourceUnchanged(known)
                    }
                }
            }
        }
    }

    func testRendererAndExportSnapshotMatchIndependentFreshReferenceBytes() throws {
        // Alpha 0, 1, 2, 127, 254, 255 appear in each row. Padded source rows
        // differ in color, making row-stride and vertical-flip errors visible.
        for alpha in rgbaLayouts + [.none] {
            let orders: [CGBitmapInfo] = alpha == .none ? [.byteOrderDefault]
                : [.byteOrderDefault, .byteOrder32Big, .byteOrder32Little]
            for order in orders {
                let known = try fixture(depth: 8, alpha: alpha, order: order, color: sRGB())
                let expected = try referenceBytes(known.image)
                for strategy in [DrawingRasterStrategy.reference, .ownedSRGB8] {
                    let config = DrawingRasterConfiguration(strategy: strategy)
                    let rendered = try XCTUnwrap(ImageEditorRenderer.render(image: known.image,
                        annotations: [], drawingRaster: config))
                    try assertSRGB8(rendered, equals: expected)
                    let snapshot = try ImageExportSnapshot(image: known.image, drawingRaster: config)
                    try assertSRGB8(snapshot.image, equals: expected)
                    XCTAssertFalse(snapshot.image === known.image)
                    try assertSourceUnchanged(known)
                }
            }
        }
    }

    func testSixteenBitAndNonSRGBOriginalsRemainExactWhileDrawingUsesReferenceFallback() throws {
        let colors = [try sRGB(), try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3)),
                      try XCTUnwrap(CGColorSpace(name: CGColorSpace.linearSRGB)), CGColorSpaceCreateDeviceRGB()]
        for color in colors {
            for depth in [8, 16] where depth == 16 || color.name != CGColorSpace.sRGB {
                for intent in intents {
                    let known = try fixture(depth: depth, alpha: .last,
                        order: depth == 8 ? .byteOrder32Big : .byteOrder16Big,
                        color: color, intent: intent)
                    let config = DrawingRasterConfiguration(strategy: .ownedSRGB8)
                    let prepared = try DrawingRaster.prepare(known.image, configuration: config)
                    XCTAssertTrue(prepared.image === known.image, "Unsupported source must retain its original representation")
                    let expected = try referenceBytes(known.image)
                    let context = try bitmap(width: known.image.width, height: known.image.height)
                    _ = try DrawingRaster.seedFreshSRGB8Context(context, from: known.image, configuration: config)
                    XCTAssertEqual(try bytes(context), expected)
                    let rendered = try XCTUnwrap(ImageEditorRenderer.render(image: known.image,
                        annotations: [], drawingRaster: config))
                    try assertSRGB8(rendered, equals: expected)
                    let snapshot = try ImageExportSnapshot(image: known.image, drawingRaster: config)
                    try assertSRGB8(snapshot.image, equals: expected)
                    try assertSourceUnchanged(known)
                }
            }
        }
    }

    func testProcessSelectionDefaultsToOwnedAndExplicitOverridesRequireSmokeReport() throws {
        XCTAssertEqual(DrawingRasterStrategy.productionDefault, .ownedSRGB8)
        for environment in [[:], ["PICSHOT_SMOKE_TEST": "1"], ["UNRELATED_SETTING": "anything"]] {
            XCTAssertEqual(try DrawingRasterConfiguration.selection(environment: environment), .ownedSRGB8)
            XCTAssertEqual(try DrawingRasterConfiguration(environment: environment).selectedStrategy(), .ownedSRGB8)
        }
        for strategy in DrawingRasterStrategy.allCases {
            let environment = smoke(strategy.rawValue)
            XCTAssertEqual(try DrawingRasterConfiguration.selection(environment: environment), strategy)
            XCTAssertEqual(try DrawingRasterConfiguration(environment: environment).selectedStrategy(), strategy)
            for key in ["PICSHOT_SMOKE_TEST", "PICSHOT_SMOKE_REPORT"] {
                var invalid = environment; invalid.removeValue(forKey: key)
                XCTAssertThrowsError(try DrawingRasterConfiguration(environment: invalid).selectedStrategy())
            }
        }
    }

    func testInvalidDrawingRasterFlagsAreRejectedInsteadOfSilentlyChoosingAPath() throws {
        for value in ["", "owned", "ownedSRGB8", "OWNED-SRGB8", " owned-srgb8", "owned-srgb8 ", "reference,owned-srgb8"] {
            XCTAssertThrowsError(try DrawingRasterConfiguration.selection(environment: smoke(value)), value)
        }
        for key in ["PICSHOT_DRAWING_RASTER", "PICSHOT_DRAWING_RASTER_UNKNOWN", "PICSHOT_DRAWING_RASTER_STRATEGY_EXTRA"] {
            XCTAssertThrowsError(try DrawingRasterConfiguration.selection(environment: [key: "reference"]), key)
        }
        for strategy in DrawingRasterStrategy.allCases {
            for value in ["", "0", "true", " 1", "1 "] {
                var invalid = smoke(strategy.rawValue); invalid["PICSHOT_SMOKE_TEST"] = value
                XCTAssertThrowsError(try DrawingRasterConfiguration.selection(environment: invalid))
            }
            for value in ["", "relative.json", "~/report.json", "file:///tmp/report.json", "/tmp/report\0.json"] {
                var invalid = smoke(strategy.rawValue); invalid["PICSHOT_SMOKE_REPORT"] = value
                XCTAssertThrowsError(try DrawingRasterConfiguration.selection(environment: invalid))
            }
        }
    }

    func testDefaultProcessPreservesPixelsSourceFormatsAndProviderRetirementWithoutExplicitConfiguration() throws {
        // This integration test must exercise the same unconfigured entry points
        // as the installed app. Diagnostic overrides would invalidate that claim.
        XCTAssertFalse(ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("PICSHOT_DRAWING_RASTER") })
        XCTAssertEqual(try DrawingRasterConfiguration.process.selectedStrategy(), .ownedSRGB8)
        let tracker = DrawingRasterConfiguration.process.tracker
        let colors = [try sRGB(), try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3)),
                      try XCTUnwrap(CGColorSpace(name: CGColorSpace.linearSRGB)), CGColorSpaceCreateDeviceRGB()]
        for color in colors { for depth in [8, 16] {
            let known = try fixture(depth: depth, alpha: .last,
                order: depth == 8 ? .byteOrder32Big : .byteOrder16Big, color: color)
            let expected = try referenceBytes(known.image)
            let ownedBytes = known.image.width * known.image.height * 4
            let eligible = depth == 8 && color.name == CGColorSpace.sRGB
            let reason: DrawingRaster.UnsupportedReason = color.name == CGColorSpace.sRGB ? .componentDepth : .colorSpace
            let before = tracker.snapshot()
            try autoreleasepool {
                let prepared = try DrawingRaster.prepare(known.image)
                if eligible {
                    XCTAssertEqual(prepared.outcome, .owned(bytes: ownedBytes))
                    XCTAssertFalse(prepared.image === known.image)
                    try assertSRGB8(prepared.image, equals: expected)
                    XCTAssertEqual(prepared.image.shouldInterpolate, known.interpolate)
                    XCTAssertEqual(prepared.image.renderingIntent, known.intent)
                } else {
                    XCTAssertEqual(prepared.outcome, .unchanged(reason))
                    XCTAssertTrue(prepared.image === known.image)
                }
                let context = try bitmap(width: known.image.width, height: known.image.height)
                let outcome = try DrawingRaster.seedFreshSRGB8Context(context, from: known.image)
                XCTAssertEqual(outcome, eligible ? .seededContext(bytes: ownedBytes) : .unchanged(reason))
                XCTAssertEqual(try bytes(context), expected)
                let rendered = try XCTUnwrap(ImageEditorRenderer.render(image: known.image, annotations: []))
                try assertSRGB8(rendered, equals: expected)
                let snapshot = try ImageExportSnapshot(image: known.image)
                try assertSRGB8(snapshot.image, equals: expected)
                XCTAssertFalse(snapshot.image === known.image)
                try assertSourceUnchanged(known)
            }
            let after = tracker.snapshot()
            XCTAssertEqual(after.referenceCount, before.referenceCount)
            XCTAssertEqual(after.failureCount, before.failureCount)
            XCTAssertEqual(after.presentationFallbackCount, before.presentationFallbackCount)
            XCTAssertEqual(after.eligibleCount - before.eligibleCount, eligible ? 4 : 0)
            XCTAssertEqual(after.ownedCount - before.ownedCount, eligible ? 1 : 0)
            XCTAssertEqual(after.seededContextCount - before.seededContextCount, eligible ? 3 : 0)
            XCTAssertEqual(after.allocations - before.allocations, eligible ? 1 : 0)
            XCTAssertEqual(after.deallocations - before.deallocations, eligible ? 1 : 0)
            XCTAssertEqual(after.releaseCallbacks - before.releaseCallbacks, eligible ? 1 : 0)
            XCTAssertEqual(after.allocatedBytes - before.allocatedBytes, eligible ? ownedBytes : 0)
            XCTAssertEqual(after.deallocatedBytes - before.deallocatedBytes, eligible ? ownedBytes : 0)
            XCTAssertEqual(after.callbackBytes - before.callbackBytes, eligible ? ownedBytes : 0)
            XCTAssertEqual(after.activeBytes, before.activeBytes)
            XCTAssertTrue(after.callbackSizesMatch)
            var expectedUnsupported = before.unsupportedCounts
            if !eligible { expectedUnsupported[reason.rawValue, default: 0] += 4 }
            XCTAssertEqual(after.unsupportedCounts, expectedUnsupported)
        } }
    }

    func testRequiredRenderingAndSnapshotFailClosedOnInvalidSettingsOrConversion() throws {
        let known = try fixture(depth: 8, alpha: .last, order: .byteOrder32Big, color: sRGB())
        for configuration in [DrawingRasterConfiguration(environment: smoke("invalid")),
                              DrawingRasterConfiguration(strategy: .ownedSRGB8, failureInjection: .conversion),
                              DrawingRasterConfiguration(strategy: .ownedSRGB8, limits: .init(maximumOwnedBytes: 1))] {
            XCTAssertNil(ImageEditorRenderer.render(image: known.image, annotations: [], drawingRaster: configuration))
            XCTAssertThrowsError(try ImageExportSnapshot(image: known.image, drawingRaster: configuration))
            let counts = configuration.tracker.snapshot()
            XCTAssertEqual(counts.failureCount, 2)
            XCTAssertEqual(counts.ownedCount + counts.seededContextCount + counts.presentationFallbackCount, 0)
            XCTAssertEqual(counts.activeBytes, 0)
            try assertSourceUnchanged(known)
        }
    }

    func testOwnedFailuresAndEveryCancellationFenceReleaseWithoutPublishing() throws {
        let image = try fixture(depth: 8, alpha: .last, order: .byteOrder32Big, color: sRGB()).image
        for injection in [DrawingRaster.FailureInjection.conversion, .provider] {
            let configuration = DrawingRasterConfiguration(strategy: .ownedSRGB8, failureInjection: injection)
            try autoreleasepool { XCTAssertThrowsError(try DrawingRaster.prepare(image, configuration: configuration)) }
            let counts = configuration.tracker.snapshot()
            XCTAssertEqual(counts.allocations, 1); XCTAssertEqual(counts.deallocations, 1)
            XCTAssertEqual(counts.releaseCallbacks, 0); XCTAssertEqual(counts.activeBytes, 0)
            XCTAssertEqual(counts.ownedCount, 0); XCTAssertEqual(counts.failureCount, 1)
        }
        for fence in 1...4 {
            let configuration = DrawingRasterConfiguration(strategy: .ownedSRGB8)
            var calls = 0
            try autoreleasepool {
                XCTAssertThrowsError(try DrawingRaster.prepare(image, configuration: configuration,
                    isCancelled: { calls += 1; return calls == fence })) { error in
                    XCTAssertEqual(error as? DrawingRaster.Failure, .cancelled)
                }
            }
            let counts = configuration.tracker.snapshot()
            XCTAssertEqual(calls, fence); XCTAssertEqual(counts.ownedCount, 0)
            XCTAssertEqual(counts.allocations, fence == 1 ? 0 : 1)
            XCTAssertEqual(counts.deallocations, counts.allocations)
            XCTAssertEqual(counts.releaseCallbacks, fence == 4 ? 1 : 0)
            XCTAssertEqual(counts.activeBytes, 0); XCTAssertTrue(counts.callbackSizesMatch)
        }
        for fence in 1...3 {
            let configuration = DrawingRasterConfiguration(strategy: .ownedSRGB8)
            let context = try bitmap(width: image.width, height: image.height)
            var calls = 0
            XCTAssertThrowsError(try DrawingRaster.seedFreshSRGB8Context(context, from: image, configuration: configuration,
                isCancelled: { calls += 1; return calls == fence }))
            XCTAssertEqual(calls, fence); XCTAssertEqual(configuration.tracker.snapshot().seededContextCount, 0)
        }
    }

    func testOwnedProviderLifetimeAndAdmissionAreBoundedAcrossIndependentImages() throws {
        let image = try fixture(depth: 8, alpha: .last, order: .byteOrder32Big, color: sRGB()).image
        let count = image.width * image.height * 4
        let configuration = DrawingRasterConfiguration(strategy: .ownedSRGB8,
            limits: .init(maximumActiveOwnedBytes: count))
        var expectedAllocations = 1
        try autoreleasepool {
            var first: DrawingRaster.Representation? = try DrawingRaster.prepare(image, configuration: configuration)
            var provider = first?.image.dataProvider
            XCTAssertNotNil(provider)
            // An eager framework copy may already have released our provider.
            // Gate admission on observed owned bytes, not CGImage object lifetime.
            let live = configuration.tracker.snapshot()
            XCTAssertTrue(live.activeBytes == 0 || live.activeBytes == count)
            if live.activeBytes == count {
                XCTAssertThrowsError(try DrawingRaster.prepare(image, configuration: configuration))
            } else {
                _ = try DrawingRaster.prepare(image, configuration: configuration)
                expectedAllocations += 1
            }
            XCTAssertLessThanOrEqual(configuration.tracker.snapshot().peakActiveBytes, count)
            first = nil
            withExtendedLifetime(provider) { }
            provider = nil
        }
        assertBalanced(configuration.tracker, allocations: expectedAllocations, callbacks: expectedAllocations)
        try autoreleasepool { _ = try DrawingRaster.prepare(image, configuration: configuration) }
        assertBalanced(configuration.tracker, allocations: expectedAllocations + 1, callbacks: expectedAllocations + 1)
        let refused = DrawingRasterConfiguration(strategy: .ownedSRGB8, limits: .init(maximumActiveOwnedBytes: count - 1))
        XCTAssertThrowsError(try DrawingRaster.prepare(image, configuration: refused))
        XCTAssertEqual(refused.tracker.snapshot().allocations, 0)
        XCTAssertThrowsError(try DrawingRaster.admittedStorage(image, destinationRowBytes: Int.max, limits: .standard))
        XCTAssertThrowsError(try DrawingRaster.admittedStorage(image, destinationRowBytes: 1, limits: .standard))
        for limits in [DrawingRaster.Limits(maximumDimension: 1), .init(maximumOwnedBytes: count - 1),
                       .init(maximumWorkingBytes: image.bytesPerRow * image.height + count - 1)] {
            XCTAssertThrowsError(try DrawingRaster.prepare(image, configuration: .init(strategy: .ownedSRGB8, limits: limits)))
        }
    }

    func testSeedRejectsIncompatibleDestinationAndNeverCountsItAsAnOptimization() throws {
        let image = try fixture(depth: 8, alpha: .last, order: .byteOrder32Big, color: sRGB()).image
        let configuration = DrawingRasterConfiguration(strategy: .ownedSRGB8)
        let wrongSize = try bitmap(width: image.width + 1, height: image.height)
        let transformed = try bitmap(width: image.width, height: image.height)
        transformed.translateBy(x: 1, y: 0)
        let wrongFormat = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: sRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        for destination in [wrongSize, transformed, wrongFormat] {
            XCTAssertThrowsError(try DrawingRaster.seedFreshSRGB8Context(destination, from: image, configuration: configuration))
        }
        XCTAssertEqual(configuration.tracker.snapshot().seededContextCount, 0)
        XCTAssertEqual(configuration.tracker.snapshot().failureCount, 3)
    }

    func testSnapshotDetachesEvenCanonicalMutableProviderAndSurvivesFileRemoval() throws {
        let known = try fixture(depth: 8, alpha: .premultipliedLast, order: .byteOrder32Big, color: sRGB())
        let count = known.raw.count
        let raw = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
        defer { raw.deallocate() }
        let provider = try XCTUnwrap(CGDataProvider(dataInfo: nil, data: raw, size: count, releaseData: { _, _, _ in }))
        for strategy in DrawingRasterStrategy.allCases {
            known.raw.withUnsafeBytes { raw.copyMemory(from: $0.baseAddress!, byteCount: count) }
            let source = try XCTUnwrap(CGImage(width: 6, height: 3, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: known.rowBytes, space: sRGB(), bitmapInfo: DrawingRaster.bitmapInfo,
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let expected = try referenceBytes(source)
            let snapshot = try ImageExportSnapshot(image: source, drawingRaster: .init(strategy: strategy))
            raw.initializeMemory(as: UInt8.self, repeating: 0xFF, count: count)
            XCTAssertFalse(snapshot.image === source)
            try assertSRGB8(snapshot.image, equals: expected)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("drawing-snapshot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try known.image.writePNG(to: url)
        var snapshots: [ImageExportSnapshot] = []
        var expected: [Data] = []
        try autoreleasepool {
            for strategy in DrawingRasterStrategy.allCases {
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary))
                let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                expected.append(try referenceBytes(decoded))
                snapshots.append(try ImageExportSnapshot(image: decoded, sourceURL: url, drawingRaster: .init(strategy: strategy)))
            }
        }
        try FileManager.default.removeItem(at: url)
        for (snapshot, bytes) in zip(snapshots, expected) { try assertSRGB8(snapshot.image, equals: bytes) }
    }

    @MainActor
    func testPresentationCacheReusesOnlyIdenticalSourceInvalidatesAndReleases() throws {
        let first = try fixture(depth: 8, alpha: .last, order: .byteOrder32Big, color: sRGB()).image
        let second = try fixture(depth: 8, alpha: .last, order: .byteOrder32Big, color: sRGB()).image
        let configuration = DrawingRasterConfiguration(strategy: .ownedSRGB8)
        try autoreleasepool {
            var cache: DrawingRasterPresentationCache? = DrawingRasterPresentationCache(configuration: configuration)
            let firstIdentity = ObjectIdentifier(cache!.image(for: first))
            for _ in 0..<8 { XCTAssertEqual(ObjectIdentifier(cache!.image(for: first)), firstIdentity) }
            XCTAssertEqual(configuration.tracker.snapshot().ownedCount, 1)
            XCTAssertEqual(configuration.tracker.snapshot().presentationReuseCount, 8)
            _ = cache!.image(for: second)
            XCTAssertEqual(configuration.tracker.snapshot().ownedCount, 2)
            cache!.clear(); XCTAssertEqual(cache!.retainedBytes, 0)
            _ = cache!.image(for: first)
            XCTAssertEqual(configuration.tracker.snapshot().ownedCount, 3)
            cache = nil
        }
        assertBalanced(configuration.tracker, allocations: 3, callbacks: 3)
    }

    @MainActor
    func testPresentationFailureIsExplicitCountedAndDoesNotRetrySameIdentity() throws {
        let known = try fixture(depth: 8, alpha: .last, order: .byteOrder32Big, color: sRGB())
        for configuration in [DrawingRasterConfiguration(strategy: .ownedSRGB8, failureInjection: .conversion),
                              DrawingRasterConfiguration(strategy: .ownedSRGB8, failureInjection: .provider),
                              DrawingRasterConfiguration(environment: smoke("invalid"))] {
            let cache = DrawingRasterPresentationCache(configuration: configuration)
            for _ in 0..<4 { XCTAssertTrue(cache.image(for: known.image) === known.image) }
            XCTAssertEqual(cache.representation?.outcome, .presentationFallback)
            let counts = configuration.tracker.snapshot()
            XCTAssertEqual(counts.presentationFallbackCount, 1); XCTAssertEqual(counts.failureCount, 1)
            XCTAssertEqual(counts.presentationReuseCount, 3); XCTAssertEqual(counts.ownedCount, 0)
            XCTAssertEqual(counts.activeBytes, 0); XCTAssertEqual(cache.retainedBytes, 0)
            cache.clear()
            XCTAssertTrue(cache.image(for: known.image) === known.image)
            XCTAssertEqual(configuration.tracker.snapshot().presentationFallbackCount, 2)
            try assertSourceUnchanged(known)
        }
    }

    @MainActor
    func testScaledPinCanvasMatchesIndependentOriginalQuartzDrawAtBothBackingScales() throws {
        _ = NSApplication.shared
        for alpha in rgbaLayouts + [.none] {
            let orders: [CGBitmapInfo] = alpha == .none ? [.byteOrderDefault] : [.byteOrderDefault, .byteOrder32Big, .byteOrder32Little]
            for order in orders { for intent in intents {
                let known = try fixture(depth: 8, alpha: alpha, order: order, color: sRGB(), intent: intent)
                let configuration = DrawingRasterConfiguration(strategy: .ownedSRGB8)
                let view = PinCanvas(frame: NSRect(x: 0, y: 0, width: 41, height: 31), drawingRaster: configuration)
                view.image = known.image
                for zoom in [CGFloat(0.5), 1, 3.25] { for backingScale in [1, 2] {
                    view.zoom = zoom
                    let expected = try appKitPixels(size: view.bounds.size, backingScale: backingScale) { context in
                        context.interpolationQuality = zoom > 1 ? .none : .high
                        context.draw(known.image, in: view.imageRect)
                        context.setStrokeColor(NSColor.black.withAlphaComponent(0.18).cgColor)
                        context.setLineWidth(1); context.stroke(view.imageRect.insetBy(dx: 0.5, dy: 0.5))
                    }
                    XCTAssertEqual(try viewPixels(view, backingScale: backingScale), expected,
                        "alpha=\(alpha), order=\(order), intent=\(intent), zoom=\(zoom), backing=\(backingScale)")
                } }
                XCTAssertEqual(configuration.tracker.snapshot().ownedCount, 1)
                XCTAssertEqual(configuration.tracker.snapshot().presentationReuseCount, 5)
                XCTAssertTrue(view.image === known.image)
                try assertSourceUnchanged(known)
                view.image = nil
            } }
        }
    }

    @MainActor
    func testExportPreviewKeepsNativeAspectFitAndSourceIdentityAcrossScaledDraws() throws {
        _ = NSApplication.shared
        let colors = [try sRGB(), try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))]
        for color in colors { for depth in [8, 16] { for intent in intents {
            let known = try fixture(depth: depth, alpha: .last,
                order: depth == 8 ? .byteOrder32Little : .byteOrder16Big, color: color, intent: intent)
            let configuration = DrawingRasterConfiguration(strategy: .ownedSRGB8)
            let view = ImageExportPreviewView(drawingRaster: configuration)
            view.setSourceImage(known.image)
            let original = try XCTUnwrap(view.image)
            var observations: [ImageExportPreviewDrawObservation] = []
            view.diagnosticDrawObserver = { observations.append($0) }
            for size in [NSSize(width: 4, height: 3), NSSize(width: 19, height: 13), NSSize(width: 57, height: 41)] {
                view.setFrameSize(size)
                let expectedRect = CGRect(x: 0, y: (size.height - size.width / 2) / 2,
                    width: size.width, height: size.width / 2)
                XCTAssertEqual(view.displayedImageRect, expectedRect)
                for backingScale in [1, 2] {
                    let expected = try appKitPixels(size: size, backingScale: backingScale) { _ in
                        original.draw(in: expectedRect, from: .zero, operation: .sourceOver, fraction: 1,
                            respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
                    }
                    XCTAssertEqual(try viewPixels(view, backingScale: backingScale), expected)
                }
                view.setSourceImage(known.image)
                XCTAssertTrue(view.image === original)
            }
            XCTAssertEqual(observations.count, 6)
            XCTAssertTrue(observations.allSatisfy { $0.imageIdentity == String(describing: ObjectIdentifier(original)) })
            let eligible = depth == 8 && color.name == CGColorSpace.sRGB
            XCTAssertEqual(configuration.tracker.snapshot().ownedCount, eligible ? 1 : 0)
            XCTAssertEqual(configuration.tracker.snapshot().presentationReuseCount, 5)
            try assertSourceUnchanged(known)
            view.image = nil
        } } }
    }

    @MainActor
    func testPinCropOverlayAndPresentationFailuresPreserveNativePixelsAndGeometry() throws {
        let known = try fixture(depth: 8, alpha: .last, order: .byteOrder32Big, color: sRGB())
        let frame = NSRect(x: 0, y: 0, width: 71, height: 53)
        let baseline = PinCanvas(frame: frame, drawingRaster: .init(strategy: .reference))
        baseline.image = known.image; baseline.zoom = 7.5; baseline.isCropping = true
        baseline.selection = CGRect(x: 1, y: 1, width: 3, height: 1)
        let expected = try viewPixels(baseline)
        for configuration in [DrawingRasterConfiguration(strategy: .ownedSRGB8),
                              DrawingRasterConfiguration(strategy: .ownedSRGB8, failureInjection: .conversion)] {
            let view = PinCanvas(frame: frame, drawingRaster: configuration)
            view.image = known.image; view.zoom = baseline.zoom; view.isCropping = true; view.selection = baseline.selection
            for _ in 0..<3 { XCTAssertEqual(try viewPixels(view), expected) }
            XCTAssertEqual(view.imageRect, baseline.imageRect); XCTAssertEqual(view.selection, baseline.selection)
            XCTAssertTrue(view.image === known.image)
            XCTAssertEqual(configuration.tracker.snapshot().presentationFallbackCount,
                configuration.failureInjection == .conversion ? 1 : 0)
            view.image = nil
        }
        let failure = DrawingRasterConfiguration(strategy: .ownedSRGB8, failureInjection: .provider)
        let preview = ImageExportPreviewView(frame: frame, drawingRaster: failure)
        preview.setSourceImage(known.image)
        let original = try XCTUnwrap(preview.image)
        let previewExpected = try appKitPixels(size: frame.size) { _ in
            original.draw(in: preview.displayedImageRect, from: .zero, operation: .sourceOver, fraction: 1,
                respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        }
        for _ in 0..<3 { XCTAssertEqual(try viewPixels(preview), previewExpected) }
        XCTAssertEqual(failure.tracker.snapshot().presentationFallbackCount, 1)
        XCTAssertEqual(failure.tracker.snapshot().ownedCount, 0)
        preview.image = nil
    }

    @MainActor
    func testNativePinAndExportCloseClearOwnedCachesEvenWhileViewsRemainRetained() throws {
        _ = NSApplication.shared
        let known = try fixture(depth: 8, alpha: .last, order: .byteOrder32Big, color: sRGB())
        let pinConfiguration = DrawingRasterConfiguration(strategy: .ownedSRGB8)
        try autoreleasepool {
            let pin = PinController(originalImage: known.image, currentImage: known.image, isModified: false,
                defaults: nil, drawingRaster: pinConfiguration)
            let canvas = try XCTUnwrap(pinCanvas(in: pin.window?.contentView))
            _ = try viewPixels(canvas)
            XCTAssertEqual(pinConfiguration.tracker.snapshot().ownedCount, 1)
            XCTAssertTrue(pin.image === known.image); XCTAssertTrue(pin.currentImage === known.image)
            pin.close()
            XCTAssertNil(canvas.image)
            XCTAssertNil(pin.window?.contentView)
            withExtendedLifetime(canvas) { }
        }
        assertBalanced(pinConfiguration.tracker, allocations: 1, callbacks: 1)
        let exportConfiguration = DrawingRasterConfiguration(strategy: .ownedSRGB8)
        try autoreleasepool {
            let export = try ImageExportController(image: known.image, drawingRaster: exportConfiguration)
            let preview = export.previewView
            preview.setFrameSize(NSSize(width: 120, height: 90))
            preview.setSourceImage(known.image)
            _ = try viewPixels(preview)
            XCTAssertEqual(exportConfiguration.tracker.snapshot().ownedCount, 1)
            export.cancelExport()
            XCTAssertNil(preview.image); XCTAssertTrue(export.isClosed)
            XCTAssertNil(export.window?.contentView)
            withExtendedLifetime(preview) { }
        }
        assertBalanced(exportConfiguration.tracker, allocations: 1, callbacks: 1)
    }

    @MainActor
    func testDetachAndReattachDropsRepresentationAndRebuildsFromSameSourceOnce() throws {
        _ = NSApplication.shared
        let source = try fixture(depth: 8, alpha: .last, order: .byteOrder32Big, color: sRGB()).image
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 90),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for isPin in [true, false] {
            let configuration = DrawingRasterConfiguration(strategy: .ownedSRGB8)
            try autoreleasepool {
                let view: NSView
                if isPin {
                    let canvas = PinCanvas(frame: NSRect(x: 0, y: 0, width: 40, height: 30), drawingRaster: configuration)
                    canvas.image = source; view = canvas
                } else {
                    let preview = ImageExportPreviewView(frame: NSRect(x: 0, y: 0, width: 40, height: 30), drawingRaster: configuration)
                    preview.setSourceImage(source); view = preview
                }
                for cycle in 1...2 {
                    window.contentView!.addSubview(view)
                    _ = try viewPixels(view)
                    XCTAssertEqual(configuration.tracker.snapshot().ownedCount, cycle)
                    view.removeFromSuperview()
                }
            }
            assertBalanced(configuration.tracker, allocations: 2, callbacks: 2)
        }
    }

    @MainActor
    func testOriginalP3And16BitCopyResetEditableRePersistenceRemainUnchanged() throws {
        _ = NSApplication.shared
        for color in [try sRGB(), try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))] { for depth in [8, 16] {
            let known = try fixture(depth: depth, alpha: .last,
                order: depth == 8 ? .byteOrder32Big : .byteOrder16Big, color: color)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("drawing-model-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try PinSessionStore(directory: directory)
            let id = UUID()
            let document = EditableAnnotationDocument(originalAssetID: id, originalPixelWidth: 6,
                originalPixelHeight: 3, baseAssetID: id, basePixelWidth: 6, basePixelHeight: 3,
                baseProvenance: .originalCapture, annotations: [])
            let payload = EditableCapturePayload(document: document, originalImage: known.image, baseImage: known.image)
            let entry = try store.add(originalImage: known.image, currentImage: known.image, editable: payload)
            let originalFile = directory.appendingPathComponent(entry.original.filename)
            let persistedBefore = try Data(contentsOf: originalFile)
            let restoredBefore = try XCTUnwrap(store.editablePayload(id: entry.id))
            let copyBefore = try XCTUnwrap(NSBitmapImageRep(cgImage: known.image).representation(using: .png, properties: [:]))
            let configuration = DrawingRasterConfiguration(strategy: .ownedSRGB8)
            try autoreleasepool {
                let pin = PinController(originalImage: known.image, currentImage: known.image, isModified: false,
                    defaults: nil, drawingRaster: configuration)
                defer { pin.close() }
                let canvas = try XCTUnwrap(pinCanvas(in: pin.window?.contentView))
                _ = try viewPixels(canvas)
                XCTAssertTrue(pin.image === known.image); XCTAssertTrue(pin.currentImage === known.image)
                try pin.cropImage(to: CGRect(x: 1, y: 0, width: 3, height: 2))
                _ = try viewPixels(canvas)
                try pin.restoreOriginalImage()
                _ = try viewPixels(canvas)
                XCTAssertTrue(pin.image === known.image); XCTAssertTrue(pin.currentImage === known.image)
                XCTAssertEqual(try XCTUnwrap(NSBitmapImageRep(cgImage: pin.currentImage).representation(using: .png, properties: [:])), copyBefore)
                XCTAssertTrue(payload.originalImage === known.image); XCTAssertTrue(payload.baseImage === known.image)
                try store.replaceImage(pin.currentImage, id: entry.id, editable: payload)
            }
            XCTAssertEqual(try Data(contentsOf: originalFile), persistedBefore)
            let reloaded = try PinSessionStore(directory: directory)
            let restoredAfter = try XCTUnwrap(reloaded.editablePayload(id: entry.id))
            XCTAssertEqual(restoredAfter.originalImage.bitsPerComponent, depth)
            XCTAssertEqual(restoredAfter.baseImage.bitsPerComponent, depth)
            XCTAssertEqual(try meaningfulSamples(restoredAfter.originalImage), try meaningfulSamples(restoredBefore.originalImage))
            XCTAssertEqual(try meaningfulSamples(restoredAfter.baseImage), try meaningfulSamples(restoredBefore.baseImage))
            let beforeProfile = try XCTUnwrap(restoredBefore.originalImage.colorSpace?.copyICCData()) as Data
            let afterProfile = try XCTUnwrap(restoredAfter.originalImage.colorSpace?.copyICCData()) as Data
            XCTAssertEqual(afterProfile, beforeProfile)
            XCTAssertEqual(try EditableAnnotationDocumentCodec.encode(restoredAfter.document), try EditableAnnotationDocumentCodec.encode(document))
            try assertSourceUnchanged(known)
            XCTAssertEqual(configuration.tracker.snapshot().presentationFallbackCount, 0)
        } }
    }

    func testRendererEffectsKeepOriginalBaseInputsAndFailClosedOnEffectFailure() throws {
        let sourceContext = try bitmap(width: 96, height: 64)
        for y in 0..<64 { for x in 0..<96 {
            sourceContext.setFillColor(CGColor(srgbRed: CGFloat(x % 13) / 13, green: CGFloat(y % 11) / 11,
                blue: CGFloat((x + y) % 7) / 7, alpha: CGFloat((x + y) % 9) / 8))
            sourceContext.fill(CGRect(x: x, y: y, width: 1, height: 1))
        } }
        let original = try XCTUnwrap(sourceContext.makeImage())
        let originalBytes = try providerBytes(original)
        let extent = CGRect(x: 0, y: 0, width: 96, height: 64)
        for tool in [ImageEditorTool.rectangle, .blur, .pixelate, .spotlight, .magnifier, .redact, .eraser] {
            var mark = ImageAnnotation(tool: tool, points: [CGPoint(x: 12, y: 9), CGPoint(x: 70, y: 48)], lineWidth: 3)
            mark.magnifierShowsAnnotations = false
            let marks = [ImageAnnotation(tool: .freehand, points: [CGPoint(x: 4, y: 10), CGPoint(x: 80, y: 55)], lineWidth: 4), mark]
            let oracle = try bitmap(width: 96, height: 64)
            oracle.draw(original, in: extent)
            XCTAssertTrue(ImageEditorRenderer.drawAnnotations(marks, in: oracle, extent: extent, baseImage: original))
            let actual = try XCTUnwrap(ImageEditorRenderer.render(image: original, annotations: marks,
                drawingRaster: .init(strategy: .ownedSRGB8)))
            try assertSRGB8(actual, equals: bytes(oracle))
            XCTAssertEqual(try providerBytes(original), originalBytes)
        }
        let blur = ImageAnnotation(tool: .blur, points: [CGPoint(x: 12, y: 9), CGPoint(x: 70, y: 48)])
        XCTAssertNil(ImageEditorRenderer.render(image: original, annotations: [blur], drawingRaster: .init(strategy: .ownedSRGB8),
            effectPatchRenderer: { _, _ in nil }))
    }

    @MainActor private func pinCanvas(in view: NSView?) -> PinCanvas? {
        if let canvas = view as? PinCanvas { return canvas }
        for child in view?.subviews ?? [] { if let found = pinCanvas(in: child) { return found } }
        return nil
    }
    @MainActor private func viewPixels(_ view: NSView, backingScale: Int = 1) throws -> Data {
        try appKitPixels(size: view.bounds.size, backingScale: backingScale) { _ in view.draw(view.bounds) }
    }
    @MainActor private func appKitPixels(size: CGSize, backingScale: Int = 1, draw: (CGContext) throws -> Void) throws -> Data {
        try autoreleasepool {
            let context = try bitmap(width: max(1, Int(ceil(size.width * CGFloat(backingScale)))),
                height: max(1, Int(ceil(size.height * CGFloat(backingScale)))))
            context.scaleBy(x: CGFloat(backingScale), y: CGFloat(backingScale))
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            try draw(context); context.flush()
            return try bytes(context)
        }
    }
    private func meaningfulSamples(_ image: CGImage) throws -> Data {
        let raw = try providerBytes(image), count = (image.width * image.bitsPerPixel + 7) / 8
        var result = Data()
        for row in 0..<image.height { result.append(raw[(row * image.bytesPerRow)..<(row * image.bytesPerRow + count)]) }
        return result
    }

    func testMasksGrayDecodeArraysAndFloatingSamplesUseUnchangedNativeRepresentations() throws {
        let data = Data(repeating: 127, count: 16)
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        var decode: [CGFloat] = [1, 0, 0.2, 0.8, 0, 1]
        let remapped = try decode.withUnsafeMutableBufferPointer { values in
            try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: 8, space: sRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: values.baseAddress, shouldInterpolate: false, intent: .saturation))
        }
        let gray = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: 2, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        let mask = try XCTUnwrap(CGImage(maskWidth: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: 2, provider: provider, decode: nil, shouldInterpolate: false))
        let samples: [Float] = [0.1, 0.2, 0.3, 0.5]
        let floatData = samples.withUnsafeBytes { Data($0) }
        let floating = try XCTUnwrap(CGImage(width: 1, height: 1, bitsPerComponent: 32, bitsPerPixel: 128,
            bytesPerRow: 16, space: sRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: XCTUnwrap(CGDataProvider(data: floatData as CFData)), decode: nil,
            shouldInterpolate: true, intent: .perceptual))
        let cases: [(CGImage, DrawingRaster.UnsupportedReason)] = [
            (remapped, .decodeArray), (gray, .colorSpace), (mask, .imageMask), (floating, .floatingPoint)
        ]
        for (image, reason) in cases {
            let configuration = DrawingRasterConfiguration(strategy: .ownedSRGB8,
                limits: .init(maximumDimension: 1, maximumOwnedBytes: 1, maximumWorkingBytes: 1))
            let before = try providerBytes(image)
            let prepared = try DrawingRaster.prepare(image, configuration: configuration)
            XCTAssertTrue(prepared.image === image); XCTAssertEqual(prepared.outcome, .unchanged(reason))
            XCTAssertEqual(try providerBytes(image), before)
            XCTAssertEqual(configuration.tracker.snapshot().unsupportedCounts[reason.rawValue], 1)
            XCTAssertEqual(configuration.tracker.snapshot().eligibleCount, 0)
            XCTAssertEqual(configuration.tracker.snapshot().allocations, 0)
            let context = try bitmap(width: image.width, height: image.height)
            try DrawingRaster.seedFreshSRGB8Context(context, from: image, configuration: configuration)
            XCTAssertEqual(try bytes(context), try referenceBytes(image))
        }
    }

    func testOwnedDrawingProviderDoesNotKeepItsSourceProviderAlive() throws {
        let known = try fixture(depth: 8, alpha: .last, order: .byteOrder32Big, color: sRGB())
        let expected = try referenceBytes(known.image)
        let released = DrawingRasterSourceReleaseProbe()
        let configuration = DrawingRasterConfiguration(strategy: .ownedSRGB8)
        try autoreleasepool {
            let result: DrawingRaster.Representation = try autoreleasepool {
                let raw = UnsafeMutableRawPointer.allocate(byteCount: known.raw.count, alignment: 16)
                known.raw.withUnsafeBytes { raw.copyMemory(from: $0.baseAddress!, byteCount: known.raw.count) }
                let retained = Unmanaged.passRetained(released)
                guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: raw, size: known.raw.count,
                    releaseData: { info, data, _ in
                        UnsafeMutableRawPointer(mutating: data).deallocate()
                        guard let info else { return }
                        Unmanaged<DrawingRasterSourceReleaseProbe>.fromOpaque(info).takeRetainedValue().callbacks += 1
                    }) else {
                    raw.deallocate(); retained.release(); throw DrawingRaster.Failure.providerFailed
                }
                let source = try XCTUnwrap(CGImage(width: 6, height: 3, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: known.rowBytes, space: sRGB(), bitmapInfo: known.info, provider: provider,
                    decode: nil, shouldInterpolate: false, intent: known.intent))
                return try DrawingRaster.prepare(source, configuration: configuration)
            }
            XCTAssertEqual(released.callbacks, 1)
            try assertSRGB8(result.image, equals: expected)
        }
        assertBalanced(configuration.tracker, allocations: 1, callbacks: 1)
    }

    private func smoke(_ strategy: String) -> [String: String] {
        ["PICSHOT_DRAWING_RASTER_STRATEGY": strategy, "PICSHOT_SMOKE_TEST": "1", "PICSHOT_SMOKE_REPORT": "/tmp/drawing-report.json"]
    }
    private func assertBalanced(_ tracker: DrawingRasterTracker, allocations: Int, callbacks: Int,
        file: StaticString = #filePath, line: UInt = #line) {
        let state = tracker.snapshot()
        XCTAssertEqual(state.allocations, allocations, file: file, line: line)
        XCTAssertEqual(state.deallocations, allocations, file: file, line: line)
        XCTAssertEqual(state.releaseCallbacks, callbacks, file: file, line: line)
        XCTAssertEqual(state.activeBytes, 0, file: file, line: line)
        XCTAssertEqual(state.allocatedBytes, state.deallocatedBytes, file: file, line: line)
        XCTAssertTrue(state.callbackSizesMatch, file: file, line: line)
    }

    private struct Fixture {
        let image: CGImage
        let raw: Data
        let color: CGColorSpace
        let depth: Int
        let pixelBits: Int
        let rowBytes: Int
        let info: CGBitmapInfo
        let intent: CGColorRenderingIntent
        let interpolate: Bool
    }

    private func fixture(depth: Int, alpha: CGImageAlphaInfo, order: CGBitmapInfo,
        color: CGColorSpace, intent: CGColorRenderingIntent = .absoluteColorimetric,
        interpolate: Bool = false) throws -> Fixture {
        let width = 6, height = 3, channels = alpha == .none ? 3 : 4, sampleBytes = depth / 8
        let rowBytes = width * channels * sampleBytes + 16
        var raw = Data(repeating: 0xB7, count: rowBytes * height)
        let alphas = depth == 8 ? [0, 1, 2, 127, 254, 255] : [0, 1, 257, 32769, 65534, 65535]
        let first = [.first, .premultipliedFirst, .noneSkipFirst].contains(alpha)
        let premultiplied = [.premultipliedFirst, .premultipliedLast].contains(alpha)
        for y in 0..<height { for x in 0..<width {
            let a = alphas[x], maximum = depth == 8 ? 255 : 65535
            var colors = depth == 8 ? [173 - x * 9 - y * 13, 37 + x * 17 + y * 9, 241 - y * 31]
                : [0xAB31 - x * 263 - y * 521, 0x1257 + x * 257 + y * 311, 0xF139 - y * 521]
            if premultiplied { colors = colors.map { $0 * a / maximum } }
            var values = channels == 3 ? colors : (first ? [a] + colors : colors + [a])
            if depth == 8 && order == .byteOrder32Little { values.reverse() }
            for (component, value) in values.enumerated() {
                let offset = y * rowBytes + (x * channels + component) * sampleBytes
                if depth == 8 { raw[offset] = UInt8(value) }
                else if order == .byteOrder16Little {
                    raw[offset] = UInt8(value & 255); raw[offset + 1] = UInt8(value >> 8)
                } else {
                    raw[offset] = UInt8(value >> 8); raw[offset + 1] = UInt8(value & 255)
                }
            }
        } }
        let info = CGBitmapInfo(rawValue: alpha.rawValue | order.rawValue)
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: depth,
            bitsPerPixel: channels * depth, bytesPerRow: rowBytes, space: color,
            bitmapInfo: info, provider: XCTUnwrap(CGDataProvider(data: raw as CFData)),
            decode: nil, shouldInterpolate: interpolate, intent: intent))
        return Fixture(image: image, raw: raw, color: color, depth: depth,
            pixelBits: channels * depth, rowBytes: rowBytes, info: info, intent: intent, interpolate: interpolate)
    }

    private func sRGB() throws -> CGColorSpace { try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)) }

    private func bitmap(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: sRGB(), bitmapInfo:
                CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    }

    private func referenceBytes(_ image: CGImage) throws -> Data {
        let context = try bitmap(width: image.width, height: image.height)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try bytes(context)
    }

    private func bytes(_ context: CGContext) throws -> Data {
        let raw = try XCTUnwrap(context.data)
        var result = Data()
        for row in 0..<context.height {
            result.append(Data(bytes: raw.advanced(by: row * context.bytesPerRow), count: context.width * 4))
        }
        return result
    }

    private func providerBytes(_ image: CGImage) throws -> Data {
        try XCTUnwrap(XCTUnwrap(image.dataProvider).data) as Data
    }

    private func assertSRGB8(_ image: CGImage, equals expected: Data,
        file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(image.bitsPerComponent, 8, file: file, line: line)
        XCTAssertEqual(image.bitsPerPixel, 32, file: file, line: line)
        XCTAssertEqual(image.alphaInfo, .premultipliedLast, file: file, line: line)
        XCTAssertEqual(image.bitmapInfo.intersection(.byteOrderMask), .byteOrder32Big, file: file, line: line)
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB, file: file, line: line)
        let raw = try providerBytes(image)
        XCTAssertGreaterThanOrEqual(raw.count, image.bytesPerRow * image.height, file: file, line: line)
        guard raw.count >= image.bytesPerRow * image.height else { return }
        var actual = Data()
        for row in 0..<image.height {
            actual.append(raw[(row * image.bytesPerRow)..<(row * image.bytesPerRow + image.width * 4)])
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func assertSourceUnchanged(_ fixture: Fixture,
        file: StaticString = #filePath, line: UInt = #line) throws {
        let image = fixture.image
        XCTAssertEqual(try providerBytes(image), fixture.raw, file: file, line: line)
        XCTAssertEqual(image.width, 6, file: file, line: line)
        XCTAssertEqual(image.height, 3, file: file, line: line)
        XCTAssertEqual(image.bitsPerComponent, fixture.depth, file: file, line: line)
        XCTAssertEqual(image.bitsPerPixel, fixture.pixelBits, file: file, line: line)
        XCTAssertEqual(image.bytesPerRow, fixture.rowBytes, file: file, line: line)
        XCTAssertEqual(image.bitmapInfo, fixture.info, file: file, line: line)
        XCTAssertTrue(image.colorSpace === fixture.color, file: file, line: line)
        XCTAssertEqual(image.renderingIntent, fixture.intent, file: file, line: line)
        XCTAssertEqual(image.shouldInterpolate, fixture.interpolate, file: file, line: line)
        XCTAssertNil(image.decode, file: file, line: line)
    }
}

private final class DrawingRasterSourceReleaseProbe { var callbacks = 0 }
