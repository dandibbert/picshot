#!/bin/bash
# One fresh installed process; complete observations are not a leak-free verdict.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -eq 3 || $# -eq 4 ]] || exit 64
app="$1"; root="$2"; expected="$3"; mode=normalizedCandidate; selection=productionDefault
if [[ $# -eq 4 ]];then
  mode="$4"; selection=diagnosticOverride
fi
[[ "$mode" == coreGraphicsBaseline || "$mode" == normalizedCandidate ]] || exit 64
[[ "$app" == /* && "$root" == /* && ! -e "$root" && "$expected" =~ ^[0-9a-f]{40}$ ]] || exit 64
codesign --verify --deep --strict "$app"
mkdir -p "$(dirname "$root")"
mkdir "$root"
python3 - "$app" "$expected" "$root/provenance.json" <<'PY'
def require(condition, message):
  if not condition: raise ValueError(message)
import hashlib,json,pathlib,plistlib,sys
app=pathlib.Path(sys.argv[1]); info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
require(info['PicShotSourceCommit'] == sys.argv[2], 'Resource evidence check failed')
exe=app/'Contents/MacOS/PicShot'
pathlib.Path(sys.argv[3]).write_text(json.dumps(dict(sourceCommit=sys.argv[2],version=info['CFBundleShortVersionString'],buildVersion=info['CFBundleVersion'],bundlePath=str(app.resolve()),executableSHA256=hashlib.sha256(exe.read_bytes()).hexdigest(),executableBytes=exe.stat().st_size),indent=2))
PY
launch_status=0
(
  export PICSHOT_MULTIWINDOW_RESOURCES_ONLY=1
  if [[ "$selection" == productionDefault ]];then
    # An inherited diagnostic environment must not masquerade as installed defaults.
    unset PICSHOT_MULTIWINDOW_COMPOSITION PICSHOT_MULTIWINDOW_DIAGNOSTIC_TAIL_FIRST PICSHOT_MULTIWINDOW_DIAGNOSTIC_BOUNDARIES
  else
    export PICSHOT_MULTIWINDOW_COMPOSITION="$mode"
  fi
  swift scripts/launch-smoke-app.swift "$app" "$root/launch.json"
) > "$root/launcher.log" 2>&1 || launch_status=$?
python3 - "$root" "$app" "$expected" "$launch_status" "$mode" "$selection" <<'PY'
def require(condition, message):
  if not condition: raise ValueError(message)
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]); result={'status':'failed','memoryStabilityAssessed':False,'sourceCommit':sys.argv[3]}
try:
  launcher=json.loads((root/'launch.json.launcher.json').read_text())
  require(int(sys.argv[4]) == 0 and launcher['status'] == 'exited' and (launcher['ownedExitConfirmed'] is True), launcher)
  require(pathlib.Path(launcher['launchedAppPath']).resolve() == pathlib.Path(sys.argv[2]).resolve(), 'Resource evidence check failed')
  launch=json.loads((root/'launch.json').read_text())
  r=json.loads((root/'multi-window-resource.json').read_text())
  require(launch['sourceCommit'] == sys.argv[3] and len(launch['arguments']) == 1, launch)
  require(pathlib.Path(launch['bundlePath']).resolve() == pathlib.Path(sys.argv[2]).resolve(), 'Resource evidence check failed')
  require(r['compositionMode'] == sys.argv[5], r)
  require(r['productionCompositionMode'] == 'normalizedCandidate', r)
  require(r['compositionModeSource'] == sys.argv[6], r)
  if sys.argv[6]=='productionDefault':
    require(r['diagnosticCompositionOverride'] is None, r)
    require(r['compositionMode'] == r['productionCompositionMode'], r)
    require(r['diagnosticTailStripFirst'] is False and r['diagnosticBoundariesEnabled'] is False, r)
  else:
    require(sys.argv[6] == 'diagnosticOverride' and r['diagnosticCompositionOverride'] == sys.argv[5], r)
  require(r['candidateImplementation'] == 'vimage-canonical-cgimage-quartz-strips-v1', r)
  require(r['normalizationRasterBytes'] == (3840 * 2160 * 4 if sys.argv[5] != 'coreGraphicsBaseline' else 0), r)
  require(r['status'] == 'observed' and r['observationsComplete'] is True, r)
  require(r['completedWarmupCycles'] == 4 and r['completedMeasuredCycles'] == 12, 'Resource evidence check failed')
  require(r['remainingWarmupCycles'] == 0 and r['remainingMeasuredCycles'] == 0, 'Resource evidence check failed')
  require((r['sourceWidth'], r['sourceHeight'], r['outputWidth'], r['outputHeight']) == (3840, 2160, 4480, 2520), 'Resource evidence check failed')
  require(len(r['warmups']) == 4 and len(r['cycles']) == 12, 'Resource evidence check failed')
  for cycle in r['warmups']+r['cycles']:
    require(cycle['rgbaSHA256'] == r['expectedOutputSHA256'] and cycle['exactOutputPixels'] == 4480 * 2520, cycle)
    require(cycle['ownedOpenFileDescriptorsAfter'] == 0, cycle)
    raster=cycle['ownedRasterProbe']
    require(raster['currentRasterBytes'] == 0 and raster['peakRasterBytes'] <= 192000000, raster)
    require(raster['normalizationCount'] == (2 if sys.argv[5] != 'coreGraphicsBaseline' else 0), raster)
    require(raster['liveCanonicalImages'] == 0, raster)
    require(raster['canonicalImagesCreated'] == (2 if sys.argv[5] == 'normalizedCandidate' else 0), raster)
    owned=cycle['ownership']
    require(owned['inputObjectsCreated'] == 2 and owned['decoderObjectsCreated'] == 2 and (owned['outputObjectsCreated'] == 1), owned)
    require(owned['maximumConcurrentInputObjects'] == 1, owned)
    require(owned['liveInputObjects'] == owned['liveDecoderObjects'] == owned['liveOutputObjects'] == 0, owned)
  require(r['temporaryDirectoryRemoved'] and r['ownedOpenFileDescriptorsAfterCleanup'] == 0, 'Resource evidence check failed')
  require(r['cancellation']['status'] == 'passed', 'Resource evidence check failed')
  for key in ['screenCaptureStarted','permissionRequested','systemScreenshotCommandInvoked','userAssetsRead','globalInputPosted','memoryPressureOrPurgeRequested','zeroLeakClaim','plateauAssessed','memoryStabilityAssessed']:
    require(r[key] is False, key)
  sampled=r['transientSampler']['total']; require(sampled['timerSampleCount']>0 and not sampled['missingFieldCounts'],sampled)
  before=r['afterWarmupBaseline']['counters']; after=r['finalAfterCleanup']['counters']
  delta={key:after[key]-before[key] for key in before.keys() & after.keys()}
  result.update(status='observed',compositionMode=r['compositionMode'],productionCompositionMode=r['productionCompositionMode'],compositionModeSource=r['compositionModeSource'],diagnosticCompositionOverride=r['diagnosticCompositionOverride'],observationsComplete=True,measuredCycles=12,elapsedSeconds=r['elapsedSeconds'],afterWarmupToCleanupDeltaBytes=delta,lateMeasuredIncrements=r['lateMeasuredIncrements'],sampledPeakBytes=sampled['sampledPeakBytes'],ownedExitConfirmed=True)
except Exception as error:
  result['error']=str(error)[:4096]
finally:
  (root/'checked-resource.json').write_text(json.dumps(result,indent=2)+'\n')
  print(json.dumps(result,indent=2))
sys.exit(0 if result['status']=='observed' else 1)
PY
