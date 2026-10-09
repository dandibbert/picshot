#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/build-native-codecs.py --arch "$(uname -m)"
swift build -c release
bin=$(swift build -c release --show-bin-path)
version=0.17.0
arch=$(uname -m)
sha=$(git rev-parse HEAD)
app=dist/PicShot.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Helpers"
cp "$bin/PicShot" "$app/Contents/MacOS/PicShot"
cp "$bin/PicShotMLHelper" "$app/Contents/Helpers/PicShotMLHelper"
cp "$bin/PicShotCodecHelper" "$app/Contents/Helpers/PicShotCodecHelper"
codesign --force --sign - --identifier local.picshot.codechelper "$app/Contents/Helpers/PicShotCodecHelper"
mkdir -p "$app/Contents/Resources/NativeCodecs"
ditto .build/native-codecs/install/licenses "$app/Contents/Resources/NativeCodecs/licenses"
cp .build/native-codecs/install/native-build.json .build/native-codecs/install/native-selftest-dependencies.txt "$app/Contents/Resources/NativeCodecs/"
cp docs/WEB_CODECS.md "$app/Contents/Resources/NativeCodecs/"
python3 - "$app/Contents/Helpers/PicShotCodecHelper" "$app/Contents/Resources/NativeCodecs" <<'PYTHON'
import json, pathlib, platform, subprocess, sys, hashlib
helper, evidence = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
r = json.loads((evidence / 'native-build.json').read_text())
assert r['native_selftest'] == 'passed' and r['architecture'] == platform.machine(), r
for name, dependency in r['dependencies'].items():
    for entry in dependency['notices']:
        path = evidence / 'licenses' / name / entry['path']
        assert hashlib.sha256(path.read_bytes()).hexdigest() == entry['sha256_local'], path
assert subprocess.check_output(['lipo', '-archs', str(helper)], text=True).strip() == platform.machine()
for line in subprocess.check_output(['otool', '-L', str(helper)], text=True).splitlines()[1:]:
    library = line.strip().split(' ', 1)[0]
    assert library.startswith(('/usr/lib/', '/System/Library/')), library
PYTHON
python3 scripts/bundle-runtime.py "$app"
cp "$bin/PicShotEraseHelper" "$app/Contents/Helpers/PicShotEraseHelper"
codesign --force --sign - --identifier local.picshot.erasehelper "$app/Contents/Helpers/PicShotEraseHelper"
cp "$bin/PicShotFormulaRenderHelper" "$app/Contents/Helpers/PicShotFormulaRenderHelper"
ditto "$bin/PicShot_PicShotFormulaRenderHelper.bundle" "$app/Contents/Resources/PicShot_PicShotFormulaRenderHelper.bundle"
codesign --force --sign - --identifier local.picshot.formularenderhelper "$app/Contents/Helpers/PicShotFormulaRenderHelper"
cp docs/FormulaRender.md "$app/Contents/Resources/"
cp docs/SmartErase.md docs/SmartErase_CoreMLaMa_LICENSE.txt docs/SmartErase_LaMa_LICENSE.txt "$app/Contents/Resources/"
cp docs/MODELS.md docs/ONNX_RUNTIME_LICENSE.txt docs/ONNX_RUNTIME_THIRD_PARTY_NOTICES.txt docs/TABLE_MODEL.md "$app/Contents/Resources/"
swift scripts/build-icon.swift "$PWD/$app/Contents/Resources/PicShot.icns"
iconutil -c icns "$app/Contents/Resources/PicShot.iconset" -o "$app/Contents/Resources/PicShot.icns"
rm -rf "$app/Contents/Resources/PicShot.iconset"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PicShot</string><key>CFBundleIdentifier</key><string>local.picshot.app</string><key>CFBundleName</key><string>PicShot</string><key>CFBundleDisplayName</key><string>PicShot</string><key>CFBundleIconFile</key><string>PicShot</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>$version</string><key>CFBundleVersion</key><string>${GITHUB_RUN_NUMBER:-1}</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>NSHighResolutionCapable</key><true/><key>PicShotSourceCommit</key><string>$sha</string><key>NSMicrophoneUsageDescription</key><string>仅在你选择麦克风录屏后录制声音。</string><key>NSCameraUsageDescription</key><string>仅在你启用录屏摄像头画中画后使用所选摄像头。</string><key>NSScreenCaptureUsageDescription</key><string>仅在你点击截图或录屏后捕获所选屏幕内容。</string></dict></plist>
PLIST
cat > "$app/Contents/Resources/build-info.json" <<JSON
{"app":"PicShot","version":"$version","architecture":"$arch","sourceCommit":"$sha","minimumMacOS":"14.0","signing":"ad-hoc","notarized":false}
JSON
codesign --force --deep --sign - --identifier local.picshot.app "$app"
codesign --verify --deep --strict "$app"
# Prove the installed helper can render after relocation while the original
# SwiftPM build bundle is unavailable. The verifier restores it before returning.
python3 scripts/FormulaRender-verify-packaged-runtime.py --app "$app" --build-bundle "$bin/PicShot_PicShotFormulaRenderHelper.bundle"
codesign --verify --deep --strict "$app"
# Diagnostic jobs need the verified signed app, without creating installers.
if [[ "${PICSHOT_PACKAGE_APP_ONLY:-0}" == "1" ]]; then
  echo "Signed diagnostic application prepared"
  exit 0
fi
base="PicShot-$version-macos-$arch"
ditto -c -k --sequesterRsrc --keepParent "$app" "dist/$base.zip"
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/PicShot.app"
ln -s /Applications "$staging/Applications"
cat > "$staging/安装说明.txt" <<'TEXT'
将 PicShot.app 拖到 Applications 后打开。需要 macOS 14 或更新版本。
开发预览，尚未实现全部 PixPin 功能。功能差异见项目 docs/PARITY.md。
此包使用 ad-hoc 签名，未经 Developer ID 签名和 Apple 公证。
首次打开若被阻止，请确认来源后在系统设置 → 隐私与安全性中允许打开。
点击截图或录屏后，按系统提示授予屏幕录制权限。应用不会自动上传截图。
新安装快捷键：⌃1 区域截图；⌃2 剪贴板贴图；⌃3 恢复最后关闭的贴图；⌃⌘H 历史记录。旧版已保存的自定义快捷键保留，可在设置修改。
录屏：最长 10 分钟，最多 1 GB；可选择最多 30 秒的录制片段导出 GIF。
MP4 修剪单独导出新副本，不覆盖原录制。
动画 WebP 最多 60 秒且不超过 600 帧，无声音；静态 WebP/AVIF 在导出预览中设置。
保存图标旁的小箭头提供快速 PNG 保存、保存并复制及命名设置；自动副本默认关闭。
TEXT
hdiutil create -volname PicShot -srcfolder "$staging" -format UDZO -ov "dist/$base.dmg"
hdiutil verify "dist/$base.dmg"
cp "$app/Contents/Resources/build-info.json" "dist/$base.build-info.json"
(cd dist;for f in "$base.zip" "$base.dmg" "$base.build-info.json";do shasum -a 256 "$f" > "$f.sha256";done)
