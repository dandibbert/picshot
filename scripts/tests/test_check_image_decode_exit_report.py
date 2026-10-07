"""Synthetic report tamper checks only; never native evidence."""
import copy
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
import test_check_image_decode_timing_report as timing
import test_check_image_decode_large_report as large

SPEC=importlib.util.spec_from_file_location('exit_check',Path(__file__).resolve().parents[1]/'check-image-decode-exit-report.py')
CHECK=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(CHECK)


class ExitComparisonTests(unittest.TestCase):
    def setUp(self):
        self.template=timing.TimingReportTests(methodName='test_complete_instrumented_matrix_and_prelaunch_cancel')
        self.template.setUp();self.addCleanup(self.template.doCleanups)
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)
        for strategy in ['wait-until-exit','termination-latch']:
            shutil.copytree(self.template.fixture.root,self.root/strategy)
            for f in (self.root/strategy).glob('*/image-decode-large-*.json'):
                if f.name=='image-decode-large-inputs.json':continue
                r=json.loads(f.read_text())
                for row in r.get('workers',r.get('warmups',[])+r.get('cycles',[])):
                    if 'process'in row:row['process']['signatureSeconds']=0.05
                f.write_text(json.dumps(r))
        self.candidate=self.root/'termination-latch'
        for f in self.candidate.glob('*/image-decode-large-*.json'):
            if f.name=='image-decode-large-inputs.json':continue
            r=json.loads(f.read_text());r['exitObservationStrategy']='termination-latch'
            for row in r.get('workers',r.get('warmups',[])+r.get('cycles',[])):
                if 'process'in row:self.add_latch(row['process'])
            f.write_text(json.dumps(r))
        prepared=self.template.fixture.prepared['5k']
        for index,mode in enumerate(['cancel-after-decode','timeout-after-decode']):
            r=self.template.fixture.base('5k',mode,40+index)
            p=self.template.fixture.process('5k','cancelled-after-decode');timing.TimingReportTests.add_process_timing(p);self.add_latch(p)
            if mode=='timeout-after-decode':
                p['outcome']='deadline-after-decode';p['terminal']['error']='deadline';p['phases'][-1]['child']['error']='deadline'
            r.update(timingInstrumentationVersion=3,exitObservationStrategy='termination-latch',oneShotProbe=True,
                warmupCycles=0,measuredCycles=0,completedParentDraws=0,armDeadlineSeconds=20,requiredOuterDeadlineSeconds=30,
                elapsedSeconds=6,probeDecodedRGBAMatchesReference=True,sharedLeaseReacquired=True,helperInvocations=1,
                parentMemoryWatchdogBytes=536870912,childMemoryWatchdogBytes=268435456,beforeProbe=large.memory(),afterProbe=large.memory(),probe=p)
            f=self.root/'probes'/mode/f'image-decode-large-{mode}.json';f.parent.mkdir(parents=True);f.write_text(json.dumps(r))

    @staticmethod
    def add_latch(p):
        p.update(exitObservationStrategy='termination-latch',terminationHandlerCleared=bool(p['childLaunched']),
                 stdoutEOFConfirmed=bool(p['childLaunched']),stderrEOFConfirmed=bool(p['childLaunched']))
        if not p['childLaunched']:return
        t=p['parentTimingUptimes'];t.pop('waitUntilExitStarted');t.pop('waitUntilExitCompleted')
        t.update(terminationHandlerInstalled=99,terminationLatchWaitStarted=103.011,terminationLatchValidated=103.012,
                 stdoutEOFObserved=103.013,stderrEOFObserved=103.014)
        p['boundaryUptimes'].update(processRunStarted=99.1,childExitConfirmed=103.02,cleanupFinished=103.3)
        p['terminationLatch']=dict(callbackCount=1,childPID=p['childPID'],terminationStatus=p['terminationStatus'],terminationReason=1,
            callbackObservedNotRunning=True,callbackEnteredUptimeSeconds=103.005,callbackPublishedUptimeSeconds=103.006)

    def check(self):return CHECK.validate(self.root,large.SOURCE,large.ARCHITECTURE)
    def reject(self,mutate,relative='termination-latch/4k-isolated-decode/image-decode-large-isolated-decode.json'):
        f=self.root/relative;old=f.read_text();r=json.loads(old);mutate(r);f.write_text(json.dumps(r))
        try:
            with self.assertRaises((AssertionError,KeyError,StopIteration)):self.check()
        finally:f.write_text(old)

    def test_complete_comparison_and_fault_probes(self):
        r=self.check();self.assertEqual(len(r['comparisons']),3);self.assertEqual(len(r['probes']),2);self.assertFalse(r['parentLossVerified'])
    def test_missing_duplicate_or_wrong_callback_is_rejected(self):
        for change in [dict(callbackCount=0),dict(callbackCount=2),dict(childPID=99999),dict(terminationStatus=19),dict(terminationReason=2),dict(callbackObservedNotRunning=False)]:
            self.reject(lambda r:r['cycles'][0]['process']['terminationLatch'].update(change))
    def test_callback_alone_cannot_replace_exit_EOF_cleanup_or_lease(self):
        for key in ['exitConfirmed','stdoutEOFConfirmed','stderrEOFConfirmed','cleanupConfirmed','admissionReleased','terminationHandlerCleared']:
            self.reject(lambda r:r['cycles'][0]['process'].update({key:False}))
    def test_late_install_or_reversed_callback_times_are_rejected(self):
        self.reject(lambda r:r['cycles'][0]['process']['parentTimingUptimes'].update(terminationHandlerInstalled=104))
        self.reject(lambda r:r['cycles'][0]['process']['terminationLatch'].update(callbackPublishedUptimeSeconds=103))
        self.reject(lambda r:r['cycles'][0]['process']['terminationLatch'].update(callbackEnteredUptimeSeconds=float('nan')))
    def test_candidate_cannot_silently_retain_old_wait(self):
        self.reject(lambda r:r['cycles'][0]['process']['parentTimingUptimes'].update(waitUntilExitStarted=103.011))
        self.reject(lambda r:r.pop('exitObservationStrategy'))
    def test_baseline_cannot_silently_install_candidate(self):
        self.reject(lambda r:r['cycles'][0]['process'].update(exitObservationStrategy='termination-latch'),
                    'wait-until-exit/4k-isolated-decode/image-decode-large-isolated-decode.json')
    def test_probe_requires_real_postdecode_hash_no_output_and_reacquired_lease(self):
        path='probes/cancel-after-decode/image-decode-large-cancel-after-decode.json'
        for key in ['sharedLeaseReacquired','probeDecodedRGBAMatchesReference']:
            self.reject(lambda r:r.update({key:False}),path)
        self.reject(lambda r:r['probe'].update(sawPostDecodeReady=False),path)
        self.reject(lambda r:r['probe'].update(outputExistedBeforeCleanup=True),path)
        self.reject(lambda r:r['probe']['phases'][4]['child'].update(rawSHA256='f'*64),path)
    def test_probe_deadline_and_cancel_outcomes_are_not_interchangeable(self):
        self.reject(lambda r:r['probe'].update(outcome='cancelled-after-decode'),'probes/timeout-after-decode/image-decode-large-timeout-after-decode.json')
        self.reject(lambda r:r.update(completedParentDraws=1),'probes/cancel-after-decode/image-decode-large-cancel-after-decode.json')
    def test_cancel_between_install_and_launch_is_valid_without_fabricated_callback(self):
        f=self.candidate/'5k-native-ui-isolated/image-decode-large-native-ui-isolated.json';r=json.loads(f.read_text());p=r['workers'][7]['process']
        p.update(terminationHandlerCleared=True,terminationLatch={'callbackCount':0},parentTimingUptimes={'terminationHandlerInstalled':99})
        f.write_text(json.dumps(r));self.check()
    def test_launch_failure_does_not_count_as_a_successful_probe(self):
        self.reject(lambda r:r['probe'].update(childLaunched=False),'probes/cancel-after-decode/image-decode-large-cancel-after-decode.json')


if __name__=='__main__':unittest.main()
