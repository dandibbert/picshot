#!/usr/bin/env python3
"""Strict four-process drawing diagnostic. Synthetic tests are not native evidence."""
import argparse
import base64
import copy
import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import stat
import uuid


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


O = module('drawing_observation_check', 'check-editable-observation-comparison.py')
N = O.N
C = module('drawing_component_check', 'check-editable-components.py')
STRATEGIES = ('reference', 'owned-srgb8')
CELLS = [('baseline-certification', 'reference', 'certify'),
         ('candidate-certification', 'owned-srgb8', 'certify'),
         ('baseline', 'reference', 'resources'), ('candidate', 'owned-srgb8', 'resources')]
COMPARISON_KINDS = ('drawing-input', 'renderer-final-storage',
                    'renderer-autorelease-scope', 'renderer-final-storage-scoped',
                    'effect-context-memory-target')
RENDERER_POLICIES = {'native': 'caller', 'owned-srgb8': 'draw-only',
                     'native-pooled': 'whole-render', 'owned-pooled': 'whole-render'}


def comparison_contract(kind):
    # A closed contract, not mutable validation globals or caller-defined paths.
    N.need(kind in COMPARISON_KINDS, 'unknown comparison kind')
    if kind == 'drawing-input':
        return STRATEGIES, CELLS, 'scripts/launch-editable-drawing-pair.swift'
    strategies = {
        'renderer-final-storage': ('native', 'owned-srgb8'),
        'renderer-autorelease-scope': ('native', 'native-pooled'),
        'renderer-final-storage-scoped': ('native-pooled', 'owned-pooled'),
        'effect-context-memory-target': ('reference', 'memory32'),
    }[kind]
    baseline, candidate = strategies
    return strategies, [
        ('baseline-certification', baseline, 'certify'),
        ('candidate-certification', candidate, 'certify'),
        ('baseline', baseline, 'resources'), ('candidate', candidate, 'resources')
    ], ('scripts/launch-effect-context-pair.swift' if kind == 'effect-context-memory-target'
        else 'scripts/launch-renderer-storage-pair.swift')


SUBSTAGE_OBSERVATION_KIND = 'seed-render-crop'


def observation_contract(kind, strategy, comparison_kind):
    # A separate finite observation route, never an additional comparison arm.
    if kind is None:
        return
    N.need(kind == SUBSTAGE_OBSERVATION_KIND and type(kind) is str,
           'unknown substage observation kind')
    N.need(comparison_kind == 'drawing-input' and strategy == 'owned-srgb8',
           'substage observation requires fixed owned drawing and no comparison intervention')


def renderer_autorelease_scope(strategy):
    N.need(type(strategy) is str and strategy in RENDERER_POLICIES, 'unknown renderer strategy')
    return RENDERER_POLICIES[strategy]


def drawing_strategy(strategy, kind):
    strategies, _, _ = comparison_contract(kind)
    N.need(strategy in strategies, 'unknown comparison strategy')
    return strategy if kind == 'drawing-input' else 'owned-srgb8'


DRAWING_INTEGERS = {'referenceCount', 'eligibleCount', 'ownedCount', 'seededContextCount',
    'presentationReuseCount', 'presentationFallbackCount', 'failureCount', 'allocations',
    'deallocations', 'releaseCallbacks', 'allocatedBytes', 'deallocatedBytes', 'callbackBytes',
    'activeBytes', 'peakActiveBytes', 'seededContextBytes'}
UNSUPPORTED = {'imageMask', 'decodeArray', 'colorSpace', 'floatingPoint', 'componentDepth',
               'channelLayout', 'byteOrder', 'bitmapFlags'}
BACKING_BYTES = {'virtual_size', 'resident_size', 'resident_size_peak', 'device', 'device_peak',
    'internal', 'internal_peak', 'external', 'external_peak', 'reusable', 'reusable_peak',
    'compressed', 'compressed_peak', 'compressed_lifetime', 'phys_footprint'}
VOLATILE_BYTES = {'purgeable_volatile_pmap', 'purgeable_volatile_resident', 'purgeable_volatile_virtual'}
BACKING_LEDGERS = {'ledger_phys_footprint_peak', 'ledger_purgeable_nonvolatile',
    'ledger_purgeable_novolatile_compressed', 'ledger_purgeable_volatile',
    'ledger_purgeable_volatile_compressed', *{'ledger_tag_' + category + '_' + kind
        for category in ('graphics', 'media')
        for kind in ('footprint', 'footprint_compressed', 'nofootprint', 'nofootprint_compressed')}}
IDENTITY = ('sourceCommit', 'executableSHA256', 'architecture', 'processIdentifier', 'resourcesRequested')
CASE_COMPARE = (N.CASE_FIELDS - {'visualEvidence', 'ownershipAfterRelease', 'documentSHA256', 'appliedDocumentSHA256'})
UUID_ROOTS = ('documentID', 'originalAssetID', 'baseAssetID')
UUID_LINKS = ('groupID', 'additionID', 'rootAdditionID')
DOCUMENT_POLICY = {
    'version': 1,
    'ephemeralUUIDPaths': ['$.documentID', '$.originalAssetID', '$.baseAssetID', '$.annotations[*].id',
        '$.annotations[*].mosaicLink.groupID', '$.annotations[*].mosaicLink.additionID', '$.annotations[*].mosaicLink.rootAdditionID'],
    'sessionDatePaths': ['$.capturedAt only when captureTimestampKnown=false',
        '$.annotations[7].frozenTimestamp in applied document only when timestampIsCaptureDate=false'],
    'preserved': 'All other keys and values, annotation order, UUID equality/linkage within original+applied, known timestamps, first seven frozen timestamps, timestamp flags and time zones; session dates must be inside this process wall-clock bounds. Raw SHA fidelity is separately checked against native assertions.'}


