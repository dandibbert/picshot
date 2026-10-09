"""Hostile report-schema checks only. None of these inputs is native evidence."""
import copy
import functools
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
import zlib

SPEC = importlib.util.spec_from_file_location('editable_check', Path(__file__).resolve().parents[1] / 'check-editable-annotation-report.py')
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


def png(width, height, color):
    def chunk(kind, payload):
        return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload) & 0xffffffff)
    row = b''.join(bytes([(color + x % 32) % 256, color // 2, 31, 255]) for x in range(width))
    body = (b'\0' + row) * height
    data = (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(body)) + chunk(b'IEND', b''))
    return data, hashlib.sha256(row * height).hexdigest()


@functools.lru_cache(maxsize=1)
def visuals():
    result, files = [], {}
    for index, (name, (kind, appearance)) in enumerate(CHECK.VISUAL_NAMES.items()):
        width, height = (640, 360) if kind == 'reopenedEditor' else (414, 274)
        data, pixels = png(width, height, 70 + 35 * index); files[name] = data
        controls = [{'id': value, 'frame': [12 + 40 * n, 310, 32, 32], 'nativeHitVerified': True}
                    for n, value in enumerate(sorted(CHECK.VISUAL_CONTROLS))] if kind == 'reopenedEditor' else []
        result.append({'filename': name, 'sha256': hashlib.sha256(data).hexdigest(), 'rgbaSHA256': pixels,
            'byteCount': len(data), 'pixelWidth': width, 'pixelHeight': height, 'kind': kind, 'appearance': appearance,
            'windowFrame': [100, 200, width, height], 'contentBounds': [0, 0, width, height],
            'imageScreenFrame': [220, 220, 400, 260] if controls else [100, 200, width, height],
            'viewportScreenFrame': [216, 206, 414, 274] if controls else [100, 200, width, height],
            'cropViewportInBase': [80, 40, 400, 260], 'toolbarFrame': [8, 306, 300, 40] if controls else [],
            'controls': controls, 'imageNativeHitVerified': True, 'whileSnapshotLiveMemory': memory(index), 'scope': 'Synthetic schema PNG, never native evidence'})
    return result, files


def memory(index=0):
    counters = {name: 100000 + index * 1000 for name in CHECK.MEMORY}
    values = {}
    for label, flavor in [('standard', 'TASK_VM_INFO'), ('purgeable', 'TASK_VM_INFO_PURGEABLE')]:
        values[label] = {'flavor': flavor, 'kernelReturn': 0, 'requestedNaturalCount': 100,
                         'returnedNaturalCount': 100, 'observedAtUptimeSeconds': index,
                         'pageSizeBytes': 16384, 'regionCount': 40,
                         'bytes': {key: value for key, value in counters.items() if not key.startswith('ledger_')},
                         'ledgerBytes': {key: value for key, value in counters.items() if key.startswith('ledger_')}}
    return {'uptimeSeconds': index + 0.01, 'counters': counters, 'backingAccounting': values}


def ownership(width, height):
    expected = {'editor': 5, 'canvas': 5, 'content': 5, 'window': 7, 'pin': 2, 'store': 4}
    return {role: {'created': expected.get(role, 10), 'alive': 1 if role == 'window' else 0,
                   'peakConcurrent': 1, 'peakKnownBytes': width * height * 4 if role in ('original', 'base', 'current', 'canonical') else 0}
            for role in CHECK.ROLES}


def case(width, height, profile=None, index=None, phase=None):
    output = 'a' * 64
    result = {'width': width, 'height': height, 'fullBasePixels': width * height,
              'viewportPixels': (width // 640 * 400) * (width // 640 * 260),
              'outputWidth': width // 640 * 400 + 14, 'outputHeight': width // 640 * 260 + 14,
              'layerCount': 7, 'originalAndBaseAreDistinct': True,
              'visualEvidence': copy.deepcopy(visuals()[0]) if profile == 'small' and index is None else [],
              'sourcePixelsSHA256': 'b' * 64, 'basePixelsSHA256': 'c' * 64,
              'expectedOutputPixelsSHA256': output, 'persistedOutputPixelsSHA256': output,
              'reopenedOutputPixelsSHA256': output, 'ordinaryExportPixelsSHA256': output,
              'hiddenPixelsSHA256': 'd' * 64, 'originalExportPixelsSHA256': 'b' * 64,
              'appliedLayerCount': 8, 'appliedDocumentSHA256': '5' * 64,
              'appliedExpectedOutputPixelsSHA256': '6' * 64, 'appliedPersistedOutputPixelsSHA256': '6' * 64,
              'appliedReopenedOutputPixelsSHA256': '6' * 64,
              'originalPNGSHA256': 'e' * 64, 'basePNGSHA256': 'f' * 64, 'documentSHA256': '1' * 64,
              'assertions': dict.fromkeys(CHECK.ASSERTIONS, True), 'ownershipAfterRelease': ownership(width, height),
              'windowContentGraphsAfterRelease': 0, 'ownedOpenDescriptorsAfter': 0}
    if index is None:
        result.update(profile=profile, afterReleaseMemory=memory(2))
    else:
        result.update(index=index, phase=phase, beforeMemory=memory(index + 4), afterMemory=memory(index + 5),
                      temporaryDirectoryRemoved=True, activeExportControllersAfter=0, projectionReservedBytesAfter=0,
                      canonicalNormalizationBytesPerFullBase=width * height * 4,
                      minimumOriginalPlusBaseBytesWhileLoaded=width * height * 8)
    return result


def statistics(index=0):
    counters = memory(index)['counters']
    return {'sampleCount': 2, 'timerSampleCount': 1, 'sampledPeakBytes': counters.copy(),
            'sampledMinimumBytes': counters.copy(), 'lastBytes': counters.copy(), 'missingFieldCounts': {}}


def report(resources=False):
    identity = {'sourceCommit': '2' * 40, 'version': '0.17.0', 'buildVersion': '105',
                'bundlePath': '/test/PicShot.app', 'architecture': 'arm64', 'executableSHA256': '3' * 64, 'executableBytes': 1024}
    result = dict(identity, processIdentifier=1234, schemaVersion=2, status='passed', deadlineSeconds=300, elapsedSeconds=120,
                  resourcesRequested=resources, entryMemory=memory(), finalMemory=memory(20), resources=None,
                  functionalCases=[case(640, 360, 'small'), case(3840, 2160, '4k')],
                  flags={**dict.fromkeys(CHECK.FLAGS_TRUE, True), **dict.fromkeys(CHECK.FLAGS_FALSE, False)},
                  historyReopenEntryPoint='HistoryStore.editablePayload + ImageEditorController.restoreEditablePayload',
                  memoryScope='Synthetic schema fixture. No native execution. No stability claim.',
                  ownedTemporaryDirectoryRemoved=True, ownedOpenDescriptorsAfterCleanup=0)
    labels = ['entry', 'functional-small', 'functional-4k', 'final-cleanup']
    if resources:
        warmups = [case(3840, 2160, index=i, phase='warmup') for i in range(1, 3)]
        cycles = [case(3840, 2160, index=i, phase='measured') for i in range(1, 9)]
        baseline, after = memory(5), memory(15)
        endpoints = [c['afterMemory'] for c in cycles]
        result['resources'] = {'status': 'observed', 'warmupCycles': 2, 'measuredCycles': 8,
            'completedWarmupCycles': 2, 'completedMeasuredCycles': 8, 'sourceWidth': 3840, 'sourceHeight': 2160,
            'fixedInputRastersAtEndpoints': 0, 'originalAndBaseDistinct': True, 'fullBaseCostsIncluded': True,
            'realHistoryPNGMetadataRoundTripsPerCycle': True, 'nativeActionsInEveryCycle': True,
            'beforeWarmup': memory(3), 'afterWarmupBaseline': baseline, 'warmups': warmups, 'cycles': cycles,
            'afterMeasuredCycles': after, 'afterWarmupToMeasuredDeltaBytes': CHECK.delta(baseline, after),
            'lateMeasuredIncrements': [CHECK.delta(endpoints[i], endpoints[i + 1]) for i in range(4, 7)],
            'memoryStabilityAssessed': False, 'zeroLeakClaim': False, 'workload': 'Synthetic schema input'}
        labels += ['resource-before-input'] + [f'warmup-{i}' for i in range(1, 3)] + [f'measured-{i}' for i in range(1, 9)]
    phases = {label: statistics(index) for index, label in enumerate(labels)}
    total = statistics()
    total['sampleCount'] = 2 * len(labels); total['timerSampleCount'] = len(labels)
    total['sampledPeakBytes'] = memory(len(labels) - 1)['counters']; total['lastBytes'] = total['sampledPeakBytes'].copy()
    result['sampledMemory'] = {'scope': 'Synthetic aggregates', 'sampleIntervalSeconds': 0.05,
        'maximumPhaseAggregates': 128, 'continuousSampleArraysRetained': False, 'pairedTaskInfoCallsAreAtomic': False,
        'missingFieldsBecomeZero': False, 'total': total, 'phases': phases}
    return result, identity


class EditableReportTests(unittest.TestCase):
    def test_valid_functional_schema_is_not_native_attestation(self):
        value, identity = report()
        checked = CHECK.validate(value, identity, False)
        self.assertFalse(checked['nativeExecutionAttestedByChecker'])
        self.assertFalse(checked['visualFilesVerified'])
        self.assertFalse(checked['memoryStabilityAssessed'])
        with self.assertRaises(ValueError):
            CHECK.validate(value, identity, False, process_id=4321)

    def test_valid_positive_growth_is_preserved_without_stability_claim(self):
        value, identity = report(True)
        checked = CHECK.validate(value, identity, True)
        self.assertTrue(checked['resourceObservationsComplete'])
        self.assertGreater(value['resources']['afterWarmupToMeasuredDeltaBytes']['resident_size'], 0)
        self.assertFalse(checked['zeroLeakClaim'])

    def test_invalid_functional_mutations_rejected(self):
        mutations = [
            lambda r: r.update(schemaVersion=True), lambda r: r.update(executableSHA256='0' * 64),
            lambda r: r.update(architecture='x86_64'), lambda r: r.update(deadlineSeconds=600),
            lambda r: r.update(elapsedSeconds=float('nan')), lambda r: r.update(elapsedSeconds=301),
            lambda r: r['flags'].update(zeroLeakClaim=True), lambda r: r['flags'].update(generalPasteboardUsed=True),
            lambda r: r['functionalCases'].pop(), lambda r: r['functionalCases'][1].update(width=640),
            lambda r: r['functionalCases'][0].update(fullBasePixels=True),
            lambda r: r['functionalCases'][0].update(reopenedOutputPixelsSHA256='0' * 64),
            lambda r: r['functionalCases'][0].update(ordinaryExportPixelsSHA256='d' * 64),
            lambda r: r['functionalCases'][0].update(originalExportPixelsSHA256='c' * 64),
            lambda r: r['functionalCases'][0].update(appliedExpectedOutputPixelsSHA256='a' * 64),
            lambda r: r['functionalCases'][0].update(appliedPersistedOutputPixelsSHA256='a' * 64),
            lambda r: r['functionalCases'][0]['assertions'].update(uncropUndo=False),
            lambda r: r['functionalCases'][0]['ownershipAfterRelease']['base'].update(alive=1),
            lambda r: r['functionalCases'][0]['ownershipAfterRelease']['canonical'].update(peakKnownBytes=1),
            lambda r: r['functionalCases'][0].update(windowContentGraphsAfterRelease=1),
            lambda r: r.update(ownedTemporaryDirectoryRemoved=False), lambda r: r.update(ownedOpenDescriptorsAfterCleanup=1),
            lambda r: r['finalMemory']['counters'].update(phys_footprint=0),
            lambda r: r['entryMemory']['backingAccounting']['standard'].update(kernelReturn=1),
            lambda r: r['sampledMemory']['total'].update(timerSampleCount=0),
            lambda r: r['sampledMemory']['total']['sampledPeakBytes'].update(resident_size=1),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                value, identity = report(); mutate(value)
                with self.assertRaises((ValueError, TypeError, KeyError)):
                    CHECK.validate(value, identity, False)

    def test_incomplete_or_misleading_resource_mutations_rejected(self):
        mutations = [
            lambda r: r['resources']['cycles'].pop(),
            lambda r: r['resources'].update(completedMeasuredCycles=7),
            lambda r: r['resources']['cycles'][0].update(minimumOriginalPlusBaseBytesWhileLoaded=1024),
            lambda r: r['resources']['cycles'][0].update(projectionReservedBytesAfter=512),
            lambda r: r['resources']['cycles'][0].update(temporaryDirectoryRemoved=False),
            lambda r: r['resources']['cycles'][0].update(index=True),
            lambda r: r['resources']['cycles'][0]['afterMemory']['counters'].pop('purgeable_volatile_pmap'),
            lambda r: r['resources']['afterWarmupToMeasuredDeltaBytes'].update(resident_size=0),
            lambda r: r['resources']['lateMeasuredIncrements'][0].update(resident_size=0),
            lambda r: r['resources'].update(zeroLeakClaim=True),
            lambda r: r['sampledMemory']['phases'].pop('measured-8'),
            lambda r: r['sampledMemory']['phases']['measured-1']['missingFieldCounts'].update(compressed=1),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                value, identity = report(True); mutate(value)
                with self.assertRaises((ValueError, TypeError, KeyError)):
                    CHECK.validate(value, identity, True)

    def test_visual_metadata_scope_geometry_and_native_targets_rejected(self):
        mutations = [
            lambda r: r.update(schemaVersion=1),
            lambda r: r['functionalCases'][0]['visualEvidence'].pop(),
            lambda r: r['functionalCases'][0]['visualEvidence'][0].update(filename='../escape.png'),
            lambda r: r['functionalCases'][0]['visualEvidence'][0].update(pixelWidth=1281),
            lambda r: r['functionalCases'][0]['visualEvidence'][0]['controls'][0].update(nativeHitVerified=False),
            lambda r: r['functionalCases'][0]['visualEvidence'][0].update(imageNativeHitVerified=False),
            lambda r: r['functionalCases'][0]['visualEvidence'][1].update(windowFrame=[101, 200, 640, 360]),
            lambda r: r['functionalCases'][1].update(visualEvidence=copy.deepcopy(visuals()[0])),
            lambda r: r['resources']['cycles'][0].update(visualEvidence=copy.deepcopy(visuals()[0])),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                value, identity = report(True); mutate(value)
                with self.assertRaises((ValueError, TypeError, KeyError)):
                    CHECK.validate(value, identity, True)

    def test_visual_png_files_hashes_and_rgba_are_checked(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, data in visuals()[1].items():
                (root / name).write_bytes(data)
            value, identity = report()
            checked = CHECK.validate(value, identity, False, evidence_directory=root)
            self.assertTrue(checked['visualFilesVerified'])
            value['functionalCases'][0]['visualEvidence'][0]['rgbaSHA256'] = '0' * 64
            with self.assertRaises(ValueError):
                CHECK.validate(value, identity, False, evidence_directory=root)
            value, identity = report()
            entry = value['functionalCases'][0]['visualEvidence'][0]
            data = bytearray((root / entry['filename']).read_bytes()); data[-15] ^= 1
            (root / entry['filename']).write_bytes(data)
            entry['sha256'] = hashlib.sha256(data).hexdigest()
            with self.assertRaisesRegex(ValueError, 'CRC'):
                CHECK.validate(value, identity, False, evidence_directory=root)

    def test_linked_or_missing_visual_png_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, data in visuals()[1].items():
                (root / name).write_bytes(data)
            value, identity = report()
            name = value['functionalCases'][0]['visualEvidence'][0]['filename']
            (root / name).unlink()
            with self.assertRaises(FileNotFoundError):
                CHECK.validate(value, identity, False, evidence_directory=root)
            target = root / 'linked-target.png'; target.write_bytes(visuals()[1][name])
            (root / name).symlink_to(target)
            with self.assertRaises(ValueError):
                CHECK.validate(value, identity, False, evidence_directory=root)

    def test_duplicate_nonfinite_oversized_and_linked_reports_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'report.json'
            for text in ['{"a": 1, "a": 2}', '{"a":NaN}', '{"a":Infinity}', ' ' * (CHECK.MAX_BYTES + 1)]:
                path.write_text(text)
                with self.assertRaises(ValueError):
                    CHECK.read_report(path)
            path.write_text('{}')
            link = Path(directory) / 'link.json'; link.symlink_to(path)
            with self.assertRaises(ValueError):
                CHECK.read_report(link)

    def test_real_bundle_identity_reads_header_and_binds_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'PicShot.app'; executable = app / 'Contents/MacOS/PicShot'
            executable.parent.mkdir(parents=True)
            executable.write_bytes(bytes.fromhex('cffaedfe') + struct.pack('<I', 0x0100000c) + b'synthetic-not-native')
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'PicShotSourceCommit': '2' * 40,
                'CFBundleShortVersionString': '0.17.0', 'CFBundleVersion': '105'}))
            identity = CHECK.bundle_identity(app, '2' * 40)
            self.assertEqual(identity['architecture'], 'arm64')
            value, _ = report(); value.update(identity)
            CHECK.validate(value, identity, False)
            executable.write_bytes(b'not MachO')
            with self.assertRaises(ValueError):
                CHECK.bundle_identity(app, '2' * 40)


if __name__ == '__main__':
    unittest.main()
