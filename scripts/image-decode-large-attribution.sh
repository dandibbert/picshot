#!/bin/bash
# Explicit standalone diagnostic. No default release hook or installer.
set -euo pipefail
if [[ $# -ne 3 || ( "$1" != --compare && "$1" != --timing-v3 ) ]]; then
  echo 'Usage: image-decode-large-attribution.sh {--compare|--timing-v3} /absolute/PicShot.app /absolute/new-evidence-directory' >&2
  exit 64
fi
cd "$(dirname "$0")/.."
app="$2"; root="$3"
if [[ "$1" == --timing-v3 ]]; then
  export PICSHOT_IMAGE_DECODE_LARGE_TIMING=3
else
  unset PICSHOT_IMAGE_DECODE_LARGE_TIMING
fi
check_report() {
  if [[ "${PICSHOT_IMAGE_DECODE_LARGE_TIMING:-}" == 3 ]]; then
    python3 scripts/check-image-decode-large-report.py "$@" --timing-v3
  else
    python3 scripts/check-image-decode-large-report.py "$@"
  fi
}
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
import os,sys
for path,needle in [(sys.argv[1],b'image-decode-large-parent-v2'),(sys.argv[2],b'--image-draw-decode-diagnostic-v3' if os.getenv('PICSHOT_IMAGE_DECODE_LARGE_TIMING') == '3' else b'--image-draw-decode-diagnostic-v2')]:
    with open(path,'rb') as stream:
        tail=b''
        while True:
            block=stream.read(1024*1024)
            if not block: raise SystemExit('Missing explicit v2 diagnostic hook')
            if needle in tail+block: break
            tail=block[-len(needle):]
PY
mkdir -p "$(dirname "$root")"
mkdir "$root"
for profile in 4k 5k; do
  swift scripts/launch-image-decode-large.swift "$app" prepare "$profile" "$root/prepared-$profile"
  for mode in production-control isolated-decode; do
    swift scripts/launch-image-decode-large.swift "$app" "$mode" "$profile" "$root/$profile-$mode" "$root/prepared-$profile"
  done
done
# UI runs only after all large source/preview/exit/pixel checks succeed.
check_report "$root" "$source_commit" "$architecture" --headless-only
for mode in native-ui-control native-ui-isolated; do
  swift scripts/launch-image-decode-large.swift "$app" "$mode" 5k "$root/5k-$mode" "$root/prepared-5k"
done
check_report "$root" "$source_commit" "$architecture"
