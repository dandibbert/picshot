#!/bin/bash
# Explicit full-workload diagnostic suites. No installer or production-default change.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -eq 3 || $# -eq 4 ]] || { echo 'Usage: manual-hash-comparison.sh APP NEW_EVIDENCE COMMIT [context-reuse|direct-conversion]' >&2; exit 64; }
app="$1"; root="$2"; expected="$3"; suite="${4:-context-reuse}"
case "$suite" in
  context-reuse) strategies=(full-frame pooled-full-frame reusable-full-frame) ;;
  direct-conversion) strategies=(full-frame vimage-full-frame) ;;
  *) echo "Unknown manual-hash suite: $suite" >&2; exit 64 ;;
esac
[[ "$app" == /* && "$root" == /* && ! -e "$root" && "$expected" =~ ^[0-9a-f]{40}$ ]] || exit 64
codesign --verify --deep --strict "$app"
python3 - "$app" "$expected" <<'PY'
import pathlib,plistlib,sys
app=pathlib.Path(sys.argv[1]); info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info['PicShotSourceCommit']==sys.argv[2]
PY
mkdir -p "$(dirname "$root")"
mkdir "$root"
blocked=''
for strategy in "${strategies[@]}"; do
  directory="$root/$strategy"
  mkdir "$directory"
  if [[ -n "$blocked" ]]; then
    python3 - "$strategy" "$blocked" > "$directory/checked-cell.json" <<'PY'
import json,sys
print(json.dumps(dict(status='blocked',strategy=sys.argv[1],observationsComplete=False,error=sys.argv[2],diagnosticOnly=True),indent=2))
PY
    continue
  fi
  launch_status=0
  (
    unset PICSHOT_UI_PREVIEW_ONLY PICSHOT_SMOKE_GIF_RESOURCES PICSHOT_GIF_DIAGNOSTIC_MODE
    unset PICSHOT_CODEC_ATTRIBUTION_MODE PICSHOT_IMAGE_BACKING_MODE PICSHOT_IMAGE_RELIEF_MODE
    unset PICSHOT_LATEX_PIN_VERIFY PICSHOT_PIN_DESKTOP_VISIBILITY_ONLY PICSHOT_PIN_GROUP_TRANSFORMS_ONLY
    unset PICSHOT_ANNOTATION_DETAILS_ONLY PICSHOT_AUTOMATIC_MOSAIC_ONLY PICSHOT_SCROLL_ATTRIBUTION_MODE
    unset PICSHOT_SCROLL_ATTRIBUTION_INPUT_DIRECTORY PICSHOT_SCROLL_ATTRIBUTION_PRODUCTION_COMMIT PICSHOT_SCROLL_ATTRIBUTION_OVERLAY_COMMIT
    export PICSHOT_MANUAL_SCROLL_ONLY=1 PICSHOT_MANUAL_SCROLL_RESOURCES=1
    export PICSHOT_MANUAL_HASH_STRATEGY="$strategy"
    swift scripts/launch-smoke-app.swift "$app" "$directory/launch.json"
  ) > "$directory/launcher.log" 2>&1 || launch_status=$?
  # A timed-out/failed resource cell is still preserved. Validation failure is
  # local to this cell; other independent strategies remain useful observations.
  if ! python3 scripts/check-manual-hash-comparison.py cell "$directory" "$app" "$expected" "$strategy" \
      --launcher-exit-code "$launch_status" > "$directory/checked-cell.json"; then
    echo "Manual hash cell $strategy did not complete valid full-workload evidence" >&2
  fi
  # Never overlap a new experiment with a process whose exit is unconfirmed.
  # Internal 240s fixture failures normally terminate and therefore allow peers.
  if ! python3 - "$directory/launch.json.launcher.json" <<'PY'
import json,pathlib,sys
r=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert r['ownedExitConfirmed'] is True
PY
  then
    blocked="Owned application exit was not confirmed after $strategy; later processes were not launched"
  fi
done
python3 scripts/check-manual-hash-comparison.py matrix "$root" "$expected" --suite "$suite" > "$root/comparison.json"
echo "All ${#strategies[@]} cells in $suite completed comparable full-workload diagnostic observations"
