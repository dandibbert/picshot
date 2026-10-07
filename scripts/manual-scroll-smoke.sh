#!/bin/bash
# Separate installed-app launch; synthetic frames, no physical capture or OS input.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -eq 4 ]] || { echo 'Usage: manual-scroll-smoke.sh APP NEW_EVIDENCE EXPECTED_COMMIT zip|dmg' >&2; exit 64; }
app="$1"; root="$2"; expected="$3"; format="$4"
[[ "$app" == /* && "$root" == /* && ! -e "$root" && "$expected" =~ ^[0-9a-f]{40}$ ]] || exit 64
[[ "$format" == zip || "$format" == dmg ]] || exit 64
codesign --verify --deep --strict "$app"
mkdir -p "$(dirname "$root")"
mkdir "$root"
(
  unset PICSHOT_UI_PREVIEW_ONLY PICSHOT_SMOKE_GIF_RESOURCES PICSHOT_GIF_DIAGNOSTIC_MODE
  unset PICSHOT_CODEC_ATTRIBUTION_MODE PICSHOT_IMAGE_BACKING_MODE PICSHOT_IMAGE_RELIEF_MODE
  unset PICSHOT_LATEX_PIN_VERIFY PICSHOT_PIN_DESKTOP_VISIBILITY_ONLY PICSHOT_PIN_GROUP_TRANSFORMS_ONLY
  unset PICSHOT_ANNOTATION_DETAILS_ONLY PICSHOT_AUTOMATIC_MOSAIC_ONLY PICSHOT_MANUAL_SCROLL_RESOURCES
  unset PICSHOT_MANUAL_HASH_STRATEGY PICSHOT_SCROLL_ATTRIBUTION_MODE PICSHOT_SCROLL_ATTRIBUTION_INPUT_DIRECTORY
  unset PICSHOT_SCROLL_ATTRIBUTION_PRODUCTION_COMMIT PICSHOT_SCROLL_ATTRIBUTION_OVERLAY_COMMIT
  export PICSHOT_MANUAL_SCROLL_ONLY=1
  if [[ "$format" == zip ]]; then export PICSHOT_MANUAL_SCROLL_RESOURCES=1; fi
  swift scripts/launch-smoke-app.swift "$app" "$root/launch.json"
)
python3 - "$root" "$app" "$expected" "$format" <<'PY'
import importlib.util,pathlib,sys
spec=importlib.util.spec_from_file_location('manual','scripts/check-scroll-manual-resource-report.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
root=pathlib.Path(sys.argv[1]); app=pathlib.Path(sys.argv[2]).resolve();source=sys.argv[3]
r=module.read_json(root/'launch.json');module.functional(r,source)
assert r['manualHashStrategy']=='vimage-full-frame',r
assert pathlib.Path(r['bundlePath']).resolve()==app and len(r['arguments'])==1,r
large=r['largeFrameProviders'];assert len(large)==2,large
assert {(x['width'],x['height'],x['axis']) for x in large}=={(3840,2160,'horizontal'),(5120,2880,'vertical')},large
for x in large:
    assert x['exactOutputDigest'] and x['closeReleasesControllerAndSpool'],x
    assert x['samples']>=4 and 0<x['pendingImagePixelBound']<=x['width']*x['height'],x
    assert x['retainedGrayPixels']==x['width']*x['height'] and 0<x['overviewPixels']<=800*800,x
if sys.argv[4]=='zip': assert r['resourceEvidence']['status']=='passed',r
else: assert 'resourceEvidence' not in r,r
print('Installed continuous manual scroll controls, exact output and cleanup passed')
PY
if [[ "$format" == zip ]]; then
  python3 scripts/check-scroll-manual-resource-report.py "$root/scroll-manual-resource.json" "$app" "$expected" \
    "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" \
    "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" \
    --functional-report "$root/scroll-manual-continuous.json"
fi