def equal_int(value, expected, label):
    N.need(N.integer(value) == expected, label + ' changed')


def complete_memory(value):
    N.observation(value)
    for flavor in ('standard', 'purgeable'):
        part = value['backingAccounting'][flavor]
        N.keys(part['bytes'], BACKING_BYTES | (VOLATILE_BYTES if flavor == 'purgeable' else set()))
        N.keys(part['ledgerBytes'], BACKING_LEDGERS)


def all_memory(value):
    """Recheck every native/sidecar full accounting record, not just flattened RSS."""
    if type(value) is dict:
        if 'backingAccounting' in value:
            complete_memory(value)
        else:
            for child in value.values():
                all_memory(child)
    elif type(value) is list:
        for child in value:
            all_memory(child)


def observation_times(value, began, finished):
    if type(value) is dict:
        for key, child in value.items():
            if key in ('uptimeSeconds', 'observedAtUptimeSeconds'):
                N.number(child, began, finished)
            else:
                observation_times(child, began, finished)
    elif type(value) is list:
        for child in value:
            observation_times(child, began, finished)


def native_memory_timeline(native):
    ordered = [native['entryMemory']] + [c['afterReleaseMemory'] for c in native['functionalCases']]
    if native['resourcesRequested']:
        resources = native['resources']
        ordered += [resources['beforeWarmup']]
        ordered += [value for cycle in resources['warmups'] for value in (cycle['beforeMemory'], cycle['afterMemory'])]
        ordered += [resources['afterWarmupBaseline']]
        ordered += [value for cycle in resources['cycles'] for value in (cycle['beforeMemory'], cycle['afterMemory'])]
        ordered += [resources['afterMeasuredCycles']]
    ordered += [native['finalMemory']]
    N.need(all(a['uptimeSeconds'] <= b['uptimeSeconds'] for a, b in zip(ordered, ordered[1:])),
           'native cold/warmup/measured/cleanup memory chronology differs')
    for shot in native['functionalCases'][0]['visualEvidence']:
        N.number(shot['whileSnapshotLiveMemory']['uptimeSeconds'], native['entryMemory']['uptimeSeconds'],
                 native['functionalCases'][0]['afterReleaseMemory']['uptimeSeconds'])


def cases(native):
    result = dict(zip(('functional-small', 'functional-4k'), native['functionalCases']))
    if native['resourcesRequested']:
        result.update({f"{case['phase']}-{case['index']}": case
                       for case in native['resources']['warmups'] + native['resources']['cycles']})
    return result


def drawing_snapshot(value, strategy, previous=None, released=False):
    N.keys(value, DRAWING_INTEGERS | {'unsupportedCounts', 'callbackSizesMatch'})
    for field in DRAWING_INTEGERS:
        N.integer(value[field])
    N.need(type(value['unsupportedCounts']) is dict and set(value['unsupportedCounts']) <= UNSUPPORTED,
           'unknown drawing unsupported reason')
    for count in value['unsupportedCounts'].values():
        N.integer(count, 1)
    N.need(value['callbackSizesMatch'] is True, 'provider release callback size differs')
    N.need(value['failureCount'] == value['presentationFallbackCount'] == 0, 'drawing failed or silently fell back')
    N.need(value['deallocations'] <= value['allocations'] and value['releaseCallbacks'] <= value['allocations'],
           'drawing allocation/release counts disagree')
    N.need(value['allocatedBytes'] - value['deallocatedBytes'] == value['activeBytes']
           and value['callbackBytes'] <= value['allocatedBytes']
           and value['activeBytes'] <= value['peakActiveBytes'] <= 800_000_000, 'owned byte accounting disagrees')
    # Reserve, publish, provider callback and deinit are distinct lock-protected
    # updates. A checkpoint can observe a valid operation in progress. Require
    # completed equality at released endpoints rather than inventing atomicity.
    N.need(value['allocations'] >= value['ownedCount'], 'successful owned providers exceed allocations')
    N.need(value['eligibleCount'] >= value['ownedCount'] + value['seededContextCount'], 'eligible drawing count differs')
    N.need((value['seededContextCount'] == 0) == (value['seededContextBytes'] == 0), 'seeded byte work omitted')
    N.need((value['allocations'] == 0) == (value['allocatedBytes'] == 0), 'owned byte work omitted')
    if strategy == 'reference':
        N.need(all(value[field] == 0 for field in DRAWING_INTEGERS - {'referenceCount', 'presentationReuseCount'})
               and value['unsupportedCounts'] == {}, 'reference performed candidate drawing work')
    else:
        N.need(value['referenceCount'] == 0, 'candidate used reference strategy')
    if previous is not None:
        for field in DRAWING_INTEGERS - {'activeBytes'}:
            N.need(value[field] >= previous[field], 'drawing cumulative count moved backward: ' + field)
        for reason, count in previous['unsupportedCounts'].items():
            N.need(value['unsupportedCounts'].get(reason, 0) >= count, 'unsupported count moved backward')
    if released:
        N.need(value['activeBytes'] == 0 and value['allocations'] == value['deallocations'] == value['releaseCallbacks']
               and value['allocatedBytes'] == value['deallocatedBytes'] == value['callbackBytes']
               and value['allocations'] == value['ownedCount']
               and value['eligibleCount'] == value['ownedCount'] + value['seededContextCount'],
               'owned drawing provider survived released endpoint')


