"""Portable synthetic report contracts, never native memory or PNG evidence.

The failed control's scalar values come from candidate223: ten completed cycles,
9,863,168 bytes of warm footprint growth against the unchanged 9,830,400 gate.
All identities, certificates, timing, and the candidate are synthetic. No native
app or image writer is launched, and no pixel comparison is claimed by tests.
"""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("live_scroll_png_pair", SCRIPTS / "compare-live-scroll-png-pair.py")
PAIR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PAIR)
SOURCE = "a" * 40
GATES = dict(coldFinalGrowth=26607616, coldSampledGrowth=129171456,
             lateIntervalAndSum=4915200, measuredGrowth=9830400)
RSS = [229539840, 256049152, 246693888, 227131392, 227278848,
       227393536, 236781568, 236912640, 238469120, 240664576]
FOOTPRINT = [26790144, 26921280, 35424576, 36210944, 36358400,
             36473088, 36522304, 36653376, 36735296, 36784448]
PIXEL_BYTES = 36536320
ENCODED_BYTES = 22041073


def dump(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True) + "\n")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def reading(rss, footprint):
    return dict(memory=dict(residentBytes=rss, physicalFootprintBytes=footprint),
                backing=dict(standard=dict(kernelReturn=0, bytes=dict(resident_size=rss, phys_footprint=footprint)),
                             purgeable=dict(kernelReturn=0, ledgerBytes=dict(ledger_purgeable_volatile=18513920,
                                                                         ledger_purgeable_volatile_compressed=0))))


