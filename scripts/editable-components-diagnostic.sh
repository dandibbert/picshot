#!/bin/bash
# Opt-in only. No package, workflow, installer or production acceptance changes.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -eq 3 ]] || { echo 'Usage: editable-components-diagnostic.sh ABS_APP ABS_FRESH_ROOT EXPECTED_SOURCE' >&2; exit 64; }
app="$1"; root="$2"; expected="$3"
[[ "$app" == /* && "$root" == /* && ! -e "$root" && "$expected" =~ ^[0-9a-f]{40}$ ]] || exit 64
[[ "$(uname -s)" == Darwin ]] || { echo 'This diagnostic requires an installed macOS app and native display' >&2; exit 64; }
app="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve(strict=True))' "$app")"
root="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve())' "$root")"
[[ ! -e "$root" && "$root" != "$app" && "$root" != "$app"/* ]] || exit 64
codesign --verify --deep --strict "$app"
mkdir -p "$(dirname "$root")"
mkdir "$root"
launch() {
  local mode="$1"
  mkdir "$root/$mode"
  (
    export PICSHOT_EDITABLE_COMPONENT_MODE="$mode"
    unset PICSHOT_EDITABLE_COMPONENT_INPUT PICSHOT_EDITABLE_COMPONENT_CERTIFICATE PICSHOT_EDITABLE_COMPONENT_WRITES
    if [[ "$mode" != prepare ]]; then export PICSHOT_EDITABLE_COMPONENT_INPUT="$root/prepare"; fi
    if [[ "$mode" != prepare && "$mode" != certify ]]; then export PICSHOT_EDITABLE_COMPONENT_CERTIFICATE="$root/certify/component.json"; fi
    if [[ "$mode" == verify-writes ]]; then export PICSHOT_EDITABLE_COMPONENT_WRITES="$root/png-write"; fi
    python3 scripts/run-bounded-command.py --timeout-seconds 620 --grace-seconds 5 --max-log-bytes 2097152 \
      --log "$root/$mode/launcher.log" --report "$root/$mode/command.json" \
      -- swift scripts/launch-editable-component.swift "$app" "$root/$mode/launch.json"
  )
}
launch prepare
launch certify
python3 scripts/check-editable-components.py --app "$app" --expected-source "$expected" --root "$root" --stage certify --output "$root/certification-check.json"
# The same unchanged prepared byte files and certificate feed every cell.
for mode in raw-draw png-write png-decode-draw editable-render-pin; do launch "$mode"; done
# Only after the writer has exited: actual decode/draw+memcmp of ALL 30 outputs.
launch verify-writes
python3 scripts/check-editable-components.py --app "$app" --expected-source "$expected" --root "$root" --stage complete --output "$root/comparison.json"
