#!/usr/bin/env python3
"""Two-process bounded scalar attribution; no cross-run memory comparison or remedy claim."""
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


C = module('substage_drawing_check', 'check-editable-drawing-pair.py')
E = module('substage_effect_check', 'check-effect-context-pair.py')
D = module('substage_strict_reader', 'check-drawing-raster-guard.py')
N, O, R = C.N, C.O, E.R
KIND = 'seed-render-crop'
FILENAME = 'seed-render-crop-substage.json'
MAX_BYTES = 256 * 1024
LABELS = ('after-native-crop', 'after-reference-full-render')
CELLS = (('certification', 'certify'), ('resources', 'resources'))
IDENTITY = (*C.IDENTITY, 'executableBytes')


def select(kind):
    N.need(type(kind) is str and kind == KIND, 'unknown substage observation kind')


def validate_sidecar(report, arm, raw_native, raw_drawing):
    N.keys(report, {'schemaVersion', 'status', *IDENTITY, 'probeKind', 'diagnosticOnly',
        'drawingStrategy', 'rendererStorageStrategy', 'rendererAutoreleaseScope', 'effectContextPolicy',
        'productionDefaultPolicy', 'hashObservation', 'nativeReportSHA256', 'drawingReportSHA256',
        'maximumCheckpoints', 'checkpointsPerWorkflow', 'additionalMemoryObservations', 'additionalRasterObservations',
        'metadataCheckpointCount', 'maximumMetadataCheckpoints', 'contextInitializationBoundary',
        'memoryObservationKind', 'existingMaterializedCropBoundary', 'existingMaterializedCropBoundaryHasFullBackingFields',
        'existingMaterializedCropBoundaryCounterCount', 'productDefaultsChanged', 'privateFrameworkReleaseClaim',
        'checkpoints', 'scope'})
    C.equal_int(report['schemaVersion'], 1, 'substage schema')
    select(report['probeKind'])
    N.need(report['status'] == 'passed' and report['diagnosticOnly'] is True, 'substage incomplete/not diagnostic')
    N.need(report['drawingStrategy'] == 'owned-srgb8' and report['rendererStorageStrategy'] == 'native'
           and report['rendererAutoreleaseScope'] == 'caller' and report['effectContextPolicy'] == 'reference'
           and report['productionDefaultPolicy'] == 'reference', 'substage fixed policies differ')
    for field in IDENTITY:
        N.need(type(report[field]) is type(arm['native'][field]) and report[field] == arm['native'][field],
               'substage identity differs: ' + field)
    resources = arm['native']['resourcesRequested']
    N.need(report['hashObservation'] == ('vimage' if resources else 'certify'), 'substage observer differs')
    for field, raw in [('nativeReportSHA256', raw_native), ('drawingReportSHA256', raw_drawing)]:
        N.need(report[field] == hashlib.sha256(raw).hexdigest(), 'substage bound to different raw bytes: ' + field)
    names = O.workload_names(resources)
    count = 2 * len(names)
    for field, expected in [('maximumCheckpoints', count), ('checkpointsPerWorkflow', 2),
            ('additionalMemoryObservations', count), ('additionalRasterObservations', 0),
            ('metadataCheckpointCount', len(arm['drawing']['checkpoints'])), ('maximumMetadataCheckpoints', 256),
            ('existingMaterializedCropBoundaryCounterCount', 8)]:
        C.equal_int(report[field], expected, field)
    N.need(report['contextInitializationBoundary'] == 'after-first-drawing-memory-before-native-entry'
           and report['memoryObservationKind'] == 'complete-O.memory-dictionary', 'substage memory/context boundary differs')
    N.need(report['existingMaterializedCropBoundary'] == 'reference-crop.before'
           and report['existingMaterializedCropBoundaryHasFullBackingFields'] is False,
           'existing pre-hash boundary must remain eight-counter-only')
    N.need(report['productDefaultsChanged'] is False and report['privateFrameworkReleaseClaim'] is False,
           'unsupported substage claim')
    N.string(report['scope'])
    points = report['checkpoints']
    N.need(type(points) is list and len(points) == count, 'substage checkpoints missing/extra')
    for index, (point, expected) in enumerate(zip(points, ((w, label) for w in names for label in LABELS)), 1):
        N.keys(point, {'index', 'workload', 'label', 'drawingCheckpointLabel', 'memory', 'drawing', 'rendererStorage', 'effectContext'})
        C.equal_int(point['index'], index, 'substage index')
        N.need((point['workload'], point['label']) == expected
               and point['drawingCheckpointLabel'] == 'seed-native-render-crop', 'substage checkpoints missing/reordered')
        C.complete_memory(point['memory'])
        N.need(len(json.dumps(point['memory'], separators=(',', ':'), allow_nan=False).encode()) <= 16 * 1024,
               'substage memory metadata exceeds bound')
    # Merge into the existing source-order states. All three cumulative trackers
    # must bridge the old stage, the two hooks, and the next old stage.
    indexed = {(p['workload'], p['label']): p for p in points}
    previous_drawing = previous_renderer = previous_effect = None
    previous_time = 0
    for drawing, effect in zip(arm['drawing']['checkpoints'], arm['effectContext']['checkpoints']):
        sequence = [dict(drawing, rendererStorage=effect['rendererStorage'], effectContext=effect['effectContext'])]
        if drawing['label'] == 'seed-native-render-crop':
            sequence += [indexed[(drawing['workload'], label)] for label in LABELS]
        for point in sequence:
            now = point['memory']['uptimeSeconds']
            N.need(now >= previous_time, 'substage memory chronology moved backward')
            previous_time = now
            released = point['label'] in ('workload-released', 'final-cleanup')
            C.drawing_snapshot(point['drawing'], 'owned-srgb8', previous_drawing, released)
            R.snapshot(point['rendererStorage'], 'native', previous_renderer, released)
            E.snapshot(point['effectContext'], 'reference', previous_effect, released)
            previous_drawing, previous_renderer, previous_effect = point['drawing'], point['rendererStorage'], point['effectContext']
    drawing_points = {(p['workload'], p['label']): p for p in arm['drawing']['checkpoints']}
    stages = {(p['workload'], p['label']): p for p in arm['diagnostic']['checkpoints']}
    hashes = {(p['workload'], p['label']): p for p in arm['diagnostic']['hashes']}
    for workload in names:
        seed = stages[(workload, 'seed-native-render-crop')]['observation']
        native_crop = indexed[(workload, LABELS[0])]['memory']
        full_render = indexed[(workload, LABELS[1])]['memory']
        materialized = hashes[(workload, 'reference-crop')]
        # This is the ACTUAL existing eight-counter sample, never a nearby full
        # backing dictionary. The lower observer validator refuses extra keys.
        O.observation(materialized['before'])
        timeline = [seed['uptimeSeconds']]
        for memory in (native_crop, full_render):
            timeline += [memory['backingAccounting'][flavor]['observedAtUptimeSeconds']
                         for flavor in ('standard', 'purgeable')] + [memory['uptimeSeconds']]
        for label in ('reference-crop', 'actual-crop', 'decorated-reference'):
            row = hashes[(workload, label)]
            timeline += [row['before']['uptimeSeconds'], row['after']['uptimeSeconds']]
        timeline += [drawing_points[(workload, 'history-save-reopen-decode')]['memory']['uptimeSeconds']]
        N.need(all(a <= b for a, b in zip(timeline, timeline[1:])), 'seed/render/materialized-crop/hash source chronology differs')
    C.observation_times(report, arm['lifecycle']['launchBeganUptimeSeconds'], arm['lifecycle']['finishUptimeSeconds'])
    return report


