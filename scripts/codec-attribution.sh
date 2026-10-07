#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
ditto -x -k "dist/PicShot-0.14.0-macos-$(uname -m).zip" "$work"
app="$work/PicShot.app"
codesign --verify --deep --strict "$app"
unset PICSHOT_UI_PREVIEW_ONLY PICSHOT_SMOKE_GIF_RESOURCES PICSHOT_GIF_DIAGNOSTIC_MODE PICSHOT_CODEC_ATTRIBUTION_INPUT_DIRECTORY PICSHOT_CODEC_ATTRIBUTION_FORMAT
unset PICSHOT_SMOKE_FORMULA_MODEL_DIR PICSHOT_SMOKE_TABLE_MODEL_DIR PICSHOT_SMOKE_ERASE_MODEL_DIR
export PICSHOT_CODEC_ATTRIBUTION_PROFILE=installed-768x576
export PICSHOT_CODEC_ATTRIBUTION_MODE=prepare-inputs
input="$PWD/dist/evidence/codec-attribution/prepared"
mkdir -p "$input"
swift scripts/launch-smoke-app.swift "$app" "$input/launch.json"
python3 - "$input/launch.json" "$(git rev-parse HEAD)" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]));assert r['status']=='prepared' and r['sourceCommit']==sys.argv[2],r
assert not r['captureStarted'] and not r['networkAttempted'] and len(r['inputs'])==2,r
PY
for format in webp avif; do
  export PICSHOT_CODEC_ATTRIBUTION_FORMAT="$format"
  for mode in export-only decode-only combined; do
    export PICSHOT_CODEC_ATTRIBUTION_MODE="$mode"
    unset PICSHOT_CODEC_ATTRIBUTION_INPUT_DIRECTORY
    if [[ "$mode" == decode-only ]]; then export PICSHOT_CODEC_ATTRIBUTION_INPUT_DIRECTORY="$input"; fi
    report="$PWD/dist/evidence/codec-attribution/$format/$mode/launch.json"
    mkdir -p "$(dirname "$report")"
    swift scripts/launch-smoke-app.swift "$app" "$report"
    python3 - "$report" "$(git rev-parse HEAD)" "$app" "$mode" "$format" "$input" <<'PY'
import json,pathlib,sys
r=json.load(open(sys.argv[1]));assert r['status']=='observed',r
prepared=json.load(open(pathlib.Path(sys.argv[6])/'codec-attribution-inputs.json'))
entry=next(x for x in prepared['inputs'] if x['format']==r['format'])
assert r['sourceCommit']==sys.argv[2] and pathlib.Path(r['bundlePath']).resolve()==pathlib.Path(sys.argv[3]).resolve(),r
assert r['mode']==sys.argv[4] and r['format']==sys.argv[5],r
assert r['diagnosticOnly'] and not r['captureStarted'] and not r['networkAttempted'] and not r['mockedCodec'],r
assert r['profile']=='installed-768x576' and r['warmupCycles']==2 and r['measuredCycles']==12,r
assert len(r['warmups'])==2 and len(r['cycles'])==12,r
assert r['temporaryDirectoryRemoved'] and r['fixtureEncodingTasksActive']==0,r
assert r['activeControllersAfterAllCycles']==0 and r['queuedOrRunningJobsAfterAllCycles']==0,r
assert r['totalExports']==(0 if r['mode']=='decode-only' else 14),r
assert r['totalIndependentDecodes']==(0 if r['mode']=='export-only' else 14),r
if r['mode']=='decode-only':assert r['immutableInputUnchanged'] and len(r['immutableInputSHA256'])==64,r
for c in r['warmups']+r['cycles']:
    assert c['sourceSHA256']==entry['sourceSHA256'] and len(c['encodedSHA256'])==64,c
    if r['mode']=='decode-only':assert c['encodedSHA256']==entry['sha256'],c
    assert c['payloadReleased'] and not c['helperActive'] and c['ownedTemporaryFiles']==0,c
    assert c['activeControllers']==0 and c['queuedOrRunningJobs']==0 and c['fixtureEncodingTasksActive']==0,c
    if r['mode']!='decode-only':
        h=c['helper'];assert h['outcome']=='succeeded' and h['childExitConfirmed'] and h['temporaryDirectoryRemoved'],h
        assert c['sameByteSave'],c
    if r['mode']!='export-only':assert c['independentDecode']['allPixelsAndAlphaCompared'],c
for key in ['residentTrend','physicalFootprintTrend']:
    assert r[key]['observationsComplete'] and len(r[key]['intervalGrowthBytes'])==12 and len(r[key]['lastThreeIntervalGrowthBytes'])==3,r[key]
print(json.dumps({k:r[k] for k in ['sourceCommit','mode','format','warmupCycles','measuredCycles','residentTrend','physicalFootprintTrend','elapsedSeconds']},indent=2))
PY
  done
done
python3 - "$PWD/dist/evidence/codec-attribution" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]);reports=[json.loads(p.read_text()) for p in root.glob('*/*/launch.json')]
assert len(reports)==6
pids=[r['processIdentifier'] for r in reports];prepared=json.loads((root/'prepared/launch.json').read_text())['processIdentifier']
assert len(set(pids+[prepared]))==7,'Each workload requires a fresh process'
print('Six separately launched workloads completed; memory values are observations, not a no-leak verdict')
PY
