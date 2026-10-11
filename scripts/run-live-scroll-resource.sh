#!/bin/bash
set -euo pipefail

# Private qualification wrapper. The caller supplies the exact installed ZIP app.
# No build, package discovery, workflow mutation, upload or installer promotion.
if [ "$#" -ne 3 ]; then
  echo "Usage: run-live-scroll-resource.sh EXACT_INSTALLED_APP EVIDENCE_DIR SOURCE_SHA" >&2
  exit 64
fi
resource_app="$1"
resource_evidence="$2"
resource_source="$3"
resource_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$resource_evidence"
resource_evidence="$(cd "$resource_evidence" && pwd)"
for resource_reserved in input certify measure upload review-output review-reference resource-wrapper.json; do
  if [ -e "$resource_evidence/$resource_reserved" ]; then
    echo "Resource evidence is not fresh: $resource_reserved already exists" >&2
    exit 1
  fi
done
resource_phase="identity"
trap 'resource_code=$?; if [ "$resource_code" -ne 0 ]; then python3 -I - "$resource_evidence" "$resource_phase" "$resource_code" <<'"'"'PY'"'"'
import json, pathlib, shutil, sys
root=pathlib.Path(sys.argv[1])
try: report=json.loads((root/"resource-wrapper.json").read_text())
except (ValueError,OSError): report={}
report.update(status="failed-or-incomplete",phase=sys.argv[2],exitCode=int(sys.argv[3]),installerAcceptance=False)
for item in [root/"measure"/"live-scroll-resource-measurement.json", root/"measure"/"live-scroll-resource-validation.json"]:
    if item.is_file():
        try: report[item.name+"Status"]=json.loads(item.read_text()).get("status")
        except (ValueError, OSError): pass
(root/"resource-wrapper.json").write_text(json.dumps(report,indent=2)+"\n")
compact=root/"upload"; compact.mkdir(exist_ok=True)
for phase in ["certify","measure"]:
    if (root/phase).is_dir():
        for item in (root/phase).glob("*.json"): shutil.copy2(item,compact/(phase+"-"+item.name))
if (root/"input/certificate.json").is_file(): shutil.copy2(root/"input/certificate.json",compact/"input-certificate.json")
shutil.copy2(root/"resource-wrapper.json",compact/"resource-wrapper.json")
PY
fi' EXIT

python3 -I - "$resource_app" "$resource_source" "$resource_evidence" <<'PY'
import hashlib,json,pathlib,plistlib,re,sys
app=pathlib.Path(sys.argv[1]).resolve(strict=True)
sha=sys.argv[2]
if not re.fullmatch(r"[0-9a-f]{40}",sha): raise SystemExit("Invalid expected source SHA")
with (app/"Contents/Info.plist").open("rb") as f: info=plistlib.load(f)
if info.get("PicShotSourceCommit")!=sha: raise SystemExit("Exact installed app source stamp mismatch")
binary=app/"Contents/MacOS/PicShot"
digest=hashlib.file_digest(binary.open("rb"),"sha256").hexdigest() if hasattr(hashlib,"file_digest") else hashlib.sha256(binary.read_bytes()).hexdigest()
report={"status":"running","exactInstalledApp":str(app),"sourceCommit":sha,"executableSHA256":digest,"installerAcceptance":False}
(pathlib.Path(sys.argv[3])/"resource-wrapper.json").write_text(json.dumps(report,indent=2)+"\n")
PY

unset PICSHOT_LIVE_SCROLL_DEMO_ONLY PICSHOT_LIVE_SCROLL_TARGET
mkdir -p "$resource_evidence/certify" "$resource_evidence/measure"
if [ -e "$resource_evidence/input/fixture.bgra" ]; then
  echo "Resource input already exists; use a fresh evidence directory" >&2
  exit 1
fi

