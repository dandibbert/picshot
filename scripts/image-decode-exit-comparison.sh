#!/bin/bash
# Explicit diagnostic only. Keeps both fresh-process arms and unchanged defaults.
set -euo pipefail
if [[ $# -ne 3 || ( "$1" != --compare && "$1" != --finish ) ]]; then
  echo 'Usage: image-decode-exit-comparison.sh {--compare|--finish} /absolute/PicShot.app /absolute/evidence-directory' >&2
  exit 64
fi
cd "$(dirname "$0")/.."
mode="$1"; app="$2"; root="$3"
[[ "$app" == /* && "$root" == /* && "$app" == *.app ]] || exit 64
[[ "$(uname -s)" == Darwin ]] || exit 69
architecture=$(uname -m)
[[ "$architecture" == arm64 || "$architecture" == x86_64 ]] || exit 69
if [[ "$mode" == --compare ]]; then
  [[ ! -e "$root" ]] || exit 64
  mkdir -p "$(dirname "$root")"
  mkdir "$root"
  bash scripts/image-decode-large-attribution.sh --timing-v3 "$app" "$root/wait-until-exit"
  bash scripts/image-decode-large-attribution.sh --termination-latch "$app" "$root/termination-latch"
else
  [[ -d "$root" && ! -L "$root" && -d "$root/wait-until-exit" && -d "$root/termination-latch" ]] || exit 64
fi
# Separate one-shot probes never alter the two-warmup/twelve-cycle measurements.
mkdir "$root/probes"
for mode in cancel-after-decode timeout-after-decode; do
  PICSHOT_IMAGE_DECODE_LARGE_TIMING=3 PICSHOT_IMAGE_DECODE_LARGE_EXIT=termination-latch \
    swift scripts/launch-image-decode-large.swift "$app" "$mode" 5k "$root/probes/$mode" "$root/termination-latch/prepared-5k"
done
source_commit=$(/usr/libexec/PlistBuddy -c 'Print :PicShotSourceCommit' "$app/Contents/Info.plist")
[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || exit 65
python3 scripts/check-image-decode-exit-report.py "$root" "$source_commit" "$architecture"
