"""Narrow chain deadline/source regressions; native launch is the CI gate."""
import hashlib
from pathlib import Path
import unittest
from save_png_launcher_source_contract import current_save_png_fragment
from product_launcher_source_contract import (CAPTURE_CHAIN_TIMEOUT_HOOKS, TEXT_SCRIPT_LAUNCHER_HOOKS,
    without_capture_chain_timeout_hooks, without_text_script_launcher_hooks)

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / 'scripts/launch-smoke-app.swift').read_text()

class CaptureChainDeadlineTests(unittest.TestCase):
    def test_exact_timeout_reversal_restores_candidate245_launcher(self):
        restored = without_capture_chain_timeout_hooks(self, SOURCE)
        self.assertEqual(hashlib.sha256(restored.encode()).hexdigest(), '9f4d041f5779e08dbef9761bbb5adb8e716e440ac648b3016e30b03c4b99d92d')

    def test_missing_changed_or_duplicate_deadline_hooks_are_rejected(self):
        for hook, _ in CAPTURE_CHAIN_TIMEOUT_HOOKS:
            # Mutate the actual current hook, not a previous literal that no
            # longer occurs after the reviewed additive text-script hook.
            for current, previous in TEXT_SCRIPT_LAUNCHER_HOOKS:
                if previous and previous in hook: hook = hook.replace(previous, current)
            hook = current_save_png_fragment(hook)
            self.assertEqual(SOURCE.count(hook), 1)
            for replacement in ('', hook + hook, hook.replace('effectiveTimeout', 'unboundedTimeout').replace('240', '301')):
                if replacement == hook:
                    continue
                with self.subTest(hook=hook[:60], replacement=replacement[:60]), self.assertRaises(AssertionError):
                    without_capture_chain_timeout_hooks(self, SOURCE.replace(hook, replacement, 1))

    def test_only_chain_selector_uses240_and_receipt_uses_effective_deadline(self):
        source = without_text_script_launcher_hooks(self, SOURCE)
        self.assertIn('let effectiveTimeout: TimeInterval = captureChainDiagnostic ? 240 : timeout', source)
        self.assertIn('let deadline = Date().addingTimeInterval(effectiveTimeout)', source)
        self.assertIn('"timeoutSeconds": effectiveTimeout', source)
        self.assertIn('"appTimeoutSeconds": captureChainDiagnostic ? 240 : 600', source)
        self.assertIn('within \\(Int(effectiveTimeout)) seconds', source)
        self.assertEqual(source.count('Date().addingTimeInterval(3)'), 2)
        self.assertIn('private let schedule: [TimeInterval] = [90, 360]', source)
        self.assertIn('configuration.arguments = []', source)
        self.assertNotIn('PICSHOT_CAPTURE_CHAIN_DIAGNOSIS_ONLY', source)

if __name__ == '__main__':
    unittest.main()