def documents(backend, growth=None):
    """Create internally consistent scalar reports using the fixed 223 workload."""
    if growth is None:
        growth = 9863168 if backend == "foundation" else 9830400
    footprint = FOOTPRINT.copy()
    adjustment = growth - (FOOTPRINT[-1] - FOOTPRINT[1])
    footprint[2:] = [value + adjustment for value in footprint[2:]]
    memory_passed = growth <= GATES["measuredGrowth"]
    status = "passed" if memory_passed else "failed"
    identity = dict(sourceCommit=SOURCE, executableSHA256="b" * 64,
                    inputSHA256="c" * 64, pngWriterBackend=backend)
    workload = dict(workload="live-scroll-owned-1280-v1", warmupCycles=2, measuredCycles=8,
                    sourceFramesPerCycle=218, viewportWidth=1280, viewportHeight=960,
                    outputWidth=1280, outputHeight=7136, preparedRawBytes=PIXEL_BYTES)
    certificate = dict(identity, **workload, status="passed", mode="certify",
                       bundlePath="/installed/PicShot.app", pixelValidationStatus="passed")
    owners = dict(controlsReleased=True, sessionReleased=True, sourceReleased=True, thumbnailReleased=True,
                  attachedWindowGraphs=0, retainedWindowShells=0)
    provider = dict(allocatedBytes=1071513600, releasedBytes=1071513600, allocatedImages=218,
                    releasedImages=218, liveBytes=0, liveImages=0, peakLiveBytes=9830400, peakLiveImages=2)
    cycles, proofs = [], []
    for ordinal in range(1, 11):
        filename = f"cycle-{ordinal:02d}.png"
        boundary = reading(RSS[ordinal - 1], footprint[ordinal - 1])
        boundary.update(phase="released-plus-1000ms", uptime=ordinal * 34.0)
        cycles.append(dict(ordinal=ordinal, status="passed", warmup=ordinal <= 2, pngWriterBackend=backend,
                           finishCallbacks=1, elapsedSeconds=33.4, sessionReportedClosed=True,
                           lastProductState=dict(acceptedObservations=218, width=1280, height=7136),
                           output=dict(file=filename, width=1280, height=7136, layoutBytes=PIXEL_BYTES,
                                       encodedBytes=ENCODED_BYTES),
                           sourceAfterStop=dict(successfulFrames=218, activeReads=0, descriptorCloseConfirmed=True,
                                                descriptorOpen=False, confirmedStops=1, state="stopped"),
                           ownedSpoolParentRemoved=True, remainingSpoolEntries=[],
                           ownership150ms=copy.deepcopy(owners), ownership1000ms=copy.deepcopy(owners),
                           provider150ms=copy.deepcopy(provider), providerAfterClose=copy.deepcopy(provider),
                           memory=dict(timerTickCount=668, backingSampleCount=670, residentSampleCount=670,
                                       physicalFootprintSampleCount=670, failedResidentSampleCount=0,
                                       failedPhysicalFootprintSampleCount=0,
                                       peakResidentBytes=267665408, peakPhysicalFootprintBytes=118966464),
                           boundaries=[boundary]))
        proofs.append(dict(ordinal=ordinal, file=filename, encodedBytes=ENCODED_BYTES,
                           expectedEncodedBytes=ENCODED_BYTES, sha256="d" * 64, hashAvailable=True,
                           passed=True, pixelEquality=True, comparedBytes=PIXEL_BYTES))
    assessment = dict(warmAndLateGatesPassed=memory_passed, coldAndPeakTargetsAreDiagnosticOnly=True)
    for key, endpoints in [("residentBytes", RSS), ("physicalFootprintBytes", footprint),
                           ("combinedVolatileLedger", [18513920] * 10)]:
        delta = endpoints[-1] - endpoints[1]
        late = [endpoints[i] - endpoints[i - 1] for i in range(7, 10)]
        passed = delta <= GATES["measuredGrowth"] and all(x <= GATES["lateIntervalAndSum"] for x in late) \
            and sum(late) <= GATES["lateIntervalAndSum"]
        assessment[key] = dict(measuredGrowth=delta, lateThreeIncrements=late, settledEndpoints=endpoints.copy())
        assessment[key]["passed" if key == "combinedVolatileLedger" else "warmAndLateGatePassed"] = passed
    measurement = dict(identity, **workload, cycles=cycles, measurementComplete=True, measurementStatus="complete",
                       completedWarmupCycles=2, completedMeasuredCycles=8, memoryGateStatus=status,
                       status="measured-awaiting-pixel-validation" if memory_passed else "failed",
                       budgetAssessment=assessment, predeclaredTargetsAndGatesBytes=copy.deepcopy(GATES),
                       entry=reading(70778880, 21006400), afterInputValidation=reading(70811648, 21039168),
                       final=reading(RSS[-1], footprint[-1]), elapsedSeconds=340.0,
                       bundlePath="/installed/PicShot.app", mode="measure")
    if not memory_passed:
        measurement.update(failureKind="memory-gates", error="Predeclared measured/late growth gate exceeded")
    validation = dict(identity, **workload, validationCompleted=True, measurementComplete=True,
                      measurementStatus="complete", completedWarmupCycles=2, completedMeasuredCycles=8,
                      pixelValidationStatus="passed", memoryGateStatus=status, status=status,
                      outputCertificates=proofs, mode="validate", bundlePath="/installed/PicShot.app")
    wrapper = dict(identity, status=status, qualificationStatus=status, memoryGateStatus=status,
                   measurementComplete=True, completedWarmupCycles=2, completedMeasuredCycles=8,
                   pixelValidationStatus="passed", validationCompleted=True, outputCertificates=copy.deepcopy(proofs),
                   exactInstalledApp="/installed/PicShot.app", installerAcceptance=False)
    return dict(certificate=certificate, measurement=measurement, validation=validation, wrapper=wrapper,
                exitCode=0 if memory_passed else 1)


def write_cell(root, backend, reports):
    cell = root / backend
    certificate = cell / "input/certificate.json"
    dump(certificate, reports["certificate"])
    for kind in ["measurement", "validation", "wrapper"]:
        reports[kind].setdefault("certificateSHA256", digest(certificate))
    measurement = cell / "measure/live-scroll-resource-measurement.json"
    dump(measurement, reports["measurement"])
    reports["validation"]["measurementReportSHA256"] = digest(measurement)
    dump(cell / "measure/live-scroll-resource-validation.json", reports["validation"])
    dump(cell / "resource-wrapper.json", reports["wrapper"])
    (root / f"{backend}-exit-code.txt").write_text(str(reports["exitCode"]) + "\n")


class LiveScrollPNGPairTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def pair(self, control=None, candidate=None):
        write_cell(self.root, "foundation", control or documents("foundation"))
        write_cell(self.root, "posix", candidate or documents("posix"))

    def assert_rejected(self, candidate):
        self.pair(candidate=candidate)
        try:
            result = PAIR.compare(self.root, SOURCE)
        except (ValueError, KeyError, TypeError, OSError):
            return
        self.assertEqual(result["status"], "incomplete", "Altered evidence was accepted as an observed pair")
        self.assertFalse(result["candidatePromoted"])

    def test_complete_failed_control_and_qualified_candidate_are_retained(self):
        self.pair()
        result = PAIR.compare(self.root, SOURCE)
        self.assertEqual(result["status"], "observed")
        self.assertEqual(result["completeCycles"], 20)
        self.assertEqual(result["independentPixelCertificates"], 20)
        self.assertEqual(result["cells"]["foundation"]["qualificationStatus"], "failed")
        self.assertEqual(result["cells"]["foundation"]["exitCode"], 1)
        self.assertEqual(result["cells"]["posix"]["qualificationStatus"], "passed")
        self.assertFalse(result["allMemoryGatesPassed"])
        self.assertFalse(result["candidatePromoted"])
        self.assertFalse(result["installerAcceptance"])
        self.assertEqual(result["candidateDecision"], "requires-full-trace-review")
        self.assertEqual(result["measuredGrowthDifferenceCandidateMinusControl"]["physicalFootprintBytes"], -32768)

    def test_both_failed_cells_are_observed_without_hiding_failures(self):
        self.pair(candidate=documents("posix", 9895936))
        result = PAIR.compare(self.root, SOURCE)
        self.assertEqual(result["status"], "observed")
        self.assertEqual([result["cells"][name]["qualificationStatus"] for name in result["order"]], ["failed", "failed"])
        self.assertEqual([result["cells"][name]["exitCode"] for name in result["order"]], [1, 1])
        self.assertEqual(result["candidateDecision"], "reject-no-qualified-footprint-improvement")
        self.assertFalse(result["allMemoryGatesPassed"])
        self.assertFalse(result["candidatePromoted"])

    def test_no_improvement_never_promotes_even_when_both_qualify(self):
        for control_growth in [9830400, 9797632]:
            with self.subTest(control_growth=control_growth):
                self.pair(control=documents("foundation", control_growth), candidate=documents("posix", 9830400))
                result = PAIR.compare(self.root, SOURCE)
                self.assertEqual(result["status"], "observed")
                self.assertTrue(result["allMemoryGatesPassed"])
                self.assertEqual(result["candidateDecision"], "reject-no-qualified-footprint-improvement")
                self.assertFalse(result["candidatePromoted"])

    def test_incomplete_workload_rejected(self):
        for field, value in [("measurementComplete", False), ("measurementStatus", "incomplete"),
                             ("completedWarmupCycles", 1), ("completedMeasuredCycles", 7)]:
            with self.subTest(field=field):
                data = documents("posix"); data["measurement"][field] = value
                self.assert_rejected(data)
        for kind, field in [("measurement", "cycles"), ("validation", "outputCertificates")]:
            with self.subTest(field=field):
                data = documents("posix"); data[kind][field].pop()
                self.assert_rejected(data)

    def test_cycle_order_finish_warmup_and_accepted_work_rejected(self):
        for key, value in [("ordinal", 1), ("status", "failed"), ("warmup", True), ("finishCallbacks", 0)]:
            with self.subTest(key=key):
                data = documents("posix"); data["measurement"]["cycles"][-1][key] = value
                self.assert_rejected(data)
        for owner, field in [("sourceAfterStop", "successfulFrames"), ("lastProductState", "acceptedObservations")]:
            with self.subTest(field=field):
                data = documents("posix"); data["measurement"]["cycles"][-1][owner][field] = 217
                self.assert_rejected(data)

    def test_source_executable_input_and_backend_identity_mismatch_rejected(self):
        for kind in ["certificate", "measurement", "validation", "wrapper"]:
            for key in ["sourceCommit", "executableSHA256", "inputSHA256", "pngWriterBackend"]:
                with self.subTest(kind=kind, key=key):
                    data = documents("posix"); data[kind][key] = "unexpected"
                    self.assert_rejected(data)
        for key in ["executableSHA256", "inputSHA256"]:
            with self.subTest(pair_identity=key):
                data = documents("posix")
                for kind in ["certificate", "measurement", "validation", "wrapper"]:
                    data[kind][key] = "e" * 64
                self.assert_rejected(data)

    def test_stale_measurement_hash_rejected(self):
        self.pair()
        path = self.root / "posix/measure/live-scroll-resource-measurement.json"
        path.write_text(path.read_text() + " ")
        self.assertEqual(PAIR.compare(self.root, SOURCE)["status"], "incomplete")

    def test_output_hash_pixel_or_byte_mismatch_rejected(self):
        for key, value in [("sha256", "bad"), ("sha256", "e" * 64), ("file", "wrong.png"),
                           ("encodedBytes", ENCODED_BYTES - 1), ("expectedEncodedBytes", ENCODED_BYTES - 1),
                           ("pixelEquality", False), ("passed", False), ("comparedBytes", PIXEL_BYTES - 1)]:
            with self.subTest(key=key, value=value):
                data = documents("posix"); data["validation"]["outputCertificates"][-1][key] = value
                self.assert_rejected(data)

    def test_missing_or_retained_ownership_rejected(self):
        for phase in ["ownership150ms", "ownership1000ms"]:
            for key in ["controlsReleased", "sessionReleased", "sourceReleased", "thumbnailReleased"]:
                for missing in [False, True]:
                    with self.subTest(phase=phase, key=key, missing=missing):
                        data = documents("posix"); owner = data["measurement"]["cycles"][-1][phase]
                        if missing: del owner[key]
                        else: owner[key] = False
                        self.assert_rejected(data)
            for key in ["attachedWindowGraphs", "retainedWindowShells"]:
                with self.subTest(phase=phase, key=key):
                    data = documents("posix"); data["measurement"]["cycles"][-1][phase][key] = 1
                    self.assert_rejected(data)

    def test_spool_source_and_provider_cleanup_rejected(self):
        for key, value in [("ownedSpoolParentRemoved", False), ("remainingSpoolEntries", ["frame.raw"])]:
            with self.subTest(key=key):
                data = documents("posix"); data["measurement"]["cycles"][-1][key] = value
                self.assert_rejected(data)
        for key, value in [("activeReads", 1), ("descriptorCloseConfirmed", False)]:
            with self.subTest(key=key):
                data = documents("posix"); data["measurement"]["cycles"][-1]["sourceAfterStop"][key] = value
                self.assert_rejected(data)
        for phase in ["provider150ms", "providerAfterClose"]:
            with self.subTest(phase=phase):
                data = documents("posix"); data["measurement"]["cycles"][-1][phase]["liveBytes"] = 4915200
                self.assert_rejected(data)

    def test_changed_gate_in_one_cell_rejected(self):
        data = documents("posix")
        data["measurement"]["predeclaredTargetsAndGatesBytes"]["measuredGrowth"] += 32768
        self.assert_rejected(data)

    def test_same_changed_gates_in_both_cells_rejected(self):
        a, b = documents("foundation"), documents("posix")
        for data in [a, b]:
            data["measurement"]["predeclaredTargetsAndGatesBytes"]["measuredGrowth"] += 32768
        self.pair(a, b)
        try: result = PAIR.compare(self.root, SOURCE)
        except (ValueError, KeyError, TypeError, OSError): return
        self.assertEqual(result["status"], "incomplete", "Both cells must retain the fixed candidate223 gates")

    def test_per_cycle_backend_mismatch_rejected(self):
        data = documents("posix"); data["measurement"]["cycles"][-1]["pngWriterBackend"] = "foundation"
        self.assert_rejected(data)

    def test_certificate_hash_mismatch_rejected(self):
        data = documents("posix"); data["validation"]["certificateSHA256"] = "e" * 64
        self.assert_rejected(data)

    def test_exact_installed_app_mismatch_rejected(self):
        data = documents("posix"); data["wrapper"]["exactInstalledApp"] = "/different/PicShot.app"
        self.assert_rejected(data)

    def test_output_dimensions_and_fixed_filename_rejected(self):
        for field, value in [("width", 640), ("height", 7135), ("layoutBytes", PIXEL_BYTES - 4)]:
            with self.subTest(field=field):
                data = documents("posix"); data["measurement"]["cycles"][-1]["output"][field] = value
                self.assert_rejected(data)
        data = documents("posix")
        data["measurement"]["cycles"][-1]["output"]["file"] = "cycle-01.png"
        data["validation"]["outputCertificates"][-1]["file"] = "cycle-01.png"
        self.assert_rejected(data)

    def test_hidden_memory_failure_or_wrong_exit_rejected(self):
        for kind, key, value in [("measurement", "status", "passed"), ("measurement", "memoryGateStatus", "failed"),
                                 ("validation", "memoryGateStatus", "failed"), ("wrapper", "qualificationStatus", "failed")]:
            with self.subTest(kind=kind, key=key):
                data = documents("posix"); data[kind][key] = value
                self.assert_rejected(data)
        data = documents("posix"); data["exitCode"] = 1
        self.assert_rejected(data)

    def test_cli_persists_observed_pair_with_failed_control(self):
        self.pair()
        completed = subprocess.run([sys.executable, "-I", str(SCRIPTS / "compare-live-scroll-png-pair.py"),
                                    str(self.root), SOURCE], capture_output=True, text=True)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        result = json.loads((self.root / "comparison.json").read_text())
        self.assertEqual(result["cells"]["foundation"]["qualificationStatus"], "failed")
        self.assertFalse(result["allMemoryGatesPassed"])

    def test_outer_shell_runs_both_cells_after_nonzero_control(self):
        scripts = self.root / "stub-repo/scripts"; scripts.mkdir(parents=True)
        shutil.copy2(SCRIPTS / "live-scroll-png-pair.sh", scripts / "live-scroll-png-pair.sh")
        (scripts / "run-live-scroll-resource.sh").write_text(
            '#!/bin/bash\nset -eu\nmkdir -p "$2"\nprintf "%s|%s|%s\\n" "$1" "$3" "$4" > "$2/call.txt"\n'
            'if [ "$4" = foundation ]; then exit 1; fi\nexit 0\n')
        (scripts / "compare-live-scroll-png-pair.py").write_text(
            'from pathlib import Path\nimport sys\nr=Path(sys.argv[1])\n'
            'assert (r/"foundation-exit-code.txt").read_text().strip()=="1"\n'
            'assert (r/"posix-exit-code.txt").read_text().strip()=="0"\n'
            'assert (r/"foundation/call.txt").is_file() and (r/"posix/call.txt").is_file()\n'
            '(r/"comparison-called.txt").write_text(sys.argv[2])\n')
        evidence = self.root / "pair-evidence"
        completed = subprocess.run(["bash", str(scripts / "live-scroll-png-pair.sh"), "/installed/PicShot.app",
                                    str(evidence), SOURCE], capture_output=True, text=True)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual((evidence / "comparison-called.txt").read_text(), SOURCE)
        for backend in ["foundation", "posix"]:
            self.assertEqual((evidence / backend / "call.txt").read_text().strip(),
                             f"/installed/PicShot.app|{SOURCE}|{backend}")


if __name__ == "__main__":
    unittest.main()
