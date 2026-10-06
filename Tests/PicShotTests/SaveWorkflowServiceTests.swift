import XCTest
import CoreGraphics
import Darwin
import PicShotCore
@testable import PicShot

final class SaveWorkflowServiceTests: XCTestCase {
    func testNamedSaveCreatesOnlyApprovedSubdirectoriesAndExactBytes() throws {
        try withDirectory { directory in
            let artifact = try makeArtifact()
            let settings = SaveWorkflowSettings(baseURL: directory, relativeFolderTemplate: "{date}/{width}x{height}", filenameTemplate: "capture-{counter}")
            let result = try SaveWorkflowService.publish(artifact, settings: settings, context: context)
            XCTAssertEqual(result.savedURL.path, directory.appendingPathComponent("1970-01-01/8x6/capture-1.png").path)
            XCTAssertEqual(try Data(contentsOf: result.savedURL), artifact.data)
            XCTAssertEqual(result.byteCount, artifact.data.count)
            XCTAssertEqual(result.clipboardOutcome, .notRequested)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: result.savedURL.deletingLastPathComponent().path), ["capture-1.png"])
        }
    }
    func testAskCollisionAndKeepBothNeverReplaceExistingBytes() throws {
        try withDirectory { directory in
            let artifact = try makeArtifact(), target = directory.appendingPathComponent("capture.png")
            let original = Data("private existing file".utf8); try original.write(to: target)
            XCTAssertThrowsError(try SaveWorkflowService.publish(artifact, to: target)) { error in
                guard case SaveWorkflowError.collision(let url) = error else { return XCTFail("Unexpected \(error)") }
                XCTAssertEqual(url, target)
            }
            let first = try SaveWorkflowService.publish(artifact, to: target, collisionBehavior: .keepBoth)
            let second = try SaveWorkflowService.publish(artifact, to: target, collisionBehavior: .keepBoth)
            XCTAssertEqual(first.savedURL.lastPathComponent, "capture (1).png")
            XCTAssertEqual(second.savedURL.lastPathComponent, "capture (2).png")
            XCTAssertEqual(try Data(contentsOf: target), original)
            XCTAssertEqual(try Data(contentsOf: first.savedURL), artifact.data)
            XCTAssertEqual(try Data(contentsOf: second.savedURL), artifact.data)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 3)
        }
    }
    func testRacingCollisionIsExclusiveAndKeepBothRetries() throws {
        try withDirectory { directory in
            let artifact = try makeArtifact(), target = directory.appendingPathComponent("race.png")
            let competitor = Data("new competing file".utf8)
            let saved = try SaveWorkflowService.publish(artifact, to: target, collisionBehavior: .keepBoth,
                                                        beforeCommit: { try competitor.write(to: target) })
            XCTAssertEqual(saved.savedURL.lastPathComponent, "race (1).png")
            XCTAssertEqual(try Data(contentsOf: target), competitor)
            XCTAssertEqual(try Data(contentsOf: saved.savedURL), artifact.data)
        }
    }
    func testRacingAskCollisionFailsWithoutDeletingCompetitor() throws {
        try withDirectory { directory in
            let artifact = try makeArtifact(), target = directory.appendingPathComponent("race.png")
            let competitor = Data("new competing file".utf8)
            XCTAssertThrowsError(try SaveWorkflowService.publish(artifact, to: target, beforeCommit: { try competitor.write(to: target) }))
            XCTAssertEqual(try Data(contentsOf: target), competitor)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["race.png"])
        }
    }
    func testCancellationBeforeAndImmediatelyBeforeCommitCreatesNoOutput() throws {
        try withDirectory { directory in
            let artifact = try makeArtifact(), target = directory.appendingPathComponent("cancel.png")
            let cancelled = ImageExportCancellation(); cancelled.cancel()
            XCTAssertThrowsError(try SaveWorkflowService.publish(artifact, to: target, cancellation: cancelled))
            let late = ImageExportCancellation()
            XCTAssertThrowsError(try SaveWorkflowService.publish(artifact, to: target, cancellation: late, beforeCommit: { late.cancel() }))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        }
    }
    func testExistingBaseRequiredAndValidationDoesNotCreateFolders() throws {
        try withDirectory { directory in
            try SaveWorkflowService.validateBaseDirectory(directory)
            let absent = directory.appendingPathComponent("absent")
            XCTAssertThrowsError(try SaveWorkflowService.validateBaseDirectory(absent))
            XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
            let settings = SaveWorkflowSettings(baseURL: absent)
            XCTAssertThrowsError(try SaveWorkflowService.publish(makeArtifact(), settings: settings, context: context))
            XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
        }
    }
    func testSymlinkBaseAndSubfolderNeverEscapeApprovedRoot() throws {
        try withDirectory { directory in
            let real = directory.appendingPathComponent("real"), outside = directory.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            let baseAlias = directory.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: baseAlias, withDestinationURL: real)
            XCTAssertThrowsError(try SaveWorkflowService.validateBaseDirectory(baseAlias))
            let subfolder = real.appendingPathComponent("subfolder")
            try FileManager.default.createSymbolicLink(at: subfolder, withDestinationURL: outside)
            let settings = SaveWorkflowSettings(baseURL: real, relativeFolderTemplate: "subfolder", filenameTemplate: "capture")
            XCTAssertThrowsError(try SaveWorkflowService.publish(makeArtifact(), settings: settings, context: context))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
        }
    }
    func testParentDirectoryReplacementDetectedBeforePublication() throws {
        try withDirectory { directory in
            let base = directory.appendingPathComponent("base"), moved = directory.appendingPathComponent("moved")
            let outside = directory.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            let settings = SaveWorkflowSettings(baseURL: base, filenameTemplate: "capture")
            XCTAssertThrowsError(try SaveWorkflowService.publish(makeArtifact(), settings: settings, context: context, beforeCommit: {
                try FileManager.default.moveItem(at: base, to: moved)
                try FileManager.default.createSymbolicLink(at: base, withDestinationURL: outside)
            })) { error in
                guard case SaveWorkflowError.changedDirectory = error else { return XCTFail("Unexpected \(error)") }
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: moved.path), [])
        }
    }
    func testDestinationSymlinkAndHardlinkSourceBytesPreserved() throws {
        try withDirectory { directory in
            let source = directory.appendingPathComponent("source.png"), link = directory.appendingPathComponent("link.png")
            let hard = directory.appendingPathComponent("hard.png"), bytes = Data("private-source".utf8)
            try bytes.write(to: source)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
            XCTAssertEqual(Darwin.link(source.path, hard.path), 0)
            let artifact = try makeArtifact(sourceURL: source)
            for target in [source, link, hard] { XCTAssertThrowsError(try SaveWorkflowService.publish(artifact, to: target)) }
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            XCTAssertEqual(try Data(contentsOf: hard), bytes)
            let kept = try SaveWorkflowService.publish(artifact, to: source, collisionBehavior: .keepBoth)
            XCTAssertEqual(kept.savedURL.lastPathComponent, "source (1).png")
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }
    func testRemovedSourcePathIsNotReused() throws {
        try withDirectory { directory in
            let source = directory.appendingPathComponent("source.png")
            // The snapshot records source identity by canonical path even after deletion.
            let artifact = try makeArtifact(sourceURL: source)
            XCTAssertThrowsError(try SaveWorkflowService.publish(artifact, to: source))
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        }
    }
    func testUnknownDimensionsWrongExtensionAndCorruptContextCreateNoFiles() throws {
        try withDirectory { directory in
            let artifact = try makeArtifact()
            XCTAssertThrowsError(try SaveWorkflowService.publish(artifact, to: directory.appendingPathComponent("wrong.jpg")))
            XCTAssertThrowsError(try SaveWorkflowService.publish(artifact, settings: SaveWorkflowSettings(baseURL: directory),
                                                                 context: SaveWorkflowContext(width: 9, height: 6, counter: 1)))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        }
    }
    func testExactSelectedFilenameNotTemplateExpandedAndAllNativeFormatsPreserved() throws {
        try withDirectory { directory in
            for format in ImageExportFormat.nativeFormats {
                let artifact = try makeArtifact(format: format)
                let url = directory.appendingPathComponent("chosen-{literal}-截图.\(format.filenameExtension)")
                let result = try SaveWorkflowService.publish(artifact, to: url)
                XCTAssertEqual(result.savedURL, url)
                XCTAssertEqual(try Data(contentsOf: result.savedURL), artifact.data)
            }
        }
    }
    @MainActor func testSaveThenCopyUsesExactSavedBytesAndCopyFailureDoesNotDelete() throws {
        try withDirectory { directory in
            let artifact = try makeArtifact(), target = directory.appendingPathComponent("saved.png")
            let saved = try SaveWorkflowService.publish(artifact, to: target)
            let copied = SaveWorkflowService.copySaved(saved) { bytes, type in
                XCTAssertEqual(bytes, artifact.data); XCTAssertEqual(type, "public.png"); return true
            }
            XCTAssertEqual(copied.clipboardOutcome, .copied)
            let failed = SaveWorkflowService.copySaved(saved, copier: { _, _ in false })
            XCTAssertEqual(failed.clipboardOutcome, .failed)
            XCTAssertEqual(try Data(contentsOf: target), artifact.data)
            let cancellation = ImageExportCancellation(); cancellation.cancel()
            let cancelled = SaveWorkflowService.copySaved(saved, cancellation: cancellation, copier: { _, _ in
                XCTFail("Cancellation after save must skip copying"); return true
            })
            XCTAssertEqual(cancelled.clipboardOutcome, .cancelledAfterSave)
            XCTAssertEqual(try Data(contentsOf: target), artifact.data)
        }
    }
    func testReplacingStagePayloadNeverDeletesForeignEntry() throws {
        try withDirectory { directory in
            let artifact = try makeArtifact(), target = directory.appendingPathComponent("capture.png")
            let foreign = Data("preserve this unexpected file".utf8)
            var foreignURL: URL?
            XCTAssertThrowsError(try SaveWorkflowService.publish(artifact, to: target, beforeCommit: {
                let name = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: directory.path).first { $0.hasPrefix(".picshot-save-") })
                let stage = directory.appendingPathComponent(name), payload = stage.appendingPathComponent("payload")
                try FileManager.default.moveItem(at: payload, to: stage.appendingPathComponent("original-payload"))
                try foreign.write(to: payload); foreignURL = payload
            }))
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(foreignURL)), foreign)
        }
    }
    func testSameInodeStageTamperingIsRejectedBeforePublication() throws {
        try withDirectory { directory in
            let artifact = try makeArtifact(), target = directory.appendingPathComponent("capture.png")
            XCTAssertThrowsError(try SaveWorkflowService.publish(artifact, to: target, beforeCommit: {
                let name = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: directory.path).first { $0.hasPrefix(".picshot-save-") })
                let payload = directory.appendingPathComponent(name).appendingPathComponent("payload")
                let handle = try FileHandle(forWritingTo: payload)
                defer { try? handle.close() }
                try handle.write(contentsOf: Data(repeating: 0, count: artifact.data.count))
            }))
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        }
    }
    func testSameInodeContentChangesAfterReadbackAreNotPublished() throws {
        for truncate in [false, true] {
            try withDirectory { directory in
                let artifact = try makeArtifact(), target = directory.appendingPathComponent("capture.png")
                let original = Data("keep-original".utf8); try original.write(to: target)
                let hooks = SaveWorkflowTestHooks(beforeCollisionAttempt: { attempt in
                    guard attempt == 1 else { return }
                    do {
                        let name = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: directory.path).first { $0.hasPrefix(".picshot-save-") })
                        let payload = directory.appendingPathComponent(name).appendingPathComponent("payload")
                        let handle = try FileHandle(forWritingTo: payload)
                        defer { try? handle.close() }
                        if truncate { try handle.truncate(atOffset: 0) }
                        else {
                            try handle.write(contentsOf: Data(repeating: 0, count: artifact.data.count))
                            // Explicit mtime makes this deterministic on lower-resolution test volumes.
                            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: payload.path)
                        }
                    } catch { XCTFail("Unable to inject mutation: \(error)") }
                })
                XCTAssertThrowsError(try SaveWorkflowService.publish(artifact, to: target, collisionBehavior: .keepBoth, testHooks: hooks))
                XCTAssertEqual(try Data(contentsOf: target), original)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["capture.png"])
            }
        }
    }
    func testCancellationReturnsWhileReadbackIsPausedAndPublishesNothing() throws {
        try withDirectory { directory in
            let target = directory.appendingPathComponent("capture.png")
            try assertCancellationWhilePaused(artifact: makeArtifact(), target: target, collisionAttempt: nil)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        }
    }
    func testCancellationBetweenManyCollisionAttemptsReturnsWithoutWaitingForSearch() throws {
        try withDirectory { directory in
            let target = directory.appendingPathComponent("capture.png"), existing = Data("keep-original".utf8)
            try existing.write(to: target)
            for index in 1...30 { try existing.write(to: directory.appendingPathComponent("capture (\(index)).png")) }
            try assertCancellationWhilePaused(artifact: makeArtifact(), target: target, collisionAttempt: 25)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 31)
            XCTAssertEqual(try Data(contentsOf: target), existing)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("capture (31).png").path))
        }
    }
    private func assertCancellationWhilePaused(artifact: ImageExportArtifact, target: URL, collisionAttempt: Int?) throws {
        let reached = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let workerFinished = DispatchSemaphore(value: 0), cancelReturned = DispatchSemaphore(value: 0)
        let cancellation = ImageExportCancellation()
        let pause: (Int) -> Void = { value in
            guard value == (collisionAttempt ?? 0) else { return }
            reached.signal(); _ = resume.wait(timeout: .now() + 5)
        }
        let hooks = collisionAttempt == nil
            ? SaveWorkflowTestHooks(beforeReadbackChunk: pause)
            : SaveWorkflowTestHooks(beforeCollisionAttempt: pause)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { workerFinished.signal() }
            do {
                _ = try SaveWorkflowService.publish(artifact, to: target, collisionBehavior: .keepBoth,
                                                     cancellation: cancellation, testHooks: hooks)
                XCTFail("Cancellation must win while publication is paused outside the fence")
            } catch is CancellationError { }
            catch { XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(reached.wait(timeout: .now() + 3), .success)
        // Run the cancellation separately so a fence regression yields a bounded
        // assertion failure, never an indefinitely deadlocked XCTest process.
        DispatchQueue.global(qos: .userInitiated).async { cancellation.cancel(); cancelReturned.signal() }
        let returned = cancelReturned.wait(timeout: .now() + 2)
        resume.signal()
        XCTAssertEqual(returned, .success, "UI cancellation must not wait for bulk readback or collision search")
        XCTAssertEqual(workerFinished.wait(timeout: .now() + 3), .success)
        if returned != .success { XCTAssertEqual(cancelReturned.wait(timeout: .now() + 3), .success) }
    }
    private var context: SaveWorkflowContext { SaveWorkflowContext(date: Date(timeIntervalSince1970: 0), width: 8, height: 6, counter: 1) }
    private func makeArtifact(format: ImageExportFormat = .png, sourceURL: URL? = nil) throws -> ImageExportArtifact {
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(gray: 0, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        let image = try XCTUnwrap(bitmap.makeImage())
        return try ImageExportService.encode(snapshot: ImageExportSnapshot(image: image, sourceURL: sourceURL), options: ImageExportOptions(format: format))
    }
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("PicShot-save-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }; try body(directory)
    }
}
