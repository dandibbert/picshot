#!/bin/bash
# Three separate native installed-app processes; no real capture or Spaces changes.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -eq 3 ]] || { echo 'Usage: pin-workflows-smoke.sh APP NEW_EVIDENCE EXPECTED_COMMIT' >&2; exit 64; }
app="$1"; root="$2"; expected="$3"
[[ "$app" == /* && "$root" == /* && ! -e "$root" && "$expected" =~ ^[0-9a-f]{40}$ ]] || exit 64
codesign --verify --deep --strict "$app"
mkdir -p "$(dirname "$root")"
mkdir "$root"
for mode in latex desktop group; do
  mkdir "$root/$mode"
  (
    unset PICSHOT_UI_PREVIEW_ONLY PICSHOT_SMOKE_GIF_RESOURCES PICSHOT_GIF_DIAGNOSTIC_MODE
    unset PICSHOT_CODEC_ATTRIBUTION_MODE PICSHOT_IMAGE_BACKING_MODE PICSHOT_IMAGE_RELIEF_MODE
    unset PICSHOT_LATEX_PIN_VERIFY PICSHOT_PIN_DESKTOP_VISIBILITY_ONLY PICSHOT_PIN_GROUP_TRANSFORMS_ONLY
    case "$mode" in
      latex) export PICSHOT_LATEX_PIN_VERIFY=1 ;;
      desktop) export PICSHOT_PIN_DESKTOP_VISIBILITY_ONLY=1 ;;
      group) export PICSHOT_PIN_GROUP_TRANSFORMS_ONLY=1 ;;
    esac
    swift scripts/launch-smoke-app.swift "$app" "$root/$mode/launch.json"
  )
done
python3 scripts/check-pin-resource-report.py "$root/latex/launch.json" latex
python3 scripts/check-pin-resource-report.py "$root/group/launch.json" group
python3 - "$root" "$app" "$expected" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]);app=pathlib.Path(sys.argv[2]).resolve();source=sys.argv[3]
reports={}
for mode in ['latex','desktop','group']:
    r=json.loads((root/mode/'launch.json').read_text())
    assert r['status']=='passed' and r['sourceCommit']==source,r
    assert pathlib.Path(r['bundlePath']).resolve()==app,r
    assert len(r['arguments'])==1,r
    reports[mode]=r
r=reports['latex']
for key in ['actualBundledRenderer','nativeEditableSource','sourceCopyVerified','atomicSourceRasterEdit',
            'invalidDraftPreservesLastValid','undoVerified','cancelAndClosePreserveSavedSource','restoreWithoutAutomaticRendering']:
    assert r[key] is True,(key,r)
assert not r['screenCaptureStarted'] and not r['modelDownloaded'],r
assert r['cycles']==12 and r['maximumUndoSourceEntries']==10,r
assert set(r['exportBytes'])=={'latex','mathML','svg','png','pdf'} and all(v>0 for v in r['exportBytes'].values()),r
r=reports['desktop']
for key in ['toggledInPlace','closedControllersReleased','sessionBytesUnchangedByToggle','noActivationFollowFlag','originalRasterProviderReleased']:
    assert r[key] is True,(key,r)
assert not r['physicalSpacesVerified'] and not r['screenCaptureAttempted'] and not r['userPreferencesReadOrWritten'],r
assert r['contextActionCount']==25 and r['inPlaceToggleCount']==27,r
r=reports['group']
assert r['selectedPins']==3 and r['unselectedSentinels']==1 and r['warmupCycles']==3 and r['cycles']==20,r
assert r['retainedControllersOrContent']==0 and not r['captureStarted'] and not r['userDefaultsChanged'],r
assert 'six-native-alignments' in r['stages'] and 'atomic-undo-redo' in r['stages'],r
for mode,r in reports.items():
    for name in r.get('snapshots',r.get('previews',[])):
        assert pathlib.Path(name).name==name
        assert (root/mode/name).read_bytes().startswith(b'\x89PNG\r\n\x1a\n'),name
summary={'status':'passed','sourceCommit':source,'bundlePath':str(app),'separateNativeLaunches':3,
         'physicalSpacesVerified':False,'screenCaptureStarted':False,
         'scope':'Real renderer and native controls with synthetic local pins; no physical Spaces or external-app acceptance'}
(root/'pin-workflows.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary,indent=2))
PY
