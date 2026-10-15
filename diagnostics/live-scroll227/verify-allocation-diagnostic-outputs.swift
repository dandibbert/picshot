import Accelerate
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

// Separate post-exit decoder. The normalization and full BGRA oracle comparison
// are the original227 verification policy; incomplete runs retain partial proof.
func need(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "PicShot.AllocationDiagnostic.Output", code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]) }
}
func sha(_ url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
    var digest = SHA256()
    while let block = try file.read(upToCount: 1_048_576), !block.isEmpty { digest.update(data: block) }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}
func check(_ url: URL, raw: Data) throws -> [String: Any] {
    let count = 1280 * 7136 * 4
    let size = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
    try need(size.isSymbolicLink != true && (size.fileSize ?? 0) > 0 && (size.fileSize ?? Int.max) <= 512 * 1024 * 1024, "Invalid bounded PNG file")
    guard let reader = CGImageSourceCreateWithURL(url as CFURL, nil),
          CGImageSourceGetCount(reader) == 1,
          let image = CGImageSourceCreateImageAtIndex(reader, 0, nil),
          CGImageSourceGetStatus(reader) == .statusComplete,
          image.width == 1280, image.height == 7136,
          let color = CGColorSpace(name: CGColorSpace.sRGB),
          var format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: color,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            renderingIntent: .defaultIntent), let storage = malloc(count) else {
        throw NSError(domain: "PicShot.AllocationDiagnostic.Output", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "PNG decode or bounded RGBA allocation failed"])
    }
    defer { free(storage) }
    memset(storage, 0, count)
    var destination = vImage_Buffer(data: storage, height: 7136, width: 1280, rowBytes: 5120)
    let error = withExtendedLifetime(color) {
        vImageBuffer_InitWithCGImage(&destination, &format, nil, image, vImage_Flags(kvImageNoAllocate))
    }
    try need(error == kvImageNoError && destination.data == storage && destination.width == 1280
        && destination.height == 7136 && destination.rowBytes == 5120, "RGBA normalization failed")
    let bytes = UnsafeRawBufferPointer(start: storage, count: count)
    try raw.withUnsafeBytes { (oracle: UnsafeRawBufferPointer) in
        for i in stride(from: 0, to: count, by: 4) {
            try need(bytes[i] == oracle[i + 2] && bytes[i + 1] == oracle[i + 1]
                && bytes[i + 2] == oracle[i] && bytes[i + 3] == oracle[i + 3], "PNG differs from complete generated BGRA oracle")
        }
    }
    return ["file": url.lastPathComponent, "encodedBytes": size.fileSize!, "sha256": try sha(url),
        "width": 1280, "height": 7136, "comparedBytes": count, "pixelEquality": true, "passed": true]
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fputs("usage: verify-allocation-diagnostic-outputs ROOT REPORT\n", stderr); exit(64) }
let root = URL(fileURLWithPath: arguments[1]).standardizedFileURL
let reportURL = URL(fileURLWithPath: arguments[2]).standardizedFileURL
var report: [String: Any] = ["schemaVersion": 1, "diagnosticOnly": true, "installerAcceptance": false,
    "original227MemoryFailurePreserved": true, "expectedOutputs": 10, "decoderPID": ProcessInfo.processInfo.processIdentifier,
    "method": "Original227 ImageIO/vImage sRGB RGBA normalization and every-byte generated BGRA comparison, after measured app exit"]
var proofs: [[String: Any]] = [], missing: [Int] = [], failed = false
do {
    let input = root.appendingPathComponent("input/fixture.bgra")
    let raw = try Data(contentsOf: input)
    try need(raw.count == 36_536_320, "Generated oracle length changed")
    let certificateURL = root.appendingPathComponent("input/certificate.json")
    let certificateData = try Data(contentsOf: certificateURL)
    let certificate = try JSONSerialization.jsonObject(with: certificateData) as? [String: Any]
    try need(certificate?["status"] as? String == "passed" && certificate?["sourceCommit"] as? String == "e5a859a82b2a7a697e51a0a4d42f34ae4f5602d0"
        && certificate?["inputSHA256"] as? String == sha(input), "Generated input certificate identity differs")
    report["sourceCommit"] = certificate?["sourceCommit"]; report["executableSHA256"] = certificate?["executableSHA256"]
    report["inputSHA256"] = try sha(input); report["certificateSHA256"] = try sha(certificateURL)
    for ordinal in 1...10 {
        let file = root.appendingPathComponent(String(format: "measure/cycle-%02d.png", ordinal))
        guard FileManager.default.fileExists(atPath: file.path) else { missing.append(ordinal); continue }
        var proof: [String: Any]
        do { proof = try autoreleasepool { try check(file, raw: raw) } }
        catch { failed = true; proof = ["file": file.lastPathComponent, "passed": false, "error": error.localizedDescription] }
        proof["ordinal"] = ordinal; proofs.append(proof)
    }
    report["status"] = failed ? "pixel-failure" : (missing.isEmpty ? "all-ten-exact" : (proofs.isEmpty ? "no-produced-outputs" : "partial-outputs-verified"))
} catch { failed = true; report["status"] = "unavailable"; report["error"] = error.localizedDescription }
report["outputs"] = proofs; report["missingOrdinals"] = missing; report["verifiedOutputCount"] = proofs.filter { $0["passed"] as? Bool == true }.count
do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic) }
catch { fputs("Could not preserve output verification report\n", stderr); exit(1) }
exit(failed ? 1 : 0)