def parse_document(encoded):
    N.need(type(encoded) is str and 0 < len(encoded) <= 174_764, 'document base64 exceeds bound')
    raw = base64.b64decode(encoded, validate=True)
    N.need(0 < len(raw) <= 131_072 and base64.b64encode(raw).decode() == encoded, 'document byte bound/encoding differs')
    value = json.loads(raw, object_pairs_hook=N.strict_pairs,
                      parse_constant=lambda _: (_ for _ in ()).throw(ValueError('nonfinite document JSON')))
    N.need(type(value) is dict, 'document is not an object')
    # parse_constant rejects NaN/Infinity tokens; this also rejects a finite JSON
    # spelling (such as 1e9999) that overflowed Python's floating-point parser.
    canonical_json(value)
    return value, raw


def canonical_json(value):
    # Python's ordinary container equality conflates True with 1. Preserve JSON
    # types and all undeclared fields when comparing meaningful document values.
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False)


def canonical_documents(original, applied, bounds):
    """Only these schema paths can change. No recursive dropping of id/date keys."""
    identities, session_dates = {}, {}
    def identity(value):
        N.need(type(value) is str and str(uuid.UUID(value)).lower() == value.lower(), 'invalid document UUID')
        # Preserve cross-role, cross-annotation and original/applied equality topology.
        key = value.lower()
        if key not in identities:
            identities[key] = 'ephemeral-uuid-' + str(len(identities))
        return identities[key]
    def session_date(value):
        N.number(value, bounds['beganReferenceDateSeconds'], bounds['finishedReferenceDateSeconds'])
        if value not in session_dates:
            session_dates[value] = 'session-date-' + str(len(session_dates))
        return session_dates[value]
    result = []
    for document, count in ((original, 7), (applied, 8)):
        value = copy.deepcopy(document)
        N.need(value.get('format') == 'picshot.editable-annotations' and type(value.get('version')) is int
               and value['version'] == 1 and value.get('coordinates') == 'image-pixels-bottom-left', 'wrong editable document schema')
        for key in UUID_ROOTS:
            value[key] = identity(value[key])
        N.need(type(value['annotations']) is list and len(value['annotations']) == count, 'document annotation work changed')
        N.need(type(value['captureTimestampKnown']) is bool, 'invalid capture timestamp flag')
        N.number(value['capturedAt'], -(2**53), 2**53)
        if value['captureTimestampKnown'] is False:
            value['capturedAt'] = session_date(value['capturedAt'])
        for index, annotation in enumerate(value['annotations']):
            N.need(type(annotation) is dict, 'annotation is not an object')
            annotation['id'] = identity(annotation['id'])
            if annotation.get('mosaicLink') is not None:
                for key in UUID_LINKS:
                    annotation['mosaicLink'][key] = identity(annotation['mosaicLink'][key])
            N.need(type(annotation['timestampIsCaptureDate']) is bool, 'invalid annotation timestamp flag')
            N.number(annotation['frozenTimestamp'], -(2**53), 2**53)
            if index == 7 and count == 8 and annotation['timestampIsCaptureDate'] is False:
                annotation['frozenTimestamp'] = session_date(annotation['frozenTimestamp'])
        result.append(value)
    return result


