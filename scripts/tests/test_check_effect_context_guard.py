"""Portable adversarial guard contracts; synthetic files do not attest native runs."""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
SCRIPT = SCRIPTS / 'check-effect-context-guard.py'
MISSING = object()


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


CHECK = module('effect_context_guard_checker_tests', SCRIPT)
DRAWING = module('effect_context_guard_drawing_fixture', SCRIPTS / 'tests/test_check_drawing_raster_guard.py')
RENDERER = module('effect_context_guard_renderer_fixture', SCRIPTS / 'tests/test_check_renderer_storage_pair.py')


def effect_state(policy, work=0):
    value = dict(attemptCount=work, publishCount=work, failureCount=0, contextCount=1,
                 contextOptionCount=2 if policy == 'memory32' else 1, configuredCacheIntermediates=False)
    if policy == 'memory32':
        value['configuredMemoryTargetMegabytes'] = 32
    return value


def positive_control(policy, before_work=0):
    metadata = dict(width=129, height=101, bitsPerComponent=8, bitsPerPixel=32, bytesPerRow=516,
        bitmapInfo=16385, alphaInfo=1, renderingIntent=1, colorSpaceModel=1, shouldInterpolate=False,
        hasDecodeArray=False, isMask=False, colorSpaceName='kCGColorSpaceSRGB', colorSpaceICCSHA256='6' * 64)
    records = []
    for index, effect in enumerate(('blur', 'pixelate')):
        records.append(dict(effect=effect, inputWidth=129, inputHeight=101, outputWidth=129, outputHeight=101,
            inputRGBASHA256='1' * 64, referenceRGBASHA256=str(2 + index) * 64,
            candidateRGBASHA256=str(2 + index) * 64, referenceStoredPixelsSHA256=str(4 + index) * 64,
            candidateStoredPixelsSHA256=str(4 + index) * 64,
            referenceMetadata=copy.deepcopy(metadata), candidateMetadata=copy.deepcopy(metadata),
            pixelsEqual=True, rgbaEqual=True, metadataEqual=True, outputDiffersFromInput=True))
    return dict(schemaVersion=1, status='passed', stage='separate-positive-effect-control-after-output-guard',
        comparisonKind='effect-context-memory-target', selectedPolicy=policy,
        processBefore=effect_state(policy, before_work), processAfter=effect_state(policy, before_work + 2),
        processControlCallCount=2, independentReferenceContextCount=1, independentReferenceCallCount=2,
        rasterObservationCount=5, memoryObservationCount=0, records=records)


