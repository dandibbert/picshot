#!/usr/bin/env python3
"""Strict post-exit evidence gate for the fixed actual-product 2+8 workload.

The native workload is an observation, not a leak-free or remedy verdict. PNG
conversion happens only in a separate decoder process after the exact app exits.
Portable tests exercise this contract; they are never native evidence.
"""
import argparse
import base64
import copy
import datetime
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import plistlib
import re
import stat
import sys
import uuid
import zlib


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


C = module('product_component_check', 'check-editable-components.py')
D = module('product_drawing_check', 'check-editable-drawing-pair.py')
R = module('product_renderer_check', 'check-renderer-storage-pair.py')
E = module('product_effect_check', 'check-effect-context-pair.py')
need, keys, integer, number, sha = C.need, C.keys, C.integer, C.number, C.sha
PROTOCOL = 'editable-product-resource-v1'
PIXEL_PROTOCOL = 'editable-product-pixels-v1'
MAX_JSON = 2 * 1024 * 1024
MAX_RAW_REPORT = 8 * 1024 * 1024
MAX_PNG = 40 * 1024 * 1024
MAX_DOCUMENT = 131072
MAX_ARTIFACT_COUNT = 256
MAX_ARTIFACT_BYTES = 640 * 1024 * 1024
RECIPE_SHA256 = 'f29b03cadfacc0c156e5a633c7adf3fc88e04851cec40fddd37ddc6972382b6a'
GOLDEN = {
    'original': 'c7819513b71c4ad1675665feece59747ff9a518db5766c5a8de973f65fdf19c6',
    'base': 'b41f79800dd04476e3381aa6fa9da0a2e4f61034729dce3551909a383be83fc9',
    'seven': 'b8362e485bb0bfc04471d4a9de1eaf01be470fb66f419193fa41966cdcaaaff5',
    'eight': '901d625dd2b57188f0d6228ab9ecfbdc1ceee7d2e297d85d42a03bcdf751f621',
}
DIMENSIONS = {'original': (3840, 2160), 'base': (3840, 2160), 'seven': (2414, 1574), 'eight': (2414, 1574)}


def canonical(value):
    # Unlike ordinary Python equality, this never aliases bool with a count.
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False)


def equal(actual, expected, label):
    need(canonical(actual) == canonical(expected), label + ' differs')


