"""Synthetic checker contracts only. No test is native execution evidence.

Small file fixtures exercise byte binding and adversarial mutations. In-memory
native-shaped reports exercise counts/metadata/memory; they never claim that a
Mac, installed application, CoreGraphics, ImageIO or kernel observation ran.
"""
import copy
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zlib

SCRIPT = Path(__file__).resolve().parents[1] / 'check-editable-components.py'
spec = importlib.util.spec_from_file_location('editable_components_checker', SCRIPT)
C = importlib.util.module_from_spec(spec)
spec.loader.exec_module(C)
PROFILE = 'a' * 64
INSTALLED = {'sourceCommit': 'b' * 40, 'executableSHA256': 'c' * 64,
             'executableBytes': 128, 'bundlePath': '/Applications/PicShot.app', 'architecture': 'arm64'}


def memory(t=100, offset=0):
    values = {name: (1000000 if name in ('resident_size', 'phys_footprint') else 100) + offset for name in C.MEMORY}
    values['ledger_purgeable_volatile'] = -50 + offset
    values['ledger_purgeable_volatile_compressed'] = -20 + offset
    raw = {}
    for label, flavor in [('standard', 'TASK_VM_INFO'), ('purgeable', 'TASK_VM_INFO_PURGEABLE')]:
        raw[label] = {'flavor': flavor, 'kernelReturn': 0, 'requestedNaturalCount': 100,
            'returnedNaturalCount': 100, 'observedAtUptimeSeconds': t, 'pageSizeBytes': 16384,
            'regionCount': 25, 'bytes': {}, 'ledgerBytes': {}}
    raw['standard']['bytes'] = {name: values[name] for name in ('resident_size', 'phys_footprint', 'compressed')}
    raw['standard']['bytes']['resident_size_peak'] = 2000000
    raw['standard']['ledgerBytes']['ledger_phys_footprint_peak'] = 2000000
    raw['purgeable']['bytes'] = {name: values[name] for name in C.MEMORY if name.startswith('purgeable_')}
    raw['purgeable']['ledgerBytes'] = {name: values[name] for name in C.MEMORY if name.startswith('ledger_')}
    return {'uptimeSeconds': t, 'counters': values, 'backingAccounting': raw}


def stats():
    values = memory()['counters']
    return {'sampleCount': 2, 'timerSampleCount': 1, 'sampledPeakBytes': dict(values),
            'sampledMinimumBytes': dict(values), 'lastBytes': dict(values), 'missingFieldCounts': {}}


def sampler(consumer=False):
    phases = ['entry', 'final-cleanup']
    if consumer:
        phases += [f'warmup-{i}' for i in range(1, 3)] + [f'measured-{i}' for i in range(1, 9)]
    total = stats()
    total['sampleCount'] *= len(phases); total['timerSampleCount'] *= len(phases)
    return {'scope': 'Synthetic sampler schema fixture only', 'sampleIntervalSeconds': .05,
        'maximumPhaseAggregates': 128, 'continuousSampleArraysRetained': False,
        'pairedTaskInfoCallsAreAtomic': False, 'missingFieldsBecomeZero': False,
        'total': total, 'phases': {name: stats() for name in phases}}


def canonical(role):
    w, h = C.DIMENSIONS[role]
    return {'width': w, 'height': h, 'bytesPerRow': w*4, 'bitsPerComponent': 8, 'bitsPerPixel': 32,
        'alphaInfo': 1, 'bitmapInfo': 16385, 'colorSpaceName': 'kCGColorSpaceSRGB', 'colorSpaceModel': 1,
        'colorSpaceICC_SHA256': PROFILE, 'channelOrder': 'RGBA', 'includesAllAlphaBytes': True}


def image_metadata(role, decoded=False):
    value = canonical(role)
    del value['channelOrder']; del value['includesAllAlphaBytes']
    value.update(renderingIntent=3 if decoded else 0, shouldInterpolate=True if decoded else role != 'current')
    if decoded:
        value.update(alphaInfo=3, bitmapInfo=3)
    return value


def assets():
    return {role: {'role': role, 'rawSHA256': C.EXPECTED_HASHES[role], 'canonical': canonical(role)} for role in C.ROLES}


def pixel(label, role, drawn=False, decoded=False):
    w, h = C.DIMENSIONS[role]
    value = {'label': label, 'sha256': C.EXPECTED_HASHES[role], 'comparedBytes': w*h*4,
        'exact': True, 'width': w, 'height': h, 'imageMetadata': image_metadata(role, decoded)}
    if drawn:
        value.update(beforeDrawMemory=memory(), afterDrawMemory=memory(), afterCompareMemory=memory(), elapsedSeconds=.1)
    return value


def certificate():
    return {'validations': [pixel(role, role, decoded=True) for role in C.ROLES] + [pixel('controller-replay', 'current')]}


def allocations(count):
    return {role: {'allocations': count, 'releaseCallbacks': count, 'deallocations': count,
        'activeBytes': 0, 'peakActiveBytes': C.DIMENSIONS[role][0] * C.DIMENSIONS[role][1] * 4 if count else 0,
        'callbackSizesMatch': True} for role in C.ROLES}


def ownership(editable=False):
    counts = {'original': 0, 'base': 0, 'current': 0, 'canonical': 0,
        'editor': 2 if editable else 0, 'canvas': 2 if editable else 0, 'content': 3 if editable else 0,
        'window': 3 if editable else 0, 'pin': 1 if editable else 0, 'store': 0}
    return {role: {'created': count, 'alive': 0, 'peakConcurrent': 1 if count else 0,
        'peakKnownBytes': 0}
        for role, count in counts.items()}


