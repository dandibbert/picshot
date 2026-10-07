import AppKit
import Foundation
import PicShotCore

/// Callable installed-app acceptance: synthetic provider, real passive driver/coordinator,
/// native owned buttons/mouse events and the production disk-spooled acceptance path.
/// This never captures an external app, posts global input, or touches TCC/Accessibility.
@MainActor
enum ScrollManualCaptureSmokeFixture {
    static func verify(evidenceDirectory: URL, includeLargeFrames: Bool = false) async throws -> [String: Any] {
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        var report: [String: Any] = [
            "status": "running", "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "provider": "owned synthetic deterministic RGBA frames, no physical external-app capture",
            "screenCaptureStarted": false, "accessibilityRequested": false, "permissionRequested": false,
            "systemInputEventsPosted": 0, "acceptedSourcesImmutable": true,
            "limits": ["framePixels": ScrollFrame.maximumPixels, "outputPixels": ScrollCaptureSequence.maximumOutputPixels,
                       "frames": ScrollCaptureSequence.maximumBlocks, "diskBytes": 512 * 1024 * 1024],
            "limitations": ["Does not establish physical display, third-party scrolling or live input routing acceptance",
                            "Process memory observations include allocator caches; release assertions concern owned state, workers and source files"]
        ]
        let reportURL = evidenceDirectory.appendingPathComponent("scroll-manual-continuous.json")
        do {
            report["memoryBefore"] = try memory()
            var axes: [[String: Any]] = []
            for axis in ScrollAxis.allCases { axes.append(try await acceptanceCycle(axis: axis)) }
            report["axes"] = axes
            report["regionMoveNativeEvents"] = try regionMoveEvents()
            report["lateCaptureClose"] = try await lateCaptureClose()
            report["lateWritePauseStopClose"] = try await writeCancellationCycles()
            report["colorDigest"] = try colorDigest()
            report["nativeAppearanceSnapshots"] = try await appearanceSnapshots(directory: evidenceDirectory)
            if includeLargeFrames {
                var resources: [[String: Any]] = []
                for (size, axis) in [((3840, 2160), ScrollAxis.horizontal), ((5120, 2880), ScrollAxis.vertical)] {
                    resources.append(try await resourceCycle(width: size.0, height: size.1, axis: axis))
                }
                report["largeFrameProviders"] = resources
            }
            report["memoryAfter"] = try memory()
            report["status"] = "passed"
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
            return report
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
            throw error
        }
    }

    @MainActor private final class Source {
        var offset = 100
        var alteration: String?
        var captures = 0
        let axis: ScrollAxis
        init(axis: ScrollAxis) { self.axis = axis }
        func next() throws -> CGImage {
            captures += 1
            return try ScrollSequenceSmokeFixture.image(axis: axis, offset: offset, alteration: alteration)
        }
    }

    private static func configuration() -> ManualScrollConfiguration {
        var config = ManualScrollConfiguration()
        config.countdownSeconds = 0; config.sampleInterval = 0.05
        config.maximumDuration = 120
        return config
    }

