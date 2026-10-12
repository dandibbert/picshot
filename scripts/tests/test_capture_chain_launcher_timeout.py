"""Narrow chain deadline/source regressions; native launch is the CI gate."""
import hashlib
from pathlib import Path
import unittest
from product_launcher_source_contract import (CAPTURE_CHAIN_TIMEOUT_HOOKS,
    without_capture_chain_timeout_hooks)

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / 'scripts/launch-smoke-app.swift').read_text()

class CaptureChainDeadlineTests(unittest.TestCase):
    def test_exact_timeout_reversal_restores_candidate245_launcher(self):
        restored = without_capture_chain_timeout_hooks(self, SOURCE)
        self.assertEqual(hashlib.sha256(restored.encode()).hexdigest(), '9f4d041f5779e08dbef9761bbb5adb8e716e440ac648b3016e30b03c4b99d92d')

    def test_missing_changed_or_duplicate_deadline_hooks_are_rejected(self):
        for hook, _ in CAPTURE_CHAIN_TIMEOUT_HOOKS:
            for replacement in ('', hook + hook, hook.replace('effectiveTimeout', 'unboundedTimeout').replace('240', '301')):
                if replacement == hook:
                    continue
                with self.subTest(hook=hook[:60], replacement=replacement[:60]), self.assertRaises(AssertionError):
                    without_capture_chain_timeout_hooks(self, SOURCE.replace(hook, replacement, 1))

    def test_only_chain_selector_uses240_and_receipt_uses_effective_deadline(self):
        self.assertIn('let effectiveTimeout: TimeInterval = captureChainDiagnostic ? 240 : timeout', SOURCE)
        self.assertIn('let deadline = Date().addingTimeInterval(effectiveTimeout)', SOURCE)
        self.assertIn('"timeoutSeconds": effectiveTimeout', SOURCE)
        self.assertIn('"appTimeoutSeconds": captureChainDiagnostic ? 240 : 600', SOURCE)
        self.assertIn('within \\(Int(effectiveTimeout)) seconds', SOURCE)
        self.assertEqual(SOURCE.count('Date().addingTimeInterval(3)'), 2)
        self.assertIn('private let schedule: [TimeInterval] = [90, 360]', SOURCE)
        self.assertIn('configuration.arguments = []', SOURCE)
        self.assertNotIn('PICSHOT_CAPTURE_CHAIN_DIAGNOSIS_ONLY', SOURCE)

if __name__ == '__main__':
    unittest.main()
