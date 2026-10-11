"""Focused fixtures and mutations for the testing-only live-scroll classifier."""
import copy
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "classify-live-scroll-testing.py"
SPEC = importlib.util.spec_from_file_location("live_scroll_testing", SCRIPT)
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)
SOURCE, EXE, ARCHIVE, INPUT = "a" * 40, "b" * 64, "c" * 64, "d" * 64
APP = "/runner/dist/installed/PicShot.app"


def boundary(phase, uptime, footprint=30000000, resident=250000000, volatile=18000000):
    backing = {}
    for flavor, name in (("standard", "TASK_VM_INFO"), ("purgeable", "TASK_VM_INFO_PURGEABLE")):
        backing[flavor] = dict(flavor=name, kernelReturn=0, requestedNaturalCount=93,
            returnedNaturalCount=93, observedAtUptimeSeconds=uptime - .00001,
            bytes=dict(resident_size=resident, phys_footprint=footprint,
                       purgeable_volatile_resident=volatile, purgeable_volatile_virtual=volatile,
                       purgeable_volatile_pmap=volatile),
            ledgerBytes=dict(ledger_purgeable_volatile=volatile, ledger_purgeable_volatile_compressed=0))
    return dict(phase=phase, uptime=uptime,
                memory=dict(residentBytes=resident, physicalFootprintBytes=footprint), backing=backing)


def cycle(ordinal, footprint):
    base = 1010 + (ordinal - 1) * 40
    times = [0, .1, .2, 18, 19, 19.5, 19.9, 20.01, 20.16, 21.02]
    owners = dict(sessionReleased=True, sourceReleased=True, controlsReleased=True,
                  thumbnailReleased=True, attachedWindowGraphs=0, retainedWindowShells=0)
    provider = dict(liveBytes=0, liveImages=0, allocatedImages=218, releasedImages=218,
                    allocatedBytes=218 * CHECK.VIEWPORT, releasedBytes=218 * CHECK.VIEWPORT,
                    peakLiveImages=2, peakLiveBytes=2 * CHECK.VIEWPORT)
    return dict(ordinal=ordinal, status="passed", warmup=ordinal <= 2, cold=ordinal == 1,
        pngWriterBackend="foundation", finishCallbacks=1, sessionReportedClosed=True,
        ownedSpoolParentRemoved=True, remainingSpoolEntries=[],
        lastProductState=dict(acceptedObservations=218, sampledFrames=218,
            width=1280, height=7136, offset=6176, matched=True, previewUnavailable=False),
        sourceAfterStop=dict(successfulFrames=218, activeReads=0, state="stopped",
            descriptorOpen=False, descriptorCloseConfirmed=True, confirmedStops=1),
        preFinish=dict(acceptedObservations=218, height=7136, offset=6176, sourceReadCount=0,
            cachedPreviewBytes=800000, durableHeight=7104, observedGrowths=190, observedReverseSamples=12),
        output=dict(file="cycle-%02d.png" % ordinal, width=1280, height=7136,
                    layoutBytes=CHECK.OUTPUT, encodedBytes=10000),
        ownership150ms=copy.deepcopy(owners), ownership1000ms=copy.deepcopy(owners),
        provider150ms=copy.deepcopy(provider), providerAfterClose=copy.deepcopy(provider),
        memory=dict(timerTickCount=400, boundarySampleCount=2, residentSampleCount=402,
            physicalFootprintSampleCount=402, backingSampleCount=402, failedResidentSampleCount=0,
            failedPhysicalFootprintSampleCount=0, peakResidentBytes=300000000,
            peakPhysicalFootprintBytes=120000000, peakVolatileResidentBytes=29000000,
            peakVolatileLedgerBytes=29000000),
        boundaries=[boundary(phase, base + delay, footprint) for phase, delay in zip(CHECK.PHASES, times)],
        elapsedSeconds=21.1, explicitOwnerReleaseUptime=base + 20,
        observed150msElapsedSeconds=.17, observed1000msElapsedSeconds=1.03)


