"""Adversarial portable schema tests. Synthetic bytes never attest native execution."""
import base64
import copy
import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
import uuid

SCRIPTS = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


C = load('drawing_pair_check', SCRIPTS / 'check-editable-drawing-pair.py')
F = load('drawing_observation_fixture', SCRIPTS / 'tests/test_check_editable_observation_comparison.py')
N = F.F
REJECTED = (ValueError, KeyError, TypeError, FileNotFoundError)
FILES = {'native': 'editable-annotation-native.json', 'diagnostic': 'editable-annotation-observation.json',
         'drawing': 'editable-drawing-pair.json', 'launcher': 'launch.json.launcher.json',
         'wrapper': 'bounded-launch.json', 'envelope': 'launch.json'}


def full_memory(index=0, uptime=None):
    value = N.memory(index)
    for flavor in ('standard', 'purgeable'):
        part = value['backingAccounting'][flavor]
        part['bytes'] = {key: 100000 + index * 1000 for key in C.BACKING_BYTES |
                         (C.VOLATILE_BYTES if flavor == 'purgeable' else set())}
        part['ledgerBytes'] = {key: -1024 + index * 1000 for key in C.BACKING_LEDGERS}
    for key, count in value['counters'].items():
        source = value['backingAccounting']['purgeable']['ledgerBytes'] if key.startswith('ledger_') else (
            value['backingAccounting']['purgeable']['bytes'] if key.startswith('purgeable_') else
            value['backingAccounting']['standard']['bytes'])
        source[key] = count
    if uptime is not None:
        value['uptimeSeconds'] = uptime
        for part in value['backingAccounting'].values():
            part['observedAtUptimeSeconds'] = uptime - .001
    return value


def supplement_memory(value, offset):
    if isinstance(value, dict):
        if 'backingAccounting' in value:
            index = round((value['counters']['resident_size'] - 100000) / 1000)
            value.clear()
            value.update(full_memory(index, offset + index + 1))
        else:
            for child in value.values():
                supplement_memory(child, offset)
    elif isinstance(value, list):
        for child in value:
            supplement_memory(child, offset)


def memory_time(value, when):
    """Change fixture chronology without changing counters or accounting deltas."""
    value['uptimeSeconds'] = when
    for part in value['backingAccounting'].values():
        part['observedAtUptimeSeconds'] = when - .001


def documents(seed=1, date=800000001, scale=1):
    uid = lambda n: str(uuid.UUID(int=seed * 1000 + n))
    annotations = []
    for index in range(7):
        mark = {'id': uid(10 + index), 'tool': ('redact', 'blur', 'magnifier', 'spotlight', 'eraser', 'pixelate', 'pixelate')[index],
                'points': [[10 * scale, 20 * scale], [30 * scale, 40 * scale]], 'lineWidth': 3 * scale,
                'color': {'space': 'srgb', 'components': [0.2, 0.4, 0.6, 1]}, 'rotation': .08,
                'opacity': .8, 'strokeStyle': 'solid', 'frozenTimestamp': -978307200 if index % 2 == 0 else 500000000 + index,
                'frozenTimeZoneIdentifier': 'UTC', 'timestampIsCaptureDate': bool(index % 2)}
        if index >= 5:
            mark['mosaicLink'] = {'groupID': uid(30), 'additionID': uid(31), 'rootAdditionID': uid(31),
                                  'target': [[20, 30], [40, 50]], 'includedTargets': [[[20, 30], [40, 50]]],
                                  'excludedTargets': [], 'synchronizes': True}
        annotations.append(mark)
    original = {'format': 'picshot.editable-annotations', 'version': 1, 'coordinates': 'image-pixels-bottom-left',
                'documentID': uid(1), 'originalAssetID': uid(2), 'baseAssetID': uid(3),
                'capturedAt': date, 'captureTimestampKnown': False, 'captureTimeZoneIdentifier': 'UTC',
                'originalPixelWidth': 640 * scale, 'originalPixelHeight': 360 * scale,
                'basePixelWidth': 640 * scale, 'basePixelHeight': 360 * scale,
                'cropViewportInBase': [[80 * scale, 40 * scale], [400 * scale, 260 * scale]],
                'baseProvenance': 'synthetic', 'annotations': annotations,
                'numberSequence': {'nextValue': 1, 'isExhausted': False, 'closesGapsOnDelete': True},
                'outputDecoration': {'enabled': True, 'cornerRadius': 8, 'borderWidth': 2}}
    applied = copy.deepcopy(original)
    applied['annotations'].append({'id': uid(40), 'tool': 'rectangle', 'points': [[12, 18], [45, 80]],
                                  'lineWidth': 2, 'frozenTimestamp': date + 2,
                                  'timestampIsCaptureDate': False, 'frozenTimeZoneIdentifier': 'UTC'})
    return original, applied


