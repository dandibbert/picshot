#!/usr/bin/env python3
"""Classify a testing package without changing original live-scroll qualification.

Only an otherwise complete run whose sole failed gate is warm physical-footprint
growth may receive partial-memory testing eligibility. This is not an installer,
real-capture, leak, stability, or full-memory qualification.
"""
import argparse
import hashlib
import json
import math
import re
from pathlib import Path

VIEWPORT = 1280 * 960 * 4
OUTPUT = 1280 * 7136 * 4
RSS_CAP, FOOTPRINT_CAP = 3 * 1024**3, 512 * 1024**2
TARGETS = dict(coldFinalGrowth=26607616, coldSampledGrowth=129171456,
               measuredGrowth=2 * VIEWPORT, lateIntervalAndSum=VIEWPORT)
PHASES = ["before-session", "source-ready", "first-displayed-preview",
          "pre-finish-pending-edge", "finish-image-alive-before-png",
          "png-finalized-image-alive", "session-closed-output-recipient-alive",
          "recipient-and-helper-locals-released", "released-plus-150ms",
          "released-plus-1000ms"]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def integer(value, label, minimum=0, maximum=2**63 - 1):
    require(type(value) is int and minimum <= value <= maximum, label + ": invalid integer")
    return value


def number(value, label, minimum=0, maximum=float("inf")):
    require(type(value) in (int, float) and math.isfinite(value)
            and minimum <= value <= maximum, label + ": invalid number/deadline")
    return value


def equal(actual, expected, label):
    require(type(actual) is type(expected), label + ": wrong type/missing")
    if isinstance(expected, dict):
        require(actual.keys() == expected.keys(), label + ": keys differ/missing")
        for key, value in expected.items():
            equal(actual[key], value, label + "." + key)
    elif isinstance(expected, list):
        require(len(actual) == len(expected), label + ": length differs")
        for index, (left, right) in enumerate(zip(actual, expected)):
            equal(left, right, label + "[%d]" % index)
    else:
        require(actual == expected, label + ": differs/missing")


def fields(row, expected, label):
    require(isinstance(row, dict), label + ": missing object")
    for key, value in expected.items():
        equal(row.get(key), value, label + "." + key)


def sha(value, label, length=64):
    require(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{%d}" % length, value),
            label + ": invalid SHA")
    return value


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_json(path):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "Duplicate JSON key: " + key)
            result[key] = value
        return result
    raw = path.read_bytes()
    require(len(raw) <= 16 * 1024**2, str(path) + ": report exceeds 16MiB")
    value = json.loads(raw, object_pairs_hook=unique,
                       parse_constant=lambda value: (_ for _ in ()).throw(ValueError("Invalid JSON number: " + value)))
    require(isinstance(value, dict), str(path) + ": expected object")
    return value, raw


def bounded_runner(row, timeout, code, label):
    fields(row, dict(status="exited", child_returncode=code, exit_code=code,
                     cancel_signal=None, sigterm_sent=False, sigkill_sent=False,
                     descendant_cleanup=False, termination_reason="exited"), label)
    equal(number(row.get("timeout_seconds"), label), float(timeout), label + ".timeout")
    equal(number(row.get("grace_seconds"), label), 10.0, label + ".grace")
    number(row.get("duration_seconds"), label + ".duration", 0, timeout)


def launcher(row, identity, label, pid=None):
    fields(row, dict(status="exited", launcherExitCode=0, callbackReceived=True,
                     createsNewApplicationInstance=True, ownedExitConfirmed=True,
                     launchedIdentityMatches=True, timeoutSeconds=600,
                     selectedAppPath=identity["bundlePath"], launchedAppPath=identity["bundlePath"],
                     launchedExecutablePath=identity["executablePath"]), label)
    result = integer(row.get("processIdentifier"), label + ".pid", 1)
    if pid is not None:
        equal(result, pid, label + ".pid")
    number(row.get("elapsedSeconds"), label + ".elapsed", 0, 600)
    return result


