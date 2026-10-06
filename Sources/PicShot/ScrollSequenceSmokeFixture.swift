import AppKit
import ImageIO
import PicShotCore

/// Installed-app, synthetic native-controller evidence. This never captures the desktop,
/// requests permission, posts scroll events or changes the user's general clipboard.
@MainActor
enum ScrollSequenceSmokeFixture {
    static func verify(evidenceDirectory: URL) async throws -> [String: Any] {
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let reportURL = evidenceDirectory.appendingPathComponent("scroll-sequence.json")
        var report: [String: Any] = [
            "status": "running", "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "sourceProvenance": "original deterministic coordinate-hashed RGB fixtures, generated locally",
            "scope": "real native scroll-controller acceptance/buttons, reverse auto-crop in both start directions, arbitrary cross-source preview band drags, edited PNG pixels, editor pin callback, private PNG clipboard representation, temporary-source preservation and in-flight cancellation cleanup",
            "screenCaptureStarted": false, "permissionRequested": false, "inputEventsPosted": 0,
            "generalClipboardChanged": false,
            "snapshotBackground": "effective NSWindow background; cached transparent content is composited before encoding",
            "snapshotCaption": "合成纹理接缝测试（非真实页面）; verification window PNGs only, never captured/output image pixels",
            "limitations": ["Synthetic fixtures do not establish live third-party app, Retina or input-routing acceptance",
                            "Memory readings are sampled process observations at small fixture sizes, not maximum-size or zero-leak acceptance",
                            "Copy evidence uses the same PNG representation on a private pasteboard; the system Copy button is not invoked"],
            "maximumBlocks": ScrollCaptureSequence.maximumBlocks,
            "maximumOutputPixels": ScrollCaptureSequence.maximumOutputPixels,
            "maximumOutputDimension": ScrollCaptureSequence.maximumOutputDimension,
            "maximumOutputRasterBytes": ScrollCaptureSequence.maximumRasterBytes,
            "maximumTemporarySourceBytes": 512 * 1024 * 1024
        ]
        do {
            let baseline = GIFResourceMemoryReading.current()
            report["memoryBefore"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(baseline))
            var axes: [[String: Any]] = []
            for axis in ScrollAxis.allCases {
                axes.append(try await cycle(axis: axis, directory: evidenceDirectory))
                report["axes"] = axes
            }
            var automaticCropping: [[String: Any]] = []
            for axis in ScrollAxis.allCases {
                for sign in [1, -1] { automaticCropping.append(try await autoCropCycle(axis: axis, sign: sign, directory: evidenceDirectory)) }
            }
            report["reverseAutoCrop"] = automaticCropping
            report["diskLimitRefusal"] = try await diskLimitCheck()
            report["inFlightCancellationCleanup"] = try await inFlightCleanupCheck()
            report["memoryAfter"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(GIFResourceMemoryReading.current()))
            report["status"] = "passed"
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
            return report
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
            throw error
        }
    }

    private static func cycle(axis: ScrollAxis, directory: URL) async throws -> [String: Any] {
        var completion: CGImage?, completionCount = 0
        var controller: ScrollCaptureController? = ScrollCaptureController { image in completion = image; completionCount += 1 }
        guard let live = controller else { throw failure("Missing scroll controller") }
        defer { live.close() }
        live.showWindow(nil)
        try await live.setAutoCropForVerification(false)
        let offsets = [100, 147, 198, 157, 90, 138, 218]
        let expectedContributions = [true, true, true, false, true, false, true]
        var evidence: [[String: Any]] = []
        for (index, offset) in offsets.enumerated() {
            let beforeBytes = live.diskBytesForVerification, beforeURLs = live.sourceURLsForVerification
            let added = try await live.acceptForVerification(image(axis: axis, offset: offset), axis: axis)
            try require(added == expectedContributions[index], "Wrong contribution for \(axis.rawValue) offset \(offset)")
            if !added {
                try require(live.diskBytesForVerification == beforeBytes && live.sourceURLsForVerification == beforeURLs,
                            "A revisit duplicated a stored source")
            }
            if let match = live.lastMatch, let quality = match.evidence {
                evidence.append(["advance": match.advance, "overlap": match.overlap, "meanError": quality.meanError,
                                 "badFraction": quality.badFraction, "worstBandError": quality.worstBandError,
                                 "texture": quality.texture, "uniquenessMargin": quality.uniquenessMargin ?? -1,
                                 "addedBlock": added])
            }
        }
        let sequence = try unwrap(live.sequenceForVerification, "Missing accepted sequence")
        try require(sequence.blocks.count == 5, "Wrong accepted block count")
        let full = try live.currentOutputForVerification()
        let expectedFull = try image(axis: axis, offset: 90, length: 268)
        try require(try pixels(full) == pixels(expectedFull), "Reverse extension/export duplicated, dropped or reordered pixels")
        let fullPreview = try unwrap(live.previewImageForVerification, "Missing full preview raster")
        try require(try pixels(fullPreview) == pixels(expectedFull), "Full preview and export differ at 1:1")
        try require(live.retainedGrayPixelsForVerification == 96 * 140, "More than one full grayscale viewport is retained")
        try require(live.previewPixelsForVerification <= 800 * 800, "Preview raster exceeds its bound")
        let sourceURLs = live.sourceURLsForVerification
        let sourceBytes = try sourceURLs.map { try Data(contentsOf: $0) }
        let temp = try unwrap(live.temporaryDirectoryForVerification, "Missing spool directory")
        let diskBytes = live.diskBytesForVerification
        try require(try FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil).count == 5,
                    "Unexpected temporary source files")

