#!/usr/bin/env python3
"""Four-process final-renderer storage comparison; synthetic input is not native evidence."""
import argparse
import hashlib
import json
from pathlib import Path
import importlib.util


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


C = module('renderer_drawing_pair', 'check-editable-drawing-pair.py')
N = C.N
KIND = 'renderer-final-storage'
STRATEGIES, CELLS, _ = C.comparison_contract(KIND)
COMPARISON_KINDS = tuple(kind for kind in C.COMPARISON_KINDS if kind != 'drawing-input')
POLICIES = tuple(C.RENDERER_POLICIES)
NATIVE_POLICIES = ('native', 'native-pooled')
OWNED_POLICIES = ('owned-srgb8', 'owned-pooled')
INTERVENTIONS = {
    KIND: 'combined final renderer storage and draw-only autorelease pool intervention',
    'renderer-autorelease-scope': 'whole-render autorelease pool with native destination and final makeImage',
    'renderer-final-storage-scoped': 'final destination allocation and snapshot storage under matched whole-render autorelease pools',
}


def comparison_contract(kind=KIND):
    N.need(kind in COMPARISON_KINDS, 'unknown renderer comparison kind')
    return C.comparison_contract(kind)
FILENAME = 'renderer-storage-pair.json'
MAX_BYTES = 256 * 1024
COUNTERS = {'attemptCount', 'nativeCount', 'eligibleCount', 'seedCount', 'drawCount', 'publishCount',
            'failureCount', 'allocations', 'deallocations', 'releaseCallbacks', 'allocatedBytes',
            'deallocatedBytes', 'callbackBytes', 'activeBytes', 'peakActiveBytes'}
OWNERSHIP = {'allocations', 'deallocations', 'releaseCallbacks', 'allocatedBytes',
             'deallocatedBytes', 'callbackBytes', 'activeBytes', 'peakActiveBytes'}


def snapshot(value, strategy, previous=None, released=False, allow_failures=False):
    N.keys(value, COUNTERS | {'unsupportedCounts', 'callbackSizesMatch'})
    C.renderer_autorelease_scope(strategy)
    for field in COUNTERS:
        N.integer(value[field])
    unsupported = value['unsupportedCounts']
    N.need(type(unsupported) is dict and set(unsupported) <= C.UNSUPPORTED, 'unknown renderer unsupported reason')
    for count in unsupported.values():
        N.integer(count, 1)
    N.integer(sum(unsupported.values()))
    N.need(value['callbackSizesMatch'] is True, 'renderer callback size mismatch')
    N.need(value['publishCount'] <= value['drawCount'] <= value['seedCount']
           <= value['nativeCount'] + value['eligibleCount'] <= value['attemptCount'], 'renderer stage counts disagree')
    N.need(value['publishCount'] + value['failureCount'] <= value['attemptCount'], 'renderer terminal counts disagree')
    N.need(value['allocations'] <= value['eligibleCount'] and value['deallocations'] <= value['allocations']
           and value['releaseCallbacks'] <= min(value['allocations'], value['drawCount']), 'renderer owner counts disagree')
    N.need(value['allocatedBytes'] - value['deallocatedBytes'] == value['activeBytes']
           and value['callbackBytes'] <= value['allocatedBytes']
           and value['activeBytes'] <= value['peakActiveBytes'] <= min(value['allocatedBytes'], 800_000_000),
           'renderer owned byte accounting disagrees')
    for field in ('allocatedBytes', 'deallocatedBytes', 'callbackBytes', 'activeBytes', 'peakActiveBytes'):
        N.need(value[field] % 4 == 0, 'renderer sRGB8 byte alignment differs')
    for count, size in (('allocations', 'allocatedBytes'), ('deallocations', 'deallocatedBytes'),
                        ('releaseCallbacks', 'callbackBytes')):
        N.need(4 * value[count] <= value[size] <= 400_000_000 * value[count], 'renderer byte totals do not cover work')
    for count, size in (('releaseCallbacks', 'callbackBytes'), ('deallocations', 'deallocatedBytes')):
        remaining_count = value['allocations'] - value[count]
        remaining_bytes = value['allocatedBytes'] - value[size]
        N.need(4 * remaining_count <= remaining_bytes <= 400_000_000 * remaining_count,
               'renderer allocation byte partition differs: ' + count)
    N.need((value['allocations'] == 0) == (value['peakActiveBytes'] == 0)
           and value['peakActiveBytes'] * value['allocations'] >= value['allocatedBytes'], 'renderer peak omits owned work')
    if not allow_failures:
        N.need(value['failureCount'] == 0, 'renderer failed during complete workload')
    if strategy in NATIVE_POLICIES:
        N.need(value['eligibleCount'] == 0 and not unsupported
               and all(value[field] == 0 for field in OWNERSHIP), 'native renderer performed owned storage work')
    else:
        N.need(value['nativeCount'] == sum(unsupported.values()), 'renderer silently used native fallback')
    if previous is not None:
        for field in COUNTERS - {'activeBytes'}:
            N.need(value[field] >= previous[field], 'renderer cumulative count moved backward: ' + field)
        for reason, count in previous['unsupportedCounts'].items():
            N.need(unsupported.get(reason, 0) >= count, 'renderer unsupported count moved backward')
    if released:
        N.need(value['attemptCount'] == value['publishCount'] + value['failureCount'], 'renderer attempt not terminal at release')
        N.need(value['activeBytes'] == 0 and value['allocations'] == value['deallocations']
               and value['allocatedBytes'] == value['deallocatedBytes'], 'renderer owner survived released endpoint')
        if not allow_failures:
            N.need(value['nativeCount'] + value['eligibleCount'] == value['attemptCount']
                   and value['eligibleCount'] == value['allocations'] == value['releaseCallbacks']
                   and value['allocatedBytes'] == value['callbackBytes'], 'renderer successful provider accounting differs')
    return value