def boundary(row, label):
    require(isinstance(row, dict), label + ": missing boundary")
    number(row.get("uptime"), label + ".uptime", 0)
    memory = row.get("memory", {})
    for key, cap in (("residentBytes", RSS_CAP), ("physicalFootprintBytes", FOOTPRINT_CAP)):
        integer(memory.get(key), label + "." + key, 1, cap)
    for flavor, name in (("standard", "TASK_VM_INFO"), ("purgeable", "TASK_VM_INFO_PURGEABLE")):
        sample = row.get("backing", {}).get(flavor, {})
        fields(sample, dict(flavor=name, kernelReturn=0), label + "." + flavor)
        requested = integer(sample.get("requestedNaturalCount"), label + ".requested", 1)
        integer(sample.get("returnedNaturalCount"), label + ".returned", 1, requested)
        number(sample.get("observedAtUptimeSeconds"), label + ".observed", 0, row["uptime"])
        for key, cap in (("resident_size", RSS_CAP), ("phys_footprint", FOOTPRINT_CAP)):
            integer(sample.get("bytes", {}).get(key), label + "." + flavor + "." + key, 1, cap)
        if flavor == "purgeable":
            for key in ("purgeable_volatile_resident", "purgeable_volatile_virtual", "purgeable_volatile_pmap"):
                integer(sample.get("bytes", {}).get(key), label + "." + key)
            for key in ("ledger_purgeable_volatile", "ledger_purgeable_volatile_compressed"):
                integer(sample.get("ledgerBytes", {}).get(key), label + "." + key, -(2**63))
    ledgers = row["backing"]["purgeable"]["ledgerBytes"]
    volatile = sum(ledgers[key] for key in ("ledger_purgeable_volatile", "ledger_purgeable_volatile_compressed"))
    integer(volatile, label + ".combinedVolatileLedger", -(2**63))
    return dict(memory, combinedVolatileLedger=volatile)


def cycle(row, ordinal):
    label = "cycle-%02d" % ordinal
    fields(row, dict(ordinal=ordinal, status="passed", warmup=ordinal <= 2, cold=ordinal == 1,
                     pngWriterBackend="foundation", finishCallbacks=1, sessionReportedClosed=True,
                     ownedSpoolParentRemoved=True, remainingSpoolEntries=[]), label)
    require(not row.get("error") and not row.get("cleanupError"), label + ": error present")
    fields(row.get("lastProductState"), dict(acceptedObservations=218, sampledFrames=218,
           width=1280, height=7136, offset=6176, matched=True, previewUnavailable=False), label + ".product")
    fields(row.get("sourceAfterStop"), dict(successfulFrames=218, activeReads=0, state="stopped",
           descriptorOpen=False, descriptorCloseConfirmed=True, confirmedStops=1), label + ".source")
    pre = row.get("preFinish", {})
    fields(pre, dict(acceptedObservations=218, height=7136, offset=6176, sourceReadCount=0), label + ".preview")
    integer(pre.get("cachedPreviewBytes"), label + ".cache", 1, 4 * 1024**2)
    integer(pre.get("durableHeight"), label + ".durableHeight", 1, 7136)
    integer(pre.get("observedGrowths"), label + ".growths", 8)
    integer(pre.get("observedReverseSamples"), label + ".reverse", 2)
    output = row.get("output", {})
    fields(output, dict(file=label + ".png", width=1280, height=7136, layoutBytes=OUTPUT), label + ".output")
    integer(output.get("encodedBytes"), label + ".encodedBytes", 1, 512 * 1024**2)
    for key in ("ownership150ms", "ownership1000ms"):
        fields(row.get(key), dict(sessionReleased=True, sourceReleased=True, controlsReleased=True,
               thumbnailReleased=True, attachedWindowGraphs=0, retainedWindowShells=0), label + "." + key)
    for key in ("provider150ms", "providerAfterClose"):
        provider = row.get(key, {})
        fields(provider, dict(liveBytes=0, liveImages=0, allocatedImages=218, releasedImages=218,
               allocatedBytes=218 * VIEWPORT, releasedBytes=218 * VIEWPORT), label + "." + key)
        integer(provider.get("peakLiveImages"), label + ".peakImages", 1, 2)
        integer(provider.get("peakLiveBytes"), label + ".peakBytes", 1, 2 * VIEWPORT)
    samples = row.get("memory", {})
    count = integer(samples.get("timerTickCount"), label + ".ticks", 1) + integer(samples.get("boundarySampleCount"), label + ".samples", 1)
    fields(samples, dict(residentSampleCount=count, physicalFootprintSampleCount=count,
           backingSampleCount=count, failedResidentSampleCount=0, failedPhysicalFootprintSampleCount=0), label + ".samples")
    integer(samples.get("peakResidentBytes"), label + ".peakRSS", 1, RSS_CAP)
    integer(samples.get("peakPhysicalFootprintBytes"), label + ".peakFootprint", 1, FOOTPRINT_CAP)
    integer(samples.get("peakVolatileResidentBytes"), label + ".peakVolatileResident")
    integer(samples.get("peakVolatileLedgerBytes"), label + ".peakVolatileLedger", -(2**63))
    rows = row.get("boundaries")
    require(isinstance(rows, list) and [b.get("phase") for b in rows] == PHASES,
            label + ": missing/reordered/duplicate boundaries")
    observations = [boundary(b, label + "." + b["phase"]) for b in rows]
    times = [b["uptime"] for b in rows]
    require(times == sorted(times), label + ": nonmonotonic boundaries")
    require(times[6] - times[1] <= 180, label + ": product session deadline exceeded")
    elapsed = number(row.get("elapsedSeconds"), label + ".elapsed", times[-1] - times[0], 590)
    release = number(row.get("explicitOwnerReleaseUptime"), label + ".release", times[6], times[7])
    for index, delay, key in ((8, .15, "observed150msElapsedSeconds"), (9, 1.0, "observed1000msElapsedSeconds")):
        require(times[index] - release >= delay, label + ": premature cleanup observation")
        number(row.get(key), label + "." + key, times[index] - release, elapsed)
    return observations[8]


