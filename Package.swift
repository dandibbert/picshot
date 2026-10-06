// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "PicShot", platforms: [.macOS(.v14)],
    products: [.executable(name: "PicShot", targets: ["PicShot"]), .executable(name: "PicShotMLHelper", targets: ["PicShotMLHelper"]), .executable(name: "PicShotEraseHelper", targets: ["PicShotEraseHelper"])],
    dependencies: [.package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", revision: "b7fb7f7dea8a2469e6335d95a61b8f36d0dc83b2")],
    targets: [
        .target(name: "PicShotCore"),
        .target(name: "PicShotFormulaCore"),
        .target(name: "PicShotEraseCore", dependencies: ["PicShotFormulaCore"]),
        .executableTarget(name: "PicShotEraseHelper", dependencies: ["PicShotEraseCore"]),
        .target(name: "PicShotTableEngine", dependencies: ["PicShotCore"]),
        .executableTarget(name: "PicShot", dependencies: ["PicShotCore", "PicShotFormulaCore", "PicShotTableEngine", "PicShotEraseCore"]),
        .executableTarget(name: "PicShotMLHelper", dependencies: ["PicShotFormulaCore", "PicShotTableEngine", .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")]),
        .testTarget(name: "PicShotCoreTests", dependencies: ["PicShotCore"]),
        .testTarget(name: "PicShotTests", dependencies: ["PicShot"]),
        .testTarget(name: "PicShotEraseCoreTests", dependencies: ["PicShotEraseCore"]),
        .testTarget(name: "PicShotEraseHelperTests", dependencies: ["PicShotEraseHelper", "PicShotEraseCore"]),
        .testTarget(name: "PicShotFormulaCoreTests", dependencies: ["PicShotFormulaCore"]),
        .testTarget(name: "PicShotMLHelperTests", dependencies: ["PicShotMLHelper"], resources: [.copy("Fixtures")]),
        .testTarget(name: "PicShotTableEngineTests", dependencies: ["PicShotTableEngine"], resources: [.process("Fixtures")])
    ]
)
