// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "PicShot", platforms: [.macOS(.v14)], products: [.executable(name: "PicShot", targets: ["PicShot"])], targets: [
    .target(name: "PicShotCore"),
    .executableTarget(name: "PicShot", dependencies: ["PicShotCore"]),
    .testTarget(name: "PicShotCoreTests", dependencies: ["PicShotCore"]),
    .testTarget(name: "PicShotTests", dependencies: ["PicShot"])
])
