#!/bin/bash
set -euo pipefail

# One private cell only. The outer paired experiment owns running both backends.
# Complete memory failures still receive a fresh all-output pixel verification.
if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
  echo "Usage: run-live-scroll-resource.sh EXACT_INSTALLED_APP EVIDENCE_DIR SOURCE_SHA [foundation|posix]" >&2
  exit 64
fi
resource_app="$1"
resource_evidence="$2"
resource_source="$3"
resource_backend="${4:-foundation}"
case "$resource_backend" in foundation|posix) ;; *) echo "Unknown PNG writer backend" >&2; exit 64 ;; esac
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

preserve_resource_evidence() {
  python3 -I - "$resource_evidence" "$resource_phase" "$1" <<'PY'
import hashlib,json,pathlib,shutil,sys
root=pathlib.Path(sys.argv[1]); code=int(sys.argv[3])
try: report=json.loads((root/"resource-wrapper.json").read_text())
except (ValueError,OSError): report={}
if code and report.get("status")!="failed": report["status"]="failed-or-incomplete"
report.update(phase=sys.argv[2],exitCode=code,installerAcceptance=False)
for name in ["measurement","validation"]:
    path=root/"measure"/("live-scroll-resource-"+name+".json")
    if path.is_file():
        try: report[name+"ReportStatus"]=json.loads(path.read_text()).get("status")
        except (ValueError,OSError): pass
compact=root/"upload"; compact.mkdir(exist_ok=True)
for phase in ["certify","measure"]:
    if (root/phase).is_dir():
        for item in (root/phase).glob("*.json"): shutil.copy2(item,compact/(phase+"-"+item.name))
if (root/"input/certificate.json").is_file(): shutil.copy2(root/"input/certificate.json",compact/"input-certificate.json")
# Preserve one completed recipient PNG even after a memory gate or later failure.
chosen=None
for phase,name in [("measure","live-scroll-resource-measurement.json"),("certify","live-scroll-resource-certificate-run.json")]:
    try: cell=json.loads((root/phase/name).read_text())
    except (ValueError,OSError): continue
    for cycle in reversed(cell.get("cycles",[])):
        output=cycle.get("output",{}); filename=output.get("file","")
        if filename!=pathlib.Path(filename).name or not filename.startswith("cycle-"): continue
        image=root/phase/filename
        if image.is_file() and output.get("encodedBytes",0)>0 and image.stat().st_size==output["encodedBytes"]:
            chosen=image; break
    if chosen: break
review=[]
for name,source in [("review-output",chosen),("review-reference",root/"certify/expected-reference.png")]:
    if source is None or not source.is_file():
        review.append({"directory":name,"available":False}); continue
    size=source.stat().st_size
    with source.open("rb") as stream:
        digest=hashlib.sha256()
        while block:=stream.read(1024*1024): digest.update(block)
    item={"directory":name,"file":source.name,"bytes":size,"sha256":digest.hexdigest(),"under32MiB":size<32*1024*1024,"available":True}
    if item["under32MiB"]:
        target=root/name; target.mkdir(exist_ok=True); shutil.copy2(source,target/source.name); item["copied"]=True
    else: item.update(copied=False,reason="Over32MiB; exact file retained on runner")
    review.append(item)
report["reviewEvidence"]=review; report["compactEvidenceDirectory"]="upload"
report["bulkEvidenceRetainedOnRunner"]=["input/fixture.bgra","measure/cycle-01.png through cycle-10.png"]
(root/"resource-wrapper.json").write_text(json.dumps(report,indent=2)+"\n")
shutil.copy2(root/"resource-wrapper.json",compact/"resource-wrapper.json")
PY
}
trap 'resource_code=$?; preserve_resource_evidence "$resource_code"' EXIT

python3 -I - "$resource_app" "$resource_source" "$resource_evidence" "$resource_backend" <<'PY'
import hashlib,json,pathlib,plistlib,re,sys
app=pathlib.Path(sys.argv[1]).resolve(strict=True); sha=sys.argv[2]
if not re.fullmatch(r"[0-9a-f]{40}",sha): raise SystemExit("Invalid expected source SHA")
with (app/"Contents/Info.plist").open("rb") as f: info=plistlib.load(f)
if info.get("PicShotSourceCommit")!=sha: raise SystemExit("Exact installed app source stamp mismatch")
with (app/"Contents/MacOS/PicShot").open("rb") as stream:
    digest=hashlib.sha256()
    while block:=stream.read(1024*1024): digest.update(block)
report={"status":"running","exactInstalledApp":str(app),"sourceCommit":sha,"executableSHA256":digest.hexdigest(),"pngWriterBackend":sys.argv[4],"installerAcceptance":False}
(pathlib.Path(sys.argv[3])/"resource-wrapper.json").write_text(json.dumps(report,indent=2)+"\n")
PY

unset PICSHOT_LIVE_SCROLL_DEMO_ONLY PICSHOT_LIVE_SCROLL_TARGET
mkdir -p "$resource_evidence/certify" "$resource_evidence/measure"
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
result=json.loads(summary.read_text())
assert result.get("mode")==sys.argv[3] and result.get("status") in sys.argv[4].split(","),result
for key in ["sourceCommit","executableSHA256","pngWriterBackend"]: assert result.get(key)==expected[key],(key,result)
assert result.get("processIdentifier")==receipt.get("processIdentifier"),"Current result PID differs from owned launched app"
PY
}

