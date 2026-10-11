#!/bin/bash
set -euo pipefail
if [ "$#" -ne 3 ]; then
  echo "Usage: live-scroll-png-pair.sh EXACT_APP FRESH_EVIDENCE SOURCE_SHA" >&2
  exit 64
fi
pair_app="$1"
pair_root="$2"
pair_source="$3"
pair_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -e "$pair_root" ]; then
  echo "Paired evidence directory must not already exist" >&2
  exit 1
fi
mkdir -p "$pair_root"
pair_root="$(cd "$pair_root" && pwd -P)"
# Deliberately continue after a failed control. Each cell retains its own failed
# qualification, bounded launcher receipts and independent ten-output checks.
for pair_backend in foundation posix; do
  pair_code=0
  bash "$pair_repo/scripts/run-live-scroll-resource.sh" "$pair_app" "$pair_root/$pair_backend" "$pair_source" "$pair_backend" || pair_code=$?
  printf '%s\n' "$pair_code" > "$pair_root/$pair_backend-exit-code.txt"
done
python3 -I "$pair_repo/scripts/compare-live-scroll-png-pair.py" "$pair_root" "$pair_source"
