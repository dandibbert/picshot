import Foundation
import Darwin
import PicShotEraseCore

@main
enum PicShotEraseHelper {
    static func main() {
        umask(0o077)
        // RLIMIT_CPU counts aggregate CPU time across threads, not wall time.
        // Scale it to the machine's logical CPUs so a legitimate parallel Intel
        // prediction is not killed before its explicit 300-second wall budget.
        let cpuSeconds = rlim_t(Int(SmartEraseLimits.seconds) * max(1, ProcessInfo.processInfo.activeProcessorCount))
        var cpu = rlimit(rlim_cur: cpuSeconds, rlim_max: cpuSeconds + 5)
        _ = setrlimit(RLIMIT_CPU, &cpu)
        // Core ML compilation writes its intermediate weight file too.
        var file = rlimit(rlim_cur: 536_870_912, rlim_max: 536_870_912)
        _ = setrlimit(RLIMIT_FSIZE, &file)
        let parent = getppid()
        var watchdog: DispatchSourceTimer?
        do {
            let args = try arguments(Array(CommandLine.arguments.dropFirst()))
            let input = URL(fileURLWithPath: args["--input"]!)
            let maskURL = URL(fileURLWithPath: args["--mask"]!)
            let output = URL(fileURLWithPath: args["--output"]!)
            let directory = URL(fileURLWithPath: args["--model-dir"]!)
            let job = output.deletingLastPathComponent()
            guard input.deletingLastPathComponent() == job, maskURL.deletingLastPathComponent() == job,
                  input.lastPathComponent == "input.png", maskURL.lastPathComponent == "mask.bin",
                  output.lastPathComponent == "output.png",
                  job.standardizedFileURL == job.resolvingSymlinksInPath() else { throw SmartEraseError.invalidInput }
            try SmartEraseTemporaryJob.claim(job, parent: parent)
            let started = ProcessInfo.processInfo.systemUptime
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
            timer.setEventHandler {
                if !SmartEraseTemporaryJob.parentIsAlive(parent) || ProcessInfo.processInfo.systemUptime - started > SmartEraseLimits.seconds {
                    // Do not race recursive deletion against Core ML writers.
                    // The live parent cleans up after waitUntilExit; an orphan
                    // leaves its intact marker for the next constrained sweep.
                    _exit(EXIT_FAILURE)
                }
            }
            timer.resume(); watchdog = timer
            let image = try SmartEraseRaster.readImage(input)
            let values = try maskURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  values.fileSize == image.width * image.height else { throw SmartEraseError.invalidInput }
            let mask = try Data(contentsOf: maskURL)
            let result = try SmartEraseEngine.erase(image: image, mask: mask, modelDirectory: directory, jobDirectory: job)
            let data = try SmartEraseRaster.png(result)
            let fd = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: data); try handle.close()
            watchdog?.cancel()
            // The live parent still needs output.png; it removes this job after
            // reading the result. Abnormal exits retain the marker for recovery.
            exit(EXIT_SUCCESS)
        } catch {
            watchdog?.cancel()
            let text = String(error.localizedDescription.prefix(1_000)) + "\n"
            try? FileHandle.standardError.write(contentsOf: Data(text.utf8))
            exit(EXIT_FAILURE)
        }
    }

    static func arguments(_ args: [String]) throws -> [String: String] {
        guard args.count == 8 else { throw SmartEraseError.invalidInput }
        let allowed = Set(["--input", "--mask", "--output", "--model-dir"])
        var result: [String: String] = [:]
        for index in stride(from: 0, to: args.count, by: 2) {
            guard allowed.contains(args[index]), result[args[index]] == nil, args[index + 1].hasPrefix("/"),
                  !args[index + 1].contains("\0") else { throw SmartEraseError.invalidInput }
            result[args[index]] = args[index + 1]
        }
        return result
    }
}