    private static func acceptanceCycle(axis: ScrollAxis) async throws -> [String: Any] {
        var controller: ScrollCaptureController? = ScrollCaptureController { _ in }
        weak var weakController = controller
        let source = Source(axis: axis)
        var coordinator: ManualScrollCoordinator?
        weak var weakDriver: ManualScrollScreenDriver?
        var savedDirectory: URL?
        do {
            let live = try unwrap(controller, "Missing controller")
            try await live.setAutoCropForVerification(false)
            coordinator = try live.startManualForVerification(axis: axis,
                region: CGRect(x: 20, y: 20, width: axis == .vertical ? 96 : 140, height: axis == .vertical ? 140 : 96), screenSize: CGSize(width: 800, height: 600),
                configuration: configuration(), provider: { try source.next() })
            weakDriver = live.manualDriverForVerification
            try await wait("Initial stable viewport not accepted") { live.sourceURLsForVerification.count == 1 }
            let first = live.sourceURLsForVerification
            let firstBytes = try first.map { try Data(contentsOf: $0) }
            try await wait("Stationary viewport not sampled repeatedly") { source.captures >= 4 }
            try require(live.sourceURLsForVerification == first, "Stationary sampling duplicated a source")
            try click("scroll.manual.pause", in: live.manualControlsForVerification)
            try await wait("Pause did not drain") { coordinator?.canResume == true }
            try require(weakDriver?.pendingImage == nil, "Pause retained an uncommitted full image")
            let count = source.captures
            try await Task.sleep(nanoseconds: 100_000_000)
            try require(source.captures == count, "Paused coordinator kept sampling")
            let oldRegion = try unwrap(live.manualRegionForVerification, "Missing region")
            try live.moveManualRegionForVerification(to: oldRegion.offsetBy(dx: 12, dy: 8))
            try require(live.sourceURLsForVerification == first, "Move changed accepted source metadata")
            try require(try first.map { try Data(contentsOf: $0) } == firstBytes, "Move changed accepted source bytes")
            do {
                try live.moveManualRegionForVerification(to: CGRect(x: oldRegion.minX, y: oldRegion.minY, width: oldRegion.width + 1, height: oldRegion.height))
                throw failure("Move allowed a resize")
            } catch is FixtureFailure { throw failure("Move allowed a resize") } catch { }
            source.offset = 147
            try click("scroll.manual.pause", in: live.manualControlsForVerification)
            try require(coordinator?.state != .countdown(3), "Resume repeated the initial countdown")
            try await wait("Moved-region resume failed") { live.sourceURLsForVerification.count == 2 }
            let accepted = live.sourceURLsForVerification
            let immutable = try accepted.map { try Data(contentsOf: $0) }
            source.alteration = "independent"
            try await wait("Uncertain seam was not recoverable") {
                if case .recoverable? = coordinator?.state { return coordinator?.canResume == true }; return false
            }
            try require(live.sourceURLsForVerification == accepted, "Rejected seam committed a source")
            try require(try accepted.map { try Data(contentsOf: $0) } == immutable, "Rejected seam modified a source")
            source.alteration = nil; source.offset = 190
            try click("scroll.manual.pause", in: live.manualControlsForVerification)
            try await wait("Retry did not preserve the accepted anchor") { live.sourceURLsForVerification.count == 3 }
            try click("scroll.manual.stop", in: live.manualControlsForVerification)
            try await wait("Stop did not drain") { coordinator?.hasPendingOperation == false }
            try require(coordinator?.state == .finished(.stopped), "Stop did not become terminal")
            try require(weakDriver?.pendingImage == nil, "Stop retained candidate image")
            let output = try live.currentOutputForVerification()
            let expected = try ScrollSequenceSmokeFixture.image(axis: axis, offset: 100, length: 230)
            try require(try ScrollSequenceSmokeFixture.pixels(output) == ScrollSequenceSmokeFixture.pixels(expected), "Continuous output pixels differ")
            savedDirectory = live.temporaryDirectoryForVerification
            live.close()
        }
        controller = nil; coordinator = nil
        try await wait("Closed manual objects remain retained") { weakController == nil && weakDriver == nil }
        if let savedDirectory { try require(!FileManager.default.fileExists(atPath: savedDirectory.path), "Close leaked source directory") }
        return ["axis": axis.rawValue, "stableCapture": true, "stationarySuppressed": true,
                "pauseDrains": true, "resumeWithoutCountdown": true, "fixedRegionMovePreservesBytes": true,
                "uncertainSeamRejected": true, "retryKeepsAnchor": true, "exactPixels": true, "closeReleases": true]
    }

