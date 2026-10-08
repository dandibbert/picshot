#!/bin/bash
# Derive an app-only package driver; never edit the production package script.
set -euo pipefail
picshot_root="$(cd "$(dirname "$0")/.." && pwd)"
picshot_driver="$(mktemp "$picshot_root/scripts/.package-callout-retirement.XXXXXX")"
trap 'rm -f "$picshot_driver"' EXIT
python3 - "$picshot_root/scripts/package.sh" "$picshot_driver" <<'PY'
import hashlib
from pathlib import Path
import sys
source, destination = map(Path, sys.argv[1:])
text = source.read_text()
needle = 'swift build -c release'
if text.count(needle) != 2: raise ValueError('Review package script changes before deriving diagnostic build')
derived = text.replace(needle, needle + ' -Xswiftc -DPICSHOT_CALLOUT_RETIREMENT_DIAGNOSTICS')
if 'PICSHOT_PACKAGE_APP_ONLY' not in text: raise ValueError('App-only package exit missing')
print('Original package driver SHA256', hashlib.sha256(text.encode()).hexdigest())
print('Derived diagnostic driver SHA256', hashlib.sha256(derived.encode()).hexdigest())
destination.write_text(derived)
PY
# The original driver contains legacy assert checks; keep those enabled too.
unset PYTHONOPTIMIZE
export PICSHOT_PACKAGE_APP_ONLY=1
bash "$picshot_driver"