def load_cell(directory, identity, mode, launcher_status=0, *, observation_kind=KIND):
    select(observation_kind)
    arm = C.load_cell(directory, identity, 'owned-srgb8', mode, launcher_status, observation_kind=observation_kind)
    directory = Path(arm['directory'])
    for key, filename in {
            'native': 'editable-annotation-native.json', 'diagnostic': 'editable-annotation-observation.json',
            'drawing': 'editable-drawing-pair.json', 'launcher': 'launch.json.launcher.json',
            'wrapper': 'bounded-launch.json', 'envelope': 'launch.json'}.items():
        raw = D.read_bytes(directory / filename, N.MAX_BYTES)
        N.need(hashlib.sha256(raw).hexdigest() == arm['reportHashes'][key]
               and C.canonical_json(D.parse_json(raw)) == C.canonical_json(arm[key]),
               'substage validated report changed during binding: ' + key)
    arm['bundlePlistSHA256'] = hashlib.sha256(D.read_bytes(
        Path(identity['bundlePath']) / 'Contents/Info.plist', D.MAX_PLIST_BYTES)).hexdigest()
    raw_native = D.read_bytes(directory / 'editable-annotation-native.json', N.MAX_BYTES)
    raw_drawing = D.read_bytes(directory / 'editable-drawing-pair.json', N.MAX_BYTES)
    raw_effect = D.read_bytes(directory / E.FILENAME, E.MAX_BYTES)
    arm['effectContext'] = E.validate_sidecar(D.parse_json(raw_effect), arm, raw_native, raw_drawing, 'reference')
    raw_probe = D.read_bytes(directory / FILENAME, MAX_BYTES)
    arm['substage'] = validate_sidecar(D.parse_json(raw_probe), arm, raw_native, raw_drawing)
    arm['reportHashes'].update(effectContext=hashlib.sha256(raw_effect).hexdigest(), substage=hashlib.sha256(raw_probe).hexdigest())
    return arm


