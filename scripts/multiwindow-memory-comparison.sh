#!/bin/bash
# Diagnostic-only fresh processes; no installer publication or stability verdict.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -eq 3 ]] || exit 64
app="$1"; root="$2"; expected="$3"
[[ "$app" == /* && "$root" == /* && ! -e "$root" && "$expected" =~ ^[0-9a-f]{40}$ ]] || exit 64
mkdir -p "$(dirname "$root")"
mkdir "$root"
allow_candidate="${PICSHOT_MULTIWINDOW_ALLOW_CANDIDATE:-1}"
[[ "$allow_candidate" == 0 || "$allow_candidate" == 1 ]] || exit 64
for profile in baseline tail-first baseline-traced tail-first-traced candidate candidate-traced;do
  mode=coreGraphicsBaseline; tail_first=0; boundaries=0
  case "$profile" in candidate*) mode=normalizedCandidate;; esac
  case "$profile" in tail-first*) tail_first=1;; esac
  case "$profile" in *-traced) boundaries=1;; esac
  status=0
  if [[ "$mode" == normalizedCandidate && "$allow_candidate" == 0 ]];then
    status=125
  else
    PICSHOT_MULTIWINDOW_DIAGNOSTIC_TAIL_FIRST="$tail_first" \
    PICSHOT_MULTIWINDOW_DIAGNOSTIC_BOUNDARIES="$boundaries" \
      bash scripts/multiwindow-resource-smoke.sh "$app" "$root/$profile" "$expected" "$mode" || status=$?
  fi
  python3 - "$root" "$profile" "$status" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1])/'cell-outcomes.json'
rows=json.loads(p.read_text()) if p.exists() else []
code=int(sys.argv[3])
rows.append(dict(profile=sys.argv[2],exitCode=code,status='skipped' if code==125 else 'exited',
                 reason='Native exact-pixel gate did not pass' if code==125 else None))
p.write_text(json.dumps(rows,indent=2)+'\n')
PY
done
python3 scripts/check-multiwindow-memory-comparison.py "$root" "$expected"
