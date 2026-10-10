"""Portable scope checks; macOS compilation and real sampling remain CI checks."""
import hashlib
import json
from pathlib import Path
import unittest

from product_launcher_source_contract import without_pin_ui_diagnostic_launcher_hooks

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / 'scripts/launch-smoke-app.swift').read_text()


class PinUIOwnedDiagnosticContract(unittest.TestCase):
    def test_exact_reversal_restores_frozen_launcher(self):
        restored = without_pin_ui_diagnostic_launcher_hooks(self, SOURCE)
        self.assertEqual(hashlib.sha256(restored.encode()).hexdigest(), '87af74858f438540411dab48194a084e5730418f2156265eb166e9ccbe144b50')

    def test_reverse_manifest_rejects_unreviewed_observer_change(self):
        changed = SOURCE.replace('"/usr/bin/sample"', '"/bin/sh"', 1)
        with self.assertRaises(AssertionError):
            without_pin_ui_diagnostic_launcher_hooks(self, changed)

    def test_only_bounded_numeric_owned_pid_sampling(self):
        self.assertIn('private let schedule: [TimeInterval] = [90, 360]', SOURCE)
        self.assertIn('process.arguments = [String(ownedPID), "1", "10", "-file", "/dev/stdout"]', SOURCE)
        self.assertIn('private let outputLimit = 2 * 1024 * 1024', SOURCE)
        self.assertIn('private let receiptLimit = 256 * 1024', SOURCE)
        self.assertIn('let allowed = min(count, outputLimit - outputBytes)', SOURCE)
        self.assertIn('for _ in 0..<16', SOURCE)
        self.assertIn('sampleStart >= 10', SOURCE)
        self.assertEqual(SOURCE.count('try process.run()'), 1)
        for forbidden in ['runningApplications', 'pgrep', 'sudo', '/bin/sh', 'waitUntilExit', 'readDataToEndOfFile']:
            self.assertNotIn(forbidden, SOURCE)

    def test_identity_rechecked_immediately_before_spawn(self):
        self.assertIn('let current = launched.flatMap { NSRunningApplication(processIdentifier: $0.processIdentifier) }', SOURCE)
        self.assertIn('ownedBundle == expectedBundle && currentBundle == expectedBundle', SOURCE)
        self.assertIn('ownedExecutable == expectedExecutablePath && currentExecutable == expectedExecutablePath', SOURCE)
        self.assertIn('launched?.launchDate == pinUILaunchedDate && current?.launchDate == pinUILaunchedDate', SOURCE)
        start = SOURCE.index('record("sample-starting"')
        guard = SOURCE.index('guard !receiptFailed, identity()["samplingFingerprintMatches"] as? Bool == true', start)
        self.assertLess(guard, SOURCE.index('try process.run()', start))
        self.assertIn('"identityBefore": before', SOURCE)
        self.assertIn('"identityAfter": identity', SOURCE)

    def test_missing_launch_date_blocks_sampling_but_not_owned_cleanup(self):
        self.assertIn('let samplingFingerprintMatches = matches && pinUILaunchedDate != nil && dateMatches', SOURCE)
        self.assertIn('let dateMatches = pinUILaunchedDate == nil ||', SOURCE)
        self.assertIn('guard before["samplingFingerprintMatches"] as? Bool == true', SOURCE)
        self.assertIn('"owned-launch-date-unavailable"', SOURCE)
        self.assertIn('pinUIDiagnostic == nil || pinUIOwnedIdentity()["ownedLiveIdentityMatches"] as? Bool == true', SOURCE)
        observer = SOURCE[SOURCE.index('final class PinUIOwnedDiagnostic'):SOURCE.index('// END opt-in pin UI owned-process diagnostics')]
        self.assertNotIn('["ownedLiveIdentityMatches"]', observer)

    def test_sample_completion_rejects_changed_after_identity_before_exit_success(self):
        completion = SOURCE[SOURCE.index('private func complete('):SOURCE.index('func stopSample(')]
        guard = completion.index('if identity["samplingFingerprintMatches"] as? Bool != true')
        self.assertLess(guard, completion.index('let exited = !child.isRunning'))
        self.assertIn('sampleFailure = sampleFailure ?? "owned-sampling-identity-changed-or-not-live-after-sample"', completion)
        self.assertIn('if let sampleFailure { failed = true; row["failure"] = sampleFailure }', completion)

    def test_child_failure_and_unconfirmed_cleanup_are_not_success(self):
        self.assertIn('child.terminationReason != .exit || child.terminationStatus != 0', SOURCE)
        self.assertIn('"outcome": sampleFailure == nil ? "sample-command-completed" : "sample-failed"', SOURCE)
        self.assertIn('failed = true; cleanupUnconfirmed = true', SOURCE)
        self.assertIn('guard child == nil, !receiptFailed, !cleanupUnconfirmed, nextSample < schedule.count', SOURCE)
        self.assertIn('"sampleChildExitConfirmed": child == nil', SOURCE)
        self.assertIn('requestedCode == 0 && pinUIDiagnostic?.failed == true ? 1 : requestedCode', SOURCE)
        self.assertIn('stopSample("launcher-finishing", identity: identity)', SOURCE)

    def test_opt_in_preserves_app_input_and_bound(self):
        self.assertIn('if let directory = pinUIDiagnosticDirectory {', SOURCE)
        self.assertIn('configuration.environment["PICSHOT_PIN_UI_DIAGNOSTIC_DIRECTORY"] = directory', SOURCE)
        self.assertIn('configuration.arguments = []', SOURCE)
        self.assertNotIn('configuration.standardInput', SOURCE)
        self.assertIn('let diagnosticMode = pinUIDiagnostic != nil ? "" :', SOURCE)
        self.assertIn('let timeout: TimeInterval = ["export-only", "decode-only"].contains(diagnosticMode) ? 900 : 600', SOURCE)
        self.assertEqual(SOURCE.count('Date().addingTimeInterval(3)'), 2)
        self.assertEqual(SOURCE.count('O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC'), 2)
        self.assertIn('try receipts.synchronize()', SOURCE)
        self.assertIn('try output.synchronize()', SOURCE)


if __name__ == '__main__':
    unittest.main()