def pixel_proof(ordinal):
    return dict(passed=True, pixelEquality=True, hashAvailable=True, comparedBytes=CHECK.OUTPUT,
                expectedWidth=1280, expectedHeight=7136, file="cycle-%02d.png" % ordinal,
                encodedBytes=10000, sha256="e" * 64)


def runner(timeout, code):
    return dict(status="exited", child_returncode=code, exit_code=code, cancel_signal=None,
                sigterm_sent=False, sigkill_sent=False, descendant_cleanup=False,
                termination_reason="exited", timeout_seconds=float(timeout), grace_seconds=10.0,
                duration_seconds=400.0 if timeout == 2640 else 30.0)


def launcher(pid):
    return dict(status="exited", launcherExitCode=0, callbackReceived=True,
        createsNewApplicationInstance=True, ownedExitConfirmed=True, launchedIdentityMatches=True,
        timeoutSeconds=600, selectedAppPath=APP, launchedAppPath=APP,
        launchedExecutablePath=APP + "/Contents/MacOS/PicShot", processIdentifier=pid, elapsedSeconds=400.0)


def fixture(partial=True):
    common = dict(schemaVersion=2, sourceCommit=SOURCE, executableSHA256=EXE,
        bundlePath=APP, architecture="arm64", pngWriterBackend="foundation",
        workload="live-scroll-owned-1280-v1", warmupCycles=2, measuredCycles=8, sourceFramesPerCycle=218,
        viewportWidth=1280, viewportHeight=960, outputWidth=1280, outputHeight=7136,
        preparedRawBytes=CHECK.OUTPUT, cooperativeDeadlineSeconds=590, externalLauncherDeadlineSeconds=600,
        sampleIntervalSeconds=.05, predeclaredTargetsAndGatesBytes=copy.deepcopy(CHECK.TARGETS),
        coldAndPeakTargetsAreDiagnosticOnly=True, installerAcceptance=False, nativeAcquisitionValidated=False,
        pixelVerificationInMeasuredProcess=False, memoryStabilityClaimed=False, zeroLeakClaimed=False,
        inputSHA256=INPUT, entry=boundary("entry", 1000), afterInputValidation=boundary("input", 1001))
    certificate = copy.deepcopy(common)
    certificate.update(mode="certify", status="passed", processIdentifier=2,
        byteConversionFidelity=dict(passed=True, bytesCompared=CHECK.VIEWPORT),
        cycles=[cycle(1, 30000000)], outputCertificate=pixel_proof(1),
        expectedReference=dict(file="expected-reference.png", sha256="e" * 64), final=boundary("final", 1032))
    measurement = copy.deepcopy(common)
    footprint = ([26282432, 26315328, 35604992, 35654208, 35752512,
                  35834432, 36981312, 35965504, 36702784, 36948544] if partial else [30000000] * 10)
    measurement.update(mode="measure", processIdentifier=3, cycles=[cycle(i, fp) for i, fp in enumerate(footprint, 1)],
        final=boundary("final", 1392), elapsedSeconds=392.1, measurementComplete=True,
        measurementStatus="complete", completedWarmupCycles=2, completedMeasuredCycles=8,
        pixelValidationStatus="pending-independent-validation", independentValidationRequired=True)
    validation = copy.deepcopy(common)
    validation.update(mode="validate", processIdentifier=4, measurementComplete=True, measurementStatus="complete",
        completedWarmupCycles=2, completedMeasuredCycles=8, pixelValidationStatus="passed", validationCompleted=True,
        outputCertificates=[dict(pixel_proof(i), ordinal=i, expectedEncodedBytes=10000) for i in range(1, 11)])
    comparison = dict(passed=True, dimensionsMatch=True, meanAbsoluteRGBAError=0.0,
                      fractionOfChannelsDifferingByMoreThan8=0.0)
    demo = dict(status="passed", sourceCommit=SOURCE, bundlePath=APP, build="226", version="0.22.0",
                globalInputPosted=False, installerAcceptance=False)
    for name in ("illustratedCase", "ordinaryTextCase", "movementCase"):
        demo[name] = dict(status="passed", productSessionClosed=True,
                         finishCallbacks=1, finishButtonCompletionCallbacks=1,
                         nativeReferenceComparison=copy.deepcopy(comparison), referenceComparison=copy.deepcopy(comparison))
    return dict(certificate=certificate, measurement=measurement, validation=validation, demo=demo,
        identity=dict(status="passed", sourceCommit=SOURCE, executableSHA256=EXE, archiveSHA256=ARCHIVE,
                      build="226", version="0.22.0", architecture="arm64", bundlePath=APP,
                      executablePath=APP + "/Contents/MacOS/PicShot"),
        launchers={name: launcher(pid) for name, pid in (("demo", 1), ("certify", 2), ("measure", 3), ("validate", 4))})


