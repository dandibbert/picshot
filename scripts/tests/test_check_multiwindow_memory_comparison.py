"""Portable evidence-gate tests. All process/counter records are explicitly synthetic."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
import subprocess
import sys

CHECKER = Path(__file__).resolve().parents[1] / 'check-multiwindow-memory-comparison.py'
namespace = {'__name__': 'comparison_checker_under_test'}
exec(compile(CHECKER.read_text(), str(CHECKER), 'exec'), namespace)
SOURCE = '0' * 40
FIELDS = ('resident_size', 'phys_footprint', 'purgeable_volatile_resident', 'purgeable_volatile_virtual', 'compressed', 'ledger_purgeable_volatile_compressed')
OUTPUT_HASH = '5b8033659faae766800872f3684782128355a46fc4603aa5718e3134b2ac941d'

def counters(value):
    return {key: (0 if 'compressed' in key else value) for key in FIELDS}

def trace(candidate, tail_first):
    rows = []
    def add(phase, cycle, event, window=0, top=-1):
        n = len(rows)
        def task(purgeable):
            return dict(flavor='TASK_VM_INFO_PURGEABLE' if purgeable else 'TASK_VM_INFO',
                kernelReturn=0, requiredCountersAvailable=True, missingRequiredFields=[],
                returnedNaturalCount=93, requestedNaturalCount=93, observedAtUptimeSeconds=1 + n + (0.1 if purgeable else 0),
                pageSizeBytes=16384, regionCount=10,
                bytes=({'purgeable_volatile_resident': 10, 'purgeable_volatile_virtual': 10} if purgeable
                    else {'resident_size': 10, 'phys_footprint': 10, 'compressed': 0}),
                ledgerBytes={'ledger_purgeable_volatile_compressed': 0})
        rows.append(dict(phase=phase, cycle=cycle, event=event, windowID=window, stripTop=top,
            standard=task(False), purgeable=task(True)))
    for phase, count in ((1, 4), (2, 12)):
        for cycle in range(1, count + 1):
            add(phase, cycle, 'canvasBeforeAllocation'); add(phase, cycle, 'canvasAfterAllocation')
            for window in (202, 101):
                for event in ('decodeBefore', 'decodeImageCreated', 'decodeReturned', 'inputBeforeAppend'):
                    add(phase, cycle, event, window)
                if candidate:
                    for event in ('normalizationBefore', 'normalizationAfter', 'candidateBlendBefore', 'candidateBlendAfter'):
                        add(phase, cycle, event, window)
                else:
                    add(phase, cycle, 'appendBeforeDraws', window)
                    tops = [2048] + list(range(0, 2048, 128)) if tail_first else list(range(0, 2160, 128))
                    for top in tops:
                        add(phase, cycle, 'drawBefore', window, top); add(phase, cycle, 'drawAfter', window, top)
                    add(phase, cycle, 'appendAfterFlush', window)
                add(phase, cycle, 'inputAfterAppendScope', window)
            for event in ('finishBefore', 'finishAfterOwnershipTransfer', 'outputAfterFinishScope', 'digestBefore', 'digestAfter', 'cycleAfterRelease'):
                add(phase, cycle, event)
    for event, window in [('canvasBeforeAllocation', 0), ('canvasAfterAllocation', 0),
            ('decodeBefore', 202), ('decodeImageCreated', 202), ('decodeReturned', 202), ('cancellationAfterRelease', 0)]:
        add(3, 0, event, window)
    assert len(rows) == (422 if candidate else 1446)
    return dict(capacity=2048, allocatedBytes=2048 * 800, overflowCount=0, recordCount=len(rows), observations=rows)

def cell(number, name, mode, tail_first, traced):
    app = '/explicitly-synthetic/PicShot.app'
    pid = 1000 + number
    expected = OUTPUT_HASH
    owned = dict(inputObjectsCreated=2, decoderObjectsCreated=2, outputObjectsCreated=1,
        maximumConcurrentInputObjects=1, liveInputObjects=0, liveDecoderObjects=0, liveOutputObjects=0)
    def cycle(phase, index):
        return dict(phase=phase, index=index, rgbaSHA256=expected, exactOutputPixels=4480 * 2520,
            ownedOpenFileDescriptorsAfter=0, ownership=owned.copy(),
            ownedRasterProbe=dict(currentRasterBytes=0, peakRasterBytes=111513600,
                canvasBytes=0, normalizationBytes=0, admittedSourceBytes=0,
                normalizationCount=2 if mode == 'normalizedCandidate' else 0),
            **{key:dict(counters=counters(30+index)) for key in ('before','afterCompositionBeforeDigest','afterDigestBeforeOutputRelease','afterRelease')})
    report = dict(syntheticFixture=True, status='observed', observationsComplete=True, pid=pid,
        bundlePath=app, executablePath=app+'/Contents/MacOS/PicShot', compiledArchitecture='arm64', osVersion='explicitly synthetic macOS',
        compositionMode=mode, productionCompositionMode='coreGraphicsBaseline',
        diagnosticTailStripFirst=tail_first, diagnosticBoundariesEnabled=traced,
        diagnosticTraceAllocatedBytesBeforeEntry=2048 * 800 if traced else 0,
        warmupCycles=4, measuredCycles=12, windowsPerCycle=2, maximumConcurrentCycleTasks=1, cooperativeDeadlineSeconds=180, perCompositionDeadlineSeconds=20,
        completedWarmupCycles=4, completedMeasuredCycles=12, remainingWarmupCycles=0, remainingMeasuredCycles=0,
        sourceWidth=3840, sourceHeight=2160, outputWidth=4480, outputHeight=2520,
        normalizationRasterBytes=3840*2160*4 if mode == 'normalizedCandidate' else 0,
        warmups=[cycle('warmup', n) for n in range(1,5)], cycles=[cycle('measured', n) for n in range(1,13)],
        temporaryDirectoryRemoved=True, ownedOpenFileDescriptorsAfterCleanup=0,
        cancellation=dict(status='passed', ownership={**owned, 'inputObjectsCreated':1, 'decoderObjectsCreated':1, 'outputObjectsCreated':0}, ownedOpenFileDescriptors=0),
        memoryStabilityAssessed=False, plateauAssessed=False, zeroLeakClaim=False,
        screenCaptureStarted=False, permissionRequested=False, systemScreenshotCommandInvoked=False,
        userAssetsRead=False, globalInputPosted=False, memoryPressureOrPurgeRequested=False,
        preparedInputs=[dict(filename=n+'.png', bytes=100+i, pngSHA256=str(i+1)*64, generatedRGBA_SHA256=str(i+3)*64) for i,n in enumerate(('front','back'))],
        expectedOutputSHA256=expected, elapsedSeconds=5,
        fixtureEntryBeforeInputPreparation=dict(counters=counters(10)), afterInputPreparationPreWarmup=dict(counters=counters(20)),
        afterWarmupBaseline=dict(counters=counters(30)), finalAfterCleanup=dict(counters=counters(40)),
        lateMeasuredIncrements=[], transientSampler=dict(total=dict(sampledPeakBytes=counters(50), timerSampleCount=20, sampleCount=30, missingFieldCounts={})))
    if traced: report['diagnosticBoundaryTrace'] = trace(mode=='normalizedCandidate', tail_first)
    checked = dict(status='observed', observationsComplete=True, sourceCommit=SOURCE, compositionMode=mode,
        ownedExitConfirmed=True, memoryStabilityAssessed=False, measuredCycles=12, elapsedSeconds=5, afterWarmupToCleanupDeltaBytes=counters(10), sampledPeakBytes=counters(50))
    increments=[dict(fromMeasuredCycle=i,toMeasuredCycle=i+1,counterDeltaBytes=counters(1)) for i in range(1,12)]
    report['measuredBoundaryIncrements']=increments
    report['lateMeasuredIncrements']=increments[-4:]
    checked['lateMeasuredIncrements']=increments[-4:]
    return {'multi-window-resource.json':report, 'checked-resource.json':checked,
        'provenance.json':dict(sourceCommit=SOURCE, version='synthetic', buildVersion='synthetic', executableSHA256='b'*64, executableBytes=42, bundlePath=app),
        'launch.json':dict(sourceCommit=SOURCE, status='observed', pid=pid, bundlePath=app, arguments=[app+'/Contents/MacOS/PicShot']),
        'launch.json.launcher.json':dict(processIdentifier=pid, ownedExitConfirmed=True, createsNewApplicationInstance=True,
            status='exited', launcherExitCode=0, callbackReceived=True, selectedAppPath=app, launchedAppPath=app)}


class ComparisonCheckerTests(unittest.TestCase):
    """Synthetic schema controls, not native workload or memory-stability tests."""
    @classmethod
    def setUpClass(cls):
        cls.cells = {p[0]: cell(i, *p) for i, p in enumerate(namespace['PROFILES'])}

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='picshot-explicitly-synthetic-checker-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for profile, files in self.cells.items():
            (self.root/profile).mkdir()
            for filename, data in files.items():
                (self.root/profile/filename).write_text(json.dumps(data))
        self.write_outcomes([dict(profile=p[0], exitCode=0, status='exited', reason=None) for p in namespace['PROFILES']])

    def write_outcomes(self, rows):
        (self.root/'cell-outcomes.json').write_text(json.dumps(rows))

    def mutate(self, profile, filename, change):
        path = self.root/profile/filename
        value = json.loads(path.read_text()); change(value); path.write_text(json.dumps(value))

    def reject(self, profile, filename, change):
        self.mutate(profile, filename, change)
        with self.assertRaises((ValueError, KeyError, TypeError)):
            namespace['validate'](self.root, SOURCE)

    def test_complete_synthetic_matrix_is_observed_without_promotion(self):
        result = namespace['validate'](self.root, SOURCE)
        self.assertEqual(result['status'], 'observed')
        self.assertFalse(result['memoryStabilityAssessed'])
        self.assertFalse(result['productionPromotionApproved'])
        self.assertEqual(len(result['cells']), 6)
        self.assertEqual(result['cells'][0]['measuredDelta'], counters(10))
        self.assertEqual(result['cells'][0]['sampledPeaks'], counters(50))

    def test_trace_counts_are_1446_and_422(self):
        self.assertEqual(len(trace(False, False)['observations']), 1446)
        self.assertEqual(len(trace(False, True)['observations']), 1446)
        self.assertEqual(len(trace(True, False)['observations']), 422)

    def test_stale_zero_measured_delta_rejected(self):
        self.reject('baseline','checked-resource.json',lambda d:d['afterWarmupToCleanupDeltaBytes'].update(resident_size=0))

    def test_stale_zero_peak_rejected(self):
        self.reject('baseline','checked-resource.json',lambda d:d['sampledPeakBytes'].update(resident_size=0))

    def test_missing_raw_boundary_counter_rejected(self):
        self.reject('baseline','multi-window-resource.json',lambda d:d['finalAfterCleanup']['counters'].pop('resident_size'))

    def test_missing_trace_bytes_despite_availability_flag_rejected(self):
        self.reject('baseline-traced','multi-window-resource.json',lambda d:d['diagnosticBoundaryTrace']['observations'][0]['standard']['bytes'].pop('resident_size'))

    def test_missing_trace_ledger_despite_availability_flag_rejected(self):
        self.reject('candidate-traced','multi-window-resource.json',lambda d:d['diagnosticBoundaryTrace']['observations'][0]['purgeable']['ledgerBytes'].clear())

    def test_release_before_decode_rejected(self):
        def change(d):
            rows=d['diagnosticBoundaryTrace']['observations']
            i=next(i for i,r in enumerate(rows) if r['event']=='decodeBefore')
            j=next(i for i,r in enumerate(rows) if r['event']=='inputAfterAppendScope')
            rows[i],rows[j]=rows[j],rows[i]
        self.reject('baseline-traced','multi-window-resource.json',change)

    def test_missing_append_event_rejected(self):
        self.reject('baseline-traced','multi-window-resource.json',lambda d:next(r for r in d['diagnosticBoundaryTrace']['observations'] if r['event']=='appendBeforeDraws').update(event='unexpectedSyntheticEvent'))

    def test_invalid_cancellation_sequence_rejected(self):
        def change(d):
            for row in d['diagnosticBoundaryTrace']['observations']:
                if row['phase']==3:row['event']='canvasBeforeAllocation'
        self.reject('candidate-traced','multi-window-resource.json',change)

    def test_wrong_decode_window_rejected(self):
        self.reject('baseline-traced','multi-window-resource.json',lambda d:next(r for r in d['diagnosticBoundaryTrace']['observations'] if r['event']=='decodeBefore').update(windowID=999))

    def test_candidate_normalization_and_blend_order_rejected(self):
        def change(d):
            rows=d['diagnosticBoundaryTrace']['observations']
            i=next(i for i,r in enumerate(rows) if r['event']=='normalizationAfter')
            j=next(i for i,r in enumerate(rows) if r['event']=='candidateBlendAfter')
            rows[i],rows[j]=rows[j],rows[i]
        self.reject('candidate-traced','multi-window-resource.json',change)

    def test_backward_trace_timestamp_rejected(self):
        self.reject('baseline-traced','multi-window-resource.json',lambda d:d['diagnosticBoundaryTrace']['observations'][4]['standard'].update(observedAtUptimeSeconds=0))

    def test_retained_raw_input_rejected(self):
        self.reject('baseline','multi-window-resource.json',lambda d:d['cycles'][0]['ownership'].update(liveInputObjects=1))

    def test_retained_raw_canvas_rejected(self):
        self.reject('candidate','multi-window-resource.json',lambda d:d['cycles'][0]['ownedRasterProbe'].update(canvasBytes=16))

    def test_changed_source_dimensions_rejected(self):
        self.reject('baseline','multi-window-resource.json',lambda d:d.update(sourceWidth=384))

    def test_unexpected_output_hash_rejected(self):
        self.reject('baseline','multi-window-resource.json',lambda d:d.update(expectedOutputSHA256='c'*64))

    def test_wrong_launcher_path_rejected(self):
        self.reject('baseline','launch.json.launcher.json',lambda d:d.update(launchedAppPath='/explicitly-synthetic/Other.app'))

    def test_launcher_timeout_even_with_exit_confirmed_rejected(self):
        self.reject('baseline','launch.json.launcher.json',lambda d:d.update(status='timed-out',launcherExitCode=1))

    def test_wrong_profile_rejected(self):
        self.reject('baseline','multi-window-resource.json',lambda d:d.update(compositionMode='normalizedCandidate'))

    def test_trace_overflow_rejected(self):
        self.reject('baseline-traced','multi-window-resource.json',lambda d:d['diagnosticBoundaryTrace'].update(overflowCount=1))

    def test_stale_late_increment_rejected(self):
        self.reject('baseline','checked-resource.json',lambda d:d['lateMeasuredIncrements'][-1]['counterDeltaBytes'].update(resident_size=0))

    def test_boolean_counter_rejected(self):
        self.reject('baseline','multi-window-resource.json',lambda d:d['finalAfterCleanup']['counters'].update(resident_size=True))

    def test_missing_outcome_rejected(self):
        rows=json.loads((self.root/'cell-outcomes.json').read_text());self.write_outcomes(rows[:-1])
        with self.assertRaises(ValueError):namespace['validate'](self.root,SOURCE)

    def test_skipped_candidate_rejected(self):
        rows=json.loads((self.root/'cell-outcomes.json').read_text());rows[-1].update(status='skipped',exitCode=125,reason='Native exact-pixel gate did not pass');self.write_outcomes(rows)
        with self.assertRaises(ValueError):namespace['validate'](self.root,SOURCE)

    def test_failed_cell_even_with_stale_success_files_rejected(self):
        rows=json.loads((self.root/'cell-outcomes.json').read_text());rows[0]['exitCode']=7;self.write_outcomes(rows)
        with self.assertRaises(ValueError):namespace['validate'](self.root,SOURCE)

    def test_cli_failure_preserves_cells_and_replaces_stale_success_even_optimized(self):
        (self.root/'comparison.json').write_text('{"status":"observed"}')
        self.mutate('baseline','checked-resource.json',lambda d:d['sampledPeakBytes'].update(resident_size=0))
        result=subprocess.run([sys.executable,'-O',str(CHECKER),str(self.root),SOURCE],capture_output=True,text=True)
        self.assertEqual(result.returncode,1)
        result=json.loads((self.root/'comparison.json').read_text())
        self.assertEqual(result['status'],'failed')
        self.assertFalse(result['productionPromotionApproved'])
        self.assertFalse(result['observationsComplete'])
        self.assertTrue((self.root/'baseline/multi-window-resource.json').exists())


if __name__=='__main__':unittest.main()
