#!/bin/bash
# Same binary, separate owned native launches; never a product-memory acceptance gate.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -eq 4 ]] || { echo 'Usage: editable-observation-diagnostic.sh APP EVIDENCE_ROOT EXPECTED_SOURCE functional-comparison|candidate-resources' >&2; exit 64; }
app="$1"; root="$2"; expected="$3"; stage="$4"
[[ "$app" == /* && "$root" == /* && "$expected" =~ ^[0-9a-f]{40}$ ]] || exit 64
[[ "$stage" == functional-comparison || "$stage" == candidate-resources ]] || exit 64
if [[ "$stage" == functional-comparison ]]; then
  [[ ! -e "$root" ]] || { echo 'Evidence root already exists; preserve it and choose a fresh root' >&2; exit 64; }
  mkdir -p "$(dirname "$root")"
  mkdir "$root"
  PICSHOT_EDITABLE_HASH_DIAGNOSTIC=certify bash scripts/editable-annotation-smoke.sh "$app" "$root/certification" "$expected" functional
  python3 scripts/check-editable-observation-comparison.py --app "$app" --expected-source "$expected" \
    --certification "$root/certification" --output "$root/certification-check.json"
  PICSHOT_EDITABLE_HASH_DIAGNOSTIC=cgcontext bash scripts/editable-annotation-smoke.sh "$app" "$root/baseline" "$expected" functional
  PICSHOT_EDITABLE_HASH_DIAGNOSTIC=vimage bash scripts/editable-annotation-smoke.sh "$app" "$root/candidate" "$expected" functional
  python3 scripts/check-editable-observation-comparison.py --app "$app" --expected-source "$expected" \
    --certification "$root/certification" --baseline "$root/baseline" --candidate "$root/candidate" --output "$root/comparison.json"
else
  [[ -d "$root" && ! -e "$root/candidate-resources" ]] || exit 64
  # Revalidate the raw, source-bound certificate and both unchanged functional arms.
  python3 scripts/check-editable-observation-comparison.py --app "$app" --expected-source "$expected" \
    --certification "$root/certification" --baseline "$root/baseline" --candidate "$root/candidate" --output "$root/pre-resource-comparison.json"
  PICSHOT_EDITABLE_HASH_DIAGNOSTIC=vimage bash scripts/editable-annotation-smoke.sh "$app" "$root/candidate-resources" "$expected" resources
  python3 scripts/check-editable-observation-comparison.py --app "$app" --expected-source "$expected" \
    --certification "$root/certification" --baseline "$root/baseline" --candidate "$root/candidate" \
    --candidate-resources "$root/candidate-resources" --output "$root/comparison-with-candidate-resources.json"
fi