def write_fixture(root, data, refresh=True):
    def put(name, value):
        raw = (json.dumps(value, sort_keys=True) + "\n").encode()
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
        return CHECK.digest(raw)
    certificate, measurement, validation = (data[key] for key in ("certificate", "measurement", "validation"))
    cert_hash = put("resource/upload/input-certificate.json", certificate)
    certify = dict(certificate, elapsedSeconds=32.1)
    put("resource/upload/certify-live-scroll-resource-certificate-run.json", certify)
    put("resource/upload/certify-summary.json", certify)
    # Rebind mutations so checks reach the changed raw evidence instead of merely
    # rejecting its checksum; gate/status fields remain internally consistent.
    endpoints = [dict(c["boundaries"][8]["memory"], combinedVolatileLedger=sum(
        c["boundaries"][8]["backing"]["purgeable"]["ledgerBytes"].values())) for c in measurement["cycles"]]
    if refresh:
        assessment, failed = CHECK.assess(measurement, endpoints)
        measurement["budgetAssessment"] = assessment
        memory_status = "failed" if failed else "passed"
        measurement.update(status="failed" if failed else "measured-awaiting-pixel-validation", memoryGateStatus=memory_status)
        if failed:
            measurement["failureKind"] = "memory-gates"
    status = "failed" if measurement["memoryGateStatus"] == "failed" else "passed"
    measurement["certificateSHA256"] = cert_hash
    measurement_hash = put("resource/upload/measure-live-scroll-resource-measurement.json", measurement)
    put("resource/upload/measure-summary.json", measurement)
    validation.update(status=status, memoryGateStatus=measurement["memoryGateStatus"],
                      measurementReportStatus=measurement["status"], certificateSHA256=cert_hash,
                      measurementReportSHA256=measurement_hash)
    put("resource/upload/measure-live-scroll-resource-validation.json", validation)
    put("resource/upload/measure-validation-summary.json", validation)
    for name, path in (("certify", "certify-summary"), ("measure", "measure-summary"), ("validate", "measure-validation-summary")):
        put("resource/upload/" + path + ".json.launcher.json", data["launchers"][name])
    put("package-identity.json", data["identity"])
    put("demo/demo.json", data["demo"])
    put("demo/demo.json.launcher.json", data["launchers"]["demo"])
    put("demo-launch.json", runner(660, 0))
    code = 1 if status == "failed" else 0
    put("resource/upload/resource-wrapper.json", dict(status=status, qualificationStatus=status,
        sourceCommit=SOURCE, executableSHA256=EXE, exactInstalledApp=APP, pngWriterBackend="foundation",
        installerAcceptance=False, measurementComplete=True, completedWarmupCycles=2, completedMeasuredCycles=8,
        validationCompleted=True, outputCertificates=10, inputSHA256=INPUT, certificateSHA256=cert_hash,
        memoryGateStatus=measurement["memoryGateStatus"], pixelValidationStatus="passed",
        measurementReportStatus=measurement["status"], validationReportStatus=status, phase="validate", exitCode=code))
    return runner(2640, code), "failure" if code else "success"


class ClassificationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "evidence"
        self.runner = Path(self.temp.name) / "runner.json"
        self.output = Path(self.temp.name) / "classification.json"

    def prepare(self, data=None, refresh=True):
        row, outcome = write_fixture(self.root, data or fixture(), refresh)
        self.runner.write_text(json.dumps(row))
        return outcome

    def classify(self, outcome="failure", **changes):
        args = dict(root=self.root, source=SOURCE, executable_sha=EXE, archive_sha=ARCHIVE,
                    build="226", runner_path=self.runner, step_outcome=outcome, report={})
        args.update(changes)
        return CHECK.classify(**args)

    def test_sole_warm_footprint_failure_is_explicitly_partial(self):
        self.prepare()
        result = self.classify()
        self.assertEqual(result["status"], "eligible-partial-memory")
        self.assertTrue(result["testingPackageEligible"])
        self.assertTrue(result["partialMemoryQualification"])
        self.assertFalse(result["fullMemoryQualification"])
        self.assertEqual(result["originalResourceStatus"], "failed")
        self.assertEqual(result["originalStepOutcome"], "failure")
        self.assertEqual(result["failedOriginalMemoryGates"], ["physicalFootprintBytes.warmGrowth"])
        self.assertEqual(result["recomputedBudgetAssessment"]["physicalFootprintBytes"]["measuredGrowth"], 10633216)
        self.assertEqual(sum(result["recomputedBudgetAssessment"]["physicalFootprintBytes"]["lateThreeIncrements"]), -32768)

    def test_original_full_pass_remains_eligible(self):
        self.prepare(fixture(False))
        result = self.classify("success")
        self.assertEqual(result["status"], "eligible-original-resource-pass")
        self.assertFalse(result["partialMemoryQualification"])
        self.assertTrue(result["originalMemoryGatesPassed"])
        self.assertFalse(result["fullMemoryQualification"])
        self.assertFalse(result["installerAcceptance"])

    def test_warm_rss_and_volatile_alone_and_late_sum_failures_rejected(self):
        for metric in ("residentBytes", "volatile", "physicalFootprintBytes"):
            with self.subTest(metric=metric):
                data = fixture(False)
                if metric == "volatile":
                    data["measurement"]["cycles"][1]["boundaries"][8]["backing"]["purgeable"]["ledgerBytes"]["ledger_purgeable_volatile"] = 0
                elif metric == "residentBytes":
                    data["measurement"]["cycles"][1]["boundaries"][8]["memory"][metric] -= 20000000
                else:
                    # Each increment passes, but the final three sum exceeds one viewport.
                    for index, amount in ((6, -6000000), (7, -4000000), (8, -2000000)):
                        data["measurement"]["cycles"][index]["boundaries"][8]["memory"][metric] += amount
                self.prepare(data)
                with self.assertRaisesRegex(ValueError, "Only sole"):
                    self.classify()

    def test_other_raw_memory_gates_and_watchdogs_rejected(self):
        for key, amount in (("residentBytes", 20000000), ("physicalFootprintBytes", 20000000),
                            ("volatile", 20000000), ("residentBytes", CHECK.RSS_CAP),
                            ("physicalFootprintBytes", CHECK.FOOTPRINT_CAP)):
            with self.subTest(key=key, amount=amount):
                data = fixture()
                point = data["measurement"]["cycles"][-1]["boundaries"][8]
                if key == "volatile":
                    point["backing"]["purgeable"]["ledgerBytes"]["ledger_purgeable_volatile"] += amount
                else:
                    point["memory"][key] += amount
                self.prepare(data)
                with self.assertRaises(ValueError):
                    self.classify()

    def test_incomplete_wrong_identity_pixel_owner_timing_and_sampler_rejected(self):
        mutations = [
            ("frames", lambda d: d["measurement"]["cycles"][0]["sourceAfterStop"].update(successfulFrames=217)),
            ("owner", lambda d: d["measurement"]["cycles"][0]["ownership1000ms"].update(sourceReleased=False)),
            ("spool", lambda d: d["measurement"]["cycles"][0].update(remainingSpoolEntries=["leaked"])),
            ("provider", lambda d: d["measurement"]["cycles"][0]["provider150ms"].update(liveBytes=1)),
            ("pixels", lambda d: d["validation"]["outputCertificates"][0].update(pixelEquality=False)),
            ("missing certificate", lambda d: d["validation"]["outputCertificates"].pop()),
            ("wrong output", lambda d: d["validation"]["outputCertificates"][0].update(file="cycle-02.png")),
            ("hash", lambda d: d["validation"]["outputCertificates"][0].update(sha256="not-a-hash")),
            ("backend", lambda d: d["measurement"].update(pngWriterBackend="posix")),
            ("source", lambda d: d["measurement"].update(sourceCommit="f" * 40)),
            ("exe", lambda d: d["identity"].update(executableSHA256="f" * 64)),
            ("demo", lambda d: d["demo"]["illustratedCase"].update(productSessionClosed=False)),
            ("launch", lambda d: d["launchers"]["measure"].update(ownedExitConfirmed=False)),
            ("deadline", lambda d: d["measurement"].update(cooperativeDeadlineSeconds=600)),
            ("sample", lambda d: d["measurement"]["cycles"][0]["memory"].update(residentSampleCount=401)),
            ("peak", lambda d: d["measurement"]["cycles"][0]["memory"].update(peakPhysicalFootprintBytes=CHECK.FOOTPRINT_CAP + 1)),
            ("missing ledger", lambda d: d["measurement"]["entry"]["backing"]["purgeable"]["ledgerBytes"].pop("ledger_purgeable_volatile")),
            ("boolean count", lambda d: d["measurement"]["cycles"][0].update(finishCallbacks=True)),
        ]
        for label, mutate in mutations:
            with self.subTest(label=label):
                data = fixture()
                mutate(data)
                self.prepare(data)
                with self.assertRaises((ValueError, KeyError)):
                    self.classify()

    def test_missing_cycle_and_false_summary_do_not_pass(self):
        data = fixture()
        self.prepare(data)
        data["measurement"]["cycles"].pop()
        self.prepare(data, refresh=False)
        with self.assertRaisesRegex(ValueError, "2\\+8"):
            self.classify()
        data = fixture()
        self.prepare(data)
        data["measurement"]["budgetAssessment"]["warmAndLateGatesPassed"] = True
        self.prepare(data, refresh=False)
        with self.assertRaisesRegex(ValueError, "recomputed"):
            self.classify()

    def test_hash_binding_missing_evidence_runner_and_step_rejected(self):
        self.prepare()
        for field, value in (("executable_sha", "f" * 64), ("archive_sha", "f" * 64),
                             ("source", "f" * 40), ("build", "225"), ("step_outcome", "success")):
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.classify(**{field: value})
        path = self.root / "resource/upload/measure-live-scroll-resource-measurement.json"
        path.write_bytes(path.read_bytes() + b" ")
        with self.assertRaisesRegex(ValueError, "measurement binding"):
            self.classify()
        self.prepare()
        row = json.loads(self.runner.read_text())
        row["sigterm_sent"] = True
        self.runner.write_text(json.dumps(row))
        with self.assertRaisesRegex(ValueError, "sigterm"):
            self.classify()
        self.prepare()
        (self.root / "resource/upload/measure-validation-summary.json").unlink()
        with self.assertRaises(OSError):
            self.classify()

    def test_cli_preserves_success_failure_reports_and_originals(self):
        self.prepare()
        inputs = {p: p.read_bytes() for p in self.root.rglob("*.json")}
        command = [sys.executable, "-O", str(SCRIPT), str(self.root), SOURCE, str(self.output),
                   "--executable-sha256", EXE, "--archive-sha256", ARCHIVE, "--build", "226",
                   "--runner-report", str(self.runner), "--step-outcome", "failure"]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        report = json.loads(self.output.read_text())
        self.assertFalse(report["installerAcceptance"])
        self.assertFalse(report["fullMemoryQualification"])
        self.assertEqual(inputs, {p: p.read_bytes() for p in self.root.rglob("*.json")})
        missing = self.root / "demo/demo.json"
        missing.write_text("{invalid JSON")
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        report = json.loads(self.output.read_text())
        self.assertEqual(report["status"], "ineligible")
        self.assertFalse(report["testingPackageEligible"])
        self.assertIn("error", report)


if __name__ == "__main__":
    unittest.main()
