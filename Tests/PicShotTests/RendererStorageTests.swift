import AppKit
import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PicShot

/// Read provider bytes directly. Redrawing the returned image would conceal
/// alpha/color conversion or a stale pointer and is never the pixel oracle here.
final class RendererStorageTests: XCTestCase {
    func testProductionDefaultIsNativeAndOnlyExactSmokeSelectionIsAllowed() throws {
        XCTAssertEqual(try RendererStorageConfiguration.selection(environment: [:]), .native)
        XCTAssertEqual(try RendererStorageConfiguration.selection(environment: ["PICSHOT_SMOKE_TEST": "1"]), .native)
        for strategy in RendererStorageStrategy.allCases {
            XCTAssertEqual(try RendererStorageConfiguration(environment: smoke(strategy.rawValue)).selectedStrategy(), strategy)
            for key in ["PICSHOT_SMOKE_TEST", "PICSHOT_SMOKE_REPORT"] {
                var invalid = smoke(strategy.rawValue); invalid.removeValue(forKey: key)
                XCTAssertThrowsError(try RendererStorageConfiguration.selection(environment: invalid))
            }
        }
        for raw in ["", "reference", "owned", "ownedSRGB8", "NATIVE", " native", "owned-srgb8 "] {
            XCTAssertThrowsError(try RendererStorageConfiguration.selection(environment: smoke(raw)))
        }
        for key in ["PICSHOT_RENDERER_STORAGE", "PICSHOT_RENDERER_STORAGE_UNKNOWN", "PICSHOT_RENDERER_STORAGE_STRATEGY_EXTRA"] {
            XCTAssertThrowsError(try RendererStorageConfiguration.selection(environment: [key: "native"]))
        }
        for raw in ["", "0", "true", " 1", "1 "] {
            var invalid = smoke("owned-srgb8"); invalid["PICSHOT_SMOKE_TEST"] = raw
            XCTAssertThrowsError(try RendererStorageConfiguration.selection(environment: invalid))
        }
        for raw in ["", "relative.json", "~/report.json", "file:///tmp/report.json", "/tmp/report\0.json"] {
            var invalid = smoke("owned-srgb8"); invalid["PICSHOT_SMOKE_REPORT"] = raw
            XCTAssertThrowsError(try RendererStorageConfiguration.selection(environment: invalid))
        }
        let configuration = RendererStorageConfiguration(environment: smoke("native"))
        var changed = smoke("native"); changed["PICSHOT_RENDERER_STORAGE_STRATEGY"] = "owned-srgb8"
        XCTAssertEqual(try configuration.selectedStrategy(), .native)
        XCTAssertEqual(try RendererStorageConfiguration(environment: changed).selectedStrategy(), .ownedSRGB8)
    }

    func testAllEligibleLayoutsPaddedRowsLowAlphaIntentsAndInterpolationMatchIndependentBytes() throws {
        let layouts: [CGImageAlphaInfo] = [.none, .first, .last, .premultipliedFirst, .premultipliedLast, .noneSkipFirst, .noneSkipLast]
        let intents: [CGColorRenderingIntent] = [.defaultIntent, .absoluteColorimetric, .relativeColorimetric, .perceptual, .saturation]
        for alpha in layouts {
            let orders: [CGBitmapInfo] = alpha == .none ? [.byteOrderDefault] : [.byteOrderDefault, .byteOrder32Big, .byteOrder32Little]
            for order in orders { for intent in intents { for interpolate in [false, true] {
                let fixture = try source(alpha: alpha, order: order, intent: intent, interpolate: interpolate)
                let original = try providerBytes(fixture)
                let expected = try referenceBytes(fixture, annotations: [])
                for strategy in RendererStorageStrategy.allCases {
                    let configuration = RendererStorageConfiguration(strategy: strategy)
                    try autoreleasepool {
                        let result = try render(fixture, configuration: configuration)
                        try assertBytes(result, expected)
                        XCTAssertFalse(result === fixture)
                        XCTAssertEqual(configuration.tracker.snapshot().nativeCount, strategy == .native ? 1 : 0)
                        XCTAssertEqual(configuration.tracker.snapshot().eligibleCount, strategy == .ownedSRGB8 ? 1 : 0)
                    }
                    assertBalanced(configuration.tracker, allocations: strategy == .ownedSRGB8 ? 1 : 0,
                        callbacks: strategy == .ownedSRGB8 ? 1 : 0)
                    XCTAssertEqual(configuration.tracker.snapshot().publishCount, 1)
                }
                XCTAssertEqual(try providerBytes(fixture), original)
                XCTAssertEqual(fixture.renderingIntent, intent); XCTAssertEqual(fixture.shouldInterpolate, interpolate)
                XCTAssertEqual(fixture.bytesPerRow, 6 * (alpha == .none ? 3 : 4) + 16)
            } } }
        }
    }

