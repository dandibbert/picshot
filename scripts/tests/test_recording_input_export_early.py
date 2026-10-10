"""Portable early-gate failure contracts. Stubs are not native/media evidence."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("early_exports", ROOT / "scripts/recording-input-export-early.py")
EARLY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EARLY)
COMMIT = "a" * 40


class EarlyRecordingExportContracts(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.workspace = Path(self.temporary.name).resolve()
        self.dist = self.workspace / "dist"
        self.dist.mkdir()
        self.packaged = self.dist / "PicShot.app"
        self.archive = self.dist / "PicShot-0.19.0-macos-arm64.zip"
        self.archive.write_bytes(b"portable package identity stub")
        info = dict(PicShotSourceCommit=COMMIT, CFBundleExecutable="PicShot", CFBundleShortVersionString="0.19.0", CFBundleVersion="1")
        build = dict(sourceCommit=COMMIT, version="0.19.0", architecture="arm64")
        for name, data in zip(EARLY.IDENTITY_FILES, (b"portable executable stub", plistlib.dumps(info), json.dumps(build).encode())):
            path = self.packaged / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.evidence = self.dist / "evidence/recording-input-export-early"

    def write_launch(self, root, app, mutate=None):
        executable = str(app / EARLY.IDENTITY_FILES[0])
        receipt = dict(selectedAppPath=str(app), launchedAppPath=str(app), expectedExecutablePath=executable,
            launchedExecutablePath=executable, earlyWitnessOnly=True, launchedIdentityMatches=True,
            callbackReceived=True, createsNewApplicationInstance=True, processIdentifier=123,
            ownedExitConfirmed=True, status="exited", launcherExitCode=0, timeoutSeconds=600)
        report = dict(status="exported-awaiting-independent-validation", sourceCommit=COMMIT,
            bundlePath=str(app), executablePath=executable, arguments=[executable], earlyWitnessOnly=True,
            installerAcceptance=False, independentValidationRequired=True,
            historyDirectoryPath=str(self.workspace / "PicShot-Smoke-removed"), historyDirectoryRemoved=True)
        if mutate:
            mutate(receipt, report)
        for name, data in (("launch.json.launcher.json", receipt), ("launch.json", report)):
            (root / name).write_text(json.dumps(data))
        for name, status, seconds in (("recording-input.json", "passed", 60),
                                      ("recording-input-export.json", "exported-awaiting-independent-validation", 120)):
            (root / name).write_text(json.dumps(dict(status=status, sourceCommit=COMMIT,
                temporaryDirectoryRemoved=True, cooperativeDeadlineSeconds=seconds, elapsedSeconds=1,
                captureStarted=False, permissionRequested=False, globalInputPosted=False)))

    def drive(self, mutate=None, reader_failure=False):
        calls = []

        def command(argv, **kwargs):
            if argv[0] == "ditto":
                shutil.copytree(self.packaged, Path(argv[-1]) / "PicShot.app")
            elif argv[0] != "codesign":
                self.fail(f"Unexpected subprocess: {argv}")

        def bounded(argv, seconds, name, root, environment):
            calls.append(name)
            self.assertEqual(environment["PICSHOT_RECORDING_INPUT_EXPORT_ONLY"], "1")
            self.assertNotIn("PICSHOT_UI_PREVIEW_ONLY", environment)
            if name == "launcher":
                self.assertEqual(seconds, 660)
                self.write_launch(root, Path(argv[2]), mutate)
            else:
                self.assertEqual(seconds, 330)
                self.assertIn("scripts/verify-recording-input-exports.py", argv)
                if reader_failure:
                    (root / "recording-input-export-independent.json").write_text(json.dumps(
                        dict(status="failed", error="Lossy WebP frame 10/11 pixel witness failed")))
                    (root / "recording-input-lossy.webp").write_bytes(b"retained failed media stub")
                    raise ValueError("Lossy WebP frame 10/11 pixel witness failed")

        with patch.object(EARLY, "ROOT", self.workspace), patch.object(EARLY.platform, "system", return_value="Darwin"), \
             patch.object(EARLY.platform, "machine", return_value="arm64"), patch.object(EARLY, "source_identity"), \
             patch.object(EARLY.subprocess, "run", side_effect=command), \
             patch.object(EARLY.subprocess, "check_output", return_value="arm64\n"), \
             patch.object(EARLY, "bounded", side_effect=bounded), \
             patch.object(EARLY.GATE, "validate", return_value={"status": "passed", "testStub": True}) as join, \
             patch.dict(os.environ, {"GITHUB_RUN_NUMBER": "1", "PICSHOT_UI_PREVIEW_ONLY": "1"}), \
             contextlib.redirect_stdout(io.StringIO()):
            status = EARLY.run(COMMIT)
        return status, json.loads((self.evidence / "checked.json").read_text()), calls, join.call_count

    def test_app_pass_cannot_hide_native_reader_failure(self):
        status, report, calls, joins = self.drive(reader_failure=True)
        self.assertEqual(status, 1)
        self.assertEqual(calls, ["launcher", "reader"])
        self.assertEqual(joins, 0)
        self.assertEqual(report["phase"], "independent-native-reader")
        self.assertIn("Lossy WebP frame 10/11", report["error"])
        self.assertTrue(report["ownedAppExitConfirmed"])
        self.assertTrue(report["installedDirectoryRemoved"])
        self.assertFalse(report["installerAcceptance"])
        self.assertTrue((self.evidence / "recording-input-export.json").is_file())
        self.assertEqual(json.loads((self.evidence / "recording-input-export-independent.json").read_text())["status"], "failed")
        self.assertEqual((self.evidence / "recording-input-lossy.webp").read_bytes(), b"retained failed media stub")
        self.assertEqual((self.evidence / "artifact/recording-input-lossy.webp").read_bytes(), b"retained failed media stub")
        self.assertEqual(json.loads((self.evidence / "artifact/checked.json").read_text())["status"], "failed")

    def test_wrong_executable_blocks_reader_and_preserves_unconfirmed_bundle(self):
        status, report, calls, joins = self.drive(lambda receipt, _: receipt.update(launchedExecutablePath="/other/PicShot"))
        self.assertEqual(status, 1)
        self.assertEqual(calls, ["launcher"])
        self.assertEqual(joins, 0)
        self.assertFalse(report["ownedAppExitConfirmed"])
        self.assertFalse(report["installedDirectoryRemoved"])
        self.assertTrue(Path(report["retainedInstalledDirectory"]).is_dir())

    def test_recorded_history_cleanup_must_match_filesystem(self):
        (self.workspace / "PicShot-Smoke-removed").mkdir()
        status, report, calls, _ = self.drive()
        self.assertEqual(status, 1)
        self.assertEqual(calls, ["launcher"])
        self.assertIn("history cleanup", report["error"])
        self.assertTrue(report["installedDirectoryRemoved"])

    def test_success_is_only_early_witness_and_preserves_reports(self):
        status, report, calls, joins = self.drive()
        self.assertEqual((status, calls, joins), (0, ["launcher", "reader"], 1))
        self.assertEqual(report["status"], "passed")
        self.assertFalse(report["installerAcceptance"])
        self.assertTrue(report["fullZIPAndDMGSmokeRequired"])
        self.assertTrue(report["installedDirectoryRemoved"])
        self.assertTrue((self.evidence / "launch.json").is_file())
        with self.assertRaises(FileExistsError):
            self.drive()

    def test_source_or_executable_mismatch_cannot_share_package_identity(self):
        app = self.workspace / "Installed.app"
        shutil.copytree(self.packaged, app)
        with patch.dict(os.environ, {"GITHUB_RUN_NUMBER": "1"}):
            identity = EARLY.package_identity(app, self.packaged, self.archive, COMMIT, "arm64")
            self.assertEqual(identity["sourceCommit"], COMMIT)
            with self.assertRaisesRegex(ValueError, "source, architecture"):
                EARLY.package_identity(app, self.packaged, self.archive, "b" * 40, "arm64")
            (app / EARLY.IDENTITY_FILES[0]).write_bytes(b"different executable")
            with self.assertRaisesRegex(ValueError, "differs from packaged"):
                EARLY.package_identity(app, self.packaged, self.archive, COMMIT, "arm64")

    def test_cancel_timeout_and_missing_identity_are_never_success(self):
        root = self.workspace / "reports"
        root.mkdir()
        mutations = [lambda r, _: r.update(status="timed-out"), lambda r, _: r.update(interruptedSignal=15),
            lambda r, _: r.update(ownedExitConfirmed=False), lambda r, _: r.update(timeoutSeconds=900),
            lambda r, _: r.pop("launchedIdentityMatches"), lambda _, r: r.update(installerAcceptance=True),
            lambda _, r: r.update(arguments=["PicShot", "unexpected"]),
            lambda _, r: r.update(sourceCommit="b" * 40)]
        for index, mutation in enumerate(mutations):
            with self.subTest(index=index):
                self.write_launch(root, self.packaged, mutation)
                with self.assertRaises(ValueError):
                    EARLY.validate_launch(root, self.packaged, COMMIT)

    def test_artifact_stays_below_transfer_limit_without_bundle_or_oversized_media(self):
        root = self.workspace / "artifact-test"
        root.mkdir()
        (root / "launcher.log").write_bytes(b"")
        (root / "recording-input.png").write_bytes(b"extra PNG is deliberately not uploaded")
        (root / "PicShot.app").mkdir()
        oversized = root / "recording-input-lossy.webp"
        with oversized.open("wb") as stream:
            stream.truncate(EARLY.GATE.MEDIA_CAP + 1)
        record = dict(status="passed")
        EARLY.prepare_artifact(root, record)
        self.assertEqual(record["status"], "failed")
        self.assertEqual(record["artifactMaximumPayloadBytes"], 25 * 1024 * 1024)
        self.assertLess(record["artifactMaximumPayloadBytes"], 32 * 1024 * 1024)
        self.assertEqual(set(record["artifactOmissions"]), {"recording-input-lossy.webp"})
        self.assertEqual({x.name for x in (root / "artifact").iterdir()}, {"checked.json", "launcher.log"})
        self.assertEqual(oversized.stat().st_size, EARLY.GATE.MEDIA_CAP + 1)

    def test_existing_bounded_runner_preserves_failure_without_retry(self):
        root = self.workspace / "bounded"
        root.mkdir()
        with self.assertRaisesRegex(ValueError, "failed reader process"):
            EARLY.bounded([sys.executable, "-c", "raise SystemExit(7)"], 5, "reader", root, os.environ.copy())
        report = json.loads((root / "reader-report.json").read_text())
        self.assertEqual(report["child_returncode"], 7)
        self.assertEqual(report["max_log_bytes"], 2 * 1024 * 1024)
        self.assertEqual(report["timeout_seconds"], 5)

    def test_gate_is_additive_and_before_slow_native_execution(self):
        workflow = (ROOT / ".github/workflows/macos.yml").read_text().split("  build:\n", 1)[1].split("  codec-dependencies:\n", 1)[0]
        early = workflow.index("run: python3 scripts/recording-input-export-early.py")
        gate = workflow.split("- name: Check installed recording exports before slow native gates", 1)[1].split("- name:", 1)[0]
        upload = workflow.split("- name: Upload early installed recording export witness", 1)[1].split("- name:", 1)[0]
        self.assertIn("timeout-minutes: 20", gate)
        self.assertIn("timeout-minutes: 2", upload)
        self.assertIn("if: always()", upload)
        self.assertIn("path: dist/evidence/recording-input-export-early/artifact/", upload)
        self.assertLess(workflow.index("bash scripts/ui-preview.sh"), early)
        for later in ("-- swift build --product PicShot", "-- swift build --build-tests", "--directory dist/focused-test-shards", "--directory dist/native-test-shards", "bash scripts/smoke.sh"):
            self.assertLess(early, workflow.index(later))
        smoke = (ROOT / "Sources/PicShot/SmokeVerification.swift").read_text()
        self.assertEqual(smoke.count("RecordingInputSmokeFixture.verify(evidenceDirectory:"), 2)
        self.assertEqual(smoke.count("RecordingInputExportSmokeFixture.verify(evidenceDirectory:"), 2)
        self.assertIn("guard RecordingInputExportSmokeSelection.isExclusive(ProcessInfo.processInfo.environment)", smoke)
        self.assertLess(smoke.index("guard RecordingInputExportSmokeSelection.isExclusive"), smoke.index("_ = try await RecordingInputSmokeFixture.verify"))
        self.assertIn("verify-recording-input-exports.py", (ROOT / "scripts/smoke.sh").read_text())


if __name__ == "__main__":
    unittest.main()
