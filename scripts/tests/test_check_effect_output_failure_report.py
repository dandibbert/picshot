"""Synthetic report mutations test the checker, never installed runtime acceptance."""
import copy
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'check-effect-output-failure-report.py'
SPEC = importlib.util.spec_from_file_location('effect_check', SCRIPT)
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)

# Keep synthetic expectations independent of the checker's constants, so removal
# of a required field or route from the checker still fails its mutation tests.
ROUTES = ['copy', 'history', 'pin', 'quickSave', 'saveCopy', 'applyToPin', 'recognition', 'translation', 'export']
SELECTORS = ['copyResult', 'saveResult', 'pinResult', 'quickSaveResult', 'saveCopyResult',
             'recognizeResult', 'translateResult', 'applyResult', 'exportResult']
FALSE_FLAGS = ['generalPasteboardReadOrWritten', 'screenCaptureStarted', 'permissionRequests',
               'networkUsed', 'userFilesReadOrWritten', 'standardUserDefaultsChanged',
               'originalImageCopyTestedAsAnnotatedOutput', 'nonNilGPUCorruptionCovered',
               'onscreenConcealmentCovered']
TRUE_FLAGS = ['syntheticSource', 'perCanvasFailureInjection', 'productionOutputActions', 'temporaryDirectoryRemoved']
CASE_FLAGS = ['draftPreserved', 'undoRedoPreserved', 'existingRedoBranchPreserved',
              'sourcePixelsUnchanged', 'priorOutputPreserved',
              'originalIdentityPreserved', 'baseIdentityPreserved', 'originalPixelsUnchanged',
              'basePixelsUnchanged', 'editableDocumentPreserved', 'cropViewportPreserved',
              'baseCropPreserved', 'numberSequencePreserved', 'decorationsPreserved',
              'priorEditableDocumentPreserved', 'presentationCacheCleared', 'failureNeverCached',
              'retryMatchesExpectedProjection', 'retryPreservesEditableDocument']
HASHES = ['priorOutputSHA256', 'priorEditableDocumentSHA256', 'editableDocumentSHA256',
          'originalSHA256', 'baseSHA256']
ROOT_COUNTS = dict(schemaVersion=2, caseCount=24, controllerReleaseCount=24,
                   activeProjectionJobsAfter=0, projectionReservedBytesAfter=0, queuedOperationsAfter=0,
                   activeExportSessionsAfter=0, projectionJobsStartedDuringFailures=0,
                   projectionJobsStarted=12, projectionJobsCompleted=12)
CASE_COUNTS = dict(failedRenderRequests=18, errorCallbacks=18, sinkDeliveriesDuringFailures=0,
                   wrongErrorCallbacks=0, closeCallbacksDuringFailures=0, successControlDeliveries=1,
                   retryDeliveries=1, failedPatchPosition=2, cacheFailureAttempts=2,
                   existingRedoBranchRoundTrips=2,
                   projectionJobsStartedDuringFailures=0)
MISSING = object()


