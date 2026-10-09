import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import Darwin

// Independent, post-exit decoder. This helper has no PicShot renderer, editor,
// document codec or persistence dependencies. It never creates a golden.
struct Invalid: Error { let message: String }
func need(_ condition: Bool, _ message: String) throws {
    if !condition { throw Invalid(message: message) }
}
func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func read(_ path: String, maximum: Int) throws -> Data {
    let url = URL(fileURLWithPath: path)
    try need(path.hasPrefix("/") && url.standardizedFileURL.path == path && url.resolvingSymlinksInPath().path == path,
             "Noncanonical or linked evidence path")
    var before = stat()
    try need(lstat(path, &before) == 0 && before.st_mode & S_IFMT == S_IFREG && before.st_nlink == 1
             && before.st_size > 0 && before.st_size <= maximum, "Unsafe evidence file")
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
    try need(descriptor >= 0, "Cannot open evidence")
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var opened = stat()
    try need(fstat(descriptor, &opened) == 0 && opened.st_dev == before.st_dev && opened.st_ino == before.st_ino
             && opened.st_size == before.st_size, "Evidence changed at open")
    var data = Data()
    while data.count <= maximum {
        let part = try handle.read(upToCount: min(65_536, maximum + 1 - data.count)) ?? Data()
        if part.isEmpty { break }; data.append(part)
    }
    var after = stat()
    try need(fstat(descriptor, &after) == 0 && data.count == before.st_size && after.st_size == opened.st_size
             && after.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec && after.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec
             && after.st_ctimespec.tv_sec == opened.st_ctimespec.tv_sec && after.st_ctimespec.tv_nsec == opened.st_ctimespec.tv_nsec,
             "Evidence changed while reading")
    return data
}
func object(_ data: Data) throws -> [String: Any] {
    guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Invalid(message: "Expected JSON object") }
    return result
}
func string(_ value: Any?) throws -> String {
    guard let result = value as? String, !result.isEmpty, result.utf8.count <= 8192 else { throw Invalid(message: "Expected bounded string") }
    return result
}
func integer(_ value: Any?, _ minimum: Int, _ maximum: Int) throws -> Int {
    guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
          value.doubleValue.isFinite, value.doubleValue == Double(value.intValue),
          value.intValue >= minimum && value.intValue <= maximum else { throw Invalid(message: "Expected bounded integer") }
    return value.intValue
}
func decode(_ row: [String: Any]) throws -> [String: Any] {
    let path = try string(row["path"]), goldenPath = try string(row["goldenPath"])
    let width = try integer(row["width"], 1, 3840), height = try integer(row["height"], 1, 2160)
    let count = width * height * 4
    let encoded = try read(path, maximum: 40 * 1024 * 1024)
    let raw = try read(goldenPath, maximum: count)
    let encodedHash = sha(encoded), goldenHash = sha(raw)
    try need(encoded.count == integer(row["encodedBytes"], 1, 40 * 1024 * 1024)
             && encodedHash == string(row["encodedSHA256"]) && raw.count == count
             && goldenHash == string(row["goldenSHA256"]), "Plan byte identity mismatch")
    let options = [kCGImageSourceShouldCache: false, kCGImageSourceShouldCacheImmediately: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(encoded as CFData, options), CGImageSourceGetCount(source) == 1,
          let image = CGImageSourceCreateImageAtIndex(source, 0, options) else { throw Invalid(message: "PNG decode failed") }
    try need(image.width == width && image.height == height && image.bitsPerComponent == 8,
             "Decoded dimensions or precision differ")
    let color = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: color,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
        let destination = context.data else { throw Invalid(message: "Independent comparison allocation failed") }
    context.setBlendMode(.copy); context.setShouldAntialias(false); context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)); context.flush()
    let (exact, pixelsHash) = withExtendedLifetime(context) {
        let matches = raw.withUnsafeBytes { memcmp(destination, $0.baseAddress!, count) == 0 }
        let digest = SHA256.hash(data: Data(bytesNoCopy: destination, count: count, deallocator: .none))
            .map { String(format: "%02x", $0) }.joined()
        return (matches, digest)
    }
    try need(exact && pixelsHash == goldenHash, "Full decoded RGBA differs from independent golden")
    return ["path": path, "encodedBytes": encoded.count, "encodedSHA256": encodedHash,
        "goldenPath": goldenPath, "goldenSHA256": goldenHash, "width": width, "height": height,
        "comparedBytes": count, "rgbaSHA256": pixelsHash, "exact": true,
        "comparison": "memcmp/full-premultiplied-sRGB-RGBA8-including-alpha"]
}
guard CommandLine.arguments.count == 3 else { fputs("Usage: verify-editable-product-pixels PLAN OUTPUT\n", stderr); exit(64) }
let began = ProcessInfo.processInfo.systemUptime
var report: [String: Any] = ["protocol": "editable-product-pixels-v1", "status": "failed",
    "processIdentifier": Int(getpid()), "startUptimeSeconds": began,
    "memoryComparisonExcluded": true, "goldensGenerated": false]
do {
    let planData = try read(CommandLine.arguments[1], maximum: 2 * 1024 * 1024)
    let plan = try object(planData)
    try need(plan["protocol"] as? String == "editable-product-pixels-v1", "Unknown plan")
    let measuredPID = try integer(plan["measuredProcessIdentifier"], 1, Int(Int32.max))
    try need(measuredPID != Int(getpid()) && began >= (plan["ownedExitUptimeSeconds"] as? Double ?? .infinity), "Decode precedes owned exit")
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
    let executableData = try read(executable, maximum: 64 * 1024 * 1024)
    try need(sha(executableData) == string(plan["decoderExecutableSHA256"]), "Decoder executable changed")
    guard let rows = plan["files"] as? [[String: Any]], !rows.isEmpty, rows.count <= 128 else { throw Invalid(message: "Unbounded file plan") }
    var results: [[String: Any]] = []
    for row in rows { results.append(try autoreleasepool { try decode(row) }) }
    report.merge(["status": "verified", "planSHA256": sha(planData), "measuredProcessIdentifier": measuredPID,
        "executablePath": executable, "executableSHA256": sha(executableData), "executableBytes": executableData.count,
        "files": results, "finishUptimeSeconds": ProcessInfo.processInfo.systemUptime]) { _, new in new }
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .withoutOverwriting)
} catch {
    report["error"] = String(describing: error); report["finishUptimeSeconds"] = ProcessInfo.processInfo.systemUptime
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .withoutOverwriting)
    }
    fputs("Independent pixel verification failed: \(error)\n", stderr); exit(1)
}
