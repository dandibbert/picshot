"""Hostile synthetic schema tests; no native execution or memory evidence."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value)
    return value

C = load('observation_comparison', SCRIPTS / 'check-editable-observation-comparison.py')
F = load('native_synthetic', SCRIPTS / 'tests/test_check_editable_annotation_report.py')
FIELDS = {'source': 'sourcePixelsSHA256', 'base': 'basePixelsSHA256',
    'decorated-reference': 'expectedOutputPixelsSHA256', 'history-persisted-current': 'persistedOutputPixelsSHA256',
    'history-replayed': 'reopenedOutputPixelsSHA256', 'hidden-preview': 'hiddenPixelsSHA256',
    'hidden-after-snapshots': 'hiddenPixelsSHA256', 'export-annotated': 'ordinaryExportPixelsSHA256',
    'export-original': 'originalExportPixelsSHA256', 'pin-current-after-cancel': 'expectedOutputPixelsSHA256',
    'applied-reference': 'appliedExpectedOutputPixelsSHA256', 'applied-persisted': 'appliedPersistedOutputPixelsSHA256',
    'applied-replayed': 'appliedReopenedOutputPixelsSHA256', 'pin-current-after-apply': 'appliedExpectedOutputPixelsSHA256',
    'immutable-original': 'sourcePixelsSHA256', 'immutable-base': 'basePixelsSHA256'}


def observation():
    return {k: v for k, v in F.memory().items() if k != 'backingAccounting'}


def fixture(mode='certify', resources=False):
    native, _ = F.report(resources)
    cases = dict(zip(['functional-small', 'functional-4k'], native['functionalCases']))
    if resources:
        cases.update({f"{c['phase']}-{c['index']}": c for c in native['resources']['warmups'] + native['resources']['cycles']})
    rows, points = [], []
    multiplier = 2 if mode == 'certify' else 1
    for workload, case in cases.items():
        labels = C.SMALL_LABELS if workload == 'functional-small' else C.LABELS
        case['ownershipAfterRelease']['canonical']['created'] = len(labels)
        for label in labels:
            scale = 1 if workload == 'functional-small' else 6
            if label in ('source', 'base', 'export-original', 'immutable-original', 'immutable-base'):
                width, height = 640 * scale, 360 * scale
            elif label in ('reference-crop', 'actual-crop'):
                width, height = 400 * scale, 260 * scale
            else:
                width, height = 400 * scale + 14, 260 * scale + 14
            digest = case[FIELDS[label]] if label in FIELDS else '9' * 64
            size = width * height * 4
            row = {'index': len(rows) + 1, 'workload': workload, 'label': label,
                'input': {'width': width, 'height': height, 'bitsPerComponent': 8, 'bitsPerPixel': 32,
                          'bytesPerRow': width * 4, 'alphaInfo': 1, 'bitmapInfo': 16385,
                          'colorSpaceName': 'kCGColorSpaceSRGB', 'colorSpaceModel': 1,
                          'colorSpaceICC_SHA256': '8' * 64, 'renderingIntent': 0, 'shouldInterpolate': False},
                'normalizedBytes': size, 'conversionCount': multiplier, 'knownSimultaneousDestinationBytes': size * multiplier,
                'before': observation(), 'after': observation(), 'status': 'passed', 'elapsedSeconds': 0.01, 'sha256': digest}
            if mode == 'certify':
                row.update(referenceSHA256=digest, candidateSHA256=digest, comparedBytes=size, everyRGBAByteEqual=True)
            rows.append(row)
        stages = C.STAGES.copy()
        if workload == 'functional-small':
            stages[6:6] = [f'snapshot-{when}-{name}' for name in ('editable-hidden-pin.png', 'editable-restored-pin.png') for when in ('before', 'after')]
            stages[12:12] = [f'snapshot-{when}-{name}' for name in ('editable-reopened-light.png', 'editable-reopened-dark.png') for when in ('before', 'after')]
        points += [{'workload': workload, 'label': label, 'observation': observation()} for label in stages]
    points.append({'workload': list(cases)[-1], 'label': 'final-cleanup', 'observation': observation()})
    native_bytes = json.dumps(native).encode()
    diagnostic = {k: native[k] for k in ('sourceCommit', 'executableSHA256', 'architecture', 'processIdentifier', 'resourcesRequested')}
    diagnostic.update(schemaVersion=1, status='passed', mode=mode, nativeReportSHA256=hashlib.sha256(native_bytes).hexdigest(),
        normalizedFormat=C.FORMAT, hashCount=len(rows), conversionCount=len(rows) * multiplier,
        totalNormalizedBytes=sum(r['normalizedBytes'] * multiplier for r in rows), snapshotCount=4,
        maximumHashes=256, maximumCheckpoints=256, hashes=rows, checkpoints=points,
        elapsedSecondsBeforeSidecarWrite=123, certificationOnly=mode == 'certify',
        memoryStabilityAssessed=False, productMemoryRemedyClaim=False, scope='Synthetic test; not native evidence')
    return diagnostic, native, native_bytes


def arm(mode, resources=False):
    d, n, raw = fixture(mode, resources)
    return {'diagnostic': d, 'native': n, 'inputs': C.validate_diagnostic(d, n, raw, mode, resources)}


class ObservationComparisonTests(unittest.TestCase):
    def test_certification_includes_every_normalization_input(self):
        d, n, raw = fixture()
        values = C.validate_diagnostic(d, n, raw, 'certify', False)
        self.assertEqual(len(values), 35)
        self.assertEqual(d['conversionCount'], 70)
        self.assertEqual(len(d['checkpoints']), 31)

    def test_candidate_resource_work_includes_initial_and_warmup_cost(self):
        d, n, raw = fixture('vimage', True)
        self.assertEqual(len(C.validate_diagnostic(d, n, raw, 'vimage', True)), 205)
        self.assertEqual(len(d['checkpoints']), 141)
        arms = {'certification': arm('certify'), 'baseline': arm('cgcontext'), 'candidate': arm('vimage'), 'candidateResources': arm('vimage', True)}
        result = C.compare(arms)
        self.assertFalse(result['memoryStabilityAssessed'])
        self.assertIn('baseline-resources', result['unmatchedCells'])
        measured = result['arms']['candidateResources']
        self.assertEqual((measured['functionalWorkloads'], measured['warmupWorkloads'], measured['measuredWorkloads']), (2, 2, 8))
        self.assertEqual(len(measured['lateMeasuredIncrements']), 3)
        self.assertGreater(measured['entryToAfterWarmupDeltaBytes']['resident_size'], 0)

    def test_missing_changed_or_uncertified_work_is_rejected(self):
        mutations = [
            lambda d: d['hashes'].pop(),
            lambda d: d['hashes'][0].update(everyRGBAByteEqual=False),
            lambda d: d['hashes'][0].update(candidateSHA256='0' * 64),
            lambda d: d['hashes'][0].update(comparedBytes=1),
            lambda d: d['hashes'][0]['input'].update(width=320),
            lambda d: d['hashes'][0].update(normalizedBytes=1),
            lambda d: d['hashes'][0].update(conversionCount=1),
            lambda d: d['hashes'][0].update(knownSimultaneousDestinationBytes=1),
            lambda d: d['hashes'][0]['before']['counters'].pop('purgeable_volatile_resident'),
            lambda d: d['hashes'][0].update(sha256='0' * 64, referenceSHA256='0' * 64, candidateSHA256='0' * 64),
            lambda d: d['hashes'][3].update(sha256='0' * 64, referenceSHA256='0' * 64, candidateSHA256='0' * 64),
            lambda d: d.update(nativeReportSHA256='0' * 64),
            lambda d: d.update(totalNormalizedBytes=1),
            lambda d: d.update(snapshotCount=0),
            lambda d: d.update(mode='vimage'),
            lambda d: d.update(memoryStabilityAssessed=True),
            lambda d: d.update(productMemoryRemedyClaim=True),
            lambda d: d['checkpoints'].pop(6),
            lambda d: d['checkpoints'].reverse(),
            lambda d: d.update(hashCount=True),
        ]
        for mutate in mutations:
            d, n, raw = fixture(); mutate(d)
            with self.subTest(mutation=mutate), self.assertRaises((ValueError, KeyError, TypeError)):
                C.validate_diagnostic(d, n, raw, 'certify', False)

    def test_cross_process_source_pixel_alpha_color_changes_rejected(self):
        for change in ('source', 'executable', 'alpha', 'color', 'pixels'):
            arms = {'certification': arm('certify'), 'baseline': arm('cgcontext'), 'candidate': arm('vimage')}
            candidate = arms['candidate']
            if change == 'source': candidate['native']['sourceCommit'] = '0' * 40
            elif change == 'executable': candidate['native']['executableSHA256'] = '0' * 64
            else:
                p, h = candidate['inputs'][('functional-small', 'source')]
                if change == 'alpha': p['alphaInfo'] = 5
                elif change == 'color': p['colorSpaceICC_SHA256'] = '0' * 64
                else: h = '0' * 64
                candidate['inputs'][('functional-small', 'source')] = p, h
            with self.subTest(change=change), self.assertRaises(ValueError): C.compare(arms)

    def test_resource_cycle_must_match_certified_input(self):
        arms = {'certification': arm('certify'), 'baseline': arm('cgcontext'), 'candidate': arm('vimage'), 'candidateResources': arm('vimage', True)}
        p, h = arms['candidateResources']['inputs'][('warmup-1', 'source')]
        arms['candidateResources']['inputs'][('warmup-1', 'source')] = p, '0' * 64
        with self.assertRaises(ValueError): C.compare(arms)


if __name__ == '__main__':
    unittest.main()
