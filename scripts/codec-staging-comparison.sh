#!/bin/bash
set -euo pipefail
[[ $# == 4 && "$1" == --phase ]] || { echo 'Usage: codec-staging-comparison.sh --phase export|product|fidelity|summary|avif-confirmation|fidelity-only ABS_APP ABS_EVIDENCE_ROOT' >&2; exit 64; }
phase="$2"; app="$3"; root="$4"
[[ "$app" == /* && "$app" == *.app && "$root" == /* && "$(uname -s)" == Darwin ]] || exit 64
cd -P "$(dirname "$0")/.."
[[ "$phase" == export || "$phase" == product || "$phase" == fidelity || "$phase" == summary || "$phase" == avif-confirmation || "$phase" == fidelity-only ]] || exit 64
if [[ "$phase" == export || "$phase" == avif-confirmation || "$phase" == fidelity-only ]]; then
  [[ ! -e "$root" ]] || exit 65
  mkdir -p "$root"
else
  [[ -f "$root/export-summary.json" ]] || exit 65
  python3 - "$root/export-summary.json" <<'PY'
import json,sys
if json.load(open(sys.argv[1]))["verdict"] != "passes-predeclared-gates":raise SystemExit("Export-only benefit did not pass; stop before product/fidelity matrix")
PY
fi
finish() {
  original_status=$?
  trap - EXIT
  set +e
# Each attachment stays below the actual transfer ceiling, even without relying
# on the artifact service's compression. Reports and specimens are separate.
python3 - "$root" "$phase" "$original_status" <<'PY'
import json, pathlib, sys, zipfile
root=pathlib.Path(sys.argv[1]); phase=sys.argv[2]
parts=root/'upload';parts.mkdir(exist_ok=True)
(root/(phase+'-exit.json')).write_text(json.dumps({'phase':phase,'exitCode':int(sys.argv[3])})+'\n')
if not (root/(phase+'-summary.json')).exists():
    incomplete={'phase':phase,'verdict':'inconclusive-phase-did-not-complete','promotionReady':False}
    if phase=='fidelity-only':incomplete.update(sameRunMeasuredCellBinding=False,historicalMemoryQualification=False)
    if phase=='avif-confirmation':incomplete.update(avifQualificationHold=True,overallAVIFVerdict='inconclusive-incomplete-confirmation')
    (root/(phase+'-summary.json')).write_text(json.dumps(incomplete)+'\n')
total=0
with zipfile.ZipFile(parts/(phase+'-reports.zip'),'w',compression=zipfile.ZIP_DEFLATED) as z:
    for p in sorted(root.rglob('*')):
        if p.is_file() and 'upload' not in p.parts and p.suffix in ('.json','.log'):
            total+=p.stat().st_size
            if total>=28*1024*1024:raise SystemExit('Report/log budget exceeds 28 MiB; retain raw evidence and fail')
            z.write(p,p.relative_to(root))
if phase in ('fidelity','fidelity-only'):
    for group,pattern in [('small','evidence-small-*/*'),('large-control','evidence-large-control/*'),('large-candidate','evidence-large-candidate/*')]:
        archive=parts/(group+'-specimens.zip')
        with zipfile.ZipFile(archive,'x',compression=zipfile.ZIP_DEFLATED) as z:
            for p in sorted(root.glob(pattern)):
                if p.is_file() and not p.is_symlink() and p.suffix in ('.png','.rgba','.webp','.avif'):
                    z.write(p,p.relative_to(root))
for p in parts.iterdir():
    if p.stat().st_size>=28*1024*1024:raise SystemExit('Artifact exceeds 28 MiB: '+str(p))
PY

  pack_status=$?
  if [[ "$original_status" != 0 ]]; then exit "$original_status"; fi
  exit "$pack_status"
}
trap finish EXIT
/usr/bin/codesign --verify --deep --strict "$app"
/usr/bin/codesign --verify --strict "$app/Contents/Helpers/PicShotCodecHelper"
identity() {
  python3 - "$app" "$root" "$phase" "$1" <<'PYIDENTITY'
import hashlib, json, pathlib, plistlib, sys
app=pathlib.Path(sys.argv[1]); root=pathlib.Path(sys.argv[2]); phase,position=sys.argv[3:5]
canonical=app.resolve(strict=True)
if app != canonical:raise SystemExit('Comparison requires the canonical bundle path')
info=app/'Contents/Info.plist'
with info.open('rb') as f:metadata=plistlib.load(f)
source=metadata.get('PicShotSourceCommit','')
if not isinstance(source,str) or len(source)!=40 or any(c not in '0123456789abcdef' for c in source):
    raise SystemExit('Missing exact Info.plist source commit')
if metadata.get('CFBundleExecutable')!='PicShot':raise SystemExit('Unexpected main executable name')
main=app/'Contents/MacOS/PicShot'; helper=app/'Contents/Helpers/PicShotCodecHelper'
def digest(path):
    if path.is_symlink() or not path.is_file() or path.resolve(strict=True)!=path:
        raise SystemExit('Executable is not a canonical regular file')
    sha=hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''):sha.update(block)
    return sha.hexdigest()
actual={'schemaVersion':1,'bundlePath':str(canonical),'sourceCommit':source,
    'mainExecutablePath':str(main),'mainExecutableSHA256':digest(main),
    'helperExecutablePath':str(helper),'helperExecutableSHA256':digest(helper),
    'infoPlistSHA256':digest(info)}
identity=root/'identity.json'
if phase in ('export','avif-confirmation','fidelity-only') and position=='before':
    with identity.open('x') as f:json.dump(actual,f,indent=2,sort_keys=True);f.write('\n')
with identity.open() as f:expected=json.load(f)
report={'phase':phase,'position':position,'outsideMeasuredParents':True,'matchesPreflight':actual==expected,'identity':actual}
(root/('identity-'+phase+'-'+position+'.json')).write_text(json.dumps(report,indent=2,sort_keys=True)+'\n')
if actual!=expected:raise SystemExit('Signed app/helper/Info.plist identity changed since preflight')
PYIDENTITY
}
if [[ "$phase" == avif-confirmation ]]; then
  PYTHONDONTWRITEBYTECODE=1 python3 scripts/check-avif-confirmation-source.py --report "$root/source-guard-before.json"
fi
identity before
run() {
  local name="$1" mode="$2" arm="$3" profile="$4" format="${5:-webp}" input="${6:-}"
  [[ ! -e "$root/$name" ]] || exit 65
  mkdir "$root/$name"
  if [[ -n "$input" ]]; then
    env -i HOME="$HOME" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" \
      PICSHOT_CODEC_STAGING_MODE="$mode" PICSHOT_CODEC_STAGING_ARM="$arm" PICSHOT_CODEC_STAGING_PROFILE="$profile" \
      PICSHOT_CODEC_STAGING_FORMAT="$format" PICSHOT_CODEC_STAGING_INPUT_DIRECTORY="$input" \
      swift scripts/launch-smoke-app.swift "$app" "$root/$name/launch.json" >"$root/$name/launcher.log" 2>&1
  else
    env -i HOME="$HOME" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" \
      PICSHOT_CODEC_STAGING_MODE="$mode" PICSHOT_CODEC_STAGING_ARM="$arm" PICSHOT_CODEC_STAGING_PROFILE="$profile" \
      PICSHOT_CODEC_STAGING_FORMAT="$format" \
      swift scripts/launch-smoke-app.swift "$app" "$root/$name/launch.json" >"$root/$name/launcher.log" 2>&1
  fi
}
case "$phase" in
 avif-confirmation)
  run avif-confirmation-candidate export-only candidate staging-768x576 avif
  run avif-confirmation-control export-only control staging-768x576 avif
  ;;
 export)
  run export-ab-control export-only control installed-768x576
  run export-ab-candidate export-only candidate installed-768x576
  run export-ba-candidate export-only candidate installed-768x576
  run export-ba-control export-only control installed-768x576
  ;;
 product)
  run controller-ab-control controller control installed-768x576
  run controller-ab-candidate controller candidate installed-768x576
  run controller-ba-candidate controller candidate installed-768x576
  run controller-ba-control controller control installed-768x576
  for arm in control candidate; do
    run large-export-$arm export-only "$arm" staging-2048x1536
    run large-controller-$arm controller "$arm" staging-2048x1536
    run avif-export-$arm export-only "$arm" staging-768x576 avif
    run combined-$arm combined "$arm" installed-768x576
  done
  ;;
 fidelity|fidelity-only)
  for profile in small large; do
    native_profile=installed-768x576
    [[ "$profile" != large ]] || native_profile=staging-2048x1536
    for arm in control candidate; do
      run evidence-$profile-$arm evidence "$arm" "$native_profile"
      run validate-$profile-$arm validate "$arm" "$native_profile" webp "$root/evidence-$profile-$arm"
    done
  done
  for arm in control candidate; do run interruptions-$arm interruptions "$arm" installed-768x576; done
  ;;
 summary) ;;
esac
if [[ "$phase" == avif-confirmation ]]; then
  PYTHONDONTWRITEBYTECODE=1 python3 scripts/check-avif-confirmation-source.py --report "$root/source-guard-after.json"
fi
identity after
check_status=0
python3 scripts/check-codec-staging-comparison.py "$root" --phase "$phase" || check_status=$?
exit "$check_status"
