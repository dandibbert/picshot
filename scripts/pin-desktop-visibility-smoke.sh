#!/bin/bash
# Opt-in native fixture. No packaging, upload, signing changes or CI modifications.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 /absolute/PicShot.app /absolute/evidence-directory [expected-source-commit]" >&2
  exit 64
fi
app="$1"
evidence="$2"
[[ "$app" = /* && "$evidence" = /* ]] || { echo "Use absolute local paths" >&2; exit 64; }
[[ "$(uname -s)" == Darwin ]] || { echo "Native AppKit fixture requires macOS" >&2; exit 69; }
[[ -d "$app" ]] || { echo "App bundle missing: $app" >&2; exit 66; }
codesign --verify --deep --strict "$app"
mkdir -p "$evidence"
export PICSHOT_PIN_DESKTOP_VISIBILITY_ONLY=1
swift scripts/launch-smoke-app.swift "$app" "$evidence/pin-desktop-visibility.json"
python3 - "$evidence" "${3:-}" <<'PY'
import json, pathlib, sys
root=pathlib.Path(sys.argv[1]); r=json.loads((root/'pin-desktop-visibility.json').read_text())
assert r['status']=='passed', r
if sys.argv[2]: assert r['sourceCommit']==sys.argv[2], r
for key in ['toggledInPlace','closedControllersReleased','sessionBytesUnchangedByToggle','noActivationFollowFlag','originalRasterProviderReleased']:
    assert r[key] is True, (key,r)
for key in ['physicalSpacesVerified','screenCaptureAttempted','userPreferencesReadOrWritten']:
    assert r[key] is False, (key,r)
assert r['contextActionCount']==25 and r['inPlaceToggleCount']==27, r
assert set(r['contentKinds'])=={'image','text','files','color','animation'}, r
for name in r['snapshots']:
    assert pathlib.Path(name).name==name
    assert (root/name).read_bytes().startswith(b'\x89PNG\r\n\x1a\n'),name
print(json.dumps(r,ensure_ascii=False,indent=2))
print('Physical Mission Control/Spaces acceptance remains NOT RUN.')
PY
