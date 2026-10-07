#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
ditto -x -k "dist/PicShot-0.10.0-macos-$(uname -m).zip" "$work"
app="$work/PicShot.app"
codesign --verify --deep --strict "$app"
mkdir -p dist/evidence/recording-recovery
python3 - "$app" "$PWD/dist/evidence/recording-recovery" "$(git rev-parse HEAD)" <<'PY'
import json, os, pathlib, signal, subprocess, sys
app=pathlib.Path(sys.argv[1]).resolve(); destination=pathlib.Path(sys.argv[2]).resolve()
report=destination/'recovery.json'; log=destination/'fixture.log'
env=os.environ.copy()
for key in list(env):
    if key.startswith('PICSHOT_SMOKE_') or key in ['PICSHOT_UI_PREVIEW_ONLY','PICSHOT_GIF_DIAGNOSTIC_MODE','PICSHOT_GIF_EXTRACTION','PICSHOT_GIF_EXECUTION']:
        env.pop(key)
env['PICSHOT_RECOVERY_FIXTURE_MODE']='verify'
env['PICSHOT_RECOVERY_FIXTURE_REPORT']=str(report)
# This is a dedicated, permission-free media fixture, not the normal app-startup
# test. ZIP/DMG LaunchServices launches are independently required by smoke.sh.
with log.open('wb') as output:
    process=subprocess.Popen([str(app/'Contents/MacOS/PicShot')],env=env,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
    try:
        code=process.wait(timeout=180)
    except subprocess.TimeoutExpired:
        # Only the process group created by this invocation is in scope. The
        # fixture's child inherits that group; no app/user process is targeted.
        if process.poll() is None:
            os.killpg(process.pid,signal.SIGTERM)
            try: process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid,signal.SIGKILL); process.wait(timeout=5)
        raise RuntimeError('Owned recovery fixture exceeded 180 seconds; no recovery pass is claimed')
assert code==0, log.read_text(errors='replace')[-32000:]
r=json.loads(report.read_text())
assert r['status']=='passed' and r['sourceCommit']==sys.argv[3],r
assert pathlib.Path(r['bundlePath']).resolve()==app,r
assert r['killedOwnProcess'] and r['terminationSignal']==signal.SIGKILL and r['ownChildExitConfirmed'],r
assert r['discoveredCaptures']==1 and r['fragmentCount']>0,r
assert r['decodedVideoFrames']>0 and r['decodedAudioFrames']>0 and r['recoveredDuration']>0,r
assert r['sourceUnchanged'] and r['previewJournalRecovered'] and r['temporaryDirectoryRemoved'],r
for key in ['captureStarted','cameraStarted','microphoneStarted']:
    assert r[key] is False,r
print(json.dumps(r,indent=2))
PY