def read(path, maximum=MAX_JSON):
    path = Path(path)
    need(path.is_absolute() and str(path) == str(path.resolve(strict=True)), 'unsafe evidence path')
    before = path.lstat()
    need(before.st_nlink == 1, 'hard-linked evidence is not an owned copy')
    data = C.read_bytes(path, maximum)
    after = path.lstat()
    signature = lambda value: (value.st_dev, value.st_ino, value.st_mode, value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
    need(signature(before) == signature(after), 'evidence path changed while reading')
    return data


def load(path, maximum=MAX_JSON, root_type=dict):
    data = read(path, maximum)
    value = json.loads(data, object_pairs_hook=C.strict_pairs,
                      parse_constant=lambda _: (_ for _ in ()).throw(ValueError('nonfinite JSON')))
    need(type(value) is root_type, 'unexpected JSON root')
    canonical(value)  # catches exponent overflow, including deeply nested data
    return value, C.digest(data)


def uuid_value(value):
    need(type(value) is str and str(uuid.UUID(value)).lower() == value.lower(), 'invalid UUID')
    return value.lower()


def date_bounds(value):
    keys(value, {'start', 'end'}, 'session date bounds')
    start = number(value['start'])
    end = number(value['end'], start, start + 300)
    return start, end


def documents(values, bounds, *, allow_new_dates=True):
    """Normalize only declared UUID paths and the eighth mark's session date.

    The prepared capture time, timezone, first seven frozen times, all style and
    geometry, unknown fields, and UUID equality topology are preserved.
    """
    start, end = date_bounds(bounds)
    identities = {}

    def identity(value):
        key = uuid_value(value)
        if key not in identities:
            identities[key] = 'fixture-uuid-' + str(len(identities))
        return identities[key]

    result = []
    for document in values:
        value = copy.deepcopy(document)
        for field in ('documentID', 'originalAssetID', 'baseAssetID'):
            value[field] = identity(value[field])
        annotations = value.get('annotations')
        need(type(annotations) is list and len(annotations) in (7, 8), 'layer work changed')
        for index, annotation in enumerate(annotations):
            need(type(annotation) is dict, 'annotation must be an object')
            annotation['id'] = identity(annotation['id'])
            if annotation.get('mosaicLink') is not None:
                for field in ('groupID', 'additionID', 'rootAdditionID'):
                    annotation['mosaicLink'][field] = identity(annotation['mosaicLink'][field])
            if index == 7:
                need(allow_new_dates and annotation['timestampIsCaptureDate'] is False,
                     'eighth mark has unexpected timestamp semantics')
                number(annotation['frozenTimestamp'], start, end)
                annotation['frozenTimestamp'] = 'bounded-session-date'
        result.append(value)
    return result


def recipe():
    value, digest = load(Path(__file__).resolve().parent / 'fixtures/editable-product-recipe.json')
    need(digest == RECIPE_SHA256, 'independent audited recipe changed')
    return value


def parse_document(encoded):
    need(type(encoded) is str and 0 < len(encoded) <= MAX_DOCUMENT * 4 // 3 + 4, 'unbounded document encoding')
    raw = base64.b64decode(encoded, validate=True)
    need(0 < len(raw) <= MAX_DOCUMENT and base64.b64encode(raw).decode() == encoded, 'noncanonical document encoding')
    value = C.json_object(raw)
    canonical(value)
    return value


def check_recipe(seven, eight, bounds):
    expected = recipe()
    equal(documents([seven, eight], bounds), [expected['seven'], expected['eight']], 'audited recipe')
    # Seed identities and metadata survive restoration exactly; only one mark is added.
    before, after = copy.deepcopy(seven), copy.deepcopy(eight)
    after['annotations'] = after['annotations'][:7]
    equal(before, after, 'seven original layers/root metadata changed on apply')
    all_ids = [uuid_value(seven[key]) for key in ('documentID', 'originalAssetID', 'baseAssetID')]
    all_ids += [uuid_value(item['id']) for item in seven['annotations']]
    need(len(set(all_ids)) == len(all_ids), 'document identities unexpectedly alias')
    need(uuid_value(eight['annotations'][7]['id']) not in all_ids, 'new mark reuses an existing identity')


def installed_identity(app, source):
    app = Path(app)
    need(app.is_absolute() and app.resolve(strict=True) == app, 'installed bundle path is not canonical')
    result = C.bundle_identity(app, source)
    result['infoPlistSHA256'] = C.digest(read(app / 'Contents/Info.plist', 1048576))
    return result


def command(report, argv, timeout, *, pid=None):
    expected = {'schema_version', 'status', 'command', 'started_at', 'timeout_seconds', 'grace_seconds',
        'max_log_bytes', 'pid', 'child_returncode', 'exit_code', 'cancel_signal', 'sigterm_sent', 'sigkill_sent',
        'descendant_cleanup', 'output_bytes', 'log_bytes', 'log_truncated', 'termination_reason',
        'duration_seconds', 'group_observation'}
    keys(report, expected, 'bounded command')
    equal(report['command'], argv, 'bounded command argv')
    equal(report['schema_version'], 1, 'bounded command schema')
    need(report['status'] == report['termination_reason'] == 'exited', 'command failed/timed out')
    equal(report['exit_code'], 0, 'command exit'); equal(report['child_returncode'], 0, 'child exit')
    need(report['cancel_signal'] is None, 'command cancelled')
    for name in ('sigterm_sent', 'sigkill_sent', 'descendant_cleanup', 'log_truncated'):
        need(report[name] is False, 'command cleanup/truncation prevents acceptance: ' + name)
    need(number(report['timeout_seconds']) == timeout, 'command timeout differs')
    need(number(report['grace_seconds']) == 5, 'command grace differs')
    equal(report['max_log_bytes'], MAX_JSON, 'log bound')
    integer(report['pid'], 1, 2**31-1)
    if pid is not None:
        equal(report['pid'], pid, 'command process identifier')
    integer(report['output_bytes'], 0, MAX_JSON)
    equal(report['log_bytes'], report['output_bytes'], 'command log byte count')
    duration = number(report['duration_seconds'], 0, timeout)
    C.validate_group_observation(report['group_observation'], duration)
    start = datetime.datetime.fromisoformat(C.string(report['started_at']))
    need(start.tzinfo is not None and start.utcoffset() == datetime.timedelta(0), 'command start must be UTC')
    return start.timestamp(), duration


def product_process(directory, installed, *, certify=False):
    report, report_hash = load(directory / ('product-certificate.json' if certify else 'editable-product-resource.json'), MAX_RAW_REPORT)
    envelope, envelope_hash = load(directory / 'launch.json', MAX_RAW_REPORT)
    equal(envelope, report, 'launch envelope')
    launcher, launcher_hash = load(directory / 'launch.json.launcher.json')
    native_installed = {k: v for k, v in installed.items() if k != 'infoPlistSHA256'}
    C.identity(report, native_installed)
    C.validate_launch(launcher, report, native_installed)
    wrapper, wrapper_hash = load(directory / 'command.json')
    _, duration = command(wrapper, ['swift', 'scripts/launch-editable-product.swift', installed['bundlePath'], str(directory / 'launch.json')], 620)
    need(duration + .1 >= launcher['elapsedSeconds'], 'wrapper ended before app launcher')
    return report, launcher, {'rawReportSHA256': report_hash, 'launchReportSHA256': envelope_hash,
        'launcherSHA256': launcher_hash, 'commandSHA256': wrapper_hash}


COPY_FIELDS = {'sourceFilename', 'evidenceFilename', 'byteCount', 'sha256', 'copySeconds',
               'memoryBefore', 'memoryAfter', 'streamedBytes', 'deduplicated'}
RASTER_FIELDS = {'role', 'expectedState', 'width', 'height', 'assetID'}


def file_record(record, directory, *, raster=False):
    keys(record, COPY_FIELDS | (RASTER_FIELDS if raster else set()), 'archived file')
    relative = C.string(record['evidenceFilename'])
    need(re.fullmatch(r'artifacts/blobs/[0-9a-f]{64}\.(png|json|annotations)', relative) is not None,
         'unsafe content-addressed path')
    digest = sha(record['sha256'])
    need(Path(relative).stem == digest, 'content-addressed filename differs')
    maximum = MAX_PNG if relative.endswith('.png') else MAX_DOCUMENT if relative.endswith('.annotations') else MAX_JSON
    integer(record['byteCount'], 1, maximum)
    data = read(directory / relative, maximum)
    need(len(data) == record['byteCount'] and C.digest(data) == digest, 'archived bytes differ')
    need(type(record['deduplicated']) is bool, 'copy deduplication flag missing')
    equal(integer(record['streamedBytes']), len(data), 'streamed byte count')
    duration = number(record['copySeconds'], 0, 300)
    for item in (record['memoryBefore'], record['memoryAfter']):
        keys(item, {'uptimeSeconds', 'counters'}, 'copy memory observation')
        number(item['uptimeSeconds']); C.counters(item['counters'])
    need(record['memoryBefore']['uptimeSeconds'] <= record['memoryAfter']['uptimeSeconds'], 'copy memory moved backward')
    need(record['memoryAfter']['uptimeSeconds'] - record['memoryBefore']['uptimeSeconds'] <= duration + .1,
         'copy observations exceed copy duration')
    name = C.string(record['sourceFilename'])
    if name != 'index.json':
        need(re.fullmatch(r'[A-Fa-f0-9-]{36}\.(png|annotations)', name) is not None, 'unsafe original store filename')
        uuid_value(name.split('.')[0])
    return data


def delta(before, after):
    return {key: after['counters'][key] - before['counters'][key] for key in C.MEMORY}


ACTIONS = ('open-editor', 'seed-edit-undo', 'native-crop', 'history-save', 'seed-close',
           'history-reopen', 'reopen-edit-undo', 'native-pin', 'history-editor-close',
           'annotations-hide', 'annotations-show', 'group-hide', 'group-show',
           'space-open', 'space-edit', 'apply-to-pin', 'pin-close')
CHECKPOINTS = ('editor-open', 'history-saved', 'seed-closed', 'history-reopened', 'pin-created',
               'history-editor-closed', 'annotations-hidden', 'annotations-shown',
               'group-hidden-released', 'group-shown', 'space-edited', 'pin-applied', 'cycle-released')
STAGES = ('history-save', 'pin-before-apply', 'pin-after-apply', 'pin-closed')
SAMPLE_PHASES = ('seed', 'reopen', 'annotations', 'group-hide', 'group-show', 'space-apply', 'release')
CELL_STRATEGIES = {'baseline': 'reference', 'candidate': 'owned-srgb8'}
LIVE_COUNTS = {'editor-open': (1, 0, 0), 'history-saved': (1, 0, 0), 'seed-closed': (0, 0, 0),
    'history-reopened': (1, 0, 0), 'pin-created': (1, 1, 0), 'history-editor-closed': (0, 1, 0),
    'annotations-hidden': (0, 1, 0), 'annotations-shown': (0, 1, 0), 'group-hidden-released': (0, 0, 0),
    'group-shown': (0, 1, 0), 'space-edited': (0, 1, 1), 'pin-applied': (0, 1, 0), 'cycle-released': (0, 0, 0)}
ASSERTIONS = ('nativeEditUndo', 'cropApplied', 'appDelegateHistorySave', 'appDelegateOpenRecord',
              'nativePinCallback', 'hiddenGeometry', 'groupRetiredAndReloaded', 'spaceSharedOriginal',
              'nativeEighthLayerApplied', 'committedVersionsPreserved', 'controllerGraphsRetired', 'jobsAndDescriptorsDrained')


def owner(value, *, released=False):
    keys(value, {'created', 'aliveNonWindowObjects', 'liveEditors', 'livePins',
                 'attachedWindowGraphs', 'retainedWindowShells'}, 'ownership snapshot')
    created = integer(value['created'], 1, 64)
    for name in value:
        integer(value[name], 0, created)
    if released:
        for name in ('aliveNonWindowObjects', 'liveEditors', 'livePins', 'attachedWindowGraphs'):
            equal(value[name], 0, 'released ' + name)


def state(value, *, released=False, strategy='reference'):
    fields = {'appEditorCount', 'pinCount', 'pinEditorCount', 'knownRasters', 'knownUniqueRasterBytes',
        'rasterIdentityScope', 'editorAdmissionEstimateBytes', 'pinAdmissionEstimateBytes', 'undoRasterIdentities',
        'hiddenPreviewCount', 'retainedEditableBaseCount', 'projectionBusy', 'projectionReservedBytes',
        'projectionQueueOperations', 'projectionStarted', 'projectionCompleted', 'exportSessions',
        'exportQueueOperations', 'pinThumbnailCacheBytes', 'pinThumbnailCacheCount', 'historyThumbnailRequests',
        'historyThumbnailCacheLimitBytes', 'historyThumbnailCacheObservedBytes', 'ownedOpenDescriptors', 'fixedRunOwners', 'drawing', 'rendererStorage'}
    keys(value, fields, 'product state')
    excluded = {'knownRasters', 'rasterIdentityScope', 'projectionBusy', 'historyThumbnailCacheObservedBytes', 'fixedRunOwners', 'drawing', 'rendererStorage'}
    for name in fields - excluded:
        integer(value[name], 0, 2**40)
    D.drawing_snapshot(value['drawing'], strategy, released=released)
    R.snapshot(value['rendererStorage'], 'native', released=released)
    equal(value['fixedRunOwners'], {'appDelegate': 1, 'historyStore': 1, 'pinSessionCoordinator': 1, 'pinSessionStore': 1}, 'fixed owners')
    need(value['historyThumbnailCacheObservedBytes'] is None, 'unobservable history cache bytes fabricated')
    equal(value['historyThumbnailCacheLimitBytes'], 24 * 1024 * 1024, 'history cache limit')
    equal(value['historyThumbnailRequests'], 0, 'unexpected history thumbnail work')
    need(type(value['projectionBusy']) is bool, 'projection busy flag missing')
    need(value['projectionCompleted'] <= value['projectionStarted'], 'more completed than started projections')
    need(value['editorAdmissionEstimateBytes'] <= 768 * 1024 * 1024, 'editor admission bound exceeded')
    need(value['undoRasterIdentities'] <= 1, 'metadata workflow retained unexpected undo rasters')
    need(value['projectionReservedBytes'] <= 512 * 1024 * 1024, 'projection admission bound exceeded')
    need(value['pinThumbnailCacheBytes'] <= 12 * 1024 * 1024 and value['pinThumbnailCacheCount'] <= 24, 'pin cache bound exceeded')
    C.string(value['rasterIdentityScope'])
    rows = value['knownRasters']
    need(type(rows) is list and len(rows) <= 16, 'unbounded raster census')
    identities, total = {}, 0
    for row in rows:
        keys(row, {'role', 'identity', 'width', 'height', 'bytesPerRow', 'knownBytes', 'firstIdentityOccurrence'}, 'raster census row')
        need(row['role'] in ('editor-original', 'editor-base', 'editor-presentation', 'pin-original', 'pin-current', 'pin-hidden-preview'), 'unknown raster role')
        ident = C.string(row['identity'])
        w, h = integer(row['width'], 1, 3840), integer(row['height'], 1, 2160)
        stride = integer(row['bytesPerRow'], w * 4, w * 16 + 256)
        equal(row['knownBytes'], stride * h, 'raster row-stride accounting')
        need(row['firstIdentityOccurrence'] is (ident not in identities), 'raster identity counted twice or omitted')
        if ident in identities:
            equal(identities[ident], (w, h, stride), 'shared raster metadata')
        else:
            total += stride * h; identities[ident] = (w, h, stride)
    equal(value['knownUniqueRasterBytes'], total, 'known raster total')
    if released:
        for name in ('appEditorCount', 'pinCount', 'pinEditorCount', 'knownUniqueRasterBytes', 'editorAdmissionEstimateBytes',
                     'pinAdmissionEstimateBytes', 'undoRasterIdentities', 'hiddenPreviewCount', 'retainedEditableBaseCount',
                     'projectionReservedBytes', 'projectionQueueOperations', 'exportSessions', 'exportQueueOperations', 'ownedOpenDescriptors'):
            equal(value[name], 0, 'released ' + name)
        need(value['knownRasters'] == [] and value['projectionBusy'] is False, 'raster/job remained at release')
        equal(value['projectionStarted'], value['projectionCompleted'], 'projection jobs not drained')


def samples(value, measure):
    keys(value, {'scope', 'sampleIntervalSeconds', 'maximumPhaseAggregates', 'continuousSampleArraysRetained',
        'pairedTaskInfoCallsAreAtomic', 'missingFieldsBecomeZero', 'total', 'phases'}, 'sampler')
    C.string(value['scope'])
    equal(value['sampleIntervalSeconds'], .05, 'sampler interval')
    equal(value['maximumPhaseAggregates'], 128, 'sampler capacity')
    for name in ('continuousSampleArraysRetained', 'pairedTaskInfoCallsAreAtomic', 'missingFieldsBecomeZero'):
        need(value[name] is False, 'false sampler semantics')
    expected = {'entry', 'final-cleanup'}
    if measure:
        expected |= {'run-cleanup'} | {f'cycle-{i}-{phase}' for i in range(1, 11) for phase in SAMPLE_PHASES}
    keys(value['phases'], expected, 'sampler phases')
    C.statistics(value['total'])
    for item in value['phases'].values():
        C.statistics(item)
    for field in ('sampleCount', 'timerSampleCount'):
        equal(value['total'][field], sum(item[field] for item in value['phases'].values()), 'sample aggregation')
    if measure:
        need(value['total']['timerSampleCount'] > 0, 'no timed peak observations')
    for name in C.MEMORY:
        equal(value['total']['sampledPeakBytes'][name], max(item['sampledPeakBytes'][name] for item in value['phases'].values()), 'peak aggregation')
        equal(value['total']['sampledMinimumBytes'][name], min(item['sampledMinimumBytes'][name] for item in value['phases'].values()), 'minimum aggregation')
        equal(value['total']['lastBytes'][name], value['phases']['final-cleanup']['lastBytes'][name], 'final sample')


def cycles(report, strategy='reference'):
    rows = report['cycles']
    need(type(rows) is list and len(rows) == 10, 'exactly 2 warmup + 8 measured cycles required')
    equal(report['completedWarmupCycles'], 2, 'warmup completion')
    equal(report['completedMeasuredCycles'], 8, 'measured completion')
    actions, points = report['actions'], report['checkpoints']
    need(type(actions) is list and len(actions) == len(ACTIONS) * 10, 'actions omitted or added')
    need(type(points) is list and len(points) == len(CHECKPOINTS) * 10, 'checkpoints omitted or added')
    timings = report['phaseTimings']
    need(type(timings) is list and len(timings) == 70, 'all seventy measured phase timings required')
    previous = report['beforeWarmup']['uptimeSeconds']
    history_ids, pin_ids = set(), set()
    for ordinal, row in enumerate(rows, 1):
        keys(row, {'ordinal', 'warmup', 'cold', 'beforeMemory', 'afterMemory', 'deltaBytes', 'elapsedSeconds',
            'historyID', 'pinID', 'actionRange', 'stageRange', 'afterReleaseState', 'ownershipAfterRelease', 'assertions'}, 'cycle')
        equal(row['ordinal'], ordinal, 'cycle ordinal')
        need(row['warmup'] is (ordinal <= 2) and row['cold'] is (ordinal == 1), 'cycle phase/cold identity differs')
        C.ordered_observations([row['beforeMemory'], row['afterMemory']])
        start, end = row['beforeMemory']['uptimeSeconds'], row['afterMemory']['uptimeSeconds']
        need(start >= previous, 'cycle observations overlap or reverse')
        previous = end
        duration = number(row['elapsedSeconds'], 0, 300)
        need(end - start <= duration + .1, 'cycle interval exceeds elapsed duration')
        equal(row['deltaBytes'], delta(row['beforeMemory'], row['afterMemory']), 'cycle memory arithmetic')
        hid, pid = uuid_value(row['historyID']), uuid_value(row['pinID'])
        need(hid not in history_ids and pid not in pin_ids and hid != pid, 'history/pin identities reused')
        history_ids.add(hid); pin_ids.add(pid)
        equal(row['actionRange'], [(ordinal-1)*len(ACTIONS), ordinal*len(ACTIONS)], 'cycle action range')
        equal(row['stageRange'], [(ordinal-1)*4, ordinal*4], 'cycle stage range')
        equal(row['assertions'], {key: True for key in ASSERTIONS}, 'native lifecycle assertions')
        owner(row['ownershipAfterRelease'], released=True); state(row['afterReleaseState'], released=True, strategy=strategy)
        phase_time = start
        phase_rows = timings[(ordinal-1)*7:ordinal*7]
        for expected_phase, phase_row in zip(SAMPLE_PHASES, phase_rows):
            keys(phase_row, {'cycle', 'phase', 'startUptimeSeconds', 'endUptimeSeconds', 'elapsedSeconds'}, 'phase timing')
            equal(phase_row['cycle'], ordinal, 'phase timing cycle'); equal(phase_row['phase'], expected_phase, 'phase timing order')
            phase_begin = number(phase_row['startUptimeSeconds'], phase_time, start + duration + .1)
            phase_end = number(phase_row['endUptimeSeconds'], phase_begin, start + duration + .1)
            need(abs(phase_end - phase_begin - number(phase_row['elapsedSeconds'])) <= .001, 'phase elapsed arithmetic differs')
            phase_time = phase_end
        need(phase_rows[-1]['startUptimeSeconds'] <= end <= phase_rows[-1]['endUptimeSeconds'], 'release phase omits measured endpoint')
        action_time = start
        for expected, action in zip(ACTIONS, actions[(ordinal-1)*len(ACTIONS):ordinal*len(ACTIONS)]):
            keys(action, {'cycle', 'name', 'elapsedSeconds', 'startUptimeSeconds', 'endUptimeSeconds'}, 'action')
            equal(action['cycle'], ordinal, 'action cycle'); equal(action['name'], expected, 'action order')
            begin = number(action['startUptimeSeconds'], action_time, end)
            finish = number(action['endUptimeSeconds'], begin, end)
            elapsed = number(action['elapsedSeconds'], 0, duration)
            need(abs(finish - begin - elapsed) <= .01, 'action elapsed arithmetic differs')
            action_time = finish
        point_time = start
        for expected, point in zip(CHECKPOINTS, points[(ordinal-1)*len(CHECKPOINTS):ordinal*len(CHECKPOINTS)]):
            keys(point, {'cycle', 'phase', 'memory', 'state', 'ownership'}, 'checkpoint')
            equal(point['cycle'], ordinal, 'checkpoint cycle'); equal(point['phase'], expected, 'checkpoint order')
            C.observation(point['memory'])
            point_time = number(point['memory']['uptimeSeconds'], point_time, end)
            retired = expected in ('seed-closed', 'group-hidden-released', 'cycle-released')
            owner(point['ownership'], released=retired); state(point['state'], released=retired, strategy=strategy)
            live = point['state']
            equal(tuple(live[key] for key in ('appEditorCount', 'pinCount', 'pinEditorCount')), LIVE_COUNTS[expected], 'checkpoint live owner counts')
            for name in ('projectionReservedBytes', 'projectionQueueOperations', 'exportSessions', 'exportQueueOperations', 'ownedOpenDescriptors'):
                equal(live[name], 0, 'checkpoint job/descriptor not drained')
            need(live['projectionBusy'] is False and live['projectionStarted'] == live['projectionCompleted'], 'checkpoint projection not drained')
            raster_roles = {row['role']: row for row in live['knownRasters']}
            need(len(raster_roles) == len(live['knownRasters']), 'duplicate known raster role')
            required = set()
            if LIVE_COUNTS[expected][0] + LIVE_COUNTS[expected][2]:
                required |= {'editor-original', 'editor-base'}
            if LIVE_COUNTS[expected][1]:
                required |= {'pin-original', 'pin-current'}
            if expected == 'annotations-hidden':
                required.add('pin-hidden-preview')
            need(required <= set(raster_roles) <= required | ({'editor-presentation'} if 'editor-base' in required else set()), 'checkpoint raster roles differ')
            for role, raster in raster_roles.items():
                equal((raster['width'], raster['height']), (2414, 1574) if role in ('pin-current', 'pin-hidden-preview') else (3840, 2160), 'checkpoint raster extent')
            if expected == 'space-edited':
                equal(raster_roles['editor-original']['identity'], raster_roles['pin-original']['identity'], 'Space original sharing')
            if expected == 'annotations-hidden':
                equal(point['state']['hiddenPreviewCount'], 1, 'hidden preview missing')
            elif expected in ('annotations-shown', 'group-shown', 'pin-applied'):
                equal(point['state']['hiddenPreviewCount'], 0, 'hidden preview retained')
            if expected == 'space-edited':
                equal(point['state']['pinEditorCount'], 1, 'Space editor missing')
    equal(report['afterWarmupBaseline'], rows[1]['afterMemory'], 'warmup baseline')
    equal(report['afterMeasuredCycles'], rows[-1]['afterMemory'], 'measured endpoint')
    equal(report['warmupDeltaBytes'], delta(report['beforeWarmup'], rows[1]['afterMemory']), 'warmup arithmetic')
    equal(report['afterWarmupToMeasuredDeltaBytes'], delta(rows[1]['afterMemory'], rows[-1]['afterMemory']), 'measured arithmetic')
    equal(report['lateMeasuredIncrements'], [delta(a['afterMemory'], b['afterMemory']) for a, b in zip(rows[-4:-1], rows[-3:])], 'late growth arithmetic')


def json_value(data):
    value = json.loads(data, object_pairs_hook=C.strict_pairs,
        parse_constant=lambda _: (_ for _ in ()).throw(ValueError('nonfinite JSON')))
    canonical(value)
    return value


def asset_descriptor(value, row, *, identity=True):
    fields = {'filename', 'width', 'height', 'byteCount', 'sha256'} | ({'assetID'} if identity else set())
    keys(value, fields, 'committed raster descriptor')
    for field, source in [('filename', 'sourceFilename'), ('width', 'width'), ('height', 'height'),
                          ('byteCount', 'byteCount'), ('sha256', 'sha256')]:
        equal(value[field], row[source], 'committed raster ' + field)
    if identity:
        equal(uuid_value(value['assetID']), uuid_value(row['assetID']), 'committed raster identity')


def catalog(data, stage, doc, bounds):
    value = json_value(data)
    start, end = date_bounds(bounds)
    if stage['store'] == 'history':
        need(type(value) is list and len(value) == 1, 'history catalog must contain exactly one current record')
        record = value[0]
        keys(record, {'id', 'createdAt', 'title', 'filename', 'width', 'height', 'byteCount', 'text', 'starred', 'editableCapture'}, 'history record')
        equal(record['text'], '', 'history text'); need(record['starred'] is False, 'history star changed')
        number(record['createdAt'], start, end)
        need(C.string(record['title']).startswith('编辑 · '), 'history title changed')
        for field, source in [('filename', 'sourceFilename'), ('width', 'width'), ('height', 'height'), ('byteCount', 'byteCount')]:
            equal(record[field], stage['rasters'][2][source], 'history current ' + field)
    else:
        keys(value, {'version', 'groups', 'entries', 'activeGroupID', 'allHidden'}, 'pin index')
        equal(value['version'], 3, 'pin index version')
        equal(value['activeGroupID'].lower(), '00000000-0000-0000-0000-000000000001', 'active pin group')
        need(value['allHidden'] is False, 'pin group still hidden')
        equal(value['groups'], [{'id': '00000000-0000-0000-0000-000000000001', 'name': '默认',
            'color': 'gray', 'isHidden': False, 'isProtected': False}], 'pin groups')
        need(type(value['entries']) is list and len(value['entries']) == 1, 'pin catalog must contain exactly one current pin')
        record = value['entries'][0]
        fields = {'id', 'groupID', 'title', 'createdAt', 'updatedAt', 'original', 'current', 'presentation', 'isVisible', 'editableCapture'}
        closed = stage['stage'] == 'pin-closed'
        keys(record, fields | ({'archiveSequence'} if closed else set()), 'pin entry')
        need(record['isVisible'] is (not closed), 'pin close visibility differs')
        if closed:
            integer(record['archiveSequence'], 1, 10)
        equal(record['groupID'], value['activeGroupID'], 'pin entry group')
        number(record['createdAt'], start, end); number(record['updatedAt'], record['createdAt'], end)
        equal(record['title'], '贴图', 'pin title')
        asset_descriptor(record['original'], stage['rasters'][0], identity=False)
        asset_descriptor(record['current'], stage['rasters'][2], identity=False)
        presentation = record['presentation']
        expected = {'frame', 'opacity', 'clickThrough', 'locked'}
        if 'zoom' in presentation:
            expected.add('zoom'); number(presentation['zoom'], .25, 4)
        keys(presentation, expected, 'pin presentation')
        equal(presentation['opacity'], 1, 'pin opacity')
        need(presentation['clickThrough'] is presentation['locked'] is False, 'pin presentation mode changed')
        keys(presentation['frame'], {'x', 'y', 'width', 'height'}, 'pin frame')
        for name in ('x', 'y'):
            number(presentation['frame'][name], -10000000, 10000000)
        for name in ('width', 'height'):
            number(presentation['frame'][name], 1, 100000)
    equal(uuid_value(record['id']), uuid_value(stage['recordID']), 'store record identity')
    descriptor = record['editableCapture']
    keys(descriptor, {'documentFilename', 'documentByteCount', 'documentSHA256', 'original', 'base', 'current'}, 'editable descriptor')
    for field, source in [('documentFilename', 'sourceFilename'), ('documentByteCount', 'byteCount'), ('documentSHA256', 'sha256')]:
        equal(descriptor[field], stage['document'][source], 'committed document ' + field)
    for row in stage['rasters']:
        asset_descriptor(descriptor[row['role']], row)
        if row['role'] in ('original', 'base'):
            equal(uuid_value(row['assetID']), uuid_value(doc[row['role'] + 'AssetID']), 'document/asset foreign identity')
    need(len({row['sourceFilename'] for row in stage['rasters']}) == 3 and
         len({uuid_value(row['assetID']) for row in stage['rasters']}) == 3, 'distinct raster roles aliased')
    return value


def stages(report, directory, seed, golden_paths):
    values = report['stages']
    need(type(values) is list and len(values) == 40, 'all 40 committed lifecycle versions required')
    files, pixel_plan, immutable, previous_pin, pin_original = {}, {}, {}, None, None
    total_streamed, copy_seconds = 0, 0.0
    copies, eighth_ids = 0, set()
    for index, stage in enumerate(values):
        ordinal, label = index // 4 + 1, STAGES[index % 4]
        expected = 'eight' if label in ('pin-after-apply', 'pin-closed') else 'seven'
        keys(stage, {'cycle', 'stage', 'id', 'store', 'recordID', 'expectedState', 'index', 'document', 'rasters'}, 'saved stage')
        equal(stage['cycle'], ordinal, 'saved stage cycle'); equal(stage['stage'], label, 'saved stage order')
        equal(stage['id'], f'{ordinal}-{label}', 'saved stage identity')
        equal(stage['store'], 'history' if label == 'history-save' else 'pin', 'saved stage store')
        equal(stage['expectedState'], expected, 'saved stage expected work')
        cycle = report['cycles'][ordinal-1]
        equal(stage['recordID'], cycle['historyID'] if label == 'history-save' else cycle['pinID'], 'stage/cycle record')
        equal(stage['index']['sourceFilename'], 'index.json', 'index filename')
        need(type(stage['rasters']) is list and len(stage['rasters']) == 3 and
             [row.get('role') for row in stage['rasters']] == ['original', 'base', 'current'], 'raster roles missing/reordered')
        payloads = []
        for row_index, row in enumerate([stage['index'], stage['document'], *stage['rasters']]):
            data = file_record(row, directory, raster=row_index >= 2)
            copy_begin, copy_end = row['memoryBefore']['uptimeSeconds'], row['memoryAfter']['uptimeSeconds']
            need(cycle['beforeMemory']['uptimeSeconds'] <= copy_begin <= copy_end <= cycle['afterMemory']['uptimeSeconds'], 'evidence copy outside its cycle')
            copies += 1; total_streamed += row['streamedBytes']; copy_seconds += row['copySeconds']
            path = row['evidenceFilename']
            need(row['deduplicated'] is (path in files), 'deduplication accounting differs')
            signature = (row['byteCount'], row['sha256'])
            if path in files:
                equal(files[path], signature, 'content-addressed reuse changed')
            else:
                files[path] = signature
            payloads.append(data)
        doc = json_value(payloads[1])
        need(type(doc) is dict, 'saved document is not an object')
        if expected == 'seven':
            equal(doc, seed, 'saved seven-layer document differs from certified input')
        else:
            check_recipe(seed, doc, report['sessionDateBounds'])
            if label == 'pin-after-apply':
                new_id = uuid_value(doc['annotations'][7]['id'])
                need(new_id not in eighth_ids, 'native applied mark identity reused across cycles')
                eighth_ids.add(new_id)
        catalog(payloads[0], stage, doc, report['sessionDateBounds'])
        for row, encoded in zip(stage['rasters'], payloads[2:]):
            role = row['role']; state_key = expected if role == 'current' else role
            equal(row['expectedState'], state_key, 'saved raster state')
            equal((row['width'], row['height']), DIMENSIONS[state_key], 'saved raster dimensions')
            C.png_metadata(encoded, row['width'], row['height'])
            if role in ('original', 'base'):
                signature = uuid_value(row['assetID'])
                if role in immutable:
                    equal(signature, immutable[role], 'immutable ' + role + ' changed across lifecycle')
                else:
                    immutable[role] = signature
            plan_key = row['evidenceFilename']
            plan_row = {'path': str(directory / row['evidenceFilename']), 'encodedBytes': row['byteCount'],
                'encodedSHA256': row['sha256'], 'goldenPath': str(golden_paths[state_key]), 'goldenSHA256': GOLDEN[state_key],
                'width': row['width'], 'height': row['height']}
            if plan_key in pixel_plan:
                equal(pixel_plan[plan_key], plan_row, 'one PNG reused for different pixel states')
            pixel_plan[plan_key] = plan_row
        original_row = stage['rasters'][0]
        original_identity = {key: original_row[key] for key in ('sourceFilename', 'byteCount', 'sha256', 'assetID')}
        if label == 'pin-before-apply':
            pin_original = original_identity
        elif label in ('pin-after-apply', 'pin-closed'):
            equal(original_identity, pin_original, 'pin immutable original was replaced')
        if label == 'pin-closed':
            need(previous_pin is not None, 'preclose committed version missing')
            for name in ('document', 'rasters'):
                def content(value):
                    return [{k: r[k] for k in ('sourceFilename', 'evidenceFilename', 'byteCount', 'sha256')} for r in value] if type(value) is list else {k: value[k] for k in ('sourceFilename', 'evidenceFilename', 'byteCount', 'sha256')}
                equal(content(stage[name]), content(previous_pin[name]), 'pin close changed saved content')
        previous_pin = stage if label == 'pin-after-apply' else previous_pin
    need(immutable['original'] != immutable['base'], 'original/base asset identities alias')
    need(len(files) <= MAX_ARTIFACT_COUNT and sum(row[0] for row in files.values()) <= MAX_ARTIFACT_BYTES, 'evidence size/count exceeds bound')
    actual = set()
    for path in (directory / 'artifacts').rglob('*'):
        need(not path.is_symlink(), 'linked artifact or directory')
        if path.is_file():
            actual.add(str(path.relative_to(directory)))
        else:
            need(path.is_dir(), 'nonregular artifact')
    equal(sorted(actual), sorted(files), 'orphan/unreported evidence file')
    counts = report['evidenceCopies']
    keys(counts, {'sourceFiles', 'streamedBytes', 'uniqueFiles', 'uniqueBytes', 'copySeconds', 'bufferBytes',
        'maximumSourceFiles', 'maximumUniqueFiles', 'maximumUniqueBytes', 'maximumStreamedBytes',
        'excludedFromProcessMemory', 'rasterDecodeCount', 'rasterNormalizationCount'}, 'evidence copy accounting')
    for name, expected in {'sourceFiles': copies, 'streamedBytes': total_streamed, 'uniqueFiles': len(files),
        'uniqueBytes': sum(row[0] for row in files.values()), 'bufferBytes': 65536,
        'maximumSourceFiles': 256, 'maximumUniqueFiles': 256, 'maximumUniqueBytes': MAX_ARTIFACT_BYTES,
        'maximumStreamedBytes': 2147483648, 'rasterDecodeCount': 0, 'rasterNormalizationCount': 0}.items():
        equal(counts[name], expected, 'copy accounting ' + name)
    need(counts['excludedFromProcessMemory'] is False, 'copy overhead excluded from measurement')
    need(total_streamed <= 2147483648 and abs(number(counts['copySeconds']) - copy_seconds) <= .001, 'copy total time/stream bound differs')
    return [pixel_plan[key] for key in sorted(pixel_plan)], {'sourceFiles': copies, 'uniqueFiles': len(files),
        'uniqueBytes': sum(row[0] for row in files.values()), 'streamedBytes': total_streamed, 'copySeconds': copy_seconds}


COMMON_FIELDS = C.IDENTITY_FIELDS | {'version', 'buildVersion', 'schemaVersion', 'protocol', 'mode', 'runIdentifier',
    'requestedDrawingStrategy', 'drawingOverridePresent',
    'status', 'deadlineSeconds', 'entryMemory', 'memoryStabilityAssessed', 'zeroRSSClaim', 'privateBackingReleaseProved',
    'fullCorrectnessFixtureReplaced', 'scope', 'entryPoints', 'latencyScope', 'flags', 'limits', 'inputManifestSHA256',
    'inputCertificateSHA256', 'inputPreparationProcessIdentifier', 'inputCertificateProcessIdentifier',
    'inputOriginalEncodedBytes', 'inputBaseEncodedBytes', 'fixtureRetainedInputRasterBytes', 'sessionDateBounds',
    'sampledMemory', 'finalMemory', 'configuration', 'elapsedSeconds'}
CERT_FIELDS = {'goldens', 'originalDocumentBase64', 'appliedDocumentBase64', 'goldenSource', 'memoryComparisonExcluded'}
MEASURE_FIELDS = {'resourcePolicy', 'beforeWarmup', 'cycles', 'completedWarmupCycles', 'completedMeasuredCycles',
    'stages', 'checkpoints', 'actions', 'phaseTimings', 'evidenceCopies', 'afterWarmupBaseline', 'afterMeasuredCycles',
    'warmupDeltaBytes', 'afterWarmupToMeasuredDeltaBytes', 'lateMeasuredIncrements', 'ownedTemporaryDirectoryRemoved',
    'ownedOpenDescriptorsAfterCleanup', 'afterCloseOwnership', 'fixedRunOwnershipAfterRelease', 'fixedRunOwnersReleased'}


def common(report, installed, manifest, component, mode, certificate_hash, certificate_pid, strategy='reference'):
    measure = mode == 'measure'
    keys(report, COMMON_FIELDS | (MEASURE_FIELDS if measure else CERT_FIELDS), 'product report')
    C.identity(report, {k: v for k, v in installed.items() if k != 'infoPlistSHA256'}, manifest['operatingSystem'])
    info = plistlib.loads(read(Path(installed['bundlePath']) / 'Contents/Info.plist', 1048576))
    equal(report['version'], info['CFBundleShortVersionString'], 'bundle version')
    equal(report['buildVersion'], info['CFBundleVersion'], 'bundle build')
    equal(report['schemaVersion'], 1, 'report schema'); equal(report['protocol'], PROTOCOL, 'report protocol')
    equal(report['mode'], mode, 'report mode'); uuid_value(report['runIdentifier'])
    equal(report['status'], 'observed-pending-output-validation' if measure else 'certified', 'report status')
    for name in ('memoryStabilityAssessed', 'zeroRSSClaim', 'privateBackingReleaseProved', 'fullCorrectnessFixtureReplaced'):
        need(report[name] is False, 'unsupported acceptance/release claim')
    need(number(report['deadlineSeconds']) == 300 and 0 < number(report['elapsedSeconds']) <= 300, 'native deadline changed/exceeded')
    C.string(report['scope'])
    equal(report['latencyScope'], 'Action dispatch to semantic completion, not physical-input or first-painted-frame latency. '
        'Save/pin/apply await durable callback and projection drain; open/Space/group-show include a 150ms native settle; '
        'edit/undo/crop end after native event handlers and metadata assertions.', 'latency interpretation')
    equal(report['entryPoints'], {'seedMetadata': 'programmatic certified seven-layer payload, uncropped',
        'initialOpen': 'AppDelegate.openEditor with production CGImage.read and encoded backing admission',
        'historyReopen': 'programmatic AppDelegate.openRecord',
        'nativeControls': 'owned NSButton.performClick / NSMenu.performActionForItem',
        'nativeGestures': 'owned canvas mouseDown/mouseDragged/mouseUp and Command-Z / Space responder events',
        'groupVisibility': 'programmatic PinSessionCoordinator.hideCurrentGroup/showCurrentGroup',
        'historyGridDoubleClick': False, 'physicalInput': False}, 'entry point disclosure')
    equal(report['flags'], {'syntheticSource': True, **{key: False for key in ('screenCaptureStarted', 'permissionRequests',
        'globalInputPosted', 'networkUsed', 'generalPasteboardUsed', 'standardDefaultsWritten', 'memoryPressureOrPurgeRequested',
        'manualCachePurges', 'weakCoreFoundationProbes', 'measuredRasterReferenceWork', 'measuredRawRGBARead')}}, 'forbidden workload work')
    equal(report['limits'], {'sourceWidth': 3840, 'sourceHeight': 2160, 'warmups': 2, 'measured': 8,
        'copyBufferBytes': 65536, 'maximumPNGBytes': MAX_PNG, 'maximumMetadataBytes': MAX_DOCUMENT,
        'maximumReportBytes': MAX_RAW_REPORT,
        'maximumEvidenceFiles': 256, 'maximumEvidenceBytes': MAX_ARTIFACT_BYTES, 'maximumStages': 40,
        'maximumCheckpoints': 160, 'editorAdmissionBytes': 768 * 1024 * 1024,
        'projectionReservationBytes': 512 * 1024 * 1024}, 'workload resource bounds')
    config = report['configuration']
    fixed = {'drawingStrategy': strategy, 'rendererStorageStrategy': 'native', 'effectContextPolicy': 'reference',
        'productionDefaultsChanged': False, 'drawingProductionDefault': 'reference', 'rendererStorageProductionDefault': 'native',
        'effectContextProductionDefault': 'reference',
        'drawingOriginalFormatFallback': 'Unsupported layouts and profiles retain the original native drawing path; no model/source normalization or fallback on conversion failure'}
    keys(config, set(fixed) | {'drawing', 'rendererStorage', 'effects'}, 'finite drawing configuration')
    equal({name: config[name] for name in fixed}, fixed, 'fixed configuration')
    equal(report['requestedDrawingStrategy'], strategy, 'requested drawing strategy')
    need(report['drawingOverridePresent'] is measure, 'drawing selection source differs')
    D.drawing_snapshot(config['drawing'], strategy, released=True)
    R.snapshot(config['rendererStorage'], 'native', released=True)
    E.snapshot(config['effects'], 'reference', released=True)
    equal(report['inputManifestSHA256'], component['inputManifestSHA256'], 'input manifest binding')
    equal(report['inputCertificateSHA256'], certificate_hash, 'input certificate binding')
    equal(report['inputPreparationProcessIdentifier'], manifest['processIdentifier'], 'preparation PID binding')
    equal(report['inputCertificateProcessIdentifier'], certificate_pid, 'certificate PID binding')
    equal(report['inputOriginalEncodedBytes'], manifest['assets'][0]['pngBytes'], 'original encoded input accounting')
    equal(report['inputBaseEncodedBytes'], manifest['assets'][1]['pngBytes'], 'base encoded input accounting')
    equal(report['fixtureRetainedInputRasterBytes'], 0, 'fixture retained a duplicate raster')
    date_bounds(report['sessionDateBounds'])
    C.ordered_observations([report['entryMemory'], report['finalMemory']])
    D.all_memory(report)
    D.observation_times(report, report['entryMemory']['uptimeSeconds'] - .1, report['finalMemory']['uptimeSeconds'] + .1)
    need(report['finalMemory']['uptimeSeconds'] - report['entryMemory']['uptimeSeconds'] <= report['elapsedSeconds'] + .1, 'native observations exceed duration')
    samples(report['sampledMemory'], measure)
    if measure:
        equal(report['resourcePolicy'], {'historyMaxItems': 1, 'historyMaxBytes': 256 * 1024 * 1024,
            'pinMaxItems': 1, 'pinMaximumPixels': 100000000, 'pinMaximumDiskBytes': 536870912,
            'retirement': 'ordinary history/pin retention replacement, native close, group hide/show, final coordinator termination',
            'firstCycleCold': True, 'preliminaryFunctionalWorkInProcess': False, 'fixedRunOwnersPreservedAcrossCycles': True}, 'product retention policy')
        need(report['ownedTemporaryDirectoryRemoved'] is True and report['fixedRunOwnersReleased'] is True, 'owned cleanup incomplete')
        equal(report['ownedOpenDescriptorsAfterCleanup'], 0, 'owned file descriptors remain')
        owner(report['afterCloseOwnership'], released=True)
        owner(report['fixedRunOwnershipAfterRelease'], released=True)
        equal(report['fixedRunOwnershipAfterRelease']['created'], 5, 'fixed owner creation count')
        cycles(report, strategy)
        C.ordered_observations([report['entryMemory'], report['beforeWarmup'],
            *[x for row in report['cycles'] for x in (row['beforeMemory'], row['afterMemory'])], report['finalMemory']])


def certificate(report, directory, seed, input_profile):
    need(report['memoryComparisonExcluded'] is True, 'golden producer included in memory comparison')
    C.string(report['goldenSource'])
    seven = parse_document(report['originalDocumentBase64'])
    eight = parse_document(report['appliedDocumentBase64'])
    equal(seven, seed, 'certificate seed document')
    check_recipe(seven, eight, report['sessionDateBounds'])
    rows = report['goldens']
    need(type(rows) is list and len(rows) == 4 and [row.get('role') for row in rows] == list(GOLDEN), 'golden roles/order differs')
    paths, profile = {}, sha(input_profile)
    for row in rows:
        keys(row, {'role', 'rawFile', 'rawBytes', 'rawSHA256', 'width', 'height', 'canonical'}, 'golden raster')
        role = row['role']; w, h = DIMENSIONS[role]
        equal(row['rawFile'], role + '.rgba', 'golden raw filename')
        equal((row['width'], row['height']), (w, h), 'golden extent')
        equal(row['rawBytes'], w * h * 4, 'golden full byte count')
        equal(sha(row['rawSHA256']), GOLDEN[role], 'independent golden hash')
        C.canonical(row['canonical'], role if role in ('original', 'base') else 'current')
        equal(row['canonical']['colorSpaceICC_SHA256'], profile, 'golden profile')
        path = directory / row['rawFile']; data = read(path, w * h * 4)
        need(len(data) == w * h * 4 and C.digest(data) == GOLDEN[role], 'actual golden bytes differ from historical expectation')
        paths[role] = path
    return paths


def observations(report, copies):
    rows = report['cycles']; entry = report['entryMemory']; final = report['finalMemory']
    peak = report['sampledMemory']['total']['sampledPeakBytes']
    result = {'entryBytes': entry['counters'], 'finalBytes': final['counters'], 'sampledPeakBytes': peak,
        'entryToPeakDeltaBytes': {key: peak[key] - entry['counters'][key] for key in C.MEMORY},
        'entryToFinalDeltaBytes': delta(entry, final), 'warmupToFinalDeltaBytes': delta(rows[1]['afterMemory'], final),
        'measuredToFinalDeltaBytes': delta(rows[-1]['afterMemory'], final),
        'kernelPeakAtFinal': {'resident_size_peak': final['backingAccounting']['standard']['bytes']['resident_size_peak'],
            'ledger_phys_footprint_peak': final['backingAccounting']['standard']['ledgerBytes']['ledger_phys_footprint_peak']},
        'coldCycle': {'elapsedSeconds': rows[0]['elapsedSeconds'], 'deltaBytes': rows[0]['deltaBytes'],
            'entryToReleasedBytes': delta(entry, rows[0]['afterMemory'])},
        'cycles': [], 'evidenceCopies': copies, 'elapsedSeconds': report['elapsedSeconds'],
        'allEightCounters': list(C.MEMORY), 'fullBackingAccountingPreservedInRawReport': True,
        'memoryStabilityAssessed': False, 'universalRSSLimitApplied': False}
    for ordinal, row in enumerate(rows, 1):
        phases = {phase: report['sampledMemory']['phases'][f'cycle-{ordinal}-{phase}']['sampledPeakBytes'] for phase in SAMPLE_PHASES}
        points = report['checkpoints'][(ordinal-1)*len(CHECKPOINTS):ordinal*len(CHECKPOINTS)]
        actions = report['actions'][(ordinal-1)*len(ACTIONS):ordinal*len(ACTIONS)]
        result['cycles'].append({'ordinal': ordinal, 'warmup': ordinal <= 2, 'elapsedSeconds': row['elapsedSeconds'],
            'endpointBytes': row['afterMemory']['counters'], 'cycleDeltaBytes': delta(row['beforeMemory'], row['afterMemory']),
            'previousReleaseDeltaBytes': delta(rows[ordinal-2]['afterMemory'] if ordinal > 1 else report['beforeWarmup'], row['afterMemory']),
            'phaseSampledPeakBytes': phases,
            'phaseLatencySeconds': {item['phase']: item['elapsedSeconds'] for item in report['phaseTimings'][(ordinal-1)*7:ordinal*7]},
            'actionLatencySeconds': {action['name']: action['elapsedSeconds'] for action in actions},
            'checkpointIntervals': [{'from': a['phase'], 'to': b['phase'],
                'elapsedSeconds': b['memory']['uptimeSeconds'] - a['memory']['uptimeSeconds'],
                'deltaBytes': delta(a['memory'], b['memory'])} for a, b in zip(points, points[1:])],
            'ownershipAfterRelease': row['ownershipAfterRelease'], 'stateAfterRelease': row['afterReleaseState']})
    result['lateMeasuredIncrements'] = [item['previousReleaseDeltaBytes'] for item in result['cycles'][-3:]]
    return result


def decoder_build(root):
    directory = root / 'verification'
    compiler, compiler_hash = load(directory / 'compile-command.json')
    command(compiler, ['swiftc', 'scripts/verify-editable-product-pixels.swift', '-o', str(directory / 'pixel-verifier')], 120)
    source = read(Path(__file__).resolve().with_name('verify-editable-product-pixels.swift'), 131072)
    executable = read(directory / 'pixel-verifier', 64 * 1024 * 1024)
    need(len(executable) >= 32 and executable[:4] == bytes.fromhex('cffaedfe'), 'native decoder executable missing')
    return {'decoderSourceSHA256': C.digest(source), 'decoderExecutableSHA256': C.digest(executable),
        'decoderExecutableBytes': len(executable), 'decoderCompileCommandSHA256': compiler_hash}


def pixel_plan(root, cell, raw, launcher, bindings, cert_hash, files, all_exit):
    return {'protocol': PIXEL_PROTOCOL, 'measuredProcessIdentifier': raw['processIdentifier'],
        'ownedExitUptimeSeconds': launcher['finishUptimeSeconds'],
        'allMeasuredAppsExitUptimeSeconds': all_exit,
        'rawReportSHA256': bindings['rawReportSHA256'], 'certificateSHA256': cert_hash,
        **decoder_build(root), 'files': files}


def pixels(root, cell, expected_plan):
    directory = root / cell / 'verification'
    plan, plan_hash = load(directory / 'pixel-plan.json')
    equal(plan, expected_plan, 'post-exit decoder plan')
    result, result_hash = load(directory / 'pixel-report.json')
    keys(result, {'protocol', 'status', 'processIdentifier', 'startUptimeSeconds', 'memoryComparisonExcluded',
        'goldensGenerated', 'planSHA256', 'measuredProcessIdentifier', 'executablePath', 'executableSHA256',
        'executableBytes', 'files', 'finishUptimeSeconds'}, 'post-exit pixel report')
    equal(result['protocol'], PIXEL_PROTOCOL, 'decoder protocol'); equal(result['status'], 'verified', 'decoder status')
    need(result['memoryComparisonExcluded'] is True and result['goldensGenerated'] is False, 'decoder scope differs')
    equal(result['planSHA256'], plan_hash, 'decoder input plan digest')
    equal(result['measuredProcessIdentifier'], plan['measuredProcessIdentifier'], 'decoder measured PID')
    pid = integer(result['processIdentifier'], 1, 2**31-1)
    need(pid != plan['measuredProcessIdentifier'], 'decoder ran inside measured app')
    begin = number(result['startUptimeSeconds'], max(plan['ownedExitUptimeSeconds'], plan['allMeasuredAppsExitUptimeSeconds']))
    number(result['finishUptimeSeconds'], begin, begin + 300)
    executable = str(root / 'verification/pixel-verifier')
    equal(result['executablePath'], executable, 'decoder executable path')
    equal(result['executableSHA256'], plan['decoderExecutableSHA256'], 'decoder executable digest')
    equal(result['executableBytes'], plan['decoderExecutableBytes'], 'decoder executable byte count')
    rows = result['files']
    need(type(rows) is list and len(rows) == len(plan['files']), 'decoder skipped/added files')
    for actual, expected in zip(rows, plan['files']):
        equal(actual, {**expected, 'comparedBytes': expected['width'] * expected['height'] * 4,
            'rgbaSHA256': expected['goldenSHA256'], 'exact': True,
            'comparison': 'memcmp/full-premultiplied-sRGB-RGBA8-including-alpha'}, 'full decoded pixel comparison')
    wrapper, wrapper_hash = load(directory / 'decoder-command.json')
    command(wrapper, [executable, str(directory / 'pixel-plan.json'), str(directory / 'pixel-report.json')], 300, pid=pid)
    return {'planSHA256': plan_hash, 'pixelReportSHA256': result_hash, 'decoderCommandSHA256': wrapper_hash,
        'processIdentifier': pid, 'finishUptimeSeconds': result['finishUptimeSeconds'],
        'uniquePNGFilesVerified': len(rows), 'fullRGBABytesCompared': sum(row['comparedBytes'] for row in rows)}


def check(app, source, root, stage='complete', cell=None):
    need(stage in ('certify', 'preflight', 'complete'), 'invalid checker stage')
    need((stage == 'preflight' and cell in CELL_STRATEGIES) or (stage != 'preflight' and cell is None), 'invalid cell/stage selection')
    root = Path(root)
    need(root.is_absolute() and root.resolve(strict=True) == root and root.is_dir(), 'noncanonical evidence root')
    installed = installed_identity(app, source)
    # Revalidate upstream bytes and raw reports. A self-asserted checked summary
    # can never substitute for the preparation/certificate evidence.
    component = C.check(app, source, root, 'certify')
    manifest, _ = load(root / 'prepare/inputs.json', 262144)
    for asset in manifest['assets']:
        for field, maximum in (('pngFile', MAX_PNG), ('rawFile', asset['rawBytes'])):
            read(root / 'prepare' / asset[field], maximum)
    seed, _ = load(root / 'prepare/document.annotations', MAX_DOCUMENT)
    cert, cert_launcher, cert_bindings = product_process(root / 'product-certify', installed, certify=True)
    common(cert, installed, manifest, component, 'certify', component['certificateSHA256'], component['processIdentifiers']['certify'])
    goldens = certificate(cert, root / 'product-certify', seed, manifest['assets'][0]['canonical']['colorSpaceICC_SHA256'])
    need(component['evidenceBindings']['certify']['finishUptimeSeconds'] <= cert_launcher['launchBeganUptimeSeconds'], 'product certifier started before input certifier exited')
    pids = set(component['processIdentifiers'].values())
    need(cert['processIdentifier'] not in pids, 'golden certificate process reused input process')
    pids.add(cert['processIdentifier'])
    run_ids = {uuid_value(cert['runIdentifier'])}
    result = {'status': 'certified' if stage == 'certify' else 'preflight' if stage == 'preflight' else 'observed-and-independently-verified',
        'protocol': PROTOCOL, **installed, 'inputManifestSHA256': component['inputManifestSHA256'],
        'inputComponentCertificateSHA256': component['certificateSHA256'], 'productCertificateSHA256': cert_bindings['rawReportSHA256'],
        'independentRecipeSHA256': RECIPE_SHA256, 'certificateBindings': cert_bindings,
        'observedProcessExitRequired': True, 'nativeExecutionAttestedByChecker': False,
        'fullCorrectnessFixtureReplaced': False, 'memoryStabilityAssessed': False, 'productionDefaultsChanged': False,
        'outputPixelsIndependentlyVerified': stage == 'complete', 'observations': {}, 'evidenceBindings': {},
        'interpretation': 'Fixed 2+8 actual product lifecycles with programmatically seeded certified seven-layer payloads and owned native controls. '
            'All persisted versions are decoded only after the exact measured app exits. Eight overlapping self-task counters and non-atomic '
            'backing observations do not prove private graphics release; 50ms peaks may miss transients. No universal RSS limit or remedy verdict. '
            'Reference runs first, owned-srgb8 second; both exit before either output decoder runs. Cold means first cycle in a new process, '
            'not cold filesystem/system caches. Close differences remain preliminary pending a reversed-order run. '
            'Final renderer storage stays native and effects stay reference. This does not replace the full correctness/failure fixture.'}
    if stage == 'certify':
        return result
    selected = list(CELL_STRATEGIES)
    loaded = {name: product_process(root / name, installed) for name in selected}
    all_exit = max(value[1]['finishUptimeSeconds'] for value in loaded.values())
    last_exit = cert_launcher['finishUptimeSeconds']
    all_raster_work = []
    for name in selected:
        directory = root / name
        report, launcher, bindings = loaded[name]
        common(report, installed, manifest, component, 'measure', cert_bindings['rawReportSHA256'], cert['processIdentifier'], CELL_STRATEGIES[name])
        need(report['processIdentifier'] not in pids, 'measured process reused an input/certificate/cell PID')
        pids.add(report['processIdentifier'])
        run_id = uuid_value(report['runIdentifier'])
        need(run_id not in run_ids, 'measured run identifier reused')
        run_ids.add(run_id)
        need(launcher['launchBeganUptimeSeconds'] >= last_exit, 'measured processes overlap')
        files, copied = stages(report, directory, seed, goldens)
        plan = pixel_plan(root, name, report, launcher, bindings, cert_bindings['rawReportSHA256'], files, all_exit)
        if stage == 'preflight':
            if name == cell:
                path = directory / 'verification/pixel-plan.json'
                need(not os.path.lexists(path), 'pixel plan must be freshly created')
                path.write_text(json.dumps(plan, indent=2, sort_keys=True, allow_nan=False) + '\n')
        else:
            verified = pixels(root, name, plan)
            need(verified['processIdentifier'] not in pids, 'decoder PID aliases another process')
            pids.add(verified['processIdentifier'])
            bindings['pixelVerification'] = verified
        last_exit = launcher['finishUptimeSeconds']
        result['evidenceBindings'][name] = bindings
        result['observations'][name] = observations(report, copied)
        result['observations'][name]['drawingStrategy'] = CELL_STRATEGIES[name]
        result['observations'][name]['nativeProcessIdentifier'] = report['processIdentifier']
        all_raster_work.append([[{key: row[key] for key in ('role', 'expectedState', 'width', 'height')} for row in saved['rasters']] for saved in report['stages']])
    if stage == 'complete':
        equal(all_raster_work[0], all_raster_work[1], 'paired output work')
        baseline, candidate = (result['observations'][name] for name in CELL_STRATEGIES)
        result['candidateMinusReference'] = {field: {key: candidate[field][key] - baseline[field][key] for key in C.MEMORY}
            for field in ('entryBytes', 'finalBytes', 'sampledPeakBytes', 'entryToPeakDeltaBytes', 'entryToFinalDeltaBytes', 'warmupToFinalDeltaBytes')}
        result['candidateMinusReference']['elapsedSeconds'] = candidate['elapsedSeconds'] - baseline['elapsedSeconds']
        result['candidateMinusReference']['coldCycleSeconds'] = candidate['coldCycle']['elapsedSeconds'] - baseline['coldCycle']['elapsedSeconds']
        result['comparisonOrder'] = ['baseline', 'candidate']; result['reversedOrderReplicated'] = False
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--expected-source', required=True)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--stage', choices=('certify', 'preflight', 'complete'), default='complete')
    parser.add_argument('--cell', choices=tuple(CELL_STRATEGIES))
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(argv)
    result = {'status': 'failed', 'memoryStabilityAssessed': False, 'outputPixelsIndependentlyVerified': False,
        'productionDefaultsChanged': False, 'nativeExecutionAttestedByChecker': False}
    try:
        result = check(args.app, args.expected_source, args.root, args.stage, args.cell)
    except (ValueError, OSError, KeyError, TypeError, OverflowError, RecursionError, plistlib.InvalidFileException, zlib.error) as error:
        result['error'] = str(error)[:4096]
    text = json.dumps(result, indent=2, sort_keys=True, allow_nan=False) + '\n'
    args.output.write_text(text)
    print(text, end='')
    return 1 if result['status'] == 'failed' else 0


if __name__ == '__main__':
    sys.exit(main())