def validate_pair_sidecar(pair, native, native_bytes, diagnostic, strategy, resources):
    N.keys(pair, {'schemaVersion', 'status', *IDENTITY, 'drawingStrategy', 'hashObservation',
        'nativeReportSHA256', 'maximumCheckpoints', 'maximumDocuments', 'maximumDocumentBytes',
        'sessionDateBounds', 'checkpoints', 'documents', 'productDefaultsChanged', 'privateFrameworkReleaseClaim', 'scope'})
    equal_int(pair['schemaVersion'], 1, 'pair schema')
    N.need(pair['status'] == 'passed' and strategy in STRATEGIES and pair['drawingStrategy'] == strategy, 'pair strategy/status differs')
    for field in IDENTITY:
        N.need(type(pair[field]) is type(native[field]) and pair[field] == native[field], 'pair identity differs: ' + field)
    N.need(pair['resourcesRequested'] is resources and pair['hashObservation'] == ('vimage' if resources else 'certify'), 'pair observer/work changed')
    N.need(pair['nativeReportSHA256'] == hashlib.sha256(native_bytes).hexdigest(), 'pair bound to different native bytes')
    for key, expected in [('maximumCheckpoints', 256), ('maximumDocuments', 12), ('maximumDocumentBytes', 131_072)]:
        equal_int(pair[key], expected, key)
    N.need(pair['productDefaultsChanged'] is False and pair['privateFrameworkReleaseClaim'] is False, 'unsupported product/release claim')
    N.string(pair['scope'])
    bounds = pair['sessionDateBounds']
    N.keys(bounds, {'beganReferenceDateSeconds', 'finishedReferenceDateSeconds'})
    start = N.number(bounds['beganReferenceDateSeconds'])
    N.number(bounds['finishedReferenceDateSeconds'], start, start + 600)
    points = pair['checkpoints']
    expected = [('entry', 'native-entry')] + [(p['workload'], p['label']) for p in diagnostic['checkpoints']]
    N.need(type(points) is list and len(points) == len(expected) <= 256
           and [(p.get('workload'), p.get('label')) for p in points] == expected, 'drawing stages missing/reordered')
    previous, last_time, workload_entry = None, 0, None
    for index, point in enumerate(points):
        N.keys(point, {'workload', 'label', 'memory', 'drawing'})
        complete_memory(point['memory'])
        now = point['memory']['uptimeSeconds']
        N.need(now >= last_time, 'drawing checkpoint clock moved backward')
        last_time = now
        if index:
            # Pair checkpoint occurs immediately before the unchanged observer checkpoint.
            N.need(now <= diagnostic['checkpoints'][index - 1]['observation']['uptimeSeconds'], 'drawing/hash stage order differs')
        state = point['drawing']
        drawing_snapshot(state, strategy, previous, point['label'] in ('workload-released', 'final-cleanup'))
        if point['label'] == 'workload-entry':
            workload_entry = state
        if point['label'] == 'workload-released':
            N.need(workload_entry is not None, 'drawing workload entry missing')
            fields = ('referenceCount',) if strategy == 'reference' else ('ownedCount', 'seededContextCount')
            for field in fields:
                N.need(state[field] > workload_entry[field], 'drawing path not exercised in every workload: ' + field)
        previous = state
    N.need(points[0]['memory']['uptimeSeconds'] <= native['entryMemory']['uptimeSeconds']
           and points[-1]['memory']['uptimeSeconds'] <= native['finalMemory']['uptimeSeconds'], 'drawing checkpoints outside native endpoints')
    names = O.workload_names(resources)
    documents = pair['documents']
    N.need(type(documents) is list and len(documents) == len(names), 'document workloads incomplete')
    normalized = {}
    for row, workload in zip(documents, names):
        N.keys(row, {'workload', 'originalBase64', 'appliedBase64'})
        N.need(row['workload'] == workload, 'document workload order changed')
        original, original_bytes = parse_document(row['originalBase64'])
        applied, applied_bytes = parse_document(row['appliedBase64'])
        case = cases(native)[workload]
        N.need(hashlib.sha256(original_bytes).hexdigest() == case['documentSHA256']
               and hashlib.sha256(applied_bytes).hexdigest() == case['appliedDocumentSHA256'], 'raw document fidelity differs from native assertion')
        # This fixture adds one rectangle. The retained seven layers and all
        # document metadata must stay byte-value faithful within the process,
        # including IDs and generated dates; normalization is cross-run only.
        N.need(type(original.get('annotations')) is list and len(original['annotations']) == 7
               and type(applied.get('annotations')) is list and len(applied['annotations']) == 8,
               'raw document layer counts differ')
        N.need(canonical_json(original['annotations']) == canonical_json(applied['annotations'][:7])
               and canonical_json({k: v for k, v in original.items() if k != 'annotations'})
               == canonical_json({k: v for k, v in applied.items() if k != 'annotations'}),
               'retained document metadata changed within process')
        N.need(applied['annotations'][7].get('tool') == 'rectangle', 'applied native rectangle missing')
        normalized[workload] = canonical_documents(original, applied, bounds)
    return normalized


