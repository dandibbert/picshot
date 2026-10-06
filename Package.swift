// swift-tools-version: 5.9
import PackageDescription
import Foundation

let codecPrefix = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".build/native-codecs/install").path
let package = Package(
    name: "PicShot", platforms: [.macOS(.v14)],
    products: [.executable(name: "PicShot", targets: ["PicShot"]), .executable(name: "PicShotMLHelper", targets: ["PicShotMLHelper"]), .executable(name: "PicShotEraseHelper", targets: ["PicShotEraseHelper"]), .executable(name: "PicShotFormulaRenderHelper", targets: ["PicShotFormulaRenderHelper"]), .executable(name: "PicShotCodecHelper", targets: ["PicShotCodecHelper"])],
    dependencies: [.package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", revision: "b7fb7f7dea8a2469e6335d95a61b8f36d0dc83b2")],
    targets: [
        .target(name: "PicShotCore"),
        .target(name: "PicShotCodecCore"),
        .target(name: "CPicShotCodecs", path: "Sources/CPicShotCodecs", exclude: ["tests"], publicHeadersPath: "include",
                cSettings: [.unsafeFlags(["-I" + codecPrefix + "/include"])],
                linkerSettings: [.unsafeFlags(["-L" + codecPrefix + "/lib"]), .linkedLibrary("webpdemux"),
                                 .linkedLibrary("webp"), .linkedLibrary("sharpyuv"), .linkedLibrary("avif"),
                                 .linkedLibrary("aom"), .linkedLibrary("c++")]),
        .executableTarget(name: "PicShotCodecHelper", dependencies: ["PicShotCodecCore", "CPicShotCodecs"]),
        .target(name: "PicShotFormulaCore"),
        .target(name: "PicShotFormulaRenderCore"),
        .executableTarget(name: "PicShotFormulaRenderHelper", dependencies: ["PicShotFormulaRenderCore"], resources: [.copy("FormulaRenderResources")]),
        .target(name: "PicShotEraseCore", dependencies: ["PicShotFormulaCore"]),
        .executableTarget(name: "PicShotEraseHelper", dependencies: ["PicShotEraseCore"]),
        .target(name: "PicShotTableEngine", dependencies: ["PicShotCore"]),
        .executableTarget(name: "PicShot", dependencies: ["PicShotCore", "PicShotFormulaCore", "PicShotTableEngine", "PicShotEraseCore", "PicShotFormulaRenderCore", "PicShotCodecCore"]),
        .executableTarget(name: "PicShotMLHelper", dependencies: ["PicShotFormulaCore", "PicShotTableEngine", .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")]),
        .testTarget(name: "PicShotCoreTests", dependencies: ["PicShotCore"]),
        .testTarget(name: "PicShotCodecCoreTests", dependencies: ["PicShotCodecCore"]),
        .testTarget(name: "PicShotCodecHelperTests", dependencies: ["PicShotCodecHelper", "PicShotCodecCore", "CPicShotCodecs"]),
        .testTarget(name: "PicShotTests", dependencies: ["PicShot", "PicShotFormulaRenderCore"]),
        .testTarget(name: "PicShotEraseCoreTests", dependencies: ["PicShotEraseCore"]),
        .testTarget(name: "PicShotEraseHelperTests", dependencies: ["PicShotEraseHelper", "PicShotEraseCore"]),
        .testTarget(name: "PicShotFormulaCoreTests", dependencies: ["PicShotFormulaCore"]),
        .testTarget(name: "PicShotFormulaRenderCoreTests", dependencies: ["PicShotFormulaRenderCore"]),
        .testTarget(name: "PicShotFormulaRenderHelperTests", dependencies: ["PicShotFormulaRenderHelper", "PicShotFormulaRenderCore"]),
        .testTarget(name: "PicShotMLHelperTests", dependencies: ["PicShotMLHelper"], resources: [.copy("Fixtures")]),
        .testTarget(name: "PicShotTableEngineTests", dependencies: ["PicShotTableEngine"], resources: [.process("Fixtures")])
    ]
)
