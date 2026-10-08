#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
ditto -x -k "dist/PicShot-0.15.0-macos-$(uname -m).zip" "$work"
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
ocr=r['pinOCRWorkflow']
assert ocr['status']=='passed' and ocr['sourceCommit']==sys.argv[2],ocr
assert ocr['realAppleVisionRan'] and ocr['actualFunctionalVisionCalls'] >= 1,ocr
assert ocr['finalVisionActiveJobs']==0 and ocr['finalVisionWaitingJobs']==0,ocr
assert ocr['temporaryDirectoryRemoved'] and ocr['privateDefaultsRemoved'],ocr
for key in ['standardUserDefaultsChanged','generalPasteboardChanged','screenCaptureStarted','permissionRequests','networkUsed','globalInputPosted']:
    assert ocr[key] is False,(key,ocr)
for key in ['controls','sourceLinkAcceptance','coordinatorRestoration']:
    assert ocr[key]['status']=='passed',ocr[key]
assert ocr['coordinatorRestoration']['releaseProbeCount']==60,ocr['coordinatorRestoration']
for key,value in ocr['coordinatorRestoration']['releaseEvidence'].items():
    if key.startswith('retained'): assert value==0,(key,value)
assert not ocr['includeResourceCycles'] and ocr['resourceEvidence']['status']=='not-run',ocr
print(json.dumps(r,indent=2))
PY

python3 scripts/check-pin-ocr-report.py "$PWD/dist/evidence/ui/pin-ocr/pin-ocr-workflow.json" "$app" "$(git rev-parse HEAD)" 0.15.0 "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
python3 scripts/check-automatic-mosaic-report.py "$PWD/dist/evidence/ui/automatic-mosaic/automatic-mosaic-workflow.json" "$app" "$(git rev-parse HEAD)" "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"

python3 scripts/check-annotation-details-report.py "$PWD/dist/evidence/ui/annotation-details/annotation-details.json" "$app" "$(git rev-parse HEAD)" "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"

# Source-specific pin UI gates from the same installed ZIP, each in its own process.
bash scripts/pin-workflows-smoke.sh "$app" "$PWD/dist/evidence/ui/pin-workflows" "$(git rev-parse HEAD)"

python3 - "$PWD/dist/evidence/ui/manual-scroll/scroll-manual-continuous.json" "$(git rev-parse HEAD)" <<'PY_CHECK'
import importlib.util,pathlib,struct,sys
spec=importlib.util.spec_from_file_location('manual','scripts/check-scroll-manual-resource-report.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
r=module.read_json(sys.argv[1]);module.functional(r,sys.argv[2])
previews=r['nativeAppearanceSnapshots'];assert previews['exactReferencePixels'] is True
assert previews['acceptedFrames']==3 and (previews['outputWidth'],previews['outputHeight'])==(640,920)
expected={f'scroll-manual-{kind}-{theme}.png' for kind in ['paused-controls','stopped-preview'] for theme in ['light','dark']}
assert set(previews['files'])==expected
for name in expected:
    data=(pathlib.Path(sys.argv[1]).parent/name).read_bytes()
    assert data.startswith(b'\x89PNG\r\n\x1a\n')
    width,height=struct.unpack('>II',data[16:24]);assert 0<width<=1200 and 0<height<=1000
print('Continuous manual scroll native functional evidence passed')
PY_CHECK

python3 scripts/check-capture-output-report.py "$PWD/dist/evidence/ui/capture-output/capture-output-workflow.json" "$app" "$(git rev-parse HEAD)"