class EffectGuardCheckerTests(unittest.TestCase):
    def setUp(self):
        self.info = dict(PicShotSourceCommit='a' * 40, CFBundleShortVersionString='0.17.0',
                         CFBundleVersion='113', CFBundleExecutable='PicShot')
        self.app = '/owned/PicShot.app'
        self.launcher = dict(status='exited', schemaVersion=1, launcherExitCode=0, processIdentifier=4321,
            createsNewApplicationInstance=True, callbackReceived=True, ownedExitConfirmed=True,
            selectedAppPath=self.app, launchedAppPath=self.app, launchedExecutablePath=self.app + '/Contents/MacOS/PicShot')
        self.report = dict(status='passed', sourceCommit='a' * 40, version='0.17.0', buildVersion='113',
            bundlePath=self.app, executablePath=self.app + '/Contents/MacOS/PicShot', processIdentifier=4321,
            **ROOT_COUNTS)
        self.report.update({name: False for name in FALSE_FLAGS})
        self.report.update({name: True for name in TRUE_FLAGS})
        self.report['cases'] = []
        for tool in ('blur', 'pixelate'):
            for decorated in (False, True):
                for cropped in (False, True):
                    for sink in ('legacy', 'originalAware', 'editable'):
                        case = dict(status='passed', tool=tool, decorated=decorated, cropped=cropped, sinkMode=sink,
                            rejectedRoutes=ROUTES[:], rejectedNativeSelectors=SELECTORS[:],
                            undoRedoSteps=2 + int(cropped) + int(decorated), priorOutputBytes=200,
                            priorEditableDocumentBytes=100, editableDocumentBytes=300, **CASE_COUNTS)
                        case.update({name: True for name in CASE_FLAGS})
                        case.update({name: format(index + 1, 'x') * 64 for index, name in enumerate(HASHES)})
                        self.report['cases'].append(case)

    def check(self, report=MISSING, info=MISSING, launcher=MISSING, source='a' * 40):
        return CHECK.validate(self.report if report is MISSING else report,
                              self.info if info is MISSING else info, self.app, source,
                              self.launcher if launcher is MISSING else launcher)

    def reject_mutation(self, scope, key, value=MISSING, case_index=0):
        report, info, launcher = copy.deepcopy((self.report, self.info, self.launcher))
        target = {'report': report, 'info': info, 'launcher': launcher, 'case': report['cases'][case_index]}[scope]
        if value is MISSING:
            target.pop(key)
        else:
            target[key] = value
        with self.assertRaises(ValueError):
            self.check(report, info, launcher)

    def test_complete_contract_passes_and_case_order_is_irrelevant(self):
        self.assertIs(self.check(), self.report)
        self.report['cases'].reverse()
        self.check()

    def test_report_info_launcher_and_case_must_be_objects(self):
        for value in (None, [], 'passed', True, 42):
            for scope in ('report', 'info', 'launcher'):
                with self.subTest(scope=scope, value=value), self.assertRaises(ValueError):
                    self.check(**{scope: value})
            report = copy.deepcopy(self.report)
            report['cases'][0] = value
            with self.subTest(scope='case', value=value), self.assertRaises(ValueError):
                self.check(report)

    def test_failed_or_missing_status_is_rejected(self):
        for scope in ('report', 'case', 'launcher'):
            for value in (MISSING, None, 'failed', 'running', True):
                with self.subTest(scope=scope, value=value):
                    self.reject_mutation(scope, 'status', value)

    def test_all_root_counters_are_required_and_strict_integers(self):
        for key, expected in ROOT_COUNTS.items():
            for value in (MISSING, None, True, False, float(expected), str(expected), expected + 1, expected - 1):
                with self.subTest(key=key, value=value):
                    self.reject_mutation('report', key, value)

    def test_all_case_counters_are_required_and_strict_integers(self):
        for key, expected in dict(CASE_COUNTS, undoRedoSteps=2).items():
            for value in (MISSING, None, True, False, float(expected), str(expected), expected + 1, expected - 1):
                with self.subTest(key=key, value=value):
                    self.reject_mutation('case', key, value)
        for index, case in enumerate(self.report['cases']):
            with self.subTest(case=index):
                self.reject_mutation('case', 'undoRedoSteps', case['undoRedoSteps'] + 1, index)
                self.reject_mutation('case', 'projectionJobsStartedDuringFailures', 1, index)

    def test_projection_counts_cannot_include_failed_or_control_attempts(self):
        for key in ('projectionJobsStarted', 'projectionJobsCompleted'):
            for value in (0, 24, 36, 48):
                with self.subTest(key=key, value=value):
                    self.reject_mutation('report', key, value)

    def test_every_root_flag_is_mandatory_and_strict_boolean(self):
        for key in FALSE_FLAGS:
            for value in (MISSING, None, True, 0, 1, 'false'):
                with self.subTest(key=key, value=value):
                    self.reject_mutation('report', key, value)
        for key in TRUE_FLAGS:
            for value in (MISSING, None, False, 0, 1, 'true'):
                with self.subTest(key=key, value=value):
                    self.reject_mutation('report', key, value)

    def test_every_case_preservation_flag_is_mandatory_and_strict_boolean(self):
        for key in CASE_FLAGS:
            for value in (MISSING, None, False, 0, 1, 'true'):
                with self.subTest(key=key, value=value):
                    self.reject_mutation('case', key, value)
            for index in range(24):
                with self.subTest(key=key, case=index):
                    self.reject_mutation('case', key, False, index)

    def test_every_hash_is_mandatory_lowercase_sha256(self):
        for key in HASHES:
            for value in (MISSING, None, True, 0, [], {}, '', 'A' * 64, 'g' * 64,
                          'a' * 63, 'a' * 65, 'a' * 64 + '\n'):
                with self.subTest(key=key, value=value):
                    self.reject_mutation('case', key, value)
            for index in range(24):
                with self.subTest(key=key, case=index):
                    self.reject_mutation('case', key, case_index=index)

    def test_evidence_sizes_enforce_inclusive_bounds_and_integer_type(self):
        for key, minimum in [('priorOutputBytes', 25), ('priorEditableDocumentBytes', 1), ('editableDocumentBytes', 1)]:
            for value in (minimum, 128 * 1024):
                report = copy.deepcopy(self.report)
                report['cases'][0][key] = value
                with self.subTest(key=key, valid=value):
                    self.check(report)
            for value in (MISSING, None, True, False, float(minimum), str(minimum), minimum - 1, -1, 128 * 1024 + 1):
                with self.subTest(key=key, invalid=value):
                    self.reject_mutation('case', key, value)

    def test_all_routes_and_selectors_are_required_in_each_case(self):
        for key, values in [('rejectedRoutes', ROUTES), ('rejectedNativeSelectors', SELECTORS)]:
            for value in (MISSING, None, [], values[:-1], values[::-1], values + ['other'],
                          [values[1]] + values[1:], ' '.join(values)):
                with self.subTest(key=key, value=value):
                    self.reject_mutation('case', key, value)
            for index in range(24):
                with self.subTest(key=key, case=index):
                    self.reject_mutation('case', key, values[:-1], index)

    def test_missing_extra_duplicate_or_legacy_matrix_is_rejected(self):
        for value in (MISSING, None, {}, [], self.report['cases'][:-1], self.report['cases'] * 2):
            with self.subTest(value=value):
                self.reject_mutation('report', 'cases', value)
        for index in range(24):
            report = copy.deepcopy(self.report)
            report['cases'][index] = copy.deepcopy(report['cases'][(index + 1) % 24])
            with self.subTest(duplicate=index), self.assertRaises(ValueError):
                self.check(report)
        # A legacy eight-case report cannot substitute for the editable matrix.
        report = copy.deepcopy(self.report)
        report.update(schemaVersion=1, caseCount=8, controllerReleaseCount=8, cases=report['cases'][:8])
        with self.assertRaises(ValueError):
            self.check(report)

    def test_matrix_variants_are_mandatory_and_typed(self):
        for key in ('decorated', 'cropped'):
            for value in (MISSING, None, 0, 1, 'false', []):
                with self.subTest(key=key, value=value):
                    self.reject_mutation('case', key, value)
        for key in ('tool', 'sinkMode'):
            for value in (MISSING, None, True, 0, [], {}, '', 'unknown'):
                with self.subTest(key=key, value=value):
                    self.reject_mutation('case', key, value)
        for sink in ('legacy', 'originalAware', 'editable'):
            report = copy.deepcopy(self.report)
            for case in report['cases']:
                if case['sinkMode'] == sink:
                    case['sinkMode'] = 'originalAware' if sink == 'legacy' else 'legacy'
            with self.subTest(missing_sink=sink), self.assertRaises(ValueError):
                self.check(report)

    def test_source_identity_is_required_at_all_three_inputs(self):
        for source in (None, True, 40, '', 'a' * 39, 'a' * 41, 'A' * 40, 'g' * 40, 'a' * 40 + '\n', 'b' * 40):
            with self.subTest(source=source), self.assertRaises(ValueError):
                self.check(source=source)
        for scope, key in [('report', 'sourceCommit'), ('info', 'PicShotSourceCommit')]:
            for value in (MISSING, None, 'c' * 40):
                with self.subTest(scope=scope, value=value):
                    self.reject_mutation(scope, key, value)

    def test_version_and_build_identity_are_nonempty_strings(self):
        for key, info_key in [('version', 'CFBundleShortVersionString'), ('buildVersion', 'CFBundleVersion')]:
            for scope, field in [('report', key), ('info', info_key)]:
                for value in (MISSING, None, '', True, 113, 'different'):
                    with self.subTest(scope=scope, key=field, value=value):
                        self.reject_mutation(scope, field, value)
            for value in (None, '', True, 113):
                report, info = copy.deepcopy((self.report, self.info))
                report[key] = info[info_key] = value
                with self.subTest(matching_invalid=value), self.assertRaises(ValueError):
                    self.check(report=report, info=info)

    def test_bundle_executable_and_launcher_paths_are_bound_to_installed_app(self):
        for scope, key in [('report', 'bundlePath'), ('report', 'executablePath'),
                           ('launcher', 'selectedAppPath'), ('launcher', 'launchedAppPath'),
                           ('launcher', 'launchedExecutablePath')]:
            for value in (MISSING, None, True, 0, '', 'relative/PicShot.app', '/other/PicShot.app',
                          '/owned/PicShot.app/Contents/MacOS/Other'):
                with self.subTest(scope=scope, key=key, value=value):
                    self.reject_mutation(scope, key, value)
        for value in (MISSING, None, '', 'Other', '../MacOS/PicShot'):
            with self.subTest(executable_name=value):
                self.reject_mutation('info', 'CFBundleExecutable', value)

    def test_pid_and_launcher_exit_identity_are_required(self):
        for scope in ('report', 'launcher'):
            for value in (MISSING, None, True, False, 0, -1, 4321.0, '4321', 4322):
                with self.subTest(scope=scope, pid=value):
                    self.reject_mutation(scope, 'processIdentifier', value)
        for value in (True, False, 0, -1, 4321.0, '4321'):
            report, launcher = copy.deepcopy((self.report, self.launcher))
            report['processIdentifier'] = launcher['processIdentifier'] = value
            with self.subTest(matching_invalid_pid=value), self.assertRaises(ValueError):
                self.check(report=report, launcher=launcher)
        for key, expected in [('schemaVersion', 1), ('launcherExitCode', 0)]:
            for value in (MISSING, None, True, False, float(expected), str(expected), expected + 1):
                with self.subTest(key=key, value=value):
                    self.reject_mutation('launcher', key, value)
        for key in ('createsNewApplicationInstance', 'callbackReceived', 'ownedExitConfirmed'):
            for value in (MISSING, None, False, 0, 1, 'true'):
                with self.subTest(key=key, value=value):
                    self.reject_mutation('launcher', key, value)

    def test_symlink_parent_is_canonicalized_without_weakening_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            real = root / 'private/var'
            real.mkdir(parents=True)
            alias = root / 'var'
            alias.symlink_to(real, target_is_directory=True)
            canonical = str(real / 'owned/PicShot.app')
            self.app = str(alias / 'owned/PicShot.app')
            self.report['bundlePath'] = canonical
            self.report['executablePath'] = canonical + '/Contents/MacOS/PicShot'
            self.launcher.update(selectedAppPath=self.app, launchedAppPath=canonical,
                                 launchedExecutablePath=canonical + '/Contents/MacOS/PicShot')
            self.check()
            self.launcher['launchedExecutablePath'] = canonical + '/Contents/MacOS/Other'
            with self.assertRaises(ValueError):
                self.check()

    def test_json_reader_rejects_missing_empty_malformed_and_nonobject_reports(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'report.json'
            with self.assertRaises(ValueError):
                CHECK.read_json(path, 128 * 1024)
            with self.assertRaises(ValueError):
                CHECK.read_json(Path(tmp), 128 * 1024)
            for payload in (b'', b'{', b'[]', b'null', b'true', b'42', b'"passed"', b'\xff',
                            b'{}{}', b'{"status":"failed","status":"passed"}',
                            b'{"nested":{"value":1,"value":2}}', b'{"value":NaN}',
                            b'{"value":Infinity}', b'{"value":-Infinity}'):
                path.write_bytes(payload)
                with self.subTest(payload=payload), self.assertRaises(ValueError):
                    CHECK.read_json(path, 128 * 1024)

    def test_json_reader_bounds_report_and_launcher_sizes(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'report.json'
            for maximum in (128 * 1024, 16 * 1024):
                payload = b'{"value":1}'
                path.write_bytes(payload + b' ' * (maximum - len(payload)))
                self.assertEqual(CHECK.read_json(path, maximum), {'value': 1})
                with path.open('ab') as stream:
                    stream.write(b' ')
                with self.subTest(maximum=maximum), self.assertRaises(ValueError):
                    CHECK.read_json(path, maximum)

    def test_json_reader_rejects_report_symlinks(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / 'target.json'
            target.write_text('{}')
            alias = root / 'alias.json'
            alias.symlink_to(target)
            with self.assertRaises(ValueError):
                CHECK.read_json(alias, 128 * 1024)

    def write_cli_inputs(self, root):
        app = root / 'PicShot.app'
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))
        report, launcher = copy.deepcopy((self.report, self.launcher))
        executable = str(app / 'Contents/MacOS/PicShot')
        report.update(bundlePath=str(app), executablePath=executable)
        launcher.update(selectedAppPath=str(app), launchedAppPath=str(app), launchedExecutablePath=executable)
        report_path, launcher_path = root / 'report.json', root / 'launcher.json'
        report_path.write_text(json.dumps(report))
        launcher_path.write_text(json.dumps(launcher))
        return report_path, app, 'a' * 40, launcher_path

    def run_cli(self, args, optimized):
        return subprocess.run([sys.executable, *(['-O'] if optimized else []), str(SCRIPT), *map(str, args)],
                              capture_output=True, text=True, timeout=10, check=False)

    def test_cli_success_summary_matches_24_cases_under_normal_and_optimized_python(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = self.write_cli_inputs(Path(tmp))
            self.assertEqual(CHECK.check(*args)['caseCount'], 24)
            for optimized in (False, True):
                with self.subTest(optimized=optimized):
                    result = self.run_cli(args, optimized)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(json.loads(result.stdout), dict(status='passed', sourceCommit='a' * 40,
                        caseCount=24, rejectedOutputAttempts=432, controllerReleaseCount=24, processIdentifier=4321))

    def test_cli_invalid_reports_fail_under_normal_and_optimized_python(self):
        for scenario in ('preservation', 'missing_hash', 'schema_bool', 'projection_work', 'duplicate_case',
                         'source', 'bundle', 'executable', 'pid', 'launcher_pid', 'launcher_exit',
                         'plist_identity', 'malformed', 'nonobject', 'oversized_report',
                         'oversized_launcher', 'symlink_report', 'symlink_launcher'):
            with tempfile.TemporaryDirectory() as tmp:
                report_path, app, source, launcher_path = self.write_cli_inputs(Path(tmp))
                report = json.loads(report_path.read_text())
                launcher = json.loads(launcher_path.read_text())
                if scenario == 'preservation':
                    report['cases'][-1]['retryPreservesEditableDocument'] = False
                elif scenario == 'missing_hash':
                    report['cases'][-1].pop('editableDocumentSHA256')
                elif scenario == 'schema_bool':
                    report['schemaVersion'] = True
                elif scenario == 'projection_work':
                    report['cases'][-1]['projectionJobsStartedDuringFailures'] = 1
                elif scenario == 'duplicate_case':
                    report['cases'][-1] = report['cases'][0]
                elif scenario == 'source':
                    source = 'b' * 40
                elif scenario == 'bundle':
                    report['bundlePath'] = '/other/PicShot.app'
                elif scenario == 'executable':
                    report['executablePath'] = str(app / 'Contents/MacOS/Other')
                elif scenario == 'pid':
                    report['processIdentifier'] = True
                elif scenario == 'launcher_pid':
                    launcher['processIdentifier'] = 9999
                elif scenario == 'launcher_exit':
                    launcher['ownedExitConfirmed'] = False
                elif scenario == 'plist_identity':
                    info = dict(self.info, PicShotSourceCommit='b' * 40)
                    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
                report_path.write_text(json.dumps(report))
                launcher_path.write_text(json.dumps(launcher))
                if scenario == 'malformed':
                    report_path.write_text('{')
                elif scenario == 'nonobject':
                    launcher_path.write_text('[]')
                elif scenario == 'oversized_report':
                    report_path.write_bytes(b' ' * (128 * 1024 + 1))
                elif scenario == 'oversized_launcher':
                    launcher_path.write_bytes(b' ' * (16 * 1024 + 1))
                elif scenario.startswith('symlink_'):
                    target = report_path if scenario == 'symlink_report' else launcher_path
                    alias = Path(tmp) / 'alias.json'
                    alias.symlink_to(target)
                    if scenario == 'symlink_report':
                        report_path = alias
                    else:
                        launcher_path = alias
                for optimized in (False, True):
                    with self.subTest(scenario=scenario, optimized=optimized):
                        result = self.run_cli((report_path, app, source, launcher_path), optimized)
                        self.assertNotEqual(result.returncode, 0)
                        self.assertEqual(result.stdout, '')

    def test_cli_missing_arguments_fail_under_normal_and_optimized_python(self):
        for optimized in (False, True):
            with self.subTest(optimized=optimized):
                result = self.run_cli([], optimized)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('REPORT APP SOURCE LAUNCHER_REPORT', result.stderr)
                self.assertEqual(result.stdout, '')


if __name__ == '__main__':
    unittest.main()
