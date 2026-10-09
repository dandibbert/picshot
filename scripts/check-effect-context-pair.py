#!/usr/bin/env python3
"""One finite four-process CI memory-target experiment; no native or memory verdict."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


C = module('effect_drawing_pair', 'check-editable-drawing-pair.py')
R = module('effect_native_renderer', 'check-renderer-storage-pair.py')
D = module('effect_strict_reader', 'check-drawing-raster-guard.py')
N = C.N
KIND = 'effect-context-memory-target'
POLICIES, CELLS, _ = C.comparison_contract(KIND)
FILENAME = 'effect-context-pair.json'
MAX_BYTES = 256 * 1024
COUNTERS = {'attemptCount', 'publishCount', 'failureCount'}


def comparison_contract(kind=KIND):
    N.need(kind == KIND, 'unknown effect comparison kind')
    return C.comparison_contract(kind)


def snapshot(value, policy, previous=None, released=False):
    N.need(type(policy) is str and policy in POLICIES, 'unknown effect policy')
    keys = COUNTERS | {'contextCount', 'contextOptionCount', 'configuredCacheIntermediates'}
    if policy == 'memory32':
        keys |= {'configuredMemoryTargetMegabytes'}
    N.keys(value, keys)
    C.equal_int(value['contextCount'], 1, 'immutable process context count')
    C.equal_int(value['contextOptionCount'], 2 if policy == 'memory32' else 1, 'effect context option count')
    N.need(value['configuredCacheIntermediates'] is False, 'effect cache intermediates option differs')
    if policy == 'memory32':
        C.equal_int(value['configuredMemoryTargetMegabytes'], 32, 'effect configured memory target')
    for field in COUNTERS:
        N.integer(value[field])
    N.need(value['publishCount'] + value['failureCount'] <= value['attemptCount'], 'effect terminal counts disagree')
    # The full workflow makes normal effect calls. The output guard injects its
    # nil failures outside this closure, so those refusals are not CI failures.
    C.equal_int(value['failureCount'], 0, 'normal effect failure count')
    if previous is not None:
        for field in COUNTERS:
            N.need(value[field] >= previous[field], 'effect cumulative count moved backward: ' + field)
    if released:
        N.need(value['attemptCount'] == value['publishCount'], 'effect attempt not terminal at released boundary')
    return value


def fixed_configuration(report, policy):
    N.need(report['effectContextPolicy'] == policy and report['productionDefaultPolicy'] == 'reference',
           'effect policy/default differs')
    N.need(report['drawingStrategy'] == 'owned-srgb8' and report['rendererStorageStrategy'] == 'native'
           and report['rendererAutoreleaseScope'] == 'caller' and report['rendererProductionDefaultStrategy'] == 'native',
           'fixed drawing/renderer policy differs')
    N.need(report['contextOwnershipScope'] == 'one-immutable-process-context', 'effect context ownership scope differs')


def validate_sidecar(report, arm, raw_native, raw_drawing, policy, comparison_kind=KIND):
    comparison_contract(comparison_kind)
    C.drawing_strategy(policy, comparison_kind)
    N.keys(report, {'schemaVersion', 'status', *C.IDENTITY, 'executableBytes', 'comparisonKind',
        'effectContextPolicy', 'productionDefaultPolicy', 'rendererStorageStrategy', 'rendererAutoreleaseScope',
        'rendererProductionDefaultStrategy', 'drawingStrategy', 'hashObservation', 'nativeReportSHA256',
        'drawingReportSHA256', 'maximumCheckpoints', 'additionalRasterObservations', 'additionalMemoryObservations',
        'observationBoundary', 'contextOwnershipScope', 'contextInitializationBoundary', 'checkpoints', 'productDefaultsChanged',
        'privateFrameworkReleaseClaim', 'scope'})
    C.equal_int(report['schemaVersion'], 1, 'effect sidecar schema')
    N.need(report['status'] == 'passed' and report['comparisonKind'] == KIND, 'effect sidecar status/kind differs')
    fixed_configuration(report, policy)
    for field in ('additionalRasterObservations', 'additionalMemoryObservations'):
        C.equal_int(report[field], 0, field)
    for field in (*C.IDENTITY, 'executableBytes'):
        N.need(type(report[field]) is type(arm['native'][field]) and report[field] == arm['native'][field],
               'effect identity differs: ' + field)
    N.need(report['hashObservation'] == ('vimage' if arm['native']['resourcesRequested'] else 'certify'), 'effect observer differs')
    for field, data in [('nativeReportSHA256', raw_native), ('drawingReportSHA256', raw_drawing)]:
        N.need(report[field] == hashlib.sha256(data).hexdigest(), 'effect bound to different bytes: ' + field)
    N.need(report['contextInitializationBoundary'] == 'after-first-drawing-memory-before-native-entry',
           'effect initialization boundary differs')
    C.equal_int(report['maximumCheckpoints'], 256, 'effect checkpoint cap')
    N.need(report['observationBoundary'] == 'after-existing-drawing-checkpoint', 'effect observation boundary differs')
    N.need(report['productDefaultsChanged'] is False and report['privateFrameworkReleaseClaim'] is False, 'unsupported effect claim')
    N.string(report['scope'])
    points = report['checkpoints']
    expected = arm['drawing']['checkpoints']
    N.need(type(points) is list and len(points) == len(expected) <= 256, 'effect checkpoint work differs')
    previous, previous_renderer, entry, renderer_entry = None, None, None, None
    for index, (point, drawing) in enumerate(zip(points, expected)):
        N.keys(point, {'workload', 'label', 'effectContext', 'rendererStorage'})
        N.need((point['workload'], point['label']) == (drawing['workload'], drawing['label']), 'effect checkpoints missing/reordered')
        released = point['label'] in ('workload-released', 'final-cleanup')
        state = snapshot(point['effectContext'], policy, previous, released)
        if index == 0:
            N.need(all(state[field] == 0 for field in COUNTERS),
                   'effect calls occurred before the earliest drawing memory checkpoint')
        renderer = R.snapshot(point['rendererStorage'], 'native', previous_renderer, released)
        if point['label'] == 'workload-entry':
            entry, renderer_entry = state, renderer
        if point['label'] == 'workload-released':
            N.need(entry is not None, 'effect workload entry missing')
            for field in ('attemptCount', 'publishCount'):
                N.need(state[field] > entry[field], 'normal effect path not exercised in every workload: ' + field)
            for field in ('attemptCount', 'nativeCount', 'seedCount', 'drawCount', 'publishCount'):
                N.need(renderer[field] > renderer_entry[field], 'native renderer not exercised in every workload: ' + field)
        previous, previous_renderer = state, renderer
    return report


def load_cell(directory, identity, policy, mode, launcher_status=0, comparison_kind=KIND):
    comparison_contract(comparison_kind)
    arm = C.load_cell(directory, identity, policy, mode, launcher_status, comparison_kind=comparison_kind)
    path = Path(arm['directory']) / FILENAME
    raw = D.read_bytes(path, MAX_BYTES)
    arm['effectContext'] = validate_sidecar(D.parse_json(raw), arm,
        D.read_bytes(path.parent / 'editable-annotation-native.json', N.MAX_BYTES),
        D.read_bytes(path.parent / 'editable-drawing-pair.json', N.MAX_BYTES), policy, comparison_kind)
    arm['reportHashes']['effectContext'] = hashlib.sha256(raw).hexdigest()
    return arm


def compare(arms, stage, comparison_kind=KIND):
    comparison_contract(comparison_kind)
    result = C.compare(arms, stage, comparison_kind=comparison_kind)
    N.need(len({arm['native']['processIdentifier'] for arm in arms.values()}) == len(arms), 'effect cells do not have distinct process identifiers')
    result.update(comparisonKind=KIND, drawingStrategy='owned-srgb8', rendererStorageStrategy='native',
        rendererAutoreleaseScope='caller', productionDefaultPolicy='reference',
        intervention='only CIContextOption.memoryTarget=32 megabytes on one immutable process effect context',
        memoryTargetIsProcessRSSCap=False)
    for name, arm in arms.items():
        for field in ('effectContextPolicy', 'rendererStorageStrategy', 'rendererAutoreleaseScope', 'comparisonKind'):
            result['cells'][name][field] = arm['effectContext'][field]
    if stage == 'pair':
        for name in ('baseline', 'candidate'):
            points = arms[name]['effectContext']['checkpoints']
            result['arms'][name]['effectContextCheckpoints'] = points
            result['arms'][name]['effectContextFinal'] = points[-1]['effectContext']
            result['arms'][name]['rendererStorageFinal'] = points[-1]['rendererStorage']
            # Existing earliest drawing memory predates first context access;
            # native entry follows that access and alone would hide cold setup.
            earliest = arms[name]['drawing']['checkpoints'][0]['memory']
            final = arms[name]['native']['finalMemory']
            result['arms'][name]['earliestDrawingEntryMemory'] = earliest
            result['arms'][name]['earliestDrawingToFinalAccountingDelta'] = C.accounting_delta(earliest, final)
            result['arms'][name]['ownedLaunchElapsedSeconds'] = arms[name]['launcher']['elapsedSeconds']
            result['arms'][name]['wrapperDurationSeconds'] = arms[name]['lifecycle']['wrapperDurationSeconds']
        result['candidateMinusBaseline']['earliestDrawingToFinalAccountingDifference'] = C.accounting_difference(
            result['arms']['baseline']['earliestDrawingToFinalAccountingDelta'],
            result['arms']['candidate']['earliestDrawingToFinalAccountingDelta'])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path); parser.add_argument('--expected-source', required=True)
    parser.add_argument('--comparison-kind', choices=(KIND,), default=KIND)
    parser.add_argument('--cell', type=Path); parser.add_argument('--policy', choices=POLICIES)
    parser.add_argument('--mode', choices=('certify', 'resources')); parser.add_argument('--launcher-status', type=int, default=0)
    parser.add_argument('--root', type=Path); parser.add_argument('--stage', choices=('certification', 'pair'))
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    result = {'status': 'failed', 'memoryStabilityAssessed': False, 'productMemoryRemedyClaim': False}
    try:
        identity = N.bundle_identity(args.app, args.expected_source)
        if args.cell:
            N.need(args.root is None and args.stage is None, 'mixed effect cell/pair invocation')
            arm = load_cell(args.cell, identity, args.policy, args.mode, args.launcher_status, args.comparison_kind)
            result.update(status='passed', comparisonKind=KIND, sourceCommit=identity['sourceCommit'],
                executableSHA256=identity['executableSHA256'], architecture=identity['architecture'],
                processIdentifier=arm['native']['processIdentifier'], effectContextPolicy=args.policy,
                drawingStrategy='owned-srgb8', rendererStorageStrategy='native', rendererAutoreleaseScope='caller',
                resourcesRequested=args.mode == 'resources', ownedExitConfirmed=True, visualFilesVerified=True,
                nativeExecutionAttestedByChecker=False, reportHashes=arm['reportHashes'])
        else:
            N.need(args.root is not None and args.stage is not None and args.policy is None and args.mode is None,
                   'incomplete effect pair invocation')
            selected = CELLS[:2] if args.stage == 'certification' else CELLS
            result = compare({name: load_cell(args.root / name, identity, policy, mode, comparison_kind=args.comparison_kind)
                              for name, policy, mode in selected}, args.stage, args.comparison_kind)
    except Exception as error:
        result['error'] = str(error)[:4096]
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True, allow_nan=False) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k not in ('arms', 'visualEvidence')}, indent=2, sort_keys=True, allow_nan=False))
    return 1 if result['status'] == 'failed' else 0


if __name__ == '__main__':
    raise SystemExit(main())