def validate_sidecar(report, arm, raw_native, raw_drawing, strategy, comparison_kind=KIND):
    comparison_contract(comparison_kind)
    C.drawing_strategy(strategy, comparison_kind)
    N.keys(report, {'schemaVersion', 'status', *C.IDENTITY, 'executableBytes', 'comparisonKind',
        'rendererStorageStrategy', 'rendererAutoreleaseScope', 'drawingStrategy', 'productionDefaultStrategy', 'hashObservation',
        'nativeReportSHA256', 'drawingReportSHA256', 'maximumCheckpoints', 'additionalRasterObservations',
        'observationBoundary', 'checkpoints', 'productDefaultsChanged', 'privateFrameworkReleaseClaim', 'scope'})
    C.equal_int(report['schemaVersion'], 1, 'renderer schema')
    N.need(report['status'] == 'passed' and report['comparisonKind'] == comparison_kind, 'renderer sidecar status/kind differs')
    N.need(report['rendererStorageStrategy'] == strategy and report['drawingStrategy'] == 'owned-srgb8'
           and report['productionDefaultStrategy'] == 'native', 'renderer strategy/default differs')
    N.need(report['rendererAutoreleaseScope'] == C.renderer_autorelease_scope(strategy),
           'renderer autorelease scope differs')
    for key in (*C.IDENTITY, 'executableBytes'):
        N.need(type(report[key]) is type(arm['native'][key]) and report[key] == arm['native'][key], 'renderer identity differs: ' + key)
    N.need(report['hashObservation'] == ('vimage' if arm['native']['resourcesRequested'] else 'certify'), 'renderer observer differs')
    for field, data in [('nativeReportSHA256', raw_native), ('drawingReportSHA256', raw_drawing)]:
        N.need(report[field] == hashlib.sha256(data).hexdigest(), 'renderer bound to different bytes: ' + field)
    C.equal_int(report['maximumCheckpoints'], 256, 'renderer checkpoint cap')
    C.equal_int(report['additionalRasterObservations'], 0, 'renderer extra observation')
    N.need(report['observationBoundary'] == 'after-existing-drawing-checkpoint', 'renderer observation boundary differs')
    N.need(report['productDefaultsChanged'] is False and report['privateFrameworkReleaseClaim'] is False, 'renderer unsupported claim')
    N.string(report['scope'])
    points = report['checkpoints']
    drawing = arm['drawing']['checkpoints']
    N.need(type(points) is list and len(points) == len(drawing) <= 256, 'renderer checkpoint work differs')
    previous, entry = None, None
    for point, expected in zip(points, drawing):
        N.keys(point, {'workload', 'label', 'rendererStorage'})
        N.need((point['workload'], point['label']) == (expected['workload'], expected['label']), 'renderer checkpoints missing/reordered')
        state = snapshot(point['rendererStorage'], strategy, previous,
                         point['label'] in ('workload-released', 'final-cleanup'))
        if point['label'] == 'workload-entry':
            entry = state
        if point['label'] == 'workload-released':
            N.need(entry is not None, 'renderer workload entry missing')
            fields = ['attemptCount', 'seedCount', 'drawCount', 'publishCount',
                      'nativeCount' if strategy in NATIVE_POLICIES else 'eligibleCount']
            if strategy in OWNED_POLICIES:
                fields += ['allocations', 'releaseCallbacks', 'allocatedBytes']
            for field in fields:
                N.need(state[field] > entry[field], 'renderer path not exercised in every workload: ' + field)
        previous = state
    return report


