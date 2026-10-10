#!/bin/bash
# Unpack the real release ZIP; never reuse the app-only diagnostic directory.
set -euo pipefail
[[ $# == 3 ]] || { echo 'Usage: codec-fidelity-installed.sh ABS_ZIP ABS_NEW_EVIDENCE_ROOT EXACT_SOURCE' >&2; exit 64; }
archive="$1"; root="$2"; expected_source="$3"
[[ "$archive" == /* && "$root" == /* && ! -e "$root" && "$expected_source" =~ ^[0-9a-f]{40}$ ]] || exit 64
cd -P "$(dirname "$0")/.."
# Keep all new evidence/media outside the broad existing dist/evidence QA upload.
[[ "$root" != "$PWD/dist/evidence" && "$root" != "$PWD/dist/evidence/"* ]] || exit 64
# Keep native reports and POSIX evidence checks on the same physical app path.
mkdir -p dist
test "$(cd dist && pwd -P)" = "$PWD/dist"
work=$(mktemp -d "$PWD/dist/codec-fidelity-installed.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
ditto -x -k "$archive" "$work"
app="$work/PicShot.app"
codesign --verify --deep --strict "$app"
python3 - "$archive" "$app" "$expected_source" "$work/installed-zip.json" <<'PY'
import hashlib,json,pathlib,plistlib,sys
archive,app=map(pathlib.Path,sys.argv[1:3])
with (app/'Contents/Info.plist').open('rb') as stream:info=plistlib.load(stream)
if info.get('PicShotSourceCommit')!=sys.argv[3]:raise SystemExit('Installed ZIP source differs')
digest=hashlib.sha256()
with archive.open('rb') as stream:
    for block in iter(lambda:stream.read(1024*1024),b''):digest.update(block)
pathlib.Path(sys.argv[4]).write_text(json.dumps({'sourceCommit':sys.argv[3],'zipSHA256':digest.hexdigest(),'zipBytes':archive.stat().st_size,
    'installedBundlePath':str(app),'installedFromZIP':True,'promotionReady':False},indent=2)+'\n')
PY
phase_status=0
bash scripts/codec-staging-comparison.sh --phase fidelity-only "$app" "$root" || phase_status=$?
# Preserve actual ZIP provenance with the bounded phase evidence even on failure.
if [[ -d "$root" ]]; then
  cp "$work/installed-zip.json" "$root/installed-zip.json"
  python3 - "$root" <<'PY'
import pathlib,sys,zipfile
root=pathlib.Path(sys.argv[1]);archive=root/'upload/fidelity-only-reports.zip'
if archive.is_file():
    with zipfile.ZipFile(archive,'a',compression=zipfile.ZIP_DEFLATED) as z:z.write(root/'installed-zip.json','installed-zip.json')
    if archive.stat().st_size>=28*1024*1024:raise SystemExit('Fidelity report archive exceeds 28 MiB')
PY
fi
exit "$phase_status"
