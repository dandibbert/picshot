#!/bin/bash
# One fresh installed process; complete observations are not a leak-free verdict.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -eq 3 || $# -eq 4 ]] || exit 64
app="$1"; root="$2"; expected="$3"; mode="${4:-coreGraphicsBaseline}"
[[ "$mode" == coreGraphicsBaseline || "$mode" == normalizedCandidate ]] || exit 64
[[ "$app" == /* && "$root" == /* && ! -e "$root" && "$expected" =~ ^[0-9a-f]{40}$ ]] || exit 64
codesign --verify --deep --strict "$app"
mkdir -p "$(dirname "$root")"
mkdir "$root"
python3 - "$app" "$expected" "$root/provenance.json" <<'PY'
import hashlib,json,pathlib,plistlib,sys
app=pathlib.Path(sys.argv[1]); info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info['PicShotSourceCommit']==sys.argv[2]
exe=app/'Contents/MacOS/PicShot'
pathlib.Path(sys.argv[3]).write_text(json.dumps(dict(sourceCommit=sys.argv[2],version=info['CFBundleShortVersionString'],buildVersion=info['CFBundleVersion'],bundlePath=str(app.resolve()),executableSHA256=hashlib.sha256(exe.read_bytes()).hexdigest(),executableBytes=exe.stat().st_size),indent=2))
PY
launch_status=0
(
  export PICSHOT_MULTIWINDOW_RESOURCES_ONLY=1
  export PICSHOT_MULTIWINDOW_COMPOSITION="$mode"
  swift scripts/launch-smoke-app.swift "$app" "$root/launch.json"
) > "$root/launcher.log" 2>&1 || launch_status=$?
python3 - "$root" "$app" "$expected" "$launch_status" "$mode" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]); result={'status':'failed','memoryStabilityAssessed':False,'sourceCommit':sys.argv[3]}
try:
  launcher=json.loads((root/'launch.json.launcher.json').read_text())
  assert int(sys.argv[4])==0 and launcher['status']=='exited' and launcher['ownedExitConfirmed'] is True,launcher
  assert pathlib.Path(launcher['launchedAppPath']).resolve()==pathlib.Path(sys.argv[2]).resolve()
  launch=json.loads((root/'launch.json').read_text())
  r=json.loads((root/'multi-window-resource.json').read_text())
  assert launch['sourceCommit']==sys.argv[3] and len(launch['arguments'])==1,launch
  assert pathlib.Path(launch['bundlePath']).resolve()==pathlib.Path(sys.argv[2]).resolve()
  assert r['compositionMode']==sys.argv[5],r
  assert r['productionCompositionMode']=='coreGraphicsBaseline',r
  assert r['normalizationRasterBytes']==(3840*2160*4 if sys.argv[5]=='normalizedCandidate' else 0),r
  assert r['status']=='observed' and r['observationsComplete'] is True,r
  assert r['completedWarmupCycles']==4 and r['completedMeasuredCycles']==12
  assert r['remainingWarmupCycles']==0 and r['remainingMeasuredCycles']==0
  assert (r['sourceWidth'],r['sourceHeight'],r['outputWidth'],r['outputHeight'])==(3840,2160,4480,2520)
  assert len(r['warmups'])==4 and len(r['cycles'])==12
  for cycle in r['warmups']+r['cycles']:
    assert cycle['rgbaSHA256']==r['expectedOutputSHA256'] and cycle['exactOutputPixels']==4480*2520,cycle
    assert cycle['ownedOpenFileDescriptorsAfter']==0,cycle
    raster=cycle['ownedRasterProbe']
    assert raster['currentRasterBytes']==0 and raster['peakRasterBytes']<=192_000_000,raster
    assert raster['normalizationCount']==(2 if sys.argv[5]=='normalizedCandidate' else 0),raster
    owned=cycle['ownership']
    assert owned['inputObjectsCreated']==2 and owned['decoderObjectsCreated']==2 and owned['outputObjectsCreated']==1,owned
    assert owned['maximumConcurrentInputObjects']==1,owned
    assert owned['liveInputObjects']==owned['liveDecoderObjects']==owned['liveOutputObjects']==0,owned
  assert r['temporaryDirectoryRemoved'] and r['ownedOpenFileDescriptorsAfterCleanup']==0
  assert r['cancellation']['status']=='passed'
  for key in ['screenCaptureStarted','permissionRequested','systemScreenshotCommandInvoked','userAssetsRead','globalInputPosted','memoryPressureOrPurgeRequested','zeroLeakClaim','plateauAssessed','memoryStabilityAssessed']:
    assert r[key] is False,key
  sampled=r['transientSampler']['total']; assert sampled['timerSampleCount']>0 and not sampled['missingFieldCounts'],sampled
  before=r['afterWarmupBaseline']['counters']; after=r['finalAfterCleanup']['counters']
  delta={key:after[key]-before[key] for key in before.keys() & after.keys()}
  result.update(status='observed',compositionMode=sys.argv[5],observationsComplete=True,measuredCycles=12,elapsedSeconds=r['elapsedSeconds'],afterWarmupToCleanupDeltaBytes=delta,lateMeasuredIncrements=r['lateMeasuredIncrements'],sampledPeakBytes=sampled['sampledPeakBytes'],ownedExitConfirmed=True)
except Exception as error:
  result['error']=str(error)[:4096]
finally:
  (root/'checked-resource.json').write_text(json.dumps(result,indent=2)+'\n')
  print(json.dumps(result,indent=2))
sys.exit(0 if result['status']=='observed' else 1)
PY
