#!/bin/bash
set -euo pipefail
cd -P "$(dirname "$0")/.."
# Keep the installed app on a physical workspace path. Foundation may remove
# /private from temporary URLs while POSIX realpath preserves it; evidence
# must identify the same literal installed bundle in every producer/checker.
mkdir -p dist
test "$(cd dist && pwd -P)" = "$PWD/dist"
work=$(mktemp -d "$PWD/dist/ui-preview.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
ditto -x -k "dist/PicShot-0.17.0-macos-$(uname -m).zip" "$work"
app="$work/PicShot.app"
codesign --verify --deep --strict "$app"
mkdir -p dist/evidence/ui
export PICSHOT_UI_PREVIEW_ONLY=1
swift scripts/launch-smoke-app.swift "$app" "$PWD/dist/evidence/ui/preview.json"
python3 - "$PWD/dist/evidence/ui/preview.json" "$(git rev-parse HEAD)" <<'PY'
import json,pathlib,sys
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
layout=batch['capturePresetsElements']['fakeProvider']['elementButtonLayout']
assert len(layout)==3 and {item['identifier'] for item in layout}=={'capture.elements.toggle','capture.elements.parent','capture.elements.child'},layout
assert all(item['hitTargetVerified'] is True for item in layout),layout
assert r['codecUIPreview']['status']=='passed',r['codecUIPreview']
inputs=r['recordingInputControls']
assert inputs['status']=='passed' and inputs['interactionStatus']=='passed' and inputs['contentWidthPoints']==440,inputs
assert inputs['interactionRoute']=='NSButton.performClick' and inputs['hitTestRoute']=='NSView.hitTest',inputs
assert inputs['nativeMonitorRegistrations']==0 and inputs['injectedPermissions'] is True,inputs
for key in ['recordingStarted','screenCaptureStarted','permissionRequested','globalInputPosted']:
    assert inputs[key] is False,inputs
assert len(inputs['appearances'])==2 and {x['appearance'] for x in inputs['appearances']}=={'light','dark'},inputs
button_ids={'recording-input-'+x for x in ['clicks','scrolls','shortcuts','help']}
for appearance in inputs['appearances']:
    ownership=appearance['ownership']
    assert ownership['status']=='passed' and ownership['retainedObjects']==0 and ownership['weakProbeCount']>=30,ownership
    assert 0<=ownership['releaseMilliseconds']<=ownership['deadlineMilliseconds']==3000,ownership
    lifecycle=appearance['representableLifecycle']
    assert lifecycle['status']=='passed',lifecycle
    for key in ['replacementBindingVerified','externalStateVerified','replacementActionVerified','inheritedDisableVerified','nativeControlAndCoordinatorReuseVerified']:
        assert lifecycle[key] is True,lifecycle
    full=appearance['fullPanel']
    assert (full['contentWidthPoints'],full['contentHeightPoints'])==(480,490),full
    assert full['syntheticTarget'] is True and full['syntheticTargetChecks']==1,full
    assert full['cameraRequested'] is False and full['recordingStarted'] is False,full
    sections=full['panelSectionGeometry']
    assert set(sections)=={'default-off','denied','allowed','restored-off'},sections
    for rows in sections.values():
        assert len(rows)==7 and {x['section'] for x in rows}=={'options','start','divider','effects','status','previewHint','privacyHint'},rows
        for row in rows:
            assert row['insideContent'] is True and row['nonoverlapping'] is True and row['coordinateSystem']=='top-left',row
            assert row['width']>0 and row['height']>0 and row['x']>=-0.5 and row['y']>=-0.5,row
            assert row['x']+row['width']<=480.5 and row['y']+row['height']<=490.5,row
    for context,prefix,size in [(appearance,'recording-input',(440,100)),(full,'recording-panel',(480,490))]:
        assert context['status']=='passed' and context['interactionStatus']=='passed' and context['layoutStatus']=='passed',context
        assert context['defaultOff'] is True and context['initialPermissionChecks']==0,context
        assert context['nativeMonitorRegistrations']==0,context
        assert context['nativeTogglePresses']==12 and context['finalOptionsMatchInitial'] is True,context
        assert context['helpAndRefreshVerified'] is True and context['nativeHelpPresses']==4 and context['nativeRefreshPresses']==2,context
        expected={'clicks':False,'scrolls':False,'shortcuts':False}
        actions=[(control,enabled) for control in ['clicks','scrolls','shortcuts'] for enabled in [True,False,True]]
        actions += [(control,False) for control in ['clicks','scrolls','shortcuts']]
        assert len(context['optionRoundTrips'])==len(actions),context
        for step,(control,enabled) in zip(context['optionRoundTrips'],actions):
            expected[control]=enabled
            assert step==dict(control=control,enabled=enabled,**expected),step
        for key in ['defaultOffGeometry','deniedGeometry','allowedGeometry','restoredOffGeometry','helpGeometry']:
            rows=context[key]
            expected_ids={'recording-input-refresh'} if key=='helpGeometry' else button_ids | ({'recording-input-status'} if key in ['deniedGeometry','allowedGeometry'] else set())
            assert len(rows)==len(expected_ids) and {x['identifier'] for x in rows}==expected_ids,rows
            for row in rows:
                assert row['insideContent'] is True and row['nonoverlapping'] is True and row['accessibilityIdentifierVerified'] is True,row
                assert row['nativeHitTargetVerified'] is (row['identifier']!='recording-input-status'),row
                assert row['width']>0 and row['height']>0,row
        expected_files={f'{prefix}-{state}-{appearance["appearance"]}.png' for state in ['default-off','denied','help-denied','help-allowed','allowed','restored-off']}
        assert set(context['files'])==expected_files,context
        expected_geometry={filename[:-4]+'-geometry.json' for filename in expected_files}
        assert set(context['geometryFiles'])==expected_geometry,context
        for filename in context['geometryFiles']:
            assert pathlib.Path(filename).name==filename,filename
            measurement=json.loads((pathlib.Path(sys.argv[1]).parent/filename).read_text())
            assert measurement['status']=='measured-before-validation' and measurement['coordinateSystem']=='top-left',measurement
            assert len(measurement['controls']) in [1,5],measurement
            for row in measurement['controls']:
                assert row['matchCount'] in [0,1] and len(row['views'])==row['matchCount'],row
                for view in row['views']:
                    assert all(inset==0 for inset in view['alignmentInsets'].values()),view
                    assert all(abs(view['frame'][key]-view['alignmentFrame'][key])<=0.5 for key in ['x','y','width','height']),view
            assert not any(overlap['intersection']['width']>0.5 and overlap['intersection']['height']>0.5 for overlap in measurement['intersections']),measurement
        for filename in context['files']:
            assert pathlib.Path(filename).name==filename,filename
            data=(pathlib.Path(sys.argv[1]).parent/filename).read_bytes()
            assert data.startswith(b'\x89PNG\r\n\x1a\n'),filename
            import struct
            dimensions=struct.unpack('>II',data[16:24])
            if '-help-' not in filename:
                assert dimensions==size,(filename,dimensions)
            else:
                assert 0<dimensions[0]<=600 and 0<dimensions[1]<=800,(filename,dimensions)
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

python3 scripts/check-pin-ocr-report.py "$PWD/dist/evidence/ui/pin-ocr/pin-ocr-workflow.json" "$app" "$(git rev-parse HEAD)" 0.17.0 "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
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
python3 scripts/check-effect-output-failure-report.py "$PWD/dist/evidence/ui/capture-output/effect-output-failure.json" "$app" "$(git rev-parse HEAD)" "$PWD/dist/evidence/ui/preview.json.launcher.json"

# Reopen actual saved annotation documents in a fresh owned installed process.
bash scripts/editable-annotation-smoke.sh "$app" "$PWD/dist/evidence/ui/editable-annotations" "$(git rev-parse HEAD)" functional