    /// A deliberately noncooperative provider returns after close. No stale image may
    /// install, reopen controls, create a directory or retain the controller after drain.
    private static func lateCaptureClose() async throws -> Bool {
        let gate = Gate()
        var controller: ScrollCaptureController? = ScrollCaptureController { _ in }
        weak var weakController = controller
        var coordinator: ManualScrollCoordinator? = try controller?.startManualForVerification(axis: .vertical,
            region: CGRect(x: 0, y: 0, width: 96, height: 140), screenSize: CGSize(width: 800, height: 600),
            configuration: configuration(), provider: {
                await gate.hold()
                return try ScrollSequenceSmokeFixture.image(axis: .vertical, offset: 100)
            })
        weak var weakDriver = controller?.manualDriverForVerification
        try await wait("Late capture gate not reached") { gate.waiting }
        controller?.close(); controller = nil
        gate.release()
        try await wait("Late capture did not drain") { coordinator?.hasPendingOperation == false }
        try require(weakDriver?.pendingImage == nil, "Late result reinstalled pending image")
        coordinator = nil
        try await wait("Late capture retained closed controller/driver") { weakController == nil && weakDriver == nil }
        return true
    }

    private static func writeCancellationCycles() async throws -> [[String: Any]] {
        var results: [[String: Any]] = []
        for action in ["pause", "stop", "close"] {
            let live = ScrollCaptureController { _ in }
            defer { live.close() }
            _ = try await live.acceptForVerification(ScrollSequenceSmokeFixture.image(axis: .vertical, offset: 100), axis: .vertical)
            let urls = live.sourceURLsForVerification
            let contents = try urls.map { try Data(contentsOf: $0) }
            let directory = try unwrap(live.temporaryDirectoryForVerification, "Missing cancellation spool")
            let gate = WriteGate()
            live.sourceWriteBarrierForVerification = { url in await gate.hold(url) }
            let coordinator = try live.startManualForVerification(axis: .vertical,
                region: CGRect(x: 0, y: 0, width: 96, height: 140), screenSize: CGSize(width: 800, height: 600),
                configuration: configuration(), provider: { try ScrollSequenceSmokeFixture.image(axis: .vertical, offset: 147) })
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            while await gate.url == nil {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw failure("Write gate timeout") }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let pendingURL = await gate.url
            if action == "close" { live.close() }
            else { try click("scroll.manual." + action, in: live.manualControlsForVerification) }
            await gate.release()
            try await wait("Canceled write did not drain") { !coordinator.hasPendingOperation }
            if let pendingURL { try require(!FileManager.default.fileExists(atPath: pendingURL.path), "Canceled write left uncommitted PNG") }
            if action == "close" {
                try require(!FileManager.default.fileExists(atPath: directory.path), "Close retained spool during canceled write")
                try require(live.sourceURLsForVerification.isEmpty, "Close reinstalled source metadata")
            } else {
                try require(live.sourceURLsForVerification == urls, "Canceled write advanced accepted sequence")
                try require(try urls.map { try Data(contentsOf: $0) } == contents, "Canceled write altered accepted bytes")
                try require(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count == 1,
                            "Canceled write leaked source file")
                if action == "pause" { coordinator.stop() }
            }
            results.append(["action": action, "uncommittedPNGRemoved": true, "lateCommitRejected": true])
        }
        return results
    }

