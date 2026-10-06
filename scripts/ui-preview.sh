#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
ditto -x -k "dist/PicShot-0.8.0-macos-$(uname -m).zip" "$work"
app="$work/PicShot.app"
codesign --verify --deep --strict "$app"
mkdir -p dist/evidence/ui
export PICSHOT_UI_PREVIEW_ONLY=1
swift scripts/launch-smoke-app.swift "$app" "$PWD/dist/evidence/ui/preview.json"
python3 - "$PWD/dist/evidence/ui/preview.json" "$(git rev-parse HEAD)" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]));assert r['status']=='passed',r
assert r['uiPreviewOnly'] and not r['captureStarted'],r
assert r['sourceCommit']==sys.argv[2],r
assert r['annotationEffects']['status']=='passed',r
assert not r['annotationEffects']['screenCaptureAttempted'],r
parity=r['interactionParity']
assert parity['status']=='passed' and not parity['screenCaptureStarted'] and not parity['permissionRequested'],parity
for key in ['annotationPaths','scrollSequence','pinTextSelection']:
    assert parity[key]['status']=='passed',parity[key]
batch=r['captureExportRecognition']
assert batch['status']=='passed' and batch['settingsPresetRouteVerified'],batch
assert not batch['screenCaptureStarted'] and not batch['permissionRequested'] and not batch['externalURLVisited'],batch
for key in ['capturePresetsElements','imageExport','barcodes']:
    assert batch[key]['status']=='passed',batch[key]
assert r['codecUIPreview']['status']=='passed',r['codecUIPreview']
print(json.dumps(r,indent=2))
PY
