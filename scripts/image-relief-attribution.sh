#!/bin/bash
# Deliberately opt-in. Never called by packaging or the default 0.9 workflow.
set -euo pipefail
if [[ $# -ne 3 || "$1" != --compare ]]; then
  echo 'Usage: image-relief-attribution.sh --compare /absolute/PicShot.app /absolute/new-evidence-directory' >&2
  exit 64
fi
cd "$(dirname "$0")/.."
app="$2"
root="$3"
[[ "$app" == /* && "$root" == /* && "$app" == *.app && ! -e "$root" ]] || { echo 'Use an absolute app path and a new absolute evidence directory' >&2; exit 64; }
[[ "$(uname -s)" == Darwin ]] || { echo 'This diagnostic requires native macOS' >&2; exit 69; }
architecture=$(uname -m)
[[ "$architecture" == arm64 || "$architecture" == x86_64 ]] || exit 69
binary="$app/Contents/MacOS/PicShot"
/usr/bin/codesign --verify --deep --strict "$app"
/usr/bin/lipo "$binary" -verify_arch "$architecture"
source_commit=$(/usr/libexec/PlistBuddy -c 'Print :PicShotSourceCommit' "$app/Contents/Info.plist")
[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || { echo 'App must record its full build source commit' >&2; exit 65; }
# Fail closed for an older app that does not contain this opt-in protocol.
python3 - "$binary" <<'PY'
import sys
needle=b'image-allocator-relief-v1'
with open(sys.argv[1],'rb') as f:
    tail=b''
    while True:
        block=f.read(1024*1024)
        if not block: raise SystemExit('App lacks the opt-in relief protocol; build the separate diagnostic patch first')
        if needle in tail+block: break
        tail=block[-len(needle):]
PY
# Preserve exclusive creation of the new leaf while allowing a new parent path.
mkdir -p "$(dirname "$root")"
mkdir "$root"
api_check="$root/api-availability-check.swift"
cat > "$api_check" <<'SWIFT'
import Darwin
// Typechecked only; no top-level invocation and no allocator operation.
// Apple's malloc/malloc.h declares availability from macOS 10.7.
func importedAllocatorReliefSignatureOnly() {
    let reportedBytes = malloc_zone_pressure_relief(nil, 32 * 1_024 * 1_024)
    _ = reportedBytes
}
SWIFT
# Check the real native SDK/Swift import for the app's minimum deployment target.
xcrun swiftc -target "$architecture-apple-macos14.0" -typecheck "$api_check" > "$root/api-typecheck.log" 2>&1
printf 'Swift/Darwin import typecheck passed; no relief API was invoked\n' >> "$root/api-typecheck.log"
echo 'Opt-in comparison: one app-local 32 MiB-goal call, with a separate zero-call wait control'
swift scripts/launch-image-relief.swift "$app" prepare-inputs "$root/prepared"
swift scripts/launch-image-relief.swift "$app" wait-control "$root/wait-control" "$root/prepared"
swift scripts/launch-image-relief.swift "$app" allocator-relief "$root/allocator-relief" "$root/prepared"
python3 - "$root" "$source_commit" "$architecture" <<'PY'
import json,math,pathlib,sys
root=pathlib.Path(sys.argv[1]);source,architecture=sys.argv[2:]
def read(path):
    data=path.read_bytes();assert len(data)<=1024*1024
    return json.loads(data)
prepared=read(root/'prepared/image-relief-input.json')
assert prepared['protocol']=='image-allocator-relief-v1' and prepared['status']=='prepared'
assert prepared['sourceCommit']==source and prepared['architecture']==architecture
assert prepared['syntheticSource'] and prepared['reliefInvocationCount']==0
assert prepared['sourceWidth']==768 and prepared['sourceHeight']==576 and prepared['format']=='png'
ids={prepared['processIdentifier']};summaries=[]
for mode,expected_calls in [('wait-control',0),('allocator-relief',1)]:
    r=read(root/mode/f'image-relief-{mode}.json')
    assert r['protocol']=='image-allocator-relief-v1' and r['status']=='observed' and r['mode']==mode
    assert r['sourceCommit']==source and r['architecture']==architecture
    assert r['processIdentifier'] not in ids;ids.add(r['processIdentifier'])
    assert r['inputPreparationProcessIdentifier']==prepared['processIdentifier']
    assert r['sourceWidth']==768 and r['sourceHeight']==576 and r['format']=='png'
    assert r['warmupCycles']==2 and r['measuredCycles']==12
    assert len(r['warmups'])==2 and len(r['cycles'])==12 and r['completedAccumulationPreviews']==14
    assert r['configuredGoalBytes']==33554432 and r['cooperativeDeadlineSeconds']==45 and r['requiredOuterDeadlineSeconds']==60
    assert 0<=r['elapsedSeconds']<=45
    assert r['reliefInvocationCount']==expected_calls and r['helperInvocations']==0 and r['ownedTemporaryMediaFiles']==0
    assert not r['captureStarted'] and not r['networkAttempted']
    assert r['immutableInputUnchanged'] and r['immutableInputSHA256']==prepared['sha256']
    for group,is_warm in [('warmups',True),('cycles',False)]:
        for index,c in enumerate(r[group],1):
            assert c['index']==index and c['isWarmup']==is_warm and c['fixtureScopeExited']
            assert c['preview']['width']==768 and c['preview']['height']==576 and c['preview']['strideBytes']<=4*1024*1024
            assert math.isfinite(c['preview']['previewElapsedSeconds']) and c['preview']['previewElapsedSeconds']>=0
    intervention=r['intervention'];assert intervention['mode']==mode and intervention['invocationCount']==expected_calls
    if expected_calls:
        assert intervention['requestedGoalBytes']==33554432
        assert isinstance(intervention['apiReportedReleasedBytes'],int) and intervention['apiReportedReleasedBytes']>=0
        # It is a best-effort goal, not an upper bound on the returned byte count.
    else:
        assert 'apiReportedReleasedBytes' not in intervention and 'requestedGoalBytes' not in intervention
    delayed=r['postInterventionObservations']
    assert [x['requestedSecondsAfterIntervention'] for x in delayed]==[0.5,2]
    assert all(x['actualSecondsAfterIntervention']>=x['requestedSecondsAfterIntervention'] for x in delayed)
    post=r['subsequentPreviewAndPixels']
    assert r['subsequentVerificationPreviews']==1 and post['exactPixelsMatch']
    assert post['pixelsSHA256']==prepared['expectedPixelsSHA256'] and post['rasterBytes']==768*576*4
    assert math.isfinite(post['previewElapsedSeconds']) and post['previewElapsedSeconds']>=0
    keys=[('standard','bytes','resident_size'),('standard','bytes','phys_footprint'),
          ('purgeable','bytes','purgeable_volatile_resident'),('standard','ledgerBytes','ledger_purgeable_nonvolatile')]
    def delta(sample):
        values={}
        for a,b,k in keys:
            before=intervention['before'][a][b].get(k);after=sample[a][b].get(k)
            values[k]=None if before is None or after is None else after-before
        return values
    summaries.append({'mode':mode,'apiReportedReleasedBytes':intervention.get('apiReportedReleasedBytes'),
        'callElapsedSeconds':intervention['callElapsedSeconds'],'immediatelyAfterMinusBeforeBytes':delta(intervention['immediatelyAfter']),
        'delayedMinusBeforeBytes':[{'seconds':o['actualSecondsAfterIntervention'],'deltas':delta(o['memory'])} for o in delayed],
        'subsequentPreviewElapsedSeconds':post['previewElapsedSeconds'],'exactPixelsMatch':post['exactPixelsMatch']})
assert len(ids)==3
summary={'status':'observed','sourceCommit':source,'architecture':architecture,'arms':summaries,
         'interpretation':'Raw self-process measurements; allocator return alone does not prove preview reclamation or zero cost'}
(root/'comparison.json').write_text(json.dumps(summary,indent=2,sort_keys=True)+'\n')
print(json.dumps(summary,indent=2,sort_keys=True))
PY
