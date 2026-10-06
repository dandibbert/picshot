#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
ditto -x -k "dist/PicShot-0.7.0-macos-$(uname -m).zip" "$work"
app="$work/PicShot.app"
codesign --verify --deep --strict "$app"
unset PICSHOT_UI_PREVIEW_ONLY PICSHOT_SMOKE_GIF_RESOURCES
extraction=async-baseline
export PICSHOT_GIF_EXTRACTION="$extraction"
for execution in in-process-baseline isolated-helper; do
  export PICSHOT_GIF_EXECUTION="$execution"
  for mode in export-only decode-only; do
  export PICSHOT_GIF_DIAGNOSTIC_MODE="$mode"
  report="$PWD/dist/evidence/gif-attribution/$execution/$mode/launch.json"
  mkdir -p "$(dirname "$report")"
  swift scripts/launch-smoke-app.swift "$app" "$report"
  python3 - "$report" "$app" "$(git rev-parse HEAD)" "$mode" "$extraction" "$execution" <<'PY'
import json,pathlib,sys
r=json.load(open(sys.argv[1])); assert r['status']=='completed',r
assert r['diagnosticOnly'] and not r['captureStarted'] and not r['audioStarted'],r
assert not r['externalDownloads'] and r['temporaryDirectoryRemoved'],r
assert r['sourceCommit']==sys.argv[3] and r['mode']==sys.argv[4],r
assert r['frameExtraction']==sys.argv[5] and r['execution']==sys.argv[6],r
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
if r['execution']=='isolated-helper':
    exports=([r['exportWarmup']]+r['cycles']) if r['mode']=='export-only' else [r['inputPreparationExport']]
    for export in exports:
        child=export['helperProcess']
        assert child['outcome']=='succeeded' and child['childLaunched'] and child['childExitConfirmed'],child
        assert child['temporaryDirectoryRemoved'] and child['terminationStatus']==0,child
        assert child['childResidentSampleCount']>0 and child['childSampledPeakResidentBytes']>0,child
        assert child['childReportedResidentSampleCount']>0 and child['childReportedPeakResidentBytes']>0,child
        assert child['parentResidentSampleCount']>0 and child['parentSampledPeakResidentBytes']>0,child
print(json.dumps(r,indent=2))
PY
done
done
