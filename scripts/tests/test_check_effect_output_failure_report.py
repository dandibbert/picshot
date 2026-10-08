"""Synthetic report mutations test the checker, never installed runtime acceptance."""
import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('effect_check', Path(__file__).resolve().parents[1] / 'check-effect-output-failure-report.py')
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class EffectGuardCheckerTests(unittest.TestCase):
    def setUp(self):
        self.info = dict(PicShotSourceCommit='a' * 40, CFBundleShortVersionString='0.15.1', CFBundleVersion='110', CFBundleExecutable='PicShot')
        self.app = '/owned/PicShot.app'
        self.launcher = dict(status='exited', schemaVersion=1, launcherExitCode=0, processIdentifier=4321,
            createsNewApplicationInstance=True, callbackReceived=True, ownedExitConfirmed=True,
            selectedAppPath=self.app, launchedAppPath=self.app, launchedExecutablePath=self.app + '/Contents/MacOS/PicShot')
        self.report = dict(status='passed', schemaVersion=1, sourceCommit='a' * 40, version='0.15.1', buildVersion='110',
            bundlePath=self.app, executablePath=self.app + '/Contents/MacOS/PicShot', processIdentifier=4321,
            syntheticSource=True, perCanvasFailureInjection=True, productionOutputActions=True,
            temporaryDirectoryRemoved=True, caseCount=8, controllerReleaseCount=8)
        self.report.update({name: False for name in CHECK.FALSE_FLAGS})
        self.report.update({name: 0 for name in CHECK.ZERO_COUNTS})
        self.report['cases'] = [dict(status='passed', tool=tool, decorated=decorated, originalAwarePin=original,
            rejectedRoutes=CHECK.ROUTES[:], rejectedNativeSelectors=CHECK.SELECTORS[:],
            failedRenderRequests=18, errorCallbacks=18, sinkDeliveriesDuringFailures=0, wrongErrorCallbacks=0,
            closeCallbacksDuringFailures=0, successControlDeliveries=1, retryDeliveries=1, failedPatchPosition=2,
            draftPreserved=True, undoRedoPreserved=True, sourcePixelsUnchanged=True, priorOutputPreserved=True,
            priorOutputSHA256='b' * 64, priorOutputBytes=200)
            for tool in ('blur', 'pixelate') for decorated in (False, True) for original in (False, True)]

    def check(self, report=None):
        CHECK.validate(self.report if report is None else report, self.info, self.app, 'a' * 40, self.launcher)

    def test_complete_contract_passes(self):
        self.check()

    def test_source_version_build_and_bundle_mismatches_fail(self):
        for key, value in [('sourceCommit', 'c' * 40), ('version', '0.15.0'), ('buildVersion', '109'), ('bundlePath', '/other/PicShot.app')]:
            with self.subTest(key=key):
                r = copy.deepcopy(self.report); r[key] = value
                with self.assertRaises(ValueError): self.check(r)

    def test_missing_duplicate_and_changed_matrix_fail(self):
        for mutate in [lambda r: r['cases'].pop(), lambda r: r['cases'].__setitem__(0, r['cases'][1]),
                       lambda r: r['cases'][0].__setitem__('decorated', 0), lambda r: r['cases'][0].__setitem__('tool', 'redact')]:
            r = copy.deepcopy(self.report); mutate(r)
            with self.assertRaises(ValueError): self.check(r)

    def test_omitted_route_selector_and_error_fail(self):
        for key, value in [('rejectedRoutes', CHECK.ROUTES[:-1]), ('rejectedNativeSelectors', CHECK.SELECTORS[:-1]),
                           ('errorCallbacks', 17), ('failedRenderRequests', 17), ('failedPatchPosition', 1)]:
            r = copy.deepcopy(self.report); r['cases'][0][key] = value
            with self.assertRaises(ValueError): self.check(r)

    def test_publication_mutation_and_false_preservation_fail(self):
        for key, value in [('sinkDeliveriesDuringFailures', 1), ('closeCallbacksDuringFailures', 1),
                           ('draftPreserved', False), ('priorOutputPreserved', False), ('sourcePixelsUnchanged', False),
                           ('successControlDeliveries', 0), ('retryDeliveries', 0)]:
            r = copy.deepcopy(self.report); r['cases'][0][key] = value
            with self.assertRaises(ValueError): self.check(r)

    def test_cleanup_active_work_and_boolean_counter_fail(self):
        for key, value in [('controllerReleaseCount', 7), ('temporaryDirectoryRemoved', False),
                           ('projectionJobsStarted', 1), ('activeExportSessionsAfter', 1), ('queuedOperationsAfter', False)]:
            r = copy.deepcopy(self.report); r[key] = value
            with self.assertRaises(ValueError): self.check(r)

    def test_side_effect_flags_and_incomplete_prior_evidence_fail(self):
        for key in CHECK.FALSE_FLAGS:
            r = copy.deepcopy(self.report); r[key] = True
            with self.assertRaises(ValueError): self.check(r)
        for key, value in [('priorOutputSHA256', ''), ('priorOutputBytes', 0), ('priorOutputBytes', 1024 * 1024)]:
            r = copy.deepcopy(self.report); r['cases'][0][key] = value
            with self.assertRaises(ValueError): self.check(r)

    def test_pid_executable_and_owned_exit_mismatches_fail(self):
        for key, value in [('processIdentifier', 4322), ('executablePath', '/other/PicShot')]:
            r = copy.deepcopy(self.report); r[key] = value
            with self.assertRaises(ValueError): self.check(r)
        for key, value in [('processIdentifier', 0), ('launchedExecutablePath', '/other/PicShot'),
                           ('launchedAppPath', '/other/PicShot.app'), ('ownedExitConfirmed', False), ('launcherExitCode', 1)]:
            original = copy.deepcopy(self.launcher); self.launcher[key] = value
            with self.assertRaises(ValueError): self.check()
            self.launcher = original

    def test_symlink_parent_is_canonicalized_without_weakening_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); real = root / 'private/var'; real.mkdir(parents=True)
            alias = root / 'var'; alias.symlink_to(real, target_is_directory=True)
            canonical = str(real / 'owned/PicShot.app'); self.app = str(alias / 'owned/PicShot.app')
            self.report['bundlePath'] = canonical
            self.report['executablePath'] = canonical + '/Contents/MacOS/PicShot'
            self.launcher.update(selectedAppPath=self.app, launchedAppPath=canonical,
                                 launchedExecutablePath=canonical + '/Contents/MacOS/PicShot')
            self.check()
            self.launcher['launchedExecutablePath'] = canonical + '/Contents/MacOS/Other'
            with self.assertRaises(ValueError): self.check()


if __name__ == '__main__': unittest.main()