def load_cell(directory, identity, strategy, mode, launcher_status=0, comparison_kind=KIND):
    comparison_contract(comparison_kind)
    arm = C.load_cell(directory, identity, strategy, mode, launcher_status, comparison_kind=comparison_kind)
    path = Path(arm['directory']) / FILENAME
    N.need(0 < path.lstat().st_size <= MAX_BYTES, 'renderer scalar sidecar exceeds bound')
    report = N.read_report(path)
    arm['rendererStorage'] = validate_sidecar(report, arm,
        (path.parent / 'editable-annotation-native.json').read_bytes(),
        (path.parent / 'editable-drawing-pair.json').read_bytes(), strategy, comparison_kind)
    arm['reportHashes']['rendererStorage'] = hashlib.sha256(path.read_bytes()).hexdigest()
    return arm


def compare(arms, stage, comparison_kind=KIND):
    comparison_contract(comparison_kind)
    result = C.compare(arms, stage, comparison_kind=comparison_kind)
    result.update(comparisonKind=comparison_kind, drawingStrategy='owned-srgb8', productionDefaultStrategy='native',
                  intervention=INTERVENTIONS[comparison_kind], matchedAutoreleaseScope=comparison_kind == 'renderer-final-storage-scoped')
    for name, arm in arms.items():
        for field in ('rendererStorageStrategy', 'rendererAutoreleaseScope', 'comparisonKind'):
            result['cells'][name][field] = arm['rendererStorage'][field]
    if stage == 'pair':
        for name in ('baseline', 'candidate'):
            result['arms'][name]['rendererStorageCheckpoints'] = arms[name]['rendererStorage']['checkpoints']
            result['arms'][name]['rendererStorageFinal'] = arms[name]['rendererStorage']['checkpoints'][-1]['rendererStorage']
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path); parser.add_argument('--expected-source', required=True)
    parser.add_argument('--comparison-kind', choices=COMPARISON_KINDS, default=KIND)
    parser.add_argument('--cell', type=Path); parser.add_argument('--strategy', choices=POLICIES)
    parser.add_argument('--mode', choices=('certify', 'resources')); parser.add_argument('--launcher-status', type=int, default=0)
    parser.add_argument('--root', type=Path); parser.add_argument('--stage', choices=('certification', 'pair'))
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    result = {'status': 'failed', 'memoryStabilityAssessed': False, 'productMemoryRemedyClaim': False}
    try:
        identity = N.bundle_identity(args.app, args.expected_source)
        if args.cell:
            N.need(args.root is None and args.stage is None, 'mixed cell/pair invocation')
            arm = load_cell(args.cell, identity, args.strategy, args.mode, args.launcher_status, args.comparison_kind)
            result.update(status='passed', comparisonKind=args.comparison_kind, sourceCommit=identity['sourceCommit'],
                executableSHA256=identity['executableSHA256'], architecture=identity['architecture'],
                processIdentifier=arm['native']['processIdentifier'], rendererStorageStrategy=args.strategy,
                rendererAutoreleaseScope=C.renderer_autorelease_scope(args.strategy),
                drawingStrategy='owned-srgb8', resourcesRequested=args.mode == 'resources',
                ownedExitConfirmed=True, visualFilesVerified=True, nativeExecutionAttestedByChecker=False,
                reportHashes=arm['reportHashes'])
        else:
            N.need(args.root is not None and args.stage is not None and args.strategy is None and args.mode is None,
                   'incomplete renderer pair invocation')
            _, cells, _ = comparison_contract(args.comparison_kind)
            selected = cells[:2] if args.stage == 'certification' else cells
            result = compare({name: load_cell(args.root / name, identity, strategy, mode, comparison_kind=args.comparison_kind)
                              for name, strategy, mode in selected}, args.stage, args.comparison_kind)
    except Exception as error:
        result['error'] = str(error)[:4096]
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True, allow_nan=False) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k not in ('arms', 'visualEvidence')}, indent=2, sort_keys=True, allow_nan=False))
    return 1 if result['status'] == 'failed' else 0


if __name__ == '__main__':
    raise SystemExit(main())