def metrics(arm):
    result = C.metrics(arm)
    result.update(earliestDrawingEntryMemory=arm['drawing']['checkpoints'][0]['memory'],
        earliestDrawingToFinalAccountingDelta=C.accounting_delta(arm['drawing']['checkpoints'][0]['memory'], arm['native']['finalMemory']),
        ownedLaunchElapsedSeconds=arm['launcher']['elapsedSeconds'], wrapperDurationSeconds=arm['lifecycle']['wrapperDurationSeconds'],
        processStartMemoryCaptured=False, substageCheckpoints=arm['substage']['checkpoints'],
        additionalMemoryObservations=arm['substage']['additionalMemoryObservations'], additionalRasterObservations=0)
    drawings = {(p['workload'], p['label']): p for p in arm['drawing']['checkpoints']}
    points = {(p['workload'], p['label']): p for p in arm['substage']['checkpoints']}
    hashes = {(p['workload'], p['label']): p for p in arm['diagnostic']['hashes']}
    result['seedRenderCropIntervals'] = []
    for workload in O.workload_names(arm['native']['resourcesRequested']):
        entry = drawings[(workload, 'seed-native-render-crop')]['memory']
        native_crop = points[(workload, LABELS[0])]['memory']
        full = points[(workload, LABELS[1])]['memory']
        crop = hashes[(workload, 'reference-crop')]['before']
        result['seedRenderCropIntervals'].append(dict(workload=workload,
            productionEditorShowAndCrop=dict(fromBoundary='seed-native-render-crop.drawing', toBoundary=LABELS[0],
                elapsedSeconds=native_crop['uptimeSeconds']-entry['uptimeSeconds'], accountingDelta=C.accounting_delta(entry, native_crop)),
            fixtureReferenceFullRender=dict(fromBoundary=LABELS[0], toBoundary=LABELS[1],
                elapsedSeconds=full['uptimeSeconds']-native_crop['uptimeSeconds'], accountingDelta=C.accounting_delta(native_crop, full)),
            fixtureMaterializedReferenceCrop=dict(fromBoundary=LABELS[1], toBoundary='reference-crop.before',
                elapsedSeconds=crop['uptimeSeconds']-full['uptimeSeconds'], counterDelta=N.delta(full, crop),
                existingPreHashObservation=crop, fullBackingFieldsAvailable=False)))
    result['observationOverheadScope'] = ('Two logical complete-memory samples per workflow, each with non-atomic standard and purgeable task-info reads, '
        'plus bounded scalar snapshot/JSON metadata. Their allocation and serialization costs remain in later measured intervals. '
        'No overhead subtraction. Probe/effect/drawing final sidecar serialization occurs after native finalMemory; '
        'owned launch and wrapper durations include it. No process-birth memory sample.')
    return result


