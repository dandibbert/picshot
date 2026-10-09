"""Adversarial portable evidence tests; these never claim native acceptance."""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/check-drawing-raster-guard.py'


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


CHECK = module('drawing_guard_check', SCRIPT)
NATIVE_TESTS = module('native_guard_test_data', Path(__file__).with_name('test_check_effect_output_failure_report.py'))
MISSING = object()


class DrawingGuardCheckerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name).resolve(strict=True)
        fixture = NATIVE_TESTS.EffectGuardCheckerTests()
        fixture.setUp()
        native, self.app, self.source, launcher = fixture.write_cli_inputs(self.directory)
        self.native_path = self.directory / 'effect-output-failure.json'
        native.rename(self.native_path)
        self.launcher_path = self.directory / 'launch.json.launcher.json'
        launcher.rename(self.launcher_path)
        self.native = json.loads(self.native_path.read_text())
        self.sidecar_path = self.directory / 'drawing-raster-output-guard.json'
        self.sidecar = dict(schemaVersion=1, status='observed', diagnosticOnly=True,
            observationBoundary='after-effect-output-failure-fixture-return',
            sourceCommit=self.source, version='0.16.0', buildVersion='113', bundlePath=str(self.app),
            executablePath=str(self.app / 'Contents/MacOS/PicShot'), processIdentifier=4321,
            nativeReportPath=str(self.native_path), nativeReportBytes=0, nativeReportSHA256='',
            requestedStrategy='owned-srgb8', selectedStrategy='owned-srgb8', productionDefaultStrategy='reference',
            tracker=dict(referenceCount=0, eligibleCount=5, ownedCount=2, seededContextCount=3,
                presentationReuseCount=4, presentationFallbackCount=0, failureCount=0,
                unsupportedCounts={'colorSpace': 7}, allocations=2, deallocations=2, releaseCallbacks=2,
                allocatedBytes=128, deallocatedBytes=128, callbackBytes=128,
                activeBytes=0, peakActiveBytes=64, seededContextBytes=96, callbackSizesMatch=True))
        self.rebind_native()

    def rebind_native(self):
        data = self.native_path.read_bytes()
        self.sidecar['nativeReportBytes'] = len(data)
        self.sidecar['nativeReportSHA256'] = hashlib.sha256(data).hexdigest()

    def write(self):
        self.sidecar_path.write_text(json.dumps(self.sidecar))

    def check(self):
        self.write()
        return CHECK.check_directory(self.directory, self.app, self.source)

    def reject(self, scope, key, value=MISSING):
        sidecar = copy.deepcopy(self.sidecar)
        target = sidecar if scope == 'root' else sidecar['tracker']
        if value is MISSING:
            target.pop(key)
        else:
            target[key] = value
        self.sidecar_path.write_text(json.dumps(sidecar))
        with self.assertRaises((ValueError, OSError)):
            CHECK.check_directory(self.directory, self.app, self.source)

    def run_cli(self, optimized=False, args=None):
        return subprocess.run([sys.executable, *(['-O'] if optimized else []), str(SCRIPT),
            *map(str, (self.directory, self.app, self.source) if args is None else args)],
            text=True, capture_output=True, timeout=10, check=False)

    def test_complete_contract_preserves_native_matrix_and_unsupported_counts(self):
        result = self.check()
        self.assertEqual((result['caseCount'], result['rejectedOutputAttempts'], result['controllerReleaseCount']),
                         (24, 432, 24))
        self.assertEqual(result['tracker'], self.sidecar['tracker'])
        self.assertEqual(result['tracker']['unsupportedCounts'], {'colorSpace': 7})
        self.assertEqual(result['productionDefaultStrategy'], 'reference')
        for optimized in (False, True):
            with self.subTest(optimized=optimized):
                process = self.run_cli(optimized)
                self.assertEqual(process.returncode, 0, process.stderr)
                self.assertEqual(json.loads(process.stdout), result)

    def test_seeded_only_execution_is_valid_without_inventing_owned_allocations(self):
        self.sidecar['tracker'].update(eligibleCount=3, ownedCount=0, allocations=0, deallocations=0,
            releaseCallbacks=0, allocatedBytes=0, deallocatedBytes=0, callbackBytes=0, peakActiveBytes=0)
        self.check()
        for key in ('allocatedBytes', 'peakActiveBytes'):
            self.reject('tracker', key, 4)

    def test_sidecar_and_tracker_schema_are_closed(self):
        for key in self.sidecar:
            with self.subTest(missing=key):
                self.reject('root', key)
        for key in self.sidecar['tracker']:
            with self.subTest(missing=key):
                self.reject('tracker', key)
        for scope in ('root', 'tracker'):
            self.reject(scope, 'cleanedUp', True)
        for value in (None, [], True, 5, 'passed'):
            self.reject('root', 'tracker', value)

    def test_all_scalar_counters_have_strict_nonnegative_integer_types(self):
        counters = [key for key in self.sidecar['tracker'] if key not in ('unsupportedCounts', 'callbackSizesMatch')]
        for key in counters:
            for value in (None, True, False, '0', 0.0, -1, 1 << 63):
                with self.subTest(key=key, value=value):
                    self.reject('tracker', key, value)

    def test_native_identity_fields_are_bound(self):
        mutations = {
            'sourceCommit': 'b' * 40, 'version': '99', 'buildVersion': '120',
            'bundlePath': '/other/PicShot.app', 'executablePath': str(self.app / 'Contents/MacOS/Other'),
            'processIdentifier': 4322, 'nativeReportPath': str(self.directory / 'other.json'),
            'nativeReportBytes': self.sidecar['nativeReportBytes'] + 1, 'nativeReportSHA256': 'b' * 64,
        }
        for key, value in mutations.items():
            for invalid in (value, None, True, [], 0):
                with self.subTest(key=key, value=invalid):
                    self.reject('root', key, invalid)
        for key in ('processIdentifier', 'nativeReportBytes', 'schemaVersion'):
            self.reject('root', key, float(self.sidecar[key]))
        for key in ('bundlePath', 'executablePath', 'nativeReportPath'):
            self.reject('root', key, 'relative/' + Path(self.sidecar[key]).name)

    def test_exact_native_report_bytes_are_bound_even_for_semantically_identical_json(self):
        self.write()
        self.native_path.write_bytes(self.native_path.read_bytes() + b' ')
        with self.assertRaises(ValueError):
            CHECK.check_directory(self.directory, self.app, self.source)
        self.rebind_native()
        self.check()

    def test_native_validator_rejects_forged_pass_even_when_sidecar_is_rebound(self):
        mutations = [
            ('status', 'failed'), ('caseCount', 8), ('controllerReleaseCount', 23),
            ('projectionJobsStarted', 13), ('generalPasteboardReadOrWritten', True),
            ('temporaryDirectoryRemoved', False), ('sourceCommit', 'b' * 40),
            ('processIdentifier', 4322), ('executablePath', '/other/PicShot'),
        ]
        original = self.native_path.read_bytes()
        for key, value in mutations:
            native = copy.deepcopy(self.native)
            native[key] = value
            self.native_path.write_text(json.dumps(native))
            self.rebind_native()
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.check()
        for key, value in [('failedRenderRequests', 17), ('retryPreservesEditableDocument', False),
                           ('projectionJobsStartedDuringFailures', 1), ('sourcePixelsUnchanged', False)]:
            native = copy.deepcopy(self.native)
            native['cases'][-1][key] = value
            self.native_path.write_text(json.dumps(native))
            self.rebind_native()
            with self.subTest(case_key=key), self.assertRaises(ValueError):
                self.check()
        self.native_path.write_bytes(original)
        self.rebind_native()

    def test_owned_launcher_exit_and_pid_are_still_required(self):
        original = self.launcher_path.read_bytes()
        launcher = json.loads(original)
        for key, value in [('ownedExitConfirmed', False), ('processIdentifier', 777),
                           ('status', 'timed-out'), ('callbackReceived', False), ('launcherExitCode', 1)]:
            self.launcher_path.write_text(json.dumps(dict(launcher, **{key: value})))
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.check()
        self.launcher_path.write_bytes(original)

    def test_actual_and_requested_candidate_and_immutable_reference_are_required(self):
        for key in ('requestedStrategy', 'selectedStrategy'):
            for value in ('reference', 'ownedSRGB8', '', None, True, 1):
                with self.subTest(key=key, value=value):
                    self.reject('root', key, value)
        for value in ('owned-srgb8', '', None, True):
            self.reject('root', 'productionDefaultStrategy', value)
        for key, value in [('status', 'passed'), ('diagnosticOnly', 1), ('diagnosticOnly', False),
                           ('observationBoundary', 'before-fixture'), ('schemaVersion', True)]:
            self.reject('root', key, value)

    def test_candidate_requires_seeded_work_without_reference_fallback_or_failure(self):
        for key in ('referenceCount', 'presentationFallbackCount', 'failureCount', 'activeBytes'):
            with self.subTest(key=key):
                self.reject('tracker', key, 1)
        self.reject('tracker', 'seededContextCount', 0)
        self.reject('tracker', 'eligibleCount', 0)
        self.reject('tracker', 'eligibleCount', 6)
        self.reject('tracker', 'ownedCount', 3)
        # All counters can balance while no context was actually seeded.
        self.sidecar['tracker'].update(eligibleCount=2, seededContextCount=0, seededContextBytes=0)
        with self.assertRaises(ValueError):
            self.check()

    def test_retained_owners_and_callback_mismatches_cannot_be_hidden(self):
        for key in ('allocations', 'deallocations', 'releaseCallbacks'):
            for value in (0, 1, 3):
                with self.subTest(key=key, value=value):
                    self.reject('tracker', key, value)
        for key in ('allocatedBytes', 'deallocatedBytes', 'callbackBytes'):
            for value in (0, 64, 132):
                with self.subTest(key=key, value=value):
                    self.reject('tracker', key, value)
        for value in (False, 1, 'true', None):
            self.reject('tracker', 'callbackSizesMatch', value)
        self.sidecar['tracker'].update(deallocations=1, deallocatedBytes=64, releaseCallbacks=1,
                                      callbackBytes=64, activeBytes=64)
        with self.assertRaises(ValueError):
            self.check()

    def test_byte_totals_and_peaks_must_cover_actual_work(self):
        for value in (0, 4, 60, 132, 800_000_004):
            self.reject('tracker', 'peakActiveBytes', value)
        for value in (0, 8, 13, 97, 1_200_000_004):
            self.reject('tracker', 'seededContextBytes', value)
        self.sidecar['tracker'].update(allocatedBytes=4, deallocatedBytes=4, callbackBytes=4, peakActiveBytes=4)
        with self.assertRaises(ValueError):
            self.check()

    def test_unsupported_counts_are_explicit_positive_typed_and_not_candidate_work(self):
        for value in ({}, {'componentDepth': 2, 'colorSpace': 10}, {'imageMask': 1, 'decodeArray': 1,
                'floatingPoint': 1, 'channelLayout': 1, 'byteOrder': 1, 'bitmapFlags': 1}):
            self.sidecar['tracker']['unsupportedCounts'] = value
            self.check()
        for value in (None, [], 5, {'unknown': 1}, {'colorSpace': 0}, {'colorSpace': -1},
                      {'colorSpace': True}, {'colorSpace': 1.0}, {'colorSpace': '1'},
                      {'colorSpace': 1 << 63}, {'colorSpace': (1 << 63) - 1}):
            self.reject('tracker', 'unsupportedCounts', value)
        self.sidecar['tracker'].update(eligibleCount=0, ownedCount=0, seededContextCount=0,
            allocations=0, deallocations=0, releaseCallbacks=0, allocatedBytes=0,
            deallocatedBytes=0, callbackBytes=0, peakActiveBytes=0, seededContextBytes=0,
            unsupportedCounts={'colorSpace': 500})
        with self.assertRaises(ValueError):
            self.check()

    def test_json_parser_rejects_duplicate_keys_nonfinite_and_nonobjects(self):
        for payload in (b'{"status":"observed","status":"observed"}',
                        b'{"tracker":{"eligibleCount":1,"eligibleCount":5}}',
                        b'{"x":NaN}', b'{"x":Infinity}', b'{"x":-Infinity}',
                        b'{"x":1e999}', b'{"x":-1e999}', b'{"x":[1e999]}',
                        b'', b'{', b'{}{}', b'[]', b'null', b'false', b'4', b'"observed"', b'\xff'):
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                CHECK.parse_json(payload)

    def test_all_inputs_are_capped_regular_nonlinked_files(self):
        self.write()
        for path, maximum in [(self.native_path, 128 * 1024), (self.sidecar_path, 16 * 1024),
                              (self.launcher_path, 16 * 1024), (self.app / 'Contents/Info.plist', 64 * 1024)]:
            original = path.read_bytes()
            for payload in (b'', b' ' * (maximum + 1)):
                path.write_bytes(payload)
                with self.subTest(path=path.name, size=len(payload)), self.assertRaises(ValueError):
                    CHECK.check_directory(self.directory, self.app, self.source)
            path.write_bytes(original)
            alias = self.directory / 'linked-input'
            for kind in ('symlink', 'hardlink'):
                if kind == 'symlink':
                    alias.symlink_to(path)
                    with self.assertRaises(ValueError):
                        CHECK.read_bytes(alias, maximum)
                else:
                    os.link(path, alias)
                    with self.assertRaises(ValueError):
                        CHECK.check_directory(self.directory, self.app, self.source)
                alias.unlink()
        fifo = self.directory / 'fifo'
        os.mkfifo(fifo)
        with self.assertRaises(ValueError):
            CHECK.read_bytes(fifo, 16 * 1024)
        with self.assertRaises(ValueError):
            CHECK.read_bytes(self.directory, 16 * 1024)

    def test_strict_json_loading_applies_to_native_launcher_and_sidecar(self):
        self.write()
        for path in (self.native_path, self.sidecar_path, self.launcher_path):
            original = path.read_bytes()
            for suffix in (b',"extra":1e999}', b',"extra":NaN}', b',"duplicate":1,"duplicate":2}'):
                path.write_bytes(original.rstrip()[:-1] + suffix)
                with self.subTest(path=path.name, suffix=suffix), self.assertRaises(ValueError):
                    CHECK.check_directory(self.directory, self.app, self.source)
            path.write_bytes(original)

    def test_reader_accepts_exact_cap_and_rejects_one_extra_byte(self):
        path = self.directory / 'bounded'
        for maximum in (16 * 1024, 64 * 1024, 128 * 1024):
            data = b'{}' + b' ' * (maximum - 2)
            path.write_bytes(data)
            self.assertEqual(CHECK.read_bytes(path, maximum), data)
            path.write_bytes(data + b' ')
            with self.assertRaises(ValueError):
                CHECK.read_bytes(path, maximum)

    def test_cli_fail_closed_in_normal_and_optimized_python(self):
        self.write()
        valid = self.sidecar_path.read_bytes()
        bad = copy.deepcopy(self.sidecar)
        bad['tracker']['activeBytes'] = 4
        for payload in (json.dumps(bad).encode(), b'{"x":NaN}', b'{}',
                        b'{"status":"observed","status":"observed"}', b' ' * (16 * 1024 + 1)):
            self.sidecar_path.write_bytes(payload)
            for optimized in (False, True):
                result = self.run_cli(optimized)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
        self.sidecar_path.write_bytes(valid)
        for optimized in (False, True):
            result = self.run_cli(optimized, args=[])
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('EVIDENCE_DIRECTORY APP SOURCE', result.stderr)


