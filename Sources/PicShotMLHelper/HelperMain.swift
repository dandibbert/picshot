import Foundation
import ImageIO
import Darwin
import PicShotFormulaCore

@main
enum PicShotMLHelper {
    static func main() {
        // CPU/file limits supplement the parent's wall-clock timeout, cancellation
        // and RSS watchdog. No shells, plug-ins, Python or remote model code.
        var cpu = rlimit(rlim_cur: 120, rlim_max: 125)
        _ = setrlimit(RLIMIT_CPU, &cpu)
        var file = rlimit(rlim_cur: rlim_t(MLJobLimits.outputBytes), rlim_max: rlim_t(MLJobLimits.outputBytes))
        _ = setrlimit(RLIMIT_FSIZE, &file)
        do {
            let args = try arguments(Array(CommandLine.arguments.dropFirst()))
            let input = URL(fileURLWithPath: args["--input"]!)
            let output = URL(fileURLWithPath: args["--output"]!)
            let directory = URL(fileURLWithPath: args["--model-dir"]!)
            let values = try input.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= MLJobLimits.inputBytes else { throw FormulaError.invalidInput }
            guard let source = CGImageSourceCreateWithURL(input as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= MLJobLimits.inputDimension, height <= MLJobLimits.inputDimension,
                  width * height <= MLJobLimits.inputPixels,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw FormulaError.invalidInput }
            let data: Data
            switch args["--mode"] {
            case "formula": data = try JSONEncoder().encode(FormulaEngine.recognize(image: image, modelDirectory: directory))
            case "table": data = try JSONEncoder().encode(TableEngine.recognize(image: image, modelDirectory: directory))
            default: throw FormulaError.invalidInput
            }
            guard data.count <= MLJobLimits.outputBytes else { throw FormulaError.invalidTensor }
            // O_EXCL refuses symlinks or pre-existing output. Parent owns a 0700
            // job directory and deletes the entire directory after process exit.
            let fd = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.close()
            exit(EXIT_SUCCESS)
        } catch {
            // Only a bounded error, never pixels, model tensors or recognized text.
            let message = String(error.localizedDescription.prefix(1000)) + "\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
            exit(EXIT_FAILURE)
        }
    }

    static func arguments(_ args: [String]) throws -> [String: String] {
        guard args.count == 8 else { throw FormulaError.invalidInput }
        let allowed = Set(["--mode", "--input", "--output", "--model-dir"])
        var result: [String: String] = [:]
        for i in stride(from: 0, to: args.count, by: 2) {
            guard allowed.contains(args[i]), result[args[i]] == nil, !args[i + 1].isEmpty else { throw FormulaError.invalidInput }
            result[args[i]] = args[i + 1]
        }
        for key in ["--input", "--output", "--model-dir"] {
            guard result[key]?.hasPrefix("/") == true else { throw FormulaError.invalidInput }
        }
        return result
    }
}
