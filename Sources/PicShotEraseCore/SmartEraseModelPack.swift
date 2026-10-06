import Foundation
import PicShotFormulaCore

/// Candidate bytes are fully pinned and may be used by native validation. User
/// download/inference stays gated until the actual Core ML fixture passes.
public enum SmartEraseModelPack {
    public static let source = URL(string: "https://github.com/john-rocky/CoreML-Models#lama")!
    public static let license = URL(string: "https://github.com/advimman/lama/blob/main/LICENSE")!
    public static let distribution = URL(string: "https://drive.google.com/drive/folders/1s_uICJQykFFxgVubpBNeLLDL0JsxgdCd")!
    public static let nativeValidationComplete = false
    public static var manifest: ModelPackManifest? { nativeValidationComplete ? candidateManifest : nil }

    public static let candidateManifest: ModelPackManifest = {
        let files: [(String, Int64, String, String)] = [
            ("Manifest.json", 617, "c814fff3cedf827c044094545ef80b0280b6cb8dd0e5c0bcf69fd31921191e58", "1-40HIeUCpHanmU_RDAylmMfBqylcdHlV"),
            ("model.mlmodel", 1_101_809, "06a100ef99e0fd16326a3a8c4a687d13f7b26f544ea906a75338932d8554f953", "1-QSt2xEbpoRJCO8wSS40Epk00PNis3an"),
            ("weight.bin", 215_544_960, "d0541f6044a94cd4982bfdac074fc1ccfe11d8f1f590c299d6b5071b501fc184", "1-SAHMkDJLY3eHQYhtu80S2elcy6i_tVH")
        ]
        return ModelPackManifest(id: "coremlama-fp32-d0541f6", title: "LaMa · CoreMLaMa FP32", license: "Apache-2.0", source: source,
            assets: files.map { name, size, digest, id in
                ModelAsset(name: name, bytes: size, sha256: digest,
                    url: URL(string: "https://drive.usercontent.google.com/download?id=\(id)&export=download&confirm=t")!,
                    allowedDownloadHosts: ["drive.usercontent.google.com"])
            })
    }()

    public static let verifiedMetadata: [(name: String, bytes: Int64, sha256: String, driveID: String)] = [
        ("Manifest.json", 617, "c814fff3cedf827c044094545ef80b0280b6cb8dd0e5c0bcf69fd31921191e58", "1-40HIeUCpHanmU_RDAylmMfBqylcdHlV"),
        ("model.mlmodel", 1_101_809, "06a100ef99e0fd16326a3a8c4a687d13f7b26f544ea906a75338932d8554f953", "1-QSt2xEbpoRJCO8wSS40Epk00PNis3an")
    ]
    public static let weightDriveID = "1-SAHMkDJLY3eHQYhtu80S2elcy6i_tVH"

    /// Snapshot verified flat assets into an isolated package; verify the copies
    /// again before Core ML sees them. This eliminates both archive extraction
    /// and a mutable-model-cache race. Only three known package paths exist.
    public static func materialize(in jobDirectory: URL, from modelDirectory: URL) throws -> URL {
        let manifest = candidateManifest
        try ModelAssetVerifier.verify(manifest, in: modelDirectory)
        guard Set(manifest.assets.map(\.name)) == Set(["Manifest.json", "model.mlmodel", "weight.bin"]) else { throw SmartEraseError.invalidModel }
        let fm = FileManager.default
        let package = jobDirectory.appendingPathComponent("LaMa.mlpackage", isDirectory: true)
        let weights = package.appendingPathComponent("Data/com.apple.CoreML/weights", isDirectory: true)
        try fm.createDirectory(at: weights, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let paths = ["Manifest.json": "Manifest.json", "model.mlmodel": "Data/com.apple.CoreML/model.mlmodel", "weight.bin": "Data/com.apple.CoreML/weights/weight.bin"]
        for asset in manifest.assets {
            guard let path = paths[asset.name] else { throw SmartEraseError.invalidModel }
            let destination = package.appendingPathComponent(path)
            try fm.copyItem(at: modelDirectory.appendingPathComponent(asset.name), to: destination)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            try ModelAssetVerifier.verify(asset, at: destination)
        }
        return package
    }
}
