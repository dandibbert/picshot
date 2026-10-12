import Darwin
import Foundation
import PicShotTextScriptCore
import PicShotTextScriptProcess

private struct GateCheck: Codable {
    let name: String
    let subject: String
    let passed: Bool
    var diagnostic: String? = nil
    var metrics: TextScriptProcessMetrics? = nil
    var heartbeatCount: Int? = nil
    var maximumHeartbeatGapSeconds: Double? = nil
    var elapsedSeconds: Double? = nil
    var observedExitStatus: Int? = nil
    var probe: TextScriptProbeResult? = nil
    var probeBaseline: ProbeBaselineReceipt? = nil
}

private struct ProbeBaselineReceipt: Codable {
    let parentReadOpenSucceeded: Bool
    let parentWriteOpenSucceeded: Bool
    let parentLoopbackConnectAndAcceptSucceeded: Bool
    let bothSentinelsUnchanged: Bool
    let noHelperConnectionAccepted: Bool
}

private struct GateReport: Encodable {
    let schemaVersion = 1
    let sourceSHA: String
    let generatedInputsOnly = true
    let wireProtocol = "production EOF-delimited request / one newline-terminated response"
    let ordinaryAcceptanceSeconds = 3
    let resourceScope = "sampled RSS is a watchdog, not a hard allocation cap"
    var checks: [GateCheck] = []
    var passed: Bool { !checks.isEmpty && checks.allSatisfy(\.passed) }
    enum CodingKeys: String, CodingKey {
        case schemaVersion, sourceSHA, generatedInputsOnly, wireProtocol, ordinaryAcceptanceSeconds, resourceScope, checks, passed
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(sourceSHA, forKey: .sourceSHA)
        try c.encode(generatedInputsOnly, forKey: .generatedInputsOnly); try c.encode(wireProtocol, forKey: .wireProtocol)
        try c.encode(ordinaryAcceptanceSeconds, forKey: .ordinaryAcceptanceSeconds); try c.encode(resourceScope, forKey: .resourceScope)
        try c.encode(checks, forKey: .checks); try c.encode(passed, forKey: .passed)
    }
}

/// Timer callbacks execute on the actual main RunLoop while the client performs
/// evaluation/transport/supervision off the main thread. No queue-only surrogate.
private final class MainHeartbeat: @unchecked Sendable {
    let lock = NSLock()
    var times: [Double] = []
    var ranOffMain = false
    func beat() {
        lock.lock(); defer { lock.unlock() }
        if !Thread.isMainThread { ranOffMain = true }
        if times.count < 30_000 { times.append(ProcessInfo.processInfo.systemUptime) }
    }
    func sample(since start: Double, until end: Double) -> (Int, Double, Bool) {
        lock.lock(); defer { lock.unlock() }
        let observed = times.filter { $0 >= start && $0 <= end }
        let interval = [start] + observed + [end]
        let maximumGap = zip(interval.dropFirst(), interval).map { $0.0 - $0.1 }.max() ?? (end - start)
        return (observed.count, maximumGap, !ranOffMain)
    }
}

private final class NativeSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    func set() { lock.lock(); signaled = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return signaled }
}

