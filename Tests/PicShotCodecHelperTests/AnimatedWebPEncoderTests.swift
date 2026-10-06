import XCTest
import AVFoundation
import CoreGraphics
import Foundation
import CPicShotCodecs
import PicShotCodecCore
@testable import PicShotCodecHelper

final class AnimatedWebPEncoderTests: XCTestCase {
    func testNearest600HzRequestsAvoidThePrecedingFrameRegression() throws {
        let plan = try AnimatedWebPFramePlan(duration: 2.4, options: .init(frameRate: 10))
        XCTAssertEqual(plan.frameCount, 24)
        for index in [1, 2, 8, 16] {
            XCTAssertEqual(plan.samplingTime(for: index).timescale, 600)
            XCTAssertEqual(plan.samplingTime(for: index).value, Int64(index * 60))
            XCTAssertEqual(CMTimeCompare(plan.samplingTime(for: index), CMTime(value: Int64(index), timescale: 10)), 0)
        }
        XCTAssertEqual((0..<24).map { plan.delayMS(for: $0) }, Array(repeating: 100, count: 24))
    }

    func testRoundedCumulativeBoundariesPreserveVariableDelaysAndCappedDuration() throws {
        let thirty = try AnimatedWebPFramePlan(duration: 1, options: .init(frameRate: 30))
        XCTAssertEqual((0..<3).map { thirty.delayMS(for: $0) }, [33, 34, 33])
        let cases: [(Double, CodecAnimationOptions)] = [
            (59.97, .init(frameRate: 30, maximumFrames: 7)),
            (60, .init(frameRate: 30)), (1.001, .init(frameRate: 24)),
            (0.101, .init(frameRate: 30)), (0.001, .init(frameRate: 30))
        ]
        for (duration, options) in cases {
            let plan = try AnimatedWebPFramePlan(duration: duration, options: options)
            let delays = (0..<plan.frameCount).map { plan.delayMS(for: $0) }
            XCTAssertEqual(delays.reduce(0, +), Int((duration * 1_000).rounded()))
            XCTAssertTrue(delays.allSatisfy { $0 > 0 })
            XCTAssertLessThanOrEqual(plan.frameCount, options.maximumFrames)
            for index in 0..<plan.frameCount {
                XCTAssertGreaterThanOrEqual(plan.samplingTime(for: index).seconds, 0)
                XCTAssertLessThan(plan.samplingTime(for: index).seconds, duration)
            }
        }
        XCTAssertThrowsError(try AnimatedWebPFramePlan(duration: 60.1, options: .init()))
        XCTAssertThrowsError(try AnimatedWebPFramePlan(duration: 3, options: .init(maximumDuration: 2)))
        for duration in [Double.nan, .infinity, 0, -1] {
            XCTAssertThrowsError(try AnimatedWebPFramePlan(duration: duration, options: .init()))
        }
    }

