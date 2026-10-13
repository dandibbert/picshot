"""Bounded Save launchers, historical protocol refusal and default-route receipts.

Source/synthetic reader checks only; actual Save pixels and native ownership are
established by the existing native and installed qualification gates.
"""
import copy
import hashlib
from pathlib import Path
import unittest

from save_png_launcher_source_contract import (SAVE_PNG_LAUNCHER_HOOKS,
    without_save_png_launcher_hooks)

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / 'scripts/launch-smoke-app.swift').read_text()
V1_DEFAULT_GUARD = ('        guard SavePNGPreparationMode.productionDefault == .legacyPreview else {\n'
    '            throw failure("Historical save-png-comparison-v1 requires the legacyPreview production default")\n'
    '        }\n')


def historical_v1_refusal(test, source):
    entry = source.split('    static func runIfRequested(', 1)[1].split('    private static var options:', 1)[0]
    test.assertEqual(source.count(V1_DEFAULT_GUARD), 1)
    test.assertIn(V1_DEFAULT_GUARD, entry)
    position = entry.index(V1_DEFAULT_GUARD)
    test.assertLess(entry.index('mode == "measure" || mode == "validate", evidenceDirectory.isFileURL else {'), position)
    for operation in ('claimed = true', 'try FileManager.default.createDirectory(',
                      'if mode == "validate" {', 'return try validate(', 'return try await measure('):
        test.assertLess(position, entry.index(operation))
    test.assertNotIn('identity()', entry[:position])
    test.assertIn('private static func identity()', source)
    test.assertIn('private static func measure(', source)
    test.assertIn('private static func validate(', source)


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


