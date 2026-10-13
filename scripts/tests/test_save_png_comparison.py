#!/usr/bin/env python3
"""Synthetic mutation tests. These do not claim an AppKit or signed native run."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

SCRIPT = Path(__file__).resolve().parents[1] / 'check-save-png-comparison.py'
spec = importlib.util.spec_from_file_location('save_png_reader', SCRIPT)
R = importlib.util.module_from_spec(spec)
spec.loader.exec_module(R)
SOURCE = 'a' * 40


def write(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def sha(value):
    return hashlib.sha256(value).hexdigest()


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))


PNG = (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', R.WIDTH, R.HEIGHT, 8, 6, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(b'\0' * ((R.WIDTH * 4 + 1) * R.HEIGHT))) + chunk(b'IEND', b''))
SOURCE_HASH, RGBA_HASH = sha(b'synthetic-source-identity'), sha(b'synthetic-rgba-identity')


def samples():
    return {'residentSampleCount': 4, 'physicalFootprintSampleCount': 4, 'failedResidentSampleCount': 0,
        'failedPhysicalFootprintSampleCount': 0, 'timerTickCount': 2, 'boundarySampleCount': 2,
        'peakResidentBytes': 90000000, 'peakPhysicalFootprintBytes': 95000000,
        'peakVolatileResidentBytes': 7000000, 'peakVolatileLedgerBytes': -5, 'backingSampleCount': 4}


class SyntheticPair:
    def __init__(self, directory):
        # macOS TemporaryDirectory may use /var; retain strict reader identity
        # by canonicalizing only this owned synthetic root before creating files.
        directory = Path(directory).resolve(strict=True)
        self.root = directory / 'evidence'
        self.root.mkdir()
        self.app = Path(directory) / 'PicShot.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/MacOS/PicShot').write_bytes(bytes.fromhex('cffaedfe0c000001') + b'synthetic-not-executable')
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'PicShotSourceCommit': SOURCE,
            'CFBundleExecutable': 'PicShot', 'CFBundleShortVersionString': 'test', 'CFBundleVersion': '266'}))
        identity, manifest = R.bundle_identity(self.app, SOURCE)
        for phase in ('before', 'after'):
            write(self.root / f'identity-{phase}.json', identity)
            write(self.root / f'bundle-manifest-{phase}.json', manifest)
            write(self.root / f'signature-{phase}.json', {'schemaVersion': 1, 'exitCode': 0})
        self.reports = {}
        for index, arm in enumerate(('control', 'candidate')):
            start = 100 + index * 70
            self.clock = start + 1
            report = self.common(arm, start)
            report.update({field: 'Synthetic test scope; not runtime evidence' for field in
                ('sourceScope', 'memoryScope', 'peakScope', 'ownershipScope', 'bookkeepingScope',
                 'afterPreparationScope', 'entryScope', 'interpretation')})
            report.update({'status': 'observed', 'arm': arm, 'pngPreparationMode': 'legacyPreview' if index == 0 else 'encodedPayload',
                'warmupCycles': 2, 'measuredCycles': 8, 'maximumOutputs': 10, 'completedCycles': 10,
                'cooperativeDeadlineSeconds': 300, 'nativeDrainDeadlineSeconds': 4,
                'outerDeadlineRequiredSeconds': 420, 'productSaveTimeoutSeconds': 300, 'sampleIntervalSeconds': .05,
                'independentDecodes': 0, 'extraReferenceRasterDraws': 0, 'captureStarted': False,
                'networkAttempted': False, 'userPreferencesRead': False, 'generalPasteboardReadOrWritten': False,
                'warmups': [], 'cycles': [], 'observationFailures': [], 'setupSeconds': .05,
                'outputsDirectory': 'outputs', 'lateDelaySeconds': .5, 'wholeRunSampledMemory': samples(),
                'activeJobsAfterAllCycles': 0, 'activeControllersAfterAllCycles': 0,
                'queuedOrRunningJobsAfterAllCycles': 0, 'retainedInputBytesAfterAllCycles': 0,
                'outputsPreserved': [f'cycle-{n:02d}.png' for n in range(1, 11)],
                'fixtureJobsDrained': True, 'isolatedDefaultsRemoved': True})
            for field in R.ENDPOINTS[:3]:
                report[field] = self.backing(index)
            for ordinal in range(1, 11):
                if ordinal == 3:
                    report['backingBaselineAfterWarmup'] = self.backing(index)
                report['warmups' if ordinal <= 2 else 'cycles'].append(self.cycle(arm, ordinal, index))
            report['backingFinal'] = self.backing(index)
            self.clock += .6
            report['backingLate'] = self.backing(index)
            report['finishedUptimeSeconds'] = self.clock
            report['elapsedSeconds'] = self.clock - report['beganUptimeSeconds']
            self.reports[arm] = report
            cell = self.root / arm
            (cell / 'outputs').mkdir(parents=True)
            for ordinal in range(1, 11):
                (cell / f'outputs/cycle-{ordinal:02d}.png').write_bytes(PNG)
            self.save(arm)
            self.launch(arm, start)
        validation = self.common('validation', 240)
        validation.update({'status': 'validated', 'measurementProcess': False,
            'independentValidationProcess': True, 'cooperativeDeadlineSeconds': 180,
            'producerPIDs': [1001, 1002], 'producerStatuses': ['observed', 'observed'],
            'sourceSHA256': SOURCE_HASH, 'canonicalSourceSHA256': RGBA_HASH,
            'validatedOutputs': 20, 'entries': [], 'finishedUptimeSeconds': 243, 'elapsedSeconds': 2.5})
        for ordinal in range(1, 11):
            for arm in ('control', 'candidate'):
                validation['entries'].append({'arm': arm, 'ordinal': ordinal,
                    'filename': f'outputs/cycle-{ordinal:02d}.png', 'encodedBytes': len(PNG), 'encodedSHA256': sha(PNG),
                    'width': R.WIDTH, 'height': R.HEIGHT, 'canonicalRGBABytes': R.WIDTH * R.HEIGHT * 4,
                    'canonicalRGBASHA256': RGBA_HASH, 'allSourcePixelsAndAlphaExactlyEqual': True,
                    'exactPNGBytesEqualAcrossArms': True, 'optionsVerified': True, 'pngMetadataVerified': True})
        self.reports['validation'] = validation
        (self.root / 'validation').mkdir()
        self.save('validation')
        self.launch('validation', 240)

    def common(self, name, start):
        return {'schemaVersion': 1, 'protocol': R.PROTOCOL, 'sourceCommit': SOURCE,
            'bundlePath': str(self.app), 'executablePath': str(self.app / 'Contents/MacOS/PicShot'),
            'architecture': 'arm64', 'processIdentifier': {'control': 1001, 'candidate': 1002, 'validation': 1003}[name],
            'operatingSystem': 'synthetic macOS', 'sourceWidth': R.WIDTH, 'sourceHeight': R.HEIGHT,
            'options': copy.deepcopy(R.OPTIONS), 'mode': 'validate' if name == 'validation' else 'measure',
            'scope': 'Synthetic fixture, not native evidence', 'beganUptimeSeconds': start + .5,
            'productionDefaultPNGPreparationMode': 'legacyPreview', 'productDefaultsChanged': False,
            'defaultsEvidenceScope': 'source-review-invariant-not-runtime-default-observation',
            'productConfigurationScope': 'Synthetic source invariant', 'exportLimits': copy.deepcopy(R.EXPORT_LIMITS)}

    def backing(self, adjustment):
        output = {}
        for part, flavor in [('standard', 'TASK_VM_INFO'), ('purgeable', 'TASK_VM_INFO_PURGEABLE')]:
            self.clock += .01
            counts = {field: 1000 for field in R.BACKING_BYTES | (R.VOLATILE_BYTES if part == 'purgeable' else set())}
            counts.update(resident_size=10000000-adjustment*100, phys_footprint=11000000,
                          resident_size_peak=90000000)
            ledgers = {field: -5 for field in R.LEDGERS}
            ledgers['ledger_phys_footprint_peak'] = 95000000
            output[part] = {'flavor': flavor, 'kernelReturn': 0, 'requestedNaturalCount': 104,
                'returnedNaturalCount': 104, 'observedAtUptimeSeconds': self.clock,
                'pageSizeBytes': 16384, 'regionCount': 100, 'bytes': counts, 'ledgerBytes': ledgers}
        return output

    def cycle(self, arm, ordinal, adjustment):
        value = {field: self.backing(adjustment) for field in R.STAGES}
        value.update({'schemaVersion': 1, 'protocol': R.PROTOCOL, 'arm': arm, 'ordinal': ordinal,
            'index': ordinal if ordinal <= 2 else ordinal-2, 'isWarmup': ordinal <= 2,
            'status': 'observed', 'options': copy.deepcopy(R.OPTIONS), 'outputFilename': f'outputs/cycle-{ordinal:02d}.png',
            'workloadCompleted': True, 'independentDecodes': 0, 'extraReferenceRasterDraws': 0,
            'queueCounts': {stage: 0 for stage in R.STAGES}, 'sourceCreateSeconds': .01,
            'sourceSHA256': SOURCE_HASH, 'sourceHashSeconds': .01, 'controllerCreationSeconds': .01,
            'nativeWindowVisibleAtAdmission': True, 'reservedInputBytes': R.WIDTH*R.HEIGHT*4,
            'activeJobsAtAdmission': 1, 'retainedInputBytesAtAdmission': R.WIDTH*R.HEIGHT*4,
            'terminalState': 'completed', 'nativeWindowVisibleAtCompletion': True,
            'jobDrainedAtCompletion': True, 'activeJobsAtCompletion': 0, 'encodedBytes': len(PNG),
            'publishedFilenameMatches': True, 'clipboardNotRequested': True, 'closedThroughNativeButton': True,
            'saveCallbackCount': 1, 'preparationCallbackCount': 1, 'saveLatencySeconds': .08,
            'requestToPreparedSeconds': .04, 'ownershipDrained': True, 'sampledMemory': samples(),
            'stagingEntries': [], 'stagingCleanupConfirmed': True, 'elapsedSeconds': .2, 'observationFailures': [],
            'drain': {'initial': {field: False for field in R.OWNERS}, 'final': {field: True for field in R.OWNERS},
                      'elapsedSeconds': .01, 'maximumSeconds': 4, 'activeJobs': 0, 'activeControllers': 0,
                      'retainedInputBytes': 0, 'queueCount': 0}})
        return value

    def save(self, name):
        report = self.reports[name]
        cell = self.root / name
        filename = 'save-png-validation.json' if name == 'validation' else 'save-png-comparison.json'
        write(cell / filename, report)
        write(cell / 'smoke.json', {**report, 'historyDirectoryRemoved': True,
            'arguments': [str(self.app / 'Contents/MacOS/PicShot')]})
        if name != 'validation':
            for row in report['warmups'] + report['cycles']:
                write(cell / f"save-png-cycle-{row['ordinal']:02d}.json", row)

    def launch(self, name, start):
        validate = name == 'validation'
        cell = self.root / name
        executable = str(self.app / 'Contents/MacOS/PicShot')
        launcher = {'schemaVersion': 1, 'status': 'exited', 'launcherExitCode': 0, 'selectedAppPath': str(self.app),
            'createsNewApplicationInstance': True, 'timeoutSeconds': 240 if validate else 360,
            'elapsedSeconds': 30, 'callbackReceived': True, 'ownedExitConfirmed': True,
            'processStartMemoryCaptured': False, 'scope': 'Synthetic owned launch', 'launchBeganUptimeSeconds': start,
            'finishUptimeSeconds': start+30, 'launchedIdentityMatches': True, 'expectedExecutablePath': executable,
            'processIdentifier': self.reports[name]['processIdentifier'], 'launchedAppPath': str(self.app),
            'launchedExecutablePath': executable, 'savePNGComparisonDiagnosticOnly': True,
            'savePNGComparisonMode': 'validate' if validate else 'measure', 'arguments': []}
        write(cell / 'smoke.json.launcher.json', launcher)
        command = ['env', '-i', 'HOME=/synthetic/home', 'PATH=/usr/bin:/bin', 'TMPDIR=/tmp',
            'PICSHOT_SAVE_PNG_COMPARISON_MODE=' + ('validate' if validate else 'measure'),
            'PICSHOT_SAVE_PNG_COMPARISON_INPUT_DIRECTORY=' + str(self.root) if validate else 'PICSHOT_SAVE_PNG_COMPARISON_ARM=' + name,
            'swift', 'scripts/launch-smoke-app.swift', str(self.app), str(cell / 'smoke.json')]
        write(cell / 'command.json', {'schema_version': 1, 'status': 'exited', 'command': command,
            'started_at': '2026-10-13T00:00:00+00:00', 'timeout_seconds': 300 if validate else 420,
            'grace_seconds': 5, 'max_log_bytes': R.MAX_LOG, 'pid': 3001, 'child_returncode': 0,
            'exit_code': 0, 'cancel_signal': None, 'sigterm_sent': False, 'sigkill_sent': False,
            'descendant_cleanup': False, 'output_bytes': 0, 'log_bytes': 0, 'log_truncated': False,
            'termination_reason': 'exited', 'duration_seconds': 31,
            'group_observation': {'backend': 'darwin-ps-pgrp', 'timeout_seconds': .5, 'count': 1,
                'failures': 0, 'total_seconds': .01, 'max_seconds': .01, 'atomic_snapshot': False}})
        (cell / 'launcher.log').write_text('')
        (cell / 'launcher-exit-code.txt').write_text('0\n')

    def run(self):
        return R.run(self.root, self.app, SOURCE)


class ReaderMutations(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.pair = SyntheticPair(self.temporary.name)

    def test_complete_pair_retains_absolute_signed_observations_without_benefit_claim(self):
        result = self.pair.run()
        self.assertTrue(result['evidenceComplete'], result['errors'])
        self.assertEqual(result['benefitVerdict'], 'single-pair-diagnostic-requires-review')
        self.assertFalse(result['promotionReady'])
        self.assertFalse(result['memoryStabilityAssessed'])
        self.assertFalse(result['statisticalSignificanceAssessed'])
        self.assertFalse(result['general227RemedyClaim'])
        self.assertFalse(result['nativeExecutionAttestedByChecker'])
        self.assertEqual(result['retainedOutputValidation']['validatedOutputCount'], 20)
        self.assertEqual(result['candidateMinusControl']['absoluteEndpointsBytes']['diagnosticEntryBacking']['rss'], -100)
        self.assertEqual(result['measurements']['control']['absoluteEndpointsBytes']['backingLate']['volatileLedger'], -5)
        self.assertEqual(len(result['measurements']['control']['absoluteEveryCycleBoundaryBytes']), 10)
        self.assertEqual(len(result['measurements']['control']['everyMeasuredIncrementBytes']), 8)
        self.assertEqual(len(result['measurements']['control']['lateMeasuredIncrementBytes']), 3)
        self.assertEqual(result['nativeReports']['control']['backingLate'], self.pair.reports['control']['backingLate'])

    def test_owned_fixture_alias_is_canonicalized_but_reader_still_rejects_alias_app(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(strict=True)
            physical = root / 'physical'; physical.mkdir()
            alias = root / 'alias'; alias.symlink_to(physical, target_is_directory=True)
            pair = SyntheticPair(alias)
            self.assertEqual(pair.root, physical / 'evidence')
            self.assertEqual(pair.app, physical / 'PicShot.app')
            result = pair.run()
            self.assertTrue(result['evidenceComplete'], result['errors'])
            with self.assertRaisesRegex(ValueError, 'canonical'):
                R.bundle_identity(alias / 'PicShot.app', SOURCE)

    def test_failed_measurement_still_validates_all_twenty_outputs_and_preserves_observations(self):
        control = self.pair.reports['control']
        control['status'] = 'failed'
        control['observationFailures'] = ['Missing volatile sample']
        del control['backingFinal']['purgeable']['bytes']['purgeable_volatile_resident']
        self.pair.save('control')
        self.pair.reports['validation']['producerStatuses'][0] = 'failed'
        self.pair.save('validation')
        result = self.pair.run()
        self.assertFalse(result['evidenceComplete'])
        self.assertEqual(result['retainedOutputValidation']['status'], 'validated', result['errors'])
        self.assertEqual(result['retainedOutputValidation']['validatedOutputCount'], 20)
        self.assertEqual(result['nativeReports']['control']['status'], 'failed')
        self.assertNotIn('candidateMinusControl', result)

    def test_measurement_mutations_are_rejected_independently_of_output_validation(self):
        cases = [
            ('missing endpoint', lambda r: r.pop('backingLate')),
            ('unknown root', lambda r: r.update(inventedQualification=True)),
            ('bool count', lambda r: r.update(warmupCycles=True)),
            ('wrong mode', lambda r: r.update(pngPreparationMode='legacyPreview')),
            ('default changed', lambda r: r.update(productionDefaultPNGPreparationMode='encodedPayload')),
            ('limit relaxed', lambda r: r['exportLimits'].update(maximumEncodedBytes=999999999)),
            ('native hidden', lambda r: r['cycles'][0].update(nativeWindowVisibleAtAdmission=False)),
            ('owner retained', lambda r: r['cycles'][0]['drain']['final'].update(sourceReleased=False)),
            ('active job', lambda r: r['cycles'][0]['drain'].update(activeJobs=1)),
            ('missing preparation', lambda r: r['cycles'][0].update(preparationCallbackCount=0)),
            ('staging present', lambda r: r['cycles'][0].update(stagingEntries=['temp.png'])),
            ('decode contamination', lambda r: r['cycles'][0].update(independentDecodes=1)),
            ('raster contamination', lambda r: r.update(extraReferenceRasterDraws=1)),
            ('failed sample', lambda r: r['wholeRunSampledMemory'].update(failedResidentSampleCount=1)),
            ('dropped volatile samples', lambda r: r['wholeRunSampledMemory'].update(backingSampleCount=1)),
            ('no timer', lambda r: r['cycles'][0]['sampledMemory'].update(timerTickCount=0)),
            ('missing sampled peak', lambda r: r['wholeRunSampledMemory'].pop('peakVolatileResidentBytes')),
            ('failed Mach', lambda r: r['backingFinal']['standard'].update(kernelReturn=5)),
            ('missing volatile', lambda r: r['backingFinal']['purgeable']['bytes'].pop('purgeable_volatile_resident')),
            ('unknown Mach', lambda r: r['backingFinal']['standard']['bytes'].update(pretendMemory=3)),
            ('short Mach', lambda r: r['backingFinal']['standard'].update(returnedNaturalCount=0)),
            ('bool memory', lambda r: r['backingFinal']['standard']['bytes'].update(resident_size=True)),
            ('reordered time', lambda r: r['cycles'][0]['settledBacking']['standard'].update(observedAtUptimeSeconds=0)),
            ('latency reversed', lambda r: r['cycles'][0].update(requestToPreparedSeconds=100)),
            ('late omitted', lambda r: r.update(lateDelaySeconds=0)),
            ('unknown cycle', lambda r: r['cycles'][0].update(benefitPass=True)),
            ('x86 slice', lambda r: r.update(architecture='x86_64')),
        ]
        original = copy.deepcopy(self.pair.reports['candidate'])
        for label, mutate in cases:
            with self.subTest(label=label):
                self.pair.reports['candidate'] = copy.deepcopy(original)
                mutate(self.pair.reports['candidate'])
                self.pair.save('candidate')
                result = self.pair.run()
                self.assertFalse(result['evidenceComplete'], label)
                self.assertTrue(any(error['check'] == 'candidate.measurement' for error in result['errors']), result['errors'])
        self.pair.reports['candidate'] = original

    def test_output_validation_mutations(self):
        cases = [
            ('missing output', lambda r: r['entries'].pop()),
            ('RGBA mismatch', lambda r: r['entries'][3].update(canonicalRGBASHA256='f'*64)),
            ('alpha missing', lambda r: r['entries'][3].update(allSourcePixelsAndAlphaExactlyEqual=False)),
            ('options unchecked', lambda r: r['entries'][3].update(optionsVerified=False)),
            ('metadata unchecked', lambda r: r['entries'][3].update(pngMetadataVerified=False)),
            ('byte mismatch', lambda r: r['entries'][3].update(encodedSHA256='f'*64)),
            ('wrong arm', lambda r: r['entries'][3].update(arm='control')),
            ('traversal', lambda r: r['entries'][3].update(filename='../control/outputs/cycle-02.png')),
            ('wrong size', lambda r: r['entries'][3].update(width=1920)),
            ('bool size', lambda r: r['entries'][3].update(ordinal=True)),
            ('unknown entry', lambda r: r['entries'][3].update(allowMismatch=True)),
            ('same process', lambda r: r.update(producerPIDs=[1001, 1001])),
            ('wrong source', lambda r: r.update(sourceSHA256='f'*64)),
            ('in-measure decode', lambda r: r.update(measurementProcess=True)),
            ('validation failed', lambda r: r.update(status='failed')),
            ('wrong validator deadline', lambda r: r.update(cooperativeDeadlineSeconds=300)),
        ]
        original = copy.deepcopy(self.pair.reports['validation'])
        for label, mutate in cases:
            with self.subTest(label=label):
                self.pair.reports['validation'] = copy.deepcopy(original)
                mutate(self.pair.reports['validation'])
                self.pair.save('validation')
                result = self.pair.run()
                self.assertFalse(result['evidenceComplete'], label)
                self.assertTrue(any(error['check'] == 'retained-outputs' for error in result['errors']), result['errors'])

    def test_physical_output_changed_is_rejected_even_when_memory_already_failed(self):
        self.pair.reports['control']['observationFailures'] = ['sample unavailable']
        self.pair.save('control')
        path = self.pair.root / 'candidate/outputs/cycle-07.png'
        data = bytearray(path.read_bytes()); data[40] ^= 1; path.write_bytes(data)
        result = self.pair.run()
        self.assertFalse(result['evidenceComplete'])
        self.assertTrue(any(row['check'] == 'retained-outputs' for row in result['errors']))
        self.assertTrue(any(row['check'] == 'control.measurement' for row in result['errors']))

    def test_changed_receipt_is_rejected(self):
        path = self.pair.root / 'candidate/save-png-cycle-04.json'
        value = json.loads(path.read_text()); value['encodedBytes'] += 1; write(path, value)
        result = self.pair.run()
        self.assertFalse(result['evidenceComplete'])
        self.assertTrue(any(row['check'] == 'retained-outputs' for row in result['errors']))

    def test_linked_output_and_extra_staging_are_rejected(self):
        output = self.pair.root / 'candidate/outputs/cycle-03.png'
        output.unlink(); output.symlink_to(self.pair.root / 'control/outputs/cycle-03.png')
        self.assertFalse(self.pair.run()['evidenceComplete'])
        output.unlink(); output.write_bytes(PNG)
        (output.parent / '.staging').write_bytes(b'staging')
        self.assertFalse(self.pair.run()['evidenceComplete'])

    def test_identity_mutations(self):
        cases = [('main hash', 'mainExecutableSHA256', 'f'*64), ('source', 'sourceCommit', 'b'*40),
                 ('bundle hash', 'bundleFilesSHA256', 'e'*64), ('bool count', 'bundleEntryCount', True),
                 ('unknown', 'unverifiedApproval', True)]
        path = self.pair.root / 'identity-after.json'
        original = json.loads(path.read_text())
        for label, field, value in cases:
            with self.subTest(label=label):
                altered = copy.deepcopy(original); altered[field] = value; write(path, altered)
                result = self.pair.run()
                self.assertFalse(result['evidenceComplete'])
                self.assertTrue(any(row['check'] == 'identity' for row in result['errors']))
        write(path, original)
        (self.pair.app / 'Contents/extra').write_text('changed bundle')
        self.assertFalse(self.pair.run()['evidenceComplete'])

    def test_bad_signature_manifest_and_source_rejected(self):
        write(self.pair.root / 'signature-before.json', {'schemaVersion': 1, 'exitCode': 1})
        self.assertFalse(self.pair.run()['evidenceComplete'])
        write(self.pair.root / 'signature-before.json', {'schemaVersion': 1, 'exitCode': 0})
        path = self.pair.root / 'bundle-manifest-before.json'
        manifest = json.loads(path.read_text()); manifest.pop(); write(path, manifest)
        self.assertFalse(self.pair.run()['evidenceComplete'])
        self.assertFalse(R.run(self.pair.root, self.pair.app, 'b'*40)['evidenceComplete'])

    def test_lifecycle_and_command_mutations(self):
        path = self.pair.root / 'candidate/smoke.json.launcher.json'
        original = json.loads(path.read_text())
        cases = [('owned exit', 'ownedExitConfirmed', False), ('PID', 'processIdentifier', 1001),
                 ('argv', 'arguments', ['--other']), ('deadline', 'timeoutSeconds', 999),
                 ('identity', 'launchedIdentityMatches', False), ('unknown', 'pretendSafe', True)]
        for label, field, value in cases:
            with self.subTest(label=label):
                changed = copy.deepcopy(original); changed[field] = value; write(path, changed)
                self.assertFalse(self.pair.run()['evidenceComplete'])
        write(path, original)
        command_path = self.pair.root / 'candidate/command.json'
        original_command = json.loads(command_path.read_text())
        for mutation in (lambda r: r['command'].__setitem__(6, 'PICSHOT_SAVE_PNG_COMPARISON_ARM=control'),
                         lambda r: r['command'].__setitem__(2, 'PICSHOT_UNRELATED=1'),
                         lambda r: r.update(sigterm_sent=True),
                         lambda r: r['group_observation'].update(failures=1),
                         lambda r: r.update(max_log_bytes=999),
                         lambda r: r['command'].__setitem__(4, 'TMPDIR=/different')):
            changed = copy.deepcopy(original_command); mutation(changed); write(command_path, changed)
            self.assertFalse(self.pair.run()['evidenceComplete'])

    def test_validation_must_start_after_owned_producer_exit(self):
        path = self.pair.root / 'candidate/smoke.json.launcher.json'
        value = json.loads(path.read_text())
        value['finishUptimeSeconds'] = 250; value['elapsedSeconds'] = 80; write(path, value)
        command = self.pair.root / 'candidate/command.json'
        value = json.loads(command.read_text()); value['duration_seconds'] = 81; write(command, value)
        result = self.pair.run()
        self.assertFalse(result['evidenceComplete'])
        self.assertTrue(any(row['check'] == 'fresh-process-order' for row in result['errors']), result['errors'])

    def test_duplicate_and_nonfinite_json_rejected(self):
        path = self.pair.root / 'candidate/save-png-comparison.json'
        for content in ('{"status":"observed","status":"failed"}', '{"value":NaN}', '{"value":1e9999}'):
            path.write_text(content)
            result = self.pair.run()
            self.assertFalse(result['evidenceComplete'])
            self.assertTrue(any(row['check'] == 'candidate.report' for row in result['errors']))

    def test_unknown_envelope_and_no_native_history_cleanup_rejected(self):
        path = self.pair.root / 'control/smoke.json'
        original = json.loads(path.read_text())
        for key, value in [('unknown', True), ('historyDirectoryRemoved', False), ('arguments', [])]:
            changed = copy.deepcopy(original); changed[key] = value; write(path, changed)
            self.assertFalse(self.pair.run()['evidenceComplete'])

    def test_cli_success_means_complete_evidence_and_failure_remains_nonzero(self):
        command = [sys.executable, '-I', str(SCRIPT), str(self.pair.root), '--bundle', str(self.pair.app), '--source', SOURCE]
        complete = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(complete.returncode, 0, complete.stdout + complete.stderr)
        output = json.loads((self.pair.root / 'save-png-summary.json').read_text())
        self.assertEqual(output['benefitVerdict'], 'single-pair-diagnostic-requires-review')
        (self.pair.root / 'candidate/outputs/cycle-01.png').unlink()
        failed = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(failed.returncode, 2, failed.stdout + failed.stderr)
        self.assertFalse(json.loads((self.pair.root / 'save-png-summary.json').read_text())['evidenceComplete'])


if __name__ == '__main__':
    unittest.main()
