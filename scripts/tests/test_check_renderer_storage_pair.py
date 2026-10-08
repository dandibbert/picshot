"""Portable contract tests only. Synthetic processes/images are not macOS evidence."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


R = load('renderer_pair_test_check', SCRIPTS / 'check-renderer-storage-pair.py')
F = load('renderer_pair_test_fixture', SCRIPTS / 'tests/test_check_editable_drawing_pair.py')


def state(strategy, work=0):
    result = dict.fromkeys(R.COUNTERS, 0)
    result.update(unsupportedCounts={}, callbackSizesMatch=True)
    for key in ('attemptCount', 'seedCount', 'drawCount', 'publishCount'):
        result[key] = work
    if strategy in R.NATIVE_POLICIES:
        result['nativeCount'] = work
    else:
        for key in ('eligibleCount', 'allocations', 'deallocations', 'releaseCallbacks'):
            result[key] = work
        for key in ('allocatedBytes', 'deallocatedBytes', 'callbackBytes'):
            result[key] = 4096 * work
        result['peakActiveBytes'] = 4096 if work else 0
    return result


def materialize(root, identity, strategy='native', resources=False, index=0, comparison_kind=R.KIND, explicit_kind=False):
    root = Path(root).resolve(strict=True)
    directory, arm = F.materialize(root, identity, 'owned-srgb8', resources, index)
    arm['launcher'].update(rendererStorageStrategy=strategy, comparisonKind=comparison_kind,
                           rendererAutoreleaseScope=R.C.renderer_autorelease_scope(strategy))
    arm['wrapper']['command'][1] = 'scripts/launch-renderer-storage-pair.swift'
    arm['wrapper']['command'][-2] = strategy
    if comparison_kind != R.KIND or explicit_kind:
        arm['wrapper']['command'].append(comparison_kind)
    F.save(directory, arm)
    report = {key: arm['native'][key] for key in (*R.C.IDENTITY, 'executableBytes')}
    report.update(schemaVersion=1, status='passed', comparisonKind=comparison_kind, rendererStorageStrategy=strategy,
        rendererAutoreleaseScope=R.C.renderer_autorelease_scope(strategy),
        drawingStrategy='owned-srgb8', productionDefaultStrategy='native',
        hashObservation='vimage' if resources else 'certify', maximumCheckpoints=256,
        additionalRasterObservations=0, observationBoundary='after-existing-drawing-checkpoint',
        productDefaultsChanged=False, privateFrameworkReleaseClaim=False,
        scope='Synthetic scalar evidence only', checkpoints=[])
    work = 0
    for point in arm['drawing']['checkpoints']:
        if point['label'] == 'workload-released':
            work += 1
        report['checkpoints'].append(dict(workload=point['workload'], label=point['label'], rendererStorage=state(strategy, work)))
    bind(directory, report)
    return directory, arm, report


def bind(directory, report):
    for field, filename in [('nativeReportSHA256', 'editable-annotation-native.json'), ('drawingReportSHA256', 'editable-drawing-pair.json')]:
        report[field] = hashlib.sha256((directory / filename).read_bytes()).hexdigest()
    save(directory, report)


def save(directory, report):
    (directory / R.FILENAME).write_text(json.dumps(report, sort_keys=True))


class RendererStoragePairTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve(strict=True)
        self.identity = F.identity_at(self.root)

    def test_four_complete_processes_and_original_comparison_coexist(self):
        values = {}
        for index, (name, strategy, mode) in enumerate(R.CELLS):
            directory, _, _ = materialize(self.root, self.identity, strategy, mode == 'resources', index)
            values[name] = R.load_cell(directory, self.identity, strategy, mode)
        result = R.compare(values, 'pair')
        self.assertEqual(result['comparisonKind'], 'renderer-final-storage')
        self.assertEqual(result['certificationWorkPerArm']['hashes'], 35)
        self.assertEqual(result['measuredWorkPerArm']['hashes'], 205)
        self.assertEqual(len({v['native']['processIdentifier'] for v in values.values()}), 4)
        self.assertEqual(sum(len(v['native']['functionalCases'][0]['visualEvidence']) for v in values.values()), 16)
        for name in ('baseline', 'candidate'):
            self.assertEqual(len(result['arms'][name]['rendererStorageCheckpoints']), 142)
            self.assertEqual(len(values[name]['documents']), 12)
            self.assertEqual(result['arms'][name]['ownedDrawingFinal']['ownedCount'], 12)
        self.assertEqual(result['arms']['baseline']['rendererStorageFinal']['allocations'], 0)
        self.assertEqual(result['arms']['candidate']['rendererStorageFinal']['allocations'], 12)
        self.assertFalse(result['memoryStabilityAssessed'])
        self.assertFalse(result['nativeExecutionAttestedByChecker'])
        for optimized in (False, True):
            output = self.root / ('checked-opt.json' if optimized else 'checked.json')
            p = subprocess.run([sys.executable, *(['-O'] if optimized else []), str(SCRIPTS / 'check-renderer-storage-pair.py'),
                '--app', self.identity['bundlePath'], '--expected-source', self.identity['sourceCommit'], '--root', str(self.root),
                '--stage', 'pair', '--output', str(output)], capture_output=True, text=True, timeout=20)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            self.assertEqual(json.loads(output.read_text())['status'], 'compared')
        self.assertEqual(F.C.compare(F.arms(), 'pair')['status'], 'compared')
        self.assertEqual(R.C.STRATEGIES, ('reference', 'owned-srgb8'))
        self.assertEqual(R.C.CELLS[0], ('baseline-certification', 'reference', 'certify'))

    def test_every_finite_comparison_has_four_complete_independent_processes(self):
        for kind in R.COMPARISON_KINDS:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as root:
                identity = F.identity_at(Path(root))
                strategies, cells, _ = R.comparison_contract(kind)
                self.assertEqual(len(strategies), 2)
                self.assertEqual(len(cells), 4)
                arms = {}
                for index, (name, strategy, mode) in enumerate(cells):
                    directory, _, _ = materialize(root, identity, strategy, mode == 'resources', index, kind, explicit_kind=True)
                    arms[name] = R.load_cell(directory, identity, strategy, mode, comparison_kind=kind)
                certificate = R.compare({name: arms[name] for name, _, _ in cells[:2]}, 'certification', kind)
                result = R.compare(arms, 'pair', kind)
                self.assertEqual(certificate['certificationWorkPerArm']['hashes'], 35)
                self.assertEqual(result['measuredWorkPerArm'], dict(functionalWorkloads=2, warmupWorkloads=2,
                    measuredWorkloads=8, hashes=205, conversions=205, snapshots=4))
                self.assertEqual(len({arm['native']['processIdentifier'] for arm in arms.values()}), 4)
                self.assertEqual(sum(len(arm['native']['functionalCases'][0]['visualEvidence']) for arm in arms.values()), 16)
                self.assertEqual(result['comparisonKind'], kind)
                self.assertEqual(result['matchedAutoreleaseScope'], kind == 'renderer-final-storage-scoped')
                for name, strategy, mode in cells:
                    self.assertEqual(result['cells'][name]['rendererStorageStrategy'], strategy)
                    self.assertEqual(result['cells'][name]['rendererAutoreleaseScope'], R.C.renderer_autorelease_scope(strategy))
                    self.assertEqual(result['cells'][name]['comparisonKind'], kind)
                    self.assertEqual(len(arms[name]['documents']), 12 if mode == 'resources' else 2)
                for optimized in (False, True):
                    output = Path(root) / 'checked.json'
                    command = [sys.executable, *(['-O'] if optimized else []), str(SCRIPTS / 'check-renderer-storage-pair.py'),
                        '--app', identity['bundlePath'], '--expected-source', identity['sourceCommit'], '--root', root,
                        '--comparison-kind', kind, '--stage', 'pair', '--output', str(output)]
                    completed = subprocess.run(command, capture_output=True, text=True, timeout=20)
                    self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
                    self.assertEqual(json.loads(output.read_text())['comparisonKind'], kind)
                # No kind accepts extra cells, pooled arms substituted into the
                # legacy kind, a six-cell matrix or a forged report label.
                for bad in ({**arms, 'extra': arms['baseline']}, {**arms, 'other-certification': arms['baseline'], 'other': arms['candidate']}):
                    with self.assertRaisesRegex(ValueError, 'required fresh cells'):
                        R.compare(bad, 'pair', kind)
                corrupted = copy.deepcopy(arms)
                corrupted['candidate']['rendererStorage']['comparisonKind'] = 'forged'
                with self.assertRaisesRegex(ValueError, 'renderer arm selection'):
                    R.compare(corrupted, 'pair', kind)
                corrupted = copy.deepcopy(arms)
                corrupted['candidate']['rendererStorage']['rendererAutoreleaseScope'] = 'forged'
                with self.assertRaisesRegex(ValueError, 'autorelease scope'):
                    R.compare(corrupted, 'pair', kind)

    def test_pooled_launcher_policy_kind_scope_and_lifecycle_fail_closed(self):
        kind = 'renderer-final-storage-scoped'
        directory, arm, report = materialize(self.root, self.identity, 'native-pooled', comparison_kind=kind)
        original_arm = copy.deepcopy(arm)
        for target, key, value, error in [
            ('launcher', 'comparisonKind', R.KIND, 'launcher renderer storage selection'),
            ('launcher', 'rendererStorageStrategy', 'owned-pooled', 'launcher renderer storage selection'),
            ('launcher', 'rendererAutoreleaseScope', 'draw-only', 'launcher renderer autorelease scope'),
            ('launcher', 'ownedExitConfirmed', False, 'fresh owned application exit'),
            ('launcher', 'processIdentifier', 999, 'report process does not match the owned installed launch'),
            ('launcher', 'timeoutSeconds', 601, 'owned timeout'),
            ('wrapper', 'timeout_seconds', 621, 'wrapper deadline'),
            ('wrapper', 'command', original_arm['wrapper']['command'][:-1], 'bounded command selection'),
        ]:
            arm = copy.deepcopy(original_arm); arm[target][key] = value; F.save(directory, arm); bind(directory, report)
            with self.subTest(target=target, key=key), self.assertRaisesRegex(ValueError, error):
                R.load_cell(directory, self.identity, 'native-pooled', 'certify', comparison_kind=kind)
        F.save(directory, original_arm); bind(directory, report)
        for requested_kind, strategy in [(R.KIND, 'native-pooled'), ('renderer-autorelease-scope', 'owned-pooled'),
                                         ('drawing-input', 'native-pooled'), ('forged', 'native-pooled')]:
            with self.subTest(kind=requested_kind, strategy=strategy), self.assertRaises(ValueError):
                R.load_cell(directory, self.identity, strategy, 'certify', comparison_kind=requested_kind)
        for key, value in [('rendererAutoreleaseScope', 'caller'), ('rendererStorageStrategy', 'owned-pooled'),
                           ('comparisonKind', 'renderer-autorelease-scope')]:
            bad = copy.deepcopy(report); bad[key] = value; save(directory, bad)
            with self.subTest(key=key), self.assertRaises(ValueError):
                R.load_cell(directory, self.identity, 'native-pooled', 'certify', comparison_kind=kind)

    def test_new_policies_preserve_native_and_owned_scalar_partition_rules(self):
        for policy in R.POLICIES:
            value = state(policy, 4)
            R.snapshot(value, policy, released=True)
            if policy in R.NATIVE_POLICIES:
                value.update(eligibleCount=1, allocations=1, deallocations=1, releaseCallbacks=1,
                    allocatedBytes=4096, deallocatedBytes=4096, callbackBytes=4096, peakActiveBytes=4096,
                    attemptCount=5, seedCount=5, drawCount=5, publishCount=5)
                with self.assertRaisesRegex(ValueError, 'native renderer performed owned'):
                    R.snapshot(value, policy, released=True)
            else:
                value.update(releaseCallbacks=3)
                with self.assertRaisesRegex(ValueError, 'allocation byte partition'):
                    R.snapshot(value, policy, released=True)
        with self.assertRaisesRegex(ValueError, 'unknown renderer strategy'):
            R.snapshot(state('native'), 'forged')

    def test_closed_explicit_kind_does_not_accept_arbitrary_contracts(self):
        for kind in ('', 'renderer', None, True, 'drawing-input-extra'):
            with self.subTest(kind=kind), self.assertRaisesRegex(ValueError, 'unknown comparison kind'):
                R.C.comparison_contract(kind)
        with self.assertRaisesRegex(ValueError, 'unknown comparison strategy'):
            R.C.drawing_strategy('reference', R.KIND)
        with self.assertRaisesRegex(ValueError, 'unknown comparison strategy'):
            R.C.drawing_strategy('native', 'drawing-input')

    def test_scalar_identity_bindings_and_schema_reject_at_intended_check(self):
        directory, _, good = materialize(self.root, self.identity)
        self.assertEqual(R.load_cell(directory, self.identity, 'native', 'certify')['rendererStorage'], good)
        mutations = {
            'nativeReportSHA256': ('0' * 64, 'different bytes: nativeReportSHA256'),
            'drawingReportSHA256': ('0' * 64, 'different bytes: drawingReportSHA256'),
            'sourceCommit': ('0' * 40, 'identity differs: sourceCommit'),
            'executableSHA256': ('0' * 64, 'identity differs: executableSHA256'),
            'executableBytes': (True, 'identity differs: executableBytes'),
            'processIdentifier': (999, 'identity differs: processIdentifier'),
            'architecture': ('x86_64', 'identity differs: architecture'),
            'resourcesRequested': (True, 'identity differs: resourcesRequested'),
            'rendererStorageStrategy': ('owned-srgb8', 'strategy/default differs'),
            'drawingStrategy': ('reference', 'strategy/default differs'),
            'rendererAutoreleaseScope': ('whole-render', 'autorelease scope differs'),
            'productionDefaultStrategy': ('owned-srgb8', 'strategy/default differs'),
            'comparisonKind': ('drawing-input', 'status/kind differs'),
            'hashObservation': ('cgcontext', 'observer differs'),
            'maximumCheckpoints': (257, 'checkpoint cap changed'),
            'additionalRasterObservations': (1, 'extra observation changed'),
            'observationBoundary': ('new-sample', 'observation boundary differs'),
            'productDefaultsChanged': (True, 'unsupported claim'),
            'privateFrameworkReleaseClaim': (True, 'unsupported claim'),
        }
        for field, (value, expected) in mutations.items():
            report = copy.deepcopy(good); report[field] = value; save(directory, report)
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, expected):
                R.load_cell(directory, self.identity, 'native', 'certify')
        for key in good:
            report = copy.deepcopy(good); report.pop(key); save(directory, report)
            with self.subTest(missing=key), self.assertRaisesRegex(ValueError, 'unexpected object keys'):
                R.load_cell(directory, self.identity, 'native', 'certify')

    def test_every_workload_requires_bounded_ordered_exercised_snapshots(self):
        directory, _, good = materialize(self.root, self.identity, 'owned-srgb8', True, 2)
        R.load_cell(directory, self.identity, 'owned-srgb8', 'resources')
        cases = [
            ('missing', lambda r: r['checkpoints'].pop(), 'checkpoint work differs'),
            ('reorder', lambda r: r['checkpoints'].reverse(), 'checkpoints missing/reordered'),
            ('counter-backward', lambda r: r['checkpoints'][-1].update(rendererStorage=state('owned-srgb8', 1)), 'count moved backward'),
            ('no-work', lambda r: [p.update(rendererStorage=state('owned-srgb8')) for p in r['checkpoints']], 'path not exercised'),
            ('retained', lambda r: next(p for p in r['checkpoints'] if p['label'] == 'workload-released')['rendererStorage'].update(
                deallocations=0, deallocatedBytes=0, activeBytes=4096), 'owner survived'),
            ('failed', lambda r: r['checkpoints'][-1]['rendererStorage'].update(attemptCount=13, failureCount=1), 'failed during complete workload'),
        ]
        for label, mutate, expected in cases:
            report = copy.deepcopy(good); mutate(report); save(directory, report)
            with self.subTest(change=label), self.assertRaisesRegex(ValueError, expected):
                R.load_cell(directory, self.identity, 'owned-srgb8', 'resources')

    def test_scalar_types_accounting_stages_and_fallbacks_are_strict(self):
        good = state('owned-srgb8', 2)
        R.snapshot(good, 'owned-srgb8', released=True)
        for key in R.COUNTERS:
            for value in (-1, True, False, None, '2', 2.0, 1 << 63):
                bad = copy.deepcopy(good); bad[key] = value
                with self.subTest(key=key, value=value), self.assertRaisesRegex(ValueError, 'invalid bounded integer'):
                    R.snapshot(bad, 'owned-srgb8')
        mutations = [
            ('drawCount', 1, 'stage counts'), ('attemptCount', 1, 'stage counts'),
            ('allocations', 3, 'owner counts'), ('callbackSizesMatch', False, 'callback size'),
            ('activeBytes', 4, 'byte accounting'), ('peakActiveBytes', 0, 'peak omits'),
            ('allocatedBytes', 8193, 'byte accounting'), ('nativeCount', 1, 'stage counts'),
            ('unsupportedCounts', {'unknown': 1}, 'unknown renderer unsupported'),
        ]
        for key, value, error in mutations:
            bad = copy.deepcopy(good); bad[key] = value
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, error):
                R.snapshot(bad, 'owned-srgb8', released=True)
        mixed = copy.deepcopy(good)
        for key in ('attemptCount', 'seedCount', 'drawCount', 'publishCount'):
            mixed[key] += 1
        mixed.update(nativeCount=1, unsupportedCounts={'colorSpace': 1})
        R.snapshot(mixed, 'owned-srgb8', released=True)
        mixed['unsupportedCounts'] = {}
        with self.assertRaisesRegex(ValueError, 'silently used native fallback'):
            R.snapshot(mixed, 'owned-srgb8', released=True)
        with self.assertRaisesRegex(ValueError, 'native renderer performed owned'):
            R.snapshot(good, 'native')

    def test_actual_sidecar_bytes_caps_links_and_optimized_failure(self):
        directory, _, report = materialize(self.root, self.identity)
        path = directory / R.FILENAME
        R.load_cell(directory, self.identity, 'native', 'certify')
        for payload, expected in [(b' ' * (R.MAX_BYTES + 1), 'scalar sidecar exceeds bound'),
                                  (b'{}', 'unexpected object keys'),
                                  (b'{"x":NaN}', 'nonfinite'), (b'{"x":1,"x":2}', 'duplicate')]:
            path.write_bytes(payload)
            with self.subTest(expected=expected), self.assertRaisesRegex(ValueError, expected):
                R.load_cell(directory, self.identity, 'native', 'certify')
        save(directory, report)
        target = directory / 'linked.json'; path.rename(target); path.symlink_to(target)
        with self.assertRaises(ValueError):
            R.load_cell(directory, self.identity, 'native', 'certify')
        path.unlink(); target.rename(path)
        report['additionalRasterObservations'] = 1; save(directory, report)
        for optimized in (False, True):
            output = self.root / 'failed.json'
            p = subprocess.run([sys.executable, *(['-O'] if optimized else []), str(SCRIPTS / 'check-renderer-storage-pair.py'),
                '--app', self.identity['bundlePath'], '--expected-source', self.identity['sourceCommit'],
                '--cell', str(directory), '--strategy', 'native', '--mode', 'certify', '--output', str(output)],
                text=True, capture_output=True, timeout=20)
            self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
            self.assertIn('extra observation changed', json.loads(output.read_text())['error'])


if __name__ == '__main__':
    unittest.main()