resource_phase="certify"
PICSHOT_LIVE_SCROLL_RESOURCE_MODE=certify \
PICSHOT_LIVE_SCROLL_RESOURCE_INPUT="$resource_evidence/input" \
PICSHOT_LIVE_SCROLL_PNG_WRITER="$resource_backend" \
swift "$resource_repo/scripts/launch-smoke-app.swift" "$resource_app" "$resource_evidence/certify/summary.json"
verify_resource_launch "$resource_evidence/certify/summary.json" certify passed

resource_phase="measure"
PICSHOT_LIVE_SCROLL_RESOURCE_MODE=measure \
PICSHOT_LIVE_SCROLL_RESOURCE_INPUT="$resource_evidence/input" \
PICSHOT_LIVE_SCROLL_PNG_WRITER="$resource_backend" \
swift "$resource_repo/scripts/launch-smoke-app.swift" "$resource_app" "$resource_evidence/measure/summary.json"
verify_resource_launch "$resource_evidence/measure/summary.json" measure measured-awaiting-pixel-validation,failed
python3 -I - "$resource_evidence" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]); r=json.loads((root/"measure/live-scroll-resource-measurement.json").read_text())
assert r==json.loads((root/"measure/summary.json").read_text()),"Current measurement summary/detail disagree"
assert r.get("measurementComplete") is True and r.get("measurementStatus")=="complete",r
assert (r.get("completedWarmupCycles"),r.get("completedMeasuredCycles"))==(2,8),r
cycles=r.get("cycles",[]); assert len(cycles)==10,"Fixed2+8 workload incomplete"
for ordinal,c in enumerate(cycles,1):
    assert c.get("ordinal")==ordinal and c.get("status")=="passed" and c.get("finishCallbacks")==1,c
    assert c.get("warmup") is (ordinal<=2),c
    assert c.get("pngWriterBackend")==r["pngWriterBackend"],c
    assert c.get("lastProductState",{}).get("acceptedObservations")==218,c
    assert c.get("sourceAfterStop",{}).get("successfulFrames")==218,c
memory=r.get("budgetAssessment",{}).get("warmAndLateGatesPassed"); assert type(memory) is bool,r
assert r.get("memoryGateStatus")==("passed" if memory else "failed"),r
assert r.get("status")==("measured-awaiting-pixel-validation" if memory else "failed"),r
if not memory: assert r.get("failureKind")=="memory-gates",r
cert=json.loads((root/"input/certificate.json").read_text())
for key in ["sourceCommit","executableSHA256","pngWriterBackend","inputSHA256"]: assert r.get(key)==cert.get(key),(key,r,cert)
PY

# Memory gates can be failed here. Functional/owner completeness above is mandatory.
resource_phase="validate"
PICSHOT_LIVE_SCROLL_RESOURCE_MODE=validate \
PICSHOT_LIVE_SCROLL_RESOURCE_INPUT="$resource_evidence/input" \
PICSHOT_LIVE_SCROLL_PNG_WRITER="$resource_backend" \
swift "$resource_repo/scripts/launch-smoke-app.swift" "$resource_app" "$resource_evidence/measure/validation-summary.json"
verify_resource_launch "$resource_evidence/measure/validation-summary.json" validate passed,failed
python3 -I - "$resource_evidence" <<'PY'
import hashlib,json,pathlib,re,sys
root=pathlib.Path(sys.argv[1]); path=root/"measure/live-scroll-resource-validation.json"
result=json.loads(path.read_text()); measurement=json.loads((root/"measure/live-scroll-resource-measurement.json").read_text())
assert result==json.loads((root/"measure/validation-summary.json").read_text()),"Current validation summary/detail disagree"
assert result.get("validationCompleted") is True and result.get("measurementComplete") is True,result
proofs=result.get("outputCertificates",[]); assert len(proofs)==10,"Ten exact PNG certificates required"
for key in ["sourceCommit","executableSHA256","pngWriterBackend","inputSHA256","certificateSHA256"]:
    assert result.get(key)==measurement.get(key),(key,result,measurement)
for ordinal,proof in enumerate(proofs,1):
    output=measurement["cycles"][ordinal-1]["output"]
    assert proof.get("ordinal")==ordinal and proof.get("file")==output["file"],proof
    assert proof.get("expectedEncodedBytes")==output["encodedBytes"],proof
    if proof.get("passed") is True:
        assert proof.get("pixelEquality") is True and proof.get("comparedBytes")==36536320,proof
        assert proof.get("encodedBytes")==proof["expectedEncodedBytes"] and re.fullmatch(r"[0-9a-f]{64}",proof.get("sha256","")),proof
memory=measurement["budgetAssessment"]["warmAndLateGatesPassed"]
pixels=all(p.get("passed") is True for p in proofs)
assert result.get("memoryGateStatus")==("passed" if memory else "failed"),result
assert result.get("pixelValidationStatus")==("passed" if pixels else "failed"),result
assert result.get("status")==("passed" if memory and pixels else "failed"),result
report=json.loads((root/"resource-wrapper.json").read_text())
report.update(status=result["status"],phase="validated",qualificationStatus=result["status"],measurementComplete=True,
    completedWarmupCycles=2,completedMeasuredCycles=8,memoryGateStatus=result["memoryGateStatus"],pixelValidationStatus=result["pixelValidationStatus"],
    validationCompleted=True,outputCertificates=10,inputSHA256=result["inputSHA256"],certificateSHA256=result["certificateSHA256"],
    measurement="measure/live-scroll-resource-measurement.json",validation="measure/live-scroll-resource-validation.json")
(root/"resource-wrapper.json").write_text(json.dumps(report,indent=2)+"\n")
# EXIT trap persists compact JSON plus one finished PNG and reference before failure returns.
raise SystemExit(0 if memory and pixels else 1)
PY