def attribute(arms):
    N.need(set(arms) == {name for name, _ in CELLS}, 'exactly two fresh substage cells required')
    cert, resources = (arms[name] for name, _ in CELLS)
    N.need(cert['native']['resourcesRequested'] is False and resources['native']['resourcesRequested'] is True,
           'certification/resource workflow selection differs')
    for field in ('sourceCommit', 'executableSHA256', 'executableBytes', 'architecture', 'bundlePath', 'version', 'buildVersion'):
        N.need(cert['native'][field] == resources['native'][field], 'substage installed identity differs: ' + field)
    N.need(cert['bundlePlistSHA256'] == resources['bundlePlistSHA256'], 'substage bundle plist bytes differ')
    N.need(cert['native']['processIdentifier'] != resources['native']['processIdentifier'], 'substage cells require distinct process identifiers')
    N.need(cert['lifecycle']['finishUptimeSeconds'] <= resources['lifecycle']['launchBeganUptimeSeconds'],
           'fresh owned launches overlap or reordered')
    for (workload, label), value in resources['inputs'].items():
        reference = workload if workload.startswith('functional-') else 'functional-4k'
        N.need(value == cert['inputs'][(reference, label)], 'measured input differs from independently certified input')
    for workload, documents in resources['documents'].items():
        reference = workload if workload.startswith('functional-') else 'functional-4k'
        N.need(C.canonical_json(documents) == C.canonical_json(cert['documents'][reference]),
               'measured metadata differs from independently certified document')
    N.need(C.visual_work(cert['native']) == C.visual_work(resources['native']), 'certification/resource native geometry differs')
    return dict(schemaVersion=1, status='attributed', probeKind=KIND,
        **{field: cert['native'][field] for field in ('sourceCommit', 'executableSHA256', 'architecture')},
        exactCorrespondingRGBA=True, canonicalDocumentEquivalence=True, documentComparisonPolicy=C.DOCUMENT_POLICY,
        certificationWork=dict(functionalWorkloads=2, hashes=35, conversions=70, snapshots=4, documentPairs=2, additionalMemoryObservations=4),
        resourceWork=dict(functionalWorkloads=2, warmupWorkloads=2, measuredWorkloads=8, hashes=205, conversions=205, snapshots=4,
            documentPairs=12, additionalMemoryObservations=24),
        cells={name: dict(processIdentifier=arm['native']['processIdentifier'], bundlePlistSHA256=arm['bundlePlistSHA256'], reportHashes=arm['reportHashes'], **arm['lifecycle']) for name, arm in arms.items()},
        observations={name: metrics(arm) for name, arm in arms.items()},
        visualEvidence={name: arm['native']['functionalCases'][0]['visualEvidence'] for name, arm in arms.items()},
        nativeExecutionAttestedByChecker=False, memoryStabilityAssessed=False, productMemoryRemedyClaim=False,
        privateFrameworkReleaseClaim=False, crossRunMemorySubtraction=False, certificationExcludedFromEfficacyComparison=True,
        interpretation='Within-workflow endpoint attribution only. Production editor show/crop and fixture-only full rendering/materialized crop remain distinct. '
            'All native lifetime, cold, warmup, measured, late, cleanup, sampled and kernel peak values remain visible. '
            'The materialized crop endpoint has only its original eight counters. No nearby full-backing substitution, '
            'cross-run memory subtraction, private framework ownership, leak/stability, or memory-remedy claim.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path); parser.add_argument('--expected-source', required=True)
    parser.add_argument('--cell', type=Path); parser.add_argument('--mode', choices=('certify', 'resources'))
    parser.add_argument('--launcher-status', type=int, default=0); parser.add_argument('--root', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    result = dict(status='failed', memoryStabilityAssessed=False, productMemoryRemedyClaim=False)
    try:
        identity = N.bundle_identity(args.app, args.expected_source)
        if args.cell:
            N.need(args.root is None and args.mode is not None, 'mixed/incomplete substage cell invocation')
            arm = load_cell(args.cell, identity, args.mode, args.launcher_status)
            result.update(status='passed', probeKind=KIND, sourceCommit=identity['sourceCommit'],
                executableSHA256=identity['executableSHA256'], architecture=identity['architecture'],
                processIdentifier=arm['native']['processIdentifier'], resourcesRequested=args.mode == 'resources',
                additionalMemoryObservations=arm['substage']['additionalMemoryObservations'],
                ownedExitConfirmed=True, visualFilesVerified=True, nativeExecutionAttestedByChecker=False, bundlePlistSHA256=arm['bundlePlistSHA256'], reportHashes=arm['reportHashes'])
        else:
            N.need(args.root is not None and args.mode is None and args.launcher_status == 0, 'incomplete substage root invocation')
            result = attribute({name: load_cell(args.root / name, identity, mode) for name, mode in CELLS})
    except Exception as error:
        result['error'] = str(error)[:4096]
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True, allow_nan=False) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k not in ('observations', 'visualEvidence')}, indent=2, sort_keys=True, allow_nan=False))
    return 1 if result['status'] == 'failed' else 0


if __name__ == '__main__':
    raise SystemExit(main())