def proof(row, output, label):
    fields(row, dict(passed=True, pixelEquality=True, hashAvailable=True, comparedBytes=OUTPUT,
           expectedWidth=1280, expectedHeight=7136, file=output["file"], encodedBytes=output["encodedBytes"]), label)
    sha(row.get("sha256"), label + ".sha256")


def assess(measurement, endpoints):
    """Recompute the original gates, including diagnostic cold targets."""
    result = {"coldAndPeakTargetsAreDiagnosticOnly": True}
    failed = []
    for key in ("residentBytes", "physicalFootprintBytes", "combinedVolatileLedger"):
        values = [point[key] for point in endpoints]
        late = [b - a for a, b in zip(values[-4:-1], values[-3:])]
        growth = values[-1] - values[1]
        warm_pass = growth <= TARGETS["measuredGrowth"]
        late_pass = all(v <= VIEWPORT for v in late) and sum(late) <= VIEWPORT
        if not warm_pass:
            failed.append(key + ".warmGrowth")
        if not late_pass:
            failed.append(key + ".lateGrowth")
        item = dict(settledEndpoints=values, measuredGrowth=growth, lateThreeIncrements=late)
        if key == "combinedVolatileLedger":
            item["passed"] = warm_pass and late_pass
        else:
            initial, end = measurement["entry"]["memory"][key], measurement["final"]["memory"][key]
            peak_key = "peakResidentBytes" if key == "residentBytes" else "peakPhysicalFootprintBytes"
            peak = max(max(c["memory"][peak_key], *(b["memory"][key] for b in c["boundaries"])) for c in measurement["cycles"])
            item.update(entry=initial, final=end, coldPeakGrowth=peak - initial, coldFinalGrowth=end - initial,
                        estimatedColdTargetMet=end - initial <= TARGETS["coldFinalGrowth"],
                        estimatedPeakTargetMet=peak - initial <= TARGETS["coldSampledGrowth"],
                        coldAndPeakTargetsAreDiagnosticOnly=True, warmAndLateGatePassed=warm_pass and late_pass)
        result[key] = item
    result["warmAndLateGatesPassed"] = not failed
    return result, failed


