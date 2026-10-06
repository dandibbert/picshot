import Foundation
import Darwin
import PicShotFormulaRenderCore

@main
enum FormulaRenderHelperMain {
    static func main() {
        var cpu = rlimit(rlim_cur: 8, rlim_max: 9)
        _ = setrlimit(RLIMIT_CPU, &cpu)
        var outputLimit = rlimit(rlim_cur: rlim_t(FormulaRenderLimits.resultBytes), rlim_max: rlim_t(FormulaRenderLimits.resultBytes))
        _ = setrlimit(RLIMIT_FSIZE, &outputLimit)
        alarm(12) // A final independent wall-clock backstop if the parent disappears.
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count == 4, args[0] == "--input", args[2] == "--output",
                  args[1].hasPrefix("/"), args[3].hasPrefix("/") else { throw FormulaRenderError.invalidInput }
            let input = URL(fileURLWithPath: args[1]), output = URL(fileURLWithPath: args[3])
            let values = try input.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= FormulaRenderLimits.latexBytes * 8 else { throw FormulaRenderError.invalidInput }
            let request = try JSONDecoder().decode(FormulaRenderRequest.self, from: Data(contentsOf: input))
            let result = try FormulaRenderEngine.render(request)
            let data = try JSONEncoder().encode(result)
            guard data.count <= FormulaRenderLimits.resultBytes else { throw FormulaRenderError.invalidOutput }
            let fd = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: data); try handle.close()
            exit(EXIT_SUCCESS)
        } catch {
            // Never log LaTeX, source screenshots, JS exception text or user document contents.
            let message = String(error.localizedDescription.prefix(1000)) + "\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
            exit(EXIT_FAILURE)
        }
    }
}
