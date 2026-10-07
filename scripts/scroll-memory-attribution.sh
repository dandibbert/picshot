#!/bin/bash
# Pinned baseline/current diagnostic processes; never installer acceptance.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -eq 4 ]] || { echo 'Usage: scroll-memory-attribution.sh CURRENT_APP BASELINE_APP NEW_EVIDENCE OVERLAY_COMMIT' >&2; exit 64; }
current="$1"; baseline="$2"; root="$3"; overlay="$4"
production_baseline=fa4cb0ad742e89c9235cfea2eef6b5d7840a78a9
[[ "$current" == /* && "$baseline" == /* && "$root" == /* && ! -e "$root" && "$overlay" =~ ^[0-9a-f]{40}$ ]] || exit 64
codesign --verify --deep --strict "$current"
codesign --verify --deep --strict "$baseline"
python3 - "$current" "$baseline" "$overlay" "$production_baseline" <<'PY'
import pathlib,plistlib,sys
for index in [1,2]:
    root=pathlib.Path(sys.argv[index]); info=plistlib.loads((root/'Contents/Info.plist').read_bytes())
    assert info['PicShotSourceCommit']==sys.argv[3]
    if index==2:
        assert info['PicShotDiagnosticOnly'] is True
        assert info['PicShotBaselineProductionCommit']==sys.argv[4]
        assert info['PicShotDiagnosticOverlayCommit']==sys.argv[3]
PY
mkdir -p "$(dirname "$root")"
mkdir "$root"
mkdir "$root/prepared"
launch_cell() {
  local app="$1" production="$2" mode="$3" directory="$4"
  (
    unset PICSHOT_UI_PREVIEW_ONLY PICSHOT_SMOKE_GIF_RESOURCES PICSHOT_GIF_DIAGNOSTIC_MODE
    unset PICSHOT_CODEC_ATTRIBUTION_MODE PICSHOT_IMAGE_BACKING_MODE PICSHOT_IMAGE_RELIEF_MODE
    unset PICSHOT_LATEX_PIN_VERIFY PICSHOT_PIN_DESKTOP_VISIBILITY_ONLY PICSHOT_PIN_GROUP_TRANSFORMS_ONLY
    unset PICSHOT_ANNOTATION_DETAILS_ONLY PICSHOT_AUTOMATIC_MOSAIC_ONLY PICSHOT_MANUAL_SCROLL_ONLY PICSHOT_MANUAL_SCROLL_RESOURCES
    unset PICSHOT_SCROLL_ATTRIBUTION_INPUT_DIRECTORY
    export PICSHOT_SCROLL_ATTRIBUTION_MODE="$mode"
    export PICSHOT_SCROLL_ATTRIBUTION_PRODUCTION_COMMIT="$production"
    export PICSHOT_SCROLL_ATTRIBUTION_OVERLAY_COMMIT="$overlay"
    case "$mode" in
      stitch-overlap|overview|detail) export PICSHOT_SCROLL_ATTRIBUTION_INPUT_DIRECTORY="$root/prepared" ;;
    esac
    swift scripts/launch-smoke-app.swift "$app" "$directory/launch.json"
  )
}
launch_cell "$current" "$overlay" prepare-inputs "$root/prepared"
python3 - "$root/prepared" "$current" "$overlay" <<'PY'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1]); r=json.loads((root/'scroll-memory-inputs.json').read_text())
assert r['status']=='prepared' and r['sourceCommit']==r['productionSourceCommit']==r['diagnosticOverlayCommit']==sys.argv[3]
assert r['deliveredBinary'] is False and r['diagnosticOnly'] is True and len(r['inputs'])==16
assert pathlib.Path(r['bundlePath']).resolve()==pathlib.Path(sys.argv[2]).resolve()
profiles=['4k-vertical','4k-horizontal','5k-vertical','5k-horizontal']
assert {x['name'] for x in r['inputs']}=={f'{p}-{i}.png' for p in profiles for i in range(4)}
for x in r['inputs']:
    path=root/x['name']; assert path.is_file() and not path.is_symlink()
    data=path.read_bytes();assert len(data)==x['bytes'] and hashlib.sha256(data).hexdigest()==x['sha256']
PY
for variant in current baseline; do
  if [[ "$variant" == current ]]; then app="$current"; production="$overlay"; else app="$baseline"; production="$production_baseline"; fi
  mkdir "$root/$variant"
  for mode in source-create capture-hash png-spool stitch-overlap overview detail shared-accept; do
    if [[ "$variant" == baseline && "$mode" == detail ]]; then continue; fi
    directory="$root/$variant/$mode"
    mkdir "$directory"
    launch_cell "$app" "$production" "$mode" "$directory"
    arguments=("$directory/launch.json" "$app" "$production" "$overlay" "$mode")
    case "$mode" in
      stitch-overlap|overview|detail) arguments+=(--prepared-manifest "$root/prepared/scroll-memory-inputs.json") ;;
    esac
    python3 scripts/check-scroll-memory-attribution-report.py "${arguments[@]}" > "$directory/checked-summary.json"
  done
done
# Preserve the full original workload independently, now with actual VM backing
# counters. This is the signed diagnostic bundle, not a ZIP/DMG install claim.
mkdir "$root/end-to-end"
(
  unset PICSHOT_UI_PREVIEW_ONLY PICSHOT_SMOKE_GIF_RESOURCES PICSHOT_GIF_DIAGNOSTIC_MODE
  unset PICSHOT_CODEC_ATTRIBUTION_MODE PICSHOT_IMAGE_BACKING_MODE PICSHOT_IMAGE_RELIEF_MODE
  unset PICSHOT_LATEX_PIN_VERIFY PICSHOT_PIN_DESKTOP_VISIBILITY_ONLY PICSHOT_PIN_GROUP_TRANSFORMS_ONLY
  unset PICSHOT_ANNOTATION_DETAILS_ONLY PICSHOT_AUTOMATIC_MOSAIC_ONLY PICSHOT_SCROLL_ATTRIBUTION_MODE
  unset PICSHOT_SCROLL_ATTRIBUTION_INPUT_DIRECTORY PICSHOT_SCROLL_ATTRIBUTION_PRODUCTION_COMMIT PICSHOT_SCROLL_ATTRIBUTION_OVERLAY_COMMIT
  export PICSHOT_MANUAL_SCROLL_ONLY=1 PICSHOT_MANUAL_SCROLL_RESOURCES=1
  swift scripts/launch-smoke-app.swift "$current" "$root/end-to-end/launch.json"
)
python3 scripts/check-scroll-manual-resource-report.py "$root/end-to-end/scroll-manual-resource.json" "$current" "$overlay" \
  "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$current/Contents/Info.plist")" \
  "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$current/Contents/Info.plist")" \
  --functional-report "$root/end-to-end/scroll-manual-continuous.json"
python3 - "$root" "$overlay" "$production_baseline" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]); cells=[]
for variant in ['current','baseline']:
    for path in sorted((root/variant).glob('*/checked-summary.json')):
        cells.append(dict(variant=variant,mode=path.parent.name,summary=json.loads(path.read_text())))
assert len(cells)==13
raw={variant:{path.parent.name:json.loads((path.parent/'launch.json').read_text())
              for path in (root/variant).glob('*/checked-summary.json')} for variant in ['current','baseline']}
environments={(r['architecture'],r['operatingSystem'],r['buildMode']) for variants in raw.values() for r in variants.values()}
assert len(environments)==1 and next(iter(environments))[2]=='release',environments
def hashes(report):
    return [(kind,c['index'],c['profile'],c['width'],c['height'],[p['rgbaSHA256'] for p in c['phases']])
            for kind in ['warmups','cycles'] for c in report[kind]]
assert hashes(raw['current']['capture-hash'])==hashes(raw['baseline']['capture-hash'])
prepared=json.loads((root/'prepared/scroll-memory-inputs.json').read_text())
expected_inputs=[{k:row[k] for k in ['name','bytes','sha256']} for row in prepared['inputs']]
for variants in raw.values():
    for mode,r in variants.items():
        if mode in ['stitch-overlap','overview','detail']: assert r['inputFileIdentities']==expected_inputs
result=dict(status='observed',sourceCommit=sys.argv[2],baselineProductionCommit=sys.argv[3],
            diagnosticOnly=True,installerAcceptance=False,deliveredBaselineBinary=False,
            sharedPreparedInputs=True,matchingSourceHashVectors=True,matchingArchitectureOSBuildMode=True,
            runtimeEnvironment=dict(zip(['architecture','operatingSystem','buildMode'],next(iter(environments)))),ordering='current cells then instrumented baseline; fixed ordering may confound timing',
            cells=cells,endToEndAccounting='separate signed diagnostic app process; original 8+16 workload retained',
            scope='Stage-specific actual backing counters; observations do not establish reclaimability or a leak verdict')
(root/'comparison.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
PY