        // Independent content and fixed/dynamic regions cannot alter accepted state.
        var refused = 0
        for kind in ["independent", "fixed", "dynamic", "color", "stationaryColor"] {
            do {
                let offset = kind == "stationaryColor" ? 218 : 178
                _ = try await live.acceptForVerification(image(axis: axis, offset: offset, alteration: kind), axis: axis)
                throw failure("Accepted unreliable \(kind) overlap")
            } catch is FixtureFailure { throw failure("Accepted unreliable \(kind) overlap") }
            catch let error as ScrollStitchError where kind == "stationaryColor" && error == .duplicate {
                throw failure("Changed stationary color was reported unchanged")
            }
            catch { refused += 1 }
            try require(live.sourceURLsForVerification == sourceURLs && live.diskBytesForVerification == diskBytes,
                        "Refusal changed committed sources")
        }
        // A true repeated pattern is ambiguous in both directions at the core boundary.
        let repeatedA = try repeatedFrame(axis: axis, offset: 10), repeatedB = try repeatedFrame(axis: axis, offset: 5)
        do {
            _ = try ScrollStitcher.matchBidirectional(previous: repeatedA, next: repeatedB, axis: axis)
            throw failure("Repeated content was assigned a confident seam")
        } catch let error as ScrollStitchError { try require(error == .ambiguousOverlap, "Unexpected repeated-content refusal") }