    func testFinalOwnedImageMetadataMatchesNativeContextOutput() throws {
        for interpolate in [false, true] {
            let source = try source(intent: .saturation, interpolate: interpolate)
            let native = try render(source, configuration: .init(strategy: .native))
            let candidate = try render(source, configuration: .init(strategy: .ownedSRGB8))
            XCTAssertEqual(candidate.width, native.width); XCTAssertEqual(candidate.height, native.height)
            XCTAssertEqual(candidate.bitsPerComponent, native.bitsPerComponent)
            XCTAssertEqual(candidate.bitsPerPixel, native.bitsPerPixel); XCTAssertEqual(candidate.bytesPerRow, native.bytesPerRow)
            XCTAssertEqual(candidate.bitmapInfo, native.bitmapInfo)
            XCTAssertEqual(candidate.colorSpace?.name, native.colorSpace?.name)
            XCTAssertEqual(candidate.renderingIntent, native.renderingIntent)
            XCTAssertEqual(candidate.shouldInterpolate, native.shouldInterpolate)
            XCTAssertNil(candidate.decode); XCTAssertFalse(candidate.isMask)
        }
    }

    func testUnsupportedP3SixteenBitLinearAndCustomProfilesUseExactNativePath() throws {
        let sRGB = try color(), p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let custom = try XCTUnwrap(CGColorSpace(iccData: XCTUnwrap(p3.copyICCData())))
        let colors = [sRGB, p3, try XCTUnwrap(CGColorSpace(name: CGColorSpace.linearSRGB)), CGColorSpaceCreateDeviceRGB(), custom]
        for color in colors { for depth in [8, 16] where depth == 16 || color.name != CGColorSpace.sRGB {
            let source = try source(depth: depth, order: depth == 8 ? .byteOrder32Big : .byteOrder16Big, color: color)
            let original = try providerBytes(source), profile = source.colorSpace?.copyICCData() as Data?
            let reference = try referenceBytes(source, annotations: [])
            let configuration = RendererStorageConfiguration(strategy: .ownedSRGB8,
                limits: .init(maximumDimension: 1, maximumOwnedBytes: 1, maximumWorkingBytes: 1, maximumActiveOwnedBytes: 1),
                failureInjection: .provider)
            let result = try render(source, configuration: configuration)
            try assertBytes(result, reference)
            let counts = configuration.tracker.snapshot()
            XCTAssertEqual(counts.nativeCount, 1); XCTAssertEqual(counts.eligibleCount, 0)
            XCTAssertEqual(counts.unsupportedCounts.values.reduce(0, +), 1)
            XCTAssertEqual(counts.allocations, 0); XCTAssertEqual(counts.publishCount, 1)
            XCTAssertEqual(try providerBytes(source), original); XCTAssertEqual(source.bitsPerComponent, depth)
            XCTAssertEqual(source.colorSpace?.copyICCData() as Data?, profile)
        } }
    }

