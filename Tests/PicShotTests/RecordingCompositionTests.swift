import XCTest
import AppKit
import AVFoundation
import CoreImage
import ScreenCaptureKit
@testable import PicShot

final class RecordingCompositionTests: XCTestCase {
    func testCameraPlacementMirrorCropAndEllipseProduceActualPixels() throws {
        let size = CGSize(width: 160, height: 120), state = RecordingCompositionState(), token = UUID()
        state.setCanvasSize(size); state.setCameraSession(token)
        state.receiveCamera(try RecordingOverlayFixtures.splitCamera(), token: token)
        var layout = RecordingCameraLayout(frame: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.4), mirrored: false)
        state.setLayout(layout)
        let compositor = try RecordingFrameCompositor(size: size, state: state)
        let source = try RecordingOverlayFixtures.sample(at: 100)
        var result = try XCTUnwrap(compositor.composite(source))
        try assertColor(result, x: 25, y: 40, red: true)
        try assertColor(result, x: 70, y: 40, blue: true)
        try assertColor(result, x: 145, y: 100)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(result).seconds, 100)
        layout.mirrored = true; state.setLayout(layout)
        result = try XCTUnwrap(compositor.composite(source))
        try assertColor(result, x: 25, y: 40, blue: true)
        try assertColor(result, x: 70, y: 40, red: true)
        layout.crop = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        layout.frame = CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.4)
        state.setLayout(layout)
        result = try XCTUnwrap(compositor.composite(source))
        try assertColor(result, x: 24, y: 40, blue: true)
        layout.circular = true; state.setLayout(layout)
        result = try XCTUnwrap(compositor.composite(source))
        try assertColor(result, x: 17, y: 25)
        try assertColor(result, x: 32, y: 48, blue: true)
    }

    func testCameraVerticalOrientationAndCropMatchBottomLeftPreviewCoordinates() throws {
        let state = RecordingCompositionState(), token = UUID(), size = CGSize(width: 160, height: 120)
        state.setCanvasSize(size); state.setCameraSession(token)
        let pixels = try RecordingOverlayFixtures.pixels(width: 64, height: 48, color: .black)
        let lower = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 24))
        let upper = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 24, width: 64, height: 24))
        CIContext(options: [.useSoftwareRenderer: true]).render(lower.composited(over: upper), to: pixels)
        state.receiveCamera(pixels, token: token)
        var layout = RecordingCameraLayout(frame: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.4), mirrored: false)
        state.setLayout(layout)
        let compositor = try RecordingFrameCompositor(size: size, state: state)
        let source = try RecordingOverlayFixtures.sample(at: 100)
        var output = try XCTUnwrap(compositor.composite(source))
        try assertColor(output, x: 45, y: 32, red: true)
        try assertColor(output, x: 45, y: 64, blue: true)
        layout.crop = CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        state.setLayout(layout)
        output = try XCTUnwrap(compositor.composite(source))
        try assertColor(output, x: 45, y: 32, blue: true)
        try assertColor(output, x: 45, y: 64, blue: true)
    }

    func testLiveAnnotationAndEraserAffectPixelsWithoutErasingCameraOrScreen() throws {
        let state = RecordingCompositionState(), token = UUID(), size = CGSize(width: 160, height: 120)
        state.setCanvasSize(size); state.setCameraSession(token)
        state.receiveCamera(try RecordingOverlayFixtures.pixels(width: 64, height: 48, color: .blue), token: token)
        state.setLayout(RecordingCameraLayout(frame: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), mirrored: false))
        let mark = RecordingOverlayFixtures.rectangle(CGRect(x: 15, y: 15, width: 55, height: 40), color: .green)
        XCTAssertTrue(state.setAnnotations([mark]))
        let compositor = try RecordingFrameCompositor(size: size, state: state)
        let source = try RecordingOverlayFixtures.sample(at: 100)
        var result = try XCTUnwrap(compositor.composite(source))
        try assertColor(result, x: 40, y: 35, green: true)
        let eraser = ImageAnnotation(tool: .eraser, points: [CGPoint(x: 40, y: 20), CGPoint(x: 40, y: 50)], lineWidth: 16)
        XCTAssertTrue(state.setAnnotations([mark, eraser]))
        result = try XCTUnwrap(compositor.composite(source))
        try assertColor(result, x: 40, y: 35, blue: true)
        try assertColor(result, x: 20, y: 35, green: true)
        state.setCameraSession(nil); XCTAssertTrue(state.setAnnotations([]))
        result = try XCTUnwrap(compositor.composite(source))
        try assertColor(result, x: 40, y: 35)
        XCTAssertTrue(CMSampleBufferGetImageBuffer(result) === CMSampleBufferGetImageBuffer(source),
                      "A cleared overlay must return the original source without an unnecessary full-frame copy")
    }

    func testOutputPoolDropsUnderBackpressureInsteadOfGrowing() throws {
        let state = RecordingCompositionState()
        state.setCanvasSize(CGSize(width: 160, height: 120))
        XCTAssertTrue(state.setAnnotations([RecordingOverlayFixtures.rectangle(CGRect(x: 10, y: 10, width: 20, height: 20), color: .green)]))
        let compositor = try RecordingFrameCompositor(size: CGSize(width: 160, height: 120), state: state)
        let source = try RecordingOverlayFixtures.sample(at: 100)
        var held: [CMSampleBuffer] = []
        for _ in 0..<3 { held.append(try XCTUnwrap(compositor.composite(source))) }
        XCTAssertNil(try compositor.composite(source))
        XCTAssertEqual(held.count, 3)
        held.removeAll()
        XCTAssertNotNil(try compositor.composite(source))
    }

    func testLayoutAndVectorLimitsRejectUnboundedOrNonfiniteInput() throws {
        var layout = RecordingCameraLayout(frame: CGRect(x: 2, y: -1, width: 10, height: 0.001),
                                           crop: CGRect(x: CGFloat.infinity, y: 0, width: 1, height: 1))
        layout.constrain()
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).contains(layout.frame))
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).contains(layout.crop))
        let state = RecordingCompositionState()
        let mark = ImageAnnotation(tool: .freehand, points: [.zero, CGPoint(x: 10, y: 10)])
        XCTAssertTrue(state.setAnnotations([mark]))
        XCTAssertFalse(state.setAnnotations(Array(repeating: mark, count: 257)))
        var invalid = mark; invalid.points = [CGPoint(x: CGFloat.nan, y: 1)]
        XCTAssertFalse(state.setAnnotations([invalid]))
        invalid.points = Array(repeating: .zero, count: 4_097)
        XCTAssertFalse(state.setAnnotations([invalid]))
        XCTAssertEqual(state.snapshot().annotations.count, 1)
        XCTAssertThrowsError(try RecordingFrameCompositor(size: CGSize(width: 8_192, height: 8_192), state: state))
    }

    /// Encodes the production RecordingWriter, decodes H.264, checks real output
    /// pixels and stored PTS. Original generated colors require no screen, camera,
    /// microphone, TCC grants or synthetic posting of input events.
    func testEncodedMP4IncludesChangedCameraAnnotationsAndStaticDesktopRefreshAcrossPause() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-Overlays-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = RecordingCompositionState(), token = UUID(), clock = OverlayFixtureClock(100)
        let size = CGSize(width: 160, height: 120)
        state.setCanvasSize(size); state.setCameraSession(token)
        state.setLayout(RecordingCameraLayout(frame: CGRect(x: 0.05, y: 0.1, width: 0.3, height: 0.4), mirrored: false))
        state.receiveCamera(try RecordingOverlayFixtures.pixels(width: 64, height: 48, color: .red), token: token)
        let compositor = try RecordingFrameCompositor(size: size, state: state)
        let writer = try RecordingWriter(size: size, options: RecordingOptions(frameRate: 10), outputDirectory: directory,
            compositor: compositor, automaticallyRefreshOverlays: false, clock: { clock.now }) { _ in }
        for frame in 0..<3 {
            clock.set(100 + Double(frame) / 10)
            try await append(RecordingOverlayFixtures.sample(at: 100 + Double(frame) / 10), writer: writer)
        }
        // No more ScreenCaptureKit complete frames: camera and annotations still
        // update against the single last desktop surface at the screen clock.
        state.receiveCamera(try RecordingOverlayFixtures.pixels(width: 64, height: 48, color: .blue), token: token)
        let green = RecordingOverlayFixtures.rectangle(CGRect(x: 105, y: 70, width: 40, height: 30), color: .green)
        XCTAssertTrue(state.setAnnotations([green]))
        clock.set(100.3)
        try await refresh(writer: writer)
        clock.set(100.4); _ = try await writer.setPaused(true)
        state.receiveCamera(try RecordingOverlayFixtures.pixels(width: 64, height: 48, color: .yellow), token: token)
        XCTAssertTrue(state.setAnnotations([]))
        clock.set(101.3); writer.queue.sync { writer.refreshOverlay() }
        XCTAssertTrue(compositor.needsRefresh, "Paused edits must not write a paused frame")
        clock.set(101.4); _ = try await writer.setPaused(false)
        clock.set(101.5)
        try await refresh(writer: writer)
        clock.set(101.6)
        _ = await writer.stopAccepting()
        let saved = try await writer.finish()
        let asset = AVURLAsset(url: saved)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 0.6, accuracy: 0.03)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var timestamps: [Double] = [], sawRed = false, sawBlueWithGreen = false, sawYellowCleared = false
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if let previous = timestamps.last { XCTAssertGreaterThan(pts, previous) }
            timestamps.append(pts)
            if pts < 0.25 { try assertColor(sample, x: 30, y: 35, red: true); sawRed = true }
            else if pts < 0.39 {
                try assertColor(sample, x: 30, y: 35, blue: true)
                try assertColor(sample, x: 120, y: 80, green: true); sawBlueWithGreen = true
            } else {
                let camera = try RecordingOverlayFixtures.color(sample, x: 30, y: 35)
                XCTAssertGreaterThan(camera.0, 180); XCTAssertGreaterThan(camera.1, 180); XCTAssertLessThan(camera.2, 60)
                try assertColor(sample, x: 120, y: 80); sawYellowCleared = true
            }
        }
        XCTAssertEqual(reader.status, .completed, reader.error?.localizedDescription ?? "Decode failed")
        XCTAssertTrue(sawRed && sawBlueWithGreen && sawYellowCleared)
        XCTAssertEqual(timestamps.first ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(timestamps.last ?? -1, 0.5, accuracy: 0.001)
        XCTAssertFalse(timestamps.contains { $0 > 0.6 })
        let snapshot = await writer.snapshot(); XCTAssertEqual(snapshot.retainedVideoFrames, 0)
    }

    func testEncodedAsymmetricDesktopAndCameraKeepVerticalOrientation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-OverlayOrientation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try RecordingOverlayFixtures.pixels(width: 160, height: 120, color: .black)
        let lower = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 60))
        let upper = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 60, width: 160, height: 60))
        let context = CIContext(options: [.useSoftwareRenderer: true])
        context.render(lower.composited(over: upper), to: source)
        let camera = try RecordingOverlayFixtures.pixels(width: 64, height: 48, color: .white)
        let cameraLower = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 24))
        let cameraUpper = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 0, y: 24, width: 64, height: 24))
        context.render(cameraLower.composited(over: cameraUpper), to: camera)
        let state = RecordingCompositionState(), token = UUID(), clock = OverlayFixtureClock(100), size = CGSize(width: 160, height: 120)
        state.setCanvasSize(size); state.setCameraSession(token); state.receiveCamera(camera, token: token)
        state.setLayout(RecordingCameraLayout(frame: CGRect(x: 0.55, y: 0.1, width: 0.4, height: 0.4), mirrored: false))
        let compositor = try RecordingFrameCompositor(size: size, state: state)
        let writer = try RecordingWriter(size: size, options: RecordingOptions(frameRate: 10), outputDirectory: directory,
            compositor: compositor, automaticallyRefreshOverlays: false, clock: { clock.now }) { _ in }
        try await append(RecordingOverlayFixtures.sample(at: 100, pixels: source), writer: writer)
        clock.set(100.1); try await append(RecordingOverlayFixtures.sample(at: 100.1, pixels: source), writer: writer)
        clock.set(100.2); _ = await writer.stopAccepting()
        let asset = AVURLAsset(url: try await writer.finish())
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first),
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            try assertColor(sample, x: 20, y: 20, red: true)
            try assertColor(sample, x: 20, y: 100, blue: true)
            try assertColor(sample, x: 110, y: 22, red: true, green: true, blue: true)
            try assertColor(sample, x: 110, y: 50, green: true)
            count += 1
        }
        XCTAssertEqual(count, 2); XCTAssertEqual(reader.status, .completed)
    }

    func testStopFreezesPendingResumeOverlayBeforeCameraTeardownOrLaterFrames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-StopOverlay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = RecordingCompositionState(), token = UUID(), clock = OverlayFixtureClock(100)
        let size = CGSize(width: 160, height: 120)
        state.setCanvasSize(size); state.setCameraSession(token)
        state.setLayout(RecordingCameraLayout(frame: CGRect(x: 0.05, y: 0.1, width: 0.3, height: 0.4), mirrored: false))
        state.receiveCamera(try RecordingOverlayFixtures.pixels(width: 64, height: 48, color: .red), token: token)
        let compositor = try RecordingFrameCompositor(size: size, state: state)
        let writer = try RecordingWriter(size: size, options: RecordingOptions(frameRate: 10), outputDirectory: directory,
            compositor: compositor, automaticallyRefreshOverlays: false, clock: { clock.now }) { _ in }
        try await append(RecordingOverlayFixtures.sample(at: 100), writer: writer)
        clock.set(100.1); try await append(RecordingOverlayFixtures.sample(at: 100.1), writer: writer)
        clock.set(100.2); _ = try await writer.setPaused(true)
        state.receiveCamera(try RecordingOverlayFixtures.pixels(width: 64, height: 48, color: .blue), token: token)
        clock.set(101.2); _ = try await writer.setPaused(false)
        clock.set(101.3); _ = await writer.stopAccepting()
        // Simulate an in-flight camera callback after Stop, followed by hardware
        // teardown clearing the public latest-frame slot before slow save work.
        state.receiveCamera(try RecordingOverlayFixtures.pixels(width: 64, height: 48, color: .green), token: token)
        state.setCameraSession(nil)
        let asset = AVURLAsset(url: try await writer.finish())
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(value: 2, timescale: 10)).image
        let color = try RecordingOverlayFixtures.imageColor(image, x: 30, y: 35)
        XCTAssertLessThan(color.0, 60); XCTAssertLessThan(color.1, 60); XCTAssertGreaterThan(color.2, 180)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 0.3, accuracy: 0.02)
    }

    func testHeartbeatDoesNotHideNewerDesktopWhoseCallbackArrivesLate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-LateDesktop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = RecordingCompositionState(), clock = OverlayFixtureClock(100), size = CGSize(width: 160, height: 120)
        state.setCanvasSize(size)
        let box = CGRect(x: 10, y: 10, width: 20, height: 20)
        XCTAssertTrue(state.setAnnotations([RecordingOverlayFixtures.rectangle(box, color: .green)]))
        let compositor = try RecordingFrameCompositor(size: size, state: state)
        let writer = try RecordingWriter(size: size, options: RecordingOptions(frameRate: 10), outputDirectory: directory,
            compositor: compositor, automaticallyRefreshOverlays: false, clock: { clock.now }) { _ in }
        try await append(RecordingOverlayFixtures.sample(at: 100), writer: writer)
        XCTAssertTrue(state.setAnnotations([RecordingOverlayFixtures.rectangle(box, color: .blue)]))
        clock.set(100.1); try await refresh(writer: writer)
        let delayed = try RecordingOverlayFixtures.sample(at: 100.05, color: .red)
        XCTAssertFalse(writer.queue.sync { writer.consume(delayed, of: .screen) }, "Late PTS must not be encoded backwards")
        clock.set(100.2)
        // State revision is unchanged; the independent raw-screen revision must
        // nevertheless schedule this new red desktop surface.
        try await refresh(writer: writer)
        clock.set(100.3); _ = await writer.stopAccepting()
        let asset = AVURLAsset(url: try await writer.finish())
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(value: 2, timescale: 10)).image
        let rgba = try RecordingOverlayFixtures.imageColor(image, x: 120, y: 80)
        XCTAssertGreaterThan(rgba.0, 180); XCTAssertLessThan(rgba.1, 60); XCTAssertLessThan(rgba.2, 60)
    }

    private func refresh(writer: RecordingWriter) async throws {
        let deadline = Date().addingTimeInterval(10)
        while writer.queue.sync(execute: { writer.needsOverlayRefresh }) {
            writer.queue.sync { writer.refreshOverlay() }
            guard Date() < deadline else { throw RecordingError.failed("Overlay refresh fixture timed out.") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func append(_ sample: CMSampleBuffer, writer: RecordingWriter) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !writer.queue.sync(execute: { writer.consume(sample, of: .screen) }) {
            guard Date() < deadline else { throw RecordingError.failed("Overlay encoder fixture timed out.") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func assertColor(_ sample: CMSampleBuffer, x: Int, y: Int, red: Bool = false,
                             green: Bool = false, blue: Bool = false, file: StaticString = #filePath, line: UInt = #line) throws {
        let result = try RecordingOverlayFixtures.color(sample, x: x, y: y)
        for (value, on) in [(result.0, red), (result.1, green), (result.2, blue)] {
            if on { XCTAssertGreaterThan(value, 170, file: file, line: line) }
            else { XCTAssertLessThan(value, 65, file: file, line: line) }
        }
    }
}

/// Original synthetic media fixtures. Coordinates are explicitly bottom-left,
/// matching Core Image, the annotation model and the camera compositor.
enum RecordingOverlayFixtures {
    static func pixels(width: Int, height: Int, color: NSColor) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey as String: true,
                          kCVPixelBufferCGBitmapContextCompatibilityKey as String: true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { throw RecordingError.failed("Could not create synthetic pixels") }
        let image = CIImage(color: CIColor(cgColor: color.cgColor)).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        CIContext(options: [.useSoftwareRenderer: true]).render(image, to: buffer)
        return buffer
    }

    static func splitCamera() throws -> CVPixelBuffer {
        let pixels = try pixels(width: 64, height: 48, color: .red)
        let left = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 48))
        let right = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 32, y: 0, width: 32, height: 48))
        CIContext(options: [.useSoftwareRenderer: true]).render(left.composited(over: right), to: pixels)
        return pixels
    }

    static func sample(at seconds: Double, color: NSColor = .black, pixels source: CVPixelBuffer? = nil) throws -> CMSampleBuffer {
        let image = try source ?? pixels(width: 160, height: 120, color: color)
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
            formatDescriptionOut: &format) == noErr, let format else { throw RecordingError.failed("Synthetic format failed") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 10),
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48_000), decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &result) == noErr,
              let result else { throw RecordingError.failed("Synthetic sample failed") }
        let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true))
        let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: NSMutableDictionary.self)
        attachment[SCStreamFrameInfo.status.rawValue] = SCFrameStatus.complete.rawValue
        return result
    }

    static func rectangle(_ rect: CGRect, color: NSColor) -> ImageAnnotation {
        var mark = ImageAnnotation(tool: .rectangle,
            points: [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)], color: color.cgColor, lineWidth: 2)
        mark.fillEnabled = true; mark.fillColor = color.cgColor
        return mark
    }

    static func imageColor(_ image: CGImage, x: Int, y: Int) throws -> (Int, Int, Int) {
        var value = [UInt8](repeating: 0, count: 4)
        value.withUnsafeMutableBytes {
            CIContext(options: [.useSoftwareRenderer: true]).render(CIImage(cgImage: image), toBitmap: $0.baseAddress!, rowBytes: 4,
                bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        return (Int(value[0]), Int(value[1]), Int(value[2]))
    }

    static func color(_ sample: CMSampleBuffer, x: Int, y: Int) throws -> (Int, Int, Int) {
        let pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        let image = CIImage(cvPixelBuffer: pixels)
        var value = [UInt8](repeating: 0, count: 4)
        value.withUnsafeMutableBytes {
            CIContext(options: [.useSoftwareRenderer: true]).render(image, toBitmap: $0.baseAddress!, rowBytes: 4,
                bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        return (Int(value[0]), Int(value[1]), Int(value[2]))
    }
}

private final class OverlayFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: CMTime
    init(_ seconds: Double) { time = CMTime(seconds: seconds, preferredTimescale: 48_000) }
    var now: CMTime { lock.lock(); defer { lock.unlock() }; return time }
    func set(_ seconds: Double) { lock.lock(); defer { lock.unlock() }; time = CMTime(seconds: seconds, preferredTimescale: 48_000) }
}
