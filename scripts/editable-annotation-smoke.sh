#!/bin/bash
# Fresh installed process; resource completion never means a plateau or zero leaks.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -eq 3 || $# -eq 4 ]] || exit 64
app="$1"; root="$2"; expected="$3"; mode="${4:-functional}"
[[ "$app" == /* && "$root" == /* && ! -e "$root" && "$expected" =~ ^[0-9a-f]{40}$ ]] || exit 64
[[ "$mode" == functional || "$mode" == resources ]] || exit 64
codesign --verify --deep --strict "$app"
mkdir -p "$(dirname "$root")"
mkdir "$root"
launch_status=0
(
  unset PICSHOT_MULTIWINDOW_RESOURCES_ONLY PICSHOT_RECORDING_COMPOSITION_ONLY PICSHOT_RECORDING_COMPOSITION_TRACE
  unset PICSHOT_MANUAL_SCROLL_ONLY PICSHOT_MANUAL_SCROLL_RESOURCES PICSHOT_ANNOTATION_DETAILS_ONLY
  unset PICSHOT_AUTOMATIC_MOSAIC_ONLY PICSHOT_PIN_GROUP_TRANSFORMS_ONLY PICSHOT_LATEX_PIN_VERIFY
  unset PICSHOT_PIN_DESKTOP_VISIBILITY_ONLY PICSHOT_UI_PREVIEW_ONLY PICSHOT_SMOKE_GIF_RESOURCES
  unset PICSHOT_GIF_DIAGNOSTIC_MODE PICSHOT_CODEC_ATTRIBUTION_MODE PICSHOT_IMAGE_BACKING_MODE PICSHOT_SCROLL_ATTRIBUTION_MODE
  export PICSHOT_EDITABLE_ANNOTATIONS_ONLY=1
  if [[ "$mode" == resources ]]; then export PICSHOT_EDITABLE_ANNOTATION_RESOURCES=1
  else unset PICSHOT_EDITABLE_ANNOTATION_RESOURCES
  fi
  swift scripts/launch-smoke-app.swift "$app" "$root/launch.json"
) > "$root/launcher.log" 2>&1 || launch_status=$?
python3 - "$root" "$app" "$expected" "$mode" "$launch_status" <<'PY'
import importlib.util
import json
from pathlib import Path
import sys
root, app, source, mode, launch_status = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4], int(sys.argv[5])
spec = importlib.util.spec_from_file_location('editable_checker', Path('scripts/check-editable-annotation-report.py'))
checker = importlib.util.module_from_spec(spec); spec.loader.exec_module(checker)
result = {'status': 'failed', 'memoryStabilityAssessed': False, 'zeroLeakClaim': False, 'sourceCommit': source}
try:
    lifecycle = checker.read_report(root / 'launch.json.launcher.json')
    checker.need(launch_status == 0 and lifecycle['status'] == 'exited' and lifecycle['ownedExitConfirmed'] is True,
                 'owned installed process did not finish')
    checker.need(lifecycle['createsNewApplicationInstance'] is True and lifecycle['callbackReceived'] is True,
                 'fresh owned launch not established')
    checker.need(Path(lifecycle['launchedAppPath']).resolve() == app.resolve(), 'wrong installed app launched')
    pid = checker.integer(lifecycle['processIdentifier'], 1, 2**31 - 1)
    report_path = root / 'editable-annotation-native.json'
    report = checker.read_report(report_path)
    result.update(checker.validate(report, checker.bundle_identity(app, source), mode == 'resources', pid, root))
    checker.need(result['visualFilesVerified'] is True, 'native visual files were not verified')
    result['ownedExitConfirmed'] = True
    result['reportSHA256'] = checker.hashlib.sha256(report_path.read_bytes()).hexdigest()
    if mode == 'resources':
        result['entryToBeforeWarmupDeltaBytes'] = checker.delta(report['entryMemory'], report['resources']['beforeWarmup'])
        result['entryToAfterWarmupDeltaBytes'] = checker.delta(report['entryMemory'], report['resources']['afterWarmupBaseline'])
        result['afterWarmupToMeasuredDeltaBytes'] = report['resources']['afterWarmupToMeasuredDeltaBytes']
        result['lateMeasuredIncrements'] = report['resources']['lateMeasuredIncrements']
        result['afterWarmupToFinalCleanupDeltaBytes'] = checker.delta(report['resources']['afterWarmupBaseline'], report['finalMemory'])
        result['measuredToFinalCleanupDeltaBytes'] = checker.delta(report['resources']['afterMeasuredCycles'], report['finalMemory'])
    result['sampledPeakBytes'] = report['sampledMemory']['total']['sampledPeakBytes']
    shots = report['functionalCases'][0]['visualEvidence']
    result['functionalSnapshotObservedPeakBytes'] = {field: max(shot['whileSnapshotLiveMemory']['counters'][field] for shot in shots) for field in checker.MEMORY}
except Exception as error:
    result['error'] = str(error)[:4096]
finally:
    (root / 'checked-editable-annotation.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
sys.exit(0 if result['status'] == 'passed' else 1)
PY