    private static func regionMoveEvents() throws -> Bool {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.close() }
        window.isReleasedWhenClosed = false
        let view = ManualScrollRegionMoveView(frame: CGRect(x: 0, y: 0, width: 500, height: 400),
                                              region: CGRect(x: 80, y: 60, width: 120, height: 100))
        window.contentView = view
        func event(_ type: NSEvent.EventType, point: CGPoint) throws -> NSEvent {
            try unwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1), "Missing owned drag event")
        }
        view.mouseDown(with: try event(.leftMouseDown, point: CGPoint(x: 90, y: 70)))
        view.mouseDragged(with: try event(.leftMouseDragged, point: CGPoint(x: 120, y: 110)))
        view.mouseUp(with: try event(.leftMouseUp, point: CGPoint(x: 120, y: 110)))
        try require(view.region == CGRect(x: 110, y: 100, width: 120, height: 100), "Native drag changed size or wrong origin")
        var result: CGRect?
        view.finished = { if case .success(let rect) = $0 { result = rect } }
        let enter = try unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36), "Missing owned Return event")
        view.keyDown(with: enter)
        try require(result == view.region, "Return failed to commit moved rectangle")
        return true
    }

    /// Separate visual evidence uses readable, owned synthetic page content. Controls
    /// and preview belong to a real paused/stopped session; no mock UI is rendered.
    private static func appearanceSnapshots(directory: URL) async throws -> [String: Any] {
        let live = ScrollCaptureController { _ in }
        defer { live.close() }
        try await live.setAutoCropForVerification(false)
        let document = try readableDocument()
        var offset = 0
        let coordinator = try live.startManualForVerification(axis: .vertical,
            region: CGRect(x: 0, y: 0, width: 640, height: 400), screenSize: CGSize(width: 800, height: 600),
            configuration: configuration(), provider: {
                try unwrap(document.cropping(to: CGRect(x: 0, y: offset, width: 640, height: 400)),
                           "Cannot crop readable synthetic viewport")
            })
        try await wait("Readable first viewport not accepted") { live.sourceURLsForVerification.count == 1 }
        offset = 260
        try await wait("Readable second viewport not accepted") { live.sourceURLsForVerification.count == 2 }
        offset = 520
        try await wait("Readable third viewport not accepted") { live.sourceURLsForVerification.count == 3 }
        try click("scroll.manual.pause", in: live.manualControlsForVerification)
        try await wait("Readable snapshot session did not pause") { coordinator.canResume }
        let panel = try unwrap(live.manualControlsForVerification, "Missing actual paused control panel")
        var files: [String] = []
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let filename = "scroll-manual-paused-controls-\(suffix).png"
            try await snapshot(panel, appearance: appearance, to: directory.appendingPathComponent(filename))
            files.append(filename)
        }
        try click("scroll.manual.stop", in: live.manualControlsForVerification)
        try await wait("Readable snapshot session did not stop") { !coordinator.hasPendingOperation }
        let output = try live.currentOutputForVerification()
        let reference = try unwrap(document.cropping(to: CGRect(x: 0, y: 0, width: 640, height: 920)),
                                   "Cannot crop readable output reference")
        try require(try ScrollSequenceSmokeFixture.pixels(output) == ScrollSequenceSmokeFixture.pixels(reference),
                    "Readable stitched snapshot pixels differ from reference")
        live.window?.contentView?.layoutSubtreeIfNeeded()
        // Beginning scales to the preview width, exposing readable content and the
        // real overview navigator instead of a tiny full-document fit thumbnail.
        try click("scroll.preview.beginning", in: live)
        await live.previewForVerification.waitForDetailForVerification()
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let filename = "scroll-manual-stopped-preview-\(suffix).png"
            try await snapshot(live, appearance: appearance, to: directory.appendingPathComponent(filename))
            files.append(filename)
        }
        return ["files": files, "acceptedFrames": 3, "outputWidth": 640, "outputHeight": 920,
                "exactReferencePixels": true,
                "scope": "Actual paused compact panel and stopped native controller preview; owned synthetic page, no physical screen capture",
                "snapshotBackground": "Window effective appearance and background composited behind cached content; content view only",
                "appearanceScope": "Per-window aqua/darkAqua restored after each snapshot; system appearance unchanged",
                "previewNavigation": "Actual native Beginning button; bounded sampled detail, not full-resolution claim"]
    }

    private static func readableDocument() throws -> CGImage {
        let width = 640, height = 1100
        let context = try unwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), "Cannot draw readable synthetic page")
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        func text(_ string: String, x: CGFloat, top: CGFloat, size: CGFloat, bold: Bool = false) {
            NSAttributedString(string: string, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular),
                .foregroundColor: NSColor(calibratedRed: 0.12, green: 0.18, blue: 0.27, alpha: 1)
            ]).draw(at: CGPoint(x: x, y: CGFloat(height) - top - size * 1.35))
        }
        text("PicShot · 合成验收页面", x: 42, top: 30, size: 25, bold: true)
        text("手动滚动连续捕获  /  原始像素保留", x: 42, top: 70, size: 15)
        for row in 0..<8 {
            let top = CGFloat(116 + row * 118)
            context.setFillColor(NSColor(calibratedRed: row % 2 == 0 ? 0.91 : 0.95, green: 0.95, blue: 0.99, alpha: 1).cgColor)
            context.fill(CGRect(x: 36, y: CGFloat(height) - top - 96, width: 566, height: 96))
            text(String(format: "%02d", row + 1) + "  已验证的内容片段", x: 54, top: top + 12, size: 18, bold: true)
            text("暂停后移动固定选区，继续时重新验证接缝", x: 54, top: top + 43, size: 14)
            text("合成示例 · 不是浏览器或第三方应用截图", x: 54, top: top + 66, size: 12)
        }
        // A narrow deterministic alignment rail makes every row identifiable. It is
        // part of the owned source image, not an annotation added to captured content.
        for y in 0..<height {
            var value = UInt64(y) &* 0x9e3779b185ebca87
            value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
            let shade = CGFloat(value % 216 + 20) / 255
            context.setFillColor(gray: shade, alpha: 1)
            context.fill(CGRect(x: 0, y: height - y - 1, width: 18, height: 1))
        }
        return try unwrap(context.makeImage(), "Readable synthetic page is empty")
    }

    private static func snapshot(_ controller: NSWindowController, appearance: NSAppearance.Name, to url: URL) async throws {
        let window = try unwrap(controller.window, "Missing native snapshot window")
        let view = try unwrap(window.contentView, "Missing native snapshot content")
        let originalAppearance = window.appearance
        defer { window.appearance = originalAppearance; view.needsDisplay = true }
        window.appearance = try unwrap(NSAppearance(named: appearance), "Missing requested native appearance")
        window.orderFrontRegardless()
        for child in descendants(view) { child.needsDisplay = true }
        try await Task.sleep(nanoseconds: 80_000_000)
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let width = Int(view.bounds.width.rounded(.up)), height = Int(view.bounds.height.rounded(.up))
        try require(width > 0 && width <= 1200 && height > 0 && height <= 1000, "Unbounded native snapshot")
        let bitmap = try unwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4, bitsPerPixel: 32), "Cannot cache native snapshot")
        bitmap.size = view.bounds.size
        let context = try unwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), "Cannot composite native snapshot")
        window.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        let cached = try unwrap(bitmap.cgImage, "Empty cached native snapshot")
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            context.setFillColor(window.backgroundColor.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(cached, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        try ScrollImageIO.writePNG(try unwrap(context.makeImage(), "Empty composited native snapshot"), to: url)
    }

    private static func colorDigest() throws -> Bool {
        let initial = try ScrollSequenceSmokeFixture.image(axis: .vertical, offset: 100)
        let same = try ScrollSequenceSmokeFixture.image(axis: .vertical, offset: 100)
        let color = try ScrollSequenceSmokeFixture.image(axis: .vertical, offset: 100, alteration: "stationaryColor")
        let one = try ManualScrollScreenDriver.observation(initial)
        try require(try one == ManualScrollScreenDriver.observation(same), "Identical RGBA observations differ")
        try require(try one != ManualScrollScreenDriver.observation(color), "Color-only changes disappeared from stability check")
        return true
    }

    private static func resourceCycle(width: Int, height: Int, axis: ScrollAxis) async throws -> [String: Any] {
        let before = try memory()
        var controller: ScrollCaptureController? = ScrollCaptureController { _ in }
        weak var weakController = controller
        var offset = 100
        var captures = 0
        let step = (axis == .vertical ? height : width) / 4
        var coordinator: ManualScrollCoordinator?
        var peakOwnedPending = 0
        var directory: URL?
        var retainedGray = 0, thumbnail = 0
        do {
            let live = try unwrap(controller, "Missing large provider controller")
            try await live.setAutoCropForVerification(false)
            var config = configuration(); config.operationTimeout = 30
            coordinator = try live.startManualForVerification(axis: axis,
                region: CGRect(x: 0, y: 0, width: width, height: height), screenSize: CGSize(width: width + 100, height: height + 100),
                configuration: config, provider: {
                    captures += 1
                    let current = offset
                    return try await Task.detached(priority: .userInitiated) { try largeImage(width: width, height: height, offset: current, axis: axis) }.value
                })
            try await wait("Large first frame not accepted", seconds: 45) {
                if let image = live.manualDriverForVerification?.pendingImage { peakOwnedPending = max(peakOwnedPending, image.width * image.height) }
                return live.sourceURLsForVerification.count == 1
            }
            offset += step
            try await wait("Large moved frame not accepted", seconds: 45) {
                if let image = live.manualDriverForVerification?.pendingImage { peakOwnedPending = max(peakOwnedPending, image.width * image.height) }
                return live.sourceURLsForVerification.count == 2
            }
            coordinator?.stop()
            try await wait("Large provider stop did not drain") { coordinator?.hasPendingOperation == false }
            retainedGray = live.retainedGrayPixelsForVerification; thumbnail = live.previewPixelsForVerification
            try require(retainedGray == width * height && thumbnail <= 800 * 800, "Large provider retained unbounded state")
            try require(live.manualDriverForVerification?.pendingImage == nil, "Large provider retained candidate after stop")
            let output = try live.currentOutputForVerification()
            let outputSignature = try ManualScrollScreenDriver.observation(output)
            let expected = try largeImage(width: width + (axis == .horizontal ? step : 0),
                                          height: height + (axis == .vertical ? step : 0), offset: 100, axis: axis)
            try require(try outputSignature == ManualScrollScreenDriver.observation(expected), "Large output pixel digest differs")
            directory = live.temporaryDirectoryForVerification
            live.close()
        }
        controller = nil; coordinator = nil
        try await wait("Large controller remains retained") { weakController == nil }
        if let directory { try require(!FileManager.default.fileExists(atPath: directory.path), "Large spool leaked") }
        return ["width": width, "height": height, "axis": axis.rawValue, "samples": captures, "pendingImagePixelBound": peakOwnedPending,
                "retainedGrayPixels": retainedGray, "overviewPixels": thumbnail, "exactOutputDigest": true,
                "closeReleasesControllerAndSpool": true, "memoryBefore": before, "memoryAfter": try memory()]
    }

    nonisolated static func largeImage(width: Int, height: Int, offset: Int, axis: ScrollAxis = .vertical) throws -> CGImage {
        guard width > 0, height > 0, width <= ScrollFrame.maximumPixels / height else { throw ScrollStitchError.invalidPixels }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                // Unique along the scroll axis, compressible repeated cross-axis texture.
                // Repeated cross-axis motifs never supply an alignment claim.
                let cross = axis == .vertical ? x % 64 : 0
                let along = (axis == .vertical ? y : x) + offset
                var value = UInt64(cross) &* 0x9e3779b185ebca87 ^ UInt64(along) &* 0xc2b2ae3d27d4eb4f ^ 7
                value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
                value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
                value ^= value >> 31
                let sample = UInt8(value % 216 + 20), index = (y * width + x) * 4
                bytes[index] = sample; bytes[index + 1] = sample; bytes[index + 2] = sample
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw ScrollStitchError.invalidPixels }
        return image
    }

    @MainActor private final class Gate {
        var waiting = false
        var continuation: CheckedContinuation<Void, Never>?
        func hold() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }
    private actor WriteGate {
        private(set) var url: URL?
        private var continuation: CheckedContinuation<Void, Never>?
        func hold(_ value: URL) async { url = value; await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }
    private static func memory() throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(GIFResourceMemoryReading.current()))
    }
    private static func wait(_ message: String, seconds: TimeInterval = 20, until condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw failure(message) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    private static func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }; return [view] + view.subviews.flatMap { descendants($0) }
    }
    private static func click(_ identifier: String, in controller: NSWindowController?) throws {
        let button = try unwrap(descendants(controller?.window?.contentView).first { $0.identifier?.rawValue == identifier } as? NSButton,
                                "Missing native control \(identifier)")
        try require(button.isEnabled, "Disabled native control \(identifier)"); button.performClick(nil)
    }
    private struct FixtureFailure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private static func failure(_ message: String) -> FixtureFailure { FixtureFailure(message: message) }
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw failure(message) }
    }
    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw failure(message) }; return value
    }
}
