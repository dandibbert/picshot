import XCTest
import Foundation
import Darwin
@testable import PicShot

final class GIFProcessTests: XCTestCase {
    func testSignedSameExecutableHelperExportsChangingFramesThenExitsAndCleansUp() async throws {
        let app = try GIFProcessTestApplication.make()
        defer { app.cleanup() }
        let profile = GIFResourceSmokeFixture.Profile.quickTest
        let source = try await GIFResourceSmokeFixture.makeMovie(in: app.root, profile: profile)
        let sourceBefore = try Data(contentsOf: source)
        let destination = app.root.appendingPathComponent("export.gif")
        let service = app.service()
        let progress = GIFProcessTestProgress()
        let operation = InferenceTestOperation {
            try await service.export(sourceURL: source, destinationURL: destination,
                                     options: profile.options) { progress.record($0) }
        }
        defer { operation.cancel() }
        let result = try await GIFProcessTestDiagnostics.run(service: service, phase: "signed GIF helper export") {
            try await operation.value(timeout: 35, phase: "signed GIF helper export")
        }
        XCTAssertEqual(result, destination)
        let plan = try GIFFramePlan(duration: profile.duration, options: profile.options)
        let decoded = try GIFResourceSmokeFixture.validate(output: result, profile: profile, plan: plan)
        XCTAssertEqual(decoded["framesDecoded"] as? Int, 24)
        XCTAssertEqual(decoded["dimensions"] as? [String], ["96x54"])
        XCTAssertEqual(decoded["distinctDecodedThumbnailFingerprints"] as? Int, 24)
        XCTAssertEqual(try Data(contentsOf: source), sourceBefore)
        let metrics = try await finished(service, childLaunched: true)
        XCTAssertEqual(metrics.outcome, "succeeded")
        XCTAssertEqual(metrics.terminationStatus, 0)
        XCTAssertGreaterThan(metrics.childResidentSampleCount, 0)
        XCTAssertGreaterThan(try XCTUnwrap(metrics.childSampledPeakResidentBytes), 0)
        XCTAssertGreaterThan(try XCTUnwrap(metrics.parentSampledPeakResidentBytes), 0)
        if let footprint = metrics.childReportedPeakPhysicalFootprintBytes { XCTAssertGreaterThan(footprint, 0) }
        XCTAssertFalse(metrics.stderrTruncated)
        let values = progress.values
        XCTAssertEqual(values.first, 0)
        XCTAssertEqual(values.last, 1)
        XCTAssertTrue(values.allSatisfy { $0.isFinite && (0...1).contains($0) })
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0.0 <= $0.1 })
        XCTAssertEqual(values.filter { $0 == 1 }.count, 1)
        try assertNoStaging(app.root)
    }

    func testCancellingRealHelperAfterFrameProgressConfirmsExitBeforeReturning() async throws {
        let app = try GIFProcessTestApplication.make()
        defer { app.cleanup() }
        let profile = GIFResourceSmokeFixture.Profile.quickTest
        let source = try await GIFResourceSmokeFixture.makeMovie(in: app.root, profile: profile)
        let sourceBefore = try Data(contentsOf: source)
        let destination = app.root.appendingPathComponent("cancelled.gif")
        let service = app.service()
        let progress = GIFProcessTestProgress()
        let cancellation = GIFProcessTestCancellation()
        let operation = InferenceTestOperation {
            try await service.export(sourceURL: source, destinationURL: destination, options: profile.options) { value in
                progress.record(value)
                if value > 0, value < 1 { cancellation.request() }
            }
        }
        cancellation.install { operation.cancel() }
        defer { cancellation.clear(); operation.cancel() }
        do {
            _ = try await operation.value(timeout: 35, phase: "cancelled signed GIF helper exit")
            XCTFail("Cancelled helper must not publish a GIF")
        } catch {
            if !(error is CancellationError) {
                await GIFProcessTestDiagnostics.record(service: service, phase: "real-helper cancellation", detail: String(describing: error))
            }
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }
        XCTAssertTrue(cancellation.wasRequested)
        XCTAssertTrue(progress.values.contains { $0 > 0 && $0 < 1 })
        XCTAssertFalse(progress.values.contains(1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: source), sourceBefore)
        let metrics = try await finished(service, childLaunched: true)
        XCTAssertEqual(metrics.outcome, "cancelled")
        XCTAssertFalse(Task.isCancelled, "Cancelling one export must not cancel its caller")
        try assertNoStaging(app.root)
    }

    func testBusyAdmissionRemainsHeldWhileCancelledChildIgnoresTerminate() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try stubSource(in: root)
        let jobMarker = root.appendingPathComponent("job-directory.txt")
        let ready = InferenceTestLatch()
        let service = try pythonService("""
        import os, sys, signal, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        sys.stdin.buffer.readline()
        with open(sys.argv[1], 'x') as marker:
            marker.write(os.getcwd())
        print('{"version":1,"kind":"progress","fraction":0.0}', flush=True)
        time.sleep(30)
        """, arguments: [jobMarker.path])
        let first = InferenceTestOperation {
            try await service.export(sourceURL: source, destinationURL: root.appendingPathComponent("first.gif")) { _ in ready.open() }
        }
        defer { first.cancel() }
        do { try await ready.wait(timeout: 5, phase: "SIGTERM-resistant child ready") }
        catch {
            let markerExists = FileManager.default.fileExists(atPath: jobMarker.path)
            await GIFProcessTestDiagnostics.record(service: service, phase: "SIGTERM-resistant child ready",
                detail: "\(error); childWroteReadyMarker=\(markerExists)")
            throw error
        }
        let running = await service.snapshot()
        XCTAssertTrue(running.active)
        XCTAssertNil(running.lastJob)
        let job = URL(fileURLWithPath: try String(contentsOf: jobMarker, encoding: .utf8), isDirectory: true)
        XCTAssertTrue(job.lastPathComponent.hasPrefix(".picshot-gif-job-"))
        let attributes = try FileManager.default.attributesOfItem(atPath: job.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: job.path), ["source.mp4"])
        let copiedAttributes = try FileManager.default.attributesOfItem(atPath: job.appendingPathComponent("source.mp4").path)
        XCTAssertEqual((copiedAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        first.cancel()
        do {
            _ = try await service.export(sourceURL: source, destinationURL: root.appendingPathComponent("second.gif"))
            XCTFail("A competing export must fail during child cleanup")
        } catch {
            guard case GIFExportProcessError.busy = error else { return XCTFail("Expected busy during child cleanup, got \(error)") }
        }
        let cancelling = await service.snapshot()
        XCTAssertTrue(cancelling.active, "Admission must remain held until the process has actually exited")
        XCTAssertNil(cancelling.lastJob, "Rejected concurrent work cannot overwrite the active job's metrics")
        do {
            _ = try await first.value(timeout: 8, phase: "SIGTERM-resistant child killed and reaped")
            XCTFail("Cancelled sleeping child must fail")
        } catch { XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)") }
        let metrics = try await finished(service, childLaunched: true)
        XCTAssertEqual(metrics.terminationStatus, SIGKILL, "An uncooperative helper must be killed, not merely signalled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.path), "Independently verify removal of the actual child working directory")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("first.gif").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("second.gif").path))
        try assertNoStaging(root)
    }

    func testWallDeadlineTerminatesChildAndAllowsAnotherExport() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try stubSource(in: root)
        let service = GIFExportProcessService(configuration: .init(
            executable: { URL(fileURLWithPath: "/bin/sleep") }, arguments: ["30"], wallSeconds: 0.2))
        for index in 0..<2 {
            let start = ProcessInfo.processInfo.systemUptime
            let error = try await exportFailure(service, source: source,
                destination: root.appendingPathComponent("timeout-\(index).gif"))
            guard case GIFExportProcessError.timedOut = error else { return XCTFail("Expected timeout, got \(error)") }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 8)
            let metrics = try await finished(service, childLaunched: true)
            XCTAssertEqual(metrics.outcome, "timedOut")
            XCTAssertGreaterThan(metrics.childResidentSampleCount, 0)
            XCTAssertGreaterThan(try XCTUnwrap(metrics.childSampledPeakResidentBytes), 0)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [source.lastPathComponent])
    }

    func testResidentLimitTerminatesChildRatherThanWaitingForWallDeadline() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try stubSource(in: root)
        let service = GIFExportProcessService(configuration: .init(executable: { URL(fileURLWithPath: "/bin/sleep") },
            arguments: ["30"], wallSeconds: 10, residentLimitBytes: 1))
        let error = try await exportFailure(service, source: source, destination: root.appendingPathComponent("memory.gif"))
        guard case GIFExportProcessError.memoryLimit = error else { return XCTFail("Expected memory limit, got \(error)") }
        let metrics = try await finished(service, childLaunched: true)
        XCTAssertEqual(metrics.outcome, "memoryLimit")
        XCTAssertGreaterThan(metrics.childResidentSampleCount, 0)
        XCTAssertGreaterThan(try XCTUnwrap(metrics.childSampledPeakResidentBytes), 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [source.lastPathComponent])
    }

    func testMalformedOverlongIncompleteAndFloodedStdoutFailClosed() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try stubSource(in: root)
        let cases: [(String, String)] = [
            ("malformed", "os.write(1, b'not JSON\\n')"),
            ("overlong", "os.write(1, b'x' * 4097)"),
            ("partial-eof", "os.write(1, b'{\"version\":1,\"kind\":\"progress\",\"fraction\":0')"),
            ("unframed-eof", "os.write(1, b'{\"version\":1,\"kind\":\"progress\",\"fraction\":0}')"),
            ("unknown-field", "os.write(1, b'{\"version\":1,\"kind\":\"progress\",\"fraction\":0,\"unexpected\":1}\\n')"),
            ("wrong-version", "os.write(1, b'{\"version\":2,\"kind\":\"progress\",\"fraction\":0}\\n')"),
            ("progress-regression", "os.write(1, b'{\"version\":1,\"kind\":\"progress\",\"fraction\":0.75}\\n{\"version\":1,\"kind\":\"progress\",\"fraction\":0.25}\\n')"),
            // Each individual memory event is valid and short; aggregate output
            // exceeds 1 MiB. A flood must not create an unbounded event queue.
            ("stdout-flood", "line = b'{\"version\":1,\"kind\":\"memory\",\"residentBytes\":1}\\n'\nfor _ in range(30000): os.write(1, line)")
        ]
        for (name, payload) in cases {
            let service = try pythonService("import os, sys\nsys.stdin.buffer.readline()\n" + payload)
            let output = root.appendingPathComponent(name + ".gif")
            let error = try await exportFailure(service, source: source, destination: output)
            guard case GIFExportProcessError.invalidProtocol = error else {
                XCTFail("\(name) should fail protocol validation, got \(error)")
                continue
            }
            _ = try await finished(service, childLaunched: true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), name)
            try assertNoStaging(root)
        }
    }

    func testFailedChildExitAndOversizedStderrDoNotLeaveOutputOrLoseExitStatus() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try stubSource(in: root)
        let service = try pythonService("""
        import os, sys
        sys.stdin.buffer.readline()
        data = b'fixture stderr ' * 10000
        while data:
            data = data[os.write(2, data):]
        sys.exit(23)
        """)
        let error = try await exportFailure(service, source: source, destination: root.appendingPathComponent("failed.gif"))
        guard case GIFExportProcessError.failed = error else { return XCTFail("Expected failed child, got \(error)") }
        let metrics = try await finished(service, childLaunched: true)
        XCTAssertEqual(metrics.terminationStatus, 23)
        XCTAssertTrue(metrics.stderrTruncated)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [source.lastPathComponent])
    }

    func testEventByteLimitIncludesNewlineFraming() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try stubSource(in: root)
        for totalLineBytes in [4_096, 4_097] {
            let service = try pythonService("""
            import sys, time, json
            sys.stdin.buffer.readline()
            # Original one-pixel GIF, matching the streaming-writer test fixture.
            gif = b'GIF89a' + bytes([1,0,1,0,128,0,0,255,0,0,0,255,0,33,249,4,0,100,0,0,0,44,0,0,0,0,1,0,1,0,0,2,2,68,1,0,59])
            with open('result.gif', 'xb') as output:
                output.write(gif)
            time.sleep(0.15)
            first = b'{"version":1,"kind":"progress","fraction":0}'
            sys.stdout.buffer.write(b' ' * (\(totalLineBytes) - len(first) - 1) + first + b'\\n')
            sys.stdout.buffer.flush()
            print('{"version":1,"kind":"memory","residentBytes":1}', flush=True)
            print('{"version":1,"kind":"progress","fraction":0.5}', flush=True)
            print('{"version":1,"kind":"progress","fraction":1}', flush=True)
            print(json.dumps({'version':1,'kind':'result','outputBytes':len(gif),'frameCount':1,'duration':1}), flush=True)
            """)
            let output = root.appendingPathComponent("line-\(totalLineBytes).gif")
            if totalLineBytes == 4_096 {
                let operation = InferenceTestOperation { try await service.export(sourceURL: source, destinationURL: output) }
                defer { operation.cancel() }
                let result = try await operation.value(timeout: 10, phase: "maximum legal GIF event line")
                XCTAssertEqual(result, output)
                XCTAssertEqual(try Data(contentsOf: output).count, 43)
            } else {
                let error = try await exportFailure(service, source: source, destination: output)
                guard case GIFExportProcessError.invalidProtocol = error else {
                    return XCTFail("A 4096-byte body plus newline exceeds the event limit, got \(error)")
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            }
            _ = try await finished(service, childLaunched: true)
            try assertNoStaging(root)
        }
    }

    func testZeroExitWithoutResultCannotBeMistakenForSuccessfulExport() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try stubSource(in: root)
        let service = try pythonService("import sys\nsys.stdin.buffer.readline()")
        let error = try await exportFailure(service, source: source, destination: root.appendingPathComponent("missing.gif"))
        guard case GIFExportProcessError.invalidProtocol = error else { return XCTFail("Expected missing-result protocol failure, got \(error)") }
        let metrics = try await finished(service, childLaunched: true)
        XCTAssertEqual(metrics.terminationStatus, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [source.lastPathComponent])
    }

    func testChildThatExitsBeforeReadingRequestCannotDeliverSIGPIPEToCaller() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try stubSource(in: root)
        let service = GIFExportProcessService(configuration: .init(
            executable: { URL(fileURLWithPath: "/usr/bin/false") }, arguments: [], wallSeconds: 2))
        let error = try await exportFailure(service, source: source, destination: root.appendingPathComponent("early-exit.gif"))
        guard case GIFExportProcessError.failed = error else { return XCTFail("Expected failed child, got \(error)") }
        let metrics = try await finished(service, childLaunched: true)
        XCTAssertEqual(metrics.terminationStatus, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [source.lastPathComponent])
    }

    func testResultFIFOAndSymlinkCannotBlockValidationOrPublishForeignContents() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try stubSource(in: root)
        for (name, createOutput) in [("fifo", "os.mkfifo('result.gif', 0o600)"),
                                     ("symlink", "os.symlink('source.mp4', 'result.gif')")] {
            let service = try pythonService("""
            import os, sys, time
            sys.stdin.buffer.readline()
            \(createOutput)
            print('{"version":1,"kind":"progress","fraction":0}', flush=True)
            print('{"version":1,"kind":"memory","residentBytes":1}', flush=True)
            print('{"version":1,"kind":"progress","fraction":0.5}', flush=True)
            print('{"version":1,"kind":"progress","fraction":1}', flush=True)
            print('{"version":1,"kind":"result","outputBytes":14,"frameCount":1,"duration":1}', flush=True)
            time.sleep(0.15)
            """)
            let output = root.appendingPathComponent(name + ".gif")
            let error = try await exportFailure(service, source: source, destination: output)
            guard case GIFExportProcessError.invalidProtocol = error else {
                XCTFail("\(name) result should fail validation, got \(error)")
                continue
            }
            _ = try await finished(service, childLaunched: true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertEqual(try Data(contentsOf: source), Data([0x01]))
            try assertNoStaging(root)
        }
    }

    func testDestinationCreatedDuringProgressIsPreservedAndFinalProgressIsWithheld() async throws {
        let app = try GIFProcessTestApplication.make()
        defer { app.cleanup() }
        let profile = GIFResourceSmokeFixture.Profile.quickTest
        let source = try await GIFResourceSmokeFixture.makeMovie(in: app.root, profile: profile)
        let destination = app.root.appendingPathComponent("collision.gif")
        let original = Data("Independent destination contents must survive".utf8)
        let service = app.service()
        let probe = GIFProcessTestCollision()
        let progress = GIFProcessTestProgress()
        let operation = InferenceTestOperation {
            try await service.export(sourceURL: source, destinationURL: destination, options: profile.options) { value in
                progress.record(value)
                if value > 0, value < 1, probe.claim() {
                    do { try original.write(to: destination, options: .withoutOverwriting) }
                    catch { probe.record(error) }
                }
            }
        }
        defer { operation.cancel() }
        do {
            _ = try await operation.value(timeout: 35, phase: "late GIF destination collision")
            XCTFail("A late destination collision must fail instead of replacing the file")
        } catch {
            if (error as NSError).domain != NSCocoaErrorDomain ||
                (error as NSError).code != CocoaError.Code.fileWriteFileExists.rawValue {
                await GIFProcessTestDiagnostics.record(service: service, phase: "late destination collision", detail: String(describing: error))
            }
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
            XCTAssertEqual((error as NSError).code, CocoaError.Code.fileWriteFileExists.rawValue)
        }
        XCTAssertTrue(probe.claimed)
        XCTAssertNil(probe.failure)
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertFalse(progress.values.contains(1), "Final progress means the output was actually published")
        _ = try await finished(service, childLaunched: true)
        try assertNoStaging(app.root)
    }

    func testSymlinkDirectoryFIFOAndOversizedSparseSourceAreRejectedBeforeLaunch() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let regular = try stubSource(in: root)
        let link = root.appendingPathComponent("link.mp4")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        let subdirectory = root.appendingPathComponent("directory.mp4", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: false)
        let fifo = root.appendingPathComponent("pipe.mp4")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let oversized = root.appendingPathComponent("oversized.mp4")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: nil))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: 1_073_741_825) // Sparse: no 1 GiB allocation or media write.
        try handle.close()
        for (index, input) in [link, subdirectory, fifo, oversized].enumerated() {
            let service = GIFExportProcessService(configuration: .init(
                executable: { URL(fileURLWithPath: "/usr/bin/false") }, arguments: [], wallSeconds: 2))
            let destination = root.appendingPathComponent("rejected-\(index).gif")
            let error = try await exportFailure(service, source: input, destination: destination)
            guard case GIFExportProcessError.invalidSource = error else {
                XCTFail("Unsafe source \(input.lastPathComponent) should be rejected, got \(error)")
                continue
            }
            _ = try await finished(service, childLaunched: false)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
        XCTAssertEqual(try Data(contentsOf: regular), Data([0x01]))
        try assertNoStaging(root)
    }

    func testUnavailableVerifiedHelperNeverFallsBackToInProcessExporter() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await GIFResourceSmokeFixture.makeMovie(in: root, profile: .quickTest)
        let service = GIFExportProcessService(configuration: .init(executable: { throw GIFExportProcessError.helperUnavailable }))
        let destination = root.appendingPathComponent("no-fallback.gif")
        let error = try await exportFailure(service, source: source, destination: destination)
        guard case GIFExportProcessError.helperUnavailable = error else { return XCTFail("Expected helper unavailable, got \(error)") }
        _ = try await finished(service, childLaunched: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [source.lastPathComponent])
    }

    func testSignatureVerifierRejectsNonAppSymlinkedAppAndTamperedSignature() throws {
        let app = try GIFProcessTestApplication.make()
        defer { app.cleanup() }
        let executable = try GIFHelperExecutable.verified(bundleURL: app.bundleURL)
        XCTAssertEqual(executable, app.bundleURL.appendingPathComponent("Contents/MacOS/PicShot"))
        XCTAssertThrowsError(try GIFHelperExecutable.verified(bundleURL: app.root)) { error in
            guard case GIFExportProcessError.helperUnavailable = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let alias = app.root.appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: app.bundleURL)
        XCTAssertThrowsError(try GIFHelperExecutable.verified(bundleURL: alias)) { error in
            guard case GIFExportProcessError.signature = error else { return XCTFail("Unexpected error: \(error)") }
        }
        // Whitespace keeps the plist parseable but invalidates its sealed hash.
        let handle = try FileHandle(forWritingTo: app.bundleURL.appendingPathComponent("Contents/Info.plist"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()
        XCTAssertThrowsError(try GIFHelperExecutable.verified(bundleURL: app.bundleURL)) { error in
            guard case GIFExportProcessError.signature = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testConfirmedExitWithUnknownJobFileRetainsLeaseUntilOwnedCleanupCanFinish() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try stubSource(in: root)
        let sourceBytes = try Data(contentsOf: source)
        let marker = root.appendingPathComponent("job-directory.txt")
        let target = root.appendingPathComponent("unpublished.gif")
        let service = try pythonService("""
        import os,sys
        sys.stdin.buffer.readline()
        with open(sys.argv[1], 'x') as marker:
            marker.write(os.getcwd())
        with open('unrecognized-user-file', 'x') as unknown:
            unknown.write('preserve this unknown entry')
        sys.exit(1)
        """, arguments: [marker.path])
        _ = try await exportFailure(service, source: source, destination: target)
        let job = URL(fileURLWithPath: try String(contentsOf: marker, encoding: .utf8), isDirectory: true)
        let unknown = job.appendingPathComponent("unrecognized-user-file")
        do {
            let blocked = await service.snapshot()
            XCTAssertTrue(blocked.active)
            XCTAssertEqual(blocked.lastJob?.childExitConfirmed, true)
            XCTAssertEqual(blocked.lastJob?.temporaryDirectoryRemoved, false)
            XCTAssertEqual(try String(contentsOf: unknown, encoding: .utf8), "preserve this unknown entry")
            XCTAssertEqual(try Data(contentsOf: job.appendingPathComponent("source.mp4")), sourceBytes,
                "The complete entry set must be checked before deleting even known artifacts")
            if let lease = NativeExportAdmission.shared.acquire() {
                NativeExportAdmission.shared.release(lease)
                XCTFail("Cleanup failure must retain the shared native-export lease")
            }
            try FileManager.default.removeItem(at: unknown) // Explicit fixture-owned obstacle.
            let recovered = await service.snapshot()
            XCTAssertFalse(recovered.active)
            XCTAssertEqual(recovered.lastJob?.temporaryDirectoryRemoved, true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: job.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        } catch {
            try? FileManager.default.removeItem(at: unknown)
            _ = await service.snapshot()
            throw error
        }
    }

    func testGeneratedDestinationRootCannotBypassUnknownChildFileCleanupRefusal() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try stubSource(in: root)
        let marker = root.appendingPathComponent("job-directory.txt")
        let service = try pythonService("""
        import os,sys
        sys.stdin.buffer.readline()
        with open(sys.argv[1], 'x') as marker:
            marker.write(os.getcwd())
        with open('unknown-child-file', 'x') as unknown:
            unknown.write('must survive refused child cleanup')
        sys.exit(1)
        """, arguments: [marker.path])
        _ = try await exportFailure(service, source: source, destination: nil)
        let job = URL(fileURLWithPath: try String(contentsOf: marker, encoding: .utf8), isDirectory: true)
        let generated = job.deletingLastPathComponent()
        let unknown = job.appendingPathComponent("unknown-child-file")
        do {
            let state = await service.snapshot()
            XCTAssertTrue(state.active)
            XCTAssertEqual(state.lastJob?.childExitConfirmed, true)
            XCTAssertEqual(state.lastJob?.temporaryDirectoryRemoved, false)
            XCTAssertTrue(generated.lastPathComponent.hasPrefix("PicShot-GIF-"))
            XCTAssertEqual(try String(contentsOf: unknown, encoding: .utf8), "must survive refused child cleanup")
            XCTAssertEqual(try Data(contentsOf: job.appendingPathComponent("source.mp4")), try Data(contentsOf: source))
            try FileManager.default.removeItem(at: unknown)
            let recovered = await service.snapshot()
            XCTAssertFalse(recovered.active)
            XCTAssertEqual(recovered.lastJob?.temporaryDirectoryRemoved, true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: generated.path))
        } catch {
            try? FileManager.default.removeItem(at: unknown)
            _ = await service.snapshot()
            throw error
        }
    }

    func testUnknownGeneratedRootContentRetainsGateAfterChildDirectoryIsCleaned() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try stubSource(in: root)
        let marker = root.appendingPathComponent("job-directory.txt")
        let service = try pythonService("""
        import os,sys
        sys.stdin.buffer.readline()
        with open(sys.argv[1], 'x') as marker:
            marker.write(os.getcwd())
        with open('../unknown-root-file', 'x') as unknown:
            unknown.write('must survive refused root cleanup')
        sys.exit(1)
        """, arguments: [marker.path])
        _ = try await exportFailure(service, source: source, destination: nil)
        let job = URL(fileURLWithPath: try String(contentsOf: marker, encoding: .utf8), isDirectory: true)
        let generated = job.deletingLastPathComponent()
        let unknown = generated.appendingPathComponent("unknown-root-file")
        do {
            let state = await service.snapshot()
            XCTAssertTrue(state.active)
            XCTAssertEqual(state.lastJob?.childExitConfirmed, true)
            XCTAssertEqual(state.lastJob?.temporaryDirectoryRemoved, false)
            XCTAssertFalse(FileManager.default.fileExists(atPath: job.path))
            XCTAssertEqual(try String(contentsOf: unknown, encoding: .utf8), "must survive refused root cleanup")
            if let token = NativeExportAdmission.shared.acquire() {
                NativeExportAdmission.shared.release(token)
                XCTFail("Unknown generated-root contents must keep cleanup unconfirmed")
            }
            try FileManager.default.removeItem(at: unknown)
            let recovered = await service.snapshot()
            XCTAssertFalse(recovered.active)
            XCTAssertEqual(recovered.lastJob?.temporaryDirectoryRemoved, true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: generated.path))
        } catch {
            try? FileManager.default.removeItem(at: unknown)
            _ = await service.snapshot()
            throw error
        }
    }

    func testSubstitutedGeneratedRootIsNeverRecursivelyDeleted() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try stubSource(in: root)
        let original = try Data(contentsOf: source)
        let marker = root.appendingPathComponent("generated-root.txt")
        let service = try pythonService("""
        import os,sys
        sys.stdin.buffer.readline()
        root=os.path.dirname(os.getcwd())
        with open(sys.argv[1], 'x') as marker:
            marker.write(root)
        os.rename(root, root+'-moved-by-fixture')
        os.mkdir(root, 0o700)
        with open(os.path.join(root,'replacement-user-file'), 'x') as replacement:
            replacement.write('preserve substituted root')
        sys.exit(1)
        """, arguments: [marker.path])
        _ = try await exportFailure(service, source: source, destination: nil)
        let generated = URL(fileURLWithPath: try String(contentsOf: marker, encoding: .utf8), isDirectory: true)
        let moved = URL(fileURLWithPath: generated.path + "-moved-by-fixture", isDirectory: true)
        let replacement = generated.appendingPathComponent("replacement-user-file")
        func restoreOwnedRoot() throws {
            try FileManager.default.removeItem(at: replacement)
            guard Darwin.rmdir(generated.path) == 0 else { throw GIFProcessTestSupportError.failed("Fixture replacement root was not empty") }
            try FileManager.default.moveItem(at: moved, to: generated)
        }
        do {
            let state = await service.snapshot()
            XCTAssertTrue(state.active)
            XCTAssertEqual(state.lastJob?.childExitConfirmed, true)
            XCTAssertEqual(state.lastJob?.temporaryDirectoryRemoved, false)
            XCTAssertEqual(try String(contentsOf: replacement, encoding: .utf8), "preserve substituted root")
            let originalJob = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: moved, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix(".picshot-gif-job-") })
            XCTAssertEqual(try Data(contentsOf: originalJob.appendingPathComponent("source.mp4")), original)
            XCTAssertEqual(try Data(contentsOf: source), original)
            try restoreOwnedRoot()
            let recovered = await service.snapshot()
            XCTAssertFalse(recovered.active)
            XCTAssertEqual(recovered.lastJob?.temporaryDirectoryRemoved, true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: generated.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: moved.path))
        } catch {
            try? restoreOwnedRoot()
            _ = await service.snapshot()
            throw error
        }
    }

    private func pythonService(_ script: String, arguments: [String] = []) throws -> GIFExportProcessService {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw GIFProcessTestSupportError.failed("Native process-boundary tests require /usr/bin/python3")
        }
        return GIFExportProcessService(configuration: .init(executable: { python }, arguments: ["-u", "-c", script] + arguments, wallSeconds: 5))
    }

    private func exportFailure(_ service: GIFExportProcessService, source: URL, destination: URL?) async throws -> Error {
        let operation = InferenceTestOperation {
            try await service.export(sourceURL: source, destinationURL: destination)
        }
        defer { operation.cancel() }
        do { _ = try await operation.value(timeout: 10, phase: "expected GIF process failure") }
        catch let error as InferenceTestSynchronizationError { throw error }
        catch { return error }
        XCTFail("Expected process export to fail")
        throw GIFProcessTestSupportError.failed("Expected process export to fail")
    }

    @discardableResult
    private func finished(_ service: GIFExportProcessService, childLaunched: Bool,
                          file: StaticString = #filePath, line: UInt = #line) async throws -> GIFExportProcessMetrics {
        let state = await service.snapshot()
        XCTAssertFalse(state.active, "Admission must be released after confirmed exit and cleanup", file: file, line: line)
        let metrics = try XCTUnwrap(state.lastJob, file: file, line: line)
        XCTAssertEqual(metrics.childLaunched, childLaunched, file: file, line: line)
        if childLaunched {
            XCTAssertTrue(metrics.childExitConfirmed, file: file, line: line)
            XCTAssertNotNil(metrics.terminationStatus, file: file, line: line)
        } else {
            XCTAssertNil(metrics.terminationStatus, file: file, line: line)
            XCTAssertNil(metrics.childSampledPeakResidentBytes, "Missing observations cannot be fabricated as zero", file: file, line: line)
            XCTAssertEqual(metrics.childResidentSampleCount, 0, file: file, line: line)
        }
        XCTAssertTrue(metrics.temporaryDirectoryRemoved, file: file, line: line)
        XCTAssertFalse(metrics.outcome.isEmpty, file: file, line: line)
        return metrics
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("PicShot-GIF-Process-Input-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    private func stubSource(in root: URL) throws -> URL {
        let source = root.appendingPathComponent("source.mp4")
        try Data([0x01]).write(to: source, options: .withoutOverwriting)
        return source
    }

    private func assertNoStaging(_ root: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".picshot-") }, "Staging files remained: \(names)", file: file, line: line)
    }
}
