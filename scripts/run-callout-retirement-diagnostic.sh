#!/bin/bash
# One full early-UI invocation. The existing launcher owns its 600 s app deadline.
set -euo pipefail
if [[ "$#" != 2 ]]; then
  echo "Usage: run-callout-retirement-diagnostic.sh APP NEW_OUTPUT_DIRECTORY" >&2
  exit 64
fi
picshot_root="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$picshot_root" "$1" "$2" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
root, app, output = (Path(p).resolve() for p in sys.argv[1:])
if not app.is_dir() or not (app / 'Contents/MacOS/PicShot').is_file(): raise ValueError('Diagnostic app missing')
output.mkdir(parents=True, exist_ok=False)
(output / 'ui').mkdir()
# Explicitly remove inherited fixture selectors, including newly forwarded
# multi-window switches. Keep the standard runtime environment intact.
env = {key: value for key, value in os.environ.items() if not key.startswith('PICSHOT_')}
env['PICSHOT_UI_PREVIEW_ONLY'] = '1'
env['PICSHOT_CALLOUT_RETIREMENT_DIAGNOSTIC_PATH'] = str(output / 'retirement-sidecar.json')
identity = {
    'purpose': 'one diagnostic early-UI execution, not installer acceptance',
    'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
    'appPath': str(app), 'executableSHA256': hashlib.sha256((app / 'Contents/MacOS/PicShot').read_bytes()).hexdigest(),
    'architecture': subprocess.check_output(['uname', '-m'], text=True).strip(),
    'macOS': subprocess.check_output(['sw_vers'], text=True).strip(),
    'swift': subprocess.check_output(['swift', '--version'], text=True).strip(),
    'fixtureEnvironment': {key: value for key, value in env.items() if key.startswith('PICSHOT_')},
    'expectedCycles': 6, 'nativeDeadlineMilliseconds': 2000, 'maximumSamples': 256,
    'launcherDeadlineSeconds': 600, 'executionsRequested': 1,
}
(output / 'identity.json').write_text(json.dumps(identity, indent=2) + '\n')
command = ['swift', '-D', 'PICSHOT_CALLOUT_RETIREMENT_DIAGNOSTICS', str(root / 'scripts/launch-smoke-app.swift'), str(app), str(output / 'ui/preview.json')]
completed = subprocess.run(command, cwd=root, env=env)
(output / 'launcher-exit.json').write_text(json.dumps({'launcherExitCode': completed.returncode,
    'scope': 'Launcher exit is not the original gate result; read ui/preview.json and callout evidence'}, indent=2) + '\n')
sys.exit(completed.returncode)
PY