verify_resource_launch() {
  python3 -I - "$1" "$resource_app" "$2" "$3" "$resource_evidence/resource-wrapper.json" <<'PY'
import json,pathlib,sys
summary=pathlib.Path(sys.argv[1]); app=pathlib.Path(sys.argv[2]).resolve(strict=True)
expected=json.loads(pathlib.Path(sys.argv[5]).read_text())
receipt=json.loads(pathlib.Path(str(summary)+".launcher.json").read_text())
assert receipt.get("status")=="exited" and receipt.get("launcherExitCode")==0,receipt
assert receipt.get("ownedExitConfirmed") is True and receipt.get("callbackReceived") is True,receipt
assert receipt.get("createsNewApplicationInstance") is True and receipt.get("launchedIdentityMatches") is True,receipt
assert receipt.get("selectedAppPath")==str(app) and receipt.get("launchedAppPath")==str(app),receipt
assert receipt.get("launchedExecutablePath")==str((app/"Contents/MacOS/PicShot").resolve()),receipt
assert receipt.get("timeoutSeconds")==600,receipt
assert summary.is_file(),"Owned app exited without its result"
result=json.loads(summary.read_text())
assert result.get("mode")==sys.argv[3] and result.get("status")==sys.argv[4],result
assert result.get("sourceCommit")==expected["sourceCommit"] and result.get("executableSHA256")==expected["executableSHA256"],result
assert result.get("processIdentifier")==receipt.get("processIdentifier"),"Current result PID differs from owned launched app"
PY
}

resource_phase="certify"
PICSHOT_LIVE_SCROLL_RESOURCE_MODE=certify \
PICSHOT_LIVE_SCROLL_RESOURCE_INPUT="$resource_evidence/input" \
swift "$resource_repo/scripts/launch-smoke-app.swift" "$resource_app" "$resource_evidence/certify/summary.json"
verify_resource_launch "$resource_evidence/certify/summary.json" certify passed
python3 -I - "$resource_evidence/certify/summary.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); assert r.get("status")=="passed", r
PY

resource_phase="measure"
PICSHOT_LIVE_SCROLL_RESOURCE_MODE=measure \
PICSHOT_LIVE_SCROLL_RESOURCE_INPUT="$resource_evidence/input" \
swift "$resource_repo/scripts/launch-smoke-app.swift" "$resource_app" "$resource_evidence/measure/summary.json"
verify_resource_launch "$resource_evidence/measure/summary.json" measure measured-awaiting-pixel-validation
python3 -I - "$resource_evidence/measure/live-scroll-resource-measurement.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); assert r.get("status")=="measured-awaiting-pixel-validation", r
assert len(r.get("cycles",[]))==10, "Fixed 2+8 workload incomplete"
PY

resource_phase="validate"
PICSHOT_LIVE_SCROLL_RESOURCE_MODE=validate \
PICSHOT_LIVE_SCROLL_RESOURCE_INPUT="$resource_evidence/input" \
swift "$resource_repo/scripts/launch-smoke-app.swift" "$resource_app" "$resource_evidence/measure/validation-summary.json"
verify_resource_launch "$resource_evidence/measure/validation-summary.json" validate passed
python3 -I - "$resource_evidence" <<'PY'
import json,pathlib,shutil,sys
root=pathlib.Path(sys.argv[1]); result=json.loads((root/"measure/live-scroll-resource-validation.json").read_text())
assert result.get("status")=="passed",result
assert len(result.get("outputCertificates",[]))==10,"Ten exact PNG certificates required"
report=json.loads((root/"resource-wrapper.json").read_text())
report.update(status="passed",phase="validated",outputCertificates=10,measurement="measure/live-scroll-resource-measurement.json",validation="measure/live-scroll-resource-validation.json")
compact=root/"upload"; compact.mkdir()
for phase in ["certify","measure"]:
    for item in (root/phase).glob("*.json"):
        shutil.copy2(item,compact/(phase+"-"+item.name))
shutil.copy2(root/"input/certificate.json",compact/"input-certificate.json")
review=[]
for name,source in [("review-output",root/"measure/cycle-10.png"),("review-reference",root/"certify/expected-reference.png")]:
    target=root/name; target.mkdir(); shutil.copy2(source,target/source.name)
    size=source.stat().st_size
    review.append({"directory":name,"file":source.name,"bytes":size,"under32MiB":size<32*1024*1024})
report["reviewEvidence"]=review; report["compactEvidenceDirectory"]="upload"
report["bulkEvidenceRetainedOnRunner"]=["input/fixture.bgra","measure/cycle-01.png through cycle-10.png"]
(root/"resource-wrapper.json").write_text(json.dumps(report,indent=2)+"\n")
shutil.copy2(root/"resource-wrapper.json",compact/"resource-wrapper.json")
PY