def validate_launch(launcher, wrapper, envelope, native, identity, directory, strategy, mode, comparison_kind='drawing-input', *, observation_kind=None):
    observation_contract(observation_kind, strategy, comparison_kind)
    _, _, launch_script = comparison_contract(comparison_kind)
    expected_drawing = drawing_strategy(strategy, comparison_kind)
    extra_fields = {'rendererStorageStrategy', 'comparisonKind', 'rendererAutoreleaseScope'} if comparison_kind != 'drawing-input' else set()
    if comparison_kind == 'effect-context-memory-target':
        extra_fields |= {'effectContextPolicy'}
    if observation_kind is not None:
        launch_script = 'scripts/launch-seed-render-crop-substage.swift'
        extra_fields |= {'substageProbe', 'rendererStorageStrategy', 'rendererAutoreleaseScope', 'effectContextPolicy'}
    N.keys(launcher, {'schemaVersion', 'status', 'launcherExitCode', 'drawingStrategy', 'drawingMode',
        'hashObservation', 'selectedAppPath', 'createsNewApplicationInstance', 'timeoutSeconds', 'elapsedSeconds',
        'launchBeganUptimeSeconds', 'finishUptimeSeconds', 'callbackReceived', 'ownedExitConfirmed',
        'processStartMemoryCaptured', 'scope', 'processIdentifier', 'launchedAppPath', 'launchedExecutablePath', *extra_fields})
    for key, expected in [('schemaVersion', 1), ('launcherExitCode', 0), ('processIdentifier', native['processIdentifier'])]:
        equal_int(launcher[key], expected, 'launcher ' + key)
    N.need(launcher['status'] == 'exited' and launcher['callbackReceived'] is True
           and launcher['ownedExitConfirmed'] is True and launcher['createsNewApplicationInstance'] is True,
           'fresh owned application exit unverified')
    N.need(launcher['processStartMemoryCaptured'] is False, 'launcher incorrectly claims birth memory')
    if observation_kind is not None:
        N.need(launcher['substageProbe'] == observation_kind
               and launcher['rendererStorageStrategy'] == 'native'
               and launcher['rendererAutoreleaseScope'] == 'caller'
               and launcher['effectContextPolicy'] == 'reference', 'launcher fixed substage selection differs')
    elif comparison_kind == 'effect-context-memory-target':
        N.need(launcher['effectContextPolicy'] == strategy and launcher['comparisonKind'] == comparison_kind,
               'launcher effect context selection differs')
        N.need(launcher['rendererStorageStrategy'] == 'native' and launcher['rendererAutoreleaseScope'] == 'caller',
               'launcher fixed renderer selection differs')
    elif comparison_kind != 'drawing-input':
        N.need(launcher['rendererStorageStrategy'] == strategy and launcher['comparisonKind'] == comparison_kind,
               'launcher renderer storage selection differs')
        N.need(launcher['rendererAutoreleaseScope'] == renderer_autorelease_scope(strategy),
               'launcher renderer autorelease scope differs')
    N.need(launcher['drawingStrategy'] == expected_drawing and launcher['drawingMode'] == mode
           and launcher['hashObservation'] == ('certify' if mode == 'certify' else 'vimage'), 'launcher selection differs')
    executable = str(Path(identity['bundlePath']) / 'Contents/MacOS/PicShot')
    N.need(launcher['selectedAppPath'] == launcher['launchedAppPath'] == identity['bundlePath']
           and launcher['launchedExecutablePath'] == executable, 'owned app/executable path differs')
    N.need(N.number(launcher['timeoutSeconds']) == 600 and 0 < N.number(launcher['elapsedSeconds'], 0, 600), 'owned timeout changed/exceeded')
    began = N.number(launcher['launchBeganUptimeSeconds'])
    finished = N.number(launcher['finishUptimeSeconds'], began, began + 600)
    N.need(began <= native['entryMemory']['uptimeSeconds'] <= native['finalMemory']['uptimeSeconds'] <= finished
           and launcher['elapsedSeconds'] + .1 >= native['elapsedSeconds'], 'native work outside owned lifecycle')
    N.string(launcher['scope'])
    N.keys(envelope, {*native, 'arguments'})
    N.need(envelope['arguments'] == [executable] and {k: v for k, v in envelope.items() if k != 'arguments'} == native,
           'smoke envelope/argv differs from native report')
    N.keys(wrapper, {'schema_version', 'status', 'command', 'started_at', 'timeout_seconds', 'grace_seconds',
        'max_log_bytes', 'pid', 'child_returncode', 'exit_code', 'cancel_signal', 'sigterm_sent', 'sigkill_sent',
        'descendant_cleanup', 'output_bytes', 'log_bytes', 'log_truncated', 'termination_reason', 'duration_seconds', 'group_observation'})
    for key, expected in [('schema_version', 1), ('child_returncode', 0), ('exit_code', 0), ('max_log_bytes', N.MAX_BYTES)]:
        equal_int(wrapper[key], expected, 'wrapper ' + key)
    N.need(wrapper['status'] == wrapper['termination_reason'] == 'exited' and wrapper['cancel_signal'] is None,
           'bounded command did not exit normally')
    for key in ('sigterm_sent', 'sigkill_sent', 'descendant_cleanup'):
        N.need(wrapper[key] is False, 'bounded command needed cleanup')
    N.need(N.number(wrapper['timeout_seconds']) == 620 and N.number(wrapper['grace_seconds']) == 5, 'wrapper deadline changed')
    N.integer(wrapper['pid'], 1, 2**31 - 1)
    output = N.integer(wrapper['output_bytes'])
    log_size = N.integer(wrapper['log_bytes'], 0, N.MAX_BYTES)
    N.need(log_size == min(output, N.MAX_BYTES) and wrapper['log_truncated'] is (output > log_size), 'wrapper log accounting differs')
    log = directory / 'launcher.log'
    info = log.lstat()
    N.need(stat.S_ISREG(info.st_mode) and info.st_size == log_size, 'bounded launcher log missing/linked/size differs')
    duration = N.number(wrapper['duration_seconds'], 0, 620)
    N.need(duration > 0 and duration + .1 >= launcher['elapsedSeconds'], 'wrapper interval shorter than launch')
    C.validate_group_observation(wrapper['group_observation'], duration)
    command = ['swift', launch_script, identity['bundlePath'], str(directory / 'launch.json'), strategy, mode]
    commands = [command] if comparison_kind == 'drawing-input' else [command + [comparison_kind]]
    if comparison_kind == 'renderer-final-storage':
        commands.append(command)  # Preserve original default launcher invocations.
    if observation_kind is not None:
        commands = [['swift', launch_script, identity['bundlePath'], str(directory / 'launch.json'), mode]]
    N.need(wrapper['command'] in commands, 'bounded command selection differs')
    N.string(wrapper['started_at'])
    start = datetime.datetime.fromisoformat(wrapper['started_at'])
    N.need(start.tzinfo is not None and start.utcoffset() == datetime.timedelta(0), 'wrapper start is not UTC')
    return {'launchBeganUptimeSeconds': began, 'finishUptimeSeconds': finished,
            'wrapperStartEpochSeconds': start.timestamp(), 'wrapperDurationSeconds': duration}


