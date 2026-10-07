"""Schema-only fake reports; these are never native attribution evidence."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('image_decode_check', Path(__file__).resolve().parents[1]/'check-image-decode-helper-report.py')
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


def memory():
    return {'standard': {'kernelReturn': 0, 'bytes': {'resident_size': 100, 'phys_footprint': 50}},
            'purgeable': {'kernelReturn': 0, 'bytes': {'purgeable_volatile_resident': 0, 'purgeable_volatile_virtual': 0, 'purgeable_volatile_pmap': 0}}}


def child(pid, outcome, root):
    phases = ['beforePNGRead', 'imageCreated', 'rasterDrawn', 'afterContextRelease']
    phases += ['outputClosed', 'afterDecodePool'] if outcome == 'decoded' else ['heldAfterDecode']
    t = {'schema': 'image-decode-helper-v1', 'childPID': pid, 'kind': 'result' if outcome == 'decoded' else 'error',
         'peaks': {'residentBytes': 10, 'footprintBytes': 5, 'residentSamples': 1, 'footprintSamples': 1}}
    if outcome == 'decoded': t.update(rawBytes=1769472, rawSHA256='b'*64)
    else: t['error'] = 'cancelled' if outcome.startswith('cancelled') else 'deadline'
    return {'outcome': outcome, 'childLaunched': True, 'exitConfirmed': True, 'cleanupConfirmed': True, 'admissionReleased': True,
            'childPID': pid, 'stdoutBytes': 1, 'stderrBytes': 0, 'stderrTruncated': False, 'jobDirectory': str(root/f'absent-{pid}'),
            'terminationReason': 'exit', 'terminationStatus': 0 if outcome == 'decoded' else 1, 'launchThroughExitSeconds': 0.01,
            'terminal': t, 'phases': [{'child': {'phase': p, 'childPID': pid, 'memory': memory(), 'rawBytes': 1769472, 'rawSHA256': 'b'*64}, 'parentAtReceipt': memory(),
                                     'receiptSkewSeconds': 0.001, 'childObservedRunning': True} for p in phases],
            'outputExistedBeforeCleanup': outcome == 'decoded', 'sawPostDecodeReady': outcome != 'decoded',
            'cancelRequested': outcome.startswith('cancelled'), 'cancelWriteReturn': 7}


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.source = 'c'*40
        prepared = {'status': 'prepared', 'sourceCommit': self.source, 'architecture': 'arm64', 'processIdentifier': 10, 'pngSHA256': 'a'*64, 'rawSHA256': 'b'*64}
        self.write('prepared/image-draw-inputs.json', prepared)
        self.reports = {}
        for offset, mode in enumerate(['production-control', 'isolated-decode', 'cancel-after-decode', 'timeout-after-decode']):
            measured = offset < 2
            r = dict(status='observed', protocol='image-decode-helper-parent-v1', mode=mode, sourceCommit=self.source, architecture='arm64',
                     processIdentifier=11+offset, inputPreparationProcessIdentifier=10, sourceWidth=768, sourceHeight=576, rasterBytes=1769472,
                     pixelTolerance=0, immutablePNGSHA256='a'*64, immutableRawSHA256='b'*64, captureStarted=False, networkAttempted=False,
                     allocatorReliefCalls=0, immutableInputsUnchanged=True, ownedJobDirectoriesRemaining=0, retainedCycleImages=0,
                     childWorkDeadlineSeconds=5, childHardDeadlineSeconds=6, childExitDeadlineSeconds=9, armDeadlineSeconds=180,
                     requiredOuterDeadlineSeconds=200, elapsedSeconds=5, oneShotProbe=not measured, warmupCycles=2 if measured else 0,
                     measuredCycles=12 if measured else 0, completedDraws=14 if measured else 0, completedFullPixelValidations=14 if measured else 0,
                     destinationLifetime={'allocations': 1}, baselineAfterWarmup=memory(), parentSampledMemory={'residentBytes': 100, 'footprintBytes': 50},
                     helperInvocations=0 if offset == 0 else 14 if offset == 1 else 1, maximumObservedChildConcurrency=0 if offset == 0 else 1,
                     probeDecodedRGBAMatchesReference=True, warmups=[], cycles=[])
            for key in ['beforeDestinationPreparation', 'afterDestinationPreparation', 'halfSecondAfterFinalCycleDestinationLive', 'afterDestinationOwnerDropped', 'halfSecondAfterDestinationOwnerDropped']: r[key] = memory()
            if measured:
                for i in range(14):
                    warm = i < 2; index = i+1 if warm else i-1
                    c = dict(index=index, isWarmup=warm, before=memory(), beforeParentDraw=memory(), afterPool=memory(), settled=memory(),
                             timeToValidatedPixelsSeconds=0.015, fullLifecycleSeconds=0.02, observedCycleSeconds=0.2,
                             draw={'beforeDrawImageLive': memory(), 'afterDrawAndReadbackImageLive': memory(), 'actualDrawCount': 1,
                                   'validatedRGBABytes': 1769472, 'maximumAbsoluteChannelDifference': 0, 'pixelsSHA256': 'b'*64})
                    if offset == 1:
                        c['process'] = child(100+i, 'decoded', self.root)
                        c['rawProviderLifetime'] = {'allocations': i+1}
                    r['warmups' if warm else 'cycles'].append(c)
                if offset == 1: r['rawProviderLifetime'] = dict(allocations=14, callbackSizesMatch=True, releaseCallbacks=14, deallocations=14, activeBytes=0)
            else: r['probe'] = child(114 if offset == 2 else 115, 'cancelled-after-decode' if offset == 2 else 'deadline-after-decode', self.root)
            self.reports[mode] = r
            self.write(f'{mode}/image-decode-helper-{mode}.json', r)
    def write(self, path, data):
        p = self.root/path; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(json.dumps(data))
    def run_check(self): return CHECK.validate(self.root, self.source, 'arm64')
    def change(self, mode, mutate):
        r = copy.deepcopy(self.reports[mode]); mutate(r); self.write(f'{mode}/image-decode-helper-{mode}.json', r)
    def test_complete_synthetic_schema(self):
        result = self.run_check(); self.assertEqual(result['status'], 'observed')
        self.assertIn('sampledIndependentPeakEnvelope', result['arms'][1])
    def test_missing_purgeable_success_fails(self):
        self.change('isolated-decode', lambda r: r['cycles'][0]['settled']['purgeable'].update(kernelReturn=5))
        with self.assertRaises(AssertionError): self.run_check()
    def test_pixel_mismatch_fails(self):
        self.change('isolated-decode', lambda r: r['cycles'][0]['draw'].update(maximumAbsoluteChannelDifference=1))
        with self.assertRaises(AssertionError): self.run_check()
    def test_unconfirmed_exit_fails(self):
        self.change('isolated-decode', lambda r: r['cycles'][0]['process'].update(exitConfirmed=False))
        with self.assertRaises(AssertionError): self.run_check()
    def test_false_postdecode_cancel_fails(self):
        self.change('cancel-after-decode', lambda r: r['probe'].update(sawPostDecodeReady=False))
        with self.assertRaises(AssertionError): self.run_check()
    def test_duplicate_child_pid_fails(self):
        self.change('isolated-decode', lambda r: r['cycles'][0]['process'].update(childPID=100))
        with self.assertRaises(AssertionError): self.run_check()
    def test_leftover_job_fails(self):
        (self.root/'absent-100').mkdir()
        with self.assertRaises(AssertionError): self.run_check()


if __name__ == '__main__': unittest.main()
