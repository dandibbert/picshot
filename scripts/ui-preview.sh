#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
ditto -x -k "dist/PicShot-0.9.0-macos-$(uname -m).zip" "$work"
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
save=r['saveWorkflowUI']
assert save['status']=='passed' and save['quietAutomaticFinalizedAction'],save
assert not save['userPreferencesRead'] and not save['generalPasteboardReadOrWritten'],save
assert not save['liveScreenCaptured'] and not save['networkAttempted'],save
assert save['maximumSaveJobs']==2 and save['estimatedRetainedInputBudgetBytes']==256*1024*1024,save
assert len(save['resourceCycles'])==10 and sum(not x['warmup'] for x in save['resourceCycles'])==8,save
for c in save['resourceCycles']:
    assert c['activeJobs']==0 and c['retainedInputBytes']==0 and c['controllerReleased'] and c['temporaryJobRemoved'],c
print(json.dumps(r,indent=2))
PY
