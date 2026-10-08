"""Portable guard mutations. Actual native acceptance requires the macOS run."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


R = module('renderer_guard_check_test', SCRIPTS / 'check-renderer-storage-guard.py')
F = module('renderer_drawing_guard_fixture', SCRIPTS / 'tests/test_check_drawing_raster_guard.py')


class RendererStorageGuardTests(unittest.TestCase):
    def setUp(self):
        self.fixture = F.DrawingGuardCheckerTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.fixture.write()
        self.directory = self.fixture.directory.resolve(strict=True)
        self.app, self.source = self.fixture.app, self.fixture.source
        self.executable = self.app / 'Contents/MacOS/PicShot'
        self.executable.write_bytes(b'synthetic executable identity; never executed')
        self.report = copy.deepcopy(self.fixture.sidecar)
        self.report.update(comparisonKind=R.R.KIND, productionDefaultStrategy='native', drawingStrategy='owned-srgb8',
            executableBytes=self.executable.stat().st_size, executableSHA256=hashlib.sha256(self.executable.read_bytes()).hexdigest(),
            drawingReportSHA256=hashlib.sha256(self.fixture.sidecar_path.read_bytes()).hexdigest(),
            rendererAutoreleaseScope='draw-only',
            tracker=dict(attemptCount=6, nativeCount=0, eligibleCount=6, seedCount=6, drawCount=2, publishCount=2,
                failureCount=4, unsupportedCounts={}, allocations=6, deallocations=6, releaseCallbacks=2,
                allocatedBytes=384, deallocatedBytes=384, callbackBytes=128, activeBytes=0, peakActiveBytes=64,
                callbackSizesMatch=True))
        self.path = self.directory / R.FILENAME

    def write(self):
        self.path.write_text(json.dumps(self.report))

    def check(self, strategy='owned-srgb8'):
        self.write()
        return R.check_directory(self.directory, self.app, self.source, strategy)

    def test_expected_failures_free_before_provider_and_native_matrix_stays_complete(self):
        result = self.check()
        self.assertEqual((result['caseCount'], result['rejectedOutputAttempts'], result['controllerReleaseCount']), (24, 432, 24))
        self.assertEqual(result['tracker']['failureCount'], 4)
        self.assertGreater(result['tracker']['deallocations'], result['tracker']['releaseCallbacks'])
        self.assertGreater(result['tracker']['deallocatedBytes'], result['tracker']['callbackBytes'])
        self.assertFalse(result['nativeExecutionAttestedByChecker'])
        for optimized in (False, True):
            p = self.cli(optimized)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(json.loads(p.stdout), result)

    def test_pooled_guards_require_the_explicit_policy_and_actual_work(self):
        for policy in ('native', 'native-pooled', 'owned-pooled'):
            self.report.update(requestedStrategy=policy, selectedStrategy=policy,
                rendererAutoreleaseScope=R.R.C.renderer_autorelease_scope(policy))
            if policy in R.R.NATIVE_POLICIES:
                self.report['tracker'] = dict.fromkeys(R.R.COUNTERS, 0)
                self.report['tracker'].update(attemptCount=588, nativeCount=588, seedCount=588,
                    drawCount=108, publishCount=108, failureCount=480, unsupportedCounts={}, callbackSizesMatch=True)
            else:
                self.report['tracker'].update(nativeCount=0, eligibleCount=588,
                    allocations=588, deallocations=588, releaseCallbacks=108,
                    allocatedBytes=37632, deallocatedBytes=37632, callbackBytes=6912, peakActiveBytes=64)
            good = copy.deepcopy(self.report)
            result = self.check(policy)
            self.assertEqual(result['selectedStrategy'], policy)
            self.assertEqual(result['rendererAutoreleaseScope'], R.R.C.renderer_autorelease_scope(policy))
            self.assertEqual((result['caseCount'], result['rejectedOutputAttempts'], result['controllerReleaseCount']), (24, 432, 24))
            for optimized in (False, True):
                completed = self.cli(optimized, policy)
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertEqual(json.loads(completed.stdout), result)
                self.assertNotEqual(self.cli(optimized).returncode, 0)
                self.assertNotEqual(self.cli(optimized, 'forged').returncode, 0)
            for key, value, error in [('selectedStrategy', 'owned-srgb8', 'strategy/default'),
                                       ('requestedStrategy', 'owned-srgb8', 'strategy/default'),
                                       ('rendererAutoreleaseScope', 'forged', 'autorelease scope')]:
                self.report = copy.deepcopy(good); self.report[key] = value
                with self.subTest(policy=policy, key=key), self.assertRaisesRegex(ValueError, error):
                    self.check(policy)
            self.report = copy.deepcopy(good)
            if policy in R.R.NATIVE_POLICIES:
                for field in R.R.COUNTERS:
                    self.report['tracker'][field] = 0
                with self.assertRaisesRegex(ValueError, 'path not exercised'):
                    self.check(policy)
                self.report = copy.deepcopy(good)
                self.report['tracker'].update(attemptCount=2, nativeCount=2, seedCount=2, drawCount=1,
                    publishCount=1, failureCount=1)
                with self.assertRaisesRegex(ValueError, 'native guard failures or successes omitted'):
                    self.check(policy)
            if policy == 'owned-pooled':
                for changes in ({'callbackBytes': good['tracker']['allocatedBytes']},
                                {'releaseCallbacks': good['tracker']['allocations']}):
                    self.report = copy.deepcopy(good); self.report['tracker'].update(changes)
                    with self.subTest(policy=policy, changes=changes), self.assertRaises(ValueError):
                        self.check(policy)
            self.report = copy.deepcopy(good)

    def test_provider_callback_can_precede_failed_image_publication(self):
        self.report['tracker'].update(drawCount=3, releaseCallbacks=3, callbackBytes=192)
        result = self.check()
        self.assertGreater(result['tracker']['releaseCallbacks'], result['tracker']['publishCount'])

    def test_callback_bytes_partition_successful_and_failed_destinations(self):
        self.check()
        good = copy.deepcopy(self.report)
        for changes in ({'callbackBytes': 384}, {'drawCount': 6, 'releaseCallbacks': 6, 'callbackBytes': 128}):
            self.report = copy.deepcopy(good); self.report['tracker'].update(changes)
            with self.subTest(changes=changes), self.assertRaisesRegex(ValueError, 'allocation byte partition differs: releaseCallbacks'):
                self.check()
        self.report = copy.deepcopy(good)
        self.report['tracker'].update(deallocations=5)
        with self.assertRaisesRegex(ValueError, 'allocation byte partition differs: deallocations'):
            self.check()

    def cli(self, optimized, strategy=None):
        return subprocess.run([sys.executable, *(['-O'] if optimized else []), str(SCRIPTS / 'check-renderer-storage-guard.py'),
            str(self.directory), str(self.app), self.source, *(['--strategy', strategy] if strategy is not None else [])], text=True, capture_output=True, timeout=20)

    def test_identity_hashes_and_selection_reach_specific_rejection(self):
        self.check()
        good = copy.deepcopy(self.report)
        mutations = {
            'sourceCommit': ('0' * 40, 'identity differs: sourceCommit'),
            'processIdentifier': (999, 'guard PID changed'),
            'nativeReportSHA256': ('0' * 64, 'native byte binding differs'),
            'drawingReportSHA256': ('0' * 64, 'drawing byte binding differs'),
            'executableSHA256': ('0' * 64, 'executable SHA differs'),
            'executableBytes': (1, 'executable byte count changed'),
            'requestedStrategy': ('native', 'strategy/default differs'),
            'selectedStrategy': ('native', 'strategy/default differs'),
            'drawingStrategy': ('reference', 'strategy/default differs'),
            'rendererAutoreleaseScope': ('whole-render', 'autorelease scope differs'),
            'productionDefaultStrategy': ('owned-srgb8', 'strategy/default differs'),
            'comparisonKind': ('drawing-input', 'observation differs'),
            'diagnosticOnly': (1, 'not raw evidence'),
        }
        for key, (value, expected) in mutations.items():
            self.report = copy.deepcopy(good); self.report[key] = value
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, expected):
                self.check()
        for key in good:
            self.report = copy.deepcopy(good); self.report.pop(key)
            with self.subTest(missing=key), self.assertRaisesRegex(ValueError, 'unexpected object keys'):
                self.check()

    def test_no_residual_owner_and_failed_or_successful_paths_cannot_be_omitted(self):
        self.check()
        good = copy.deepcopy(self.report)
        mutations = [
            ({'activeBytes': 64, 'deallocations': 5, 'deallocatedBytes': 320}, 'owner survived released'),
            ({'attemptCount': 7}, 'attempt not terminal'),
            ({'failureCount': 0}, 'attempt not terminal'),
            ({'callbackSizesMatch': False}, 'callback size mismatch'),
            ({'allocations': 7}, 'owner counts'),
            ({'releaseCallbacks': 0, 'callbackBytes': 0}, 'path not exercised: releaseCallbacks'),
            ({'drawCount': 0}, 'stage counts'),
            ({'nativeCount': 1}, 'stage counts'),
        ]
        for changes, expected in mutations:
            self.report = copy.deepcopy(good); self.report['tracker'].update(changes)
            with self.subTest(changes=changes), self.assertRaisesRegex(ValueError, expected):
                self.check()

    def test_original_native_validator_runs_before_renderer_acceptance(self):
        self.check()
        native = copy.deepcopy(self.fixture.native)
        native['cases'][-1]['sinkDeliveriesDuringFailures'] = 1
        self.fixture.native_path.write_text(json.dumps(native))
        self.fixture.rebind_native(); self.fixture.write()
        self.report.update(nativeReportBytes=self.fixture.sidecar['nativeReportBytes'],
            nativeReportSHA256=self.fixture.sidecar['nativeReportSHA256'],
            drawingReportSHA256=hashlib.sha256(self.fixture.sidecar_path.read_bytes()).hexdigest())
        with self.assertRaisesRegex(ValueError, 'sinkDeliveriesDuringFailures'):
            self.check()

    def test_original_drawing_validator_still_rejects_retained_drawing_owner(self):
        self.check()
        self.fixture.sidecar['tracker']['activeBytes'] = 4
        self.fixture.write()
        self.report['drawingReportSHA256'] = hashlib.sha256(self.fixture.sidecar_path.read_bytes()).hexdigest()
        with self.assertRaisesRegex(ValueError, 'activeBytes'):
            self.check()

    def test_actual_executable_and_drawing_bytes_are_bound(self):
        self.check()
        self.executable.write_bytes(b'X' * self.executable.stat().st_size)
        with self.assertRaisesRegex(ValueError, 'executable SHA differs'):
            self.check()
        self.report['executableSHA256'] = hashlib.sha256(self.executable.read_bytes()).hexdigest()
        self.check()
        with self.fixture.sidecar_path.open('ab') as stream:
            stream.write(b' ')
        with self.assertRaisesRegex(ValueError, 'drawing byte binding differs'):
            self.check()

    def test_caps_strict_json_links_and_optimized_failures(self):
        self.check()
        for payload in (b'{}', b'{"x":NaN}', b'{"x":1e999}', b'{"x":1,"x":2}', b' ' * (16 * 1024 + 1)):
            self.path.write_bytes(payload)
            for optimized in (False, True):
                p = self.cli(optimized)
                self.assertNotEqual(p.returncode, 0)
                self.assertEqual(p.stdout, '')
        self.write()
        target = self.directory / 'sidecar.json'; self.path.rename(target); self.path.symlink_to(target)
        with self.assertRaisesRegex(ValueError, 'linked'):
            R.check_directory(self.directory, self.app, self.source)


if __name__ == '__main__':
    unittest.main()
