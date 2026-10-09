"""Portable acceptance-contract mutations; synthetic fixtures are never native evidence."""
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

SCRIPTS = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


E = module('test_effect_checker', SCRIPTS / 'check-effect-context-pair.py')
F = module('test_effect_drawing_fixture', SCRIPTS / 'tests/test_check_editable_drawing_pair.py')
RF = module('test_effect_renderer_fixture', SCRIPTS / 'tests/test_check_renderer_storage_pair.py')


def state(policy, work=0):
    result = dict(contextCount=1, contextOptionCount=2 if policy == 'memory32' else 1,
        configuredCacheIntermediates=False, attemptCount=work, publishCount=work, failureCount=0)
    if policy == 'memory32':
        result['configuredMemoryTargetMegabytes'] = 32
    return result


def materialize(root, identity, policy='reference', resources=False, index=0):
    root = Path(root).resolve(strict=True)
    directory, arm = F.materialize(root, identity, 'owned-srgb8', resources, index)
    arm['launcher'].update(effectContextPolicy=policy, comparisonKind=E.KIND,
        rendererStorageStrategy='native', rendererAutoreleaseScope='caller')
    arm['wrapper']['command'][1] = 'scripts/launch-effect-context-pair.swift'
    arm['wrapper']['command'][-2] = policy
    arm['wrapper']['command'].append(E.KIND)
    F.save(directory, arm)
    report = {key: arm['native'][key] for key in (*E.C.IDENTITY, 'executableBytes')}
    report.update(schemaVersion=1, status='passed', comparisonKind=E.KIND, effectContextPolicy=policy,
        productionDefaultPolicy='reference', rendererStorageStrategy='native', rendererAutoreleaseScope='caller',
        rendererProductionDefaultStrategy='native', drawingStrategy='owned-srgb8',
        hashObservation='vimage' if resources else 'certify', maximumCheckpoints=256,
        additionalRasterObservations=0, additionalMemoryObservations=0,
        observationBoundary='after-existing-drawing-checkpoint', contextOwnershipScope='one-immutable-process-context',
        contextInitializationBoundary='after-first-drawing-memory-before-native-entry',
        productDefaultsChanged=False, privateFrameworkReleaseClaim=False, scope='Synthetic scalar fixture', checkpoints=[])
    work = 0
    for point in arm['drawing']['checkpoints']:
        if point['label'] == 'workload-released':
            work += 1
        report['checkpoints'].append(dict(workload=point['workload'], label=point['label'],
            effectContext=state(policy, work), rendererStorage=RF.state('native', work)))
    bind(directory, report)
    return directory, arm, report


def bind(directory, report):
    for field, filename in [('nativeReportSHA256', 'editable-annotation-native.json'), ('drawingReportSHA256', 'editable-drawing-pair.json')]:
        report[field] = hashlib.sha256((directory / filename).read_bytes()).hexdigest()
    save(directory, report)


def save(directory, report):
    (directory / E.FILENAME).write_text(json.dumps(report, sort_keys=True))


class EffectContextPairTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve(strict=True)
        self.identity = F.identity_at(self.root)

    def cli(self, *arguments, optimized=False):
        return subprocess.run([sys.executable, *(['-O'] if optimized else []), str(SCRIPTS / 'check-effect-context-pair.py'),
            '--app', self.identity['bundlePath'], '--expected-source', self.identity['sourceCommit'], *map(str, arguments)],
            capture_output=True, text=True, timeout=25)

    def test_four_fresh_complete_workflows_and_unchanged_original_contracts(self):
        arms = {}
        for index, (name, policy, mode) in enumerate(E.CELLS):
            directory, _, _ = materialize(self.root, self.identity, policy, mode == 'resources', index)
            arms[name] = E.load_cell(directory, self.identity, policy, mode)
        self.assertEqual(E.compare({name: arms[name] for name, _, _ in E.CELLS[:2]}, 'certification')['status'], 'certified')
        result = E.compare(arms, 'pair')
        self.assertEqual(result['certificationWorkPerArm'], dict(functionalWorkloads=2, hashes=35, conversions=70, snapshots=4))
        self.assertEqual(result['measuredWorkPerArm'], dict(functionalWorkloads=2, warmupWorkloads=2, measuredWorkloads=8, hashes=205, conversions=205, snapshots=4))
        self.assertEqual(sum(len(a['native']['functionalCases'][0]['visualEvidence']) for a in arms.values()), 16)
        self.assertEqual(len({a['native']['processIdentifier'] for a in arms.values()}), 4)
        for name in ('baseline', 'candidate'):
            self.assertEqual(len(arms[name]['documents']), 12)
            self.assertEqual(len(result['arms'][name]['effectContextCheckpoints']), 142)
            self.assertEqual(result['arms'][name]['effectContextFinal']['contextCount'], 1)
            self.assertEqual(result['arms'][name]['earliestDrawingEntryMemory'], arms[name]['drawing']['checkpoints'][0]['memory'])
            self.assertEqual(result['arms'][name]['earliestDrawingToFinalAccountingDelta'], E.C.accounting_delta(
                arms[name]['drawing']['checkpoints'][0]['memory'], arms[name]['native']['finalMemory']))
            self.assertEqual(result['arms'][name]['ownedLaunchElapsedSeconds'], arms[name]['launcher']['elapsedSeconds'])
            self.assertEqual(result['arms'][name]['wrapperDurationSeconds'], arms[name]['lifecycle']['wrapperDurationSeconds'])
            self.assertTrue(all(result['arms'][name]['rendererStorageFinal'][field] == 0 for field in E.R.OWNERSHIP))
        for field in ('memoryStabilityAssessed', 'nativeExecutionAttestedByChecker', 'productMemoryRemedyClaim', 'memoryTargetIsProcessRSSCap'):
            self.assertFalse(result[field])
        for optimized in (False, True):
            output = self.root / 'checked.json'
            completed = self.cli('--root', self.root, '--stage', 'pair', '--output', output, optimized=optimized)
            self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)
            self.assertEqual(json.loads(output.read_text())['comparisonKind'], E.KIND)
        self.assertEqual(E.C.STRATEGIES, ('reference', 'owned-srgb8'))
        self.assertEqual(E.C.compare(F.arms(), 'pair')['status'], 'compared')
        self.assertNotIn(E.KIND, E.R.COMPARISON_KINDS)
        with self.assertRaisesRegex(ValueError, 'unknown renderer comparison kind'):
            E.R.comparison_contract(E.KIND)
        for kind in ('drawing-input', 'renderer-final-storage', 'bogus', None, True):
            with self.assertRaisesRegex(ValueError, 'unknown effect comparison kind'):
                E.comparison_contract(kind)
        with self.assertRaisesRegex(ValueError, 'required fresh cells'):
            E.compare({**arms, 'extra': arms['baseline']}, 'pair')
        changed = copy.deepcopy(arms); changed['candidate']['native']['processIdentifier'] = changed['baseline']['native']['processIdentifier']
        with self.assertRaisesRegex(ValueError, 'distinct process identifiers'):
            E.compare(changed, 'pair')

    def test_bound_identity_selection_options_and_schema(self):
        directory, _, good = materialize(self.root, self.identity)
        E.load_cell(directory, self.identity, 'reference', 'certify')
        mutations = {'sourceCommit': '0' * 40, 'executableSHA256': '0' * 64, 'executableBytes': True,
            'architecture': 'x86_64', 'processIdentifier': 999, 'resourcesRequested': True,
            'nativeReportSHA256': '0' * 64, 'drawingReportSHA256': '0' * 64, 'effectContextPolicy': 'memory32',
            'productionDefaultPolicy': 'memory32', 'rendererStorageStrategy': 'native-pooled',
            'rendererAutoreleaseScope': 'whole-render', 'rendererProductionDefaultStrategy': 'owned-srgb8',
            'drawingStrategy': 'reference', 'comparisonKind': 'renderer-final-storage', 'hashObservation': 'cgcontext',
            'schemaVersion': True, 'maximumCheckpoints': 257, 'additionalRasterObservations': 1,
            'additionalMemoryObservations': 1, 'contextOwnershipScope': 'per-call', 'observationBoundary': 'extra',
            'contextInitializationBoundary': 'before-all-sampling',
            'productDefaultsChanged': True, 'privateFrameworkReleaseClaim': True}
        for field, value in mutations.items():
            bad = copy.deepcopy(good); bad[field] = value; save(directory, bad)
            with self.subTest(field=field), self.assertRaises(ValueError):
                E.load_cell(directory, self.identity, 'reference', 'certify')
        for field in good:
            bad = copy.deepcopy(good); del bad[field]; save(directory, bad)
            with self.subTest(missing=field), self.assertRaisesRegex(ValueError, 'unexpected object keys'):
                E.load_cell(directory, self.identity, 'reference', 'certify')
        for policy in E.POLICIES:
            valid = state(policy, 5)
            E.snapshot(valid, policy, released=True)
            for field in valid:
                for value in (-1, True, None, '1', 1.0, 1 << 63):
                    if field == 'configuredCacheIntermediates' and value is False:
                        continue
                    bad = copy.deepcopy(valid); bad[field] = value
                    with self.subTest(policy=policy, field=field, value=value), self.assertRaises(ValueError):
                        E.snapshot(bad, policy, released=True)
            bad = copy.deepcopy(valid); bad['extraOption'] = False
            with self.assertRaisesRegex(ValueError, 'unexpected object keys'):
                E.snapshot(bad, policy)
            for target in (0, 31, 33, False, None):
                bad = copy.deepcopy(valid); bad['configuredMemoryTargetMegabytes'] = target
                with self.assertRaises(ValueError):
                    E.snapshot(bad, policy)
        with self.assertRaisesRegex(ValueError, 'unknown effect policy'):
            E.snapshot(state('reference'), 'forged')

    def test_earliest_checkpoint_refuses_effect_work_before_recorded_memory(self):
        for index, policy in enumerate(E.POLICIES):
            directory, _, good = materialize(self.root, self.identity, policy, False, index)
            E.load_cell(directory, self.identity, policy, 'certify')
            bad = copy.deepcopy(good)
            bad['checkpoints'][0]['effectContext'] = state(policy, 1)
            save(directory, bad)
            with self.subTest(policy=policy), self.assertRaisesRegex(ValueError, 'before the earliest drawing memory checkpoint'):
                E.load_cell(directory, self.identity, policy, 'certify')

    def test_work_must_exercise_real_effect_and_native_renderer_without_owned_bytes(self):
        directory, _, good = materialize(self.root, self.identity, 'memory32', True, 2)
        E.load_cell(directory, self.identity, 'memory32', 'resources')
        mutations = [lambda r: r['checkpoints'].pop(), lambda r: r['checkpoints'].reverse(),
            lambda r: [p.update(effectContext=state('memory32')) for p in r['checkpoints']],
            lambda r: r['checkpoints'][-1].update(effectContext=state('memory32', 1)),
            lambda r: [p.update(rendererStorage=RF.state('native')) for p in r['checkpoints']],
            lambda r: r['checkpoints'][-1]['effectContext'].update(failureCount=1),
            lambda r: r['checkpoints'][-1].update(rendererStorage=RF.state('owned-srgb8', 12)),
            lambda r: r['checkpoints'][-1]['effectContext'].update(attemptCount=13)]
        for mutation in mutations:
            bad = copy.deepcopy(good); mutation(bad); save(directory, bad)
            with self.assertRaises(ValueError):
                E.load_cell(directory, self.identity, 'memory32', 'resources')

    def test_launch_wrapper_stale_raw_bindings_and_fail_closed_cli(self):
        directory, arm, report = materialize(self.root, self.identity)
        for target, field, value in [('launcher', 'effectContextPolicy', 'memory32'), ('launcher', 'comparisonKind', 'forged'),
            ('launcher', 'rendererStorageStrategy', 'native-pooled'), ('launcher', 'rendererAutoreleaseScope', 'whole-render'),
            ('launcher', 'ownedExitConfirmed', False), ('launcher', 'timeoutSeconds', 601),
            ('wrapper', 'timeout_seconds', 621), ('wrapper', 'command', arm['wrapper']['command'][:-1])]:
            bad = copy.deepcopy(arm); bad[target][field] = value; F.save(directory, bad); bind(directory, report)
            with self.subTest(target=target, field=field), self.assertRaises(ValueError):
                E.load_cell(directory, self.identity, 'reference', 'certify')
        F.save(directory, arm); bind(directory, report)
        for filename in ('editable-drawing-pair.json', 'editable-annotation-native.json'):
            path = directory / filename; original = path.read_bytes(); path.write_bytes(original + b' ')
            with self.assertRaises(ValueError):
                E.load_cell(directory, self.identity, 'reference', 'certify')
            path.write_bytes(original)
        report['additionalMemoryObservations'] = 1; save(directory, report)
        for optimized in (False, True):
            output = self.root / 'rejected.json'
            completed = self.cli('--cell', directory, '--policy', 'reference', '--mode', 'certify', '--output', output, optimized=optimized)
            self.assertEqual(completed.returncode, 1)
            self.assertIn('additionalMemoryObservations', json.loads(output.read_text())['error'])
            for flags in [('--policy', 'forged'), ('--comparison-kind', 'drawing-input')]:
                self.assertNotEqual(self.cli('--output', output, *flags, optimized=optimized).returncode, 0)

    def test_bounded_strict_reader_and_canonical_temp_roots(self):
        directory, _, report = materialize(self.root, self.identity)
        path = directory / E.FILENAME
        for raw in (b' ' * (E.MAX_BYTES + 1), b'{"x":1,"x":2}', b'{"x":NaN}', b'{"x":1e9999}', b'{}'):
            path.write_bytes(raw)
            with self.assertRaises(ValueError):
                E.load_cell(directory, self.identity, 'reference', 'certify')
        save(directory, report)
        target = directory / 'target.json'; path.rename(target); path.symlink_to(target)
        with self.assertRaises(ValueError):
            E.load_cell(directory, self.identity, 'reference', 'certify')
        path.unlink(); target.rename(path)
        os.link(path, target)
        with self.assertRaises(ValueError):
            E.load_cell(directory, self.identity, 'reference', 'certify')
        target.unlink()
        alias = self.root / 'alias'; alias.symlink_to(directory, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'evidence directory linked/missing'):
            E.load_cell(alias, self.identity, 'reference', 'certify')
        # Canonicalization belongs in fixture producers and CLI callers, never a
        # weakening of the raw directory identity check above.
        E.load_cell(alias.resolve(strict=True), self.identity, 'reference', 'certify')


if __name__ == '__main__':
    unittest.main()
