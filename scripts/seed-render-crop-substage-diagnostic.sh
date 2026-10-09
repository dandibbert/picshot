#!/bin/bash
# Exactly two fresh sequential processes; scalar attribution, no efficacy arms.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -eq 3 ]] || { echo 'Usage: seed-render-crop-substage-diagnostic.sh APP NEW_EVIDENCE_ROOT EXPECTED_SOURCE' >&2; exit 64; }
app="$1"; root="$2"; expected="$3"
[[ "$app" == /* && "$root" == /* && ! -e "$root" && "$expected" =~ ^[0-9a-f]{40}$ ]] || exit 64
codesign --verify --deep --strict "$app"
mkdir -p "$(dirname "$root")"
mkdir "$root"
app="$(cd "$app" && pwd -P)"
root="$(cd "$root" && pwd -P)"
launch() {
    local cell="$1" mode="$2" status=0
    mkdir "$root/$cell"
    codesign --verify --deep --strict "$app"
    python3 scripts/run-bounded-command.py --timeout-seconds 620 --grace-seconds 5 --max-log-bytes 2097152 \
        --log "$root/$cell/launcher.log" --report "$root/$cell/bounded-launch.json" -- \
        swift scripts/launch-seed-render-crop-substage.swift "$app" "$root/$cell/launch.json" "$mode" || status=$?
    python3 scripts/check-seed-render-crop-substage.py --app "$app" --expected-source "$expected" \
        --cell "$root/$cell" --mode "$mode" --launcher-status "$status" \
        --output "$root/$cell/checked-seed-render-crop-substage.json"
}
launch certification certify
launch resources resources
codesign --verify --deep --strict "$app"
python3 scripts/check-seed-render-crop-substage.py --app "$app" --expected-source "$expected" \
    --root "$root" --output "$root/attribution.json"
