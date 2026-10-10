#!/bin/bash
set -euo pipefail
cd -P "$(dirname "$0")/.."
# Keep the previously ambiguous installed recording wait observable in the
# original broad ordering. This changes no recording work, limit or assertion.
export PICSHOT_RECORDING_COMPOSITION_TRACE=1
export PICSHOT_SMOKE_ERASE_MODEL_DIR="$PWD/.build/model-fixtures/erase"
export PICSHOT_SMOKE_FORMULA_MODEL_DIR="$PWD/.build/model-fixtures/formula"
export PICSHOT_SMOKE_FORMULA_INPUT="$PWD/Tests/PicShotMLHelperTests/Fixtures/energy.png"
export PICSHOT_SMOKE_TABLE_MODEL_DIR="$PWD/.build/model-fixtures/table"
export PICSHOT_SMOKE_TABLE_INPUT="$PWD/Tests/PicShotTableEngineTests/Fixtures/merged-table.png"
base="PicShot-0.19.1-macos-$(uname -m)"
# Keep the actual installed bundle and all evidence on physical workspace paths.
# /var-style temporary aliases are rejected by the strict product protocol.
mkdir -p dist
test "$(cd dist && pwd -P)" = "$PWD/dist"
mkdir -p dist/evidence
test "$(cd dist/evidence && pwd -P)" = "$PWD/dist/evidence"
work=$(mktemp -d "$PWD/dist/installer-smoke.XXXXXXXX")
mounted=false
trap 'if [[ "$mounted" == true ]];then hdiutil detach "$work/mount" || true;fi;rm -rf "$work"' EXIT
mkdir -p "$work/zip" "$work/dmg" "$work/mount"
ditto -x -k "dist/$base.zip" "$work/zip"
hdiutil attach -nobrowse -readonly -mountpoint "$work/mount" "dist/$base.dmg"
mounted=true
test "$(readlink "$work/mount/Applications")" = /Applications
ditto "$work/mount/PicShot.app" "$work/dmg/PicShot.app"
hdiutil detach "$work/mount"
mounted=false
# Both installer formats must contain exactly the same signed product and
# provenance before the ZIP-only default resource gate can cover that binary.
for relative in Contents/MacOS/PicShot Contents/Info.plist Contents/Resources/build-info.json; do
  cmp "$work/zip/PicShot.app/$relative" "$work/dmg/PicShot.app/$relative"
done
python3 - "$work" "$PWD/dist/evidence/installed-format-identity.json" "$(git rev-parse HEAD)" "$(uname -m)" <<'PY_IDENTITY'
import hashlib, json, pathlib, plistlib, sys
work, output = map(pathlib.Path, sys.argv[1:3])
expected_source, expected_arch = sys.argv[3:5]
identities = {}
for format in ('zip', 'dmg'):
    app = work / format / 'PicShot.app'
    if str(app.resolve()) != str(app):
        raise ValueError('Installed bundle path is not canonical')
    executable = (app / 'Contents/MacOS/PicShot').read_bytes()
    plist_bytes = (app / 'Contents/Info.plist').read_bytes()
    build_bytes = (app / 'Contents/Resources/build-info.json').read_bytes()
    info, build = plistlib.loads(plist_bytes), json.loads(build_bytes)
    if not (info['PicShotSourceCommit'] == build['sourceCommit'] == expected_source
            and build['architecture'] == expected_arch
            and info['CFBundleExecutable'] == 'PicShot'
            and info['CFBundleShortVersionString'] == build['version']):
        raise ValueError('Installed source, architecture or version differs')
    identities[format] = dict(bundlePath=str(app), sourceCommit=expected_source,
        architecture=expected_arch, version=info['CFBundleShortVersionString'],
        buildVersion=info['CFBundleVersion'], executableBytes=len(executable),
        executableSHA256=hashlib.sha256(executable).hexdigest(),
        plistSHA256=hashlib.sha256(plist_bytes).hexdigest(),
        buildInfoSHA256=hashlib.sha256(build_bytes).hexdigest())
if any(identities['zip'][key] != identities['dmg'][key]
       for key in identities['zip'] if key != 'bundlePath'):
    raise ValueError('ZIP and DMG installed identities differ')
output.write_text(json.dumps(dict(status='passed', exactInstalledBinaryIdentity=True,
    formats=identities), indent=2) + '\n')
