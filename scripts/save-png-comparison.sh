#!/bin/bash
# One same-source pair. This records evidence, not a memory qualification.
set -euo pipefail
[[ $# == 3 && "$(uname -s)" == Darwin ]] || { echo 'Usage: save-png-comparison.sh EXACT_APP FRESH_ROOT SOURCE_SHA' >&2; exit 64; }
pair_app="$1"; pair_root="$2"; pair_source="$3"
pair_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ "$pair_app" == /* && "$pair_app" == *.app && "$pair_root" == /* && ! -e "$pair_root" ]] || exit 64
[[ "$pair_source" =~ ^[0-9a-f]{40}$ ]] || exit 64
mkdir -p "$pair_root"
pair_root="$(cd "$pair_root" && pwd -P)"
cd "$pair_repo"

identity() {
  local position="$1" signature_status=0
  /usr/bin/codesign --verify --deep --strict "$pair_app" >"$pair_root/signature-$position.log" 2>&1 || signature_status=$?
  python3 - "$pair_app" "$pair_root" "$pair_source" "$position" "$signature_status" <<'PY'
import hashlib,json,pathlib,plistlib,stat,sys
app,root=map(pathlib.Path,sys.argv[1:3]); source,position,signature=sys.argv[3:]
def write(name,value):
    (root/name).write_text(json.dumps(value,indent=2,sort_keys=True)+'\n')
write('signature-'+position+'.json',{'schemaVersion':1,'exitCode':int(signature)})
if app != app.resolve(strict=True):raise SystemExit('Exact app path must be canonical')
def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
    return h.hexdigest()
info=app/'Contents/Info.plist'
with info.open('rb') as f:metadata=plistlib.load(f)
if metadata.get('PicShotSourceCommit')!=source or metadata.get('CFBundleExecutable')!='PicShot':
    raise SystemExit('Packaged source or executable differs')
entries=[]
for path in sorted(app.rglob('*'),key=lambda p:p.relative_to(app).as_posix()):
    mode=path.lstat().st_mode
    if stat.S_ISLNK(mode):kind,payload='symlink',path.readlink().as_posix()
    elif stat.S_ISDIR(mode):kind,payload='directory',''
    elif stat.S_ISREG(mode):kind,payload='file',digest(path)
    else:raise SystemExit('Unexpected bundle entry kind')
    entries.append([path.relative_to(app).as_posix(),kind,payload,stat.S_IMODE(mode)])
manifest=json.dumps(entries,ensure_ascii=False,separators=(',',':')).encode()
write('bundle-manifest-'+position+'.json',entries)
executable=app/'Contents/MacOS/PicShot'
actual={'schemaVersion':1,'sourceCommit':source,'bundlePath':str(app),
 'mainExecutablePath':str(executable),'mainExecutableSHA256':digest(executable),
 'infoPlistSHA256':digest(info),'bundleFilesSHA256':hashlib.sha256(manifest).hexdigest(),
 'bundleEntryCount':len(entries),'version':str(metadata['CFBundleShortVersionString']),
 'build':str(metadata['CFBundleVersion'])}
write('identity-'+position+'.json',actual)
if position=='after' and actual!=json.loads((root/'identity-before.json').read_text()):
    raise SystemExit('Application bytes or metadata changed during pair')
if int(signature)!=0:raise SystemExit('Strict signature verification failed')
PY
}

finish() {
  local original_status=$? identity_status=0 reader_status=0 pack_status=0
  trap - EXIT
  set +e
  identity after || identity_status=$?
  python3 -I scripts/check-save-png-comparison.py "$pair_root" --source "$pair_source" --bundle "$pair_app" || reader_status=$?
  python3 - "$pair_root" <<'PY'
import pathlib,sys,zipfile
root=pathlib.Path(sys.argv[1]);parts=root/'parts';parts.mkdir(exist_ok=True)
# Native output decoding has already run in its separate process, or its exact
# failure is retained. Preserve every existing output even after a failed cell.
with zipfile.ZipFile(parts/'save-png-reports.zip.partial','w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
    for p in sorted(root.rglob('*')):
        if p.is_file() and not p.is_symlink() and parts not in p.parents and 'outputs' not in p.relative_to(root).parts:
            z.write(p,p.relative_to(root))
for arm in ('control','candidate'):
    with zipfile.ZipFile(parts/('save-png-'+arm+'-outputs.zip.partial'),'w',zipfile.ZIP_STORED) as z:
        for p in sorted((root/arm/'outputs').glob('*.png')):
            if not p.is_symlink() and p.is_file():z.write(p,p.relative_to(root))
for p in sorted(parts.glob('*.partial')):
    if p.stat().st_size>=28*1024*1024:raise SystemExit('Bounded artifact part exceeds28MiB: '+p.name)
    p.rename(p.with_suffix(''))
PY
  pack_status=$?
  if [[ "$original_status" != 0 ]]; then exit "$original_status"; fi
  if [[ "$identity_status" != 0 ]]; then exit "$identity_status"; fi
  if [[ "$reader_status" != 0 ]]; then exit "$reader_status"; fi
  exit "$pack_status"
}
trap finish EXIT
identity before

run_cell() {
  local name="$1" mode="$2" timeout="$3" result=0
  mkdir "$pair_root/$name"
  local selector=(PICSHOT_SAVE_PNG_COMPARISON_MODE="$mode")
  if [[ "$mode" == measure ]]; then selector+=(PICSHOT_SAVE_PNG_COMPARISON_ARM="$name")
  else selector+=(PICSHOT_SAVE_PNG_COMPARISON_INPUT_DIRECTORY="$pair_root"); fi
  python3 scripts/run-bounded-command.py --timeout-seconds "$timeout" --grace-seconds 5 \
    --log "$pair_root/$name/launcher.log" --report "$pair_root/$name/command.json" \
    -- env -i HOME="$HOME" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" "${selector[@]}" \
    swift scripts/launch-smoke-app.swift "$pair_app" "$pair_root/$name/smoke.json" || result=$?
  printf '%s\n' "$result" > "$pair_root/$name/launcher-exit-code.txt"
  # A failed measurement is still independently decoded. An unconfirmed exit
  # must stop further cells so a surviving producer cannot contaminate them.
  python3 - "$pair_root/$name/smoke.json.launcher.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
if r.get('ownedExitConfirmed') is not True or r.get('launchedIdentityMatches') is not True:
    raise SystemExit('Owned application exit/identity is unconfirmed; stop later cells')
PY
}
run_cell control measure 420
run_cell candidate measure 420
run_cell validation validate 300
