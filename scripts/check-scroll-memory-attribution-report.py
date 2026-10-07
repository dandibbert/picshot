#!/usr/bin/env python3
"""Validate bounded scroll attribution evidence, never infer a leak verdict."""
import argparse
import hashlib
import json
import math
import plistlib
import re
from pathlib import Path

PROFILES = [("4k-vertical", 3840, 2160, "vertical"), ("4k-horizontal", 3840, 2160, "horizontal"),
            ("5k-vertical", 5120, 2880, "vertical"), ("5k-horizontal", 5120, 2880, "horizontal")]
COUNTS = {
    "source-create": (4, 0, 0, 0, 0, 0, 0, 0), "capture-hash": (4, 8, 0, 0, 0, 0, 0, 0),
    "png-spool": (4, 0, 4, 0, 0, 0, 0, 0), "stitch-overlap": (4, 0, 0, 3, 3, 0, 0, 0),
    "overview": (0, 0, 0, 0, 0, 4, 0, 0), "detail": (0, 0, 0, 0, 0, 0, 2, 0),
    "shared-accept": (4, 0, 4, 3, 3, 4, 0, 4),
}
COUNT_FIELDS = ("sourceCreates", "rgbaHashes", "pngWrites", "matches", "overlapValidations", "overviewRenders", "detailRenders", "acceptedFrames")
RSS_CAP, FOOTPRINT_CAP = 3 * 1024**3, 512 * 1024**2
CLEANUP = {"fixtureSourceRasters", "retainedGrayscaleFrames", "spoolDirectories", "controllers", "activeWorkloadTasks"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def integer(value, label, minimum=0):
    require(type(value) is int and value >= minimum, f"{label}: invalid integer")
    return value


def sha(value, label, length=64):
    require(isinstance(value, str) and re.fullmatch(f"[0-9a-f]{{{length}}}", value), f"{label}: invalid SHA")
    return value


def memory(value, label):
    require(isinstance(value, dict), f"{label}: memory missing")
    for key in ("residentBytes", "physicalFootprintBytes"):
        integer(value.get(key), f"{label}.{key}", 1)
    accounting = value.get("backingAccounting")
    require(isinstance(accounting, dict), f"{label}: backing accounting missing")
    for flavor, expected in (("standard", "TASK_VM_INFO"), ("purgeable", "TASK_VM_INFO_PURGEABLE")):
        row = accounting.get(flavor)
        require(isinstance(row, dict) and row.get("flavor") == expected, f"{label}: wrong Mach flavor")
        require(type(row.get("kernelReturn")) is int and row["kernelReturn"] == 0, f"{label}: Mach call failed")
        requested = integer(row.get("requestedNaturalCount"), f"{label}.requestedNaturalCount", 1)
        returned = integer(row.get("returnedNaturalCount"), f"{label}.returnedNaturalCount", 1)
        require(returned <= requested, f"{label}: invalid returned Mach count")
        time = row.get("observedAtUptimeSeconds")
        require(type(time) in (float, int) and math.isfinite(time) and time > 0, f"{label}: missing Mach observation time")
        fields = row.get("bytes")
        require(isinstance(fields, dict), f"{label}: Mach byte fields missing")
        for field in ("resident_size", "phys_footprint"):
            integer(fields.get(field), f"{label}.{flavor}.{field}", 1)
        for field in ("purgeable_volatile_resident", "purgeable_volatile_virtual", "purgeable_volatile_pmap"):
            if flavor == "purgeable":
                integer(fields.get(field), f"{label}.{flavor}.{field}")
            else:
                require(field not in fields, f"{label}: standard flavor did not query {field}")
        for field, count in fields.items():
            integer(count, f"{label}.{flavor}.{field}")
        ledgers = row.get("ledgerBytes")
        require(isinstance(ledgers, dict) and "ledger_purgeable_nonvolatile" in ledgers, f"{label}: ledger fields missing")
        for count in ledgers.values():
            require(type(count) is int, f"{label}: ledger must preserve signed integer")
    return value


def sampled(value):
    require(isinstance(value, dict), "sampledMemory missing")
    total = integer(value.get("timerTickCount"), "timerTickCount", 1) + integer(value.get("boundarySampleCount"), "boundarySampleCount", 1)
    for key in ("residentSampleCount", "physicalFootprintSampleCount"):
        require(integer(value.get(key), key) == total, f"{key}: incomplete samples")
    for key in ("failedResidentSampleCount", "failedPhysicalFootprintSampleCount"):
        require(integer(value.get(key), key) == 0, f"{key}: failed samples")
    for key, cap in (("peakResidentBytes", RSS_CAP), ("peakPhysicalFootprintBytes", FOOTPRINT_CAP)):
        require(integer(value.get(key), key, 1) <= cap, f"{key}: watchdog cap exceeded")


def delta(first, last):
    return {
        "residentBytes": last["residentBytes"] - first["residentBytes"],
        "physicalFootprintBytes": last["physicalFootprintBytes"] - first["physicalFootprintBytes"],
        "volatileResidentBytes": last["backingAccounting"]["purgeable"]["bytes"]["purgeable_volatile_resident"] - first["backingAccounting"]["purgeable"]["bytes"]["purgeable_volatile_resident"],
        "nonvolatileLedgerBytes": last["backingAccounting"]["purgeable"]["ledgerBytes"]["ledger_purgeable_nonvolatile"] - first["backingAccounting"]["purgeable"]["ledgerBytes"]["ledger_purgeable_nonvolatile"],
    }


def validate(report, production, overlay, mode, executable_sha=None, source_commit=None, prepared_manifest=None):
    require(mode in COUNTS, "Unknown cell mode")
    require(report.get("schemaVersion") == 1 and report.get("mode") == mode and report.get("status") == "observed", "Not a completed attribution report")
    require(report.get("productionSourceCommit") == sha(production, "production", 40), "Production identity mismatch")
    require(report.get("diagnosticOverlayCommit") == sha(overlay, "overlay", 40), "Overlay identity mismatch")
    sha(report.get("sourceCommit"), "sourceCommit", 40)
    if source_commit is not None:
        require(report["sourceCommit"] == source_commit, "Bundle source commit differs")
    sha(report.get("executableSHA256"), "executableSHA256")
    if executable_sha is not None:
        require(report["executableSHA256"] == executable_sha, "Executable bytes differ")
    for field in ("diagnosticOnly", "separateProcessRequired", "observationsComplete", "outerDeadlineRequired", "endToEndFixtureUnchanged"):
        require(report.get(field) is True, f"{field} missing")
    for field in ("deliveredBinary", "purgeabilityInferredFromRSSFootprintGap", "zeroLeakClaim", "stabilityAssessed", "captureStarted", "permissionRequests", "globalInputPosted", "networkUsed", "memoryPressureOrSystemSettingsChanged", "allocatorPurgeAttempted"):
        require(report.get(field) is False, f"Unexpected {field}")
    for field, expected in {"warmupCycles": 8, "measuredCycles": 16, "completedWarmupCycles": 8,
                            "completedMeasuredCycles": 16, "sourcesPerCycle": 4,
                            "cooperativeDeadlineSeconds": 240, "sampleIntervalSeconds": 0.05,
                            "settlingDelaySeconds": 0.15, "maximumConcurrentWorkloadTasks": 1,
                            "fullOutputRasters": 0, "sampledResidentCeilingBytes": RSS_CAP,
                            "sampledPhysicalFootprintCeilingBytes": FOOTPRINT_CAP}.items():
        require(type(report.get(field)) in (int, float) and report[field] == expected, f"{field} differs")
    elapsed = report.get("elapsedSeconds")
    require(type(elapsed) in (int, float) and math.isfinite(elapsed) and 0 < elapsed <= 240, "Cell deadline exceeded/missing")
    for field in ("scope", "backingAccountingScope", "backingAccountingSampling", "watchdogScope", "operatingSystem", "bundlePath", "ownershipScope"):
        require(isinstance(report.get(field), str) and report[field], f"{field} missing")
    require(report.get("architecture") in ("arm64", "x86_64") and report.get("buildMode") in ("release", "debug"), "Build identity missing")
    integer(report.get("processIdentifier"), "processIdentifier", 1)
    sampled(report.get("sampledMemory"))
    for field in ("beforeWarmup", "baselineAfterWarmup", "afterCyclesBeforeInputRevalidation", "finalAfterCleanup"):
        memory(report.get(field), field)
    for phase, expected_count in (("warmups", 8), ("cycles", 16)):
        rows = report.get(phase)
        require(isinstance(rows, list) and len(rows) == expected_count, f"{phase} count differs")
        for index, row in enumerate(rows):
            name, width, height, axis = PROFILES[index % 4]
            require(row.get("index") == index + 1 and row.get("profile") == name and row.get("axis") == axis, f"{phase}: interleaved profile order differs")
            require(row.get("phase") == ("warmup" if phase == "warmups" else "measured"), "Phase differs")
            require(row.get("width") == width and row.get("height") == height and row.get("rgbaReferenceBytes") == width * height * 4, "Profile dimensions differ")
            require(all(type(row.get(key)) is int for key in COUNT_FIELDS) and tuple(row.get(key) for key in COUNT_FIELDS) == COUNTS[mode], f"{phase}/{index}: operation counts differ")
            cleanup = row.get("cleanup")
            require(isinstance(cleanup, dict) and set(cleanup) == CLEANUP and all(type(x) is int and x == 0 for x in cleanup.values()), "Owned cleanup counters nonzero/missing")
            memory(row.get("before"), "cycle.before"); memory(row.get("settledAfterCleanup"), "cycle.settled")
            stages = row.get("phases")
            require(isinstance(stages, list) and len(stages) == (5 if mode == "detail" else 4), "Stage count differs")
            for i, stage in enumerate(stages):
                if i < 4:
                    require(stage.get("sourceIndex") == i, "Stage source order differs")
                memory(stage.get("before"), "stage.before")
                if mode in ("source-create", "capture-hash", "png-spool", "stitch-overlap", "shared-accept"):
                    memory(stage.get("afterSourceCreation"), "stage.afterSourceCreation")
                if mode == "shared-accept":
                    memory(stage.get("afterAcceptance"), "stage.afterAcceptance")
                    require(stage.get("acceptedSources") == i + 1, "Shared accept source count differs")
                else:
                    memory(stage.get("afterPool"), "stage.afterPool")
                    if mode in ("source-create", "capture-hash", "png-spool", "stitch-overlap"):
                        memory(stage.get("afterOperationWhileSourceAlive"), "stage.afterOperationWhileSourceAlive")
                if mode == "capture-hash":
                    sha(stage.get("rgbaSHA256"), "rgbaSHA256")
                if mode == "png-spool":
                    integer(stage.get("encodedBytes"), "encodedBytes", 1)
                if mode == "overview":
                    require(integer(stage.get("renderedPixels"), "overviewPixels", 1) <= 800 * 800, "Overview too large")
            if mode == "png-spool":
                require(sum(s["encodedBytes"] for s in stages) <= 512 * 1024**2, "Session spool cap exceeded")
            if mode == "detail":
                require(stages[-1].get("stage") == "two-detail-tiles" and stages[-1].get("renderCounts", {}).get("tiles") == 2, "Two detail renders missing")
    if mode in ("stitch-overlap", "overview", "detail"):
        require(report.get("preparedInputsUnchanged") is True, "Input immutability not verified")
        sha(report.get("inputManifestSHA256"), "inputManifestSHA256")
        entries = report.get("inputFileIdentities")
        require(isinstance(entries, list) and len(entries) == 16, "Input identities missing")
        for index, row in enumerate(entries):
            require(row.get("name") == f"{PROFILES[index // 4][0]}-{index % 4}.png", "Input identity order differs")
            sha(row.get("sha256"), "inputSHA256"); integer(row.get("bytes"), "inputBytes", 1)
        if prepared_manifest is not None:
            require(hashlib.sha256(prepared_manifest).hexdigest() == report["inputManifestSHA256"], "Prepared manifest bytes differ")
            data = json.loads(prepared_manifest)
            expected = [{key: entry[key] for key in ("name", "bytes", "sha256")} for entry in data["inputs"]]
            require(entries == expected, "Prepared PNG identities differ")
    settled = [row["settledAfterCleanup"] for row in report["cycles"]]
    return {"status": "observed", "mode": mode, "productionSourceCommit": production,
            "diagnosticOverlayCommit": overlay, "executableSHA256": report["executableSHA256"],
            "growthFromWarmup": delta(report["baselineAfterWarmup"], settled[-1]),
            "lateThreeIntervalGrowth": [delta(a, b) for a, b in zip(settled[-4:-1], settled[-3:])],
            "finalCleanupDelta": delta(settled[-1], report["finalAfterCleanup"]),
            "perProfileGrowth": {p[0]: delta(settled[i], settled[i + 12]) for i, p in enumerate(PROFILES)},
            "sampledMemory": report["sampledMemory"], "zeroLeakClaim": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path); parser.add_argument("app", type=Path)
    parser.add_argument("production"); parser.add_argument("overlay"); parser.add_argument("mode", choices=COUNTS)
    parser.add_argument("--source-commit"); parser.add_argument("--prepared-manifest", type=Path)
    args = parser.parse_args()
    raw = args.report.read_bytes(); require(len(raw) <= 4 * 1024**2, "Report exceeds4MiB")
    info = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())
    executable = args.app / "Contents/MacOS" / info["CFBundleExecutable"]
    require(info.get("PicShotSourceCommit") == (args.source_commit or args.overlay), "App source identity differs")
    summary = validate(json.loads(raw), args.production, args.overlay, args.mode,
                       hashlib.sha256(executable.read_bytes()).hexdigest(), args.source_commit or args.overlay,
                       args.prepared_manifest.read_bytes() if args.prepared_manifest else None)
    print(json.dumps(summary, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