def classify(root, source, executable_sha, archive_sha, build, runner_path, step_outcome, report):
    report.update(testingPackageEligible=False, partialMemoryQualification=False,
                  fullMemoryQualification=False, installerAcceptance=False)
    sha(source, "expected source", 40)
    sha(executable_sha, "expected executable")
    sha(archive_sha, "expected archive")
    require(isinstance(build, str) and re.fullmatch(r"[1-9][0-9]*", build), "Invalid expected build")
    require(step_outcome in ("success", "failure"), "Unexpected original step outcome")
    files = {}

    def load(name, fallback=None):
        path = root / name
        if not path.is_file() and fallback:
            path = root / fallback
        value, raw = read_json(path)
        files[name] = dict(path=str(path), sha256=digest(raw))
        if fallback and (root / name).is_file() and (root / fallback).is_file():
            other, other_raw = read_json(root / fallback)
            require(raw == other_raw, name + ": full and compact evidence disagree")
        return value, raw

    report["evidenceFiles"] = files
    identity, _ = load("package-identity.json")
    fields(identity, dict(status="passed", sourceCommit=source, executableSHA256=executable_sha,
           archiveSHA256=archive_sha, build=build, version="0.22.0"), "installed identity")
    require(identity.get("architecture") in ("arm64", "x86_64"), "Invalid installed architecture")
    app = identity.get("bundlePath")
    require(isinstance(app, str) and app.startswith("/") and str(Path(app)) == app and app.endswith("/PicShot.app")
            and ".." not in Path(app).parts, "Invalid installed bundle path")
    equal(identity.get("executablePath"), app + "/Contents/MacOS/PicShot", "installed executable path")
    report["packageIdentity"] = identity
    demo, _ = load("demo/demo.json")
    fields(demo, dict(status="passed", sourceCommit=source, bundlePath=app, build=build,
          version="0.22.0", globalInputPosted=False, installerAcceptance=False), "demo")
    for name in ("illustratedCase", "ordinaryTextCase", "movementCase"):
        case = demo.get(name, {})
        fields(case, dict(status="passed", productSessionClosed=True), name)
        equal(case.get("finishCallbacks" if name == "movementCase" else "finishButtonCompletionCallbacks"), 1, name + ".finish")
        comparison = case.get("referenceComparison" if name == "movementCase" else "nativeReferenceComparison", {})
        fields(comparison, dict(passed=True, dimensionsMatch=True), name + ".pixels")
        number(comparison.get("meanAbsoluteRGBAError"), name + ".error", 0, .5)
        number(comparison.get("fractionOfChannelsDifferingByMoreThan8"), name + ".fraction", 0, .001)
    demo_launch, _ = load("demo/demo.json.launcher.json")
    pids = [launcher(demo_launch, identity, "demo launch")]
    demo_runner, _ = load("demo-launch.json")
    bounded_runner(demo_runner, 660, 0, "demo runner")
    wrapper, _ = load("resource/resource-wrapper.json", "resource/upload/resource-wrapper.json")
    report["originalResourceStatus"] = wrapper.get("status")
    report["originalResourceExitCode"] = wrapper.get("exitCode")
    report["originalStepOutcome"] = step_outcome
    data, raw_data = {}, {}
    for name, phase, filename in (("certificate", "input", "certificate.json"),
            ("certify", "certify", "live-scroll-resource-certificate-run.json"),
            ("measure", "measure", "live-scroll-resource-measurement.json"),
            ("validate", "measure", "live-scroll-resource-validation.json")):
        compact = "input-certificate.json" if name == "certificate" else phase + "-" + filename
        data[name], raw_data[name] = load("resource/" + phase + "/" + filename, "resource/upload/" + compact)
    certificate, certify, measurement, validation = (data[key] for key in ("certificate", "certify", "measure", "validate"))
    report["originalMeasurementStatus"] = measurement.get("status")
    report["originalValidationStatus"] = validation.get("status")
    common = dict(schemaVersion=2, sourceCommit=source, executableSHA256=executable_sha,
                  bundlePath=app, architecture=identity["architecture"], pngWriterBackend="foundation",
                  workload="live-scroll-owned-1280-v1", warmupCycles=2, measuredCycles=8,
                  sourceFramesPerCycle=218, viewportWidth=1280, viewportHeight=960,
                  outputWidth=1280, outputHeight=7136, preparedRawBytes=OUTPUT,
                  cooperativeDeadlineSeconds=590, externalLauncherDeadlineSeconds=600,
                  sampleIntervalSeconds=.05, predeclaredTargetsAndGatesBytes=TARGETS,
                  coldAndPeakTargetsAreDiagnosticOnly=True, installerAcceptance=False,
                  nativeAcquisitionValidated=False, pixelVerificationInMeasuredProcess=False,
                  memoryStabilityClaimed=False, zeroLeakClaimed=False)
    input_sha = sha(certificate.get("inputSHA256"), "input SHA")
    for name, row in data.items():
        fields(row, common, name)
        equal(row.get("inputSHA256"), input_sha, name + ".inputSHA")
        integer(row.get("processIdentifier"), name + ".pid", 1)
        boundary(row.get("entry"), name + ".entry")
        boundary(row.get("afterInputValidation"), name + ".afterInputValidation")
    equal(certificate.get("mode"), "certify", "certificate mode")
    equal(certificate.get("status"), "passed", "certificate status")
    require(certificate == {k: v for k, v in certify.items() if k != "elapsedSeconds"}, "Input certificate/certification report disagree")
    fields(certificate.get("byteConversionFidelity"), dict(passed=True, bytesCompared=VIEWPORT), "native conversion")
    require(len(certificate.get("cycles", [])) == 1, "Certification cycle missing")
    cycle(certificate["cycles"][0], 1)
    proof(certificate.get("outputCertificate"), certificate["cycles"][0]["output"], "native certificate")
    sha(certificate.get("expectedReference", {}).get("sha256"), "reference SHA")
    for mode, phase, filename in (("certify", "certify", "summary.json"),
                                 ("measure", "measure", "summary.json"),
                                 ("validate", "measure", "validation-summary.json")):
        row = data[mode]
        equal(row.get("mode"), mode, mode + ".mode")
        summary, _ = load("resource/" + phase + "/" + filename, "resource/upload/" + phase + "-" + filename)
        require(row == summary, mode + ": detail/summary disagree")
        receipt, _ = load("resource/" + phase + "/" + filename + ".launcher.json",
                          "resource/upload/" + phase + "-" + filename + ".launcher.json")
        pids.append(launcher(receipt, identity, mode + " launch", row["processIdentifier"]))
    require(len(set(pids)) == 4, "Demo/certification/measurement/validation must be separate processes")
    for name in ("measure", "validate"):
        fields(data[name], dict(certificateSHA256=digest(raw_data["certificate"]), measurementComplete=True,
               measurementStatus="complete", completedWarmupCycles=2, completedMeasuredCycles=8), name)
    equal(validation.get("measurementReportSHA256"), digest(raw_data["measure"]), "validation measurement binding")
    rows = measurement.get("cycles")
    require(isinstance(rows, list) and len(rows) == 10, "Complete 2+8 workload required")
    endpoints = [cycle(row, ordinal) for ordinal, row in enumerate(rows, 1)]
    for row in (certify, measurement):
        boundary(row.get("final"), row["mode"] + ".final")
        number(row.get("elapsedSeconds"), row["mode"] + ".elapsed", 0, 590)
        require(row["entry"]["uptime"] <= row["afterInputValidation"]["uptime"] <= row["cycles"][0]["boundaries"][0]["uptime"], "Invalid entry/cycle order")
        require(row["final"]["uptime"] >= row["cycles"][-1]["boundaries"][-1]["uptime"], "Final observation before cleanup")
        require(row["final"]["uptime"] - row["entry"]["uptime"] <= row["elapsedSeconds"], "Run timestamps exceed elapsed time")
        for first, second in zip(row["cycles"], row["cycles"][1:]):
            require(first["boundaries"][-1]["uptime"] <= second["boundaries"][0]["uptime"], "Overlapping cycle observations")
    assessment, failures = assess(measurement, endpoints)
    report["recomputedBudgetAssessment"] = assessment
    report["failedOriginalMemoryGates"] = failures
    equal(measurement.get("budgetAssessment"), assessment, "reported/recomputed budget assessment")
    proofs = validation.get("outputCertificates")
    require(isinstance(proofs, list) and len(proofs) == 10, "Ten output certificates required")
    for ordinal, (item, row) in enumerate(zip(proofs, rows), 1):
        fields(item, dict(ordinal=ordinal, expectedEncodedBytes=row["output"]["encodedBytes"]), "output binding")
        proof(item, row["output"], "output certificate %d" % ordinal)
        image = root / "resource/measure" / item["file"]
        if image.exists():
            require(image.stat().st_size == item["encodedBytes"], "Output PNG size changed")
            with image.open("rb") as stream:
                hasher = hashlib.sha256()
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    hasher.update(block)
            equal(hasher.hexdigest(), item["sha256"], "Output PNG hash")
    memory_status, status = ("failed", "failed") if failures else ("passed", "passed")
    measurement_status = "failed" if failures else "measured-awaiting-pixel-validation"
    fields(measurement, dict(status=measurement_status, memoryGateStatus=memory_status,
           pixelValidationStatus="pending-independent-validation", independentValidationRequired=True), "measurement outcome")
    if failures:
        equal(measurement.get("failureKind"), "memory-gates", "measurement failure kind")
    else:
        require(not measurement.get("failureKind") and not measurement.get("error"), "Unexpected measurement failure")
    fields(validation, dict(status=status, memoryGateStatus=memory_status, pixelValidationStatus="passed",
           validationCompleted=True, measurementReportStatus=measurement_status), "validation outcome")
    fields(wrapper, dict(status=status, qualificationStatus=status, sourceCommit=source, executableSHA256=executable_sha,
           exactInstalledApp=app, pngWriterBackend="foundation", installerAcceptance=False, measurementComplete=True,
           completedWarmupCycles=2, completedMeasuredCycles=8, validationCompleted=True, outputCertificates=10,
           inputSHA256=input_sha, certificateSHA256=digest(raw_data["certificate"]), memoryGateStatus=memory_status,
           pixelValidationStatus="passed", measurementReportStatus=measurement_status, validationReportStatus=status,
           phase="validate", exitCode=1 if failures else 0), "resource wrapper")
    runner, runner_raw = read_json(runner_path)
    report["runnerReportSHA256"] = digest(runner_raw)
    bounded_runner(runner, 2640, 1 if failures else 0, "installed runner")
    equal(step_outcome, "failure" if failures else "success", "original step outcome")
    require(not failures or failures == ["physicalFootprintBytes.warmGrowth"],
            "Only sole warm physical-footprint failure is eligible for testing")
    partial = bool(failures)
    report.update(status="eligible-partial-memory" if partial else "eligible-original-resource-pass",
                  testingPackageEligible=True, partialMemoryQualification=partial,
                  fullMemoryQualification=False, originalMemoryGatesPassed=not partial,
                  qualification=("Testing only: original warm physical-footprint gate failed; all original late, RSS, volatile, watchdog, workload, pixel and cleanup gates passed. No new warm allowance is defined."
                                 if partial else "Original finite live-scroll resource gates passed; installer acceptance remains separate."))
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("source")
    parser.add_argument("output", type=Path)
    parser.add_argument("--executable-sha256", required=True)
    parser.add_argument("--archive-sha256", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--runner-report", type=Path, required=True)
    parser.add_argument("--step-outcome", required=True)
    args = parser.parse_args()
    report = dict(schemaVersion=1, status="ineligible", testingPackageEligible=False,
                  partialMemoryQualification=False, fullMemoryQualification=False,
                  installerAcceptance=False, sourceCommit=args.source,
                  originalStepOutcome=args.step_outcome,
                  unchangedLimits=dict(TARGETS, residentWatchdog=RSS_CAP, footprintWatchdog=FOOTPRINT_CAP,
                                       sessionSeconds=180, launcherSeconds=600, cooperativeSeconds=590),
                  scope="Owned injected-pixel finite workload only; no real screen capture, global ceiling, zero-leak, long-duration stability or installer acceptance claim")
    # Never allow a requested report destination to overwrite the source evidence.
    output = args.output.resolve()
    require(output != args.runner_report.resolve() and not output.is_relative_to(args.evidence.resolve()),
            "Classification output must be outside original evidence and runner report")
    try:
        classify(args.evidence, args.source, args.executable_sha256, args.archive_sha256,
                 args.build, args.runner_report, args.step_outcome, report)
    except (OSError, ValueError, TypeError, KeyError, IndexError, AttributeError) as error:
        report.update(status="ineligible", testingPackageEligible=False, partialMemoryQualification=False,
                      fullMemoryQualification=False, error=str(error))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True, allow_nan=False) + "\n")
    print(json.dumps(report, indent=2, sort_keys=True, allow_nan=False))
    return 0 if report["testingPackageEligible"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