def load_cell(directory, identity, strategy, mode, launcher_status=0, comparison_kind='drawing-input', *, observation_kind=None):
    observation_contract(observation_kind, strategy, comparison_kind)
    expected_drawing = drawing_strategy(strategy, comparison_kind)
    N.need(mode in ('certify', 'resources'), 'unknown pair selection')
    equal_int(launcher_status, 0, 'invoked launcher exit')
    directory = Path(directory).absolute()
    N.need(directory.resolve(strict=True) == directory and directory.is_dir(), 'evidence directory linked/missing')
    paths = {key: directory / filename for key, filename in {
        'native': 'editable-annotation-native.json', 'diagnostic': 'editable-annotation-observation.json',
        'drawing': 'editable-drawing-pair.json', 'launcher': 'launch.json.launcher.json',
        'wrapper': 'bounded-launch.json', 'envelope': 'launch.json'}.items()}
    values = {key: N.read_report(path) for key, path in paths.items()}
    native = values['native']; resources = mode == 'resources'
    checked = N.validate(native, identity, resources, values['launcher']['processIdentifier'], directory)
    N.need(checked['visualFilesVerified'] is True, 'native screenshots not independently verified')
    native_bytes = paths['native'].read_bytes()
    inputs = O.validate_diagnostic(values['diagnostic'], native, native_bytes, 'vimage' if resources else 'certify', resources)
    documents = validate_pair_sidecar(values['drawing'], native, native_bytes, values['diagnostic'], expected_drawing, resources)
    all_memory(native)
    native_memory_timeline(native)
    lifecycle = validate_launch(values['launcher'], values['wrapper'], values['envelope'], native, identity, directory, strategy, mode, comparison_kind, observation_kind=observation_kind)
    for key in ('native', 'diagnostic', 'drawing'):
        observation_times(values[key], lifecycle['launchBeganUptimeSeconds'], lifecycle['finishUptimeSeconds'])
    bounds = values['drawing']['sessionDateBounds']
    # Foundation's reference epoch is 2001-01-01. Wall clocks may drift, so no
    # equality with monotonic time is claimed; only the containing wrapper is bound.
    start = lifecycle['wrapperStartEpochSeconds'] - 978_307_200
    N.need(start - 1 <= bounds['beganReferenceDateSeconds'] <= bounds['finishedReferenceDateSeconds']
           <= start + lifecycle['wrapperDurationSeconds'] + 1, 'session date bounds outside fresh process')
    return {**values, 'inputs': inputs, 'documents': documents, 'lifecycle': lifecycle,
            'reportHashes': {key: hashlib.sha256(path.read_bytes()).hexdigest() for key, path in paths.items()},
            'directory': str(directory)}


def visual_work(native):
    excluded = {'sha256', 'rgbaSHA256', 'byteCount', 'whileSnapshotLiveMemory', 'scope'}
    return {s['filename']: {k: v for k, v in s.items() if k not in excluded}
            for s in native['functionalCases'][0]['visualEvidence']}


def compare_work(first, second):
    N.need(first['inputs'] == second['inputs'], 'corresponding actual input/intermediate/output RGBA, dimensions or metadata differ')
    N.need(canonical_json(first['documents']) == canonical_json(second['documents']), 'canonical editable documents differ')
    for workload, case in cases(first['native']).items():
        other = cases(second['native'])[workload]
        N.need({k: case[k] for k in CASE_COMPARE} == {k: other[k] for k in CASE_COMPARE}, 'native case work/source/PNG/output differs: ' + workload)
    for key in ('hashCount', 'conversionCount', 'totalNormalizedBytes', 'snapshotCount', 'normalizedFormat'):
        N.need(first['diagnostic'][key] == second['diagnostic'][key], 'normalization work differs: ' + key)
    N.need(visual_work(first['native']) == visual_work(second['native']), 'cross-process screenshot geometry/native work differs')


def accounting_delta(before, after):
    return {'counters': N.delta(before, after), 'backingAccounting': {
        flavor: {kind: {key: after['backingAccounting'][flavor][kind][key] - count
                        for key, count in before['backingAccounting'][flavor][kind].items()}
                 for kind in ('bytes', 'ledgerBytes')} for flavor in ('standard', 'purgeable')}}


def accounting_difference(baseline, candidate):
    return {'counters': {key: candidate['counters'][key] - baseline['counters'][key] for key in N.MEMORY},
        'backingAccounting': {flavor: {kind: {
            key: candidate['backingAccounting'][flavor][kind][key] - value
            for key, value in baseline['backingAccounting'][flavor][kind].items()}
            for kind in ('bytes', 'ledgerBytes')} for flavor in ('standard', 'purgeable')}}


