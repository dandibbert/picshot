#!/usr/bin/env python3
"""Early same-ZIP installed witness; never substitutes for final ZIP/DMG smoke.

Uses the existing LaunchServices owner, bounded command runner and independent
native reader. No downloads, process discovery, broad kills or fixture changes.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("export_gate", ROOT / "scripts/check-recording-input-exports.py")
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)
IDENTITY_FILES = ("Contents/MacOS/PicShot", "Contents/Info.plist", "Contents/Resources/build-info.json")
LAUNCH_SECONDS, READER_SECONDS = 660, 330
LOG_CAP = 2 * 1024 * 1024
ARTIFACT_LIMITS = {name: GATE.MEDIA_CAP for name in ["recording-input.mp4", *(name for _, name in GATE.MEDIA)]}
ARTIFACT_LIMITS.update({name: GATE.REPORT_CAP for name in (
    "checked.json", "launch.json", "launch.json.launcher.json", "launcher-report.json", "reader-report.json",
    "recording-input.json", "recording-input-export.json", "recording-input-export-independent.json")})
ARTIFACT_LIMITS.update({"launcher.log": LOG_CAP, "reader.log": LOG_CAP})


def digest(path):
    GATE.need(path.is_file() and path.resolve() == path, f"Missing canonical regular identity file: {path}")
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def source_identity(commit):
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True, timeout=10).strip()
    GATE.need(head == commit, "Reader checkout differs from selected product source")
    subprocess.run(["git", "diff", "--quiet", "HEAD", "--"], cwd=ROOT, check=True, timeout=10)


def package_identity(app, packaged, archive, commit, architecture):
    import plistlib
    GATE.need(app.is_dir() and app.resolve() == app, "Installed bundle path is not canonical")
    hashes = {name: digest(app / name) for name in IDENTITY_FILES}
    GATE.need(hashes == {name: digest(packaged / name) for name in IDENTITY_FILES},
              "Extracted executable or provenance differs from packaged app")
    info = plistlib.loads((app / IDENTITY_FILES[1]).read_bytes())
    build = json.loads((app / IDENTITY_FILES[2]).read_text())
    GATE.need(info.get("PicShotSourceCommit") == build.get("sourceCommit") == commit
              and info.get("CFBundleExecutable") == "PicShot"
              and info.get("CFBundleShortVersionString") == build.get("version") == "0.21.0"
              and build.get("architecture") == architecture, "Installed source, architecture or version differs")
    if "GITHUB_RUN_NUMBER" in os.environ:
        GATE.need(info.get("CFBundleVersion") == os.environ["GITHUB_RUN_NUMBER"], "Installed build number differs")
    return dict(bundlePath=str(app), executablePath=str(app / IDENTITY_FILES[0]),
                sourceCommit=commit, architecture=architecture, buildVersion=info["CFBundleVersion"],
                sha256=hashes, zipSHA256=digest(archive))


def owned_exit(root, app):
    receipt = GATE.read(root / "launch.json.launcher.json")
    GATE.need(receipt.get("selectedAppPath") == receipt.get("launchedAppPath") == str(app)
              and receipt.get("expectedExecutablePath") == receipt.get("launchedExecutablePath") == str(app / IDENTITY_FILES[0])
              and receipt.get("earlyWitnessOnly") is True and receipt.get("launchedIdentityMatches") is True
              and receipt.get("callbackReceived") is True and receipt.get("createsNewApplicationInstance") is True
              and type(receipt.get("processIdentifier")) is int and receipt["processIdentifier"] > 0
              and receipt.get("ownedExitConfirmed") is True, "Exact installed app exit is unconfirmed")
    return receipt


def validate_launch(root, app, commit):
    receipt = owned_exit(root, app)
    GATE.need(receipt.get("status") == "exited" and receipt.get("launcherExitCode") == 0
              and receipt.get("timeoutSeconds") == 600 and "interruptedSignal" not in receipt,
              "Installed launch failed, timed out or was interrupted")
    report = GATE.read(root / "launch.json")
    GATE.need(report.get("status") == "exported-awaiting-independent-validation"
              and report.get("sourceCommit") == commit and report.get("bundlePath") == str(app)
              and report.get("executablePath") == str(app / IDENTITY_FILES[0])
              and report.get("arguments") == [str(app / IDENTITY_FILES[0])]
              and report.get("earlyWitnessOnly") is True and report.get("installerAcceptance") is False
              and report.get("independentValidationRequired") is True,
              "Early installed fixture did not complete with the selected identity")
    history = report.get("historyDirectoryPath")
    GATE.need(isinstance(history, str) and Path(history).is_absolute()
              and Path(history).name.startswith("PicShot-Smoke-")
              and report.get("historyDirectoryRemoved") is True and not Path(history).exists(),
              "Smoke history cleanup is unconfirmed")
    for name, status, seconds in (("recording-input.json", "passed", 60),
                                   ("recording-input-export.json", "exported-awaiting-independent-validation", 120)):
        fixture = GATE.read(root / name)
        GATE.need(fixture.get("status") == status and fixture.get("sourceCommit") == commit
                  and fixture.get("temporaryDirectoryRemoved") is True
                  and fixture.get("cooperativeDeadlineSeconds") == seconds
                  and GATE.finite(fixture.get("elapsedSeconds")) and 0 <= fixture["elapsedSeconds"] < seconds,
                  f"Fixture completion, cleanup or original deadline differs: {name}")
        for key in ("captureStarted", "permissionRequested", "globalInputPosted"):
            GATE.need(fixture.get(key) is False, f"Fixture privacy boundary differs: {key}")


def bounded(command, seconds, name, root, environment):
    # The existing wrapper owns its process group. The Swift launcher separately
    # owns the LaunchServices app and confirms its exact executable and exit.
    grace = 10 if name == "launcher" else 5
    result = subprocess.run([sys.executable, "scripts/run-bounded-command.py", "--timeout-seconds", str(seconds),
        "--grace-seconds", str(grace), "--max-log-bytes", str(LOG_CAP), "--log", str(root / (name + ".log")),
        "--report", str(root / (name + "-report.json")), "--", *map(str, command)], cwd=ROOT, env=environment)
    report = GATE.read(root / (name + "-report.json"))
    GATE.need(result.returncode == 0 and report.get("status") == report.get("termination_reason") == "exited"
              and report.get("exit_code") == report.get("child_returncode") == 0
              and report.get("command") == list(map(str, command)) and report.get("timeout_seconds") == seconds
              and report.get("grace_seconds") == grace and report.get("log_truncated") is False
              and report.get("max_log_bytes") == LOG_CAP
              and report.get("log_bytes") == report.get("output_bytes") == (root / (name + ".log")).stat().st_size
              and report.get("sigterm_sent") is False and report.get("sigkill_sent") is False
              and report.get("cancel_signal") is None and report.get("descendant_cleanup") is False
              and not report.get("cleanup_errors"), f"Incomplete or failed {name} process; preserve its original outcome")


def prepare_artifact(root, record):
    # Copy only finite witness bytes, even after failure or uncertain app exit.
    # An oversized/incomplete original stays local; never truncate it or rerun.
    artifact = root / "artifact"
    artifact.mkdir()
    copied, omitted = [], {}
    for name, maximum in ARTIFACT_LIMITS.items():
        if name == "checked.json" or not (root / name).exists():
            continue
        try:
            path = root / name
            empty_log = name.endswith(".log") and path.is_file() and not path.is_symlink() and path.stat().st_size == 0
            data = b"" if empty_log else GATE.bounded(path, maximum)
            (artifact / name).write_bytes(data)
            copied.append(name)
        except (ValueError, OSError) as error:
            omitted[name] = str(error)[:1024]
    if omitted:
        record["status"] = "failed"
    record.update(artifactMaximumPayloadBytes=sum(ARTIFACT_LIMITS.values()),
                  artifactFiles=sorted(copied + ["checked.json"]), artifactOmissions=omitted)
    data = (json.dumps(record, indent=2) + "\n").encode()
    GATE.need(len(data) <= GATE.REPORT_CAP, "Early summary exceeds existing report cap")
    (root / "checked.json").write_bytes(data)
    (artifact / "checked.json").write_bytes(data)


def run(commit):
    GATE.need(platform.system() == "Darwin" and platform.machine() in ("arm64", "x86_64"), "Native macOS required")
    GATE.need(re.fullmatch(r"[0-9a-f]{40}", commit), "Expected source must be a full SHA-1")
    dist = ROOT / "dist"
    GATE.need(dist.is_dir() and dist.resolve() == dist, "Packaged dist must be a canonical directory")
    root = dist / "evidence/recording-input-export-early"
    GATE.need(root.parent.resolve() == root.parent, "Evidence parent is not canonical")
    root.mkdir(parents=True, exist_ok=False)  # Never overwrite a prior attempt.
    record = dict(schemaVersion=1, status="running", sourceCommit=commit, earlyWitnessOnly=True,
                  installerAcceptance=False, fullZIPAndDMGSmokeRequired=True,
                  installedDirectoryRemoved=False, ownedAppExitConfirmed=False)
    work, app, launch_attempted = None, None, False
    try:
        source_identity(commit)
        archive = dist / f"PicShot-0.21.0-macos-{platform.machine()}.zip"
        work = Path(tempfile.mkdtemp(prefix="recording-input-export-early.", dir=dist)).resolve()
        app = work / "PicShot.app"
        subprocess.run(["ditto", "-x", "-k", str(archive), str(work)], check=True, timeout=60)
        record["packageIdentity"] = package_identity(app, dist / "PicShot.app", archive, commit, platform.machine())
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True, timeout=30)
        architecture = subprocess.check_output(["lipo", "-archs", str(app / IDENTITY_FILES[0])], text=True, timeout=10).strip()
        GATE.need(architecture == platform.machine(), "Installed executable architecture differs")
        environment = {key: value for key, value in os.environ.items() if not key.startswith("PICSHOT_")}
        environment["PICSHOT_RECORDING_INPUT_EXPORT_ONLY"] = "1"
        record["phase"] = "installed-witness"
        (root / "checked.json").write_text(json.dumps(record, indent=2) + "\n")
        launch_attempted = True
        bounded(["swift", "scripts/launch-smoke-app.swift", app, root / "launch.json"], LAUNCH_SECONDS, "launcher", root, environment)
        validate_launch(root, app, commit)
        record["phase"] = "independent-native-reader"
        (root / "checked.json").write_text(json.dumps(record, indent=2) + "\n")
        bounded([sys.executable, "scripts/verify-recording-input-exports.py", root, commit], READER_SECONDS, "reader", root, environment)
        record["independentValidation"] = GATE.validate(root, commit)
        GATE.need(package_identity(app, dist / "PicShot.app", archive, commit, platform.machine()) == record["packageIdentity"],
                  "Package identity changed during early observation")
        source_identity(commit)
        record.update(status="passed", phase="complete")
    except Exception as error:
        record.update(status="failed", error=str(error)[:4096])
    finally:
        try:
            if launch_attempted:
                owned_exit(root, app)
                record["ownedAppExitConfirmed"] = True
            if work is not None:
                shutil.rmtree(work)
                GATE.need(not work.exists(), "Installed directory remains after cleanup")
                record["installedDirectoryRemoved"] = True
        except Exception as error:
            # Retain the exact installed path if app exit is uncertain. Never
            # remove another process's bundle or guess at a PID/name to kill.
            record.update(status="failed", cleanupError=str(error)[:4096], retainedInstalledDirectory=str(work))
        prepare_artifact(root, record)
        print(json.dumps(record, sort_keys=True))
    return 0 if record["status"] == "passed" else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_commit")
    args = parser.parse_args()
    try:
        sys.exit(run(args.source_commit))
    except (ValueError, OSError) as error:
        parser.exit(1, str(error) + "\n")