def raw_document(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def replace_document(arm, workload_index, part, edit, refresh_sha=True):
    row = arm['drawing']['documents'][workload_index]
    key = part + 'Base64'
    value = json.loads(base64.b64decode(row[key]))
    edit(value)
    raw = raw_document(value)
    row[key] = base64.b64encode(raw).decode()
    if refresh_sha:
        native_case = C.cases(arm['native'])[row['workload']]
        native_case['documentSHA256' if part == 'original' else 'appliedDocumentSHA256'] = hashlib.sha256(raw).hexdigest()
        rebind(arm)


def rebind(arm):
    raw = json.dumps(arm['native'], sort_keys=True).encode()
    arm['native_bytes'] = raw
    for key in ('diagnostic', 'drawing'):
        arm[key]['nativeReportSHA256'] = hashlib.sha256(raw).hexdigest()
    if 'envelope' in arm:
        executable = arm['envelope']['arguments']
        arm['envelope'] = dict(copy.deepcopy(arm['native']), arguments=executable)
    return raw


def state(strategy, work=0):
    result = dict.fromkeys(C.DRAWING_INTEGERS, 0)
    result.update(unsupportedCounts={}, callbackSizesMatch=True)
    if strategy == 'reference':
        result['referenceCount'] = work
    else:
        for field in ('ownedCount', 'seededContextCount', 'allocations', 'deallocations', 'releaseCallbacks'):
            result[field] = work
        result['eligibleCount'] = 2 * work
        for field in ('allocatedBytes', 'deallocatedBytes', 'callbackBytes', 'seededContextBytes'):
            result[field] = work * 4096
        result['peakActiveBytes'] = 4096 if work else 0
    return result


def fixture(strategy='reference', resources=False, index=0, identity=None):
    diagnostic, native, _ = F.fixture('vimage' if resources else 'certify', resources)
    offset = 1000 * (index + 1)
    if identity is not None:
        native.update(identity)
    native['processIdentifier'] = 1234 + index
    supplement_memory(native, offset)
    for position, case in enumerate(native['functionalCases']):
        memory_time(case['afterReleaseMemory'], offset + 20 + position * 10)
    for position, shot in enumerate(native['functionalCases'][0]['visualEvidence']):
        memory_time(shot['whileSnapshotLiveMemory'], offset + 5 + position)
    if resources:
        observations = native['resources']
        memory_time(observations['beforeWarmup'], offset + 31)
        for position, case in enumerate(observations['warmups']):
            memory_time(case['beforeMemory'], offset + 32 + position * 7)
            memory_time(case['afterMemory'], offset + 38 + position * 7)
        memory_time(observations['afterWarmupBaseline'], offset + 46)
        for position, case in enumerate(observations['cycles']):
            memory_time(case['beforeMemory'], offset + 47 + position * 9)
            memory_time(case['afterMemory'], offset + 55 + position * 9)
        memory_time(observations['afterMeasuredCycles'], offset + 119)
    native['finalMemory'] = full_memory(20, offset + 130)
    for field in C.IDENTITY:
        diagnostic[field] = native[field]
    points = [{'workload': 'entry', 'label': 'native-entry', 'memory': full_memory(0, offset + .5),
               'drawing': state(strategy)}]
    work = 0
    for position, checkpoint in enumerate(diagnostic['checkpoints']):
        when = offset + 2 + position * .75
        checkpoint['observation']['uptimeSeconds'] = when + .01
        if checkpoint['label'] == 'workload-released':
            work += 1
        points.append({'workload': checkpoint['workload'], 'label': checkpoint['label'],
                       'memory': full_memory(position, when), 'drawing': state(strategy, work)})
    for position, row in enumerate(diagnostic['hashes']):
        row['before']['uptimeSeconds'] = offset + 2 + position * .5
        row['after']['uptimeSeconds'] = offset + 2.01 + position * .5
    date = 800000000 + index * 1000
    pair = {key: native[key] for key in C.IDENTITY}
    pair.update(schemaVersion=1, status='passed', drawingStrategy=strategy, hashObservation=diagnostic['mode'],
                maximumCheckpoints=256, maximumDocuments=12, maximumDocumentBytes=131072,
                sessionDateBounds={'beganReferenceDateSeconds': date, 'finishedReferenceDateSeconds': date + 130},
                checkpoints=points, documents=[], productDefaultsChanged=False, privateFrameworkReleaseClaim=False,
                scope='Synthetic schema test; no native execution or memory evidence')
    for position, (workload, native_case) in enumerate(C.cases(native).items()):
        original, applied = documents(seed=index * 100 + position + 1, date=date + 1, scale=1 if position == 0 else 6)
        row = {'workload': workload}
        for label, document in [('original', original), ('applied', applied)]:
            raw = raw_document(document)
            row[label + 'Base64'] = base64.b64encode(raw).decode()
            native_case['documentSHA256' if label == 'original' else 'appliedDocumentSHA256'] = hashlib.sha256(raw).hexdigest()
        pair['documents'].append(row)
    arm = {'native': native, 'diagnostic': diagnostic, 'drawing': pair,
           'lifecycle': {'launchBeganUptimeSeconds': offset, 'finishUptimeSeconds': offset + 140,
                         'wrapperStartEpochSeconds': date + 978307200, 'wrapperDurationSeconds': 141},
           'reportHashes': {key: 'a' * 64 for key in FILES}}
    rebind(arm)
    return arm


def validate(arm):
    resources = arm['native']['resourcesRequested']
    arm['inputs'] = C.O.validate_diagnostic(arm['diagnostic'], arm['native'], arm['native_bytes'],
                                           'vimage' if resources else 'certify', resources)
    arm['documents'] = C.validate_pair_sidecar(arm['drawing'], arm['native'], arm['native_bytes'], arm['diagnostic'],
                                              arm['drawing']['drawingStrategy'], resources)
    C.all_memory(arm['native'])
    return arm


def arms():
    return {name: validate(fixture(strategy, mode == 'resources', index))
            for index, (name, strategy, mode) in enumerate(C.CELLS)}


def identity_at(root):
    app = root / 'PicShot.app'
    executable = app / 'Contents/MacOS/PicShot'
    executable.parent.mkdir(parents=True)
    executable.write_bytes(bytes.fromhex('cffaedfe') + struct.pack('<I', 0x0100000c) + b'synthetic-not-executable')
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'PicShotSourceCommit': '2' * 40,
        'CFBundleShortVersionString': '0.17.0', 'CFBundleVersion': '105'}))
    return C.N.bundle_identity(app, '2' * 40)


