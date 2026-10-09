#!/bin/bash
# Four fresh processes per finite comparison, one signed app. No six-cell matrix.
# Certifications never enter memory ratios.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -eq 3 || $# -eq 4 ]] || { echo 'Usage: effect-context-pair-diagnostic.sh APP NEW_EVIDENCE_ROOT EXPECTED_SOURCE [COMPARISON_KIND]' >&2; exit 64; }
app="$1"; root="$2"; expected="$3"; kind="${4:-effect-context-memory-target}"
[[ "$kind" == effect-context-memory-target ]] || { echo 'Unknown effect comparison kind' >&2; exit 64; }
baseline=reference; candidate=memory32
[[ "$app" == /* && "$root" == /* && ! -e "$root" && "$expected" =~ ^[0-9a-f]{40}$ ]] || exit 64
codesign --verify --deep --strict "$app"
mkdir -p "$(dirname "$root")"
mkdir "$root"
app="$(cd "$app" && pwd -P)"
root="$(cd "$root" && pwd -P)"
launch() {
    local cell="$1" strategy="$2" mode="$3" status=0
    mkdir "$root/$cell"
    codesign --verify --deep --strict "$app"
    python3 scripts/run-bounded-command.py --timeout-seconds 620 --grace-seconds 5 --max-log-bytes 2097152 \
        --log "$root/$cell/launcher.log" --report "$root/$cell/bounded-launch.json" -- \
        swift scripts/launch-effect-context-pair.swift "$app" "$root/$cell/launch.json" "$strategy" "$mode" "$kind" || status=$?
    python3 scripts/check-effect-context-pair.py --app "$app" --expected-source "$expected" --comparison-kind "$kind" \
        --cell "$root/$cell" --policy "$strategy" --mode "$mode" --launcher-status "$status" \
        --output "$root/$cell/checked-effect-context.json"
}
launch baseline-certification "$baseline" certify
launch candidate-certification "$candidate" certify
python3 scripts/check-effect-context-pair.py --app "$app" --expected-source "$expected" --comparison-kind "$kind" \
    --root "$root" --stage certification --output "$root/certification-check.json"
launch baseline "$baseline" resources
launch candidate "$candidate" resources
codesign --verify --deep --strict "$app"
python3 scripts/check-effect-context-pair.py --app "$app" --expected-source "$expected" --comparison-kind "$kind" \
    --root "$root" --stage pair --output "$root/comparison.json"