class SavePNGDefaultSourceTests(unittest.TestCase):
    def test_shared_payload_default_and_historical_v1_refusal_before_either_mode(self):
        controller = (ROOT / 'Sources/PicShot/SaveWorkflowController.swift').read_text()
        self.assertEqual(controller.count('static let productionDefault: Self = .encodedPayload'), 1)
        self.assertEqual(controller.count('pngPreparationMode: SavePNGPreparationMode = .productionDefault'), 2)
        fixture = (ROOT / 'Sources/PicShot/SavePNGComparisonFixture.swift').read_text()
        historical_v1_refusal(self, fixture)
        for changed in ('', V1_DEFAULT_GUARD + V1_DEFAULT_GUARD,
                        V1_DEFAULT_GUARD.replace('== .legacyPreview', '== .encodedPayload')):
            with self.subTest(guard=changed), self.assertRaises(AssertionError):
                historical_v1_refusal(self, fixture.replace(V1_DEFAULT_GUARD, changed))
        late = fixture.replace(V1_DEFAULT_GUARD, '').replace('        claimed = true\n',
                                                           '        claimed = true\n' + V1_DEFAULT_GUARD, 1)
        with self.assertRaises(AssertionError):
            historical_v1_refusal(self, late)
        # The producer is refused after promotion, while archived v1 evidence
        # remains readable with its original legacy-default identity/schema.
        self.assertIn('static let protocolName = "save-png-comparison-v1"', fixture)
        self.assertIn('"productionDefaultPNGPreparationMode": "legacyPreview", "productDefaultsChanged": false', fixture)

    def test_installed_fixture_observes_uninjected_presenter_and_controller_default(self):
        fixture = (ROOT / 'Sources/PicShot/SaveWorkflowUIPreviewFixture.swift').read_text()
        self.assertEqual(fixture.count('let presenter = SaveWorkflowPresenter(defaults: defaults)'), 1)
        self.assertNotIn('pngPreparationMode:', fixture)
        observed = ('            switch presenter.pngPreparationMode {\n'
            '            case .legacyPreview: report["defaultPNGPreparationMode"] = "legacyPreview"\n'
            '            case .encodedPayload: report["defaultPNGPreparationMode"] = "encodedPayload"\n'
            '            }\n'
            '            report["defaultPNGPreparationModeObserved"] = true\n')
        self.assertEqual(fixture.count(observed), 1)
        self.assertLess(fixture.index('try require(presenter.pngPreparationMode == .encodedPayload,'),
                        fixture.index(observed))
        self.assertLess(fixture.index('try require(quick.pngPreparationMode == presenter.pngPreparationMode,'),
                        fixture.index('let quickResult = try unwrap(quick.result,'))
        self.assertIn('try require(try pixels(decode(quickResult.savedURL)) == expected,', fixture)

    @staticmethod
    def installed_checks():
        for name, start, end in (
                ('scripts/ui-preview.sh', "save=r['saveWorkflowUI']\n", "ocr=r['pinOCRWorkflow']"),
                ('scripts/smoke.sh', "save=r['saveWorkflowEvidence']\n", 'print(json.dumps(r,indent=2))')):
            source = (ROOT / name).read_text()
            yield name, source.split(start, 1)[1].split(end, 1)[0]

    def test_installed_save_receipts_require_actual_payload_default_observation(self):
        # Explicitly synthetic values exercise only the unchanged reader block.
        valid = dict(status='passed', quietAutomaticFinalizedAction=True,
            defaultPNGPreparationMode='encodedPayload', defaultPNGPreparationModeObserved=True,
            userPreferencesRead=False, generalPasteboardReadOrWritten=False,
            liveScreenCaptured=False, networkAttempted=False, maximumSaveJobs=2,
            estimatedRetainedInputBudgetBytes=256*1024*1024,
            resourceCycles=[dict(warmup=i < 2, activeJobs=0, retainedInputBytes=0,
                                 controllerReleased=True, temporaryJobRemoved=True) for i in range(10)])
        for name, source in self.installed_checks():
            for optimization in (0, 2):
                code = compile(source, name + ':save-default-contract', 'exec', optimize=optimization)
                exec(code, {'save': copy.deepcopy(valid)})
                for field, bad_values in (
                        ('defaultPNGPreparationMode', (None, '', 'legacyPreview', True, ['encodedPayload'])),
                        ('defaultPNGPreparationModeObserved', (None, False, 0, 1, 'true', []))):
                    for value in bad_values:
                        changed = copy.deepcopy(valid); changed[field] = value
                        with self.subTest(script=name, optimize=optimization, field=field, value=value), self.assertRaises(SystemExit):
                            exec(code, {'save': changed})
                    changed = copy.deepcopy(valid); del changed[field]
                    with self.subTest(script=name, optimize=optimization, missing=field), self.assertRaises(SystemExit):
                        exec(code, {'save': changed})
            # Previous job/input limits and ten-cycle ownership gates remain
            # enforced by the ordinary Python command used by both scripts.
            code = compile(source, name + ':save-existing-contract', 'exec', optimize=0)
            for field, value in (('status', 'failed'), ('quietAutomaticFinalizedAction', False),
                                 ('maximumSaveJobs', 3), ('estimatedRetainedInputBudgetBytes', 512*1024*1024),
                                 ('resourceCycles', valid['resourceCycles'][:-1])):
                changed = copy.deepcopy(valid); changed[field] = value
                with self.subTest(script=name, field=field), self.assertRaises(AssertionError):
                    exec(code, {'save': changed})

    def test_full_experimental_gate_runs_existing_save_contracts_in_both_python_modes(self):
        workflow = (ROOT / '.github/workflows/macos.yml').read_text()
        full = workflow.split('  build:\n', 1)[1].split('\n  codec-dependencies:', 1)[0]
        step = full.split('        id: experimental_scroll_contract\n', 1)[1].split('      - name:', 1)[0]
        self.assertIn('for pattern in test_save_png_comparison.py test_save_png_launcher_source.py; do', step)
        for option in ('', '-O '):
            self.assertIn('python3 ' + option + '-m unittest discover -s scripts/tests -p "$pattern" -v', step)
        self.assertNotIn('save-png-comparison.sh', full)


if __name__ == '__main__':
    unittest.main()