PY_IDENTITY
for format in zip dmg;do
  app="$work/$format/PicShot.app"
  if [[ "$format" == zip ]];then export PICSHOT_SMOKE_GIF_RESOURCES=1;else unset PICSHOT_SMOKE_GIF_RESOURCES;fi
  codesign --verify --deep --strict "$app"
  test "$(lipo -archs "$app/Contents/MacOS/PicShot")" = "$(uname -m)"
  mkdir -p "dist/evidence/$format"
  swift scripts/launch-smoke-app.swift "$app" "$PWD/dist/evidence/$format/launch.json"
  python3 - "$PWD/dist/evidence/$format/launch.json" "$app" "$(git rev-parse HEAD)" "$format" <<'PY'
import json,sys,pathlib
r=json.load(open(sys.argv[1]));assert r['status']=='passed',r
assert r['mainWindowVisible'] and r['safeMode'] and not r['captureStarted'],r
assert r['sourceCommit']==sys.argv[3],r
assert pathlib.Path(r['bundlePath']).resolve()==pathlib.Path(sys.argv[2]).resolve(),r
assert len(r['arguments'])==1,r
assert r['resourceCycleCount']==40 and r['baselineRSSBytes']>0,r
assert r['packagedModelEvidence']['formulaLaTeX'].replace(' ','')=='E=mc^{2}',r
assert r['packagedModelEvidence']['tableRows']==4 and r['packagedModelEvidence']['tableColumns']==3,r
assert r['finalRetainedAppControllersOrContent']==0,r
assert r['packagedModelEvidence']['formulaRender']['pngBytes']>0,r
assert r['packagedModelEvidence']['formulaRender']['pdfBytes']>0,r
assert r['pinSessionEvidence']['status']=='passed',r
assert r['packagedModelEvidence']['smartErase']['status']=='passed',r
assert r['packagedModelEvidence']['smartErase']['outsideMaskByteMismatches']==0,r
jobs=r['packagedModelEvidence']['processResources']
assert jobs.get('activeJob') is None and len(jobs['lastJobs'])==3,jobs
assert {j['kind'] for j in jobs['lastJobs']}=={'formula','table','smartErase'},jobs
for job in jobs['lastJobs']:
    assert job['outcome']=='succeeded' and job['childLaunched'] and job['childExitConfirmed'],job
    assert job['temporaryDirectoryCleanup']=='confirmed',job
    assert job.get('sampledPeakResidentBytes',0)>0 and job['residentSampleCount']>0,job
parity=r['interactionParityEvidence']
assert parity['status']=='passed' and parity['sourceCommit']==sys.argv[3],parity
assert not parity['screenCaptureStarted'] and not parity['permissionRequested'],parity
for key in ['annotationPaths','scrollSequence','pinTextSelection']:
    assert parity[key]['status']=='passed',parity[key]
batch=r['captureExportRecognitionEvidence']
assert batch['status']=='passed' and batch['sourceCommit']==sys.argv[3],batch
assert batch['settingsPresetRouteVerified'] and not batch['screenCaptureStarted'] and not batch['permissionRequested'] and not batch['externalURLVisited'],batch
for key in ['capturePresetsElements','imageExport','barcodes']:
    assert batch[key]['status']=='passed',batch[key]
layout=batch['capturePresetsElements']['fakeProvider']['elementButtonLayout']
assert len(layout)==3 and {item['identifier'] for item in layout}=={'capture.elements.toggle','capture.elements.parent','capture.elements.child'},layout
assert all(item['hitTargetVerified'] is True for item in layout),layout
for key in ['codecExportEvidence','recordingWebPEvidence']:
    codec=r[key]
    assert codec['status']=='passed' and codec['sourceCommit']==sys.argv[3],codec
    assert not codec['captureStarted'] and codec['temporaryDirectoryRemoved'],codec
