#!/bin/bash
# Opt-in installed-product observation. Independent outputs are checked after exit.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -eq 3 ]] || { echo 'Usage: editable-product-resource.sh ABS_APP ABS_FRESH_ROOT EXPECTED_SOURCE' >&2; exit 64; }
app="$1"; root="$2"; expected="$3"
[[ "$app" == /* && "$root" == /* && ! -e "$root" && ! -L "$root" && "$expected" =~ ^[0-9a-f]{40}$ ]] || exit 64
[[ "$(uname -s)" == Darwin ]] || { echo 'This fixture requires an installed macOS app and native display' >&2; exit 64; }
python3 - "$app" "$root" <<'PY'
import pathlib,sys
for value in sys.argv[1:]:
    p=pathlib.Path(value)
    if str(p.resolve()) != value: raise ValueError('Noncanonical or linked path')
app,root=map(pathlib.Path,sys.argv[1:])
if root == app or app in root.parents: raise ValueError('Evidence overlaps app')
PY
codesign --verify --deep --strict "$app"
mkdir -p "$(dirname "$root")"
mkdir "$root"
launch_component() {
  local mode="$1"
  mkdir "$root/$mode"
  (
    export PICSHOT_EDITABLE_COMPONENT_MODE="$mode"
    unset PICSHOT_EDITABLE_COMPONENT_INPUT PICSHOT_EDITABLE_COMPONENT_CERTIFICATE PICSHOT_EDITABLE_COMPONENT_WRITES
    if [[ "$mode" == certify ]]; then export PICSHOT_EDITABLE_COMPONENT_INPUT="$root/prepare"; fi
    python3 scripts/run-bounded-command.py --timeout-seconds 620 --grace-seconds 5 --max-log-bytes 2097152 \
      --log "$root/$mode/launcher.log" --report "$root/$mode/command.json" \
      -- swift scripts/launch-editable-component.swift "$app" "$root/$mode/launch.json"
  )
}
launch_product() {
  local mode="$1"; local directory="$2"; local certificate="$3"; local drawing="${4:-}"
  mkdir "$root/$directory"
  (
    export PICSHOT_EDITABLE_PRODUCT_MODE="$mode"
    export PICSHOT_EDITABLE_PRODUCT_INPUT="$root/prepare"
    export PICSHOT_EDITABLE_PRODUCT_CERTIFICATE="$root/$certificate"
    unset PICSHOT_DRAWING_RASTER_STRATEGY
    if [[ -n "$drawing" ]]; then export PICSHOT_DRAWING_RASTER_STRATEGY="$drawing"; fi
    python3 scripts/run-bounded-command.py --timeout-seconds 620 --grace-seconds 5 --max-log-bytes 2097152 \
      --log "$root/$directory/launcher.log" --report "$root/$directory/command.json" \
      -- swift scripts/launch-editable-product.swift "$app" "$root/$directory/launch.json"
  )
}
launch_component prepare
launch_component certify
python3 scripts/check-editable-components.py --app "$app" --expected-source "$expected" --root "$root" --stage certify --output "$root/component-certification-check.json"
launch_product certify product-certify certify/component.json
python3 scripts/check-editable-product-resource.py --app "$app" --expected-source "$expected" --root "$root" --stage certify --output "$root/product-certification-check.json"
# Compile outside every measured application process; preserve helper identity.
mkdir "$root/verification"
python3 scripts/run-bounded-command.py --timeout-seconds 120 --grace-seconds 5 --max-log-bytes 2097152 \
  --log "$root/verification/compile.log" --report "$root/verification/compile-command.json" \
  -- swiftc scripts/verify-editable-product-pixels.swift -o "$root/verification/pixel-verifier"
for cell in baseline candidate; do
  drawing=reference
  if [[ "$cell" == candidate ]]; then drawing=owned-srgb8; fi
  launch_product measure "$cell" product-certify/product-certificate.json "$drawing"
done
# Keep native decoder graphics work outside the interval between measured cells.
for cell in baseline candidate; do
  mkdir "$root/$cell/verification"
  # Exact owned exit is checked before any evidence is decoded.
  python3 scripts/check-editable-product-resource.py --app "$app" --expected-source "$expected" --root "$root" --stage preflight --cell "$cell" --output "$root/$cell/verification/preflight.json"
  python3 scripts/run-bounded-command.py --timeout-seconds 300 --grace-seconds 5 --max-log-bytes 2097152 \
    --log "$root/$cell/verification/decoder.log" --report "$root/$cell/verification/decoder-command.json" \
    -- "$root/verification/pixel-verifier" "$root/$cell/verification/pixel-plan.json" "$root/$cell/verification/pixel-report.json"
done
python3 scripts/check-editable-product-resource.py --app "$app" --expected-source "$expected" --root "$root" --stage complete --output "$root/checked-product-resource.json"