    func testRealH264DecodesEveryExactBoundaryFrameAndPreservesSource() async throws {
        let directory = try CodecTemporaryJob.create(in: FileManager.default.temporaryDirectory)
        defer { CodecTemporaryJob.removeOwned(directory) }
        let input = directory.appendingPathComponent("input.mp4")
        try await makeMovie(input)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
        let original = try Data(contentsOf: input)
        let request = CodecExportRequest(kind: .animation, format: .webp, lossless: true,
                                        animation: .init(frameRate: 10, maximumDimension: 32))
        let files = try CodecJobFiles.validate(directory: directory, request: request)
        var progress: [Double] = []
        let result = try await AnimatedWebPEncoder.encode(files: files, request: request, isCancelled: { false }) { progress.append($0) }
        XCTAssertEqual(result.width, 32); XCTAssertEqual(result.height, 24)
        XCTAssertEqual(result.frameCount, 12); XCTAssertEqual(result.duration, 1.2, accuracy: 0.001)
        XCTAssertFalse(result.hasAlpha)
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertEqual(progress.first, 0)
        XCTAssertEqual(progress.count, 13)
        XCTAssertTrue(zip(progress, progress.dropFirst()).allSatisfy { $0.0 <= $0.1 })
        XCTAssertLessThan(try XCTUnwrap(progress.last), 1, "Final progress belongs to verified helper finalization")
        let data = try Data(contentsOf: files.outputURL)
        var error = PSCodecError()
        let animation = try XCTUnwrap(data.withUnsafeBytes { bytes in
            PSCodecWebPAnimationOpen(bytes.bindMemory(to: UInt8.self).baseAddress, UInt64(bytes.count), 32 * 24, 12, 32 * 24 * 4, &error)
        })
        defer { PSCodecAnimationFree(animation) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: input))
        generator.maximumSize = CGSize(width: 32, height: 32)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        var uniqueFrames = Set<Data>()
        for index in 0..<12 {
            var pixels: UnsafePointer<UInt8>?, count: UInt64 = 0, duration: UInt32 = 0
            XCTAssertEqual(PSCodecAnimationNext(animation, &pixels, &count, &duration, &error), Int32(PS_CODEC_OK))
            XCTAssertEqual(duration, 100)
            let decoded = Data(bytes: try XCTUnwrap(pixels), count: Int(count))
            let expectedImage = try generator.copyCGImage(at: CMTime(value: Int64(index), timescale: 10), actualTime: nil)
            let expected = try CodecRaster(image: expectedImage)
            XCTAssertEqual(decoded, Data(expected.rgba), "Wrong decoded pixels at exact source boundary \(index)/10")
            uniqueFrames.insert(decoded)
        }
        XCTAssertEqual(uniqueFrames.count, 12, "Proof must cover changing decoded frames, not merely an animation flag")
    }

    func testCancellationBeforeAndAfterFirstFrameNeverFinalizesOutput() async throws {
        for cancelBefore in [true, false] {
            let directory = try CodecTemporaryJob.create(in: FileManager.default.temporaryDirectory)
            defer { CodecTemporaryJob.removeOwned(directory) }
            let input = directory.appendingPathComponent("input.mp4")
            try await makeMovie(input)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
            let original = try Data(contentsOf: input)
            let request = CodecExportRequest(kind: .animation, format: .webp, lossless: true, animation: .init(frameRate: 10))
            let files = try CodecJobFiles.validate(directory: directory, request: request)
            var cancelled = cancelBefore
            do {
                _ = try await AnimatedWebPEncoder.encode(files: files, request: request, isCancelled: { cancelled }) { value in
                    if value > 0 { cancelled = true }
                }
                XCTFail("Cancelled animation cannot succeed")
            } catch is CancellationError { }
            XCTAssertEqual(try Data(contentsOf: input), original)
            if cancelBefore { XCTAssertFalse(FileManager.default.fileExists(atPath: files.outputURL.path)) }
            else { XCTAssertEqual(try Data(contentsOf: files.outputURL)[4..<8], Data(repeating: 0, count: 4)) }
        }
    }

    func testMP4AdmissionRejectsExternalReferenceFlagsAndNonMediaBeforeDecoding() async throws {
        let directory = try CodecTemporaryJob.create(in: FileManager.default.temporaryDirectory)
        defer { CodecTemporaryJob.removeOwned(directory) }
        let input = directory.appendingPathComponent("input.mp4")
        try await makeMovie(input)
        var data = try Data(contentsOf: input)
        let urlChunk = try XCTUnwrap(data.range(of: Data("url ".utf8)))
        data[urlChunk.upperBound + 3] = 0 // self-contained dref flag becomes external
        try data.write(to: input)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
        let request = CodecExportRequest(kind: .animation, format: .webp, animation: .init())
        let files = try CodecJobFiles.validate(directory: directory, request: request)
        XCTAssertThrowsError(try CodecAnimationMP4Admission.validate(files: files))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.outputURL.path))
    }

    private func makeMovie(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64, AVVideoHeightKey: 48,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 1]])
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CodecExportFailure(.failed) }
        writer.startSession(atSourceTime: .zero)
        let deadline = Date().addingTimeInterval(15)
        for index in 0..<12 {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, Date() < deadline else { throw CodecExportFailure(.deadline) }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer), kCVReturnSuccess)
            let pixel = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: 64, height: 48,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            context.setFillColor(CGColor(red: CGFloat(index) / 12, green: 0.25, blue: 1 - CGFloat(index) / 12, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 10)) else {
                throw writer.error ?? CodecExportFailure(.failed)
            }
        }
        writer.endSession(atSourceTime: CMTime(value: 12, timescale: 10))
        input.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else { throw writer.error ?? CodecExportFailure(.failed) }
    }
}