class EffectContextGuardTests(unittest.TestCase):
    def setUp(self):
        self.fixture = DRAWING.DrawingGuardCheckerTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        # Canonicalize before constructing identities, report paths, or CLI args:
        # macOS TemporaryDirectory roots can use the /var -> /private/var alias.
        self.root = self.fixture.directory.resolve(strict=True)
        self.app = self.fixture.app.resolve(strict=True)
        self.source = self.fixture.source
        self.executable = self.app / 'Contents/MacOS/PicShot'
        self.executable.write_bytes(bytes.fromhex('cffaedfe') + struct.pack('<I', 0x0100000c)
                                    + b'synthetic identity only; never executed')
        self.arms = {policy: self.materialize(policy, index)
                     for index, policy in enumerate(('reference', 'memory32'))}

    def materialize(self, policy, index):
        directory = self.root / policy
        directory.mkdir()
        directory = directory.resolve(strict=True)
        native, drawing = copy.deepcopy((self.fixture.native, self.fixture.sidecar))
        pid = 4321 + index
        native['processIdentifier'] = drawing['processIdentifier'] = pid
        drawing['nativeReportPath'] = str(directory / 'effect-output-failure.json')
        launcher = json.loads(self.fixture.launcher_path.read_text())
        began = 1000 + 200 * index
        launcher.update(processIdentifier=pid, drawingStrategy='owned-srgb8', rendererStorageStrategy='native',
            comparisonKind='effect-context-memory-target', rendererAutoreleaseScope='caller', effectContextPolicy=policy,
            timeoutSeconds=600, elapsedSeconds=140, launchBeganUptimeSeconds=began, finishUptimeSeconds=began + 140,
            processStartMemoryCaptured=False, scope='Synthetic lifecycle only, not a native run')
        wrapper = dict(schema_version=1, status='exited',
            command=['swift', 'scripts/launch-effect-context-guard.swift', str(self.app), str(directory / 'launch.json'), policy],
            started_at=f'2026-10-08T00:0{index * 3}:00+00:00', timeout_seconds=620, grace_seconds=5,
            max_log_bytes=2 * 1024 * 1024, pid=5001 + index, child_returncode=0, exit_code=0,
            cancel_signal=None, sigterm_sent=False, sigkill_sent=False, descendant_cleanup=False,
            output_bytes=16, log_bytes=16, log_truncated=False, termination_reason='exited', duration_seconds=141,
            group_observation=dict(backend='darwin-ps-pgrp', timeout_seconds=.5, count=2, failures=0,
                total_seconds=.02, max_seconds=.01, atomic_snapshot=False))
        renderer = RENDERER.state('native', 108)
        renderer.update(attemptCount=588, nativeCount=588, seedCount=588, failureCount=480)
        report = {key: native[key] for key in ('sourceCommit', 'version', 'buildVersion', 'bundlePath',
                                               'executablePath', 'processIdentifier')}
        report.update(schemaVersion=1, status='observed', diagnosticOnly=True,
            comparisonKind='effect-context-memory-target', observationBoundary='after-effect-output-failure-fixture-return',
            executableSHA256=hashlib.sha256(self.executable.read_bytes()).hexdigest(),
            executableBytes=self.executable.stat().st_size, nativeReportPath=str(directory / 'effect-output-failure.json'),
            requestedPolicy=policy, effectContextPolicy=policy, productionDefaultPolicy='reference',
            rendererStorageStrategy='native', rendererAutoreleaseScope='caller', rendererProductionDefaultStrategy='native',
            drawingStrategy='owned-srgb8', scalarAdditionalRasterObservations=0, additionalMemoryObservations=0,
            contextOwnershipScope='one-immutable-process-context', effectContext=effect_state(policy), rendererStorage=renderer,
            positiveControl=positive_control(policy))
        arm = dict(directory=directory, native=native, drawing=drawing, launcher=launcher, wrapper=wrapper, report=report)
        (directory / 'launcher.log').write_bytes(b'synthetic log\n  ')
        self.save(arm)
        return arm

    def save(self, arm):
        directory = arm['directory']
        native_bytes = json.dumps(arm['native'], sort_keys=True).encode()
        digest = hashlib.sha256(native_bytes).hexdigest()
        for report in (arm['drawing'], arm['report']):
            report.update(nativeReportBytes=len(native_bytes), nativeReportSHA256=digest)
        drawing_bytes = json.dumps(arm['drawing'], sort_keys=True).encode()
        arm['report']['drawingReportSHA256'] = hashlib.sha256(drawing_bytes).hexdigest()
        (directory / 'effect-output-failure.json').write_bytes(native_bytes)
        (directory / 'drawing-raster-output-guard.json').write_bytes(drawing_bytes)
        for key, filename in (('report', CHECK.FILENAME), ('launcher', 'launch.json.launcher.json'),
                              ('wrapper', 'bounded-launch.json')):
            (directory / filename).write_text(json.dumps(arm[key], sort_keys=True))

    def check(self, policy='reference'):
        return CHECK.check_directory(self.arms[policy]['directory'], self.app, self.source, policy)

    def cli(self, optimized=False, policy='reference', pair=False, args=None):
        if args is None:
            args = [self.root if pair else self.arms[policy]['directory'], self.app, self.source,
                    *(['--pair'] if pair else ['--policy', policy])]
        return subprocess.run([sys.executable, *(['-O'] if optimized else []), str(SCRIPT), *map(str, args)],
                              capture_output=True, text=True, timeout=20, check=False)

    def reject(self, component, key, value=MISSING, policy='reference', error=None):
        original = self.arms[policy]
        arm = copy.deepcopy(original)
        target = arm
        for name in component.split('.'):
            target = target[int(name)] if type(target) is list else target[name]
        if value is MISSING:
            target.pop(key)
        else:
            target[key] = value
        if component.startswith('report'):
            # Keep mutations of byte bindings intact; save() deliberately
            # rebinds upstream native/drawing changes for their own tests.
            (arm['directory'] / CHECK.FILENAME).write_text(json.dumps(arm['report'], sort_keys=True))
        else:
            self.save(arm)
        try:
            context = self.assertRaisesRegex(ValueError, error) if error else self.assertRaises((ValueError, OSError))
            with context:
                self.check(policy)
        finally:
            self.save(original)

    def test_complete_arms_preserve_original_matrix_and_do_not_attest_native_acceptance(self):
        for policy in ('reference', 'memory32'):
            with self.subTest(policy=policy):
                result = self.check(policy)
                self.assertEqual((result['caseCount'], result['rejectedOutputAttempts'], result['controllerReleaseCount']),
                                 (24, 432, 24))
                self.assertEqual(result['effectContextPolicy'], policy)
                self.assertEqual(result['productionDefaultPolicy'], 'reference')
                self.assertEqual(result['rendererStorageStrategy'], 'native')
                self.assertEqual(result['rendererAutoreleaseScope'], 'caller')
                self.assertEqual(result['architecture'], 'arm64')
                self.assertEqual(result['drawingTracker'], self.arms[policy]['drawing']['tracker'])
                self.assertEqual(result['rendererStorage']['failureCount'], 480)
                self.assertEqual(result['effectContext']['failureCount'], 0)
                self.assertEqual(result['effectContext']['attemptCount'], 0)
                self.assertEqual(result['positiveControl']['processAfter']['attemptCount'], 2)
                for field in ('injectedRefusalsAreEffectContextFailures', 'nativeExecutionAttestedByChecker',
                              'privateFrameworkReleaseClaim', 'productMemoryRemedyClaim'):
                    self.assertIs(result[field], False)
                for optimized in (False, True):
                    process = self.cli(optimized, policy)
                    self.assertEqual(process.returncode, 0, process.stderr)
                    self.assertEqual(json.loads(process.stdout), result)

    def test_policy_pair_requires_independent_ordered_complete_processes(self):
        result = CHECK.compare_guards(self.root, self.app, self.source)
        self.assertEqual(set(result['arms']), {'reference', 'memory32'})
        self.assertEqual(result['status'], 'passed')
        self.assertFalse(result['memoryStabilityAssessed'])
        self.assertFalse(result['nativeExecutionAttestedByChecker'])
        for optimized in (False, True):
            process = self.cli(optimized, pair=True)
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertEqual(json.loads(process.stdout), result)
        candidate = copy.deepcopy(self.arms['memory32'])
        for component in ('native', 'drawing', 'report', 'launcher'):
            candidate[component]['processIdentifier'] = 4321
        self.save(candidate)
        self.check('memory32')
        with self.assertRaisesRegex(ValueError, 'reused a process'):
            CHECK.compare_guards(self.root, self.app, self.source)
        candidate = copy.deepcopy(self.arms['memory32'])
        candidate['launcher'].update(launchBeganUptimeSeconds=1100, finishUptimeSeconds=1240)
        self.save(candidate)
        self.check('memory32')
        with self.assertRaisesRegex(ValueError, 'overlap or reordered'):
            CHECK.compare_guards(self.root, self.app, self.source)

    def test_closed_schema_rejects_missing_and_unrecognized_fields(self):
        components = ('report', 'report.effectContext', 'report.rendererStorage', 'report.positiveControl',
                      'report.positiveControl.processBefore', 'report.positiveControl.processAfter',
                      'report.positiveControl.records.0', 'report.positiveControl.records.1',
                      'launcher', 'wrapper', 'wrapper.group_observation')
        for policy in ('reference', 'memory32'):
            for component in components:
                target = self.arms[policy]
                for name in component.split('.'):
                    target = target[int(name)] if type(target) is list else target[name]
                for key in target:
                    with self.subTest(policy=policy, component=component, missing=key):
                        self.reject(component, key, policy=policy)
                with self.subTest(policy=policy, component=component, extra=True):
                    self.reject(component, 'inventedAcceptance', True, policy)
        for field in ('effectContext', 'rendererStorage', 'positiveControl'):
            for value in (None, [], True, 1, 'observed'):
                self.reject('report', field, value)

    def test_policy_selectors_comparison_kind_and_fixed_configuration_are_exact(self):
        mutations = dict(schemaVersion=2, status='passed', diagnosticOnly=1, comparisonKind='renderer-final-storage',
            observationBoundary='before-fixture', requestedPolicy='memory32', effectContextPolicy='memory32',
            productionDefaultPolicy='memory32', rendererStorageStrategy='native-pooled', rendererAutoreleaseScope='whole-render',
            rendererProductionDefaultStrategy='owned-srgb8', drawingStrategy='reference', scalarAdditionalRasterObservations=1,
            additionalMemoryObservations=1, contextOwnershipScope='per-effect-context')
        for key, value in mutations.items():
            with self.subTest(key=key):
                self.reject('report', key, value)
        for key in ('schemaVersion', 'scalarAdditionalRasterObservations', 'additionalMemoryObservations'):
            for value in (False, True, 0.0, None, '0'):
                self.reject('report', key, value)
        self.reject('report', 'additionalRasterObservations', 0)
        for policy in (None, True, 32, '', 'memory64', 'owned-srgb8'):
            with self.subTest(policy=policy), self.assertRaises(ValueError):
                CHECK.check_directory(self.arms['reference']['directory'], self.app, self.source, policy)
        for args in ([], [self.root, self.app, self.source],
                     [self.root, self.app, self.source, '--policy', 'memory64'],
                     [self.root, self.app, self.source, '--policy', 'reference', '--pair']):
            for optimized in (False, True):
                result = self.cli(optimized, args=args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')

    def test_effect_options_and_counters_are_strict_scalars(self):
        for policy in ('reference', 'memory32'):
            for key in ('attemptCount', 'publishCount', 'failureCount', 'contextCount', 'contextOptionCount'):
                for value in (None, True, False, '0', 0.0, -1, 1 << 63):
                    with self.subTest(policy=policy, key=key, value=value):
                        self.reject('report.effectContext', key, value, policy)
            for value in (True, 0, 1, None, 'false'):
                self.reject('report.effectContext', 'configuredCacheIntermediates', value, policy)
            for key, value in (('contextCount', 2), ('contextOptionCount', 3), ('attemptCount', 3),
                               ('publishCount', 3), ('failureCount', 1)):
                self.reject('report.effectContext', key, value, policy)
        self.reject('report.effectContext', 'configuredMemoryTargetMegabytes', 32)
        for value in (None, True, '32', 32.0, 0, 31, 33, 1 << 63):
            self.reject('report.effectContext', 'configuredMemoryTargetMegabytes', value, 'memory32')

    def test_positive_control_requires_only_its_two_real_calls_after_the_original_snapshot(self):
        for policy in ('reference', 'memory32'):
            # The untouched failure-injection guard may make zero real CI calls.
            # Neither its 432 rejected outputs nor reference-control work may be
            # folded into the separate process-context delta.
            for before_work in (0, 7):
                arm = copy.deepcopy(self.arms[policy])
                arm['report']['effectContext'] = effect_state(policy, before_work)
                arm['report']['positiveControl'] = positive_control(policy, before_work)
                self.save(arm)
                result = self.check(policy)
                control = result['positiveControl']
                self.assertEqual(result['effectContext']['attemptCount'], before_work)
                self.assertEqual(control['processAfter']['attemptCount'], before_work + 2)
                self.assertEqual(control['independentReferenceContextCount'], 1)
                self.assertEqual(control['independentReferenceCallCount'], 2)
            self.save(self.arms[policy])
            self.reject('report.positiveControl', 'processBefore', effect_state(policy, 1), policy,
                        error='does not follow original guard snapshot|call delta')
            for after_work in (0, 1, 3, 432, 434):
                self.reject('report.positiveControl', 'processAfter', effect_state(policy, after_work), policy,
                            error='call delta')
            for snapshot in ('processBefore', 'processAfter'):
                component = 'report.positiveControl.' + snapshot
                self.reject(component, 'contextCount', 2, policy)
                self.reject(component, 'failureCount', 1, policy)
                self.reject(component, 'contextOptionCount', 3, policy)
                self.reject(component, 'configuredCacheIntermediates', True, policy)
                if policy == 'memory32':
                    self.reject(component, 'configuredMemoryTargetMegabytes', 64, policy)
                else:
                    self.reject(component, 'configuredMemoryTargetMegabytes', 32, policy)

    def test_positive_control_stage_independent_reference_and_observation_budget_are_exact(self):
        component = 'report.positiveControl'
        for key, value in dict(status='observed', stage='inside-original-output-guard',
                comparisonKind='renderer-final-storage', selectedPolicy='memory32').items():
            self.reject(component, key, value)
        counts = dict(schemaVersion=1, processControlCallCount=2, independentReferenceContextCount=1,
                      independentReferenceCallCount=2, rasterObservationCount=5, memoryObservationCount=0)
        for key, expected in counts.items():
            for value in (None, True, False, str(expected), float(expected), -1, expected + 1, 1 << 63):
                with self.subTest(key=key, value=value):
                    self.reject(component, key, value)
        records = self.arms['reference']['report']['positiveControl']['records']
        for value in (None, {}, [], records[:1], records[::-1], records * 2, [records[0], records[0]]):
            self.reject(component, 'records', value)

    def test_positive_control_assertions_cannot_replace_exact_effective_pixel_equality(self):
        for index in (0, 1):
            component = f'report.positiveControl.records.{index}'
            for field in ('pixelsEqual', 'rgbaEqual', 'metadataEqual', 'outputDiffersFromInput'):
                for value in (False, 0, 1, None, 'true'):
                    self.reject(component, field, value)
            for field in ('inputWidth', 'inputHeight', 'outputWidth', 'outputHeight'):
                expected = 129 if field.endswith('Width') else 101
                for value in (None, True, str(expected), float(expected), expected - 1, expected + 1):
                    self.reject(component, field, value)
            for field in ('inputRGBASHA256', 'referenceRGBASHA256', 'candidateRGBASHA256',
                          'referenceStoredPixelsSHA256', 'candidateStoredPixelsSHA256'):
                for value in (None, True, 1, '', 'a' * 63, 'a' * 65, 'A' * 64, 'g' * 64):
                    self.reject(component, field, value)
            for field in ('referenceRGBASHA256', 'candidateRGBASHA256',
                          'referenceStoredPixelsSHA256', 'candidateStoredPixelsSHA256'):
                self.reject(component, field, 'f' * 64, error='exact pixels or effective output')
            records = copy.deepcopy(self.arms['reference']['report']['positiveControl']['records'])
            records[index]['referenceRGBASHA256'] = records[index]['candidateRGBASHA256'] = records[index]['inputRGBASHA256']
            self.reject('report.positiveControl', 'records', records, error='exact pixels or effective output')
        self.reject('report.positiveControl.records.1', 'inputRGBASHA256', 'f' * 64,
                    error='synthetic inputs differ')

    def test_positive_control_metadata_is_typed_closed_and_exactly_equal(self):
        record = self.arms['reference']['report']['positiveControl']['records'][0]
        optional = {'colorSpaceName', 'colorSpaceICCSHA256'}
        for side in ('referenceMetadata', 'candidateMetadata'):
            component = 'report.positiveControl.records.0.' + side
            for field in set(record[side]) - optional:
                with self.subTest(side=side, missing=field):
                    self.reject(component, field)
            self.reject(component, 'untypedMetadata', '129x101')
            for field in ('width', 'height', 'bitsPerComponent', 'bitsPerPixel', 'bytesPerRow',
                          'bitmapInfo', 'alphaInfo', 'renderingIntent', 'colorSpaceModel'):
                for value in (None, True, False, str(record[side][field]), float(record[side][field]), -1, 1 << 63):
                    self.reject(component, field, value)
            for field, value in dict(width=128, height=100, bitsPerComponent=16, bitsPerPixel=64,
                    bytesPerRow=515, bitmapInfo=16641, alphaInfo=5, renderingIntent=5, colorSpaceModel=0,
                    hasDecodeArray=True, isMask=True, colorSpaceName='', colorSpaceICCSHA256='A' * 64).items():
                self.reject(component, field, value)
            for value in (0, 1, None, 'false'):
                self.reject(component, 'shouldInterpolate', value)
            # Each value is valid individually; the metadata still must match.
            self.reject(component, 'shouldInterpolate', True, error='exact metadata differs')
            self.reject(component, 'renderingIntent', 2, error='exact metadata differs')
            self.reject(component, 'bytesPerRow', 520, error='exact metadata differs')
        arm = copy.deepcopy(self.arms['reference'])
        for record in arm['report']['positiveControl']['records']:
            for side in ('referenceMetadata', 'candidateMetadata'):
                for field in optional:
                    record[side].pop(field)
        self.save(arm)
        self.check()

    def test_guard_pair_requires_corresponding_positive_control_bytes_and_metadata_across_policies(self):
        arm = copy.deepcopy(self.arms['memory32'])
        record = arm['report']['positiveControl']['records'][0]
        record['referenceRGBASHA256'] = record['candidateRGBASHA256'] = 'e' * 64
        self.save(arm)
        self.check('memory32')
        with self.assertRaisesRegex(ValueError, 'corresponding policy pixels/metadata differ'):
            CHECK.compare_guards(self.root, self.app, self.source)
        for optimized in (False, True):
            process = self.cli(optimized, pair=True)
            self.assertNotEqual(process.returncode, 0)
            self.assertEqual(process.stdout, '')
        arm = copy.deepcopy(self.arms['memory32'])
        for side in ('referenceMetadata', 'candidateMetadata'):
            arm['report']['positiveControl']['records'][0][side]['shouldInterpolate'] = True
        self.save(arm)
        self.check('memory32')
        with self.assertRaisesRegex(ValueError, 'corresponding policy pixels/metadata differ'):
            CHECK.compare_guards(self.root, self.app, self.source)

    def test_native_renderer_has_no_owned_storage_and_covers_successes_and_injected_failures(self):
        original = self.arms['reference']
        for field in CHECK.R.OWNERSHIP | {'eligibleCount'}:
            with self.subTest(field=field):
                self.assertEqual(original['report']['rendererStorage'][field], 0)
                self.reject('report.rendererStorage', field, 1)
        for field in CHECK.R.COUNTERS:
            for value in (None, True, False, '0', 0.0, -1, 1 << 63):
                with self.subTest(field=field, value=value):
                    self.reject('report.rendererStorage', field, value)
        for value in (None, [], {'colorSpace': 1}, {'unknown': 1}):
            self.reject('report.rendererStorage', 'unsupportedCounts', value)
        self.reject('report.rendererStorage', 'callbackSizesMatch', False)
        for successes, failures in ((0, 0), (47, 480), (108, 479)):
            renderer = RENDERER.state('native', successes)
            renderer.update(attemptCount=successes + failures, nativeCount=successes + failures,
                            seedCount=successes + failures, failureCount=failures)
            self.reject('report', 'rendererStorage', renderer, error='failures or successes omitted')
        self.reject('report.rendererStorage', 'attemptCount', 589)
        self.reject('report.rendererStorage', 'nativeCount', 587)

    def test_identity_and_executable_bytes_are_bound(self):
        mutations = dict(sourceCommit='b' * 40, version='other', buildVersion='999', bundlePath='/other/PicShot.app',
            executablePath='/other/PicShot', processIdentifier=777, nativeReportPath=str(self.root / 'other.json'),
            executableBytes=1, executableSHA256='b' * 64)
        for key, value in mutations.items():
            for invalid in (value, None, True, [], 0):
                with self.subTest(key=key, value=invalid):
                    self.reject('report', key, invalid)
        for key in ('processIdentifier', 'executableBytes'):
            self.reject('report', key, float(self.arms['reference']['report'][key]))
        original = self.executable.read_bytes()
        self.executable.write_bytes(original[:-1] + b'!')
        with self.assertRaisesRegex(ValueError, 'executable SHA differs'):
            self.check()
        self.executable.write_bytes(b'not a Mach-O executable')
        with self.assertRaisesRegex(ValueError, 'thin 64-bit Mach-O'):
            self.check()
        self.executable.write_bytes(original[:4] + struct.pack('<I', 0) + original[8:])
        with self.assertRaisesRegex(ValueError, 'unsupported executable architecture'):
            self.check()

    def test_exact_native_and_drawing_bytes_are_bound_after_semantic_json_changes(self):
        arm = self.arms['reference']
        native_path = arm['directory'] / 'effect-output-failure.json'
        drawing_path = arm['directory'] / 'drawing-raster-output-guard.json'
        native_path.write_bytes(native_path.read_bytes() + b' ')
        with self.assertRaises(ValueError):
            self.check()
        drawing = copy.deepcopy(arm['drawing'])
        drawing.update(nativeReportBytes=native_path.stat().st_size,
                       nativeReportSHA256=hashlib.sha256(native_path.read_bytes()).hexdigest())
        drawing_path.write_text(json.dumps(drawing))
        with self.assertRaisesRegex(ValueError, 'native byte count|native byte binding'):
            self.check()
        self.save(arm)
        drawing_path.write_bytes(drawing_path.read_bytes() + b' ')
        with self.assertRaisesRegex(ValueError, 'drawing byte binding'):
            self.check()
        self.save(arm)
        path = arm['directory'] / CHECK.FILENAME
        report = copy.deepcopy(arm['report'])
        for key, value in (('nativeReportSHA256', '0' * 64), ('drawingReportSHA256', '0' * 64),
                           ('nativeReportBytes', report['nativeReportBytes'] + 1)):
            report = copy.deepcopy(arm['report']); report[key] = value
            path.write_text(json.dumps(report))
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'byte binding|byte count'):
                self.check()

    def test_original_refusal_draft_prior_file_and_retry_assertions_remain_mandatory(self):
        mutations = [('failedRenderRequests', 17), ('sinkDeliveriesDuringFailures', 1), ('errorCallbacks', 17),
            ('wrongErrorCallbacks', 1), ('closeCallbacksDuringFailures', 1), ('draftPreserved', False),
            ('undoRedoPreserved', False), ('existingRedoBranchPreserved', False), ('editableDocumentPreserved', False),
            ('priorOutputPreserved', False), ('priorEditableDocumentPreserved', False), ('priorOutputSHA256', ''),
            ('priorEditableDocumentSHA256', ''), ('priorOutputBytes', 0), ('priorEditableDocumentBytes', 0),
            ('sourcePixelsUnchanged', False), ('originalPixelsUnchanged', False), ('basePixelsUnchanged', False),
            ('presentationCacheCleared', False), ('failureNeverCached', False), ('retryMatchesExpectedProjection', False),
            ('retryPreservesEditableDocument', False), ('projectionJobsStartedDuringFailures', 1),
            ('rejectedRoutes', DRAWING.NATIVE_TESTS.ROUTES[:-1]),
            ('rejectedNativeSelectors', DRAWING.NATIVE_TESTS.SELECTORS[:-1])]
        for index in (0, 23):
            for key, value in mutations:
                arm = copy.deepcopy(self.arms['reference'])
                arm['native']['cases'][index][key] = value
                self.save(arm)
                with self.subTest(case=index, key=key), self.assertRaises(ValueError):
                    self.check()
        for key, value in (('caseCount', 8), ('controllerReleaseCount', 23), ('projectionJobsStarted', 13),
                           ('generalPasteboardReadOrWritten', True), ('temporaryDirectoryRemoved', False)):
            self.reject('native', key, value)

    def test_original_drawing_guard_still_rejects_retained_or_unseeded_work(self):
        for key, value in (('activeBytes', 4), ('seededContextCount', 0), ('referenceCount', 1),
                           ('releaseCallbacks', 1), ('callbackSizesMatch', False)):
            self.reject('drawing.tracker', key, value)

    def test_launcher_requires_exact_standalone_selection_and_owned_lifecycle(self):
        mutations = dict(schemaVersion=2, status='timed-out', launcherExitCode=1, processIdentifier=999,
            createsNewApplicationInstance=False, callbackReceived=False, ownedExitConfirmed=False,
            processStartMemoryCaptured=True, effectContextPolicy='memory32', comparisonKind='renderer-final-storage',
            drawingStrategy='reference', rendererStorageStrategy='owned-srgb8', rendererAutoreleaseScope='draw-only',
            selectedAppPath='/other/PicShot.app', launchedAppPath='/other/PicShot.app', launchedExecutablePath='/other/PicShot',
            timeoutSeconds=601, elapsedSeconds=0, finishUptimeSeconds=1138, launchBeganUptimeSeconds=1141, scope='')
        for key, value in mutations.items():
            with self.subTest(key=key):
                self.reject('launcher', key, value)
        for key in ('schemaVersion', 'launcherExitCode', 'processIdentifier', 'timeoutSeconds'):
            self.reject('launcher', key, float(self.arms['reference']['launcher'][key]))
        for key in ('elapsedSeconds', 'launchBeganUptimeSeconds', 'finishUptimeSeconds'):
            for value in (True, '140', -1, float('inf'), float('nan')):
                self.reject('launcher', key, value)

    def test_bounded_wrapper_deadlines_command_log_and_cleanup_are_exact(self):
        mutations = dict(schema_version=2, status='timed-out', child_returncode=1, exit_code=1, max_log_bytes=1,
            cancel_signal='SIGINT', sigterm_sent=True, sigkill_sent=True, descendant_cleanup=True,
            timeout_seconds=619, grace_seconds=6, pid=0, output_bytes=15, log_bytes=15, log_truncated=True,
            termination_reason='timeout', duration_seconds=139, started_at='2026-10-08T00:00:00')
        for key, value in mutations.items():
            with self.subTest(key=key):
                self.reject('wrapper', key, value)
        original = self.arms['reference']['wrapper']['command']
        commands = [original[:-1], original + ['unexpected'], ['swift', 'scripts/launch-smoke-app.swift', *original[2:]],
                    [*original[:-1], 'memory32'], [*original[:3], str(self.root / 'other.json'), 'reference']]
        for command in commands:
            self.reject('wrapper', 'command', command)
        for key, value in (('backend', 'linux-proc'), ('failures', 1), ('atomic_snapshot', True),
                           ('timeout_seconds', 1), ('count', 0), ('total_seconds', 142), ('max_seconds', 0)):
            self.reject('wrapper.group_observation', key, value)
        self.reject('wrapper', 'started_at', '2026-10-08T00:00:00+01:00')
        path = self.arms['reference']['directory'] / 'launcher.log'
        path.write_bytes(b'wrong-size')
        with self.assertRaisesRegex(ValueError, 'log missing/linked/size differs'):
            self.check()

    def test_evidence_inputs_are_bounded_regular_nonlinked_files(self):
        directory = self.arms['reference']['directory']
        for filename, maximum in ((CHECK.FILENAME, 16 * 1024), ('drawing-raster-output-guard.json', 16 * 1024),
                ('effect-output-failure.json', 128 * 1024), ('launch.json.launcher.json', 16 * 1024),
                ('bounded-launch.json', 2 * 1024 * 1024)):
            path = directory / filename
            original = path.read_bytes()
            try:
                for payload in (b'', b' ' * (maximum + 1)):
                    path.write_bytes(payload)
                    with self.subTest(file=filename, bytes=len(payload)), self.assertRaises((ValueError, OSError)):
                        self.check()
                path.write_bytes(original)
                alias = directory / 'extra-hardlink'
                os.link(path, alias)
                try:
                    with self.subTest(file=filename, link='hard'), self.assertRaises(ValueError):
                        self.check()
                finally:
                    alias.unlink()
                path.rename(alias)
                path.symlink_to(alias)
                try:
                    with self.subTest(file=filename, link='symbolic'), self.assertRaises(ValueError):
                        self.check()
                finally:
                    path.unlink(); alias.rename(path)
            finally:
                path.write_bytes(original)
        for filename in ('launcher.log',):
            path = directory / filename
            alias = directory / 'extra-link'
            os.link(path, alias)
            with self.assertRaisesRegex(ValueError, 'log missing/linked/size differs'):
                self.check()
            alias.unlink()
            path.rename(alias); path.symlink_to(alias)
            with self.assertRaisesRegex(ValueError, 'log missing/linked/size differs'):
                self.check()
            path.unlink(); alias.rename(path)

    def test_installed_executable_preserves_strict_single_link_reader(self):
        alias = self.root / 'linked-executable'
        os.link(self.executable, alias)
        try:
            with self.assertRaisesRegex(ValueError, 'linked, nonregular or oversized file'):
                self.check()
        finally:
            alias.unlink()
        self.executable.rename(alias)
        self.executable.symlink_to(alias)
        try:
            with self.assertRaises(ValueError):
                self.check()
        finally:
            self.executable.unlink()
            alias.rename(self.executable)
        self.check()

    def test_linked_evidence_directories_are_not_accepted(self):
        alias = self.root / 'linked-evidence'
        alias.symlink_to(self.arms['reference']['directory'], target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'directory linked/missing'):
            CHECK.check_directory(alias, self.app, self.source, 'reference')
        alias.unlink(); alias.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'root linked/missing'):
            CHECK.compare_guards(alias, self.app, self.source)

    def test_malformed_duplicate_nonfinite_and_nonobject_json_fail_closed(self):
        directory = self.arms['reference']['directory']
        for filename in (CHECK.FILENAME, 'effect-output-failure.json', 'drawing-raster-output-guard.json',
                         'launch.json.launcher.json', 'bounded-launch.json'):
            path = directory / filename
            original = path.read_bytes()
            for payload in (b'{', b'{}{}', b'[]', b'null', b'false', b'1', b'"observed"', b'\xff',
                            b'{"x":1,"x":2}', b'{"x":NaN}', b'{"x":Infinity}', b'{"x":1e999}'):
                path.write_bytes(payload)
                with self.subTest(file=filename, payload=payload), self.assertRaises((ValueError, OSError)):
                    self.check()
            path.write_bytes(original)

    def test_cli_failures_remain_fail_closed_with_optimized_python(self):
        path = self.arms['reference']['directory'] / CHECK.FILENAME
        original = path.read_bytes()
        bad = copy.deepcopy(self.arms['reference']['report'])
        bad['effectContext']['failureCount'] = 1
        for payload in (json.dumps(bad).encode(), b'{}', b'{"x":NaN}', b'{"x":1e999}', b'{"x":1,"x":2}',
                        b' ' * (16 * 1024 + 1)):
            path.write_bytes(payload)
            for optimized in (False, True):
                with self.subTest(optimized=optimized, payload=payload[:60]):
                    process = self.cli(optimized)
                    self.assertNotEqual(process.returncode, 0)
                    self.assertEqual(process.stdout, '')
        path.write_bytes(original)


if __name__ == '__main__':
    unittest.main()
