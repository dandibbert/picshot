#!/usr/bin/env python3
"""Bounded diagnostic attribution only; exact pixels gate comparison, never memory acceptance."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

SPEC = importlib.util.spec_from_file_location('editable_native_check', Path(__file__).with_name('check-editable-annotation-report.py'))
N = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(N)

LABELS = ['source', 'base', 'reference-crop', 'actual-crop', 'decorated-reference',
          'history-persisted-current', 'history-replayed', 'hidden-preview',
          'export-annotated', 'export-original', 'pin-current-after-cancel',
          'applied-reference', 'applied-persisted', 'applied-replayed',
          'pin-current-after-apply', 'immutable-original', 'immutable-base']
SMALL_LABELS = LABELS[:8] + ['hidden-after-snapshots'] + LABELS[8:]
STAGES = ['workload-entry', 'input-generation', 'seed-native-render-crop',
          'history-save-reopen-decode', 'history-restore-edit-failure-retry',
          'pin-create-reopen-hidden-preview', 'native-export', 'pin-edit-apply',
          'fresh-pin-load-render', 'legacy-and-cleanup', 'workload-released']
FORMAT = 'sRGB / premultipliedLast / byteOrder32Big / tightly packed RGBA8, all bytes including alpha'


def workload_names(resources):
    return ['functional-small', 'functional-4k'] + ([f'warmup-{i}' for i in range(1, 3)] + [f'measured-{i}' for i in range(1, 9)] if resources else [])


def observation(value):
    N.keys(value, {'uptimeSeconds', 'counters'})
    N.number(value['uptimeSeconds']); N.counters(value['counters'])


def validate_diagnostic(d, native, native_bytes, mode, resources):
    N.keys(d, {'schemaVersion', 'status', 'mode', 'sourceCommit', 'executableSHA256', 'architecture',
              'processIdentifier', 'nativeReportSHA256', 'resourcesRequested', 'normalizedFormat',
              'hashCount', 'conversionCount', 'totalNormalizedBytes', 'snapshotCount', 'maximumHashes',
              'maximumCheckpoints', 'hashes', 'checkpoints', 'elapsedSecondsBeforeSidecarWrite',
              'certificationOnly', 'memoryStabilityAssessed', 'productMemoryRemedyClaim', 'scope'})
    N.need(type(d['schemaVersion']) is int and d['schemaVersion'] == 1 and d['status'] == 'passed', 'diagnostic incomplete')
    N.need(mode in ('cgcontext', 'vimage', 'certify') and d['mode'] == mode, 'wrong diagnostic mode')
    for field in ('sourceCommit', 'executableSHA256', 'architecture', 'processIdentifier', 'resourcesRequested'):
        N.need(d[field] == native[field], 'sidecar/native identity differs: ' + field)
    N.need(d['nativeReportSHA256'] == hashlib.sha256(native_bytes).hexdigest(), 'native report bytes do not match sidecar')
    N.need(d['resourcesRequested'] is resources and (mode != 'certify' or not resources), 'certification/resource scope changed')
    N.need(d['certificationOnly'] is (mode == 'certify'), 'certification mislabeled')
    N.need(d['memoryStabilityAssessed'] is False and d['productMemoryRemedyClaim'] is False, 'unsupported memory claim')
    N.need(d['normalizedFormat'] == FORMAT, 'normalized pixel/color/alpha format changed')
    N.need(d['maximumHashes'] == 256 and d['maximumCheckpoints'] == 256, 'diagnostic bounds changed')
    N.need(type(d['hashes']) is list and type(d['checkpoints']) is list and len(d['checkpoints']) <= 256, 'unbounded diagnostics')
    names = workload_names(resources)
    expected = [(w, label) for w in names for label in (SMALL_LABELS if w == 'functional-small' else LABELS)]
    N.need(len(d['hashes']) == len(expected) == d['hashCount'] and type(d['hashCount']) is int, 'normalization work omitted/added')
    multiplier = 2 if mode == 'certify' else 1
    total = 0
    inputs = {}
    native_cases = dict(zip(['functional-small', 'functional-4k'], native['functionalCases']))
    if resources:
        native_cases.update({f"{c['phase']}-{c['index']}": c for c in native['resources']['warmups'] + native['resources']['cycles']})
    native_hash_fields = {
        'source': 'sourcePixelsSHA256', 'base': 'basePixelsSHA256',
        'decorated-reference': 'expectedOutputPixelsSHA256', 'history-persisted-current': 'persistedOutputPixelsSHA256',
        'history-replayed': 'reopenedOutputPixelsSHA256', 'hidden-preview': 'hiddenPixelsSHA256',
        'hidden-after-snapshots': 'hiddenPixelsSHA256', 'export-annotated': 'ordinaryExportPixelsSHA256',
        'export-original': 'originalExportPixelsSHA256', 'pin-current-after-cancel': 'expectedOutputPixelsSHA256',
        'applied-reference': 'appliedExpectedOutputPixelsSHA256', 'applied-persisted': 'appliedPersistedOutputPixelsSHA256',
        'applied-replayed': 'appliedReopenedOutputPixelsSHA256', 'pin-current-after-apply': 'appliedExpectedOutputPixelsSHA256',
        'immutable-original': 'sourcePixelsSHA256', 'immutable-base': 'basePixelsSHA256'}
    for index, (item, (workload, label)) in enumerate(zip(d['hashes'], expected), 1):
        fields = {'index', 'workload', 'label', 'input', 'normalizedBytes', 'conversionCount',
                  'knownSimultaneousDestinationBytes', 'before', 'after', 'status', 'elapsedSeconds', 'sha256'}
        if mode == 'certify':
            fields |= {'referenceSHA256', 'candidateSHA256', 'comparedBytes', 'everyRGBAByteEqual'}
        N.keys(item, fields)
        N.need(type(item['index']) is int and item['index'] == index and (item['workload'], item['label']) == (workload, label), 'hash input order changed')
        N.need(item['status'] == 'passed', 'hash did not complete')
        p = item['input']
        N.keys(p, {'width', 'height', 'bitsPerComponent', 'bitsPerPixel', 'bytesPerRow', 'alphaInfo',
                   'bitmapInfo', 'colorSpaceName', 'colorSpaceModel', 'colorSpaceICC_SHA256', 'renderingIntent', 'shouldInterpolate'})
        scale = 1 if workload == 'functional-small' else 6
        full = label in ('source', 'base', 'export-original', 'immutable-original', 'immutable-base')
        crop = label in ('reference-crop', 'actual-crop')
        width, height = (640 * scale, 360 * scale) if full else ((400 * scale, 260 * scale) if crop else (400 * scale + 14, 260 * scale + 14))
        N.need(p['width'] == width and p['height'] == height, 'input raster was resized or changed')
        for key in ('width', 'height', 'bitsPerComponent', 'bitsPerPixel', 'bytesPerRow'):
            N.integer(p[key], 1)
        for key in ('alphaInfo', 'bitmapInfo', 'renderingIntent'):
            N.integer(p[key])
        N.need(type(p['shouldInterpolate']) is bool, 'missing image interpolation metadata')
        N.need(p['colorSpaceName'] is None or type(p['colorSpaceName']) is str, 'invalid color name')
        if p['colorSpaceModel'] is not None: N.integer(p['colorSpaceModel'], -1)
        if p['colorSpaceICC_SHA256'] is not None: N.sha(p['colorSpaceICC_SHA256'])
        count = width * height * 4
        N.need(type(item['normalizedBytes']) is int and item['normalizedBytes'] == count, 'normalized byte cost changed')
        N.need(type(item['conversionCount']) is int and item['conversionCount'] == multiplier, 'conversion cost omitted')
        N.need(item['knownSimultaneousDestinationBytes'] == count * multiplier, 'live destination cost omitted')
        observation(item['before']); observation(item['after'])
        N.need(item['after']['uptimeSeconds'] >= item['before']['uptimeSeconds'], 'hash time moved backward')
        N.number(item['elapsedSeconds'], 0, 300); N.sha(item['sha256'])
        if mode == 'certify':
            N.need(item['everyRGBAByteEqual'] is True and item['comparedBytes'] == count, 'every pixel/channel/alpha byte was not certified')
            N.need(item['referenceSHA256'] == item['candidateSHA256'] == item['sha256'], 'certification digest differs')
        if label in native_hash_fields:
            N.need(item['sha256'] == native_cases[workload][native_hash_fields[label]], 'observed hash differs from native functional assertion')
        if label == 'actual-crop':
            N.need(item['sha256'] == inputs[(workload, 'reference-crop')][1], 'cropped output differs')
        inputs[(workload, label)] = (p, item['sha256'])
        total += count * multiplier
    N.need(type(d['totalNormalizedBytes']) is int and d['totalNormalizedBytes'] == total, 'total work arithmetic differs')
    N.need(type(d['conversionCount']) is int and d['conversionCount'] == len(expected) * multiplier
           and type(d['snapshotCount']) is int and d['snapshotCount'] == 4, 'hash/snapshot work changed')
    for workload, case in native_cases.items():
        N.need(case['ownershipAfterRelease']['canonical']['created'] == len(SMALL_LABELS if workload == 'functional-small' else LABELS),
               'canonical weak-object count differs from hash count')
    expected_checkpoints = []
    for workload in names:
        stages = STAGES.copy()
        if workload == 'functional-small':
            hidden = [f'snapshot-{when}-{name}' for name in ('editable-hidden-pin.png', 'editable-restored-pin.png') for when in ('before', 'after')]
            editor = [f'snapshot-{when}-{name}' for name in ('editable-reopened-light.png', 'editable-reopened-dark.png') for when in ('before', 'after')]
            stages[6:6] = hidden
            stages[12:12] = editor  # immediately after pin-edit-apply
        expected_checkpoints.extend((workload, stage) for stage in stages)
    expected_checkpoints.append((names[-1], 'final-cleanup'))
    N.need([(c.get('workload'), c.get('label')) for c in d['checkpoints']] == expected_checkpoints, 'stage/snapshot observations omitted or reordered')
    for point in d['checkpoints']:
        N.keys(point, {'workload', 'label', 'observation'}); observation(point['observation'])
    N.number(d['elapsedSecondsBeforeSidecarWrite'], 0, 300); N.string(d['scope'])
    return inputs


def load_arm(directory, identity, mode, resources=False):
    directory = Path(directory)
    path = directory / 'editable-annotation-native.json'
    native = N.read_report(path)
    launcher = N.read_report(directory / 'launch.json.launcher.json')
    checked = N.read_report(directory / 'checked-editable-annotation.json')
    N.need(launcher['status'] == 'exited' and launcher['ownedExitConfirmed'] is True and launcher['callbackReceived'] is True
           and launcher['createsNewApplicationInstance'] is True and launcher['launcherExitCode'] == 0, 'fresh owned process exit unverified')
    N.need(Path(launcher['launchedAppPath']).resolve() == Path(identity['bundlePath']).resolve(), 'different installed app launched')
    N.need(checked['status'] == 'passed' and checked['ownedExitConfirmed'] is True and checked['visualFilesVerified'] is True, 'native functional gate failed')
    N.need(checked['reportSHA256'] == hashlib.sha256(path.read_bytes()).hexdigest(), 'native checked report is stale')
    N.validate(native, identity, resources, launcher['processIdentifier'], directory)
    diagnostic = N.read_report(directory / 'editable-annotation-observation.json')
    inputs = validate_diagnostic(diagnostic, native, path.read_bytes(), mode, resources)
    return {'native': native, 'diagnostic': diagnostic, 'inputs': inputs}


def metrics(arm):
    n, d = arm['native'], arm['diagnostic']
    output = {'entryBytes': n['entryMemory']['counters'], 'finalBytes': n['finalMemory']['counters'],
        'entryToFinalDeltaBytes': N.delta(n['entryMemory'], n['finalMemory']),
        'sampledPeakBytes': n['sampledMemory']['total']['sampledPeakBytes'],
        'nativeElapsedSeconds': n['elapsedSeconds'], 'diagnosticElapsedSecondsBeforeSidecarWrite': d['elapsedSecondsBeforeSidecarWrite'],
        'functionalWorkloads': 2, 'warmupWorkloads': 2 if n['resourcesRequested'] else 0,
        'measuredWorkloads': 8 if n['resourcesRequested'] else 0, 'hashes': d['hashCount'],
        'conversions': d['conversionCount'], 'totalNormalizedBytes': d['totalNormalizedBytes'],
        'snapshots': d['snapshotCount'], 'summedHashElapsedSeconds': sum(h['elapsedSeconds'] for h in d['hashes']),
        'functionalReleaseBytes': {c['profile']: c['afterReleaseMemory']['counters'] for c in n['functionalCases']},
        'snapshotWhileLiveBytes': {s['filename']: s['whileSnapshotLiveMemory']['counters'] for s in n['functionalCases'][0]['visualEvidence']}}
    output['kernelReportedPeakBytesAtCleanup'] = {
        'resident_size_peak': n['finalMemory']['backingAccounting']['standard']['bytes'].get('resident_size_peak'),
        'ledger_phys_footprint_peak': n['finalMemory']['backingAccounting']['standard']['ledgerBytes'].get('ledger_phys_footprint_peak')}
    output['hashBoundaryNetDeltaBytesByWorkload'] = {
        workload: {key: sum(h['after']['counters'][key] - h['before']['counters'][key]
                           for h in d['hashes'] if h['workload'] == workload) for key in N.MEMORY}
        for workload in workload_names(n['resourcesRequested'])}
    output['stageBoundaryDeltas'] = [
        {'workload': a['workload'], 'from': a['label'], 'to': b['label'],
         'elapsedSeconds': b['observation']['uptimeSeconds'] - a['observation']['uptimeSeconds'],
         'deltaBytes': N.delta(a['observation'], b['observation'])}
        for a, b in zip(d['checkpoints'], d['checkpoints'][1:]) if a['workload'] == b['workload']]
    output['boundaryInterpretation'] = 'Synchronous hash and stage boundary changes are correlations, not additive allocation ownership or private framework attribution'
    if n['resourcesRequested']:
        r = n['resources']
        output.update(entryToBeforeWarmupDeltaBytes=N.delta(n['entryMemory'], r['beforeWarmup']),
            entryToAfterWarmupDeltaBytes=N.delta(n['entryMemory'], r['afterWarmupBaseline']),
            afterWarmupToMeasuredDeltaBytes=r['afterWarmupToMeasuredDeltaBytes'], lateMeasuredIncrements=r['lateMeasuredIncrements'],
            afterWarmupToFinalCleanupDeltaBytes=N.delta(r['afterWarmupBaseline'], n['finalMemory']),
            measuredToFinalCleanupDeltaBytes=N.delta(r['afterMeasuredCycles'], n['finalMemory']),
            warmupEndpoints=[c['afterMemory']['counters'] for c in r['warmups']],
            measuredEndpoints=[c['afterMemory']['counters'] for c in r['cycles']])
    return output


def compare(arms):
    cert, baseline, candidate = (arms[k] for k in ('certification', 'baseline', 'candidate'))
    for arm in arms.values():
        for field in ('sourceCommit', 'executableSHA256', 'architecture', 'bundlePath'):
            N.need(arm['native'][field] == cert['native'][field], 'comparison needs one identical installed binary/architecture')
    # PIDs can be reused by the OS; lifecycle attestation establishes distinct launches.
    N.need(baseline['inputs'] == candidate['inputs'] == cert['inputs'], 'per-input pixel/color/alpha/digest equivalence changed across fresh processes')
    if 'candidateResources' in arms:
        r = arms['candidateResources']
        for (workload, label), entry in r['inputs'].items():
            reference_key = (workload if workload.startswith('functional-') else 'functional-4k', label)
            N.need(entry == cert['inputs'][reference_key], 'resource input differs from certified functional input')
    b, c = metrics(baseline), metrics(candidate)
    return {'status': 'compared', 'architecture': cert['native']['architecture'], 'sourceCommit': cert['native']['sourceCommit'],
        'executableSHA256': cert['native']['executableSHA256'], 'exactNormalizationEquivalence': True,
        'memoryStabilityAssessed': False, 'productMemoryRemedyClaim': False,
        'matchedComparisonScope': 'Two fresh functional processes each run small 640x360 + 4K 3840x2160, 35 hashes and 4 native snapshots; only hash conversion differs',
        'unmatchedCells': ['baseline-resources', 'other-architecture'],
        'certificationExcludedFromMemoryComparison': True,
        'certificationWork': {'functionalWorkloads': 2, 'hashes': 35, 'conversions': 70,
                              'totalNormalizedBytes': cert['diagnostic']['totalNormalizedBytes'], 'snapshots': 4},
        'arms': {name: metrics(arm) for name, arm in arms.items() if name != 'certification'},
        'candidateMinusBaseline': {
            'entryToFinalDeltaBytes': {k: c['entryToFinalDeltaBytes'][k] - b['entryToFinalDeltaBytes'][k] for k in N.MEMORY},
            'sampledPeakBytes': {k: c['sampledPeakBytes'][k] - b['sampledPeakBytes'][k] for k in N.MEMORY},
            'nativeElapsedSeconds': c['nativeElapsedSeconds'] - b['nativeElapsedSeconds']},
        'interpretation': 'Single paired run supports attribution only. Entry, functional, warmup, late-cycle, snapshot and cleanup costs stay visible, including private framework backing. Candidate resources, if supplied, are unmatched observations, not a baseline improvement ratio. Native lifetime peaks can exceed 50ms sampled peaks. No purge, pressure request, threshold relaxation, product-memory remedy or leak/stability verdict.'}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', required=True, type=Path); parser.add_argument('--expected-source', required=True)
    parser.add_argument('--certification', required=True, type=Path)
    parser.add_argument('--baseline', type=Path); parser.add_argument('--candidate', type=Path)
    parser.add_argument('--candidate-resources', type=Path); parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    result = {'status': 'failed', 'memoryStabilityAssessed': False, 'productMemoryRemedyClaim': False}
    try:
        identity = N.bundle_identity(args.app, args.expected_source)
        arms = {'certification': load_arm(args.certification, identity, 'certify')}
        N.need((args.baseline is None) == (args.candidate is None), 'both functional comparison arms are required')
        if args.baseline:
            arms['baseline'] = load_arm(args.baseline, identity, 'cgcontext')
            arms['candidate'] = load_arm(args.candidate, identity, 'vimage')
            if args.candidate_resources:
                arms['candidateResources'] = load_arm(args.candidate_resources, identity, 'vimage', True)
            result = compare(arms)
        else:
            N.need(args.candidate_resources is None, 'resources require matched functional comparison first')
            result.update(status='certified', exactNormalizationEquivalence=True, certificationOnly=True,
                          conversionCount=70, hashCount=35, totalNormalizedBytes=arms['certification']['diagnostic']['totalNormalizedBytes'])
    except Exception as error:
        result['error'] = str(error)[:4096]
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    print(json.dumps(result, indent=2, sort_keys=True))
    return 1 if result['status'] == 'failed' else 0


if __name__ == '__main__':
    raise SystemExit(main())