class DrawingGuardSourceContractTests(unittest.TestCase):
    def test_existing_fixture_validator_and_smoke_runner_are_byte_identical(self):
        expected = {
            'Sources/PicShot/EffectOutputFailureNativeFixture.swift': '24ce9bf612aef873351f4abc3702dd4f78f9f61b12d67b83b5e6caf33b076cb7',
            'scripts/check-effect-output-failure-report.py': '7fe28f27f4ea208d19b12d74d4f754f9f739c25a42279887092f864547430ba3',
            'scripts/effect-output-failure-smoke.sh': 'e225338ba906ff2cf0abb05511153d09f65aa2cd512a8795fb51350baaf4dcc4',
        }
        for name, digest in expected.items():
            with self.subTest(path=name):
                self.assertEqual(hashlib.sha256((ROOT / name).read_bytes()).hexdigest(), digest)

    def test_launcher_forwards_strategy_exactly_once_without_changing_deadlines(self):
        source = (ROOT / 'scripts/launch-smoke-app.swift').read_text()
        self.assertEqual(source.count('"PICSHOT_DRAWING_RASTER_STRATEGY"'), 1)
        whitelist = source.split('for key in [', 1)[1].split('] {', 1)[0]
        self.assertIn('"PICSHOT_DRAWING_RASTER_STRATEGY"', whitelist)
        self.assertIn('if let value = ProcessInfo.processInfo.environment[key] { configuration.environment[key] = value }', source)
        self.assertIn('let timeout: TimeInterval = ["export-only", "decode-only"].contains(diagnosticMode) ? 900 : 600', source)
        self.assertEqual(source.count('Date().addingTimeInterval(3)'), 2)

    def test_hook_observes_after_verified_fixture_and_before_normal_report_write(self):
        source = (ROOT / 'Sources/PicShot/SmokeVerification.swift').read_text()
        effect_hook = '                try EffectContextOutputGuardEvidence.writeIfRequested(evidenceDirectory: directory)\n'
        self.assertEqual(source.count(effect_hook), 1)
        # Remove only the declared later diagnostic hook, then preserve the
        # complete original fixture/drawing-evidence/report-write sequence.
        source = source.replace(effect_hook, '', 1)
        route = source.split('if ProcessInfo.processInfo.environment["PICSHOT_EFFECT_OUTPUT_FAILURE_ONLY"] == "1" {', 1)[1]
        route = route.split('NSApp.terminate(nil); return', 1)[0]
        self.assertIn('var payload = try await EffectOutputFailureNativeFixture.verify(evidenceDirectory: directory)\n'
                      '                try DrawingRasterOutputGuardEvidence.writeIfRequested(evidenceDirectory: directory)\n'
                      '                payload["arguments"] = CommandLine.arguments', route)
        self.assertEqual(source.count('DrawingRasterOutputGuardEvidence.writeIfRequested'), 1)

    def test_native_sidecar_uses_process_configuration_and_raw_snapshot_without_cleanup_claim(self):
        source = (ROOT / 'Sources/PicShot/DrawingRasterOutputGuardEvidence.swift').read_text()
        for fragment in ('guard let requested = ProcessInfo.processInfo.environment["PICSHOT_DRAWING_RASTER_STRATEGY"] else { return }',
                         'let configuration = DrawingRasterConfiguration.process',
                         'let selected = try configuration.selectedStrategy()',
                         'let snapshot = configuration.tracker.snapshot()',
                         'DrawingRasterStrategy.productionDefault.rawValue',
                         'JSONEncoder().encode(snapshot)', 'SHA256.hash(data: nativeBytes)',
                         '"selectedStrategy": selected.rawValue', '"status": "observed"',
                         'ProcessInfo.processInfo.processIdentifier', 'Bundle.main.executableURL',
                         'EffectOutputFailureNativeFixture.filename'):
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, source)
        for forbidden in ('Task.sleep', 'deadline', 'RunLoop', '.clear(', '"status": "passed"',
                          'NSPasteboard', 'CGRequestScreenCaptureAccess', 'precondition('):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, source)
        self.assertNotRegex(source, r'(?m)^\s*while\s')


if __name__ == '__main__':
    unittest.main()
