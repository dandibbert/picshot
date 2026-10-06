#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
ditto -x -k "dist/PicShot-0.4.0-macos-$(uname -m).zip" "$work"
app="$work/PicShot.app"
codesign --verify --deep --strict "$app"
unset PICSHOT_UI_PREVIEW_ONLY PICSHOT_SMOKE_GIF_RESOURCES
for extraction in async-baseline scoped-sync-candidate; do
  export PICSHOT_GIF_EXTRACTION="$extraction"
  for mode in export-only decode-only; do
  export PICSHOT_GIF_DIAGNOSTIC_MODE="$mode"
  report="$PWD/dist/evidence/gif-attribution/$extraction/$mode/launch.json"
  mkdir -p "$(dirname "$report")"
  swift scripts/launch-smoke-app.swift "$app" "$report"
  python3 - "$report" "$app" "$(git rev-parse HEAD)" "$mode" "$extraction" <<'PY'
import json,pathlib,sys
r=json.load(open(sys.argv[1])); assert r['status']=='completed',r
assert r['diagnosticOnly'] and not r['captureStarted'] and not r['audioStarted'],r
assert not r['externalDownloads'] and r['temporaryDirectoryRemoved'],r
assert r['sourceCommit']==sys.argv[3] and r['mode']==sys.argv[4],r
assert r['frameExtraction']==sys.argv[5],r
assert pathlib.Path(r['bundlePath']).resolve()==pathlib.Path(sys.argv[2]).resolve(),r
assert r['measuredCycles']==8 and len(r['cycles'])==8,r
assert r['profile']=='installed-30-second',r
assert r['sourceFrames']==360 and r['outputMaximumDimension']==480,r
if r['mode']=='export-only':
    assert r['totalExportInvocations']==9 and r['totalGIFValidationInvocations']==1,r
    assert r['decoderInvocationsBeforeMeasuredExports']==0,r
    assert r['decoderInvocationsDuringMeasuredExports']==0 and r['decoderInvocationsAfterMeasuredExports']==1,r
else:
    assert r['totalExportInvocations']==1 and r['totalGIFValidationInvocations']==9,r
    assert r['exportsDuringMeasuredDecodeCycles']==0,r
print(json.dumps(r,indent=2))
PY
done
done