    func testDecodeArraysAndGraySourcesAlsoRetainNativePath() throws {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(repeating: 127, count: 16) as CFData))
        var decode: [CGFloat] = [1, 0, 0.2, 0.8, 0, 1]
        let remapped = try decode.withUnsafeMutableBufferPointer { values in
            try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: 8, space: color(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: values.baseAddress, shouldInterpolate: false, intent: .saturation))
        }
        let gray = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: 2, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        for image in [remapped, gray] {
            let configuration = RendererStorageConfiguration(strategy: .ownedSRGB8)
            try assertBytes(render(image, configuration: configuration), referenceBytes(image, annotations: []))
            XCTAssertEqual(configuration.tracker.snapshot().nativeCount, 1)
            XCTAssertEqual(configuration.tracker.snapshot().allocations, 0)
        }
    }

    func testVectorsErasureRedactionAndSpotlightMatchIndependentContextBytes() throws {
        let image = try pattern(), original = try providerBytes(image)
        for tool in [ImageEditorTool.rectangle, .ellipse, .arc, .sector, .freehand, .highlighter,
                     .line, .arrow, .polyline, .redact, .eraser, .spotlight] {
            var mark = annotation(tool, CGRect(x: 12, y: 9, width: 81, height: 57))
            mark.rotation = .pi / 11; mark.opacity = 0.65; mark.fillEnabled = true
            mark.fillColor = CGColor(srgbRed: 0.2, green: 0.7, blue: 0.8, alpha: 0.6)
            if tool == .eraser { mark.eraserMode = .rectangle }
            let marks = [annotation(.freehand, CGRect(x: 4, y: 10, width: 114, height: 69)), mark]
            let expected = try referenceBytes(image, annotations: marks)
            for strategy in RendererStorageStrategy.allCases {
                try assertBytes(render(image, marks, configuration: .init(strategy: strategy)), expected)
            }
        }
        XCTAssertEqual(try providerBytes(image), original)
    }

    func testRealBlurAndPixelateSequentialSnapshotsMatchIndependentContextBytes() throws {
        let image = try pattern()
        for tool in [ImageEditorTool.blur, .pixelate] {
            var first = annotation(tool, CGRect(x: 0, y: 0, width: 81, height: 59)); first.opacity = 0.65
            var second = annotation(tool, CGRect(x: 37, y: 23, width: 76, height: 61)); second.rotation = .pi / 7
            var eraser = annotation(.eraser, CGRect(x: 41, y: 19, width: 9, height: 79)); eraser.eraserMode = .rectangle
            let marks = [annotation(.rectangle, CGRect(x: 9, y: 13, width: 103, height: 65)), first, second, eraser]
            let expected = try referenceBytes(image, annotations: marks)
            let configuration = RendererStorageConfiguration(strategy: .ownedSRGB8)
            try autoreleasepool { try assertBytes(render(image, marks, configuration: configuration), expected) }
            assertBalanced(configuration.tracker, allocations: 1, callbacks: 1)
        }
    }

    func testOverlappingMosaicGroupsAndFollowingOrdinaryEffectsKeepSequentialSnapshots() throws {
        let image = try pattern()
        for tool in [ImageEditorTool.blur, .pixelate] {
            let first = annotation(tool, CGRect(x: 13, y: 17, width: 69, height: 43))
            let second = annotation(tool, CGRect(x: 51, y: 31, width: 63, height: 41))
            var following = annotation(.pixelate, CGRect(x: 27, y: 24, width: 88, height: 57)); following.lineWidth = 7
            let marks = [annotation(.rectangle, CGRect(x: 7, y: 9, width: 95, height: 69))] + group([first, second]) + [following]
            let expected = try referenceBytes(image, annotations: marks)
            let owned = try render(image, marks, configuration: .init(strategy: .ownedSRGB8))
            try assertBytes(owned, expected)
            let sequential = try referenceBytes(image, annotations: [marks[0], first, second, following])
            XCTAssertNotEqual(expected, sequential, "The overlapping fixture must distinguish grouped from sequential filtering")
        }
    }

    func testMagnifierBeforeAndAfterEffectsPreservesBaseAndSequentialSnapshots() throws {
        let image = try pattern(), original = try providerBytes(image)
        for showsAnnotations in [false, true] {
            var lens = annotation(.magnifier, CGRect(x: 67, y: 49, width: 48, height: 40))
            lens.magnifierShowsAnnotations = showsAnnotations
            let redaction = annotation(.redact, CGRect(x: 47, y: 39, width: 13, height: 17))
            let filters = group([annotation(.pixelate, CGRect(x: 15, y: 17, width: 71, height: 57)),
                                 annotation(.pixelate, CGRect(x: 43, y: 29, width: 69, height: 51))])
            for marks in [[lens, redaction], [annotation(.rectangle, CGRect(x: 7, y: 9, width: 87, height: 61))] + filters + [lens, redaction],
                          [lens] + filters + [lens, redaction]] {
                let expected = try referenceBytes(image, annotations: marks)
                try assertBytes(render(image, marks, configuration: .init(strategy: .ownedSRGB8)), expected)
            }
        }
        XCTAssertEqual(try providerBytes(image), original)
    }

    func testRetainedEffectInputsSurviveLaterDrawsAndOwnedOutputRelease() throws {
        for failAfterSnapshot in [false, true] {
            var retained: [(CIImage, CGRect, Data)] = []
            let configuration = RendererStorageConfiguration(strategy: .ownedSRGB8)
            try autoreleasepool {
                let image = try pattern()
                let marks = [annotation(.blur, CGRect(x: 13, y: 17, width: 69, height: 43)),
                             annotation(.redact, CGRect(x: 0, y: 0, width: 129, height: 101)),
                             annotation(.pixelate, CGRect(x: 17, y: 23, width: 83, height: 61))]
                let result = ImageEditorRenderer.render(image: image, annotations: marks,
                    drawingRaster: .init(strategy: .ownedSRGB8), rendererStorage: configuration,
                    effectPatchRenderer: { input, region in
                        guard let patch = ImageEditorRenderer.renderEffectPatch(input, region),
                              let expected = try? self.meaningfulBytes(patch) else { return nil }
                        retained.append((input, region, expected))
                        return failAfterSnapshot ? nil : patch
                    })
                if failAfterSnapshot { XCTAssertNil(result) } else { XCTAssertNotNil(result) }
            }
            // Both source and final output are now gone. Any externally retained
            // immutable effect input must still represent its original snapshot.
            XCTAssertEqual(retained.count, failAfterSnapshot ? 1 : 2)
            for (input, region, expected) in retained {
                let patch = try XCTUnwrap(ImageEditorRenderer.renderEffectPatch(input, region))
                XCTAssertEqual(try meaningfulBytes(patch), expected)
            }
            retained.removeAll()
            assertBalanced(configuration.tracker, allocations: 1, callbacks: failAfterSnapshot ? 0 : 1)
        }
    }

    func testEffectFailureAfterSuccessfulPatchDiscardsPartiallyDrawnOwnedBytes() throws {
        let image = try pattern()
        let marks = group([annotation(.blur, CGRect(x: 7, y: 9, width: 49, height: 47)),
                           annotation(.blur, CGRect(x: 43, y: 29, width: 69, height: 51))])
        let configuration = RendererStorageConfiguration(strategy: .ownedSRGB8)
        var calls = 0
        autoreleasepool {
            XCTAssertNil(ImageEditorRenderer.render(image: image, annotations: marks,
                drawingRaster: .init(strategy: .ownedSRGB8), rendererStorage: configuration,
                effectPatchRenderer: { input, region in
                    calls += 1
                    return calls == 1 ? ImageEditorRenderer.renderEffectPatch(input, region) : nil
                }))
        }
        XCTAssertEqual(calls, 2)
        let counts = configuration.tracker.snapshot()
        XCTAssertEqual(counts.seedCount, 1); XCTAssertEqual(counts.drawCount, 0)
        XCTAssertEqual(counts.publishCount, 0); XCTAssertEqual(counts.failureCount, 1)
        assertBalanced(configuration.tracker, allocations: 1, callbacks: 0)
    }

    func testDrawingConversionFailureAndInvalidConfigurationNeverFallback() throws {
        let image = try source()
        let configuration = RendererStorageConfiguration(strategy: .ownedSRGB8)
        autoreleasepool {
            XCTAssertNil(ImageEditorRenderer.render(image: image, annotations: [],
                drawingRaster: .init(strategy: .ownedSRGB8, failureInjection: .conversion), rendererStorage: configuration))
        }
        XCTAssertEqual(configuration.tracker.snapshot().nativeCount, 0)
        XCTAssertEqual(configuration.tracker.snapshot().publishCount, 0)
        XCTAssertEqual(configuration.tracker.snapshot().failureCount, 1)
        assertBalanced(configuration.tracker, allocations: 1, callbacks: 0)
        let invalid = RendererStorageConfiguration(environment: smoke("invalid"))
        XCTAssertNil(ImageEditorRenderer.render(image: image, annotations: [], rendererStorage: invalid))
        XCTAssertEqual(invalid.tracker.snapshot().attemptCount, 1)
        XCTAssertEqual(invalid.tracker.snapshot().failureCount, 1)
        XCTAssertEqual(invalid.tracker.snapshot().allocations, 0)
    }

    func testEveryInjectedOwnershipFailureReleasesExactlyOnceWithoutPublication() throws {
        let image = try source(), count = image.width * image.height * 4
        for injection in [RendererStorage.FailureInjection.allocation, .context, .seed, .draw, .provider, .image] {
            let configuration = RendererStorageConfiguration(strategy: .ownedSRGB8,
                limits: .init(maximumActiveOwnedBytes: count), failureInjection: injection)
            autoreleasepool {
                XCTAssertNil(ImageEditorRenderer.render(image: image, annotations: [],
                    drawingRaster: .init(strategy: .ownedSRGB8), rendererStorage: configuration))
            }
            let counts = configuration.tracker.snapshot()
            XCTAssertEqual(counts.attemptCount, 1); XCTAssertEqual(counts.eligibleCount, 1)
            XCTAssertEqual(counts.nativeCount, 0); XCTAssertEqual(counts.publishCount, 0); XCTAssertEqual(counts.failureCount, 1)
            assertBalanced(configuration.tracker, allocations: injection == .allocation ? 0 : 1, callbacks: injection == .image ? 1 : 0)
            // A leaked reservation must not survive even a pre-calloc failure.
            let recovery = RendererStorageConfiguration(strategy: .ownedSRGB8,
                limits: .init(maximumActiveOwnedBytes: count), tracker: configuration.tracker)
            try autoreleasepool { _ = try render(image, configuration: recovery) }
            XCTAssertEqual(recovery.tracker.snapshot().publishCount, 1)
            assertBalanced(recovery.tracker, allocations: injection == .allocation ? 1 : 2,
                callbacks: injection == .image ? 2 : 1)
        }
    }

    func testCancellationAtEveryOwnedFenceDiscardsImageAndBalancesProviderTransfer() throws {
        let image = try source()
        for fence in 1...9 {
            let configuration = RendererStorageConfiguration(strategy: .ownedSRGB8)
            var calls = 0
            try autoreleasepool {
                XCTAssertThrowsError(try RendererStorage.render(image: image, annotations: [], configuration: configuration,
                    drawingRaster: .init(strategy: .ownedSRGB8), isCancelled: { calls += 1; return calls == fence })) {
                    XCTAssertEqual($0 as? RendererStorage.Failure, .cancelled)
                }
            }
            XCTAssertEqual(calls, fence)
            XCTAssertEqual(configuration.tracker.snapshot().publishCount, 0)
            XCTAssertEqual(configuration.tracker.snapshot().failureCount, 1)
            assertBalanced(configuration.tracker, allocations: fence == 1 ? 0 : 1, callbacks: fence == 9 ? 1 : 0)
        }
    }

    func testOwnedImageIsDetachedFromMutableSourceAndSubsequentRenders() throws {
        let context = try bitmap(width: 41, height: 29)
        context.setFillColor(CGColor(srgbRed: 0.8, green: 0.2, blue: 0.4, alpha: 0.7)); context.fill(CGRect(x: 0, y: 0, width: 41, height: 29))
        let configuration = RendererStorageConfiguration(strategy: .ownedSRGB8)
        try autoreleasepool {
            let source = try XCTUnwrap(context.makeImage())
            let result = try render(source, configuration: configuration), before = try providerBytes(result)
            context.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 41, height: 29))
            let changed = try XCTUnwrap(context.makeImage())
            let next = try render(changed, configuration: configuration)
            XCTAssertNotEqual(try providerBytes(next), before)
            XCTAssertEqual(try providerBytes(result), before)
            XCTAssertEqual(configuration.tracker.snapshot().activeBytes, 41 * 29 * 4 * 2)
        }
        assertBalanced(configuration.tracker, allocations: 2, callbacks: 2)
    }

    func testProviderAloneKeepsOwnedStorageAliveUntilLastReferenceIsReleased() throws {
        let image = try source(), count = image.width * image.height * 4
        let configuration = RendererStorageConfiguration(strategy: .ownedSRGB8)
        var provider: CGDataProvider?
        try autoreleasepool {
            let result = try render(image, configuration: configuration)
            provider = result.dataProvider
        }
        XCTAssertEqual(configuration.tracker.snapshot().activeBytes, count)
        XCTAssertEqual(configuration.tracker.snapshot().releaseCallbacks, 0)
        // Drain temporary CFData/bridge observations before testing the last
        // explicit provider reference. Reading provider data can itself retain
        // autoreleased objects until the surrounding pool ends.
        try autoreleasepool {
            let observed = try XCTUnwrap(provider?.data) as Data
            XCTAssertEqual(observed.count, count)
        }
        XCTAssertEqual(configuration.tracker.snapshot().activeBytes, count)
        XCTAssertEqual(configuration.tracker.snapshot().releaseCallbacks, 0)
        provider = nil
        assertBalanced(configuration.tracker, allocations: 1, callbacks: 1)
    }

    func testPublishedProviderDoesNotRetainOriginalSourceProvider() throws {
        let known = try source(), raw = try providerBytes(known), expected = try referenceBytes(known, annotations: [])
        let released = RendererStorageSourceReleaseProbe()
        let configuration = RendererStorageConfiguration(strategy: .ownedSRGB8)
        try autoreleasepool {
            let result = try autoreleasepool { () -> CGImage in
                let pointer = UnsafeMutableRawPointer.allocate(byteCount: raw.count, alignment: 16)
                raw.withUnsafeBytes { pointer.copyMemory(from: $0.baseAddress!, byteCount: raw.count) }
                let retained = Unmanaged.passRetained(released)
                guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: pointer, size: raw.count,
                    releaseData: { info, data, _ in
                        UnsafeMutableRawPointer(mutating: data).deallocate()
                        guard let info else { return }
                        Unmanaged<RendererStorageSourceReleaseProbe>.fromOpaque(info).takeRetainedValue().callbacks += 1
                    }) else { pointer.deallocate(); retained.release(); throw RendererStorage.Failure.providerFailed }
                let source = try XCTUnwrap(CGImage(width: known.width, height: known.height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: known.bytesPerRow, space: color(), bitmapInfo: known.bitmapInfo,
                    provider: provider, decode: nil, shouldInterpolate: false, intent: known.renderingIntent))
                return try render(source, configuration: configuration)
            }
            XCTAssertEqual(released.callbacks, 1)
            try assertBytes(result, expected)
        }
        assertBalanced(configuration.tracker, allocations: 1, callbacks: 1)
    }

    func testActiveBudgetCoversPublishedImagesAndReopensAfterFinalRelease() throws {
        let image = try source(), count = image.width * image.height * 4
        let configuration = RendererStorageConfiguration(strategy: .ownedSRGB8, limits: .init(maximumActiveOwnedBytes: count))
        try autoreleasepool {
            let first = try render(image, configuration: configuration)
            XCTAssertNil(ImageEditorRenderer.render(image: image, annotations: [], rendererStorage: configuration))
            XCTAssertEqual(configuration.tracker.snapshot().activeBytes, count)
            withExtendedLifetime(first) { }
        }
        try autoreleasepool { _ = try render(image, configuration: configuration) }
        XCTAssertEqual(configuration.tracker.snapshot().publishCount, 2)
        XCTAssertEqual(configuration.tracker.snapshot().failureCount, 1)
        XCTAssertEqual(configuration.tracker.snapshot().peakActiveBytes, count)
        assertBalanced(configuration.tracker, allocations: 2, callbacks: 2)
    }

    func testAdmissionChecksDimensionsPaddedSourceWorkingSetAndEveryOverflow() throws {
        let source = try source(), count = source.width * source.height * 4
        let work = source.bytesPerRow * source.height + count
        XCTAssertEqual(try RendererStorage.admittedStorage(width: source.width, height: source.height,
            sourceBytesPerRow: source.bytesPerRow, sourceBitsPerPixel: source.bitsPerPixel,
            limits: .init(maximumOwnedBytes: count, maximumWorkingBytes: work, maximumActiveOwnedBytes: count)), count)
        for limits in [RendererStorage.Limits(maximumDimension: 2), .init(maximumOwnedBytes: count - 1),
                       .init(maximumWorkingBytes: work - 1), .init(maximumActiveOwnedBytes: count - 1)] {
            let configuration = RendererStorageConfiguration(strategy: .ownedSRGB8, limits: limits)
            XCTAssertNil(ImageEditorRenderer.render(image: source, annotations: [], rendererStorage: configuration))
            XCTAssertEqual(configuration.tracker.snapshot().allocations, 0)
            XCTAssertEqual(configuration.tracker.snapshot().eligibleCount, 1)
            XCTAssertEqual(configuration.tracker.snapshot().failureCount, 1)
        }
        for input in [(Int.max, 1, Int.max, 32), (1, Int.max, 4, 32), (1, 2, Int.max, 32),
                      (1, 1, 4, Int.max), (1, 1, Int.max, 32)] {
            XCTAssertThrowsError(try RendererStorage.admittedStorage(width: input.0, height: input.1,
                sourceBytesPerRow: input.2, sourceBitsPerPixel: input.3, limits: .standard)) {
                XCTAssertEqual($0 as? RendererStorage.Failure, .storageOverflow)
            }
        }
        for input in [(0, 1, 4, 32), (1, -1, 4, 32), (3, 2, 1, 32), (1, 1, 4, 0)] {
            XCTAssertThrowsError(try RendererStorage.admittedStorage(width: input.0, height: input.1,
                sourceBytesPerRow: input.2, sourceBitsPerPixel: input.3, limits: .standard)) {
                XCTAssertEqual($0 as? RendererStorage.Failure, .invalidBounds)
            }
        }
    }

    func testConcurrentRendersShareOneScalarAdmissionBudget() throws {
        let image = try source(), count = image.width * image.height * 4
        let configuration = RendererStorageConfiguration(strategy: .ownedSRGB8, limits: .init(maximumActiveOwnedBytes: count * 2))
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            autoreleasepool {
                _ = ImageEditorRenderer.render(image: image, annotations: [],
                    drawingRaster: .init(strategy: .ownedSRGB8), rendererStorage: configuration)
            }
        }
        let state = configuration.tracker.snapshot()
        XCTAssertEqual(state.attemptCount, 32); XCTAssertEqual(state.eligibleCount, 32)
        XCTAssertEqual(state.publishCount + state.failureCount, 32)
        XCTAssertGreaterThan(state.publishCount, 0); XCTAssertLessThanOrEqual(state.peakActiveBytes, count * 2)
        assertBalanced(configuration.tracker, allocations: state.publishCount, callbacks: state.publishCount)
    }

    private func render(_ source: CGImage, _ annotations: [ImageAnnotation] = [], configuration: RendererStorageConfiguration) throws -> CGImage {
        try XCTUnwrap(ImageEditorRenderer.render(image: source, annotations: annotations,
            drawingRaster: .init(strategy: .ownedSRGB8), rendererStorage: configuration))
    }
    private func smoke(_ strategy: String) -> [String: String] {
        ["PICSHOT_RENDERER_STORAGE_STRATEGY": strategy, "PICSHOT_SMOKE_TEST": "1", "PICSHOT_SMOKE_REPORT": "/tmp/renderer-report.json"]
    }
    private func color() throws -> CGColorSpace { try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)) }
    private func bitmap(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: color(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    }
    private func referenceBytes(_ image: CGImage, annotations: [ImageAnnotation]) throws -> Data {
        let context = try bitmap(width: image.width, height: image.height)
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: extent)
        XCTAssertTrue(ImageEditorRenderer.drawAnnotations(annotations, in: context, extent: extent, baseImage: image))
        return Data(bytes: try XCTUnwrap(context.data), count: context.bytesPerRow * context.height)
    }
    private func providerBytes(_ image: CGImage) throws -> Data { try XCTUnwrap(XCTUnwrap(image.dataProvider).data) as Data }
    private func meaningfulBytes(_ image: CGImage) throws -> Data {
        let raw = try providerBytes(image), rowCount = (image.width * image.bitsPerPixel + 7) / 8
        var rows = Data()
        for y in 0..<image.height { rows.append(raw[(y * image.bytesPerRow)..<(y * image.bytesPerRow + rowCount)]) }
        return rows
    }
    private func assertBytes(_ image: CGImage, _ expected: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(image.bitsPerComponent, 8, file: file, line: line)
        XCTAssertEqual(image.bitsPerPixel, 32, file: file, line: line)
        XCTAssertEqual(image.bitmapInfo, RendererStorage.bitmapInfo, file: file, line: line)
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB, file: file, line: line)
        let raw = try providerBytes(image)
        XCTAssertGreaterThanOrEqual(raw.count, image.bytesPerRow * image.height, file: file, line: line)
        guard raw.count >= image.bytesPerRow * image.height else { return }
        var rows = Data()
        for y in 0..<image.height { rows.append(raw[(y * image.bytesPerRow)..<(y * image.bytesPerRow + image.width * 4)]) }
        XCTAssertEqual(rows, expected, file: file, line: line)
    }
    private func assertBalanced(_ tracker: RendererStorageTracker, allocations: Int, callbacks: Int,
        file: StaticString = #filePath, line: UInt = #line) {
        let state = tracker.snapshot()
        XCTAssertEqual(state.allocations, allocations, file: file, line: line)
        XCTAssertEqual(state.deallocations, allocations, file: file, line: line)
        XCTAssertEqual(state.releaseCallbacks, callbacks, file: file, line: line)
        XCTAssertEqual(state.activeBytes, 0, file: file, line: line)
        XCTAssertEqual(state.allocatedBytes, state.deallocatedBytes, file: file, line: line)
        XCTAssertTrue(state.callbackSizesMatch, file: file, line: line)
    }
    private func annotation(_ tool: ImageEditorTool, _ rect: CGRect) -> ImageAnnotation {
        ImageAnnotation(tool: tool, points: [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)], lineWidth: 3)
    }
    private func group(_ annotations: [ImageAnnotation]) -> [ImageAnnotation] {
        let group = UUID(), addition = UUID(), targets = annotations.map(\.localBounds)
        return annotations.map { value in
            var mark = value
            mark.mosaicLink = AutomaticMosaicLink(groupID: group, additionID: addition, rootAdditionID: addition,
                target: mark.localBounds, includedTargets: targets, excludedTargets: [], synchronizes: true)
            return mark
        }
    }
    private func pattern() throws -> CGImage {
        let width = 129, height = 101, context = try bitmap(width: width, height: height)
        let bytes = try XCTUnwrap(context.data?.assumingMemoryBound(to: UInt8.self))
        for y in 0..<height { for x in 0..<width {
            let offset = (y * width + x) * 4, a = 64 + (x * 7 + y * 13) % 192
            bytes[offset] = UInt8(((x * 19 + y * 3) % 256) * a / 255)
            bytes[offset + 1] = UInt8(((x * 5 + y * 23) % 256) * a / 255)
            bytes[offset + 2] = UInt8(((x * 31 + y * 11) % 256) * a / 255)
            bytes[offset + 3] = UInt8(a)
        } }
        return try XCTUnwrap(context.makeImage())
    }
    private func source(depth: Int = 8, alpha: CGImageAlphaInfo = .last, order: CGBitmapInfo = .byteOrder32Big,
        color: CGColorSpace? = nil, intent: CGColorRenderingIntent = .absoluteColorimetric, interpolate: Bool = false) throws -> CGImage {
        let width = 6, height = 3, channels = alpha == .none ? 3 : 4, sampleBytes = depth / 8
        let row = width * channels * sampleBytes + 16
        var raw = Data(repeating: 0xB7, count: row * height)
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
                let offset = y * row + (x * channels + component) * sampleBytes
                if depth == 8 { raw[offset] = UInt8(value) }
                else { raw[offset] = UInt8(value >> 8); raw[offset + 1] = UInt8(value & 255) }
            }
        } }
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: depth, bitsPerPixel: channels * depth,
            bytesPerRow: row, space: color ?? self.color(), bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue | order.rawValue),
            provider: XCTUnwrap(CGDataProvider(data: raw as CFData)), decode: nil, shouldInterpolate: interpolate, intent: intent))
    }
}

private final class RendererStorageSourceReleaseProbe { var callbacks = 0 }