def metrics(arm):
    native, pair = arm['native'], arm['drawing']
    output = O.metrics(arm)
    output.update(entryMemory=native['entryMemory'], finalMemory=native['finalMemory'],
        entryToFinalAccountingDelta=accounting_delta(native['entryMemory'], native['finalMemory']),
        sampledMemory=native['sampledMemory'], drawingCheckpoints=pair['checkpoints'],
        functionalReleaseMemory={c['profile']: c['afterReleaseMemory'] for c in native['functionalCases']},
        snapshotWhileLiveMemory={s['filename']: s['whileSnapshotLiveMemory'] for s in native['functionalCases'][0]['visualEvidence']},
        ownedDrawingFinal=pair['checkpoints'][-1]['drawing'])
    if native['resourcesRequested']:
        r = native['resources']
        output.update(beforeWarmupMemory=r['beforeWarmup'], afterWarmupMemory=r['afterWarmupBaseline'],
            afterMeasuredMemory=r['afterMeasuredCycles'],
            warmupMemory=[{'before': c['beforeMemory'], 'after': c['afterMemory']} for c in r['warmups']],
            measuredMemory=[{'before': c['beforeMemory'], 'after': c['afterMemory']} for c in r['cycles']],
            coldAccountingDelta=accounting_delta(native['entryMemory'], r['beforeWarmup']),
            warmupAccountingDelta=accounting_delta(r['beforeWarmup'], r['afterWarmupBaseline']),
            measuredAccountingDelta=accounting_delta(r['afterWarmupBaseline'], r['afterMeasuredCycles']),
            everyMeasuredIncrementAccountingDelta=[accounting_delta(a, b) for a, b in zip(
                [r['afterWarmupBaseline']] + [c['afterMemory'] for c in r['cycles'][:-1]],
                [c['afterMemory'] for c in r['cycles']])],
            lateAccountingDelta=[accounting_delta(r['cycles'][i]['afterMemory'], r['cycles'][i + 1]['afterMemory']) for i in range(4, 7)],
            cleanupAccountingDelta=accounting_delta(r['afterMeasuredCycles'], native['finalMemory']))
    return output