assert not r['codecExportEvidence']['networkAttempted'],r['codecExportEvidence']
assert not r['recordingWebPEvidence']['externalDownloads'],r['recordingWebPEvidence']
composition=r['recordingCompositionEvidence']
assert composition['status']=='passed' and composition['temporaryDirectoryRemoved'],composition
assert composition['controllerCreationCount']==4 and composition['controllerReleaseCount']==4,composition
assert composition['pipelineReleaseCount']==4 and len(composition['cycles'])==3,composition
for cycle in composition['cycles']:
    assert cycle['decodedFrames']==7 and cycle['decodedPixelChecks']>=39,cycle
    assert cycle['writerRetainedFrameReferencesAtFinish']==0 and cycle['liveTrackedObjectsAfterRelease']==0,cycle
    assert cycle['postStopMutationExcluded'] and cycle['temporaryFilesRemaining']==0,cycle
for key in ['screenCaptureStarted','cameraCaptureStarted','microphoneStarted','permissionRequested']:
    assert composition[key] is False,composition
assert r['recordingTransport']==json.loads((pathlib.Path(sys.argv[1]).parent/'recording-transport.json').read_text()),r['recordingTransport']
derived=r['recordingInputExportEvidence']
assert derived['status']=='exported-awaiting-independent-validation' and derived['sourceCommit']==sys.argv[3],derived
assert derived==json.loads((pathlib.Path(sys.argv[1]).parent/'recording-input-export.json').read_text()),derived
inputs=r['recordingInputEvidence']
assert inputs['status']=='passed' and inputs['sourceCommit']==sys.argv[3],inputs
assert inputs['temporaryDirectoryRemoved'] and inputs['decodedFrames']==22,inputs
assert inputs['width']==320 and inputs['height']==180 and inputs['frameRate']==10,inputs
for key in ['captureStarted','permissionRequested','globalInputPosted']:
    assert inputs[key] is False,inputs
checks={'decodedClickPixels','decodedScrollDirection','decodedShortcutGlyphs','decodedExpiryClear',
        'decodedResumeClear','decodedStopFrozenTimeAndValues','cameraAndAnnotationsPreserved',
        'disabledSourceIdentity','boundedEventRetention','staleSessionRejected',
        'cancelledWriterReleased','exportWriterReleased','storedTimingAndPauseRemoval'}
assert set(inputs['functionalAssertions'])==checks,inputs
assert all(inputs['functionalAssertions'][key] is True for key in checks),inputs
for key in ['releasedExportObjects','releasedCancellationObjects']:
    assert set(inputs[key])=={'writer','compositor','state','inputEffects'},inputs
    assert all(value is False for value in inputs[key].values()),inputs
timing=inputs['storedPacketTiming']
assert timing['packets']==22 and timing['adjacent'] and timing['positiveDurations'],timing
assert abs(timing['endSeconds']-2.2)<0.001,timing
assert inputs['elapsedSeconds']<60 and inputs['cooperativeDeadlineSeconds']==60,inputs
ocr=r['pinOCRWorkflow']
assert ocr['status']=='passed' and ocr['sourceCommit']==sys.argv[3],ocr
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
resource=ocr['resourceEvidence']
assert ocr['includeResourceCycles'] and resource['status']=='passed' and resource['observationsComplete'],resource
assert resource['warmupCycles']==2 and resource['measuredCycles']==12 and resource['completedMeasuredCycles']==12,resource
assert resource['actualVisionCalls']==14 and ocr['actualResourceVisionCalls']==14,resource
assert len(resource['settledAfterCycles'])==12 and len(resource['residentLateThreeIntervalGrowthBytes'])==3,resource
assert resource['livePinsAndResultsAtBaselineAndEveryCycleEnd']==0 and resource['activeJobsAtBaselineAndEveryCycleEnd']==0,resource
for key,value in resource['releaseEvidence'].items():
    if key.startswith('retained'): assert value==0,(key,value)
gif=r['gifResourceEvidence']
if sys.argv[4]=='zip':
    assert gif['status']=='passed' and gif['profile']=='installed-30-second',gif
    assert gif['measuredExportCount']==4 and gif['expectedOutputFrames']==360,gif
    assert gif['highResolution']['status']=='passed' and gif['helperBoundaryRequired'],gif
    successful=gif['warmupExports']+gif['exports']+[gif['highResolution']['export']]
    for export in successful+[gif['cancellation']]:
        child=export['helperProcess']
        assert child['childLaunched'] and child['childExitConfirmed'] and child['temporaryDirectoryRemoved'],child
        assert child['childResidentSampleCount']>0 and child['childSampledPeakResidentBytes']>0,child
        assert child['childReportedResidentSampleCount']>0 and child['childReportedPeakResidentBytes']>0,child
        assert child['parentResidentSampleCount']>0 and child['parentSampledPeakResidentBytes']>0,child
    for export in successful:
        assert export['helperProcess']['outcome']=='succeeded' and export['helperProcess']['terminationStatus']==0,export
    assert gif['cancellation']['cancellationObserved'] and gif['cancellation']['helperProcess']['outcome']=='cancelled',gif
