import XCTest
import Foundation
import CoreMedia
import CoreVideo
import CoreGraphics
import ImageIO
@testable import PicShot

@MainActor
final class RecordingInputExportTests: XCTestCase {
    private typealias Oracle = RecordingInputExportOracle

    func testInteriorSelectionAndSamplingIncludeExpiryResumeAndFrozenStop() throws {
        let range = try VideoTrimRange(start: Oracle.start, end: Oracle.end, sourceDuration: 2.2)
        XCTAssertGreaterThan(range.start, 0)
        XCTAssertLessThan(range.end, 2.2)
        XCTAssertEqual(range.duration, 2.05, accuracy: 0.000001)
        XCTAssertEqual(Oracle.sampleTime(0).value, 0)
        XCTAssertEqual(Oracle.sampleTime(40).seconds + range.start, 2.1, accuracy: 0.000001)
        let plan = try GIFFramePlan(duration: range.duration, options: RecordingInputExportSmokeFixture.gifOptions)
        XCTAssertEqual(plan.frameCount, 41)
        for index in 0..<41 {
            XCTAssertEqual(plan.samplingTime(for: index), Oracle.sampleTime(index))
            XCTAssertEqual(plan.delay(for: index) * 1_000, Double(Oracle.delayMS(index, format: .gif)), accuracy: 0.0001)
            XCTAssertEqual(Oracle.delayMS(index, format: .webpLossless), 50)
            XCTAssertEqual(Oracle.delayMS(index, format: .webpLossy), 50)
        }
        XCTAssertEqual((0..<41).reduce(0) { $0 + Oracle.delayMS($1, format: .gif) }, 2_050)
        for lossless in [true, false] {
            let options = RecordingInputExportSmokeFixture.options(lossless: lossless)
            try options.validate()
            XCTAssertEqual(options.animation?.maximumFrames, 41)
            XCTAssertEqual(options.animation?.maximumDimension, 320)
            XCTAssertEqual(options.animation?.maximumDuration, 3)
            XCTAssertEqual(options.lossless, lossless)
        }
        // Exercise native GIF metadata in this existing ID. The logical screen
        // and each indexed image must agree, even if global image keys are absent.
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("canvas.gif")
        let provider = try XCTUnwrap(CGDataProvider(data: Data(raster()) as CFData))
        let image = try XCTUnwrap(CGImage(width: Oracle.width, height: Oracle.height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Oracle.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        try GIFSingleFrame.requireOpaque(image)
        let still = try GIFSingleFrame.encode(image: image)
        let writer = try GIFStreamingWriter(url: url)
        for _ in 0..<41 { try writer.append(singleFrameGIF: still, delay: 0.05) }
        try writer.finish()
        var metadata: [String: Any] = [:]
        let decoder = try Oracle.gifContainer(Data(contentsOf: url)) { metadata = $0 }
        XCTAssertEqual(metadata["logicalScreenWidth"] as? Int, 320)
        XCTAssertEqual(metadata["logicalScreenHeight"] as? Int, 180)
        XCTAssertEqual(metadata["imageCount"] as? Int, 41)
        XCTAssertEqual((metadata["loopCount"] as? NSNumber)?.intValue, 0)
        for index in 0..<41 {
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(decoder, index, nil) as? [CFString: Any])
            XCTAssertNoThrow(try Oracle.gifFrameDimensions(properties, index: index))
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoder, index, nil))
            XCTAssertNoThrow(try Oracle.raster(decoded))
        }
        XCTAssertThrowsError(try Oracle.gifContainer(still), "A single image cannot satisfy the 41-frame gate")
        var changed = try Data(contentsOf: url)
        let loop = try XCTUnwrap(changed.range(of: Data("NETSCAPE2.0".utf8)))
        changed[loop.upperBound + 2] = 1
        XCTAssertThrowsError(try Oracle.gifContainer(changed) { metadata = $0 })
        XCTAssertEqual((metadata["loopCount"] as? NSNumber)?.intValue, 1,
                       "Actual native metadata must survive a failed assertion")
    }

    func testPixelOracleUsesTopDownRGBAAndDetectsEffectRelocationAndExpiry() throws {
        var pixels = raster()
        paint(&pixels, x: 70, y: 95, width: 10, height: 10, color: [230, 170, 40])
        let reference = try observe(pixels)
        XCTAssertEqual(reference.regions["click"]?.yellow.count, 100)
        XCTAssertEqual(reference.regions["click"]?.yellow.x, 74.5)
        XCTAssertEqual(reference.regions["click"]?.yellow.y, 99.5)
        XCTAssertNoThrow(try Oracle.compare(reference, to: reference))
        XCTAssertThrowsError(try Oracle.compare(observe(raster()), to: reference), "Absent click must not pass lossy tolerance")
        var shifted = raster()
        paint(&shifted, x: 85, y: 95, width: 10, height: 10, color: [230, 170, 40])
        XCTAssertThrowsError(try Oracle.compare(observe(shifted), to: reference), "Same color count at wrong location must fail")
        XCTAssertThrowsError(try Oracle.compare(reference, to: observe(raster())), "Expired frame must reject a stale click")
        var reflected = raster()
        paint(&reflected, x: 70, y: 180 - 95 - 10, width: 10, height: 10, color: [230, 170, 40])
        XCTAssertThrowsError(try Oracle.compare(observe(reflected), to: reference), "Vertical reflection must fail")
    }

    func testScalarTimelineRejectsFirstFrameOnlyWrongBoundaryAndMissingResume() throws {
        // Marker-only CMSampleBuffers are control messages, not media frames.
        // Exercise actual CoreMedia buffers without changing this test's ID.
        func marker(duration: CMTime = .invalid, withTiming: Bool = true,
                    pts: CMTime = CMTime(value: 22, timescale: 10)) throws -> CMSampleBuffer {
            var result: CMSampleBuffer?
            var timing = CMSampleTimingInfo(duration: duration,
                presentationTimeStamp: pts, decodeTimeStamp: .invalid)
            let status = withUnsafePointer(to: &timing) { pointer in
                CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil,
                    dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: nil,
                    sampleCount: 0, sampleTimingEntryCount: withTiming ? 1 : 0,
                    sampleTimingArray: withTiming ? pointer : nil,
                    sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result)
            }
            XCTAssertEqual(status, noErr)
            return try XCTUnwrap(result)
        }
        // ARM162's source reader emits this unmarked empty buffer before frame 0.
        let initial = try marker(duration: .zero, pts: CMTime(value: 0, timescale: 600))
        XCTAssertTrue(try Oracle.isControlMarker(initial, context: "unmarked-initial-control"))
        let initialDiagnostic = Oracle.sampleTimingDescription(initial, route: "source", phase: "compressed",
            buffer: 0, media: 0, expected: 22)
        XCTAssertTrue(initialDiagnostic.contains("samples=0 sampleBytes=0 dataBytes=0 imagePresent=false"))
        XCTAssertTrue(initialDiagnostic.contains("sampleDuration=0/1:flags=1"))
        XCTAssertTrue(initialDiagnostic.contains("empty=absent endsPrevious=absent permanentEmpty=absent"))
        let empty = try marker()
        XCTAssertTrue(try Oracle.isControlMarker(empty, context: "unmarked"))
        CMSetAttachment(empty, key: kCMSampleBufferAttachmentKey_EndsPreviousSampleDuration,
                        value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        XCTAssertTrue(try Oracle.isControlMarker(empty, context: "end-duration-marker"))
        let diagnostic = Oracle.sampleTimingDescription(empty, route: "source", phase: "compressed",
            buffer: 22, media: 22, expected: 22)
        XCTAssertTrue(diagnostic.contains("route=source phase=compressed buffer=22 mediaSeen=22 expectedPresented=22"))
        XCTAssertTrue(diagnostic.contains("samples=0 sampleBytes=0 dataBytes=0"))
        XCTAssertTrue(diagnostic.contains("endsPrevious=true"))
        XCTAssertTrue(diagnostic.contains("timingEntries=1 timingStatus=0"))
        XCTAssertTrue(diagnostic.contains("sampleDuration=0/0:flags=0"), "The raw invalid timing entry must remain visible")
        CMSetAttachment(empty, key: kCMSampleBufferAttachmentKey_EndsPreviousSampleDuration,
                        value: NSNumber(value: 2), attachmentMode: kCMAttachmentMode_ShouldPropagate)
        XCTAssertThrowsError(try Oracle.isControlMarker(empty, context: "non-Boolean-marker"))
        CMSetAttachment(empty, key: kCMSampleBufferAttachmentKey_EmptyMedia,
                        value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        XCTAssertThrowsError(try Oracle.isControlMarker(empty, context: "mixed-malformed-marker"))
        let gap = try marker(duration: CMTime(value: 1, timescale: 10))
        XCTAssertThrowsError(try Oracle.isControlMarker(gap, context: "unmarked-playback-gap"))
        CMSetAttachment(gap, key: kCMSampleBufferAttachmentKey_EmptyMedia,
                        value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        XCTAssertThrowsError(try Oracle.isControlMarker(gap, context: "actual-playback-gap"),
                             "A positive empty-media interval must never be hidden")
        let timingFree = try marker(withTiming: false)
        CMSetAttachment(timingFree, key: kCMSampleBufferAttachmentKey_PermanentEmptyMedia,
                        value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        XCTAssertTrue(try Oracle.isControlMarker(timingFree, context: "timing-free-end-marker"))
        XCTAssertEqual(CMSampleBufferInvalidate(timingFree), noErr)
        XCTAssertThrowsError(try Oracle.isControlMarker(timingFree, context: "invalidated-marker"))

        // Exercise CoreMedia's real attachment bridges and output-time APIs,
        // in the existing test method so the native inventory stays unchanged.
        func media(rawPTS: CMTime = CMTime(value: 21, timescale: 10)) throws -> CMSampleBuffer {
            var block: CMBlockBuffer?
            XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                memoryBlock: nil, blockLength: 1, blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil, offsetToData: 0, dataLength: 1, flags: 0,
                blockBufferOut: &block), noErr)
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 10),
                presentationTimeStamp: rawPTS, decodeTimeStamp: rawPTS)
            var size = 1
            var sample: CMSampleBuffer?
            XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                dataBuffer: try XCTUnwrap(block), formatDescription: nil, sampleCount: 1,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), noErr)
            return try XCTUnwrap(sample)
        }
        let lastPacket = try media()
        CMSetAttachment(lastPacket, key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd,
            value: CMTimeCopyAsDictionary(CMTime(value: 30, timescale: 600), allocator: kCFAllocatorDefault)!,
            attachmentMode: kCMAttachmentMode_ShouldPropagate)
        XCTAssertEqual(CMSampleBufferSetOutputPresentationTimeStamp(lastPacket, newValue: CMTime(value: 2, timescale: 1)), noErr)
        let lastTiming = try Oracle.packetTiming(lastPacket, detail: "synthetic-last-packet")
        XCTAssertEqual(lastTiming.rawPTS, 2.1, accuracy: 1.0 / 600)
        XCTAssertEqual(lastTiming.rawDuration, 0.1, accuracy: 1.0 / 600)
        XCTAssertEqual(lastTiming.outputPTS, 2, accuracy: 1.0 / 600)
        XCTAssertEqual(lastTiming.outputDuration, 0.05, accuracy: 1.0 / 600)
        XCTAssertEqual(lastTiming.trimEnd, 0.05, accuracy: 1.0 / 600)
        XCTAssertFalse(lastTiming.doNotDisplay)
        let hiddenPacket = try media(rawPTS: .zero)
        XCTAssertEqual(CMSampleBufferSetOutputPresentationTimeStamp(hiddenPacket, newValue: CMTime(value: -1, timescale: 10)), noErr)
        let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(hiddenPacket, createIfNecessary: true) as? [NSMutableDictionary])
        XCTAssertEqual(attachments.count, 1)
        let sampleFlags = try XCTUnwrap(attachments.first)
        sampleFlags[kCMSampleAttachmentKey_DoNotDisplay] = kCFBooleanTrue
        XCTAssertTrue(try Oracle.packetTiming(hiddenPacket, detail: "synthetic-preroll").doNotDisplay)
        sampleFlags[kCMSampleAttachmentKey_DoNotDisplay] = kCFBooleanFalse
        XCTAssertFalse(try Oracle.packetTiming(hiddenPacket, detail: "synthetic-visible").doNotDisplay)
        sampleFlags[kCMSampleAttachmentKey_DoNotDisplay] = NSNumber(value: 2)
        XCTAssertThrowsError(try Oracle.packetTiming(hiddenPacket, detail: "synthetic-malformed-flag"))
        sampleFlags.removeObject(forKey: kCMSampleAttachmentKey_DoNotDisplay)
        CMSetAttachment(hiddenPacket, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
            value: CMTimeCopyAsDictionary(CMTime(value: 1, timescale: 10), allocator: kCFAllocatorDefault)!,
            attachmentMode: kCMAttachmentMode_ShouldPropagate)
        XCTAssertEqual(CMSampleBufferSetOutputPresentationTimeStamp(hiddenPacket, newValue: .zero), noErr)
        let fullyTrimmed = try Oracle.packetTiming(hiddenPacket, detail: "synthetic-fully-trimmed")
        XCTAssertEqual(fullyTrimmed.outputDuration, 0)
        XCTAssertNoThrow(try Oracle.validateNonPresented(fullyTrimmed, selected: true))
        CMSetAttachment(hiddenPacket, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
            value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        XCTAssertThrowsError(try Oracle.packetTiming(hiddenPacket, detail: "synthetic-malformed-trim"))

        func presented(_ index: Int) -> Oracle.PacketTiming {
            .init(rawPTS: Double(index + 1) / 10, rawDuration: 0.1,
                  outputPTS: Double(index) / 10, outputDuration: index == 20 ? 0.05 : 0.1,
                  trimStart: 0, trimEnd: index == 20 ? 0.05 : 0, doNotDisplay: false)
        }
        let visible = (0..<21).map(presented)
        let preroll = Oracle.PacketTiming(rawPTS: 0, rawDuration: 0.1, outputPTS: -0.1,
            outputDuration: 0.1, trimStart: 0, trimEnd: 0, doNotDisplay: true)
        let packetSummary = try Oracle.verifyPacketTimeline([preroll] + visible, selected: true)
        XCTAssertEqual(packetSummary.storedCount, 22)
        XCTAssertEqual(packetSummary.presentedCount, 21)
        XCTAssertEqual(packetSummary.nonPresentedCount, 1)
        XCTAssertEqual(packetSummary.rawEnd, 2.2, accuracy: 1.0 / 600)
        XCTAssertEqual(packetSummary.presentationEnd, 2.05, accuracy: 1.0 / 600)
        XCTAssertEqual(packetSummary.finalPresentedDuration, 0.05, accuracy: 1.0 / 600)
        XCTAssertNoThrow(try Oracle.verifyPacketTimeline(visible, selected: true))
        let trimmedPreroll = Oracle.PacketTiming(rawPTS: 0, rawDuration: 0.1, outputPTS: 0,
            outputDuration: 0, trimStart: 0.1, trimEnd: 0, doNotDisplay: false)
        XCTAssertNoThrow(try Oracle.verifyPacketTimeline([trimmedPreroll] + visible, selected: true))
        let unflagged = Oracle.PacketTiming(rawPTS: 0, rawDuration: 0.1, outputPTS: -0.1,
            outputDuration: 0.1, trimStart: 0, trimEnd: 0, doNotDisplay: false)
        XCTAssertThrowsError(try Oracle.verifyPacketTimeline([unflagged] + visible, selected: true))
        let unexplainedZero = Oracle.PacketTiming(rawPTS: 0, rawDuration: 0.1, outputPTS: 0,
            outputDuration: 0, trimStart: 0, trimEnd: 0, doNotDisplay: false)
        XCTAssertThrowsError(try Oracle.verifyPacketTimeline([unexplainedZero] + visible, selected: true))
        XCTAssertThrowsError(try Oracle.verifyPacketTimeline([preroll, preroll] + visible, selected: true))
        var wrongEnd = visible
        wrongEnd[20] = .init(rawPTS: 2.1, rawDuration: 0.1, outputPTS: 2, outputDuration: 0.1,
            trimStart: 0, trimEnd: 0, doNotDisplay: false)
        XCTAssertThrowsError(try Oracle.verifyPacketTimeline([preroll] + wrongEnd, selected: true))

        for invalid in [
            Oracle.PacketTiming(rawPTS: 0, rawDuration: 0.1, outputPTS: .nan,
                outputDuration: 0.1, trimStart: 0, trimEnd: 0, doNotDisplay: true),
            Oracle.PacketTiming(rawPTS: 0, rawDuration: 0.1, outputPTS: -0.1,
                outputDuration: 0.1, trimStart: -.infinity, trimEnd: 0, doNotDisplay: true),
            Oracle.PacketTiming(rawPTS: 0, rawDuration: 0.1, outputPTS: -0.1,
                outputDuration: 0.1, trimStart: -0.1, trimEnd: 0.1, doNotDisplay: true),
            Oracle.PacketTiming(rawPTS: 0, rawDuration: 0.1, outputPTS: -0.1,
                outputDuration: 0.05, trimStart: 0, trimEnd: 0, doNotDisplay: true)
        ] {
            XCTAssertThrowsError(try Oracle.verifyPacketTimeline([invalid] + visible, selected: true))
        }
        var outputGap = visible
        outputGap[10] = .init(rawPTS: 1.1, rawDuration: 0.1, outputPTS: 1.02, outputDuration: 0.1,
            trimStart: 0, trimEnd: 0, doNotDisplay: false)
        XCTAssertThrowsError(try Oracle.verifyPacketTimeline([preroll] + outputGap, selected: true))
        XCTAssertThrowsError(try Oracle.verifyPacketTimeline(Array(visible.dropLast()), selected: true))
        XCTAssertNoThrow(try Oracle.verifyPacketTimeline(Array(([preroll] + visible).reversed()), selected: true),
                         "Compressed buffers may arrive in decode order")

        // ARM164 returned a ready source image at PTS zero with invalid raw
        // and output durations. Only compressed packets prove interval length.
        func imageSample(rawPTS: CMTime = .zero, outputPTS: CMTime = .zero,
                         duration: CMTime = .invalid, width: Int = Oracle.width) throws -> CMSampleBuffer {
            var pixels: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, Oracle.height,
                kCVPixelFormatType_32BGRA, nil, &pixels), kCVReturnSuccess)
            let image = try XCTUnwrap(pixels)
            var format: CMVideoFormatDescription?
            XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                imageBuffer: image, formatDescriptionOut: &format), noErr)
            var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: rawPTS, decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                imageBuffer: image, formatDescription: try XCTUnwrap(format),
                sampleTiming: &timing, sampleBufferOut: &sample), noErr)
            let result = try XCTUnwrap(sample)
            XCTAssertEqual(CMSampleBufferSetOutputPresentationTimeStamp(result, newValue: outputPTS), noErr)
            return result
        }
        func setDisplayFlag(_ sample: CMSampleBuffer, _ value: Any) throws {
            let flags = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary])
            let dictionary = try XCTUnwrap(flags.first)
            dictionary[kCMSampleAttachmentKey_DoNotDisplay] = value
        }
        let sourcePackets = try Oracle.verifyPacketTimeline((0..<22).map {
            Oracle.PacketTiming(rawPTS: Double($0) / 10, rawDuration: 0.1,
                outputPTS: Double($0) / 10, outputDuration: 0.1, trimStart: 0, trimEnd: 0, doNotDisplay: false)
        }, selected: false)
        let durationless = try imageSample()
        let decoded = try Oracle.decodedFrameTiming(durationless, selected: false, packets: sourcePackets,
                                                    detail: "ARM164-durationless-source-image")
        XCTAssertNoThrow(try Oracle.verifyDecodedPresented(decoded, index: 0, selected: false))
        XCTAssertFalse(decoded.nonPresented)
        XCTAssertFalse(CMSampleBufferGetDuration(durationless).isValid)
        XCTAssertFalse(CMSampleBufferGetOutputDuration(durationless).isValid,
                       "The oracle must not fabricate or write a decoded duration")
        XCTAssertThrowsError(try Oracle.packetTiming(durationless, detail: "compressed-duration-still-required"))
        XCTAssertThrowsError(try Oracle.decodedFrameTiming(lastPacket, selected: false, packets: sourcePackets,
                                                          detail: "data-is-not-a-decoded-image"))
        XCTAssertThrowsError(try Oracle.decodedFrameTiming(imageSample(width: 319), selected: false,
                                                          packets: sourcePackets, detail: "wrong-decoded-canvas"))
        for bad in [
            Oracle.DecodedFrameTiming(rawPTS: .nan, outputPTS: 0, prerollRawEnd: nil),
            Oracle.DecodedFrameTiming(rawPTS: 2.2, outputPTS: 0, prerollRawEnd: nil),
            Oracle.DecodedFrameTiming(rawPTS: 0, outputPTS: .nan, prerollRawEnd: nil),
            Oracle.DecodedFrameTiming(rawPTS: 0, outputPTS: -0.1, prerollRawEnd: nil),
            Oracle.DecodedFrameTiming(rawPTS: 0, outputPTS: 0.02, prerollRawEnd: nil)
        ] {
            XCTAssertThrowsError(try Oracle.verifyDecodedPresented(bad, index: 0, selected: false))
        }
        XCTAssertThrowsError(try Oracle.verifyDecodedPresented(decoded, index: 21, selected: true),
                             "A selected decoder may not present a 22nd image")
        let hiddenImage = try imageSample(outputPTS: CMTime(value: -1, timescale: 10))
        let unflaggedImage = try Oracle.decodedFrameTiming(hiddenImage, selected: true, packets: packetSummary,
                                                          detail: "negative-PTS-is-not-preroll-proof")
        XCTAssertFalse(unflaggedImage.nonPresented)
        XCTAssertThrowsError(try Oracle.verifyDecodedPresented(unflaggedImage, index: 0, selected: true))
        try setDisplayFlag(hiddenImage, NSNumber(value: true))
        let hiddenTiming = try Oracle.decodedFrameTiming(hiddenImage, selected: true, packets: packetSummary,
                                                         detail: "durationless-explicit-preroll")
        XCTAssertEqual(try XCTUnwrap(hiddenTiming.prerollRawEnd), 0.1, accuracy: 1.0 / 600)
        XCTAssertFalse(CMSampleBufferGetDuration(hiddenImage).isValid)
        XCTAssertThrowsError(try Oracle.decodedFrameTiming(hiddenImage, selected: false, packets: sourcePackets,
                                                          detail: "unexpected-source-preroll"))
        XCTAssertEqual(CMSampleBufferSetOutputPresentationTimeStamp(hiddenImage, newValue: CMTime(value: -1, timescale: 20)), noErr)
        XCTAssertThrowsError(try Oracle.decodedFrameTiming(hiddenImage, selected: true, packets: packetSummary,
                                                          detail: "unmatched-decoded-preroll"))
        let trimmedImage = try imageSample()
        CMSetAttachment(trimmedImage, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
            value: CMTimeCopyAsDictionary(CMTime(value: 1, timescale: 10), allocator: kCFAllocatorDefault)!,
            attachmentMode: kCMAttachmentMode_ShouldPropagate)
        let trimmedPackets = try Oracle.verifyPacketTimeline([trimmedPreroll] + visible, selected: true)
        XCTAssertTrue(try Oracle.decodedFrameTiming(trimmedImage, selected: true, packets: trimmedPackets,
                                                   detail: "durationless-fully-trimmed-preroll").nonPresented)
        let contradictoryTrim = try imageSample(duration: CMTime(value: 2, timescale: 10))
        CMSetAttachment(contradictoryTrim, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
            value: CMTimeCopyAsDictionary(CMTime(value: 1, timescale: 10), allocator: kCFAllocatorDefault)!,
            attachmentMode: kCMAttachmentMode_ShouldPropagate)
        XCTAssertThrowsError(try Oracle.decodedFrameTiming(contradictoryTrim, selected: true, packets: trimmedPackets,
                                                          detail: "positive-output-contradicts-full-trim"))
        XCTAssertThrowsError(try Oracle.decodedFrameTiming(imageSample(duration: .zero), selected: true,
                                                          packets: trimmedPackets, detail: "zero-duration-without-proof"))
        let finalImage = try imageSample(rawPTS: CMTime(value: 21, timescale: 10), outputPTS: CMTime(value: 2, timescale: 1))
        CMSetAttachment(finalImage, key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd,
            value: CMTimeCopyAsDictionary(CMTime(value: 1, timescale: 20), allocator: kCFAllocatorDefault)!,
            attachmentMode: kCMAttachmentMode_ShouldPropagate)
        let finalTiming = try Oracle.decodedFrameTiming(finalImage, selected: true, packets: packetSummary,
                                                        detail: "durationless-final-visible-image")
        XCTAssertNoThrow(try Oracle.verifyDecodedPresented(finalTiming, index: 20, selected: true))
        try setDisplayFlag(durationless, NSNumber(value: 2))
        XCTAssertThrowsError(try Oracle.decodedFrameTiming(durationless, selected: false, packets: sourcePackets,
                                                          detail: "malformed-decoded-display-flag"))
        try setDisplayFlag(durationless, NSNumber(value: false))
        CMSetAttachment(durationless, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
            value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        XCTAssertThrowsError(try Oracle.decodedFrameTiming(durationless, selected: false, packets: sourcePackets,
                                                          detail: "malformed-decoded-trim"))
        XCTAssertEqual(CMSampleBufferInvalidate(finalImage), noErr)
        XCTAssertThrowsError(try Oracle.decodedFrameTiming(finalImage, selected: true, packets: packetSummary,
                                                          detail: "invalidated-decoded-image"))

        var frames = (0..<41).map { index in
            Oracle.Comparison(index: index, requestedSeconds: Double(index) / 20,
                actualSeconds: Double(index / 2) / 10, sourceIndex: index / 2 + 1,
                delayMS: 50, regionMeanAbsoluteError: [:])
        }
        XCTAssertNoThrow(try Oracle.verifyTimeline(frames))
        XCTAssertThrowsError(try Oracle.verifyTimeline(Array(frames.prefix(1))))
        frames[40] = .init(index: 40, requestedSeconds: 2, actualSeconds: 1.9, sourceIndex: 20, delayMS: 50, regionMeanAbsoluteError: [:])
        XCTAssertThrowsError(try Oracle.verifyTimeline(frames), "Missing frozen Stop endpoint must fail")
        frames[40] = .init(index: 40, requestedSeconds: 2, actualSeconds: 2, sourceIndex: 21, delayMS: 50, regionMeanAbsoluteError: [:])
        for index in [38, 39] {
            frames[index] = .init(index: index, requestedSeconds: Double(index) / 20, actualSeconds: 1.8, sourceIndex: 19, delayMS: 50, regionMeanAbsoluteError: [:])
        }
        XCTAssertThrowsError(try Oracle.verifyTimeline(frames), "Missing post-pause clear frame must fail")
    }

    func testPixelComparisonRejectsChangedGlyphShapeAndOutOfRegionArtifacts() throws {
        let reference = raster()
        XCTAssertNoThrow(try reference.withUnsafeBufferPointer {
            try Oracle.pixelErrors($0, reference: reference, limit: 9, canvasLimit: 3)
        })
        var changed = reference
        paint(&changed, x: 118, y: 12, width: 84, height: 32, color: [240, 240, 240])
        XCTAssertThrowsError(try changed.withUnsafeBufferPointer {
            try Oracle.pixelErrors($0, reference: reference, limit: 18, canvasLimit: 6)
        })
        changed = reference
        // A large unexpected block outside all effect and anchor ROIs must be
        // caught by the whole-canvas comparison, not feature-count agreement.
        paint(&changed, x: 5, y: 5, width: 100, height: 60, color: [240, 0, 0])
        XCTAssertThrowsError(try changed.withUnsafeBufferPointer {
            try Oracle.pixelErrors($0, reference: reference, limit: 18, canvasLimit: 6)
        })
    }

    func testFixtureRefusesExistingDerivedWitnessBeforeReadingOrExportingSource() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in Oracle.mediaNames + [Oracle.reportName, Oracle.independentReportName] {
            let destination = directory.appendingPathComponent(name), sentinel = Data("owned elsewhere".utf8)
            try sentinel.write(to: destination)
            do { _ = try await RecordingInputExportSmokeFixture.verify(evidenceDirectory: directory); XCTFail("Existing derived witness accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains("Refusing to replace")) }
            XCTAssertEqual(try Data(contentsOf: destination), sentinel)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [name])
            try FileManager.default.removeItem(at: destination)
        }
    }

    func testFixtureRequiresAcceptedOriginalReportBeforeLaunchingHelpers() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let prior = directory.appendingPathComponent("recording-input.json")
        try JSONSerialization.data(withJSONObject: ["status": "failed", "decodedFrames": 22]).write(to: prior)
        do { _ = try await RecordingInputExportSmokeFixture.verify(evidenceDirectory: directory); XCTFail("Failed original evidence accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("original input fixture must pass")) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["recording-input.json"])
    }

    func testBoundedEvidenceRejectsSymlinksAndOversizedFiles() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source"), alias = directory.appendingPathComponent("alias")
        try Data(repeating: 1, count: 33).write(to: source)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        XCTAssertThrowsError(try Oracle.boundedData(alias))
        XCTAssertThrowsError(try Oracle.boundedData(source, maximum: 32))
        XCTAssertEqual(try Oracle.boundedData(source, maximum: 33).count, 33)
        let header = Data(Array("GIF89a".utf8) + [0x40, 0x01, 0xB4, 0, 0x70, 0, 0])
        XCTAssertEqual(try Oracle.gifCanvas(header).width, 320)
        XCTAssertEqual(try Oracle.gifCanvas(header).height, 180)
        var oldVersion = header; oldVersion[4] = 0x37
        XCTAssertNoThrow(try Oracle.gifCanvas(oldVersion))
        for count in 0..<13 { XCTAssertThrowsError(try Oracle.gifCanvas(Data(header.prefix(count)))) }
        var wrong = header; wrong[0] = 0
        XCTAssertThrowsError(try Oracle.gifCanvas(wrong))
        for offset in [6, 7, 8, 9] {
            wrong = header; wrong[offset] = 0xFF
            XCTAssertThrowsError(try Oracle.gifCanvas(wrong))
        }
        wrong = header; wrong[10] = 0x80
        XCTAssertThrowsError(try Oracle.gifCanvas(wrong), "A truncated declared global table must fail before ImageIO")
        wrong.append(contentsOf: [0, 0, 0, 255, 255, 255])
        XCTAssertNoThrow(try Oracle.gifCanvas(wrong))
        let invalidProperties: [[CFString: Any]] = [[:], [kCGImagePropertyPixelWidth: 319, kCGImagePropertyPixelHeight: 180],
                                                   [kCGImagePropertyPixelWidth: 320, kCGImagePropertyPixelHeight: "180"]]
        for properties in invalidProperties {
            XCTAssertThrowsError(try Oracle.gifFrameDimensions(properties, index: 0))
        }
    }

    /// Native write/trim/decode test uses actual RecordingWriter + compositor
    /// and AVAssetExportSession. Signed animation helpers are installed-only.
    func testAuthoredInputTrimPreservesAllSelectedPixelsAndPacketBoundaries() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await RecordingInputSmokeFixture.verify(evidenceDirectory: directory)
            let sourceURL = directory.appendingPathComponent("recording-input.mp4")
            let originalHash = try Oracle.hash(sourceURL)
            let deadline = ProcessInfo.processInfo.systemUptime + 60
            let original = try await Oracle.movie(sourceURL, selected: false, deadline: deadline)
            let output = directory.appendingPathComponent(Oracle.mediaNames[0])
            let range = try VideoTrimRange(start: Oracle.start, end: Oracle.end, sourceDuration: 2.2)
            _ = try await VideoTrimExporter.export(sourceURL: sourceURL, destinationURL: output, range: range)
            let selected = try await Oracle.movie(output, selected: true, source: original, deadline: deadline)
            XCTAssertEqual(selected.frameCount, 21)
            XCTAssertEqual(selected.observations.map(\.index), Array(1...21))
            XCTAssertEqual(selected.duration, 2.05, accuracy: 1.0 / 600)
            XCTAssertEqual(selected.packetTiming.presentedCount, 21)
            XCTAssertEqual(selected.packetTiming.nonPresentedCount, selected.packetTiming.storedCount - 21)
            XCTAssertLessThanOrEqual(selected.packetTiming.storedCount, 22)
            XCTAssertEqual(selected.packetTiming.presentationEnd, 2.05, accuracy: 1.0 / 600)
            XCTAssertEqual(selected.packetTiming.finalPresentedDuration, 0.05, accuracy: 1.0 / 600)
            XCTAssertEqual(try Oracle.hash(sourceURL), originalHash)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".picshot-") })
        } catch {
            let failure = error
            do { try preserveFailedMovies(directory, error: failure) }
            catch { print("[recording-input-failure] Could not retain bounded evidence: \(error.localizedDescription)") }
            throw failure
        }
    }

    /// Fixed destination, two <=4 MiB synthetic movies and one <=128 KiB
    /// report. Existing evidence is never replaced and temporary cleanup stays.
    private func preserveFailedMovies(_ directory: URL, error: Error) throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let parent = repository.appendingPathComponent("dist/evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let destination = parent.appendingPathComponent("recording-input-export-failure", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        var files: [[String: Any]] = []
        var bytes = 0
        for name in ["recording-input.mp4", Oracle.mediaNames[0]] {
            let source = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let data = try Oracle.boundedData(source)
            bytes += data.count
            try Oracle.require(bytes <= 2 * Oracle.maximumFileBytes, "Failure media exceeded its fixed total cap")
            try data.write(to: destination.appendingPathComponent(name), options: .withoutOverwriting)
            files.append(["file": name, "bytes": data.count, "sha256": try Oracle.hash(source)])
        }
        try Oracle.write(["status": "failed", "purpose": "synthetic native test diagnostic, not acceptance",
            "error": String(error.localizedDescription.prefix(8_192)), "maximumMediaBytes": 2 * Oracle.maximumFileBytes,
            "files": files], to: destination.appendingPathComponent("failure.json"))
        print("[recording-input-failure] Retained \(files.count) synthetic movies / \(bytes) bytes at \(destination.path)")
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-Input-Derived-Test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
    private func raster() -> [UInt8] {
        var pixels = [UInt8](repeating: 40, count: Oracle.width * Oracle.height * 4)
        for offset in stride(from: 3, to: pixels.count, by: 4) { pixels[offset] = 255 }
        return pixels
    }
    private func observe(_ pixels: [UInt8]) throws -> Oracle.Observation {
        try pixels.withUnsafeBufferPointer { try Oracle.observation($0, index: 2, pts: 0.2) }
    }
    private func paint(_ pixels: inout [UInt8], x: Int, y: Int, width: Int, height: Int, color: [UInt8]) {
        for row in y..<(y + height) {
            for column in x..<(x + width) {
                let offset = ((Oracle.height - 1 - row) * Oracle.width + column) * 4
                for channel in 0..<3 { pixels[offset + channel] = color[channel] }
            }
        }
    }
}