@main
enum TextScriptGateMain {
    static func main() {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--parent-loss-launcher" {
            parentLossLauncher(app: URL(fileURLWithPath: CommandLine.arguments[2])); return
        }
        guard let app = argument("--app"), let output = argument("--output"), let source = argument("--source"),
              (40...64).contains(source.count), source.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            fixedStderr("gate.invalidArguments\n"); exit(64)
        }
        let heartbeat = MainHeartbeat()
        let timer = Timer(timeInterval: 0.01, repeats: true) { _ in heartbeat.beat() }
        RunLoop.main.add(timer, forMode: .common)
        Task.detached {
            let report = await run(app: URL(fileURLWithPath: app), source: source, heartbeat: heartbeat)
            var status: Int32 = report.passed ? 0 : 1
            do {
                let root = URL(fileURLWithPath: output, isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let bytes = try encoder.encode(report)
                guard bytes.count <= 512 * 1_024 else { throw GateError.report }
                try bytes.write(to: root.appendingPathComponent("text-script-gate-report.json"), options: .atomic)
            } catch { fixedStderr("gate.reportWriteFailed\n"); status = 74 }
            let finalStatus = status
            DispatchQueue.main.async { timer.invalidate(); exit(finalStatus) }
        }
        RunLoop.main.run()
    }

    private static func run(app: URL, source: String, heartbeat: MainHeartbeat) async -> GateReport {
        var report = GateReport(sourceSHA: source)
        let signedSource = try? String(contentsOf: app.appendingPathComponent("Contents/Resources/text-script-gate-source.txt"), encoding: .utf8)
        report.checks.append(.init(name: "signed-source-identity", subject: "signed-gate-bundle", passed: signedSource == source + "\n"))
        guard signedSource == source + "\n" else { return report }
        let client = TextScriptProcessService(bundleURL: app)

        func runCase(_ name: String, source: String, input: String = "generated-input", expected: String? = nil,
                     diagnostic: TextScriptDiagnostic? = nil) async {
            let result = await client.execute(.transform(source: source, text: input))
            let contentCorrect = diagnostic.map { result.response?.diagnostic == $0 && result.metrics.outcome == .helperRejected }
                ?? (result.metrics.outcome == .succeeded && result.response?.output == expected)
            report.checks.append(.init(name: name, subject: "actual-helper", passed: contentCorrect && clean(result),
                                      diagnostic: result.response?.diagnostic?.rawValue, metrics: result.metrics))
        }

        await runCase("unicode-normalization", source: "return text.normalize('NFC').replace(/\\s+/gu, ' ').trim();",
                      input: "  e\u{0301} 😀\n中文  ", expected: "é 😀 中文")
        // If the signed independently sandboxed helper cannot launch, stop the
        // runtime approach now; do not run substitutes and do not relax policy.
        guard report.checks.last?.passed == true else { return report }
        await runCase("regex-body-deduplication", source: "const ids = text.match(/\\b[A-Z]+-\\d+\\b/g) || []; return [...new Set(ids)].join('\\n');",
                      input: "问题 ABC-12 ABC-12 XYZ-9 😀", expected: "ABC-12\nXYZ-9")
        let injectionText = "'); throw new Error('generated-injection'); // 😀"
        await runCase("input-is-argument-not-source", source: "return text;", input: injectionText, expected: injectionText)
        await runCase("function-body-breakout-is-syntax", source: "return text; } throw new Error('generated'); function other() {", diagnostic: .syntaxError)
        await runCase("syntax-fixed-diagnostic", source: "return );", diagnostic: .syntaxError)
        await runCase("throw-fixed-diagnostic", source: "throw 'generated-private-exception-payload';", diagnostic: .scriptException)
        await runCase("throw-does-not-coerce-object", source: "throw { toString() { while (true) {} } };", diagnostic: .scriptException)
        await runCase("object-result-rejected", source: "return { toString() { while (true) {} } };", diagnostic: .outputNotString)
        await runCase("boxed-string-rejected", source: "return new String(text);", diagnostic: .outputNotString)
        await runCase("promise-result-rejected", source: "return Promise.resolve(text);", diagnostic: .outputNotString)
        await runCase("empty-result-rejected", source: "return '';", diagnostic: .emptyOutput)
        await runCase("oversized-result-rejected", source: "return 'a'.repeat(32769);", diagnostic: .outputTooLarge)
        await runCase("unpaired-surrogate-rejected", source: "return String.fromCharCode(0xD800);", diagnostic: .invalidUnicode)
        let absentNames = ["require", "process", "fetch", "XMLHttpRequest", "window", "document", "console", "print", "readFile", "ObjC", "NSFileManager", "PicShot", "capabilityProbe", "setTimeout"]
        let absenceBody = "return [" + absentNames.map { "typeof " + $0 }.joined(separator: ",") + "].join(',');"
        await runCase("no-host-or-native-probe-apis", source: absenceBody, expected: Array(repeating: "undefined", count: absentNames.count).joined(separator: ","))
        await runCase("maximum-utf16-output", source: "return '😀'.repeat(16384);", expected: String(repeating: "😀", count: 16_384))
        let escapedInput = String(repeating: "\u{0001}", count: 32_768)
        await runCase("partial-nonblocking-request-and-response", source: "return text;", input: escapedInput, expected: escapedInput)
        let exactSource = "return text;/*" + String(repeating: "x", count: 16_384 - 16) + "*/"
        await runCase("exact-source-byte-bound", source: exactSource, expected: "generated-input")

        for (name, request) in [
            ("source-bound-before-launch", TextScriptRequest.transform(source: exactSource + " ", text: "generated-input")),
            ("input-bound-before-launch", .transform(source: "return text;", text: String(repeating: "x", count: 32_769))),
            ("empty-input-before-launch", .transform(source: "return text;", text: ""))
        ] {
            let result = await client.execute(request)
            report.checks.append(.init(name: name, subject: "parent-validation", passed: result.metrics.outcome == .invalidRequest && !result.metrics.childLaunched && result.metrics.admissionReleased, metrics: result.metrics))
        }

        do {
            let requestID = UUID()
            let directory = URL(fileURLWithPath: TextScriptProbeRequest.sentinelDirectory(for: requestID), isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let sentinel = directory.appendingPathComponent(TextScriptProbeRequest.readSentinelName)
            let writeSentinel = directory.appendingPathComponent(TextScriptProbeRequest.writeSentinelName)
            let generatedBytes = Data("project-generated-owned-sentinel\n".utf8)
            try generatedBytes.write(to: sentinel, options: .withoutOverwriting)
            try generatedBytes.write(to: writeSentinel, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sentinel.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: writeSentinel.path)
            let readFD = Darwin.open(sentinel.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            let writeFD = Darwin.open(writeSentinel.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
            let readOpened = readFD >= 0, writeOpened = writeFD >= 0
            if readFD >= 0 { Darwin.close(readFD) }; if writeFD >= 0 { Darwin.close(writeFD) }
            guard readOpened && writeOpened else { throw GateError.fixture }
            let listener = try OwnedLoopbackListener()
            defer { listener.close() }
            let connected = listener.verifyPositiveBaseline()
            guard connected else { throw GateError.fixture }
            let result = await client.execute(.capabilityProbe(requestID: requestID, loopbackPort: listener.port))
            let unchanged = (try? Data(contentsOf: sentinel)) == generatedBytes && (try? Data(contentsOf: writeSentinel)) == generatedBytes
            let noConnection = !listener.acceptedConnection()
            let baseline = ProbeBaselineReceipt(parentReadOpenSucceeded: readOpened, parentWriteOpenSucceeded: writeOpened,
                parentLoopbackConnectAndAcceptSucceeded: connected, bothSentinelsUnchanged: unchanged, noHelperConnectionAccepted: noConnection)
            report.checks.append(.init(name: "native-sandbox-read-write-open-and-network-denials", subject: "actual-helper", passed: result.response?.probe?.allDenied == true && unchanged && noConnection && clean(result), metrics: result.metrics, probe: result.response?.probe, probeBaseline: baseline))
        } catch { report.checks.append(.init(name: "native-sandbox-denials", subject: "actual-helper", passed: false, diagnostic: "owned-fixture-setup-failed")) }

        let preCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await client.execute(.transform(source: "return text;", text: "generated-input"))
        }
        let preCancelResult = await preCancelled.value
        report.checks.append(.init(name: "cancel-before-launch", subject: "actual-helper", passed: preCancelResult.metrics.outcome == .cancelled && !preCancelResult.metrics.childLaunched && preCancelResult.metrics.admissionReleased, metrics: preCancelResult.metrics))

        let running = NativeSignal()
        var cancellationOptions = TextScriptNativeGateOptions(); cancellationOptions.onRequestSent = { running.set() }
        let cancellable = TextScriptProcessService(bundleURL: app, gate: cancellationOptions)
        let cancellationStart = ProcessInfo.processInfo.systemUptime
        let cancellationTask = Task { await cancellable.execute(.transform(source: "while (true) {}", text: "generated-input")) }
        while !running.value, ProcessInfo.processInfo.systemUptime - cancellationStart < 2.5 { try? await Task.sleep(nanoseconds: 5_000_000) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let busy = await client.execute(.transform(source: "return text;", text: "generated-input"))
        cancellationTask.cancel()
        let cancelled = await cancellationTask.value
        report.checks.append(.init(name: "single-global-admission", subject: "actual-helper", passed: running.value && busy.metrics.outcome == .busy && !busy.metrics.childLaunched, metrics: busy.metrics))
        report.checks.append(.init(name: "cancel-during-evaluation", subject: "actual-helper", passed: running.value && cancelled.metrics.outcome == .cancelled && clean(cancelled), metrics: cancelled.metrics))

        let loopStart = ProcessInfo.processInfo.systemUptime
        let loop = await client.execute(.transform(source: "while (true) {}", text: "generated-input"))
        let loopEnd = ProcessInfo.processInfo.systemUptime
        let beats = heartbeat.sample(since: loopStart, until: loopEnd)
        let cpuSignal = loop.metrics.terminationReason == "uncaughtSignal" &&
            [SIGXCPU, SIGKILL].contains(loop.metrics.terminationStatus ?? 0)
        let loopStopped = (loop.metrics.outcome == .timedOut && loop.metrics.terminateSent) ||
            (loop.metrics.outcome == .abnormalExit && cpuSignal)
        report.checks.append(.init(name: "infinite-loop-bounded-exit", subject: "actual-helper", passed: loopStopped && loop.response == nil && clean(loop) && loop.metrics.elapsedSeconds < 4.5, metrics: loop.metrics))
        report.checks.append(.init(name: "actual-main-runloop-heartbeat", subject: "actual-helper", passed: beats.0 >= 20 && beats.1 < 0.25 && beats.2, heartbeatCount: beats.0, maximumHeartbeatGapSeconds: beats.1))

        let allocation = await client.execute(.transform(source: "const keep=[]; while(true) { const a=new Uint8Array(8*1024*1024); for(let i=0;i<a.length;i+=4096) a[i]=1; keep.push(a); }", text: "generated-input"))
        report.checks.append(.init(name: "allocation-rss-watchdog", subject: "actual-helper", passed: allocation.metrics.outcome == .memoryLimit && allocation.metrics.sampledPeakResidentBytes.map { $0 > TextScriptLimits.residentBytes } == true && clean(allocation), metrics: allocation.metrics))

        var crashOptions = TextScriptNativeGateOptions(); crashOptions.killAfterRequest = true
        let crash = await TextScriptProcessService(bundleURL: app, gate: crashOptions).execute(.transform(source: "while (true) {}", text: "generated-input"))
        report.checks.append(.init(name: "abrupt-owned-helper-exit", subject: "actual-helper", passed: crash.metrics.outcome == .abnormalExit && crash.metrics.terminationReason == "uncaughtSignal" && crash.metrics.terminationStatus == SIGKILL && crash.response == nil && clean(crash), metrics: crash.metrics))
        var failedMonitorOptions = TextScriptNativeGateOptions(); failedMonitorOptions.failResidentObservation = true
        let failedMonitor = await TextScriptProcessService(bundleURL: app, gate: failedMonitorOptions).execute(.transform(source: "return text;", text: "generated-input"))
        report.checks.append(.init(name: "rss-observation-fails-closed", subject: "actual-helper-with-native-observation-injection", passed: failedMonitor.metrics.outcome == .monitorFailed && failedMonitor.metrics.residentObservationFailures > 0 && failedMonitor.metrics.sampledPeakResidentBytes == nil && failedMonitor.response == nil && clean(failedMonitor), metrics: failedMonitor.metrics))

        for mode in ["malformed", "missing-newline", "multiple-response", "oversized", "wrong-identity", "duplicate-key", "late-response", "ignore-terminate", "valid-before-hang", "stderr-flood"] {
            var options = TextScriptNativeGateOptions(); options.transportMode = mode
            let result = await TextScriptProcessService(bundleURL: app, gate: options).execute(.transform(source: "return text;", text: "generated-input"))
            let expected: TextScriptProcessOutcome = ["late-response", "ignore-terminate", "valid-before-hang"].contains(mode) ? .timedOut : mode == "stderr-flood" ? .succeeded : .invalidProtocol
            var passed = result.metrics.outcome == expected && clean(result)
            if mode == "ignore-terminate" { passed = passed && result.metrics.killSent && result.metrics.cleanupSeconds.map { $0 >= 0.25 && $0 < 1.1 } == true }
            if mode == "stderr-flood" { passed = passed && result.metrics.stderrBytes == 512 * 1_024 }
            else { passed = passed && result.response == nil && result.metrics.acceptedSeconds == nil }
            report.checks.append(.init(name: "transport-" + mode, subject: "signed-sandboxed-transport-fixture", passed: passed, metrics: result.metrics))
        }

        var withheldOptions = TextScriptNativeGateOptions(); withheldOptions.hideExitObservation = true
        let hiddenExit = await TextScriptProcessService(bundleURL: app, gate: withheldOptions).execute(.transform(source: "return text;", text: "generated-input"))
        let stillBlocked = TextScriptProcessService.snapshot()
        let refused = await client.execute(.transform(source: "return text;", text: "generated-input"))
        report.checks.append(.init(name: "unknown-exit-retains-admission", subject: "actual-helper-with-native-observation-injection", passed: hiddenExit.metrics.outcome == .exitUnconfirmed && !hiddenExit.metrics.childExitConfirmed && !hiddenExit.metrics.admissionReleased && hiddenExit.response == nil && stillBlocked.occupied && refused.metrics.outcome == .busy, metrics: hiddenExit.metrics))
        report.checks.append(.init(name: "retained-admission-discards-response", subject: "actual-helper-with-native-observation-injection", passed: hiddenExit.metrics.discardedResponseBytes > 0 && hiddenExit.metrics.retainedResponseBytesAfterFinish == 0 && stillBlocked.metrics?.retainedResponseBytesAfterFinish == 0 && stillBlocked.occupied))
        TextScriptProcessService.restoreNativeGateObservation()
        report.checks.append(.init(name: "retained-admission-recovers-only-after-observation", subject: "actual-helper", passed: !TextScriptProcessService.snapshot().occupied))
        await runCase("subsequent-run-after-cleanup", source: "return text;", expected: "generated-input")

        report.checks.append(parentLossAlarm(app: app))
        report.checks.append(.init(name: "final-admission-empty", subject: "parent-lifecycle", passed: !TextScriptProcessService.snapshot().occupied))
        return report
    }

    private static func clean(_ result: TextScriptProcessResult) -> Bool {
        let m = result.metrics
        return m.childLaunched && m.childExitConfirmed && m.pipesDrained && m.admissionReleased &&
            m.pipeDescriptorsCloseOnExec && m.parentEndpointsNonblocking && m.inputSuppressesSIGPIPE &&
            m.signature?.appAndHelperStrictlyValidated == true &&
            m.elapsedSeconds < 4.5 && (m.acceptedSeconds == nil || m.acceptedSeconds! < 3)
    }

    private static func argument(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }
    private static func fixedStderr(_ text: String) { FileHandle.standardError.write(Data(text.utf8)) }
    private enum GateError: Error { case report, fixture }

    /// The direct child launches the real verified helper with stdin inherited
    /// from this gate, reports only its PID, then exits. The gate holds stdin open
    /// without a request. This isolates the helper's 5s parent-loss alarm from
    /// the ordinary parent's 3s deadline and the evaluation CPU limit.
    private static func parentLossLauncher(app: URL) {
        do {
            let (helper, _) = try TextScriptProcessService.verifiedHelperForNativeGate(bundleURL: app)
            let child = Process(); child.executableURL = helper; child.arguments = []
            child.environment = ["LANG": "en_US.UTF-8"]; child.currentDirectoryURL = URL(fileURLWithPath: "/")
            child.standardInput = FileHandle.standardInput; child.standardOutput = FileHandle.standardOutput; child.standardError = FileHandle.standardError
            try child.run()
            FileHandle.standardOutput.write(Data((String(child.processIdentifier) + "\n").utf8))
            usleep(200_000)
            exit(0)
        } catch { exit(70) }
    }

    private static func parentLossAlarm(app: URL) -> GateCheck {
        let started = ProcessInfo.processInfo.systemUptime
        let input = Pipe(), output = Pipe(), errors = Pipe()
        let launcher = Process()
        launcher.executableURL = app.appendingPathComponent("Contents/MacOS/PicShotTextScriptGate")
        launcher.arguments = ["--parent-loss-launcher", app.path]
        launcher.environment = ["LANG": "en_US.UTF-8"]
        launcher.standardInput = input; launcher.standardOutput = output; launcher.standardError = errors
        var pid: Int32?
        var queue: Int32 = -1
        var exitObserved = false
        defer {
            if let pid, !exitObserved { _ = Darwin.kill(pid, SIGKILL) }
            if launcher.isRunning { launcher.terminate() }
            if queue >= 0 { Darwin.close(queue) }
            for handle in [input.fileHandleForWriting, input.fileHandleForReading, output.fileHandleForReading, output.fileHandleForWriting, errors.fileHandleForReading, errors.fileHandleForWriting] { try? handle.close() }
        }
        do {
            for handle in [input.fileHandleForReading, input.fileHandleForWriting, output.fileHandleForReading,
                           output.fileHandleForWriting, errors.fileHandleForReading, errors.fileHandleForWriting] {
                let fd = handle.fileDescriptor, flags = fcntl(handle.fileDescriptor, F_GETFD)
                guard flags >= 0, fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0 else { throw GateError.fixture }
            }
            try launcher.run()
            try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
            for handle in [output.fileHandleForReading, errors.fileHandleForReading] {
                let fd = handle.fileDescriptor, flags = fcntl(handle.fileDescriptor, F_GETFL)
                guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw GateError.fixture }
            }
            var line = Data()
            while !line.contains(10), ProcessInfo.processInfo.systemUptime - started < 2 {
                var byte: UInt8 = 0
                let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &byte, 1)
                if count == 1 { line.append(byte); if line.count > 16 { throw GateError.fixture } }
                else if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { throw GateError.fixture }
                Thread.sleep(forTimeInterval: 0.005)
            }
            guard let text = String(data: line, encoding: .utf8), let childPID = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), childPID > 1 else { throw GateError.fixture }
            pid = childPID; queue = kqueue()
            guard queue >= 0 else { throw GateError.fixture }
            var registration = kevent(ident: UInt(childPID), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT), fflags: UInt32(NOTE_EXIT) | UInt32(NOTE_EXITSTATUS), data: 0, udata: nil)
            guard kevent(queue, &registration, 1, nil, 0, nil) == 0 else { throw GateError.fixture }
            var reparented = false, stdoutEOF = false, stderrEOF = false
            var observedStatus: Int?
            while ProcessInfo.processInfo.systemUptime - started < 6.5 {
                var event = kevent(), timeout = timespec(tv_sec: 0, tv_nsec: 20_000_000)
                let count = kevent(queue, nil, 0, &event, 1, &timeout)
                guard count >= 0 || errno == EINTR else { throw GateError.fixture }
                if count == 1, event.flags & UInt16(EV_ERROR) != 0 { throw GateError.fixture }
                if count == 1, event.ident == UInt(childPID), event.fflags & UInt32(NOTE_EXIT) != 0 {
                    exitObserved = true; observedStatus = event.data
                }
                if !launcher.isRunning, !exitObserved {
                    var info = proc_bsdinfo()
                    if proc_pidinfo(childPID, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size) {
                        reparented = info.pbi_ppid != UInt32(launcher.processIdentifier)
                    }
                }
                var buffer = [UInt8](repeating: 0, count: 4096)
                if !stdoutEOF {
                    let amount = Darwin.read(output.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                    if amount == 0 { stdoutEOF = true }
                    else if amount > 0 { throw GateError.fixture }
                }
                if !stderrEOF {
                    let amount = Darwin.read(errors.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                    if amount == 0 { stderrEOF = true }
                    // Count-only discard: no helper stderr retained or logged.
                }
                if exitObserved && stdoutEOF && stderrEOF { break }
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let alarmSignal = observedStatus.map { ($0 & 0x7f) == Int(SIGALRM) } == true
            let passed = exitObserved && alarmSignal && reparented && !launcher.isRunning && launcher.terminationStatus == 0 && stdoutEOF && stderrEOF && elapsed >= 4.5 && elapsed < 6.5
            return .init(name: "parent-loss-five-second-alarm", subject: "actual-helper-orphan-observed-by-kqueue", passed: passed, elapsedSeconds: elapsed, observedExitStatus: observedStatus)
        } catch {
            return .init(name: "parent-loss-five-second-alarm", subject: "actual-helper-orphan-observed-by-kqueue", passed: false, diagnostic: "native-owned-observation-failed", elapsedSeconds: ProcessInfo.processInfo.systemUptime - started)
        }
    }
}

private final class OwnedLoopbackListener {
    private var descriptor: Int32
    let port: UInt16
    init() throws {
        enum Failed: Error { case socket }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failed.socket }
        descriptor = fd
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let flags = fcntl(fd, F_GETFL)
        let descriptorFlags = fcntl(fd, F_GETFD)
        guard bound == 0, named == 0, listen(fd, 2) == 0, flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              descriptorFlags >= 0, fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else { Darwin.close(fd); throw Failed.socket }
        port = UInt16(bigEndian: address.sin_port)
    }
    func acceptedConnection() -> Bool {
        let accepted = accept(descriptor, nil, nil)
        if accepted >= 0 { Darwin.close(accepted); return true }
        return errno != EAGAIN && errno != EWOULDBLOCK
    }
    func verifyPositiveBaseline() -> Bool {
        let client = socket(AF_INET, SOCK_STREAM, 0)
        guard client >= 0 else { return false }
        defer { Darwin.close(client) }
        let flags = fcntl(client, F_GETFL), descriptorFlags = fcntl(client, F_GETFD)
        guard flags >= 0, descriptorFlags >= 0, fcntl(client, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(client, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else { return false }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian; address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { return false }
            var event = pollfd(fd: client, events: Int16(POLLOUT), revents: 0)
            guard poll(&event, 1, 500) == 1 else { return false }
            var code: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(client, SOL_SOCKET, SO_ERROR, &code, &length) == 0, code == 0 else { return false }
        }
        let accepted = accept(descriptor, nil, nil)
        guard accepted >= 0 else { return false }
        Darwin.close(accepted)
        return !acceptedConnection()
    }
    func close() { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
    deinit { close() }
}
