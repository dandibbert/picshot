#!/bin/bash
# Explicit diagnostic only. Uses the existing signed app, never an installer.
set -euo pipefail
if [[ $# -ne 3 || "$1" != --compare ]]; then
  echo 'Usage: image-decode-helper-attribution.sh --compare /absolute/PicShot.app /absolute/new-evidence-directory' >&2
  exit 64
fi
cd "$(dirname "$0")/.."
app="$2"; root="$3"
[[ "$app" == /* && "$root" == /* && "$app" == *.app && ! -e "$root" ]] || exit 64
[[ "$(uname -s)" == Darwin ]] || exit 69
architecture=$(uname -m)
[[ "$architecture" == arm64 || "$architecture" == x86_64 ]] || exit 69
binary="$app/Contents/MacOS/PicShot"; helper="$app/Contents/Helpers/PicShotCodecHelper"
/usr/bin/codesign --verify --deep --strict "$app"
/usr/bin/codesign --verify --strict "$helper"
/usr/bin/lipo "$binary" -verify_arch "$architecture"
/usr/bin/lipo "$helper" -verify_arch "$architecture"
source_commit=$(/usr/libexec/PlistBuddy -c 'Print :PicShotSourceCommit' "$app/Contents/Info.plist")
[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || exit 65
python3 - "$binary" "$helper" <<'PY'
import sys
for path,needle in [(sys.argv[1],b'image-decode-helper-parent-v1'),(sys.argv[2],b'--image-draw-decode-diagnostic-v1')]:
    with open(path,'rb') as f:
        tail=b''
        while True:
            block=f.read(1024*1024)
            if not block: raise SystemExit('Missing explicit helper diagnostic protocol')
            if needle in tail+block: break
            tail=block[-len(needle):]
PY
mkdir -p "$(dirname "$root")"
mkdir "$root"
# Preparation is the already bounded separate-process draw fixture.
swift scripts/launch-image-draw.swift "$app" prepare-inputs "$root/prepared"
for mode in production-control isolated-decode cancel-after-decode timeout-after-decode; do
  swift scripts/launch-image-decode-helper.swift "$app" "$mode" "$root/$mode" "$root/prepared"
done
python3 scripts/check-image-decode-helper-report.py "$root" "$source_commit" "$architecture"
