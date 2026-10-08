#!/bin/bash
# macOS-only, dependency-free source-scoped fixture. This copies production
# files verbatim; its support declarations are extracted from CaptureService.
# It does not replace the full app build or AppMain/editor integration tests.
set -euo pipefail
picshot_root="$(cd "$(dirname "$0")/.." && pwd)"
picshot_scope="$(mktemp -d "${TMPDIR:-/tmp}/PicShot-MultiWindow-Scope.XXXXXX")"
trap 'rm -rf "$picshot_scope"' EXIT
mkdir -p "$picshot_scope/Sources/PicShot" "$picshot_scope/Sources/PicShotCore" "$picshot_scope/Tests/PicShotTests" "$picshot_scope/Tests/PicShotCoreTests"
cp "$picshot_root"/Sources/PicShot/MultiWindow*.swift "$picshot_scope/Sources/PicShot/"
cp "$picshot_root/Sources/PicShot/DisplayConfigurationWatcher.swift" "$picshot_scope/Sources/PicShot/"
cp "$picshot_root/Sources/PicShot/ImageBackingMemoryReading.swift" "$picshot_scope/Sources/PicShot/"
cp "$picshot_root/Sources/PicShotCore/MultiWindowCaptureLayout.swift" "$picshot_root/Sources/PicShotCore/DisplayCompositeLayout.swift" "$picshot_root/Sources/PicShotCore/ScreenshotCaptureOptions.swift" "$picshot_scope/Sources/PicShotCore/"
cp "$picshot_root"/Tests/PicShotTests/MultiWindow*.swift "$picshot_scope/Tests/PicShotTests/"
cp "$picshot_root/Tests/PicShotCoreTests/MultiWindowCaptureLayoutTests.swift" "$picshot_scope/Tests/PicShotCoreTests/"
cat > "$picshot_scope/Sources/PicShot/CaptureSupport.swift" <<'SUPPORT'
import AppKit
import CoreGraphics
SUPPORT
awk '/^enum CaptureError:/{copy=1} /^@MainActor/{if(copy) exit} copy' "$picshot_root/Sources/PicShot/CaptureService.swift" >> "$picshot_scope/Sources/PicShot/CaptureSupport.swift"
awk '/^extension NSScreen \{/{copy=1} copy {print} copy && /^\}/{exit}' "$picshot_root/Sources/PicShot/CaptureService.swift" >> "$picshot_scope/Sources/PicShot/CaptureSupport.swift"
cat > "$picshot_scope/Package.swift" <<'PACKAGE'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "PicShotMultiWindowSourceScope", platforms: [.macOS(.v14)], targets: [
    .target(name: "PicShotCore"), .target(name: "PicShot", dependencies: ["PicShotCore"]),
    .testTarget(name: "PicShotCoreTests", dependencies: ["PicShotCore"]),
    .testTarget(name: "PicShotTests", dependencies: ["PicShot", "PicShotCore"])
])
PACKAGE
shasum -a 256 "$picshot_root"/Sources/PicShot/MultiWindow*.swift "$picshot_root/Sources/PicShotCore/MultiWindowCaptureLayout.swift" "$picshot_root"/Tests/PicShotTests/MultiWindow*.swift "$picshot_root/Tests/PicShotCoreTests/MultiWindowCaptureLayoutTests.swift"
swift test --package-path "$picshot_scope" --filter MultiWindow
