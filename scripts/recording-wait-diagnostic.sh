#!/bin/bash
# One recording-only diagnostic, unchanged installed work and deadlines.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -eq 3 ]] || exit 64
app="$1"; root="$2"; expected="$3"
[[ "$app" == /* && "$root" == /* && ! -e "$root" && "$expected" =~ ^[0-9a-f]{40}$ ]] || exit 64
codesign --verify --deep --strict "$app"
test "$(lipo -archs "$app/Contents/MacOS/PicShot")" = "$(uname -m)"
mkdir -p "$(dirname "$root")"
mkdir "$root"
python3 - "$app" "$expected" "$root/provenance.json" <<'PY'
import hashlib,json,pathlib,plistlib,sys
app=pathlib.Path(sys.argv[1]); info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info['PicShotSourceCommit']==sys.argv[2]
exe=app/'Contents/MacOS/PicShot'
pathlib.Path(sys.argv[3]).write_text(json.dumps(dict(sourceCommit=sys.argv[2],bundlePath=str(app.resolve()),executableSHA256=hashlib.sha256(exe.read_bytes()).hexdigest(),executableBytes=exe.stat().st_size,diagnosticOnly=True,scope='one fresh recording-only installed-profile launch; no broad-smoke or installer acceptance'),indent=2))
PY
launch_status=0
(
  export PICSHOT_RECORDING_COMPOSITION_ONLY=1
  swift scripts/launch-smoke-app.swift "$app" "$root/launch.json"
) > "$root/launcher.log" 2>&1 || launch_status=$?
python3 - "$root" "$app" "$expected" "$launch_status" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]); result={'diagnosticOnly':True,'sourceCommit':sys.argv[3],'status':'failed'}
try:
  launcher=json.loads((root/'launch.json.launcher.json').read_text())
  assert launcher['ownedExitConfirmed'] is True,launcher
  assert launcher['status']=='exited' and int(sys.argv[4])==0,launcher
  assert pathlib.Path(launcher['launchedAppPath']).resolve()==pathlib.Path(sys.argv[2]).resolve(),launcher
  report=json.loads((root/'recording-composition.json').read_text())
  trace=json.loads((root/'recording-composition-trace.json').read_text())
  result.update(fixtureStatus=report['status'],phase=report.get('phase'),elapsedSeconds=report.get('elapsedSeconds'),firstFailure=trace.get('firstFailure'),traceEventCount=len(trace['events']),traceDroppedEvents=trace['droppedEvents'],ownedExitConfirmed=True)
  assert trace['sourceCommit']==sys.argv[3] and report['sourceCommit']==sys.argv[3]
  assert trace.get('lastWriteError') is None,trace
  assert (root/'recording-composition-trace.json').stat().st_size<=128*1024
  assert report['status']=='passed',result
  assert report['profile']=='installed-recording-composition' and report['completedMeasuredCycles']==3,report
  assert report['temporaryDirectoryRemoved'] is True,report
  assert len(report['cycles'])==3 and report['controllerReleaseCount']==4 and report['pipelineReleaseCount']==4
  for cycle in [report['warmup']]+report['cycles']:
    assert cycle['decodedFrames']==7 and cycle['decodedPixelChecks']>=39,cycle
    assert cycle['writerRetainedFrameReferencesAtFinish']==0 and cycle['liveTrackedObjectsAfterRelease']==0,cycle
    assert cycle['temporaryFilesRemaining']==0 and cycle['postStopMutationExcluded'],cycle
  assert trace.get('firstFailure') is None,trace
  for key in ['screenCaptureStarted','cameraCaptureStarted','microphoneStarted','permissionRequested']:
    assert report[key] is False,report
  result['status']='passed'
except Exception as error:
  result['error']=str(error)[:4096]
finally:
  (root/'checked.json').write_text(json.dumps(result,indent=2)+'\n')
  print(json.dumps(result,indent=2))
sys.exit(0 if result['status']=='passed' else 1)
PY
