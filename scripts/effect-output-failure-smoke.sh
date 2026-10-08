#!/bin/bash
# Fresh installed process over private synthetic data. Does not package or publish.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -eq 3 ]] || exit 64
app="$1"; root="$2"; expected="$3"
[[ "$app" == /* && "$root" == /* && ! -e "$root" && "$expected" =~ ^[0-9a-f]{40}$ ]] || exit 64
[[ "$(uname -s)" == Darwin ]] || { echo "Native AppKit fixture requires macOS" >&2; exit 69; }
codesign --verify --deep --strict "$app"
mkdir -p "$(dirname "$root")"
mkdir "$root"
launch_status=0
(
  # The effect-only route is first at smoke entry; it cannot silently run a
  # memory diagnostic or reuse old reports, even when the caller exported one.
  export PICSHOT_EFFECT_OUTPUT_FAILURE_ONLY=1
  swift scripts/launch-smoke-app.swift "$app" "$root/launch.json"
) > "$root/launcher.log" 2>&1 || launch_status=$?
python3 scripts/check-effect-output-failure-report.py "$root/effect-output-failure.json" "$app" "$expected" "$root/launch.json.launcher.json" > "$root/checked-effect-output-failure.json"
cat "$root/checked-effect-output-failure.json"
[[ "$launch_status" -eq 0 ]]