def cycle(mode='raw-draw', ordinal=1):
    editable = mode == 'editable-render-pin'
    decoded = mode == 'png-decode-draw'
    value = {'ordinal': ordinal, 'phase': 'warmup' if ordinal <= 2 else 'measured',
        'index': ordinal if ordinal <= 2 else ordinal-2, 'beforeMemory': memory(),
        'afterReleaseMemory': memory(), 'afterWorkMemory': memory(), 'elapsedSeconds': 1,
        'ownershipAfterRelease': ownership(editable), 'windowContentGraphsAfterRelease': 0,
        'providerLifetime': allocations(0 if decoded else ordinal), 'ownedOpenDescriptorsAfter': 0,
        'ownedInputOpenDescriptorsAfter': 0, 'temporaryDirectoryRemoved': True, 'activeExportControllersAfter': 0,
        'projectionReservedBytesAfter': 0, 'exportQueueOperationsAfter': 0, 'measuredDiskReads': 0,
        'validations': [pixel(role, role, drawn=True, decoded=decoded) for role in C.ROLES],
        'writtenOutputs': [], 'imageCreationCount': 3, 'pngDecodeCount': 3 if decoded else 0,
        'pngWriteCount': 3 if mode == 'png-write' else 0, 'editableRestoreCount': 2 if editable else 0,
        'pinApplyCount': 1 if editable else 0, 'freshRenderCount': 1 if editable else 0,
        'afterCreationMemory': memory(), 'afterValidationMemory': memory()}
    if editable:
        value['validations'] += [pixel(label, 'current', drawn=True) for label in ('restored-render', 'pin-applied-current', 'fresh-render')]
        value.update(documentChanged=False, persistenceCommitCount=0, afterRestoreMemory=memory(),
            afterPinOpenMemory=memory(), afterApplyMemory=memory(), afterFreshRenderMemory=memory())
    else:
        value.update(creationStartUptime=100, afterWritesMemory=memory(), writeSeconds=.2)
    if mode == 'png-write':
        value['writtenOutputs'] = [{'file': f'cycle-{ordinal}-{role}.png', 'role': role, 'byteCount': 10,
            'sourceRawSHA256': C.EXPECTED_HASHES[role], 'width': C.DIMENSIONS[role][0],
            'height': C.DIMENSIONS[role][1], 'outputPixelVerificationPending': True} for role in C.ROLES]
    return value


def consumer(mode='raw-draw'):
    return {'mode': mode, 'nativeImageIOProviderCallbacksObserved': False, 'cycles': [cycle(mode, i) for i in range(1, 11)],
        'retainedOutputBytes': 300 if mode == 'png-write' else 0, 'retainedOutputFileCount': 30 if mode == 'png-write' else 0,
        'outputPixelsValidatedInThisProcess': mode != 'png-write', 'inputScope': 'Synthetic fixture',
        'diskReadScope': 'Synthetic fixture', 'outputVerificationScope': 'Synthetic fixture',
        'measuredDiskReads': 0, 'retainedValidationDestinationBytesAfterCleanup': 0,
        'ownedOpenDescriptorsAfterCleanup': 0, 'retainedValidationDestinationBytes': sum(w*h*4 for w,h in C.DIMENSIONS.values()),
        'destinationLifetime': allocations(1), 'providerLifetime': allocations(0 if mode == 'png-decode-draw' else 10),
        'entryMemory': memory(), 'afterInputLoadMemory': memory(), 'afterPreparationMemory': memory(),
        'afterWarmupMemory': memory(), 'afterMeasuredMemory': memory(), 'afterDestinationCleanupMemory': memory(),
        'finalMemory': memory(), 'sampledMemory': sampler(True), 'elapsedSeconds': 20, 'retainedInputBytes': 123}


def common(mode='certify'):
    value = {**INSTALLED, 'operatingSystem': 'Synthetic schema fixture OS', 'processIdentifier': 102,
        'protocol': C.PROTOCOL, 'mode': mode, 'status': 'certified', 'entryMemory': memory(), 'diagnosticOnly': True,
        'fullWorkEquivalent': False, 'memoryStabilityAssessed': False, 'productMemoryRemedyClaim': False,
        'memoryPressureOrPurgeRequested': False, 'coreFoundationWeakProbesUsed': False, 'nativeImageLifetimeScope': 'Synthetic AppKit-only observer fixture', 'deadlineSeconds': 300, 'fixtureSourceCommit': C.FIXTURE_SOURCE,
        'warmupCycles': 2, 'measuredCycles': 8, 'scope': 'Synthetic schema fixture only', 'finalMemory': memory(),
        'sampledMemory': sampler(), 'elapsedSeconds': 20, 'inputManifestSHA256': 'd'*64,
        'inputPreparationProcessIdentifier': 101, 'certificateSHA256': None, 'retainedInputBytes': 123,
        'afterInputLoadMemory': memory(), 'retainedInputBytesAfterCleanup': 0,
        'inputOpenDescriptorsAfterPreparation': 0, **certificate()}
    return value


def manifest_summary():
    return {'operatingSystem': 'Synthetic schema fixture OS', 'processIdentifier': 101, 'totalBytes': 123}


