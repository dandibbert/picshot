#!/bin/bash
# Two independent unchanged failure guards; scalar effect evidence only.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -eq 3 ]] || { echo 'Usage: effect-context-output-guard.sh APP NEW_ROOT SOURCE' >&2; exit 64; }
app="$1"; root="$2"; expected="$3"
[[ "$app" == /* && "$root" == /* && ! -e "$root" && "$expected" =~ ^[0-9a-f]{40}$ ]] || exit 64
codesign --verify --deep --strict "$app"
mkdir -p "$(dirname "$root")"
mkdir "$root"
app="$(cd "$app" && pwd -P)"
root="$(cd "$root" && pwd -P)"
launch() {
    local policy="$1" status=0
    mkdir "$root/$policy"
    codesign --verify --deep --strict "$app"
    python3 scripts/run-bounded-command.py --timeout-seconds 620 --grace-seconds 5 --max-log-bytes 2097152 \
        --log "$root/$policy/launcher.log" --report "$root/$policy/bounded-launch.json" -- \
        swift scripts/launch-effect-context-guard.swift "$app" "$root/$policy/launch.json" "$policy" || status=$?
    [[ "$status" -eq 0 ]] || { echo 'Owned effect guard launch failed' >&2; return "$status"; }
    python3 scripts/check-effect-context-guard.py "$root/$policy" "$app" "$expected" --policy "$policy" \
        > "$root/$policy/checked-effect-context-guard.json"
}
launch reference
launch memory32
codesign --verify --deep --strict "$app"
python3 scripts/check-effect-context-guard.py "$root" "$app" "$expected" --pair > "$root/comparison.json"
