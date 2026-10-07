"""Schema-only synthetic reports. Never use these fixtures as native evidence."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    'image_decode_large_check', Path(__file__).resolve().parents[1] / 'check-image-decode-large-report.py')
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)
RAW_BYTES = 2_359_296
SOURCE = 'c' * 40
ARCHITECTURE = 'arm64'


def memory():
    return {
        'standard': {'kernelReturn': 0, 'bytes': {'resident_size': 1_000, 'phys_footprint': 500}},
        'purgeable': {'kernelReturn': 0, 'bytes': {
            'purgeable_volatile_resident': 0, 'purgeable_volatile_virtual': 0, 'purgeable_volatile_pmap': 0}},
    }


def peaks():
    return {'residentBytes': 1_000, 'footprintBytes': 500, 'residentSamples': 2, 'footprintSamples': 2}


def lifetime(allocations=1):
    return {'allocations': allocations, 'deallocations': allocations, 'releaseCallbacks': allocations,
            'activeBytes': 0, 'peakActiveBytes': RAW_BYTES, 'callbackSizesMatch': True}


class LargeReportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='picshot-large-schema-only-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.prepared = {}
        self.reports = {}
        self.next_child_pid = 1_000
        raw = bytes(RAW_BYTES)
        for index, (profile, width, height) in enumerate([('4k', 3840, 2160), ('5k', 5120, 2880)]):
            directory = self.root / f'prepared-{profile}'
            directory.mkdir()
            # Deliberately not a decodable PNG: the Python checker verifies
            # file sizes/hashes, while native XCTest owns pixel-decoder proof.
            png = b'\x89PNG\r\n\x1a\nSCHEMA-ONLY-' + profile.encode('ascii')
            (directory / 'input.png').write_bytes(png)
            (directory / 'reference.rgba').write_bytes(raw)
            prepared = dict(protocol='image-decode-large-input-v2', status='prepared', profile=profile,
                            sourceCommit=SOURCE, architecture=ARCHITECTURE, processIdentifier=10 + index,
                            sourceWidth=width, sourceHeight=height, previewWidth=1024, previewHeight=576,
                            rawBytes=RAW_BYTES, pngBytes=len(png), pngSHA256=hashlib.sha256(png).hexdigest(),
                            rawSHA256=hashlib.sha256(raw).hexdigest(), syntheticSource=True,
                            screenCaptureAttempted=False)
            self.prepared[profile] = prepared
            self.write(f'prepared-{profile}/image-decode-large-inputs.json', prepared)
            for mode_index, mode in enumerate(['production-control', 'isolated-decode']):
                report = self.headless(profile, mode, 20 + index * 2 + mode_index)
                self.reports[f'{profile}-{mode}'] = report
                self.save_report(f'{profile}-{mode}', report)
        for index, mode in enumerate(['native-ui-control', 'native-ui-isolated']):
            report = self.ui(mode, 30 + index)
            self.reports[f'5k-{mode}'] = report
            self.save_report(f'5k-{mode}', report)

    def base(self, profile, mode, pid):
        prepared = self.prepared[profile]
        return dict(protocol='image-decode-large-parent-v2', status='observed', mode=mode, profile=profile,
                    sourceCommit=SOURCE, architecture=ARCHITECTURE, processIdentifier=pid,
                    inputPreparationProcessIdentifier=prepared['processIdentifier'],
                    sourceWidth=prepared['sourceWidth'], sourceHeight=prepared['sourceHeight'],
                    previewWidth=1024, previewHeight=576, rasterBytes=RAW_BYTES, maximumPreviewBytes=4_194_304,
                    maximumPreviewDimension=1024, maximumEncodedBytes=8_388_608, pixelTolerance=0,
                    pngSHA256=prepared['pngSHA256'], rawSHA256=prepared['rawSHA256'],
                    parentLossVerified=False, screenCaptureAttempted=False, networkAttempted=False,
                    preferencesWritten=False, allocatorReliefCalls=0, ownedJobsRemaining=0,
                    parentPeaks=peaks(), destinationLifetime=lifetime(), maximumObservedChildConcurrency=0)

    def process(self, profile, outcome='decoded', launched=True):
        pid = self.next_child_pid
        self.next_child_pid += 1
        reference_sha = self.prepared[profile]['rawSHA256']
        held = outcome == 'cancelled-after-decode'
        terminal = dict(schema='image-decode-helper-v2', profile=profile, childPID=pid,
                        kind='result' if outcome == 'decoded' else 'error',
                        phase='complete' if outcome == 'decoded' else 'failed', uptimeSeconds=103.0,
                        helperEntryUptimeSeconds=100.0, responsePreparedUptimeSeconds=103.0,
                        pngReadAndHashSeconds=0.01, imageCreationSeconds=0.1, drawSeconds=0.01,
                        writeSeconds=0.01, childWorkSeconds=3.0, peaks=peaks(), memory=memory())
        if outcome == 'decoded':
            terminal.update(rawBytes=RAW_BYTES, rawSHA256=reference_sha)
        else:
            terminal['error'] = 'cancelled'
        names = ['beforePNGRead', 'imageCreated', 'rasterDrawn', 'afterContextRelease']
        names += ['heldAfterDecode'] if held else ['outputClosed', 'afterDecodePool']
        phases = []
        for offset, name in enumerate(names):
            event = dict(schema='image-decode-helper-v2', profile=profile, childPID=pid,
                         kind='ready' if name == 'heldAfterDecode' else 'phase', phase=name,
                         uptimeSeconds=100.1 + offset * 0.1, memory=memory())
            if name == 'heldAfterDecode':
                event.update(rawBytes=RAW_BYTES, rawSHA256=reference_sha)
            phases.append(dict(child=event, parentAtReceipt=memory(), childObservedRunning=True, receiptSkewSeconds=0.001))
        phases.append(dict(child=copy.deepcopy(terminal), parentAtReceipt=memory(), childObservedRunning=False, receiptSkewSeconds=0.001))
        boundaries = ['signatureStarted', 'signatureFinished', 'stagingFinished', 'processRunStarted',
                      'processRunReturned', 'childExitConfirmed', 'cleanupFinished']
        if outcome == 'decoded':
            boundaries.insert(-1, 'rawReadFinished')
        if held:
            boundaries.insert(-2, 'heldAfterDecode')
            boundaries.insert(-2, 'cancelCommandSent')
        signature = []
        for index, name in enumerate(['pathAndIdentity', 'appCodeObject', 'appValidity', 'helperCodeObject', 'helperValidity']):
            phase = dict(phase=name, startedUptimeSeconds=99 + index * 0.01, elapsedSeconds=0.01)
            if index:
                phase['securityStatus'] = 0
            signature.append(phase)
        result = dict(diagnosticProfile=profile, outcome=outcome, childLaunched=launched, exitConfirmed=launched,
                      cleanupConfirmed=True, admissionReleased=True, stdoutBytes=1_024 if launched else 0,
                      stderrBytes=0, stderrTruncated=False, childPID=pid,
                      jobDirectory=str(self.root / f'absent-job-{pid}'), terminationReason='exit',
                      terminationStatus=0 if outcome == 'decoded' else 1, launchThroughExitSeconds=3.1,
                      terminal=terminal, phases=phases, signaturePhases=signature,
                      parentBoundaries={name: memory() for name in boundaries},
                      boundaryUptimes={name: 99 + index * 0.7 for index, name in enumerate(boundaries)},
                      sawPostDecodeReady=held, outputExistedBeforeCleanup=outcome == 'decoded',
                      cancelRequested=outcome != 'decoded', cancelWriteReturn=7)
        if not launched:
            for name in ['childPID', 'jobDirectory', 'terminationReason', 'terminationStatus', 'terminal']:
                result.pop(name)
            result.update(phases=[], boundaryUptimes={}, parentBoundaries={})
        return result

    def headless(self, profile, mode, pid):
        isolated = mode == 'isolated-decode'
        report = self.base(profile, mode, pid)
        report.update(warmupCycles=2, measuredCycles=12, warmups=[], cycles=[], completedDraws=14,
                      completedExactPixelChecks=14, armDeadlineSeconds=180, requiredOuterDeadlineSeconds=200,
                      elapsedSeconds=50, baselineAfterWarmup=memory(), helperInvocations=14 if isolated else 0,
                      maximumObservedChildConcurrency=1 if isolated else 0)
        if isolated:
            report['providerLifetime'] = lifetime(14)
        for ordinal in range(14):
            warm = ordinal < 2
            cycle = dict(index=ordinal + 1 if warm else ordinal - 1, isWarmup=warm,
                         before=memory(), beforeImageCreation=memory(), afterPool=memory(), settled=memory(),
                         timeToValidatedPixelsSeconds=3.2, fullLifecycleSeconds=3.3, observedCycleSeconds=3.5,
                         parentPeaks=peaks(), draw=dict(beforeDraw=memory(), afterDraw=memory(),
                         maximumDifference=0, validatedBytes=RAW_BYTES, pixelsSHA256=self.prepared[profile]['rawSHA256'],
                         imageCreationSeconds=0.01, drawSeconds=0.01, validationSeconds=0.01, validatedUptimeSeconds=104.0))
            if isolated:
                cycle['process'] = self.process(profile)
                cycle['providerLifetime'] = lifetime(ordinal + 1)
            report['warmups' if warm else 'cycles'].append(cycle)
        return report

    def ui(self, mode, pid):
        isolated = mode == 'native-ui-isolated'
        report = self.base('5k', mode, pid)
        report.update(warmupCycles=2, measuredCycles=4, warmups=[], cycles=[], workers=[], faultScenarios=[],
                      completedSuccessfulNativeDraws=6, exactSuccessfulPreviewValidations=6, actualNativeDrawCount=8,
                      armDeadlineSeconds=120, requiredOuterDeadlineSeconds=140, elapsedSeconds=50,
                      controllersReleased=True, activeExportControllers=0, allRequestedCancellationRacesObserved=True,
                      debounceBurst=dict(startedWorkers=1, latestResultDrawn=True),
                      mainQueue=dict(samples=100, outstandingCallbacks=0, maximumDelaySeconds=0.02,
                                     histogramTenMillisecondBins=[100] + [0] * 63),
                      responsivenessFlagTriggered=False, backingScaleFactor=2.0, highDPIBackingObserved=True,
                      maximumObservedChildConcurrency=1 if isolated else 0)
        for ordinal in range(6):
            worker = self.worker(ordinal + 1, 'normal', isolated)
            report['workers'].append(worker)
            draw = dict(uptimeSeconds=104.0, imageIdentity=f'schema-only-image-{ordinal}', backingScale=2.0,
                        windowVisible=True, displayedRect=[0.0, 0.0, 584.0, 328.5])
            cycle = dict(index=ordinal + 1 if ordinal < 2 else ordinal - 1, isWarmup=ordinal < 2,
                         workerIndex=worker['index'], exactPreviewPixels=True, rawSHA256=self.prepared['5k']['rawSHA256'],
                         nativeDraw=draw, requestToNativeDrawSeconds=3.5, before=memory(), settled=memory())
            report['warmups' if ordinal < 2 else 'cycles'].append(cycle)
        report['workers'].append(self.worker(7, 'burst', isolated))
        for index, scenario in enumerate(['cancelActive', 'closeDecoded', 'lateResult'], 8):
            report['workers'].append(self.worker(index, scenario, isolated))
            report['faultScenarios'].append(dict(scenario=scenario, workerIndex=index, staleResultSuppressed=True,
                                                 windowClosed=True, cancellationRaceExercised=True,
                                                 cancellationHandledToWorkerFinishedSeconds=0.02))
        report['helperInvocations'] = sum(w.get('process', {}).get('childLaunched', False) for w in report['workers'])
        if isolated:
            report['providerLifetime'] = lifetime(8)
        return report

    def worker(self, index, scenario, isolated):
        outcome = 'cancelled' if isolated and scenario in ('cancelActive', 'closeDecoded') else (
            'completed-after-cancel' if scenario in ('cancelActive', 'closeDecoded', 'lateResult') else 'completed')
        result = dict(index=index, scenario=scenario, requestUptimeSeconds=99.0, startedUptimeSeconds=99.2,
                      finishedUptimeSeconds=103.5, outcome=outcome)
        if outcome.startswith('completed'):
            result.update(pixelsSHA256=self.prepared['5k']['rawSHA256'], imageIdentity=f'schema-only-cgimage-{index}')
        if isolated:
            child_outcome = 'cancelled' if scenario == 'cancelActive' else ('cancelled-after-decode' if scenario == 'closeDecoded' else 'decoded')
            result['process'] = self.process('5k', child_outcome, launched=scenario != 'cancelActive')
        return result

    def write(self, path, data):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(data))

    def save_report(self, cell, report):
        self.write(f'{cell}/image-decode-large-{report["mode"]}.json', report)

    def run_check(self, headless_only=False):
        return CHECK.validate(self.root, SOURCE, ARCHITECTURE, headless_only)

    def assert_report_rejected(self, mutate, cell='4k-isolated-decode', headless_only=True):
        original = self.reports[cell]
        changed = copy.deepcopy(original)
        mutate(changed)
        # A wrong mode must overwrite the original report path, too.
        path = f'{cell}/image-decode-large-{original["mode"]}.json'
        self.write(path, changed)
        try:
            with self.assertRaises((AssertionError, KeyError, StopIteration)):
                self.run_check(headless_only)
        finally:
            self.write(path, original)

    def test_complete_four_headless_cells_without_ui_reports(self):
        for mode in ['native-ui-control', 'native-ui-isolated']:
            shutil.rmtree(self.root / f'5k-{mode}')
        result = self.run_check(True)
        self.assertEqual(result['status'], 'observed')
        self.assertTrue(result['headlessOnly'])
        self.assertEqual(len(result['cells']), 4)
        self.assertFalse(result['parentLossVerified'])

    def test_complete_six_cells_with_native_ui_schema(self):
        result = self.run_check()
        self.assertEqual(len(result['cells']), 6)
        self.assertFalse(result['headlessOnly'])
        self.assertTrue(result['cells'][-1]['allRequestedCancellationRacesObserved'])

    def test_missing_raw_memory_component_is_rejected(self):
        for key in ['standard', 'purgeable']:
            with self.subTest(key=key):
                self.assert_report_rejected(lambda r: r['cycles'][0]['settled'].pop(key))

    def test_failed_memory_call_and_missing_purgeable_bytes_are_rejected(self):
        self.assert_report_rejected(lambda r: r['cycles'][0]['before']['standard'].update(kernelReturn=5))
        self.assert_report_rejected(lambda r: r['cycles'][0]['before']['purgeable']['bytes'].pop('purgeable_volatile_resident'))

    def test_missing_pixel_validation_and_mismatched_pixels_are_rejected(self):
        self.assert_report_rejected(lambda r: r['cycles'][0]['draw'].pop('validatedBytes'))
        for changes in [dict(validatedBytes=1_769_472), dict(maximumDifference=1), dict(pixelsSHA256='a' * 64)]:
            with self.subTest(changes=changes):
                self.assert_report_rejected(lambda r: r['cycles'][0]['draw'].update(changes))

    def test_missing_exit_or_failed_cleanup_is_rejected(self):
        for key in ['exitConfirmed', 'cleanupConfirmed', 'admissionReleased']:
            with self.subTest(key=key):
                self.assert_report_rejected(lambda r: r['cycles'][0]['process'].update({key: False}))
        self.assert_report_rejected(lambda r: r['cycles'][0]['process'].pop('exitConfirmed'))

    def test_abnormal_exit_and_stale_job_are_rejected(self):
        self.assert_report_rejected(lambda r: r['cycles'][0]['process'].update(terminationReason='uncaughtSignal'))
        self.assert_report_rejected(lambda r: r['cycles'][0]['process'].update(terminationStatus=1))
        process = self.reports['4k-isolated-decode']['cycles'][0]['process']
        Path(process['jobDirectory']).mkdir()
        with self.assertRaises(AssertionError):
            self.run_check(True)

    def test_missing_signature_checks_and_failed_security_status_are_rejected(self):
        self.assert_report_rejected(lambda r: r['cycles'][0]['process'].pop('signaturePhases'))
        self.assert_report_rejected(lambda r: r['cycles'][0]['process']['signaturePhases'].pop())
        self.assert_report_rejected(lambda r: r['cycles'][0]['process']['signaturePhases'][2].update(securityStatus=-67050))

    def test_signature_order_and_nonfinite_duration_are_rejected(self):
        self.assert_report_rejected(lambda r: r['cycles'][0]['process']['signaturePhases'].reverse())
        for seconds in [-1, float('inf'), float('nan')]:
            with self.subTest(seconds=seconds):
                self.assert_report_rejected(lambda r: r['cycles'][0]['process']['signaturePhases'][0].update(elapsedSeconds=seconds))

    def test_wrong_source_architecture_profile_and_producer_are_rejected(self):
        for key, value in [('sourceCommit', 'd' * 40), ('architecture', 'x86_64'), ('profile', '5k'),
                           ('inputPreparationProcessIdentifier', 999), ('mode', 'production-control')]:
            with self.subTest(key=key):
                self.assert_report_rejected(lambda r: r.update({key: value}))

    def test_wrong_source_and_preview_bounds_are_rejected(self):
        for key, value in [('sourceWidth', 3841), ('sourceHeight', 2161), ('previewWidth', 768),
                           ('previewHeight', 577), ('rasterBytes', 1_769_472), ('maximumPreviewBytes', 8_388_608),
                           ('maximumPreviewDimension', 2048), ('pixelTolerance', 1)]:
            with self.subTest(key=key):
                self.assert_report_rejected(lambda r: r.update({key: value}))

    def test_wrong_child_schema_profile_and_raw_bounds_are_rejected(self):
        for key, value in [('schema', 'image-decode-helper-v1'), ('profile', '5k'),
                           ('rawBytes', 1_769_472), ('rawSHA256', 'f' * 64)]:
            with self.subTest(key=key):
                self.assert_report_rejected(lambda r: r['cycles'][0]['process']['terminal'].update({key: value}))

    def test_child_pid_reuse_is_rejected(self):
        old = self.reports['4k-isolated-decode']['warmups'][0]['process']['childPID']
        self.assert_report_rejected(lambda r: r['cycles'][0]['process'].update(childPID=old))

    def test_memory_stream_and_wall_bounds_are_rejected(self):
        for key, value in [('stdoutBytes', 131073), ('stderrBytes', 8193), ('stderrTruncated', True),
                           ('launchThroughExitSeconds', 9)]:
            with self.subTest(key=key):
                self.assert_report_rejected(lambda r: r['cycles'][0]['process'].update({key: value}))
        self.assert_report_rejected(lambda r: r['parentPeaks'].update(residentBytes=536870913))
        self.assert_report_rejected(lambda r: r['cycles'][0]['process']['terminal']['peaks'].update(footprintBytes=268435457))

    def test_prepared_file_tampering_and_wrong_raw_size_are_rejected(self):
        png = self.root / 'prepared-4k/input.png'
        original = png.read_bytes()
        png.write_bytes(original[:-1] + b'!')
        with self.assertRaises(AssertionError):
            self.run_check(True)
        png.write_bytes(original)
        (self.root / 'prepared-4k/reference.rgba').write_bytes(b'not-a-raster')
        with self.assertRaises(AssertionError):
            self.run_check(True)

    def test_wrong_prepared_profile_source_and_bounds_are_rejected(self):
        original = self.prepared['4k']
        for key, value in [('profile', '5k'), ('sourceCommit', 'd' * 40), ('sourceWidth', 5120),
                           ('rawBytes', 1_769_472), ('pngBytes', 8_388_609)]:
            with self.subTest(key=key):
                changed = copy.deepcopy(original)
                changed[key] = value
                self.write('prepared-4k/image-decode-large-inputs.json', changed)
                with self.assertRaises(AssertionError):
                    self.run_check(True)
        self.write('prepared-4k/image-decode-large-inputs.json', original)

    def test_stale_ui_suppression_window_and_release_flags_are_rejected(self):
        cell = '5k-native-ui-isolated'
        for key in ['staleResultSuppressed', 'windowClosed']:
            with self.subTest(key=key):
                self.assert_report_rejected(lambda r: r['faultScenarios'][2].update({key: False}), cell, False)
        self.assert_report_rejected(lambda r: r.update(controllersReleased=False), cell, False)
        self.assert_report_rejected(lambda r: r.update(activeExportControllers=1), cell, False)

    def test_stale_ui_draw_pixel_and_debounce_flags_are_rejected(self):
        cell = '5k-native-ui-control'
        self.assert_report_rejected(lambda r: r['cycles'][0].update(exactPreviewPixels=False), cell, False)
        self.assert_report_rejected(lambda r: r['cycles'][0]['nativeDraw'].update(windowVisible=False), cell, False)
        self.assert_report_rejected(lambda r: r['debounceBurst'].update(latestResultDrawn=False), cell, False)
        self.assert_report_rejected(lambda r: r['debounceBurst'].update(startedWorkers=3), cell, False)

    def test_stale_ui_responsiveness_and_retina_flags_are_rejected(self):
        cell = '5k-native-ui-control'
        self.assert_report_rejected(lambda r: r.update(responsivenessFlagTriggered=True), cell, False)
        self.assert_report_rejected(lambda r: r.update(highDPIBackingObserved=False), cell, False)

    def test_ui_worker_pixel_and_finished_time_mismatch_are_rejected(self):
        cell = '5k-native-ui-isolated'
        self.assert_report_rejected(lambda r: r['workers'][0].update(pixelsSHA256='f' * 64), cell, False)
        self.assert_report_rejected(lambda r: r['workers'][0].update(finishedUptimeSeconds=0), cell, False)

    def test_ui_held_child_wrong_reference_or_output_is_rejected(self):
        cell = '5k-native-ui-isolated'
        self.assert_report_rejected(lambda r: r['workers'][8]['process'].update(outputExistedBeforeCleanup=True), cell, False)
        self.assert_report_rejected(lambda r: next(p['child'] for p in r['workers'][8]['process']['phases']
                                                 if p['child']['kind'] == 'ready').update(rawSHA256='f' * 64), cell, False)

    def test_missing_phase_memory_evidence_is_rejected(self):
        self.assert_report_rejected(lambda r: r['cycles'][0]['process'].update(phases=[]))

    def test_missing_parent_boundary_memory_evidence_is_rejected(self):
        self.assert_report_rejected(lambda r: r['cycles'][0]['process'].update(parentBoundaries={}))

    def test_missing_ui_workers_is_rejected(self):
        self.assert_report_rejected(lambda r: r.update(workers=[]), '5k-native-ui-isolated', False)

    def test_ui_isolated_worker_without_process_evidence_is_rejected(self):
        self.assert_report_rejected(lambda r: r['workers'][0].pop('process'), '5k-native-ui-isolated', False)

    def test_stale_aggregate_cancellation_race_flag_is_rejected(self):
        self.assert_report_rejected(lambda r: r['faultScenarios'][0].update(cancellationRaceExercised=False),
                                    '5k-native-ui-isolated', False)

    def test_completed_signature_race_is_explicitly_unobserved(self):
        cell = '5k-native-ui-isolated'
        report = copy.deepcopy(self.reports[cell])
        report['workers'][7] = self.worker(8, 'normal', True)
        report['workers'][7]['scenario'] = 'cancelActive'
        report['faultScenarios'][0]['cancellationRaceExercised'] = False
        report['allRequestedCancellationRacesObserved'] = False
        report['helperInvocations'] += 1
        self.save_report(cell, report)
        result = self.run_check()
        self.assertFalse(result['coverage']['allCancellationRacesObserved'])

    def test_failed_fault_worker_and_undrained_probe_are_rejected(self):
        self.assert_report_rejected(lambda r: r['workers'][7].update(outcome='failed'), '5k-native-ui-isolated', False)
        self.assert_report_rejected(lambda r: r['mainQueue'].update(outstandingCallbacks=1), '5k-native-ui-isolated', False)


if __name__ == '__main__':
    unittest.main()