def launcher():
    return {'schemaVersion': 1, 'status': 'exited', 'launcherExitCode': 0,
        'selectedAppPath': INSTALLED['bundlePath'], 'createsNewApplicationInstance': True,
        'timeoutSeconds': 600, 'elapsedSeconds': 21, 'callbackReceived': True, 'ownedExitConfirmed': True,
        'processStartMemoryCaptured': False, 'scope': 'Synthetic launcher contract', 'processIdentifier': 102,
        'launchedAppPath': INSTALLED['bundlePath'], 'launchBeganUptimeSeconds': 99, 'finishUptimeSeconds': 120}


def command(directory):
    return {'schema_version': 1, 'status': 'exited', 'command': ['swift', 'scripts/launch-editable-component.swift',
        INSTALLED['bundlePath'], str(directory / 'launch.json')], 'started_at': '2026-10-08T10:00:00+00:00',
        'timeout_seconds': 620, 'grace_seconds': 5, 'max_log_bytes': C.MAX_REPORT, 'pid': 103,
        'child_returncode': 0, 'exit_code': 0, 'cancel_signal': None, 'sigterm_sent': False, 'sigkill_sent': False,
        'descendant_cleanup': False, 'output_bytes': 0, 'log_bytes': 0, 'log_truncated': False,
        'termination_reason': 'exited', 'duration_seconds': 22}


def png(w=1, h=1, rgba=b'\x01\x02\x03\xff', *, depth=8, color=6, extra=b''):
    def chunk(kind, payload):
        return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload)&0xffffffff)
    header = struct.pack('>IIBBBBB', w, h, depth, color, 0, 0, 0)
    row = rgba[:4 if color == 6 else 3]*w
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) + extra + chunk(b'IDAT', zlib.compress((b'\0'+row)*h)) + chunk(b'IEND', b'')