def compare(arms, stage, comparison_kind='drawing-input'):
    _, selected_cells, _ = comparison_contract(comparison_kind)
    expected = selected_cells[:2] if stage == 'certification' else selected_cells
    N.need(stage in ('certification', 'pair') and set(arms) == {c[0] for c in expected}, 'required fresh cells missing/extra')
    first = arms['baseline-certification']
    previous = None
    for name, strategy, mode in expected:
        arm = arms[name]
        for field in ('sourceCommit', 'executableSHA256', 'executableBytes', 'architecture', 'bundlePath', 'version', 'buildVersion'):
            N.need(arm['native'][field] == first['native'][field], 'paired installed binary identity differs: ' + field)
        N.need(arm['drawing']['drawingStrategy'] == drawing_strategy(strategy, comparison_kind)
               and arm['native']['resourcesRequested'] is (mode == 'resources'), 'arm selection differs')
        if comparison_kind == 'effect-context-memory-target':
            N.need(arm['effectContext']['effectContextPolicy'] == strategy
                   and arm['effectContext']['comparisonKind'] == comparison_kind, 'effect arm selection differs')
            N.need(arm['effectContext']['rendererStorageStrategy'] == 'native'
                   and arm['effectContext']['rendererAutoreleaseScope'] == 'caller', 'effect fixed renderer selection differs')
        elif comparison_kind != 'drawing-input':
            N.need(arm['rendererStorage']['rendererStorageStrategy'] == strategy
                   and arm['rendererStorage']['comparisonKind'] == comparison_kind, 'renderer arm selection differs')
            N.need(arm['rendererStorage']['rendererAutoreleaseScope'] == renderer_autorelease_scope(strategy),
                   'renderer arm autorelease scope differs')
        if previous:
            N.need(previous['finishUptimeSeconds'] <= arm['lifecycle']['launchBeganUptimeSeconds'], 'fresh owned launches overlap or reordered')
        previous = arm['lifecycle']
    compare_work(first, arms['candidate-certification'])
    result = {'schemaVersion': 1, 'status': 'certified' if stage == 'certification' else 'compared',
        **{k: first['native'][k] for k in ('sourceCommit', 'executableSHA256', 'architecture')},
        'certificationExcludedFromMemoryComparison': True, 'exactCorrespondingRGBA': True,
        'canonicalDocumentEquivalence': True, 'documentComparisonPolicy': DOCUMENT_POLICY,
        'nativeExecutionAttestedByChecker': False,
        'memoryStabilityAssessed': False, 'productMemoryRemedyClaim': False, 'privateFrameworkReleaseClaim': False,
        'certificationWorkPerArm': {'functionalWorkloads': 2, 'hashes': 35, 'conversions': 70, 'snapshots': 4},
        'cells': {name: {'processIdentifier': arm['native']['processIdentifier'], 'drawingStrategy': arm['drawing']['drawingStrategy'],
                        'reportHashes': arm['reportHashes'], **arm['lifecycle']} for name, arm in arms.items()},
        'screenshotComparisonScope': 'Each cell independently verifies all four real PNG files, their encoded and decoded RGBA hashes, geometry and native hit targets. Cross-process checks require identical geometry and work. Native AppKit chrome RGBA/encoded hashes and file sizes remain individually reported, not required to match across sessions.',
        'visualEvidence': {name: arm['native']['functionalCases'][0]['visualEvidence'] for name, arm in arms.items()}}
    if stage == 'pair':
        baseline, candidate = arms['baseline'], arms['candidate']
        compare_work(baseline, candidate)
        for name, cert_name in [('baseline', 'baseline-certification'), ('candidate', 'candidate-certification')]:
            arm, certificate = arms[name], arms[cert_name]
            for (workload, label), value in arm['inputs'].items():
                reference = workload if workload.startswith('functional-') else 'functional-4k'
                N.need(value == certificate['inputs'][(reference, label)], 'measured input differs from independently certified input')
            for workload, documents in arm['documents'].items():
                reference = workload if workload.startswith('functional-') else 'functional-4k'
                N.need(canonical_json(documents) == canonical_json(certificate['documents'][reference]),
                       'measured metadata differs from independently certified document')
            N.need(visual_work(arm['native']) == visual_work(certificate['native']), 'certification/measured native geometry differs')
        b, c = metrics(baseline), metrics(candidate)
        result.update(matchedComparisonScope='Two fresh COMPLETE small+4K functional plus 2 warmup+8 measured 4K native workflows; same vImage observer in both measured arms',
            measuredWorkPerArm={'functionalWorkloads': 2, 'warmupWorkloads': 2, 'measuredWorkloads': 8, 'hashes': 205, 'conversions': 205, 'snapshots': 4},
            arms={'baseline': b, 'candidate': c}, candidateMinusBaseline={
                'entryToFinalDeltaBytes': {key: c['entryToFinalDeltaBytes'][key] - b['entryToFinalDeltaBytes'][key] for key in N.MEMORY},
                'sampledPeakBytes': {key: c['sampledPeakBytes'][key] - b['sampledPeakBytes'][key] for key in N.MEMORY},
                'nativeElapsedSeconds': c['nativeElapsedSeconds'] - b['nativeElapsedSeconds'],
                'accountingDeltaDifferences': {key: accounting_difference(b[key], c[key]) for key in (
                    'entryToFinalAccountingDelta', 'coldAccountingDelta', 'warmupAccountingDelta',
                    'measuredAccountingDelta', 'cleanupAccountingDelta')},
                'everyMeasuredIncrementAccountingDifferences': [accounting_difference(x, y) for x, y in zip(
                    b['everyMeasuredIncrementAccountingDelta'], c['everyMeasuredIncrementAccountingDelta'])]},
            interpretation='A single paired diagnostic supports attribution only. All cold, functional, warmup, every measured and late-cycle, snapshot, cleanup, sampled and kernel peak observations remain visible. Both measured arms have identical observer work; certifications are excluded from memory ratios. Owned-provider callbacks and zero activeBytes do not prove CoreFoundation/AppKit backing release. Full task-info dictionaries retain reusable/internal/external/graphics/media values and signed ledgers. No pressure, purge, threshold relaxation, stability, leak or product remedy verdict.')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path); parser.add_argument('--expected-source', required=True)
    parser.add_argument('--cell', type=Path); parser.add_argument('--strategy', choices=STRATEGIES)
    parser.add_argument('--mode', choices=('certify', 'resources')); parser.add_argument('--launcher-status', type=int, default=0)
    parser.add_argument('--root', type=Path); parser.add_argument('--stage', choices=('certification', 'pair'))
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    result = {'status': 'failed', 'memoryStabilityAssessed': False, 'productMemoryRemedyClaim': False}
    try:
        identity = N.bundle_identity(args.app, args.expected_source)
        if args.cell:
            N.need(args.root is None and args.stage is None, 'mixed cell/pair invocation')
            arm = load_cell(args.cell, identity, args.strategy, args.mode, args.launcher_status)
            result.update(status='passed', sourceCommit=identity['sourceCommit'], executableSHA256=identity['executableSHA256'],
                architecture=identity['architecture'], processIdentifier=arm['native']['processIdentifier'],
                drawingStrategy=args.strategy, resourcesRequested=args.mode == 'resources',
                ownedExitConfirmed=True, visualFilesVerified=True, nativeExecutionAttestedByChecker=False,
                reportHashes=arm['reportHashes'])
        else:
            N.need(args.root is not None and args.stage is not None and args.strategy is None and args.mode is None,
                   'incomplete pair invocation')
            selected = CELLS[:2] if args.stage == 'certification' else CELLS
            arms = {name: load_cell(args.root / name, identity, strategy, mode) for name, strategy, mode in selected}
            result = compare(arms, args.stage)
    except Exception as error:
        result['error'] = str(error)[:4096]
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k not in ('arms', 'visualEvidence')}, indent=2, sort_keys=True))
    return 1 if result['status'] == 'failed' else 0


if __name__ == '__main__':
    raise SystemExit(main())
