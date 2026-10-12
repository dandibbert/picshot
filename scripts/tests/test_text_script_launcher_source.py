"""Candidate255 additive launcher contracts; portable source checks only."""
import hashlib
from pathlib import Path
import unittest

from product_launcher_source_contract import (TEXT_SCRIPT_LAUNCHER_HOOKS,
    without_text_script_launcher_hooks, without_capture_chain_timeout_hooks,
    without_capture_chain_launcher_hooks, without_live_scroll_launcher_hooks,
    without_pin_ui_diagnostic_launcher_hooks, without_product_launcher_hooks)

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT/'scripts/launch-smoke-app.swift').read_text()
PRE_TEXT_SHA256 = '3f30ec9e5816d72f4174a1df4204ae5151b13fa3970e6ec5a2e33cb55ae7b4e2'


class TextScriptLauncherSourceTests(unittest.TestCase):
    def test_exact_nine_reversals_restore_previous_launcher_bytes(self):
        self.assertEqual(len(TEXT_SCRIPT_LAUNCHER_HOOKS), 9)
        restored = without_text_script_launcher_hooks(self, SOURCE)
        self.assertEqual(hashlib.sha256(restored.encode()).hexdigest(), PRE_TEXT_SHA256)
        self.assertNotIn('PICSHOT_TEXT_SCRIPT_', restored)
        self.assertNotIn('textScriptDiagnostic', restored)

    def test_missing_changed_duplicate_text_hooks_fail_every_shared_entry(self):
        entries = (without_text_script_launcher_hooks, without_capture_chain_timeout_hooks,
            without_capture_chain_launcher_hooks, without_live_scroll_launcher_hooks,
            without_pin_ui_diagnostic_launcher_hooks, without_product_launcher_hooks)
        for index, (hook, _) in enumerate(TEXT_SCRIPT_LAUNCHER_HOOKS):
            self.assertEqual(SOURCE.count(hook), 1)
            changed = hook.replace('textScriptDiagnostic', 'unreviewedDiagnostic').replace('PICSHOT_TEXT_SCRIPT_', 'PICSHOT_OTHER_SCRIPT_')
            self.assertNotEqual(changed, hook)
            for disposition, replacement in (('missing', ''), ('changed', changed), ('duplicated', hook+hook)):
                mutated = SOURCE.replace(hook, replacement, 1)
                self.assertNotEqual(mutated, SOURCE)
                for entry in entries:
                    with self.subTest(index=index, disposition=disposition, entry=entry.__name__), self.assertRaises(AssertionError):
                        entry(self, mutated)

    def test_missing_all_or_extra_text_selectors_are_not_accepted_as_legacy_input(self):
        previous = without_text_script_launcher_hooks(self, SOURCE)
        for changed in (previous, SOURCE+'\nlet unexpected = textScriptDiagnostic\n',
                        SOURCE+'\nlet unexpected = "PICSHOT_TEXT_SCRIPT_OTHER"\n'):
            with self.subTest(changed=changed[-80:]), self.assertRaises(AssertionError):
                without_text_script_launcher_hooks(self, changed)

    def test_current_selector_forwarding_and_owned_receipt_are_exact(self):
        self.assertEqual(SOURCE.count('let textScriptDiagnostic = ProcessInfo.processInfo.environment["PICSHOT_TEXT_SCRIPT_DEMO_ONLY"] == "1"'), 1)
        whitelist = SOURCE.split('for key in [', 1)[1].split('] {', 1)[0]
        self.assertEqual(whitelist.count('"PICSHOT_TEXT_SCRIPT_DEMO_ONLY"'), 1)
        self.assertEqual(SOURCE.count('if let value = ProcessInfo.processInfo.environment[key] { configuration.environment[key] = value }'), 1)
        for fragment in ('configuration.createsNewApplicationInstance = true', 'configuration.arguments = []',
            '"selectedAppPath": appURL.resolvingSymlinksInPath().path',
            '"ownedExitConfirmed": launched?.isTerminated == true', '"processStartMemoryCaptured": false',
            'report["textScriptDiagnosticOnly"] = textScriptDiagnostic',
            'report["expectedExecutablePath"] = expectedExecutablePath',
            'report["launchedAppPath"] = launchedBundlePath', 'report["launchedExecutablePath"] = launchedExecutablePath',
            'launchedBundlePath == appURL.resolvingSymlinksInPath().path && launchedExecutablePath == expectedExecutablePath'):
            self.assertIn(fragment, SOURCE)
        identity = 'if (liveScrollDiagnostic || captureChainDiagnostic || textScriptDiagnostic || recordingInputExportOnly || ProcessInfo.processInfo.environment["PICSHOT_CODEC_STAGING_MODE"] != nil) && !launchedIdentityMatches() {'
        self.assertEqual(SOURCE.count(identity), 1)
        self.assertLess(SOURCE.index(identity), SOURCE.index('if launched.isTerminated { finish(0, "exited") }'))

    def test_current240_deadline_preserves_original_modes_and3_plus3_owned_cleanup(self):
        for fragment in ('let effectiveTimeout: TimeInterval = (captureChainDiagnostic || textScriptDiagnostic) ? 240 : timeout',
            'let deadline = Date().addingTimeInterval(effectiveTimeout)', '"timeoutSeconds": effectiveTimeout',
            '"appTimeoutSeconds": (captureChainDiagnostic || textScriptDiagnostic) ? 240 : 600, "appCleanupSeconds": [3, 3]',
            'within \\(Int(effectiveTimeout)) seconds',
            'let timeout: TimeInterval = ["export-only", "decode-only"].contains(diagnosticMode) ? 900 : 600',
            'private let schedule: [TimeInterval] = [90, 360]',
            'if liveScrollDiagnostic || captureChainDiagnostic || textScriptDiagnostic || recordingInputExportOnly || pinUIDiagnostic != nil {',
            'while Date() < deadline && interruptedSignal == nil {'):
            self.assertIn(fragment, SOURCE)
        cleanup = ('if let launched, !launched.isTerminated, !(recordingInputExportOnly || liveScrollDiagnostic || captureChainDiagnostic || textScriptDiagnostic) || launchedIdentityMatches(),\n'
                   '   pinUIDiagnostic == nil || pinUIOwnedIdentity()["ownedLiveIdentityMatches"] as? Bool == true {\n'
                   '    _ = launched.terminate()\n'
                   '    let grace = Date().addingTimeInterval(3)\n'
                   '    while !launched.isTerminated && Date() < grace {\n'
                   '        RunLoop.current.run(until: Date().addingTimeInterval(0.1))\n'
                   '    }\n'
                   '    if !launched.isTerminated { _ = launched.forceTerminate() }\n'
                   '    let forced = Date().addingTimeInterval(3)\n'
                   '    while !launched.isTerminated && Date() < forced {\n'
                   '        RunLoop.current.run(until: Date().addingTimeInterval(0.1))\n'
                   '    }\n')
        self.assertEqual(SOURCE.count(cleanup), 1)
        self.assertEqual(SOURCE.count('Date().addingTimeInterval(3)'), 2)
        self.assertIn('finish(1, interruptedSignal == nil ? "timed-out" : "cancelled")', SOURCE)
        for forbidden in ('killall', 'pkill', 'runningApplications', 'waitUntilExit'):
            self.assertNotIn(forbidden, SOURCE)


if __name__ == '__main__': unittest.main()
