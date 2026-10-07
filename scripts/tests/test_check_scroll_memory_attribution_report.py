"""Synthetic checker mutation tests; these are not native memory observations."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("checker", Path(__file__).parents[1] / "check-scroll-memory-attribution-report.py")
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


def memory():
    def flavor(name):
        value = {"flavor": name, "kernelReturn": 0, "requestedNaturalCount": 100,
                 "returnedNaturalCount": 100, "observedAtUptimeSeconds": 1234.0,
                 "bytes": {"resident_size": 4096, "phys_footprint": 4096},
                 "ledgerBytes": {"ledger_purgeable_nonvolatile": -4096}}
        if name == "TASK_VM_INFO_PURGEABLE":
            value["bytes"].update(purgeable_volatile_resident=0, purgeable_volatile_virtual=0, purgeable_volatile_pmap=0)
        return value
    return {"residentBytes": 4096, "physicalFootprintBytes": 4096,
            "backingAccounting": {"standard": flavor("TASK_VM_INFO"), "purgeable": flavor("TASK_VM_INFO_PURGEABLE")}}


def synthetic(mode="source-create"):
    report = {"schemaVersion": 1, "mode": mode, "status": "observed", "productionSourceCommit": "a" * 40,
              "diagnosticOverlayCommit": "b" * 40, "sourceCommit": "b" * 40, "executableSHA256": "c" * 64,
              "architecture": "arm64", "buildMode": "release", "processIdentifier": 100,
              "warmupCycles": 8, "measuredCycles": 16, "completedWarmupCycles": 8, "completedMeasuredCycles": 16,
              "sourcesPerCycle": 4, "cooperativeDeadlineSeconds": 240, "sampleIntervalSeconds": 0.05,
              "settlingDelaySeconds": 0.15, "maximumConcurrentWorkloadTasks": 1, "fullOutputRasters": 0,
              "sampledResidentCeilingBytes": CHECK.RSS_CAP, "sampledPhysicalFootprintCeilingBytes": CHECK.FOOTPRINT_CAP,
              "elapsedSeconds": 100.0, "sampledMemory": {"timerTickCount": 100, "boundarySampleCount": 20,
              "residentSampleCount": 120, "physicalFootprintSampleCount": 120, "failedResidentSampleCount": 0,
              "failedPhysicalFootprintSampleCount": 0, "peakResidentBytes": 4096, "peakPhysicalFootprintBytes": 4096}}
    for key in ("diagnosticOnly", "separateProcessRequired", "observationsComplete", "outerDeadlineRequired", "endToEndFixtureUnchanged"):
        report[key] = True
    for key in ("deliveredBinary", "purgeabilityInferredFromRSSFootprintGap", "zeroLeakClaim", "stabilityAssessed", "captureStarted", "permissionRequests", "globalInputPosted", "networkUsed", "memoryPressureOrSystemSettingsChanged", "allocatorPurgeAttempted"):
        report[key] = False
    for key in ("scope", "backingAccountingScope", "backingAccountingSampling", "watchdogScope", "operatingSystem", "bundlePath", "ownershipScope"):
        report[key] = "Synthetic unit-test metadata only"
    for key in ("beforeWarmup", "baselineAfterWarmup", "afterCyclesBeforeInputRevalidation", "finalAfterCleanup"):
        report[key] = memory()
    for phase, count in (("warmups", 8), ("cycles", 16)):
        rows = []
        for index in range(count):
            name, width, height, axis = CHECK.PROFILES[index % 4]
            row = {"index": index + 1, "phase": "warmup" if phase == "warmups" else "measured",
                   "profile": name, "width": width, "height": height, "axis": axis, "rgbaReferenceBytes": width * height * 4,
                   "before": memory(), "settledAfterCleanup": memory(), "cleanup": dict.fromkeys(CHECK.CLEANUP, 0)}
            row.update(zip(CHECK.COUNT_FIELDS, CHECK.COUNTS[mode]))
            stages = []
            for source in range(4):
                stage = {"sourceIndex": source, "before": memory(), "afterPool": memory()}
                if mode in ("source-create", "capture-hash", "png-spool", "stitch-overlap", "shared-accept"):
                    stage["afterSourceCreation"] = memory(); stage["afterOperationWhileSourceAlive"] = memory()
                if mode == "shared-accept":
                    stage["afterAcceptance"] = memory(); stage["acceptedSources"] = source + 1
                if mode == "capture-hash": stage["rgbaSHA256"] = "d" * 64
                if mode == "png-spool": stage["encodedBytes"] = 1024
                if mode == "overview": stage["renderedPixels"] = 800 * 400
                stages.append(stage)
            if mode == "detail":
                stages.append({"stage": "two-detail-tiles", "before": memory(), "afterPool": memory(), "renderCounts": {"tiles": 2}})
            row["phases"] = stages; rows.append(row)
        report[phase] = rows
    if mode in ("stitch-overlap", "overview", "detail"):
        report.update(preparedInputsUnchanged=True, inputManifestSHA256="e" * 64,
                      inputFileIdentities=[{"name": f"{profile[0]}-{i}.png", "bytes": 1024, "sha256": "f" * 64} for profile in CHECK.PROFILES for i in range(4)])
    return report


class ReportTests(unittest.TestCase):
    def check(self, report):
        return CHECK.validate(report, "a" * 40, "b" * 40, report["mode"], "c" * 64, "b" * 40)

    def test_all_cells_accept_returned_zero_and_negative_ledger(self):
        for mode in CHECK.COUNTS:
            with self.subTest(mode=mode):
                result = self.check(synthetic(mode))
                self.assertEqual(result["growthFromWarmup"]["volatileResidentBytes"], 0)
                self.assertFalse(result["zeroLeakClaim"])

    def test_missing_purgeable_fields_and_failed_calls_rejected(self):
        for field in ("purgeable_volatile_resident", "purgeable_volatile_virtual", "purgeable_volatile_pmap"):
            report = synthetic(); del report["cycles"][-1]["settledAfterCleanup"]["backingAccounting"]["purgeable"]["bytes"][field]
            with self.assertRaises(ValueError): self.check(report)
        report = synthetic(); report["baselineAfterWarmup"]["backingAccounting"]["purgeable"]["kernelReturn"] = 5
        with self.assertRaises(ValueError): self.check(report)

    def test_standard_flavor_unqueried_zero_rejected(self):
        report = synthetic(); report["baselineAfterWarmup"]["backingAccounting"]["standard"]["bytes"]["purgeable_volatile_resident"] = 0
        with self.assertRaises(ValueError): self.check(report)

    def test_sample_failures_gaps_and_watchdog_excess_rejected(self):
        for key, value in (("failedResidentSampleCount", 1), ("failedPhysicalFootprintSampleCount", 1),
                           ("residentSampleCount", 119), ("physicalFootprintSampleCount", 119),
                           ("peakResidentBytes", CHECK.RSS_CAP + 1), ("peakPhysicalFootprintBytes", CHECK.FOOTPRINT_CAP + 1)):
            report = synthetic(); report["sampledMemory"][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): self.check(report)

    def test_shrunken_workload_changed_profile_and_stage_omissions_rejected(self):
        report = synthetic(); report["cycles"].pop()
        with self.assertRaises(ValueError): self.check(report)
        report = synthetic(); report["cycles"][0]["width"] = 160
        with self.assertRaises(ValueError): self.check(report)
        report = synthetic(); report["cycles"][0]["phases"].pop()
        with self.assertRaises(ValueError): self.check(report)
        report = synthetic(); report["cycles"][0]["sourceCreates"] = 3
        with self.assertRaises(ValueError): self.check(report)

    def test_cleanup_lie_missing_phase_boundary_and_timeout_rejected(self):
        report = synthetic(); report["cycles"][0]["cleanup"]["controllers"] = 1
        with self.assertRaises(ValueError): self.check(report)
        report = synthetic(); del report["cycles"][0]["phases"][0]["afterSourceCreation"]
        with self.assertRaises(ValueError): self.check(report)
        report = synthetic(); report["elapsedSeconds"] = 240.01
        with self.assertRaises(ValueError): self.check(report)

    def test_identity_changes_are_rejected(self):
        for field in ("productionSourceCommit", "diagnosticOverlayCommit", "sourceCommit", "executableSHA256"):
            report = synthetic(); report[field] = "0" * len(report[field])
            with self.subTest(field=field), self.assertRaises(ValueError): self.check(report)

    def test_growth_is_computed_without_threshold_or_leak_verdict(self):
        report = synthetic(); report["cycles"][-1]["settledAfterCleanup"]["residentBytes"] += 714358784
        result = self.check(report)
        self.assertEqual(result["growthFromWarmup"]["residentBytes"], 714358784)
        self.assertEqual(result["growthFromWarmup"]["volatileResidentBytes"], 0)
        self.assertFalse(result["zeroLeakClaim"])

    def test_reader_hash_identity_mutation_rejected(self):
        report = synthetic("overview"); report["inputFileIdentities"][0]["name"] = "another.png"
        with self.assertRaises(ValueError): self.check(report)
        report = synthetic("overview"); report["inputFileIdentities"][0]["sha256"] = "missing"
        with self.assertRaises(ValueError): self.check(report)


if __name__ == "__main__":
    unittest.main()
