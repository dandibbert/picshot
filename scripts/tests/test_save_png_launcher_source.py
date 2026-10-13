"""Bounded Save launcher ownership and historical-mode preservation."""
import hashlib
from pathlib import Path
import unittest

from save_png_launcher_source_contract import (SAVE_PNG_LAUNCHER_HOOKS,
    without_save_png_launcher_hooks)

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / 'scripts/launch-smoke-app.swift').read_text()


class SavePNGLauncherTests(unittest.TestCase):
    def test_save_only_delta_restores_exact265_launcher(self):
        historical = without_save_png_launcher_hooks(self, SOURCE)
        self.assertEqual(hashlib.sha256(historical.encode()).hexdigest(),
                         '6ec209939dc935a679a453ec3b3d43b0cf7c8d5c556112739b4f5f2d33db5b90')

    def test_missing_changed_duplicate_or_extra_save_hooks_fail_closed(self):
        for hook, _ in SAVE_PNG_LAUNCHER_HOOKS:
            changed = hook.replace('savePNGComparison', 'otherComparison').replace('PICSHOT_SAVE_PNG_', 'PICSHOT_OTHER_')
            self.assertNotEqual(changed, hook)
            for replacement in ('', changed, hook + hook):
                with self.subTest(hook=hook[:60], replacement=replacement[:60]), self.assertRaises(AssertionError):
                    without_save_png_launcher_hooks(self, SOURCE.replace(hook, replacement, 1))
        with self.assertRaises(AssertionError):
            without_save_png_launcher_hooks(self, SOURCE + '\nlet extra = savePNGComparisonDiagnostic\n')

    def test_measurement_validation_cleanup_and_owned_identity_remain_bounded(self):
        self.assertIn('? (savePNGComparisonMode == "validate" ? 240 : 360)', SOURCE)
        self.assertIn('report["launchBeganUptimeSeconds"] = launchBeganUptime', SOURCE)
        self.assertIn('report["finishUptimeSeconds"] = ProcessInfo.processInfo.systemUptime', SOURCE)
        self.assertIn('report["arguments"] = configuration.arguments', SOURCE)
        self.assertEqual(SOURCE.count('Date().addingTimeInterval(3)'), 2)
        self.assertIn('savePNGComparisonDiagnostic || liveScrollDiagnostic', SOURCE)
        self.assertIn('if launched.isTerminated { finish(0, "exited") }', SOURCE)
        shell = (ROOT / 'scripts/save-png-comparison.sh').read_text()
        self.assertIn('run_cell control measure 420\nrun_cell candidate measure 420\nrun_cell validation validate 300', shell)
        self.assertIn("r.get('ownedExitConfirmed') is not True or r.get('launchedIdentityMatches') is not True", shell)
        self.assertIn('trap finish EXIT', shell)
        self.assertIn('identity after || identity_status=$?', shell)
        self.assertIn('check-save-png-comparison.py', shell)
        self.assertLess(360 + 6, 420)
        self.assertLess(240 + 6, 300)
        for forbidden in ('killall', 'pkill', 'runningApplications', 'waitUntilExit'):
            self.assertNotIn(forbidden, SOURCE)


if __name__ == '__main__':
    unittest.main()
