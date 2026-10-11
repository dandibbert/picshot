#!/bin/bash
# Qualify the live session from the exact shipped ZIP in fresh owned processes.
set -euo pipefail
cd -P "$(dirname "$0")/.."
test "$#" -eq 3
archive="$1"
evidence="$2"
source_sha="$3"
mkdir -p "$evidence" dist
evidence=$(cd "$evidence" && pwd -P)
work=$(mktemp -d "$PWD/dist/live-scroll-installed.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
ditto -x -k "$archive" "$work"
app="$work/PicShot.app"
codesign --verify --deep --strict "$app"
python3 - "$app" "$archive" "$evidence/package-identity.json" "$source_sha" <<'PY'
import hashlib,json,os,pathlib,platform,plistlib,subprocess,sys
app,archive,output=map(pathlib.Path,sys.argv[1:4]); source=sys.argv[4]
if str(app.resolve())!=str(app): raise ValueError('Installed application path is not canonical')
info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
build=json.loads((app/'Contents/Resources/build-info.json').read_text())
expected_build=os.environ.get('GITHUB_RUN_NUMBER')
actual_arch=subprocess.check_output(['lipo','-archs',str(app/'Contents/MacOS/PicShot')],text=True,timeout=10).strip()
if not (info['PicShotSourceCommit']==build['sourceCommit']==source
        and info['CFBundleShortVersionString']==build['version']=='0.22.0'
        and expected_build is not None and info['CFBundleVersion']==expected_build
        and info['CFBundleExecutable']=='PicShot'
        and build['architecture']==actual_arch==platform.machine()):
    raise ValueError('Installed source/version/build/executable/architecture differs')
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
output.write_text(json.dumps(dict(status='passed',sourceCommit=source,
    bundlePath=str(app),executablePath=str(app/'Contents/MacOS/PicShot'),
    executableSHA256=sha(app/'Contents/MacOS/PicShot'),archiveSHA256=sha(archive),
    version=build['version'],build=info['CFBundleVersion'],architecture=platform.machine()),indent=2)+'\n')
PY
mkdir -p "$evidence/demo"
PICSHOT_LIVE_SCROLL_DEMO_ONLY=1 \
PICSHOT_LIVE_SCROLL_TARGET="$PWD/.build/LiveScrollTarget.app/Contents/MacOS/LiveScrollTarget" \
python3 scripts/run-bounded-command.py --timeout-seconds 660 --grace-seconds 10 \
  --log "$evidence/demo-launch.log" --report "$evidence/demo-launch.json" \
  -- swift scripts/launch-smoke-app.swift "$app" "$evidence/demo/demo.json"
python3 - "$evidence" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]); identity=json.loads((root/'package-identity.json').read_text())
r=json.loads((root/'demo/demo.json').read_text())
launch=json.loads((root/'demo/demo.json.launcher.json').read_text())
if not (r['status']=='passed' and r['sourceCommit']==identity['sourceCommit']
        and r['bundlePath']==identity['bundlePath'] and r['version']==identity['version']
        and str(r['build'])==str(identity['build'])):
    raise ValueError('Installed demonstration result identity differs')
if not (launch['status']=='exited' and launch['launcherExitCode']==0
        and launch['ownedExitConfirmed'] is True and launch['launchedIdentityMatches'] is True
        and launch['selectedAppPath']==launch['launchedAppPath']==identity['bundlePath']
        and launch['launchedExecutablePath']==identity['executablePath']
        and launch['timeoutSeconds']==600 and launch['callbackReceived'] is True):
    raise ValueError('Installed demonstration lifecycle is incomplete')
if r['globalInputPosted'] is not False: raise ValueError('Unexpected global input')
for name in ('illustratedCase','ordinaryTextCase','movementCase'):
    case=r[name]
    comparison=case['referenceComparison' if name=='movementCase' else 'nativeReferenceComparison']
    callbacks=case['finishCallbacks' if name=='movementCase' else 'finishButtonCompletionCallbacks']
    if not (case['status']=='passed' and case['productSessionClosed'] is True
            and callbacks==1 and comparison['passed'] is True
            and comparison['dimensionsMatch'] is True
            and comparison['meanAbsoluteRGBAError']<=0.5
            and comparison['fractionOfChannelsDifferingByMoreThan8']<=0.001):
        raise ValueError('Installed demonstration output or ownership failed: '+name)
PY
bash scripts/run-live-scroll-resource.sh "$app" "$evidence/resource" "$source_sha"