def materialize(root, identity, strategy='reference', resources=False, index=0):
    directory = root / C.CELLS[index][0]
    directory.mkdir()
    arm = fixture(strategy, resources, index, identity)
    interval = arm['lifecycle']
    executable = str(Path(identity['bundlePath']) / 'Contents/MacOS/PicShot')
    mode = 'resources' if resources else 'certify'
    arm['launcher'] = {'schemaVersion': 1, 'status': 'exited', 'launcherExitCode': 0,
        'drawingStrategy': strategy, 'drawingMode': mode, 'hashObservation': 'vimage' if resources else 'certify',
        'selectedAppPath': identity['bundlePath'], 'createsNewApplicationInstance': True, 'timeoutSeconds': 600,
        'elapsedSeconds': 140, 'launchBeganUptimeSeconds': interval['launchBeganUptimeSeconds'],
        'finishUptimeSeconds': interval['finishUptimeSeconds'], 'callbackReceived': True, 'ownedExitConfirmed': True,
        'processStartMemoryCaptured': False, 'scope': 'Synthetic lifecycle, not a native run',
        'processIdentifier': arm['native']['processIdentifier'], 'launchedAppPath': identity['bundlePath'],
        'launchedExecutablePath': executable}
    arm['envelope'] = dict(copy.deepcopy(arm['native']), arguments=[executable])
    arm['wrapper'] = {'schema_version': 1, 'status': 'exited',
        'command': ['swift', 'scripts/launch-editable-drawing-pair.swift', identity['bundlePath'], str(directory / 'launch.json'), strategy, mode],
        'started_at': datetime.datetime.fromtimestamp(interval['wrapperStartEpochSeconds'], datetime.timezone.utc).isoformat(),
        'timeout_seconds': 620, 'grace_seconds': 5, 'max_log_bytes': C.N.MAX_BYTES, 'pid': 4321 + index,
        'child_returncode': 0, 'exit_code': 0, 'cancel_signal': None, 'sigterm_sent': False, 'sigkill_sent': False,
        'descendant_cleanup': False, 'output_bytes': 16, 'log_bytes': 16, 'log_truncated': False,
        'termination_reason': 'exited', 'duration_seconds': 141,
        'group_observation': {'backend': 'darwin-ps-pgrp', 'timeout_seconds': .5, 'count': 2, 'failures': 0,
                              'total_seconds': .02, 'max_seconds': .01, 'atomic_snapshot': False}}
    (directory / 'launcher.log').write_bytes(b'synthetic log\n  ')
    for name, data in N.visuals()[1].items():
        (directory / name).write_bytes(data)
    save(directory, arm)
    return directory, arm


def save(directory, arm):
    rebind(arm)
    for key, filename in FILES.items():
        (directory / filename).write_bytes(arm['native_bytes'] if key == 'native' else json.dumps(arm[key], sort_keys=True).encode())


