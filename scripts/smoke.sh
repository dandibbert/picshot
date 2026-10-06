#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
base="PicShot-0.1.0-macos-$(uname -m)"
work=$(mktemp -d)
mounted=false
trap 'if [[ "$mounted" == true ]];then hdiutil detach "$work/mount" || true;fi;rm -rf "$work"' EXIT
mkdir -p dist/evidence "$work/zip" "$work/dmg" "$work/mount"
ditto -x -k "dist/$base.zip" "$work/zip"
hdiutil attach -nobrowse -readonly -mountpoint "$work/mount" "dist/$base.dmg"
mounted=true
test "$(readlink "$work/mount/Applications")" = /Applications
ditto "$work/mount/PicShot.app" "$work/dmg/PicShot.app"
hdiutil detach "$work/mount"
mounted=false
for format in zip dmg;do
  app="$work/$format/PicShot.app"
  codesign --verify --deep --strict "$app"
  test "$(lipo -archs "$app/Contents/MacOS/PicShot")" = "$(uname -m)"
  mkdir -p "dist/evidence/$format"
  swift scripts/launch-smoke-app.swift "$app" "$PWD/dist/evidence/$format/launch.json"
  python3 - "$PWD/dist/evidence/$format/launch.json" "$app" "$(git rev-parse HEAD)" <<'PY'
import json,sys,pathlib
r=json.load(open(sys.argv[1]));assert r['status']=='passed',r
assert r['mainWindowVisible'] and r['safeMode'] and not r['captureStarted'],r
assert r['sourceCommit']==sys.argv[3],r
assert pathlib.Path(r['bundlePath']).resolve()==pathlib.Path(sys.argv[2]).resolve(),r
assert len(r['arguments'])==1,r
assert r['resourceCycleCount']==40 and r['baselineRSSBytes']>0,r
print(json.dumps(r,indent=2))
PY
done