else:
    assert gif['status']=='not-run',gif
save=r['saveWorkflowEvidence']
assert save['status']=='passed' and save['quietAutomaticFinalizedAction'],save
assert not save['userPreferencesRead'] and not save['generalPasteboardReadOrWritten'],save
assert not save['liveScreenCaptured'] and not save['networkAttempted'],save
assert save['maximumSaveJobs']==2 and save['estimatedRetainedInputBudgetBytes']==256*1024*1024,save
assert len(save['resourceCycles'])==10 and sum(not x['warmup'] for x in save['resourceCycles'])==8,save
for c in save['resourceCycles']:
    assert c['activeJobs']==0 and c['retainedInputBytes']==0 and c['controllerReleased'] and c['temporaryJobRemoved'],c
print(json.dumps(r,indent=2))
PY
  python3 scripts/verify-recording-input-exports.py "$PWD/dist/evidence/$format" "$(git rev-parse HEAD)"
  python3 scripts/check-recording-transport-report.py "$PWD/dist/evidence/$format/recording-transport.json"
  python3 scripts/check-portable-settings.py "$PWD/dist/evidence/$format/portable-settings-ui.json" "$app" "$(git rev-parse HEAD)" "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
  python3 scripts/check-capture-output-report.py "$PWD/dist/evidence/$format/capture-output/capture-output-workflow.json" "$app" "$(git rev-parse HEAD)"
  python3 scripts/check-effect-output-failure-report.py "$PWD/dist/evidence/$format/capture-output/effect-output-failure.json" "$app" "$(git rev-parse HEAD)" "$PWD/dist/evidence/$format/launch.json.launcher.json"
  if [[ "$format" == zip ]];then
    bash scripts/multiwindow-resource-smoke.sh "$app" "$PWD/dist/evidence/$format/multiwindow-resources" "$(git rev-parse HEAD)"
  fi
  python3 scripts/check-pin-ocr-report.py "$PWD/dist/evidence/$format/pin-ocr/pin-ocr-workflow.json" "$app" "$(git rev-parse HEAD)" 0.19.1 "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" --full
  python3 scripts/check-automatic-mosaic-report.py "$PWD/dist/evidence/$format/automatic-mosaic/automatic-mosaic-workflow.json" "$app" "$(git rev-parse HEAD)" "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" --full
  python3 scripts/check-annotation-details-report.py "$PWD/dist/evidence/$format/annotation-details/annotation-details.json" "$app" "$(git rev-parse HEAD)" "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" --full
  bash scripts/pin-workflows-smoke.sh "$app" "$PWD/dist/evidence/$format/pin-workflows" "$(git rev-parse HEAD)"
  bash scripts/manual-scroll-smoke.sh "$app" "$PWD/dist/evidence/$format/manual-scroll" "$(git rev-parse HEAD)" "$format"
  if [[ "$format" == zip ]];then
    bash scripts/editable-annotation-smoke.sh "$app" "$PWD/dist/evidence/$format/editable-annotations" "$(git rev-parse HEAD)" resources
  else
    bash scripts/editable-annotation-smoke.sh "$app" "$PWD/dist/evidence/$format/editable-annotations" "$(git rev-parse HEAD)" functional
  fi
done
# Preserve both complete installer smoke paths before the independent default
# product gate. Four 620s application wrappers + 120s compilation + 300s decode
# retain the existing 300s native / 600s launcher limits within a 3300s bound.
python3 scripts/run-bounded-command.py --timeout-seconds 3300 \
  --log "$PWD/dist/editable-product-installed-default.log" \
  --report "$PWD/dist/editable-product-installed-default-report.json" \
  -- bash scripts/editable-product-installed-default.sh "$work/zip/PicShot.app" \
  "$PWD/dist/evidence/zip/editable-product-installed-default" "$(git rev-parse HEAD)"