class DrawingPairTests(unittest.TestCase):
    def test_complete_pair_has_35_certified_and_205_measured_hashes(self):
        values = arms()
        result = C.compare(values, 'pair')
        self.assertEqual(result['status'], 'compared')
        self.assertEqual(result['certificationWorkPerArm']['hashes'], 35)
        self.assertEqual(result['measuredWorkPerArm']['hashes'], 205)
        self.assertTrue(result['certificationExcludedFromMemoryComparison'])
        for key in ('memoryStabilityAssessed', 'productMemoryRemedyClaim', 'privateFrameworkReleaseClaim'):
            self.assertFalse(result[key])
        self.assertFalse(result['nativeExecutionAttestedByChecker'])
        measured = result['arms']['candidate']
        self.assertEqual(len(measured['everyMeasuredIncrementAccountingDelta']), 8)
        self.assertEqual(len(measured['lateAccountingDelta']), 3)
        self.assertEqual(len(measured['drawingCheckpoints']), 142)
        self.assertEqual(len(measured['snapshotWhileLiveMemory']), 4)
        self.assertEqual(measured['ownedDrawingFinal']['allocations'], 12)
        self.assertEqual(C.compare({key: values[key] for key, _, _ in C.CELLS[:2]}, 'certification')['status'], 'certified')

    def test_missing_changed_hashes_and_certification_are_rejected(self):
        mutations = {
            'missing-first': lambda a: a['diagnostic']['hashes'].pop(0),
            'missing-last': lambda a: a['diagnostic']['hashes'].pop(),
            'wrong-total': lambda a: a['diagnostic'].update(hashCount=34),
            'reordered': lambda a: a['diagnostic']['hashes'].reverse(),
            'changed-pixel': lambda a: a['diagnostic']['hashes'][0].update(sha256='0' * 64),
            'changed-alpha': lambda a: a['diagnostic']['hashes'][0]['input'].update(width=641),
            'conversion-count': lambda a: a['diagnostic'].update(conversionCount=1),
            'snapshot-count': lambda a: a['diagnostic'].update(snapshotCount=0),
            'native-sha': lambda a: a['diagnostic'].update(nativeReportSHA256='0' * 64),
            'source': lambda a: a['diagnostic'].update(sourceCommit='0' * 40),
            'executable': lambda a: a['diagnostic'].update(executableSHA256='0' * 64),
            'pid': lambda a: a['diagnostic'].update(processIdentifier=4321),
        }
        for resources in (False, True):
            for name, mutate in mutations.items():
                with self.subTest(resources=resources, change=name):
                    arm = fixture(resources=resources)
                    mutate(arm)
                    with self.assertRaises(REJECTED):
                        validate(arm)
        for field, value in [('everyRGBAByteEqual', False), ('candidateSHA256', '0' * 64), ('comparedBytes', 1)]:
            arm = fixture()
            arm['diagnostic']['hashes'][-1][field] = value
            with self.subTest(field=field), self.assertRaises(REJECTED):
                validate(arm)

    def test_pair_identity_scope_and_bounds_are_strict(self):
        changes = {'sourceCommit': '0' * 40, 'executableSHA256': '0' * 64, 'processIdentifier': 4321,
                   'architecture': 'x86_64', 'nativeReportSHA256': '0' * 64, 'resourcesRequested': True,
                   'hashObservation': 'cgcontext', 'drawingStrategy': 'unknown', 'status': 'failed',
                   'productDefaultsChanged': True, 'privateFrameworkReleaseClaim': True,
                   'maximumDocuments': 13, 'maximumDocumentBytes': 131073, 'maximumCheckpoints': 257, 'schemaVersion': True}
        for field, value in changes.items():
            arm = fixture()
            arm['drawing'][field] = value
            with self.subTest(field=field), self.assertRaises(REJECTED):
                C.validate_pair_sidecar(arm['drawing'], arm['native'], arm['native_bytes'], arm['diagnostic'], 'reference', False)

    def test_ephemeral_uuids_and_in_process_session_dates_canonicalize(self):
        first = documents(1, 800000001)
        second = documents(2, 800001001)
        before = copy.deepcopy(first)
        one = C.canonical_documents(*first, {'beganReferenceDateSeconds': 800000000, 'finishedReferenceDateSeconds': 800000100})
        two = C.canonical_documents(*second, {'beganReferenceDateSeconds': 800001000, 'finishedReferenceDateSeconds': 800001100})
        self.assertEqual(one, two)
        self.assertEqual(first, before, 'canonicalization must not mutate raw document objects')
        self.assertEqual([a['frozenTimestamp'] for a in one[0]['annotations']],
                         [-978307200, 500000001, -978307200, 500000003, -978307200, 500000005, -978307200])

    def test_uuid_equality_and_mosaic_linkage_changes_are_not_dropped(self):
        changes = {
            'asset-alias': lambda o, a: o.update(baseAssetID=o['originalAssetID']),
            'annotation-alias': lambda o, a: o['annotations'][1].update(id=o['annotations'][0]['id']),
            'applied-document': lambda o, a: a.update(documentID=str(uuid.UUID(int=900000))),
            'applied-annotation': lambda o, a: a['annotations'][0].update(id=str(uuid.UUID(int=900000))),
            'mosaic-group': lambda o, a: o['annotations'][6]['mosaicLink'].update(groupID=str(uuid.UUID(int=900000))),
            'mosaic-root': lambda o, a: o['annotations'][5]['mosaicLink'].update(rootAdditionID=str(uuid.UUID(int=900000))),
        }
        bounds = {'beganReferenceDateSeconds': 800000000, 'finishedReferenceDateSeconds': 800000100}
        expected = C.canonical_documents(*documents(), bounds)
        for name, mutate in changes.items():
            original, applied = documents()
            mutate(original, applied)
            with self.subTest(change=name):
                self.assertNotEqual(C.canonical_documents(original, applied, bounds), expected)

    def test_unlisted_uuid_and_date_paths_retain_their_exact_values(self):
        bounds = {'beganReferenceDateSeconds': 800000000, 'finishedReferenceDateSeconds': 800000100}
        original, applied = documents()
        for document in (original, applied):
            document['unknown'] = {'id': str(uuid.UUID(int=900000)), 'capturedAt': 800000001}
            document['annotations'][0]['unknown'] = {'documentID': str(uuid.UUID(int=900001)), 'frozenTimestamp': 800000002}
        expected = C.canonical_documents(original, applied, bounds)
        for name in ('root-id', 'root-date', 'nested-id', 'nested-date'):
            first, second = copy.deepcopy((original, applied))
            for document in (first, second):
                if name == 'root-id':
                    document['unknown']['id'] = str(uuid.UUID(int=900099))
                elif name == 'root-date':
                    document['unknown']['capturedAt'] += 1
                elif name == 'nested-id':
                    document['annotations'][0]['unknown']['documentID'] = str(uuid.UUID(int=900099))
                else:
                    document['annotations'][0]['unknown']['frozenTimestamp'] += 1
            with self.subTest(change=name):
                self.assertNotEqual(C.canonical_documents(first, second, bounds), expected)

    def test_only_explicit_session_dates_are_normalized(self):
        bounds = {'beganReferenceDateSeconds': 800000000, 'finishedReferenceDateSeconds': 800000100}
        for field, value in [('capturedAt', 799999999), ('capturedAt', '2026-10-08'), ('capturedAt', float('nan'))]:
            original, applied = documents()
            original[field] = value
            with self.subTest(value=value), self.assertRaises(REJECTED):
                C.canonical_documents(original, applied, bounds)
        original, applied = documents()
        applied['annotations'][7]['frozenTimestamp'] = 800000101
        with self.assertRaises(REJECTED):
            C.canonical_documents(original, applied, bounds)
        original, applied = documents()
        original.update(captureTimestampKnown=True, capturedAt=-978307200)
        applied.update(captureTimestampKnown=True, capturedAt=-978307200)
        applied['annotations'][7].update(timestampIsCaptureDate=True, frozenTimestamp=-978307200)
        result = C.canonical_documents(original, applied, bounds)
        self.assertEqual(result[0]['capturedAt'], -978307200)
        self.assertEqual(result[1]['annotations'][7]['frozenTimestamp'], -978307200)
        for target in (original, applied):
            target['capturedAt'] += 1
        self.assertNotEqual(result, C.canonical_documents(original, applied, bounds))

    def test_styles_geometry_unknown_keys_and_first_seven_dates_are_preserved(self):
        changes = {
            'style': lambda d: d['annotations'][0].update(lineWidth=99),
            'geometry': lambda d: d['annotations'][0]['points'][0].__setitem__(0, 99),
            'first-epoch': lambda d: d['annotations'][0].update(frozenTimestamp=-978307199),
            'first-known': lambda d: d['annotations'][1].update(frozenTimestamp=500000099),
            'timezone': lambda d: d['annotations'][1].update(frozenTimeZoneIdentifier='Europe/London'),
            'timestamp-flag': lambda d: d['annotations'][1].update(timestampIsCaptureDate=False),
            'boolean-as-number': lambda d: d['outputDecoration'].update(enabled=1),
            'number-as-boolean': lambda d: d['numberSequence'].update(nextValue=True),
            'root-extra': lambda d: d.update(extra={'id': 'unlisted-id', 'createdAt': 123}),
            'annotation-extra': lambda d: d['annotations'][0].update(extra={'id': 'unlisted-id', 'timestamp': 123}),
            'order': lambda d: d['annotations'].__setitem__(slice(0, 7), list(reversed(d['annotations'][:7]))),
        }
        for name, mutate in changes.items():
            pair = arms()
            candidate = pair['candidate']
            replace_document(candidate, 0, 'original', mutate)
            replace_document(candidate, 0, 'applied', mutate)
            validate(candidate)
            with self.subTest(change=name), self.assertRaises(ValueError):
                C.compare_work(pair['baseline'], candidate)

    def test_raw_document_sha_encoding_and_workload_binding_are_checked(self):
        mutations = {
            'stale-document-sha': lambda a: replace_document(a, 0, 'original', lambda d: d.update(baseProvenance='changed'), False),
            'missing-document': lambda a: a['drawing']['documents'].pop(),
            'reordered-document': lambda a: a['drawing']['documents'].reverse(),
            'invalid-base64': lambda a: a['drawing']['documents'][0].update(originalBase64='!!!'),
            'bad-document-sha': lambda a: a['native']['functionalCases'][0].update(documentSHA256='0' * 64),
            'missing-annotation': lambda a: replace_document(a, 0, 'original', lambda d: d['annotations'].pop()),
            'invalid-uuid': lambda a: replace_document(a, 0, 'applied', lambda d: d.update(documentID='not-a-uuid')),
        }
        for name, mutate in mutations.items():
            arm = fixture()
            mutate(arm)
            if name == 'bad-document-sha':
                rebind(arm)
            with self.subTest(change=name), self.assertRaises(REJECTED):
                validate(arm)
        for raw in (b'{"a":1,"a":2}', b'{"capturedAt":NaN}', b'{"capturedAt":1e999}', b'[]', b' ' * 131073):
            with self.subTest(raw=raw[:40]), self.assertRaises(REJECTED):
                C.parse_document(base64.b64encode(raw).decode())

    def test_applied_document_preserves_all_original_metadata_within_process(self):
        changes = {
            'root-id': lambda d: d.update(documentID=str(uuid.UUID(int=900000))),
            'root-date': lambda d: d.update(capturedAt=d['capturedAt'] + 1),
            'root-style': lambda d: d['outputDecoration'].update(borderWidth=3),
            'annotation-id': lambda d: d['annotations'][0].update(id=str(uuid.UUID(int=900000))),
            'annotation-style': lambda d: d['annotations'][0].update(lineWidth=4),
            'annotation-date': lambda d: d['annotations'][0].update(frozenTimestamp=-978307199),
            'bool-number': lambda d: d['outputDecoration'].update(enabled=1),
            'added-tool': lambda d: d['annotations'][7].update(tool='ellipse'),
        }
        for name, edit in changes.items():
            arm = fixture('owned-srgb8')
            replace_document(arm, 0, 'applied', edit)
            with self.subTest(change=name), self.assertRaises(REJECTED):
                validate(arm)

    def test_all_backing_memory_fields_are_required_in_each_flavor(self):
        valid = full_memory()
        C.complete_memory(valid)
        self.assertEqual(set(valid['counters']), C.N.MEMORY)
        for flavor in ('standard', 'purgeable'):
            for kind in ('bytes', 'ledgerBytes'):
                for field in valid['backingAccounting'][flavor][kind]:
                    value = copy.deepcopy(valid)
                    del value['backingAccounting'][flavor][kind][field]
                    with self.subTest(flavor=flavor, kind=kind, field=field), self.assertRaises(REJECTED):
                        C.complete_memory(value)
        for field in C.N.MEMORY:
            value = copy.deepcopy(valid)
            del value['counters'][field]
            with self.subTest(counter=field), self.assertRaises(REJECTED):
                C.complete_memory(value)

    def test_full_accounting_retains_graphics_media_reusable_and_signed_deltas(self):
        before, after = full_memory(0), full_memory(1)
        for flavor in ('standard', 'purgeable'):
            after['backingAccounting'][flavor]['bytes']['reusable'] = 90000
            after['backingAccounting'][flavor]['ledgerBytes']['ledger_tag_media_nofootprint'] = -4096
        delta = C.accounting_delta(before, after)
        for flavor in ('standard', 'purgeable'):
            for kind in ('bytes', 'ledgerBytes'):
                expected = dict.fromkeys(before['backingAccounting'][flavor][kind], 1000)
                if kind == 'bytes':
                    expected['reusable'] = -10000
                else:
                    expected['ledger_tag_media_nofootprint'] = -3072
                self.assertEqual(delta['backingAccounting'][flavor][kind], expected)
            self.assertEqual(delta['backingAccounting'][flavor]['bytes']['reusable'], -10000)
            self.assertEqual(delta['backingAccounting'][flavor]['ledgerBytes']['ledger_tag_media_nofootprint'], -3072)
            self.assertEqual(delta['backingAccounting'][flavor]['ledgerBytes']['ledger_tag_graphics_footprint'], 1000)
        result = C.compare(arms(), 'pair')
        for name in ('baseline', 'candidate'):
            measured = result['arms'][name]
            self.assertEqual(measured['entryToFinalAccountingDelta'],
                             C.accounting_delta(measured['entryMemory'], measured['finalMemory']))
            self.assertEqual(len(measured['entryMemory']['counters']), 8)
            self.assertEqual(len(measured['measuredMemory']), 8)
            self.assertEqual(len(measured['warmupMemory']), 2)

    def test_missing_deep_native_and_checkpoint_accounting_is_rejected(self):
        for path in ('entry', 'final', 'functional', 'snapshot', 'warmup', 'measured', 'checkpoint'):
            arm = fixture(resources=True)
            target = {'entry': arm['native']['entryMemory'], 'final': arm['native']['finalMemory'],
                      'functional': arm['native']['functionalCases'][0]['afterReleaseMemory'],
                      'snapshot': arm['native']['functionalCases'][0]['visualEvidence'][0]['whileSnapshotLiveMemory'],
                      'warmup': arm['native']['resources']['warmups'][0]['beforeMemory'],
                      'measured': arm['native']['resources']['cycles'][-1]['afterMemory'],
                      'checkpoint': arm['drawing']['checkpoints'][5]['memory']}[path]
            del target['backingAccounting']['standard']['ledgerBytes']['ledger_tag_graphics_nofootprint']
            rebind(arm)
            with self.subTest(path=path), self.assertRaises(REJECTED):
                validate(arm)

    def test_drawing_provider_failures_fallbacks_and_release_arithmetic_rejected(self):
        good = state('owned-srgb8', 2)
        C.drawing_snapshot(good, 'owned-srgb8', released=True)
        changes = {'failureCount': 1, 'presentationFallbackCount': 1, 'callbackSizesMatch': False,
                   'referenceCount': 1, 'eligibleCount': 1, 'ownedCount': 1, 'allocations': 1,
                   'deallocations': 1, 'releaseCallbacks': 1, 'allocatedBytes': 8193, 'deallocatedBytes': 8191,
                   'callbackBytes': 8191, 'activeBytes': 1, 'peakActiveBytes': 800000001,
                   'seededContextBytes': 0, 'seededContextCount': 0, 'presentationReuseCount': True}
        for field, value in changes.items():
            snapshot = copy.deepcopy(good)
            snapshot[field] = value
            with self.subTest(field=field), self.assertRaises(REJECTED):
                C.drawing_snapshot(snapshot, 'owned-srgb8', released=True)
        for counts in ({'unknownReason': 1}, {'imageMask': 0}, {'imageMask': True}):
            snapshot = copy.deepcopy(good)
            snapshot['unsupportedCounts'] = counts
            with self.subTest(unsupported=counts), self.assertRaises(REJECTED):
                C.drawing_snapshot(snapshot, 'owned-srgb8')
        with self.assertRaises(REJECTED):
            C.drawing_snapshot(good, 'reference')
        with self.assertRaises(REJECTED):
            C.drawing_snapshot(state('owned-srgb8', 1), 'owned-srgb8', good)
        old = copy.deepcopy(good)
        old['unsupportedCounts'] = {'imageMask': 1}
        with self.assertRaises(REJECTED):
            C.drawing_snapshot(good, 'owned-srgb8', old)

    def test_in_flight_callback_before_deinit_is_retained_until_release(self):
        pending = state('owned-srgb8', 2)
        pending.update(deallocations=0, deallocatedBytes=0, activeBytes=8192, peakActiveBytes=8192)
        C.drawing_snapshot(pending, 'owned-srgb8')
        with self.assertRaises(REJECTED):
            C.drawing_snapshot(pending, 'owned-srgb8', released=True)
        published = copy.deepcopy(pending)
        published['ownedCount'] = 1
        C.drawing_snapshot(published, 'owned-srgb8')
        finished = state('owned-srgb8', 2)
        finished['peakActiveBytes'] = 8192
        C.drawing_snapshot(finished, 'owned-srgb8', pending, released=True)
        for field in C.DRAWING_INTEGERS | {'unsupportedCounts', 'callbackSizesMatch'}:
            missing = copy.deepcopy(finished)
            missing.pop(field)
            with self.subTest(missing=field), self.assertRaises(REJECTED):
                C.drawing_snapshot(missing, 'owned-srgb8', released=True)

    def test_every_workload_requires_drawing_and_released_providers(self):
        for strategy in C.STRATEGIES:
            arm = fixture(strategy, True)
            for point in arm['drawing']['checkpoints']:
                point['drawing'] = state(strategy, 0)
            with self.subTest(strategy=strategy), self.assertRaises(REJECTED):
                validate(arm)
        arm = fixture('owned-srgb8')
        endpoint = next(p for p in arm['drawing']['checkpoints'] if p['label'] == 'workload-released')
        endpoint['drawing'].update(deallocations=0, releaseCallbacks=0, deallocatedBytes=0, callbackBytes=0, activeBytes=4096)
        with self.assertRaises(REJECTED):
            validate(arm)

    def test_checkpoint_order_missing_and_clock_mutations_are_rejected(self):
        changes = {
            'missing': lambda a: a['drawing']['checkpoints'].pop(4),
            'reversed': lambda a: a['drawing']['checkpoints'].reverse(),
            'backward': lambda a: a['drawing']['checkpoints'][5]['memory'].update(uptimeSeconds=0),
            'after-observer': lambda a: a['drawing']['checkpoints'][4]['memory'].update(uptimeSeconds=1500),
            'entry-late': lambda a: a['drawing']['checkpoints'][0]['memory'].update(uptimeSeconds=1001.5),
        }
        for name, mutate in changes.items():
            arm = fixture()
            mutate(arm)
            with self.subTest(change=name), self.assertRaises(REJECTED):
                validate(arm)

    def test_cross_process_native_work_identity_and_observer_scope_are_matched(self):
        changes = {
            'source': lambda a: a['native'].update(sourceCommit='0' * 40),
            'exe': lambda a: a['native'].update(executableSHA256='0' * 64),
            'size': lambda a: a['native'].update(executableBytes=1),
            'architecture': lambda a: a['native'].update(architecture='x86_64'),
            'native-png': lambda a: a['native']['functionalCases'][0].update(originalPNGSHA256='0' * 64),
            'native-assertion': lambda a: a['native']['functionalCases'][0]['assertions'].update(nativeHistorySave=False),
            'source-pixels': lambda a: a['inputs'].__setitem__(('functional-small', 'source'), (a['inputs'][('functional-small', 'source')][0], '0' * 64)),
            'alpha': lambda a: a['inputs'][('functional-small', 'source')][0].update(alphaInfo=5),
            'color': lambda a: a['inputs'][('functional-small', 'source')][0].update(colorSpaceICC_SHA256='0' * 64),
            'work': lambda a: a['diagnostic'].update(conversionCount=410),
            'geometry': lambda a: a['native']['functionalCases'][0]['visualEvidence'][0].update(imageScreenFrame=[221, 220, 400, 260]),
            'strategy': lambda a: a['drawing'].update(drawingStrategy='reference'),
            'resource-scope': lambda a: a['native'].update(resourcesRequested=False),
            'overlap': lambda a: a['lifecycle'].update(launchBeganUptimeSeconds=1),
        }
        for name, mutate in changes.items():
            values = arms()
            mutate(values['candidate'])
            with self.subTest(change=name), self.assertRaises(REJECTED):
                C.compare(values, 'pair')
        values = arms()
        values.pop('candidate-certification')
        with self.assertRaises(REJECTED):
            C.compare(values, 'pair')
        for strategy, resources, mode in [('reference', True, 'cgcontext'), ('owned-srgb8', False, 'vimage')]:
            arm = fixture(strategy, resources)
            arm['diagnostic']['mode'] = mode
            with self.subTest(mode=mode), self.assertRaises(REJECTED):
                validate(arm)

    def test_measured_work_must_match_its_own_independent_certificate(self):
        values = arms()
        for name in ('baseline', 'candidate'):
            p, digest = values[name]['inputs'][('measured-8', 'reference-crop')]
            values[name]['inputs'][('measured-8', 'reference-crop')] = p, '0' * 64
        with self.assertRaisesRegex(ValueError, 'independently certified'):
            C.compare(values, 'pair')

    def test_real_file_load_and_four_process_comparison(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(strict=True)
            identity = identity_at(root)
            values = {}
            for index, (name, strategy, mode) in enumerate(C.CELLS):
                directory, _ = materialize(root, identity, strategy, mode == 'resources', index)
                values[name] = C.load_cell(directory, identity, strategy, mode)
            result = C.compare(values, 'pair')
            self.assertEqual(result['status'], 'compared')
            self.assertFalse(result['memoryStabilityAssessed'])
            self.assertEqual(len({a['native']['processIdentifier'] for a in values.values()}), 4)
            for arm in values.values():
                for key, filename in FILES.items():
                    self.assertEqual(arm['reportHashes'][key], hashlib.sha256((Path(arm['directory']) / filename).read_bytes()).hexdigest())

    def test_file_loading_rejects_lifecycle_deadline_and_native_identity_changes(self):
        mutations = {
            'native-deadline-300': lambda a: a['native'].update(deadlineSeconds=301),
            'native-elapsed': lambda a: a['native'].update(elapsedSeconds=301),
            'native-source': lambda a: a['native'].update(sourceCommit='0' * 40),
            'native-exe': lambda a: a['native'].update(executableSHA256='0' * 64),
            'launcher-pid': lambda a: a['launcher'].update(processIdentifier=9999),
            'launcher-600': lambda a: a['launcher'].update(timeoutSeconds=601),
            'launcher-elapsed': lambda a: a['launcher'].update(elapsedSeconds=601),
            'wrapper-620': lambda a: a['wrapper'].update(timeout_seconds=621),
            'wrapper-elapsed': lambda a: a['wrapper'].update(duration_seconds=621),
            'new-instance': lambda a: a['launcher'].update(createsNewApplicationInstance=False),
            'callback': lambda a: a['launcher'].update(callbackReceived=False),
            'exit': lambda a: a['launcher'].update(ownedExitConfirmed=False),
            'birth-memory': lambda a: a['launcher'].update(processStartMemoryCaptured=True),
            'selected-path': lambda a: a['launcher'].update(selectedAppPath='/elsewhere/PicShot.app'),
            'executable-path': lambda a: a['launcher'].update(launchedExecutablePath='/elsewhere/PicShot'),
            'argv': lambda a: a['envelope'].update(arguments=['wrong']),
            'command-mode': lambda a: a['wrapper']['command'].__setitem__(-1, 'resources'),
            'outside-launch': lambda a: a['launcher'].update(launchBeganUptimeSeconds=1002),
            'outside-finish': lambda a: a['launcher'].update(finishUptimeSeconds=1100),
            'wrapper-short': lambda a: a['wrapper'].update(duration_seconds=100),
            'group-probe-failure': lambda a: a['wrapper']['group_observation'].update(failures=1),
            'cleanup': lambda a: a['wrapper'].update(descendant_cleanup=True),
            'naive-start': lambda a: a['wrapper'].update(started_at='2026-10-08T12:00:00'),
            'wall-clock': lambda a: a['wrapper'].update(started_at='2001-01-01T00:00:00+00:00'),
            'date-bounds': lambda a: a['drawing']['sessionDateBounds'].update(finishedReferenceDateSeconds=800000700),
            'hash-before-birth': lambda a: a['diagnostic']['hashes'][0]['before'].update(uptimeSeconds=999),
            'hash-after-exit': lambda a: a['diagnostic']['hashes'][-1]['after'].update(uptimeSeconds=1141),
            'task-info-before-birth': lambda a: a['native']['functionalCases'][0]['afterReleaseMemory']['backingAccounting']['standard'].update(observedAtUptimeSeconds=999),
            'snapshot-after-exit': lambda a: a['native']['functionalCases'][0]['visualEvidence'][0]['whileSnapshotLiveMemory'].update(uptimeSeconds=1141),
        }
        for name, mutate in mutations.items():
            with self.subTest(change=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve(strict=True)
                identity = identity_at(root)
                directory, arm = materialize(root, identity)
                mutate(arm)
                save(directory, arm)
                with self.assertRaises(REJECTED):
                    C.load_cell(directory, identity, 'reference', 'certify')

    def test_actual_png_bytes_crc_rgba_and_regular_files_are_verified(self):
        for change in ('missing', 'linked', 'bytes', 'crc', 'rgba', 'log-size', 'report-link', 'stale-native-bytes', 'launcher-status'):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve(strict=True)
                identity = identity_at(root)
                directory, arm = materialize(root, identity)
                entry = arm['native']['functionalCases'][0]['visualEvidence'][0]
                path = directory / entry['filename']
                if change == 'missing':
                    path.unlink()
                elif change == 'linked':
                    target = directory / 'target.png'
                    path.rename(target)
                    path.symlink_to(target)
                elif change in ('bytes', 'crc'):
                    data = bytearray(path.read_bytes())
                    data[-15] ^= 1
                    path.write_bytes(data)
                    if change == 'crc':
                        entry['sha256'] = hashlib.sha256(data).hexdigest()
                        save(directory, arm)
                elif change == 'rgba':
                    entry['rgbaSHA256'] = '0' * 64
                    save(directory, arm)
                elif change == 'log-size':
                    (directory / 'launcher.log').write_bytes(b'changed')
                elif change == 'report-link':
                    report = directory / FILES['drawing']
                    report.rename(directory / 'target.json')
                    report.symlink_to(directory / 'target.json')
                elif change == 'stale-native-bytes':
                    with (directory / FILES['native']).open('ab') as handle:
                        handle.write(b'\n')
                with self.assertRaises(REJECTED):
                    C.load_cell(directory, identity, 'reference', 'certify', launcher_status=1 if change == 'launcher-status' else 0)

    def test_native_endpoint_order_and_snapshot_interval_are_verified(self):
        mutations = {
            'functional-order': lambda n: memory_time(n['functionalCases'][1]['afterReleaseMemory'], 3019),
            'warmup-baseline': lambda n: memory_time(n['resources']['afterWarmupBaseline'], 3040),
            'measured-order': lambda n: memory_time(n['resources']['cycles'][1]['beforeMemory'], 3050),
            'cleanup-order': lambda n: memory_time(n['resources']['afterMeasuredCycles'], 3117),
            'snapshot-after-small': lambda n: memory_time(n['functionalCases'][0]['visualEvidence'][0]['whileSnapshotLiveMemory'], 3021),
            'missing-warmup': lambda n: n['resources']['warmups'].pop(),
            'missing-measured': lambda n: n['resources']['cycles'].pop(),
        }
        for name, mutate in mutations.items():
            with self.subTest(change=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve(strict=True)
                identity = identity_at(root)
                directory, arm = materialize(root, identity, 'reference', True, 2)
                mutate(arm['native'])
                save(directory, arm)
                with self.assertRaises(REJECTED):
                    C.load_cell(directory, identity, 'reference', 'resources')


if __name__ == '__main__':
    unittest.main()
