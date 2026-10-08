#!/bin/bash
# Four fresh processes, one signed app. Certifications never enter memory ratios.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -eq 3 ]] || { echo 'Usage: renderer-storage-pair-diagnostic.sh APP NEW_EVIDENCE_ROOT EXPECTED_SOURCE' >&2; exit 64; }
app="$1"; root="$2"; expected="$3"
[[ "$app" == /* && "$root" == /* && ! -e "$root" && "$expected" =~ ^[0-9a-f]{40}$ ]] || exit 64
codesign --verify --deep --strict "$app"
mkdir -p "$(dirname "$root")"
mkdir "$root"
launch() {
    local cell="$1" strategy="$2" mode="$3" status=0
    mkdir "$root/$cell"
    codesign --verify --deep --strict "$app"
    python3 scripts/run-bounded-command.py --timeout-seconds 620 --grace-seconds 5 --max-log-bytes 2097152 \
        --log "$root/$cell/launcher.log" --report "$root/$cell/bounded-launch.json" -- \
        swift scripts/launch-renderer-storage-pair.swift "$app" "$root/$cell/launch.json" "$strategy" "$mode" || status=$?
    python3 scripts/check-renderer-storage-pair.py --app "$app" --expected-source "$expected" \
        --cell "$root/$cell" --strategy "$strategy" --mode "$mode" --launcher-status "$status" \
        --output "$root/$cell/checked-renderer-storage.json"
}
launch baseline-certification native certify
launch candidate-certification owned-srgb8 certify
python3 scripts/check-renderer-storage-pair.py --app "$app" --expected-source "$expected" \
    --root "$root" --stage certification --output "$root/certification-check.json"
launch baseline native resources
launch candidate owned-srgb8 resources
codesign --verify --deep --strict "$app"
python3 scripts/check-renderer-storage-pair.py --app "$app" --expected-source "$expected" \
    --root "$root" --stage pair --output "$root/comparison.json"
