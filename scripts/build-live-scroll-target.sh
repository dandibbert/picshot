#!/bin/bash
set -euo pipefail
cd -P "$(dirname "$0")/.."
app="${1:-$PWD/.build/LiveScrollTarget.app}"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LiveScrollTarget</string>
<key>CFBundleIdentifier</key><string>dev.picshot.live-scroll-owned-target</string>
<key>CFBundleName</key><string>PicShot Owned Scroll Target</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xcrun swiftc -parse-as-library -swift-version 5 -O \
  -framework AppKit -framework ImageIO -framework UniformTypeIdentifiers \
  scripts/live-scroll-target.swift -o "$app/Contents/MacOS/LiveScrollTarget"
codesign --force --sign - "$app"
printf '%s\n' "$app/Contents/MacOS/LiveScrollTarget"
