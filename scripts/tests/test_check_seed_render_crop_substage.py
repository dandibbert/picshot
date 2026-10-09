"""Portable adversarial contracts only; synthetic files never attest native execution."""
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


S = module('substage_checker_tests', SCRIPTS / 'check-seed-render-crop-substage.py')
EF = module('substage_effect_fixture', SCRIPTS / 'tests/test_check_effect_context_pair.py')
F = EF.F


def save(directory, report):
    (directory / S.FILENAME).write_text(json.dumps(report, sort_keys=True))


def materialize(root, identity, resources=False, index=0):
    # Resolve the producer root before constructing ANY path-bound identity.
    root = Path(root).resolve(strict=True)
    directory, arm, effect = EF.materialize(root, identity, 'reference', resources, index)
    destination = root / ('resources' if resources else 'certification')
    directory.rename(destination); directory = destination
    arm['launcher'].pop('comparisonKind')
    arm['launcher']['substageProbe'] = S.KIND
    arm['wrapper']['command'] = ['swift', 'scripts/launch-seed-render-crop-substage.swift', identity['bundlePath'],
                               str(directory / 'launch.json'), 'resources' if resources else 'certify']
    drawing = {(p['workload'], p['label']): p for p in arm['drawing']['checkpoints']}
    stages = {(p['workload'], p['label']): p for p in arm['diagnostic']['checkpoints']}
    effect_points = {(p['workload'], p['label']): p for p in effect['checkpoints']}
    points = []
    for workload in S.O.workload_names(resources):
        before = drawing[(workload, 'seed-native-render-crop')]
        start = stages[(workload, 'seed-native-render-crop')]['observation']['uptimeSeconds']
        stop = drawing[(workload, 'history-save-reopen-decode')]['memory']['uptimeSeconds']
        step = (stop - start) / 12
        for position, label in enumerate(S.LABELS, 1):
            points.append(dict(index=len(points)+1, workload=workload, label=label,
                drawingCheckpointLabel='seed-native-render-crop', memory=F.full_memory(position, start + position*step),
                drawing=copy.deepcopy(before['drawing']), rendererStorage=copy.deepcopy(effect_points[(workload, 'seed-native-render-crop')]['rendererStorage']),
                effectContext=copy.deepcopy(effect_points[(workload, 'seed-native-render-crop')]['effectContext'])))
        for position, label in enumerate(('reference-crop', 'actual-crop', 'decorated-reference')):
            row = next(p for p in arm['diagnostic']['hashes'] if (p['workload'], p['label']) == (workload, label))
            row['before']['uptimeSeconds'] = start + (3 + 2*position)*step
            row['after']['uptimeSeconds'] = start + (4 + 2*position)*step
    F.save(directory, arm); EF.bind(directory, effect)
    report = {key: arm['native'][key] for key in S.IDENTITY}
    report.update(schemaVersion=1, status='passed', probeKind=S.KIND, diagnosticOnly=True,
        drawingStrategy='owned-srgb8', rendererStorageStrategy='native', rendererAutoreleaseScope='caller',
        effectContextPolicy='reference', productionDefaultPolicy='reference', hashObservation='vimage' if resources else 'certify',
        nativeReportSHA256=hashlib.sha256((directory/'editable-annotation-native.json').read_bytes()).hexdigest(),
        drawingReportSHA256=hashlib.sha256((directory/'editable-drawing-pair.json').read_bytes()).hexdigest(),
        maximumCheckpoints=len(points), checkpointsPerWorkflow=2, additionalMemoryObservations=len(points), additionalRasterObservations=0,
        metadataCheckpointCount=len(arm['drawing']['checkpoints']), maximumMetadataCheckpoints=256,
        contextInitializationBoundary='after-first-drawing-memory-before-native-entry', memoryObservationKind='complete-O.memory-dictionary',
        existingMaterializedCropBoundary='reference-crop.before', existingMaterializedCropBoundaryHasFullBackingFields=False,
        existingMaterializedCropBoundaryCounterCount=8, productDefaultsChanged=False, privateFrameworkReleaseClaim=False,
        checkpoints=points, scope='Synthetic scalar contract fixture; no native execution')
    save(directory, report)
    return directory, arm, report, effect


class SubstageCheckerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve(strict=True)
        self.identity = F.identity_at(self.root)

    def cli(self, *arguments, optimized=False):
        return subprocess.run([sys.executable, *(['-O'] if optimized else []), str(SCRIPTS/'check-seed-render-crop-substage.py'),
            '--app', self.identity['bundlePath'], '--expected-source', self.identity['sourceCommit'], *map(str, arguments)],
            capture_output=True, text=True, timeout=30)

    def test_exact_two_complete_processes_certify_every_resource_input_and_document(self):
        arms = {}
        for index, (name, mode) in enumerate(S.CELLS):
            directory, _, _, _ = materialize(self.root, self.identity, mode == 'resources', index)
            arms[name] = S.load_cell(directory, self.identity, mode)
        result = S.attribute(arms)
        self.assertEqual(result['status'], 'attributed')
        self.assertEqual(result['certificationWork'], dict(functionalWorkloads=2, hashes=35, conversions=70, snapshots=4, documentPairs=2, additionalMemoryObservations=4))
        self.assertEqual(result['resourceWork'], dict(functionalWorkloads=2, warmupWorkloads=2, measuredWorkloads=8, hashes=205, conversions=205, snapshots=4, documentPairs=12, additionalMemoryObservations=24))
        self.assertNotIn('candidateMinusBaseline', result)
        for name, arm in arms.items():
            metrics = result['observations'][name]
            self.assertEqual(metrics['entryMemory'], arm['native']['entryMemory'])
            self.assertEqual(metrics['finalMemory'], arm['native']['finalMemory'])
            self.assertEqual(metrics['sampledMemory'], arm['native']['sampledMemory'])
            self.assertEqual(metrics['earliestDrawingEntryMemory'], arm['drawing']['checkpoints'][0]['memory'])
            self.assertEqual(metrics['ownedLaunchElapsedSeconds'], arm['launcher']['elapsedSeconds'])
            self.assertIn('serialization occurs after native finalMemory', metrics['observationOverheadScope'])
            for row in metrics['seedRenderCropIntervals']:
                crop = row['fixtureMaterializedReferenceCrop']
                self.assertFalse(crop['fullBackingFieldsAvailable'])
                self.assertEqual(set(crop['existingPreHashObservation']), {'uptimeSeconds', 'counters'})
                self.assertEqual(set(crop['counterDelta']), S.N.MEMORY)
                self.assertNotIn('accountingDelta', crop)
        for key in ('memoryStabilityAssessed', 'productMemoryRemedyClaim', 'privateFrameworkReleaseClaim',
                    'nativeExecutionAttestedByChecker', 'crossRunMemorySubtraction'):
            self.assertFalse(result[key])
        self.assertEqual(len(result['observations']['resources']['everyMeasuredIncrementAccountingDelta']), 8)
        self.assertEqual(len(result['observations']['resources']['lateAccountingDelta']), 3)
        for optimized in (False, True):
            output = self.root/'checked.json'
            run = self.cli('--root', self.root, '--output', output, optimized=optimized)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertEqual(json.loads(output.read_text())['status'], 'attributed')

    def test_identity_config_claim_count_and_exact_keys_mutations(self):
        directory, arm, good, effect = materialize(self.root, self.identity)
        S.load_cell(directory, self.identity, 'certify')
        changes = dict(schemaVersion=True, status='observed', probeKind='unknown', diagnosticOnly=False,
            sourceCommit='0'*40, executableSHA256='0'*64, executableBytes=True, architecture='x86_64', processIdentifier=3,
            resourcesRequested=True, drawingStrategy='reference', rendererStorageStrategy='owned-srgb8', rendererAutoreleaseScope='whole-render',
            effectContextPolicy='memory32', productionDefaultPolicy='memory32', hashObservation='vimage', nativeReportSHA256='0'*64,
            drawingReportSHA256='0'*64, maximumCheckpoints=5, checkpointsPerWorkflow=3, additionalMemoryObservations=5,
            additionalRasterObservations=1, metadataCheckpointCount=0, maximumMetadataCheckpoints=257,
            contextInitializationBoundary='before-entry', memoryObservationKind='counters-only', existingMaterializedCropBoundary='nearby-drawing',
            existingMaterializedCropBoundaryHasFullBackingFields=True, existingMaterializedCropBoundaryCounterCount=9,
            productDefaultsChanged=True, privateFrameworkReleaseClaim=True, scope='')
        for key, value in changes.items():
            bad = copy.deepcopy(good); bad[key] = value; save(directory, bad)
            with self.subTest(field=key), self.assertRaises(ValueError):
                S.load_cell(directory, self.identity, 'certify')
        for key in good:
            bad = copy.deepcopy(good); del bad[key]; save(directory, bad)
            with self.subTest(missing=key), self.assertRaises(ValueError):
                S.load_cell(directory, self.identity, 'certify')
        for field, value in [('index', True), ('workload', 'functional-4k'), ('label', 'after-reference-full-render'),
                             ('drawingCheckpointLabel', 'input-generation')]:
            bad = copy.deepcopy(good); bad['checkpoints'][0][field] = value; save(directory, bad)
            with self.subTest(point=field), self.assertRaises(ValueError):
                S.load_cell(directory, self.identity, 'certify')

    def test_full_backing_counters_trackers_and_precise_timestamp_source_order(self):
        directory, arm, good, effect = materialize(self.root, self.identity)
        mutations = [lambda r: r['checkpoints'].pop(), lambda r: r['checkpoints'].reverse(),
            lambda r: r['checkpoints'].append(copy.deepcopy(r['checkpoints'][-1])),
            lambda r: r['checkpoints'][0]['memory'].pop('backingAccounting'),
            lambda r: r['checkpoints'][0]['memory']['counters'].pop('resident_size'),
            lambda r: r['checkpoints'][0]['memory']['backingAccounting']['standard']['bytes'].pop('internal'),
            lambda r: r['checkpoints'][0]['memory']['backingAccounting']['purgeable']['ledgerBytes'].pop('ledger_tag_graphics_footprint'),
            lambda r: r['checkpoints'][0]['memory']['backingAccounting']['standard'].update(kernelReturn=5),
            lambda r: r['checkpoints'][0]['memory'].update(uptimeSeconds=0),
            lambda r: r['checkpoints'][0]['memory']['backingAccounting']['standard'].update(observedAtUptimeSeconds=1),
            lambda r: r['checkpoints'][0]['memory']['backingAccounting']['purgeable'].update(
                observedAtUptimeSeconds=r['checkpoints'][0]['memory']['uptimeSeconds']+.01),
            lambda r: r['checkpoints'][1]['memory'].update(uptimeSeconds=99999),
            lambda r: r['checkpoints'][1]['memory'].update(uptimeSeconds=r['checkpoints'][0]['memory']['uptimeSeconds']-.01),
            lambda r: r['checkpoints'][0]['drawing'].update(failureCount=1),
            lambda r: r['checkpoints'][0]['rendererStorage'].update(failureCount=1),
            lambda r: r['checkpoints'][0]['effectContext'].update(failureCount=1),
            lambda r: r['checkpoints'][0]['effectContext'].update(attemptCount=100, publishCount=100)]
        for i, edit in enumerate(mutations):
            bad = copy.deepcopy(good); edit(bad); save(directory, bad)
            with self.subTest(mutation=i), self.assertRaises(ValueError):
                S.load_cell(directory, self.identity, 'certify')
        save(directory, good)
        # Retiming an existing hash (raw observer is independently revalidated)
        # cannot move crop materialization before the new full-render hook.
        bad = copy.deepcopy(arm)
        row = next(p for p in bad['diagnostic']['hashes'] if p['label'] == 'reference-crop')
        row['before']['uptimeSeconds'] = good['checkpoints'][1]['memory']['uptimeSeconds'] - .001
        F.save(directory, bad); EF.bind(directory, effect)
        with self.assertRaisesRegex(ValueError, 'source chronology'):
            S.load_cell(directory, self.identity, 'certify')
        # Supplying a nearby full dictionary at the old counter-only endpoint is rejected.
        row['before'] = copy.deepcopy(good['checkpoints'][1]['memory'])
        F.save(directory, bad); EF.bind(directory, effect)
        with self.assertRaisesRegex(ValueError, 'unexpected object keys'):
            S.load_cell(directory, self.identity, 'certify')

    def test_launcher_wrapper_identity_bounds_and_fail_closed_cli(self):
        directory, arm, report, effect = materialize(self.root, self.identity)
        mutations = [('launcher', 'substageProbe', 'other'), ('launcher', 'effectContextPolicy', 'memory32'),
            ('launcher', 'rendererStorageStrategy', 'native-pooled'), ('launcher', 'rendererAutoreleaseScope', 'whole-render'),
            ('launcher', 'drawingStrategy', 'reference'), ('launcher', 'ownedExitConfirmed', False),
            ('launcher', 'processIdentifier', 999), ('launcher', 'timeoutSeconds', 601),
            ('launcher', 'processStartMemoryCaptured', True), ('wrapper', 'timeout_seconds', 621),
            ('wrapper', 'command', arm['wrapper']['command'] + ['extra'])]
        for target, field, value in mutations:
            bad = copy.deepcopy(arm); bad[target][field] = value; F.save(directory, bad); EF.bind(directory, effect)
            with self.subTest(target=target, field=field), self.assertRaises(ValueError):
                S.load_cell(directory, self.identity, 'certify')
        F.save(directory, arm); EF.bind(directory, effect)
        for status in (1, 124, True):
            with self.assertRaises(ValueError):
                S.load_cell(directory, self.identity, 'certify', status)
        report['additionalMemoryObservations'] = 0; save(directory, report)
        for optimized in (False, True):
            output = self.root/'rejected.json'
            run = self.cli('--cell', directory, '--mode', 'certify', '--output', output, optimized=optimized)
            self.assertEqual(run.returncode, 1)
            self.assertIn('additionalMemoryObservations', json.loads(output.read_text())['error'])
            for args in [('--mode', 'anything'), ('--observation-kind', 'anything'), ('--root', self.root, '--mode', 'certify')]:
                self.assertNotEqual(self.cli('--output', output, *args, optimized=optimized).returncode, 0)

    def test_sequential_identity_certified_hash_document_and_geometry_mapping(self):
        arms = {}
        for index, (name, mode) in enumerate(S.CELLS):
            directory, _, _, _ = materialize(self.root, self.identity, mode == 'resources', index)
            arms[name] = S.load_cell(directory, self.identity, mode)
        mutations = [lambda a: a.update(extra=a['certification']),
            lambda a: a['resources'].update(bundlePlistSHA256='0'*64),
            lambda a: a['resources']['native'].update(executableSHA256='0'*64),
            lambda a: a['resources']['native'].update(processIdentifier=a['certification']['native']['processIdentifier']),
            lambda a: a['resources']['lifecycle'].update(launchBeganUptimeSeconds=0),
            lambda a: a['resources']['inputs'].update({('measured-8', 'reference-crop'): ({}, '0'*64)}),
            lambda a: a['resources']['documents']['measured-8'][0].update(extra='changed'),
            lambda a: a['resources']['native']['functionalCases'][0]['visualEvidence'][0].update(width=999)]
        for edit in mutations:
            bad = copy.deepcopy(arms); edit(bad)
            with self.assertRaises(ValueError):
                S.attribute(bad)

    def test_raw_reports_png_binary_and_plist_are_bound(self):
        directory, arm, report, effect = materialize(self.root, self.identity)
        for filename in ('editable-annotation-native.json', 'editable-drawing-pair.json', S.E.FILENAME):
            path = directory/filename; raw = path.read_bytes()
            path.write_bytes(raw + b' ')
            if filename == S.E.FILENAME:
                changed = json.loads(raw); changed['nativeReportSHA256'] = '0'*64; path.write_text(json.dumps(changed))
            with self.subTest(file=filename), self.assertRaises(ValueError):
                S.load_cell(directory, self.identity, 'certify')
            path.write_bytes(raw)
        png = directory/'editable-hidden-pin.png'; raw = png.read_bytes(); png.write_bytes(raw[:-1])
        with self.assertRaises(ValueError):
            S.load_cell(directory, self.identity, 'certify')
        png.write_bytes(raw)
        for relative in ('Contents/MacOS/PicShot', 'Contents/Info.plist'):
            path = Path(self.identity['bundlePath'])/relative; raw = path.read_bytes(); path.write_bytes(b'forged')
            output = self.root/'rejected.json'
            self.assertEqual(self.cli('--cell', directory, '--mode', 'certify', '--output', output).returncode, 1)
            path.write_bytes(raw)

    def test_strict_bounds_nonfinite_duplicates_links_and_canonical_temporary_roots(self):
        directory, _, report, _ = materialize(self.root, self.identity)
        path = directory/S.FILENAME
        for raw in (b' '*(S.MAX_BYTES+1), b'{"x":1,"x":2}', b'{"x":NaN}', b'{"x":1e9999}', b'{}'):
            path.write_bytes(raw)
            with self.assertRaises(ValueError):
                S.load_cell(directory, self.identity, 'certify')
        save(directory, report)
        # The new route applies the same stable regular-file contract to every raw report.
        for filename in (*F.FILES.values(), S.E.FILENAME):
            original = directory/filename; linked = directory/'linked.json'; os.link(original, linked)
            with self.subTest(linked=filename), self.assertRaises(ValueError):
                S.load_cell(directory, self.identity, 'certify')
            linked.unlink()
        target = directory/'target.json'; path.rename(target); path.symlink_to(target)
        with self.assertRaises(ValueError):
            S.load_cell(directory, self.identity, 'certify')
        path.unlink(); target.rename(path); os.link(path, target)
        with self.assertRaises(ValueError):
            S.load_cell(directory, self.identity, 'certify')
        target.unlink()
        alias = self.root/'alias'; alias.symlink_to(directory, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'evidence directory linked/missing'):
            S.load_cell(alias, self.identity, 'certify')
        S.load_cell(alias.resolve(strict=True), self.identity, 'certify')

    def test_old_public_calls_and_explicit_comparison_sets_remain_closed(self):
        self.assertEqual(S.C.compare(F.arms(), 'pair')['status'], 'compared')
        self.assertEqual(S.C.COMPARISON_KINDS, ('drawing-input', 'renderer-final-storage', 'renderer-autorelease-scope',
            'renderer-final-storage-scoped', 'effect-context-memory-target'))
        self.assertEqual(S.R.COMPARISON_KINDS, ('renderer-final-storage', 'renderer-autorelease-scope', 'renderer-final-storage-scoped'))
        for kind in (S.KIND, 'bogus', True, None):
            with self.assertRaises(ValueError):
                S.R.comparison_contract(kind)
            with self.assertRaises(ValueError):
                S.E.comparison_contract(kind)
        directory, _, _, _ = materialize(self.root, self.identity)
        with self.assertRaises(ValueError):
            S.C.load_cell(directory, self.identity, 'owned-srgb8', 'certify')
        for kind in ('bogus', True, None):
            with self.assertRaises(ValueError):
                S.load_cell(directory, self.identity, 'certify', observation_kind=kind)
        for strategy, comparison in [('reference', 'drawing-input'), ('owned-srgb8', 'renderer-final-storage')]:
            with self.assertRaises(ValueError):
                S.C.load_cell(directory, self.identity, strategy, 'certify', comparison_kind=comparison, observation_kind=S.KIND)


if __name__ == '__main__':
    unittest.main()