class ComponentContracts(unittest.TestCase):
    def test_known_hashes_and_extents_are_fixed(self):
        self.assertEqual(C.FIXTURE_SOURCE, 'c80e94de9cf712e118009700feacbd707356e0a3')
        self.assertEqual(C.DIMENSIONS['current'], (2414, 1574))
        self.assertEqual(C.EXPECTED_HASHES['original'], 'c7819513b71c4ad1675665feece59747ff9a518db5766c5a8de973f65fdf19c6')
        self.assertEqual(len(set(C.EXPECTED_HASHES.values())), 3)

    def test_valid_synthetic_helper_contracts(self):
        C.validate_certificate(certificate(), assets())
        C.validate_common(common(), 'certify', INSTALLED, 'd'*64, manifest_summary())
        C.validate_launch(launcher(), common(), INSTALLED)
        for mode in C.CONSUMERS:
            C.validate_consumer(consumer(mode), assets(), certificate())

    def test_mode_schemas_do_not_mutate_between_validation_calls(self):
        original = set(C.LOADED_FIELDS)
        for mode in ('certify', *C.CONSUMERS, 'verify-writes', 'certify', *reversed(C.CONSUMERS)):
            report = common()
            certificate_hash = None if mode == 'certify' else 'e'*64
            report['certificateSHA256'] = certificate_hash
            if mode in C.CONSUMERS:
                del report['validations']; report.update(consumer(mode))
                report['status'] = 'observed-pending-output-validation' if mode == 'png-write' else 'observed'
            elif mode == 'verify-writes':
                report.update(mode=mode, status='verified', writerReportSHA256='f'*64,
                    writerProcessIdentifier=150, validations=[], verifiedOutputFiles=30,
                    verifiedOutputBytes=100, memoryComparisonExcluded=True)
            C.validate_common(report, mode, INSTALLED, 'd'*64, manifest_summary(), certificate_hash)
            self.assertEqual(C.LOADED_FIELDS, original)

    def test_identity_mutations_fail(self):
        for field, value in [('sourceCommit', 'e'*40), ('architecture', 'x86_64'), ('executableSHA256', 'e'*64),
            ('executableBytes', True), ('bundlePath', '/tmp/Else.app'), ('operatingSystem', 'different'), ('processIdentifier', True)]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                report = common(); report[field] = value
                C.validate_common(report, 'certify', INSTALLED, 'd'*64, manifest_summary())

    def test_missing_and_added_common_fields_fail(self):
        for field in list(common()):
            with self.subTest(field=field), self.assertRaises(ValueError):
                report = common(); del report[field]
                C.validate_common(report, 'certify', INSTALLED, 'd'*64, manifest_summary())
        report = common(); report['unboundedExtras'] = []
        with self.assertRaises(ValueError):
            C.validate_common(report, 'certify', INSTALLED, 'd'*64, manifest_summary())

    def test_bad_binding_and_claims_fail(self):
        for field, value in [('inputManifestSHA256', 'f'*64), ('certificateSHA256', 'f'*64),
            ('fixtureSourceCommit', 'b'*40), ('status', 'observed'), ('warmupCycles', 1), ('measuredCycles', 9),
            ('inputPreparationProcessIdentifier', 102), ('retainedInputBytes', 124), ('inputOpenDescriptorsAfterPreparation', 1),
            ('fullWorkEquivalent', True), ('coreFoundationWeakProbesUsed', True), ('productMemoryRemedyClaim', True), ('memoryPressureOrPurgeRequested', True),
            ('deadlineSeconds', 600), ('elapsedSeconds', 300)]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                report = common(); report[field] = value
                C.validate_common(report, 'certify', INSTALLED, 'd'*64, manifest_summary())

    def test_certificate_exact_four_full_rgba_validations(self):
        for mutate in [lambda r:r['validations'].pop(), lambda r:r['validations'].append(r['validations'][0]),
            lambda r:r['validations'].reverse(), lambda r:r['validations'][0].update(exact=False),
            lambda r:r['validations'][0].update(sha256='a'*64), lambda r:r['validations'][2].update(comparedBytes=2414*1574*3),
            lambda r:r['validations'][0].update(width=1920), lambda r:r['validations'][0]['imageMetadata'].update(alphaInfo=5, bitmapInfo=5)]:
            with self.subTest(mutation=mutate), self.assertRaises(ValueError):
                value = certificate(); mutate(value); C.validate_certificate(value, assets())

    def test_canonical_alpha_profile_stride_and_type(self):
        for field, value in [('includesAllAlphaBytes', False), ('bitsPerComponent', 16), ('channelOrder', 'BGRA'),
            ('bytesPerRow', 15364), ('alphaInfo', 3), ('bitmapInfo', 3), ('colorSpaceName', 'DisplayP3'),
            ('colorSpaceICC_SHA256', 'missing'), ('width', True)]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                item = canonical('original'); item[field] = value; C.canonical(item, 'original')

    def test_decoded_metadata_bound_to_certificate(self):
        report = consumer('png-decode-draw')
        report['cycles'][0]['validations'][0]['imageMetadata']['renderingIntent'] = 0
        with self.assertRaisesRegex(ValueError, 'certificate'):
            C.validate_consumer(report, assets(), certificate())

    def test_every_cycle_operation_count_is_required(self):
        fields = ('imageCreationCount', 'pngDecodeCount', 'pngWriteCount', 'editableRestoreCount', 'pinApplyCount', 'freshRenderCount')
        for mode in C.CONSUMERS:
            for field in fields:
                with self.subTest(mode=mode, field=field), self.assertRaises(ValueError):
                    report = consumer(mode); report['cycles'][7][field] += 1
                    C.validate_consumer(report, assets(), certificate())

    def test_warmup_measured_order_and_count(self):
        for mutate in [lambda r:r['cycles'].pop(), lambda r:r['cycles'].reverse(),
            lambda r:r['cycles'][2].update(phase='warmup'), lambda r:r['cycles'][2].update(index=2),
            lambda r:r['cycles'][9].update(ordinal=True)]:
            with self.subTest(mutation=mutate), self.assertRaises(ValueError):
                report = consumer(); mutate(report); C.validate_consumer(report, assets(), certificate())

    def test_all_cycle_fields_required(self):
        for field in cycle():
            with self.subTest(field=field), self.assertRaises(ValueError):
                value = cycle(); del value[field]
                C.validate_cycle(value, 'raw-draw', 1, assets(), certificate())

    def test_lifetimes_and_descriptors_must_reach_zero(self):
        fields = ('windowContentGraphsAfterRelease', 'ownedOpenDescriptorsAfter', 'ownedInputOpenDescriptorsAfter',
                  'activeExportControllersAfter', 'projectionReservedBytesAfter', 'exportQueueOperationsAfter', 'measuredDiskReads')
        for field in fields:
            with self.subTest(field=field), self.assertRaises(ValueError):
                value = cycle(); value[field] = 1
                C.validate_cycle(value, 'raw-draw', 1, assets(), certificate())
        for mutate in [lambda c:c.update(temporaryDirectoryRemoved=False),
            lambda c:c['ownershipAfterRelease']['original'].update(alive=1),
            lambda c:c['providerLifetime']['base'].update(releaseCallbacks=0),
            lambda c:c['providerLifetime']['base'].update(activeBytes=4),
            lambda c:c['providerLifetime']['base'].update(callbackSizesMatch=False),
            lambda c:c['ownershipAfterRelease']['original'].update(peakKnownBytes=4)]:
            with self.subTest(mutation=mutate), self.assertRaises(ValueError):
                value = cycle(); mutate(value); C.validate_cycle(value, 'raw-draw', 1, assets(), certificate())

    def test_detached_window_shell_is_not_counted_as_live_graph(self):
        value = cycle('editable-render-pin'); value['ownershipAfterRelease']['window']['alive'] = 1
        C.validate_cycle(value, 'editable-render-pin', 1, assets(), certificate())

    def test_writer_cannot_claim_output_validation(self):
        report = consumer('png-write'); report['outputPixelsValidatedInThisProcess'] = True
        with self.assertRaises(ValueError): C.validate_consumer(report, assets(), certificate())
        report = consumer('png-write'); report['cycles'][0]['writtenOutputs'][0]['outputPixelVerificationPending'] = False
        with self.assertRaises(ValueError): C.validate_consumer(report, assets(), certificate())

    def test_writer_output_counts_names_and_bounds(self):
        for mutate in [lambda r:r.update(retainedOutputFileCount=29), lambda r:r.update(retainedOutputBytes=301),
            lambda r:r['cycles'][0]['writtenOutputs'].pop(),
            lambda r:r['cycles'][0]['writtenOutputs'][0].update(file='../outside.png'),
            lambda r:r['cycles'][0]['writtenOutputs'][0].update(byteCount=C.MAX_PNG+1)]:
            with self.subTest(mutation=mutate), self.assertRaises(ValueError):
                report = consumer('png-write'); mutate(report); C.validate_consumer(report, assets(), certificate())

    def test_all_eight_memory_counters_required(self):
        for name in C.MEMORY:
            with self.subTest(counter=name), self.assertRaises(ValueError):
                value = memory(); del value['counters'][name]; C.observation(value)

    def test_missing_kernel_and_bad_flattening_fail(self):
        for mutate in [lambda v:v['backingAccounting']['standard']['bytes'].pop('resident_size_peak'),
            lambda v:v['backingAccounting']['standard']['ledgerBytes'].pop('ledger_phys_footprint_peak'),
            lambda v:v['backingAccounting']['purgeable'].update(kernelReturn=5),
            lambda v:v['backingAccounting']['purgeable'].update(returnedNaturalCount=0),
            lambda v:v['backingAccounting']['purgeable']['ledgerBytes'].update(ledger_purgeable_volatile=0),
            lambda v:v['counters'].update(phys_footprint=True), lambda v:v.update(uptimeSeconds=float('nan'))]:
            with self.subTest(mutation=mutate), self.assertRaises(ValueError):
                value = memory(); mutate(value); C.observation(value)

    def test_signed_counters_and_independent_deltas(self):
        C.observation(memory())
        report = consumer()
        report['entryMemory'] = memory(offset=40)
        report['afterPreparationMemory'] = memory(offset=30)
        report['afterWarmupMemory'] = memory(offset=20)
        report['afterMeasuredMemory'] = memory(offset=10)
        report['finalMemory'] = memory(offset=-10)
        report['cycles'][2]['afterReleaseMemory'] = memory(offset=8)
        report['cycles'][3]['afterReleaseMemory'] = memory(offset=3)
        result = C.metrics(report)
        for name in C.MEMORY:
            self.assertEqual(result['entryToFinalDeltaBytes'][name], -50)
            self.assertEqual(result['entryToPreparationDeltaBytes'][name], -10)
            self.assertEqual(result['preparationToWarmupDeltaBytes'][name], -10)
            self.assertEqual(result['warmupToMeasuredDeltaBytes'][name], -10)
            self.assertEqual(result['lateMeasuredIncrements'][0]['deltaBytes'][name], -5)
        self.assertLess(result['finalBytes']['ledger_purgeable_volatile'], 0)
        self.assertNotIn('totalCausalAllocationBytes', result)

    def test_sampler_reconciliation_and_missing_fields(self):
        C.samples(sampler(True), True)
        for mutate in [lambda v:v['total'].update(sampleCount=1),
            lambda v:v['phases'].pop('measured-8'), lambda v:v['total'].update(missingFieldCounts={'compressed':1}),
            lambda v:v.update(missingFieldsBecomeZero=True), lambda v:v['total']['sampledPeakBytes'].update(compressed=1000),
            lambda v:v['phases']['warmup-1']['lastBytes'].pop('compressed')]:
            with self.subTest(mutation=mutate), self.assertRaises(ValueError):
                value = sampler(True); mutate(value); C.samples(value, True)

    def test_owned_launch_identity_exit_and_deadlines(self):
        for field, bad in [('ownedExitConfirmed', False), ('createsNewApplicationInstance', False),
            ('callbackReceived', False), ('launcherExitCode', True), ('processIdentifier', 999),
            ('selectedAppPath', '/tmp/Other.app'), ('timeoutSeconds', 900), ('elapsedSeconds', 600),
            ('processStartMemoryCaptured', True), ('status', 'timed-out'), ('launchBeganUptimeSeconds', 101), ('finishUptimeSeconds', 99)]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                value = launcher(); value[field] = bad; C.validate_launch(value, common(), INSTALLED)

    def test_bounded_command_success_required(self):
        directory = Path('/synthetic/certify')
        C.validate_command(command(directory), directory, INSTALLED)
        for field, bad in [('status', 'timeout'), ('child_returncode', 1), ('exit_code', 124), ('cancel_signal', 15),
            ('sigkill_sent', True), ('descendant_cleanup', True), ('timeout_seconds', 900),
            ('max_log_bytes', 999), ('duration_seconds', 621), ('started_at', '2026-10-08T10:00:00')]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                value = command(directory); value[field] = bad; C.validate_command(value, directory, INSTALLED)

    def test_png_metadata_and_truncation_crc_depth_dimensions(self):
        C.png_metadata(png(), 1, 1)
        C.png_metadata(png(color=2), 1, 1)
        bad_crc = bytearray(png()); bad_crc[-1] ^= 1
        for data, w, h in [(png()[:-1],1,1),(bytes(bad_crc),1,1),(png(depth=16),1,1),
                           (png(),2,1),(png()+b'junk',1,1), (b'not a png',1,1)]:
            with self.subTest(data=data[:16]), self.assertRaises(ValueError): C.png_metadata(data,w,h)

    def test_png_decompression_bomb_and_animated_metadata(self):
        def chunk(kind, payload):
            return struct.pack('>I',len(payload))+kind+payload+struct.pack('>I',zlib.crc32(kind+payload)&0xffffffff)
        animated = png(extra=chunk(b'acTL', struct.pack('>II',2,0)))
        with self.assertRaises(ValueError): C.png_metadata(animated,1,1)
        bomb = png().split(b'IDAT')[0][:-4] + chunk(b'IDAT',zlib.compress(b'\0'*1000000)) + chunk(b'IEND',b'')
        with self.assertRaises(ValueError): C.png_metadata(bomb,1,1)

    def test_strict_json_rejects_duplicates_nonfinite_and_array(self):
        for data in [b'{"x":1,"x":2}', b'{"x":NaN}', b'{"x":Infinity}', b'[]']:
            with self.subTest(data=data), self.assertRaises(ValueError): C.json_object(data)

    def test_bounded_file_type_links_size_and_changed_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve(); path = root/'file'; path.write_bytes(b'abcd')
            self.assertEqual(C.read_bytes(path,4), b'abcd')
            with self.assertRaises(ValueError): C.read_bytes(path,3)
            link = root/'link'; link.symlink_to(path)
            with self.assertRaises(ValueError): C.read_bytes(link,4)
            with self.assertRaises(ValueError): C.read_bytes(root,4)
            path.write_bytes(b'efgh')
            self.assertNotEqual(C.digest(C.read_bytes(path,4)), C.digest(b'abcd'))

    def test_launch_envelope_mutation_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            for name, value in [('component.json',common()),('launch.json',common()),
                                 ('launch.json.launcher.json',launcher()),('command.json',command(root))]:
                (root/name).write_text(json.dumps(value))
            C.load_process(root, INSTALLED)
            changed = common(); changed['status'] = 'failed'
            (root/'launch.json').write_text(json.dumps(changed))
            with self.assertRaisesRegex(ValueError, 'launch report differs'): C.load_process(root, INSTALLED)

    def test_installed_binary_bytes_and_architecture_are_read(self):
        with tempfile.TemporaryDirectory() as tmp:
            app=Path(tmp).resolve()/'PicShot.app'; (app/'Contents/MacOS').mkdir(parents=True)
            (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'PicShot','PicShotSourceCommit':'b'*40}))
            binary = bytes.fromhex('cffaedfe')+struct.pack('<I',0x0100000c)+b'\0'*24
            (app/'Contents/MacOS/PicShot').write_bytes(binary)
            result=C.bundle_identity(app,'b'*40)
            self.assertEqual(result['executableSHA256'], C.digest(binary)); self.assertEqual(result['architecture'],'arm64')
            with self.assertRaises(ValueError): C.bundle_identity(app,'a'*40)
            (app/'Contents/MacOS/PicShot').write_bytes(b'wrong executable')
            with self.assertRaises(ValueError): C.bundle_identity(app,'b'*40)

    def test_optimized_python_preserves_rejections(self):
        code = "import importlib.util; s=importlib.util.spec_from_file_location('c', %r); c=importlib.util.module_from_spec(s); s.loader.exec_module(c); c.integer(True)" % str(SCRIPT)
        result=subprocess.run([sys.executable,'-O','-c',code],capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('ValueError: invalid bounded integer',result.stderr)

    def test_cli_failure_writes_failure_not_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            output=Path(tmp)/'failed.json'
            result=subprocess.run([sys.executable,'-O',str(SCRIPT),'--app',tmp,'--expected-source','b'*40,
                '--root',tmp,'--output',str(output)],capture_output=True,text=True)
            self.assertEqual(result.returncode,1)
            value=json.loads(output.read_text())
            self.assertEqual(value['status'],'failed'); self.assertFalse(value['nativeExecutionAttestedByChecker'])
            self.assertFalse(value['memoryStabilityAssessed'])


class WrittenOutputContracts(unittest.TestCase):
    """1x1 helper fixtures, deliberately distinct from pinned native references."""
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.root=Path(self.temp.name).resolve()
        self.addCleanup(self.temp.cleanup)
        (self.root/'outputs').mkdir()
        self.dim_patch=mock.patch.dict(C.DIMENSIONS,{role:(1,1) for role in C.ROLES}); self.dim_patch.start(); self.addCleanup(self.dim_patch.stop)
        self.hash_patch=mock.patch.dict(C.EXPECTED_HASHES,{role:C.digest(bytes([i,2,3,255])) for i,role in enumerate(C.ROLES,1)})
        self.hash_patch.start(); self.addCleanup(self.hash_patch.stop)
        self.writer=consumer('png-write'); self.writer['processIdentifier']=200
        self.verifier={'memoryComparisonExcluded':True,'writerReportSHA256':'f'*64,'writerProcessIdentifier':200,
            'processIdentifier':201,'verifiedOutputFiles':30,'verifiedOutputBytes':0,'validations':[]}
        total=0
        for ordinal in range(1,11):
            for index,role in enumerate(C.ROLES):
                filename=f'cycle-{ordinal}-{role}.png'; data=png(rgba=bytes([index+1,2,3,255]))
                (self.root/'outputs'/filename).write_bytes(data)
                self.writer['cycles'][ordinal-1]['writtenOutputs'][index]['byteCount']=len(data)
                record=pixel(filename,role,decoded=True)
                record.update(fileSHA256=C.digest(data),byteCount=len(data),sourceRawSHA256=C.EXPECTED_HASHES[role],ordinal=ordinal,role=role)
                self.verifier['validations'].append(record); total+=len(data)
        self.writer['retainedOutputBytes']=total; self.verifier['verifiedOutputBytes']=total

    def validate(self):
        C.validate_written_outputs(self.root,self.writer,'f'*64,self.verifier,assets(),certificate())

    def preparation_fixture(self):
        directory=self.root/'prepare'; directory.mkdir(exist_ok=True)
        entries=[]; total=0
        for index,role in enumerate(C.ROLES):
            raw=bytes([index+1,2,3,255]); encoded=png(rgba=raw)
            (directory/(role+'.rgba')).write_bytes(raw); (directory/(role+'.png')).write_bytes(encoded)
            entries.append({'role':role,'width':1,'height':1,'pngFile':role+'.png','pngBytes':len(encoded),
                'pngSHA256':C.digest(encoded),'rawFile':role+'.rgba','rawBytes':len(raw),
                'rawSHA256':C.digest(raw),'sourceMetadata':image_metadata(role),'canonical':canonical(role)})
            total+=len(raw)+len(encoded)
        document={'format':'picshot.editable-annotations','coordinates':'image-pixels-bottom-left','version':1,
            'originalPixelWidth':3840,'originalPixelHeight':2160,'basePixelWidth':3840,'basePixelHeight':2160,
            'originalAssetID':'00000000-0000-0000-0000-000000000001','baseAssetID':'00000000-0000-0000-0000-000000000002',
            'baseProvenance':'derivedRaster','cropViewportInBase':[[480,240],[2400,1560]],'annotations':[{}]*7,
            'outputDecoration':{'enabled':True,'cornerRadius':8,'borderEnabled':True,'borderWidth':2,
                'shadowEnabled':True,'shadowBlur':2,'shadowOffsetX':3,'shadowOffsetY':4}}
        doc_bytes=json.dumps(document).encode(); (directory/'document.annotations').write_bytes(doc_bytes)
        manifest={**INSTALLED,'processIdentifier':101,'operatingSystem':'Synthetic schema fixture OS',
            'protocol':C.PROTOCOL,'status':'prepared','fixtureSourceCommit':C.FIXTURE_SOURCE,
            'referenceEvidence':'Synthetic helper fixture; never native evidence','assets':entries,
            'documentFile':'document.annotations','documentBytes':len(doc_bytes),'documentSHA256':C.digest(doc_bytes),
            'totalBytes':total+len(doc_bytes),'originalAndBaseDistinct':True,'sourceWidth':3840,'sourceHeight':2160,
            'crop':[480,240,2400,1560],'outputWidth':2414,'outputHeight':1574,'layerCount':7}
        report={'assets':copy.deepcopy(entries),'processIdentifier':101,'operatingSystem':manifest['operatingSystem']}
        return directory,manifest,report

    def test_preparation_reads_and_hashes_all_local_bytes(self):
        directory,manifest,report=self.preparation_fixture()
        result=C.validate_preparation(directory,manifest,report,INSTALLED)
        self.assertEqual(set(result),set(C.ROLES))

    def test_preparation_mutated_raw_png_and_document_fail(self):
        for filename in ('original.rgba','base.rgba','current.rgba','original.png','document.annotations'):
            with self.subTest(file=filename):
                directory,manifest,report=self.preparation_fixture()
                path=directory/filename; data=bytearray(path.read_bytes()); data[-1]^=1; path.write_bytes(data)
                with self.assertRaises(ValueError): C.validate_preparation(directory,manifest,report,INSTALLED)

    def test_preparation_unsafe_role_and_missing_alpha_fail(self):
        for mutate in [lambda m:m['assets'].reverse(),lambda m:m['assets'][0].update(rawFile='../original.rgba'),
            lambda m:m['assets'][0]['canonical'].update(includesAllAlphaBytes=False),
            lambda m:m['assets'][1].update(rawSHA256=C.EXPECTED_HASHES['original']),lambda m:m.update(totalBytes=1)]:
            with self.subTest(mutation=mutate):
                directory,manifest,report=self.preparation_fixture(); mutate(manifest)
                report['assets']=copy.deepcopy(manifest['assets'])
                with self.assertRaises(ValueError): C.validate_preparation(directory,manifest,report,INSTALLED)

    def pipeline_fixture(self):
        directory,manifest,_=self.preparation_fixture()
        manifest_bytes=json.dumps(manifest).encode(); (directory/'inputs.json').write_bytes(manifest_bytes)
        manifest_hash=C.digest(manifest_bytes); cert_hash=None; writer_hash=None
        for index,mode in enumerate(('prepare','certify',*C.CONSUMERS,'verify-writes')):
            target=self.root/mode; target.mkdir(exist_ok=True)
            report=common(); report['mode']=mode; report['processIdentifier']=101+index
            if mode=='prepare':
                for name in C.LOADED_FIELDS: report.pop(name)
                report.pop('validations'); report.update(status='prepared',assets=manifest['assets'])
            elif mode in C.CONSUMERS:
                report.pop('validations')
                report.update(copy.deepcopy(self.writer) if mode=='png-write' else consumer(mode))
                report['processIdentifier']=101+index
                report['status']='observed-pending-output-validation' if mode=='png-write' else 'observed'
            elif mode=='verify-writes':
                report.update(copy.deepcopy(self.verifier)); report['processIdentifier']=101+index
                report.update(status='verified',writerReportSHA256=writer_hash,writerProcessIdentifier=104)
            report['inputManifestSHA256']=manifest_hash
            if mode!='prepare':
                report['retainedInputBytes']=manifest['totalBytes']
                report['certificateSHA256']=None if mode=='certify' else cert_hash
            # Shift synthetic uptime only, preserving ordering within each process.
            def shift(value):
                if type(value) is dict:
                    for name,item in value.items():
                        if name in ('uptimeSeconds','observedAtUptimeSeconds','creationStartUptime'):
                            value[name]+=index*100
                        else: shift(item)
                elif type(value) is list:
                    for item in value: shift(item)
            shift(report)
            report_bytes=json.dumps(report).encode()
            for name in ('component.json','launch.json'): (target/name).write_bytes(report_bytes)
            owned=launcher(); owned.update(processIdentifier=101+index,launchBeganUptimeSeconds=99+index*100,
                                           finishUptimeSeconds=120+index*100)
            (target/'launch.json.launcher.json').write_text(json.dumps(owned))
            wrapper=command(target); wrapper['started_at']=f'2026-10-08T10:{index:02d}:00+00:00'
            (target/'command.json').write_text(json.dumps(wrapper))
            if mode=='certify': cert_hash=C.digest(report_bytes)
            if mode=='png-write': writer_hash=C.digest(report_bytes)
        (self.root/'outputs').rename(self.root/'png-write/outputs')
        return manifest_hash

    def check_pipeline(self,stage='complete'):
        # Explicitly stub only installed binary discovery; all synthetic report,
        # raw/PNG/document, launcher, and output bytes use the real checker paths.
        with mock.patch.object(C,'bundle_identity',return_value=INSTALLED):
            return C.check('/unused/synthetic/app','b'*40,self.root,stage)

    def test_synthetic_pipeline_is_not_native_evidence(self):
        self.pipeline_fixture(); result=self.check_pipeline()
        self.assertEqual(result['status'],'complete')
        self.assertFalse(result['nativeExecutionAttestedByChecker'])
        self.assertTrue(result['allThirtyWrittenOutputsPostExitVerified'])
        self.assertEqual(len(result['observations']),4)
        self.assertFalse(result['memoryStabilityAssessed'])

    def test_certify_stage_does_not_claim_output_completion(self):
        self.pipeline_fixture(); result=self.check_pipeline('certify')
        self.assertEqual(result['status'],'certified')
        self.assertFalse(result['allThirtyWrittenOutputsPostExitVerified'])
        self.assertEqual(result['observations'],{})

    def test_complete_cannot_omit_post_exit_verifier(self):
        self.pipeline_fixture(); (self.root/'verify-writes/component.json').unlink()
        with self.assertRaises(FileNotFoundError): self.check_pipeline()

    def test_cross_process_reused_pid_is_rejected(self):
        self.pipeline_fixture()
        for name in ('component.json','launch.json','launch.json.launcher.json'):
            path=self.root/'raw-draw'/name; value=json.loads(path.read_text()); value['processIdentifier']=102
            path.write_text(json.dumps(value))
        with self.assertRaisesRegex(ValueError,'distinct fresh process'): self.check_pipeline()

    def test_dangling_temporary_directory_link_is_not_cleanup(self):
        self.pipeline_fixture()
        (self.root/'raw-draw/cycle-temp-1').symlink_to(self.root/'missing-directory')
        with self.assertRaisesRegex(ValueError,'cycle temporary directory still exists'): self.check_pipeline()

    def test_verifier_must_start_after_owned_writer_exit(self):
        self.pipeline_fixture(); path=self.root/'verify-writes/launch.json.launcher.json'
        value=json.loads(path.read_text()); value['launchBeganUptimeSeconds']=419
        path.write_text(json.dumps(value))
        with self.assertRaisesRegex(ValueError,'previous owned process exit'): self.check_pipeline()

    def test_all_thirty_actual_file_bindings(self):
        self.validate()

    def test_missing_last_post_exit_pixel_record(self):
        self.verifier['validations'].pop()
        with self.assertRaises(ValueError): self.validate()

    def test_same_length_actual_png_mutation_rejected(self):
        path=self.root/'outputs/cycle-10-current.png'; original=path.read_bytes()
        changed=png(rgba=b'\x03\x03\x03\xff')
        self.assertEqual(len(changed),len(original)); path.write_bytes(changed)
        with self.assertRaisesRegex(ValueError,'actual PNG bytes differ'): self.validate()

    def test_mutated_output_alpha_rejected_by_certificate_binding(self):
        self.verifier['validations'][29]['sha256']=C.digest(b'\x03\x02\x03\x80')
        with self.assertRaisesRegex(ValueError,'full RGBA pixel hash differs'): self.validate()

    def test_verifier_wrong_writer_or_pid(self):
        for field,bad in [('writerReportSHA256','a'*64),('writerProcessIdentifier',999),('processIdentifier',200),
                          ('verifiedOutputFiles',29),('verifiedOutputBytes',1),('memoryComparisonExcluded',False)]:
            with self.subTest(field=field):
                old=self.verifier[field]; self.verifier[field]=bad
                with self.assertRaises(ValueError): self.validate()
                self.verifier[field]=old

    def test_extra_output_or_link_rejected(self):
        extra=self.root/'outputs/extra.png'; extra.write_bytes(png())
        with self.assertRaises(ValueError): self.validate()
        extra.unlink(); first=self.root/'outputs/cycle-1-original.png'; first.unlink()
        first.symlink_to(self.root/'outputs/cycle-2-original.png')
        with self.assertRaises(ValueError): self.validate()

    def test_wrong_role_dimension_and_missing_counter(self):
        for mutate in [lambda r:r.update(role='base'),lambda r:r.update(width=2),
                       lambda r:r['imageMetadata'].update(colorSpaceICC_SHA256='b'*64),
                       lambda r:r.update(exact=False),lambda r:r.pop('comparedBytes')]:
            with self.subTest(mutation=mutate):
                old=copy.deepcopy(self.verifier['validations'][0]); mutate(self.verifier['validations'][0])
                with self.assertRaises(ValueError): self.validate()
                self.verifier['validations'][0]=old


if __name__ == '__main__':
    unittest.main()
