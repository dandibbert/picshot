"""Portable adversarial fixtures only; these are not native lifetime evidence."""
import ast
import copy
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parent
SPEC = importlib.util.spec_from_file_location('callout_diagnostic_check', SCRIPTS / 'check-callout-retirement-diagnostic.py')
CHECK = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(CHECK)
FIXTURE_SPEC = importlib.util.spec_from_file_location('synthetic_annotation_fixture', SCRIPTS / 'tests/test_check_annotation_details_report.py')
FIXTURE = importlib.util.module_from_spec(FIXTURE_SPEC); FIXTURE_SPEC.loader.exec_module(FIXTURE)
SOURCE = '1' * 40


class CalloutDiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='explicitly-synthetic-callout-')
        self.addCleanup(self.temporary.cleanup)
        self.prepare_fixture(self.temporary.name)

    def prepare_fixture(self, directory):
        # Match the production runner's canonical paths, including macOS temp
        # aliases and explicit symlink roots used by the portable regression.
        self.root = Path(directory).resolve()
        self.output = self.root / 'capture'
        self.output.mkdir()
        callout = FIXTURE.modules()[2]
        life = callout['commentLifecycle']
        begin = 100.0
        cycles = []
        for row in life['cycles']:
            close = begin + row['closedAtMilliseconds'] / 1000
            event = dict(tokenDeinitUptime=close + .005, weakCheckFinishedUptime=close + .006,
                         sourceWasWeakNil=True, callbackWasOnMainThread=True)
            cycle = dict(cycle=row['cycle'], closedAtUptime=close, contextWasTracked=row['contextWasTracked'], input=event)
            if row['contextWasTracked']:
                cycle['context'] = copy.deepcopy(event)
            cycles.append(cycle)
        self.data = {
            'identity.json': dict(sourceCommit=SOURCE, architecture='x86_64', executableSHA256='a' * 64,
                appPath='/explicitly-synthetic/PicShot.app', expectedCycles=6, nativeDeadlineMilliseconds=2000,
                maximumSamples=256, launcherDeadlineSeconds=600, executionsRequested=1,
                fixtureEnvironment={'PICSHOT_UI_PREVIEW_ONLY': '1', 'PICSHOT_CALLOUT_RETIREMENT_DIAGNOSTIC_PATH': str(self.output / 'retirement-sidecar.json')}),
            'launcher-exit.json': dict(launcherExitCode=0),
            'ui/preview.json': dict(status='passed'),
            'ui/annotation-details/annotation-details.json': dict(status='passed', sourceCommit=SOURCE,
                includeResourceCycles=False, bundlePath='/explicitly-synthetic/PicShot.app'),
            'ui/annotation-details/callouts/annotation-callouts.json': callout,
            'retirement-sidecar.json': dict(schema='callout-associated-token-diagnostic-v1', acceptanceStatus='passed',
                monitorBeganAtUptime=begin, snapshotStartedAtUptime=103.0, snapshotFinishedAtUptime=103.1,
                cycles=cycles, observedLifecycle=copy.deepcopy(life)),
        }
        self.processes = []
        for kind, seconds in [('native', 540), ('package', 1800), ('launch', 630)]:
            path = self.root / (kind + '.json')
            path.write_text(json.dumps(dict(status='exited', exit_code=0, log_truncated=False, timeout_seconds=seconds)))
            self.processes.append(path)
        self.save()

    def save(self):
        for name, value in self.data.items():
            path = self.output / name; path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(value))

    def run_capture(self, optimized=False, capture_root=None):
        self.save()
        result = self.root / 'result.json'
        command = [sys.executable] + (['-O'] if optimized else [])
        command += [str(SCRIPTS / 'check-callout-retirement-diagnostic.py'), 'capture', str(self.output if capture_root is None else capture_root), SOURCE, str(result)]
        for path in self.processes:
            command += ['--process-report', str(path)]
        process = subprocess.run(command, capture_output=True, text=True, timeout=10)
        return process.returncode, json.loads(result.read_text())

    def test_valid_synthetic_capture_preserves_original_pass_without_installer_claim(self):
        for optimized in (False, True):
            code, report = self.run_capture(optimized)
            self.assertEqual(code, 0, report)
            self.assertEqual(report['status'], 'observed')
            self.assertEqual(report['diagnosticCompleteness'], 'captured')
            self.assertTrue(report['originalNativeFixturesPassed'])
            self.assertFalse(report['fullInstallerAcceptanceClaimed'])

    def test_symlink_fixture_root_uses_canonical_environment_in_both_modes(self):
        physical = self.root / 'physical-root'
        physical.mkdir()
        alias = self.root / 'lexical-alias'
        alias.symlink_to(physical, target_is_directory=True)
        self.prepare_fixture(alias)
        self.assertNotEqual(alias, physical.resolve())
        self.assertEqual(self.root, physical.resolve())
        environment = self.data['identity.json']['fixtureEnvironment']
        canonical = str((physical / 'capture/retirement-sidecar.json').resolve())
        self.assertEqual(environment['PICSHOT_CALLOUT_RETIREMENT_DIAGNOSTIC_PATH'], canonical)
        for optimized in (False, True):
            with self.subTest(optimized=optimized):
                # A lexical CLI root is safe when the runner-recorded sidecar
                # path is canonical. Reproduce the old malformed record too.
                environment['PICSHOT_CALLOUT_RETIREMENT_DIAGNOSTIC_PATH'] = canonical
                code, report = self.run_capture(optimized, alias / 'capture')
                self.assertEqual(code, 0, report)
                self.assertEqual(report['diagnosticCompleteness'], 'captured')
                environment['PICSHOT_CALLOUT_RETIREMENT_DIAGNOSTIC_PATH'] = str(alias / 'capture/retirement-sidecar.json')
                code, report = self.run_capture(optimized, alias / 'capture')
                self.assertEqual(code, 1, report)
                self.assertEqual(report['error'], 'fixture ordering/environment changed')
                self.assertEqual(report['diagnosticCompleteness'], 'incomplete')

    def test_original_failure_remains_failure_despite_earlier_weak_nil(self):
        for name in ('ui/preview.json', 'ui/annotation-details/annotation-details.json', 'ui/annotation-details/callouts/annotation-callouts.json'):
            self.data[name]['status'] = 'failed'
        self.data['ui/annotation-details/callouts/annotation-callouts.json']['commentLifecycle']['status'] = 'failed'
        self.data['retirement-sidecar.json']['observedLifecycle']['status'] = 'failed'
        self.data['retirement-sidecar.json']['acceptanceStatus'] = 'failed'
        for optimized in (False, True):
            code, report = self.run_capture(optimized)
            self.assertEqual(code, 1, report)
            self.assertEqual(report['status'], 'original-acceptance-failed')
            self.assertEqual(report['diagnosticCompleteness'], 'captured')
            self.assertFalse(report['originalNativeFixturesPassed'])
            self.assertEqual(report['originalAcceptance']['lifecycle'], 'failed')
            self.assertEqual(report['timing'][0]['trackedPairTiming'], 'weak-nil-confirmed-by-deadline')

    def test_no_tolerance_is_added_to_callback_deadline(self):
        row = self.data['retirement-sidecar.json']['cycles'][0]
        for delay, expected in [(2.0, 'weak-nil-confirmed-by-deadline'), (2.000001, 'inconclusive')]:
            row['input']['weakCheckFinishedUptime'] = row['closedAtUptime'] + delay
            code, report = self.run_capture(True)
            self.assertEqual(code, 0, report)
            self.assertEqual(report['timing'][0]['input']['timing'], expected)

    def test_late_missing_and_premature_callbacks_are_inconclusive(self):
        row = self.data['retirement-sidecar.json']['cycles'][0]
        for change in ('late', 'missing', 'source-alive'):
            event = dict(tokenDeinitUptime=row['closedAtUptime'] + .001,
                         weakCheckFinishedUptime=row['closedAtUptime'] + .002,
                         sourceWasWeakNil=True, callbackWasOnMainThread=True)
            row['input'] = event
            if change == 'late': event['weakCheckFinishedUptime'] = row['closedAtUptime'] + 2.1
            if change == 'missing': row.pop('input')
            if change == 'source-alive': event['sourceWasWeakNil'] = False
            code, report = self.run_capture(True)
            self.assertEqual(code, 0, report)
            self.assertEqual(report['timing'][0]['trackedPairTiming'], 'inconclusive')

    def test_optimized_checker_rejects_changed_bounds_identity_and_routes(self):
        original = copy.deepcopy(self.data)
        def change_original_bound(data):
            for life in (data['retirement-sidecar.json']['observedLifecycle'],
                         data['ui/annotation-details/callouts/annotation-callouts.json']['commentLifecycle']):
                life['maximumSamples'] = 257
        changes = [
            (lambda d: d['identity.json'].update(sourceCommit='2' * 40), 'diagnostic identity mismatch'),
            (lambda d: d['identity.json'].update(architecture='arm64'), 'diagnostic identity mismatch'),
            (lambda d: d['identity.json'].update(executionsRequested=2), 'diagnostic bounds or invocation count changed'),
            (lambda d: d['identity.json'].update(executionsRequested=True), 'invalid identity bounds'),
            (lambda d: d['identity.json'].update(nativeDeadlineMilliseconds=2001), 'diagnostic bounds or invocation count changed'),
            (lambda d: d['identity.json']['fixtureEnvironment'].update(PICSHOT_ANNOTATION_DETAILS_ONLY='1'), 'fixture ordering/environment changed'),
            (change_original_bound, 'original bounds/claim changed'),
            (lambda d: d['retirement-sidecar.json']['observedLifecycle'].update(maximumSamples=257), 'sidecar must preserve original lifecycle/status exactly'),
            (lambda d: d['retirement-sidecar.json']['cycles'][0].update(closedAtUptime=200), 'close/snapshot order'),
            (lambda d: d['retirement-sidecar.json']['cycles'][0]['input'].update(sourceWasWeakNil=1), 'invalid callback flags'),
            (lambda d: d['retirement-sidecar.json']['cycles'][0]['input'].update(weakCheckFinishedUptime=104), 'callback/snapshot clock order'),
            (lambda d: d['retirement-sidecar.json'].update(acceptanceStatus='failed'), 'sidecar must preserve original lifecycle/status exactly'),
        ]
        for change, expected_error in changes:
            with self.subTest(reason=expected_error):
                self.data = copy.deepcopy(original); change(self.data)
                code, report = self.run_capture(True)
                self.assertEqual(code, 1, report)
                self.assertEqual(report['diagnosticCompleteness'], 'incomplete')
                self.assertEqual(report['error'], expected_error)

    def test_optimized_checker_requires_complete_bounded_processes(self):
        process_error = 'bounded process incomplete: ' + str(self.processes[0])
        for change, expected_error in [(dict(status='timeout'), process_error), (dict(exit_code=1), process_error),
                       (dict(exit_code=False), process_error), (dict(log_truncated=True), process_error),
                       (dict(timeout_seconds=541), 'process timeout changed')]:
            with self.subTest(change=change):
                self.processes[0].write_text(json.dumps(dict(status='exited', exit_code=0, log_truncated=False,
                                                           timeout_seconds=540) | change))
                code, report = self.run_capture(True)
                self.assertEqual(code, 1, report)
                self.assertEqual(report['diagnosticCompleteness'], 'incomplete')
                self.assertEqual(report['error'], expected_error)

    def test_reported_pass_must_satisfy_unchanged_original_lifecycle_checker(self):
        for life in [self.data['retirement-sidecar.json']['observedLifecycle'],
                     self.data['ui/annotation-details/callouts/annotation-callouts.json']['commentLifecycle']]:
            life['cycles'][0]['releasedAfterMilliseconds'] = 2001
        code, report = self.run_capture(True)
        self.assertEqual(code, 1, report)
        self.assertEqual(report['diagnosticCompleteness'], 'incomplete')
        self.assertEqual(report['error'], 'comment lifecycle release exceeded native input deadline')

    def test_native_requires_all_eleven_unique_completions_under_optimization(self):
        source = ROOT / 'Tests/PicShotTests/NumberedCalloutRetirementDiagnosticsTests.swift'
        expected = re.findall(r'\bfunc (test\w+)\(', source.read_text())
        log = self.root / 'native.log'
        for names, success in [(expected, True), (expected[:-1], False), (expected + expected[:1], False)]:
            log.write_text('\n'.join("Test Case 'NumberedCalloutRetirementDiagnosticsTests." + name + "' passed (0.001 seconds)." for name in names))
            command = [sys.executable, '-O', str(SCRIPTS / 'check-callout-retirement-diagnostic.py'), 'native', str(self.processes[0]), str(log), str(source)]
            process = subprocess.run(command, capture_output=True, text=True, timeout=10)
            self.assertEqual(process.returncode == 0, success, process.stderr)
            if not success:
                self.assertIn('ValueError: native diagnostic completions missing, duplicated or unexpected', process.stderr)


    def test_partial_failure_snapshot_does_not_complete_missing_cycles(self):
        for name in ('ui/preview.json', 'ui/annotation-details/annotation-details.json', 'ui/annotation-details/callouts/annotation-callouts.json'):
            self.data[name]['status'] = 'failed'
        life = self.data['ui/annotation-details/callouts/annotation-callouts.json']['commentLifecycle']
        life['status'] = 'failed'
        life['cycles'] = life['cycles'][:3]
        life['samples'] = [sample for sample in life['samples'] if sample['createdCycles'] <= 3]
        sidecar = self.data['retirement-sidecar.json']
        sidecar.update(acceptanceStatus='failed', observedLifecycle=copy.deepcopy(life), cycles=sidecar['cycles'][:3])
        code, report = self.run_capture(True)
        self.assertEqual(code, 1, report)
        self.assertEqual(report['createdCycles'], 3)
        self.assertEqual(report['expectedCycles'], 6)
        self.assertEqual(report['diagnosticCompleteness'], 'captured')
        self.assertFalse(report['originalNativeFixturesPassed'])

    def test_original_functional_callout_check_is_not_relaxed(self):
        checks = self.data['ui/annotation-details/callouts/annotation-callouts.json']['checks']
        failed_check = next(iter(checks))
        checks[failed_check] = False
        code, report = self.run_capture(True)
        self.assertEqual(code, 1, report)
        self.assertEqual(report['diagnosticCompleteness'], 'incomplete')
        self.assertEqual(report['error'], 'missing/failed assertion: ' + failed_check)

    def test_new_python_checks_do_not_use_removable_assert_statements(self):
        paths = [SCRIPTS / 'check-callout-retirement-diagnostic.py']
        snippets = [paths[0].read_text()]
        for name in ('test-callout-retirement-source-scope.sh', 'package-callout-retirement-diagnostic.sh', 'run-callout-retirement-diagnostic.sh'):
            snippets.extend(re.findall(r"<<'PY'\n(.*?)\nPY", (SCRIPTS / name).read_text(), re.S))
        for snippet in snippets:
            self.assertFalse(any(isinstance(node, ast.Assert) for node in ast.walk(ast.parse(snippet))))

    def test_workflow_isolates_marker_at_workflow_level_and_launches_once(self):
        workflow = (ROOT / '.github/workflows/macos.yml').read_text()
        group = next(line for line in workflow.splitlines() if line.startswith('  group:'))
        prefix = '  group: picshot-${{ github.ref }}-${{ '
        self.assertTrue(group.startswith(prefix))
        remaining = group[len(prefix):]
        rules = []
        condition = re.compile(r"contains\(github\.event\.head_commit\.message \|\| '', '([^']+)'\) && '([^']+)' \|\| ")
        while match := condition.match(remaining):
            rules.append(match.groups())
            remaining = remaining[match.end():]
        self.assertEqual(remaining, "'current' }}")
        self.assertEqual(rules[:2], [('[editable-observation]', 'editable-observation'),
                                    ('[callout-retirement]', 'callout-retirement')])
        cancellation = next(line for line in workflow.splitlines() if line.startswith('  cancel-in-progress:'))
        non_cancelling = ['[callout-retirement]', '[editable-observation]']
        self.assertEqual(cancellation, '  cancel-in-progress: ${{ '
                         + ' && '.join(f"!contains(github.event.head_commit.message || '', '{marker}')"
                                       for marker in non_cancelling) + ' }}')
        # Evaluate the validated contains/&&/|| chain in production order.
        for message, expected_group, expected_cancel in [
            ('Ordinary release commit', 'current', True),
            ('[verify-installers] release', 'current', True),
            ('[intel-only] release', 'intel-05', True),
            ('[callout-retirement] diagnostic', 'callout-retirement', False),
            ('[editable-observation] diagnostic', 'editable-observation', False),
            ('[callout-retirement] [editable-observation]', 'editable-observation', False),
        ]:
            with self.subTest(message=message):
                selected = next((route for marker, route in rules if marker in message), 'current')
                self.assertEqual(selected, expected_group)
                self.assertEqual(all(marker not in message for marker in non_cancelling), expected_cancel)
        build = workflow.split('  build:\n', 1)[1].split('\n    strategy:', 1)[0]
        self.assertIn("!contains(github.event.head_commit.message || '', '[callout-retirement]')", build)
        self.assertIn("!contains(github.event.head_commit.message || '', '[editable-observation]')", build)
        # Later jobs have their own always() uploads; inspect this job only.
        diagnostic = re.search(r'^  callout-retirement:\n(.*?)(?=^  [\w-]+:\n|\Z)', workflow, re.M | re.S)[1]
        self.assertIn("if: ${{ contains(github.event.head_commit.message || '', '[callout-retirement]') }}", diagnostic)
        self.assertIn('runs-on: macos-15-intel', diagnostic)
        self.assertEqual(diagnostic.count('-- bash scripts/run-callout-retirement-diagnostic.sh'), 1)
        self.assertNotIn('continue-on-error', diagnostic)
        self.assertIn('Archive raw diagnostic outcomes', diagnostic)
        self.assertEqual(diagnostic.count('if: always()'), 2)


if __name__ == '__main__':
    unittest.main()
