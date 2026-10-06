#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
ditto -x -k "dist/PicShot-0.9.0-macos-$(uname -m).zip" "$work"
app="$work/PicShot.app"
codesign --verify --deep --strict "$app"
unset PICSHOT_UI_PREVIEW_ONLY PICSHOT_SMOKE_GIF_RESOURCES PICSHOT_GIF_DIAGNOSTIC_MODE PICSHOT_CODEC_ATTRIBUTION_MODE
unset PICSHOT_SMOKE_FORMULA_MODEL_DIR PICSHOT_SMOKE_TABLE_MODEL_DIR PICSHOT_SMOKE_ERASE_MODEL_DIR
unset PICSHOT_IMAGE_BACKING_FORMAT PICSHOT_IMAGE_BACKING_INPUT_DIRECTORY
export PICSHOT_IMAGE_BACKING_PROFILE=installed-768x576
export PICSHOT_IMAGE_BACKING_MODE=prepare-inputs
root="$PWD/dist/evidence/image-backing"
input="$root/prepared"
mkdir -p "$input"
swift scripts/launch-smoke-app.swift "$app" "$input/launch.json"
python3 - "$input/launch.json" "$(git rev-parse HEAD)" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]));assert r['status']=='prepared' and r['sourceCommit']==sys.argv[2],r
assert r['matrixTier']=='input-preparation' and r['syntheticSource'] and not r['captureStarted'] and not r['networkAttempted'],r
assert {x['format'] for x in r['inputs']}=={'png','jpg','bmp','pdf','webp','avif'},r
PY
run_cell() {
  local mode="$1" format="$2" tier="$3"
  export PICSHOT_IMAGE_BACKING_MODE="$mode"
  unset PICSHOT_IMAGE_BACKING_FORMAT PICSHOT_IMAGE_BACKING_INPUT_DIRECTORY
  if [[ "$format" != common ]]; then export PICSHOT_IMAGE_BACKING_FORMAT="$format"; fi
  if [[ "$mode" == preview-only || "$mode" == independent-decode-only ]]; then export PICSHOT_IMAGE_BACKING_INPUT_DIRECTORY="$input"; fi
  local report="$root/$format/$mode/launch.json"
  mkdir -p "$(dirname "$report")"
  swift scripts/launch-smoke-app.swift "$app" "$report"
  python3 - "$report" "$(git rev-parse HEAD)" "$app" "$mode" "$format" "$tier" "$input" <<'PY'
import json,pathlib,sys
r=json.load(open(sys.argv[1]));assert r['status']=='observed',r
assert r['sourceCommit']==sys.argv[2] and pathlib.Path(r['bundlePath']).resolve()==pathlib.Path(sys.argv[3]).resolve(),r
assert (r['mode'],r['format'],r['matrixTier'])==tuple(sys.argv[4:7]),r
assert r['diagnosticOnly'] and not r['captureStarted'] and not r['networkAttempted'],r
assert r['profile']=='installed-768x576' and r['warmupCycles']==2 and r['measuredCycles']==12,r
assert r['oneRGBAStorageBytes']==768*576*4 and len(r['warmups'])==2 and len(r['cycles'])==12,r
assert r['completedWorkloadInvocations']==14 and r['helperInvocations']==0,r
assert r['ownedTemporaryMediaFiles']==0 and r['activeControllersAfterAllCycles']==0 and r['queuedOrRunningJobsAfterAllCycles']==0,r
if r['mode'] in ['preview-only','independent-decode-only']:
    manifest=json.load(open(pathlib.Path(sys.argv[7])/'image-backing-inputs.json'))
    entry=next(x for x in manifest['inputs'] if x['format']==r['format'])
    assert r['immutableInputUnchanged'] and r['immutableInputSHA256']==entry['sha256'],r
    assert r['persistentSyntheticSourceCount']==0 and r['persistentSnapshotCount']==0 and r['persistentEncodedInputCount']==1,r
for c in r['warmups']+r['cycles']:
    assert c['fixtureScopeExited'] and c['workload']['operations']==r['expectedPerCycleOperations'],c
    assert c['workload']['width']==768 and c['workload']['height']==576,c
    for name in ['before','afterAutoreleasePool','settled']:
        m=c[name];assert m['standard']['kernelReturn']==0 and m['standard']['bytes']['resident_size']>0 and m['standard']['bytes']['phys_footprint']>0,m
        assert not any(k.startswith('purgeable_volatile_') for k in m['standard']['bytes']),m
        # Optional purgeable observations remain raw success/failure; never turn
        # missing data or an RSS difference into a purgeability/leak conclusion.
        assert 'kernelReturn' in m['purgeable'],m
for key in ['residentTrend','physicalFootprintTrend']:
    assert r[key]['observationsComplete'] and len(r[key]['intervalGrowthBytes'])==12 and len(r[key]['lastThreeIntervalGrowthBytes'])==3,r[key]
print(json.dumps({k:r[k] for k in ['sourceCommit','mode','format','matrixTier','warmupCycles','measuredCycles','residentTrend','physicalFootprintTrend','elapsedSeconds']},indent=2))
PY
}
# Narrow common controls first, then the independently requested native formats.
run_cell source-create common focused-control
run_cell snapshot-only common focused-control
run_cell raster-digest-only common focused-control
run_cell preview-only webp focused-control
run_cell independent-decode-only webp focused-control
run_cell native-export png focused-control
run_cell preview-only png focused-control
run_cell independent-decode-only png expanded-format-comparison
for format in jpg bmp pdf; do
  for mode in native-export preview-only independent-decode-only; do run_cell "$mode" "$format" expanded-format-comparison; done
done
run_cell preview-only avif expanded-format-comparison
run_cell independent-decode-only avif expanded-format-comparison
python3 - "$root" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]);reports=[json.loads(p.read_text()) for p in root.glob('*/*/launch.json')]
assert len(reports)==19 and sum(r['matrixTier']=='focused-control' for r in reports)==7
pids=[r['processIdentifier'] for r in reports]+[json.loads((root/'prepared/launch.json').read_text())['processIdentifier']]
assert len(set(pids))==20,'Preparation and every cell need a fresh process'
print('19 source, snapshot, raster, encoder and reader controls completed; raw memory accounting is not a no-leak verdict')
PY