        try click("scroll.trim", in: live)
        let preview: ScrollSequencePreview = try control("scroll.preview", in: live)
        live.window?.contentView?.layoutSubtreeIfNeeded()
        let selected = sequence.blocks[2]
        let layout = try sequence.layout()
        let strip = try unwrap(layout.strips.first(where: { $0.block.id == selected.id }), "Missing middle strip")
        let fraction = CGFloat(strip.outputStart) + CGFloat(strip.block.length) / 2
        let rect = preview.imageRect
        let point = axis == .vertical
            ? CGPoint(x: rect.midX, y: rect.minY + fraction / CGFloat(layout.height) * rect.height)
            : CGPoint(x: rect.minX + fraction / CGFloat(layout.width) * rect.width, y: rect.midY)
        try require(preview.block(at: point) == selected.id, "Preview hit-testing selected the wrong block")
        let event = try unwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: preview.convert(point, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: live.window?.windowNumber ?? 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1), "Cannot construct preview click")
        preview.mouseDown(with: event)
        try click("scroll.delete", in: live); await live.waitForOperationForVerification()
        try require(live.removedBlocksForVerification == [selected.id], "Middle block was not deleted")
        let expectedCut = try image(axis: axis, offset: 90, length: 268, excluding: 240..<287)
        try require(try pixels(live.currentOutputForVerification()) == pixels(expectedCut), "Middle cut did not compact exact source pixels")
        let cutPreview = try unwrap(live.previewImageForVerification, "Missing cut preview raster")
        try require(try pixels(cutPreview) == pixels(expectedCut), "Cut preview differs from export at 1:1")
        try await snapshot(live, to: directory.appendingPathComponent("scroll-\(axis.rawValue)-trim.png"))
        try click("scroll.undo", in: live); await live.waitForOperationForVerification()
        try require(live.removedBlocksForVerification.isEmpty, "Undo did not restore block")
        try click("scroll.redo", in: live); await live.waitForOperationForVerification()
        try require(live.removedBlocksForVerification == [selected.id], "Redo did not reapply deletion")
        try click("scroll.cancel", in: live); await live.waitForOperationForVerification()
        try require(live.removedBlocksForVerification.isEmpty, "Cancel did not restore trim-entry projection")
        try require(try pixels(live.currentOutputForVerification()) == pixels(expectedFull), "Cancel changed original pixels")
        let restoredPreview = try unwrap(live.previewImageForVerification, "Missing restored preview raster")
        try require(try pixels(restoredPreview) == pixels(expectedFull), "Cancel did not restore preview pixels")
        try click("scroll.trim", in: live)
        let picker: NSPopUpButton = try control("scroll.blocks", in: live)
        let item = try unwrap(picker.itemArray.first { ($0.representedObject as? UUID) == selected.id }, "Missing middle block menu item")
        picker.select(item)
        try require(picker.sendAction(picker.action, to: picker.target), "Block menu action did not dispatch")
        try click("scroll.delete", in: live); await live.waitForOperationForVerification()
        try click("scroll.apply", in: live)
        // Reopen + a different deletion + Cancel must preserve already applied cuts.
        try click("scroll.trim", in: live)
        try click("scroll.delete", in: live); await live.waitForOperationForVerification()
        try click("scroll.cancel", in: live); await live.waitForOperationForVerification()
        try require(live.removedBlocksForVerification == [selected.id], "Cancel erased a previously applied cut")
        for (index, url) in sourceURLs.enumerated() {
            try require(try Data(contentsOf: url) == sourceBytes[index], "Trimming overwrote an immutable source")
        }
        try click("scroll.finish", in: live); await live.waitForOperationForVerification()
        let handedOff = try unwrap(completion, "Finish did not call the editor handoff")
        try require(completionCount == 1, "Finish delivered more than once")
        try require(try pixels(handedOff) == pixels(expectedCut), "Editor handoff differs from edited preview")
        let outputURL = directory.appendingPathComponent("scroll-\(axis.rawValue)-output.png")
        try ScrollImageIO.writePNG(handedOff, to: outputURL)
        let reopened = try ScrollImageIO.readImage(at: outputURL)
        try require(try pixels(reopened) == pixels(expectedCut), "PNG export changed edited output")
        try require(!FileManager.default.fileExists(atPath: temp.path), "Finish did not remove the temporary source directory")
        try require(live.sourceURLsForVerification.isEmpty && live.retainedGrayPixelsForVerification == 0,
                    "Finish retained session sources or grayscale")
        let handoff = try verifyEditorPinAndCopy(handedOff, expected: expectedCut)
        controller = nil
        return ["axis": axis.rawValue, "motionEvidence": evidence, "sourceBlocks": 5,
                "deduplicatedRevisits": 2, "refusedUnreliableSamples": refused,
                "repeatedPatternRefused": true, "middleCutPixels": selected.length,
                "undoRedoCancelApplyPassed": true, "previewHitTestPassed": true, "previewExportPixelEquality": true,
                "originalSourceBytesPreserved": true, "temporaryBytes": diskBytes,
                "temporaryDirectoryRemoved": true, "completionCount": completionCount,
                "outputWidth": handedOff.width, "outputHeight": handedOff.height,
                "handoff": handoff, "closeRelease": try await closeReleaseCycle(axis: axis)]
    }

    private static func autoCropCycle(axis: ScrollAxis, sign: Int, directory: URL) async throws -> [String: Any] {
        let controller = ScrollCaptureController { _ in }
        defer { controller.close() }
        controller.showWindow(nil)
        for offset in [300, 300 + sign * 60, 300 + sign * 100] {
            _ = try await controller.acceptForVerification(image(axis: axis, offset: offset), axis: axis)
        }
        let lower = sign > 0 ? 300 : 200
        let full = try image(axis: axis, offset: lower, length: 240)
        try require(try pixels(controller.currentOutputForVerification()) == pixels(full), "Auto-crop did not extend in the initial direction")
        try require(controller.captureDirectionForVerification == sign, "Initial direction was not established")
        let sources = controller.sourceURLsForVerification, bytes = controller.diskBytesForVerification
        _ = try await controller.acceptForVerification(image(axis: axis, offset: 300 + sign * 75), axis: axis)
        let shortenedLower = sign > 0 ? 300 : 225
        let shortened = try image(axis: axis, offset: shortenedLower, length: 215)
        try require(try pixels(controller.currentOutputForVerification()) == pixels(shortened), "Reverse did not trim exactly 25 output pixels")
        try require(controller.sourceURLsForVerification == sources && controller.diskBytesForVerification == bytes, "Reverse crop duplicated source files")
        // Undo of the capture-generated crop is available as soon as Trim opens.
        try click("scroll.trim", in: controller)
        try click("scroll.undo", in: controller); await controller.waitForOperationForVerification()
        try require(try pixels(controller.currentOutputForVerification()) == pixels(full), "Undo did not recover auto-cropped edge")
        try click("scroll.cancel", in: controller); await controller.waitForOperationForVerification()
        try require(try pixels(controller.currentOutputForVerification()) == pixels(shortened), "Cancel did not restore auto-crop entry interval")
        _ = try await controller.acceptForVerification(image(axis: axis, offset: 300 + sign * 100), axis: axis)
        try require(try pixels(controller.currentOutputForVerification()) == pixels(full), "Forward movement did not restore captured edge")
        try require(controller.sourceURLsForVerification == sources, "Forward restoration rewrote a captured source")

        let start = sign > 0 ? 130 : 30
        let band = start..<(start + 80)
        let documentCut = (lower + start)..<(lower + start + 80)
        let cut = try image(axis: axis, offset: lower, length: 240, excluding: documentCut)
        try click("scroll.trim", in: controller)
        try dragBand(band, in: controller, axis: axis)
        try click("scroll.delete", in: controller); await controller.waitForOperationForVerification()
        try require(try pixels(controller.currentOutputForVerification()) == pixels(cut), "Arbitrary cross-source band deletion changed surviving pixels")
        try require(try pixels(unwrap(controller.previewImageForVerification, "Missing band preview")) == pixels(cut), "Band preview differs from export")
        try await snapshot(controller, to: directory.appendingPathComponent("scroll-\(axis.rawValue)-\(sign > 0 ? "positive" : "negative")-band.png"))
        try click("scroll.undo", in: controller); await controller.waitForOperationForVerification()
        try require(try pixels(controller.currentOutputForVerification()) == pixels(full), "Band Undo failed")
        try click("scroll.redo", in: controller); await controller.waitForOperationForVerification()
        try require(try pixels(controller.currentOutputForVerification()) == pixels(cut), "Band Redo failed")
        try click("scroll.cancel", in: controller); await controller.waitForOperationForVerification()
        try require(try pixels(controller.currentOutputForVerification()) == pixels(full), "Band Cancel failed")
        try click("scroll.trim", in: controller)
        try typeBand(band, in: controller)
        try click("scroll.delete", in: controller); await controller.waitForOperationForVerification()
        try click("scroll.apply", in: controller)
        _ = try await controller.acceptForVerification(image(axis: axis, offset: 300 + sign * 75), axis: axis)
        let croppedWithCut = try image(axis: axis, offset: shortenedLower, length: 215, excluding: documentCut)
        try require(try pixels(controller.currentOutputForVerification()) == pixels(croppedWithCut), "Reverse crop lost manual range cuts")
        let interval = controller.activeRangeForVerification, cuts = controller.excludedRangesForVerification
        try click("scroll.trim", in: controller)
        try click("scroll.restoreEdges", in: controller); await controller.waitForOperationForVerification()
        try require(try pixels(controller.currentOutputForVerification()) == pixels(cut), "Restore edges also restored an intentional middle cut")
        try typeBand(1..<3, in: controller)
        try click("scroll.delete", in: controller); await controller.waitForOperationForVerification()
        try click("scroll.cancel", in: controller); await controller.waitForOperationForVerification()
        try require(controller.activeRangeForVerification == interval && controller.excludedRangesForVerification == cuts,
                    "Cancel did not restore both active interval and arbitrary cuts")
        try require(try pixels(controller.currentOutputForVerification()) == pixels(croppedWithCut), "Cancel changed interval/cut source pixels")
        _ = try await controller.acceptForVerification(image(axis: axis, offset: 300 + sign * 100), axis: axis)
        try require(try pixels(controller.currentOutputForVerification()) == pixels(cut), "Forward restoration erased manual cuts")
        try click("scroll.resetDirection", in: controller)
        try require(controller.captureDirectionForVerification == nil, "Explicit direction reset failed")
        try require(try pixels(controller.currentOutputForVerification()) == pixels(cut), "Direction reset changed output")
        try await controller.setAutoCropForVerification(false)
        try require(controller.excludedRangesForVerification == cuts, "Mode toggle erased manual cuts")
        try await controller.setAutoCropForVerification(true)
        try require(controller.captureDirectionForVerification == nil, "Mode toggle did not reset direction")
        // A new independent viewport-only session verifies automatic reset at the minimum extent.
        let reset = ScrollCaptureController { _ in }
        defer { reset.close() }
        for offset in [300, 300 + sign * 60, 300] {
            _ = try await reset.acceptForVerification(image(axis: axis, offset: offset), axis: axis)
        }
        try require(reset.captureDirectionForVerification == nil, "Direction did not reset at one viewport")
        try require(try pixels(reset.currentOutputForVerification()) == pixels(image(axis: axis, offset: 300)), "One-viewport reset retained cropped edge pixels")
        return ["axis": axis.rawValue, "initialDirection": sign, "reversePixelsRemoved": 25,
                "restoredWithoutSourceDuplication": true, "arbitraryBandPixelsRemoved": 80,
                "bandCrossedSourceBoundaries": 2, "sourceCropCoordinatesPreserved": true,
                "manualCutsSurviveForwardRestoration": true, "cancelRestoresIntervalAndCuts": true,
                "autoCropUndo": true, "minimumExtentDirectionReset": true, "explicitAndModeDirectionReset": true]
    }

    private static func typeBand(_ range: Range<Int>, in controller: NSWindowController) throws {
        let start: NSTextField = try control("scroll.bandStart", in: controller)
        let length: NSTextField = try control("scroll.bandLength", in: controller)
        start.stringValue = String(range.lowerBound); length.stringValue = String(range.count)
        try click("scroll.selectBand", in: controller)
    }

    private static func dragBand(_ range: Range<Int>, in controller: NSWindowController, axis: ScrollAxis) throws {
        let preview: ScrollSequencePreview = try control("scroll.preview", in: controller)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let layout = try unwrap(preview.layout, "Missing drag-selection layout")
        let rect = preview.imageRect
        let total = CGFloat(axis == .vertical ? layout.height : layout.width)
        func event(_ type: NSEvent.EventType, at pixel: CGFloat) throws -> NSEvent {
            let point = axis == .vertical ? CGPoint(x: rect.midX, y: rect.minY + pixel / total * rect.height)
                                         : CGPoint(x: rect.minX + pixel / total * rect.width, y: rect.midY)
            return try unwrap(NSEvent.mouseEvent(with: type, location: preview.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: controller.window?.windowNumber ?? 0,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1), "Cannot construct band drag")
        }
        preview.mouseDown(with: try event(.leftMouseDown, at: CGFloat(range.lowerBound) + 0.5))
        preview.mouseDragged(with: try event(.leftMouseDragged, at: CGFloat(range.upperBound) - 0.5))
        preview.mouseUp(with: try event(.leftMouseUp, at: CGFloat(range.upperBound) - 0.5))
        try require(preview.selectedRange == range, "Native band drag selected the wrong pixel interval")
    }

    private actor SourceWriteGate {
        var arrived = false
        var arrivalWaiter: CheckedContinuation<Void, Error>?
        var failure: Error?
        var releaseWaiter: CheckedContinuation<Void, Never>?
        func park() async {
            arrived = true; arrivalWaiter?.resume(returning: ()); arrivalWaiter = nil
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        func waitForArrival() async throws {
            if let failure { throw failure }
            if arrived { return }
            try await withCheckedThrowingContinuation { arrivalWaiter = $0 }
        }
        func failed(_ error: Error) { failure = error; arrivalWaiter?.resume(throwing: error); arrivalWaiter = nil }
        func release() { releaseWaiter?.resume(); releaseWaiter = nil }
    }

    private static func inFlightCleanupCheck() async throws -> Bool {
        for closeDuringWrite in [false, true] {
            var completions = 0
            let controller = ScrollCaptureController { _ in completions += 1 }
            defer { controller.close() }
            _ = try await controller.acceptForVerification(image(axis: .vertical, offset: 100), axis: .vertical)
            let directory = try unwrap(controller.temporaryDirectoryForVerification, "Missing in-flight directory")
            let committedURLs = controller.sourceURLsForVerification
            let gate = SourceWriteGate()
            controller.sourceWriteBarrierForVerification = { _ in await gate.park() }
            let sample = try image(axis: .vertical, offset: 150)
            let operation = Task { @MainActor in
                do { return try await controller.acceptForVerification(sample, axis: .vertical) }
                catch { await gate.failed(error); throw error }
            }
            try await gate.waitForArrival()
            try require(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count == 2,
                        "In-flight fixture did not reach a real completed source write")
            if closeDuringWrite { controller.close() } else { operation.cancel() }
            await gate.release()
            do { _ = try await operation.value; throw failure("Late sample committed after cancellation/close") }
            catch is FixtureFailure { throw failure("Late sample committed after cancellation/close") }
            catch { }
            try require(completions == 0, "Canceled sample invoked completion")
            if closeDuringWrite {
                try require(!FileManager.default.fileExists(atPath: directory.path) && controller.sourceURLsForVerification.isEmpty,
                            "Close failed to remove an in-flight source")
            } else {
                try require(controller.sourceURLsForVerification == committedURLs, "Cancellation changed accepted sources")
                try require(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count == 1,
                            "Cancellation left an uncommitted PNG")
            }
        }
        return true
    }

    private static func verifyEditorPinAndCopy(_ image: CGImage, expected: CGImage) throws -> [String: Any] {
        var pinned: CGImage?
        let editor = ImageEditorController(image: image, onSave: { _ in }, onPin: { pinned = $0 }, onOCR: { _ in })
        defer { editor.close() }
        editor.showWindow(nil); editor.window?.contentView?.layoutSubtreeIfNeeded()
        let button = try unwrap(descendants(editor.window?.contentView).first { $0.identifier?.rawValue == "editor.pin" } as? NSButton,
                                "Missing editor pin action")
        try require(button.isEnabled, "Editor pin action unavailable")
        button.performClick(nil)
        let pinImage = try unwrap(pinned, "Editor pin callback was not called")
        try require(try pixels(pinImage) == pixels(expected), "Editor flattened away scroll cuts")
        let pin = PinController(image: pinImage)
        defer { pin.close() }
        try require(try pixels(pin.currentImage) == pixels(expected), "Pin did not retain edited scroll output")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let png = try unwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]), "PNG clipboard representation failed")
        try require(board.setData(png, forType: .png), "Private clipboard PNG write failed")
        let payload = try unwrap(board.data(forType: .png), "Private clipboard PNG missing")
        let source = try unwrap(CGImageSourceCreateWithData(payload as CFData, nil), "Cannot decode clipboard PNG")
        let copied = try unwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), "Clipboard PNG has no image")
        try require(try pixels(copied) == pixels(expected), "Clipboard representation differs from edited output")
        return ["editorPinAction": true, "nativePinPixels": true, "privatePNGClipboardRoundTrip": true]
    }

    private static func closeReleaseCycle(axis: ScrollAxis) async throws -> Bool {
        var controller: ScrollCaptureController? = ScrollCaptureController { _ in }
        weak var weakController = controller
        _ = try await controller?.acceptForVerification(image(axis: axis, offset: 100), axis: axis)
        let url = try unwrap(controller?.temporaryDirectoryForVerification, "Missing close-cycle source")
        controller?.close(); controller = nil
        try await Task.sleep(nanoseconds: 20_000_000)
        try require(weakController == nil, "Closed scroll controller remains retained")
        try require(!FileManager.default.fileExists(atPath: url.path), "Close leaked temporary sources")
        return true
    }

    private static func diskLimitCheck() async throws -> Bool {
        let controller = ScrollCaptureController(storageLimitBytes: 1) { _ in }
        defer { controller.close() }
        do {
            _ = try await controller.acceptForVerification(image(axis: .vertical, offset: 100), axis: .vertical)
            throw failure("Disk limit accepted an oversized PNG")
        } catch is FixtureFailure { throw failure("Disk limit accepted an oversized PNG") }
        catch { }
        try require(controller.sourceURLsForVerification.isEmpty && controller.diskBytesForVerification == 0,
                    "Disk refusal committed a source")
        let root = try unwrap(controller.temporaryDirectoryForVerification, "Missing disk-refusal spool")
        try require(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).isEmpty,
                    "Disk refusal left a partial file")
        controller.close()
        try require(!FileManager.default.fileExists(atPath: root.path), "Disk refusal cleanup failed")
        return true
    }

    static func image(axis: ScrollAxis, offset: Int, length: Int = 140,
                      excluding: Range<Int>? = nil, alteration: String? = nil) throws -> CGImage {
        let coordinates = (offset..<(offset + length)).filter { !(excluding?.contains($0) ?? false) }
        let width = axis == .vertical ? 96 : coordinates.count
        let height = axis == .vertical ? coordinates.count : 96
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let along = axis == .vertical ? y : x, across = axis == .vertical ? x : y
                var world = coordinates[along]
                if alteration == "fixed", along < 60 { world = 218 + along }
                var value = hash(across: across, along: world, seed: alteration == "independent" ? 991 : 7)
                if alteration == "dynamic", along == 70, across == 20 { value = value > 127 ? 0 : 255 }
                let index = (y * width + x) * 4
                data[index] = value; data[index + 1] = value; data[index + 2] = value
                if alteration == "color" || alteration == "stationaryColor" {
                    data[index] = UInt8(clamping: Int(value) + 16)
                    data[index + 1] = UInt8(clamping: Int(value) - 8)
                }
            }
        }
        let provider = try unwrap(CGDataProvider(data: Data(data) as CFData), "Missing synthetic image provider")
        return try unwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent), "Cannot create synthetic scroll image")
    }

    private static func hash(across: Int, along: Int, seed: UInt64) -> UInt8 {
        var value = UInt64(across) &* 0x9e3779b185ebca87
        value ^= UInt64(along) &* 0xc2b2ae3d27d4eb4f; value ^= seed
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb; value ^= value >> 31
        return UInt8(value % 216 + 20)
    }

    private static func repeatedFrame(axis: ScrollAxis, offset: Int) throws -> ScrollFrame {
        let width = axis == .vertical ? 96 : 140, height = axis == .vertical ? 140 : 96
        let pixels = (0..<(width * height)).map { index -> UInt8 in
            let along = axis == .vertical ? index / width : index % width
            let cross = axis == .vertical ? index % width : index / width
            return UInt8((((along + offset) % 16) * 17 + cross * 29) % 256)
        }
        return try ScrollFrame(width: width, height: height, grayscale: pixels)
    }

    static func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try unwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), "Cannot inspect output pixels")
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private static func snapshot(_ controller: NSWindowController, to url: URL) async throws {
        try await Task.sleep(nanoseconds: 80_000_000)
        let window = try unwrap(controller.window, "Missing scroll window")
        let view = try unwrap(window.contentView, "Missing scroll view")
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let width = Int(view.bounds.width.rounded(.up)), height = Int(view.bounds.height.rounded(.up))
        try require(width > 0 && width <= 1_200 && height > 0 && height <= 1_000, "Unbounded scroll window snapshot")
        let bitmap = try unwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4, bitsPerPixel: 32), "Cannot allocate scroll window snapshot")
        bitmap.size = view.bounds.size; view.cacheDisplay(in: view.bounds, to: bitmap)
        let cached = try unwrap(bitmap.cgImage, "Empty scroll window snapshot")
        let context = try unwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), "Cannot composite scroll snapshot background")
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            context.setFillColor(window.backgroundColor.cgColor)
            context.fill(bounds)
            context.draw(cached, in: bounds)
            // Evidence-only caption. Never draw into a source, preview, export or handoff.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSAttributedString(string: "合成纹理接缝测试（非真实页面）", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor
            ]).draw(at: CGPoint(x: 20, y: 20))
            NSGraphicsContext.restoreGraphicsState()
        }
        let composited = try unwrap(context.makeImage(), "Empty composited scroll window snapshot")
        try ScrollImageIO.writePNG(composited, to: url)
    }
    private static func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }; return [view] + view.subviews.flatMap { descendants($0) }
    }
    private static func control<T: NSView>(_ id: String, in controller: NSWindowController) throws -> T {
        try unwrap(descendants(controller.window?.contentView).first { $0.identifier?.rawValue == id } as? T, "Missing control \(id)")
    }
    private static func click(_ id: String, in controller: NSWindowController) throws {
        let button: NSButton = try control(id, in: controller)
        try require(button.isEnabled && !button.isHiddenOrHasHiddenAncestor, "Unavailable control \(id)")
        button.performClick(nil)
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
