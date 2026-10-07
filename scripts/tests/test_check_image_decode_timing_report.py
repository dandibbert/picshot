"""Synthetic schema checks only. These never constitute native evidence."""
import copy
import unittest
import test_check_image_decode_large_report as baseline


class TimingReportTests(unittest.TestCase):
    def setUp(self):
        self.fixture = baseline.LargeReportTests(methodName='test_complete_six_cells_with_native_ui_schema')
        self.fixture.setUp(); self.addCleanup(self.fixture.doCleanups)
        for cell, original in self.fixture.reports.items():
            report = copy.deepcopy(original); report['timingInstrumentationVersion'] = 3
            records = report.get('workers', report['warmups'] + report['cycles'])
            for record in records:
                if 'process' in record: self.add_process_timing(record['process'])
            if 'mainQueue' in report:
                phases = ['setup', 'sourceConstruction', 'controllerSnapshotConstruction', 'warmupPreview', 'steadyPreview',
                          'debounceBurst', 'cancelActive', 'closeDecoded', 'lateResult', 'evidenceCapture', 'settle', 'cleanup']
                report['mainQueue']['timing'] = dict(version=3, maximumWorstAcknowledgements=8, maximumPhaseTransitions=64,
                    overflowed=False, invalidTimestampObserved=False,
                    phaseTransitions=[dict(phase=p, uptimeSeconds=float(i)) for i,p in enumerate(phases)],
                    worstAcknowledgements=[dict(queuedUptimeSeconds=4.01+i*0.05, acknowledgedUptimeSeconds=4.03+i*0.05,
                                                delaySeconds=0.02, queuedPhase='steadyPreview', acknowledgedPhase='steadyPreview') for i in range(8)])
            self.fixture.reports[cell] = report; self.fixture.save_report(cell, report)

    @staticmethod
    def add_process_timing(process):
        process.update(timingInstrumentationVersion=3, parentTimingUptimes={}, childTimingTraceStatus='notLaunched')
        if not process['childLaunched']: return
        process.update(stderrBytes=420, childTimingTraceStatus='complete', childTimingTrace=dict(
            schema='image-decode-tail-v3', childPID=process['childPID'], terminalWriteStartedUptimeSeconds=103.001,
            terminalWriteCompletedUptimeSeconds=103.002, terminalWriteAttemptCount=1, runReturnedUptimeSeconds=103.003,
            framePreparedUptimeSeconds=103.004, terminalWriteSucceeded=True), parentTimingUptimes=dict(
            terminalFrameReadReturned=103.006, terminalFrameDecodedAtReceipt=103.007, terminationObserved=103.01,
            waitUntilExitStarted=103.011, waitUntilExitCompleted=103.10))
        process['boundaryUptimes']['childExitConfirmed'] = 103.101

    def validate(self, headless=False):
        return baseline.CHECK.validate(self.fixture.root, baseline.SOURCE, baseline.ARCHITECTURE, headless, True)

    def reject(self, mutate, cell='4k-isolated-decode'):
        original = self.fixture.reports[cell]; changed = copy.deepcopy(original); mutate(changed)
        self.fixture.save_report(cell, changed)
        try:
            with self.assertRaises((AssertionError, KeyError, StopIteration)): self.validate()
        finally: self.fixture.save_report(cell, original)

    def test_complete_instrumented_matrix_and_prelaunch_cancel(self):
        result = self.validate(); self.assertEqual(result['timingInstrumentationVersion'], 3)
        self.assertTrue(result['coverage']['allCancellationRacesObserved'])

    def test_timing_requires_explicit_checker_mode(self):
        with self.assertRaises(AssertionError): baseline.CHECK.validate(self.fixture.root, baseline.SOURCE, baseline.ARCHITECTURE)
        self.reject(lambda r:r.pop('timingInstrumentationVersion'))

    def test_missing_absent_malformed_or_wrong_pid_tail_fails(self):
        for status in ['pending','absent','malformed','oversized']:
            self.reject(lambda r:r['cycles'][0]['process'].update(childTimingTraceStatus=status))
        self.reject(lambda r:r['cycles'][0]['process'].pop('childTimingTrace'))
        self.reject(lambda r:r['cycles'][0]['process']['childTimingTrace'].update(childPID=99999))

    def test_tail_failure_extra_fields_and_byte_overflow_fail(self):
        for mutation in [dict(terminalWriteSucceeded=False),dict(terminalWriteAttemptCount=2),dict(extra=True)]:
            self.reject(lambda r:r['cycles'][0]['process']['childTimingTrace'].update(mutation))
        self.reject(lambda r:r['cycles'][0]['process'].update(stderrBytes=1025))

    def test_nonfinite_or_nonmonotone_tail_times_fail(self):
        for value in [float('nan'), float('inf'), -1, 102]:
            self.reject(lambda r:r['cycles'][0]['process']['childTimingTrace'].update(runReturnedUptimeSeconds=value))
        self.reject(lambda r:r['cycles'][0]['process']['parentTimingUptimes'].update(waitUntilExitCompleted=102))

    def test_terminal_receipt_may_precede_write_return_or_follow_exit(self):
        p = self.fixture.reports['4k-isolated-decode']['cycles'][0]['process']
        p['parentTimingUptimes'].update(terminalFrameReadReturned=103.0015, terminalFrameDecodedAtReceipt=103.0016)
        self.fixture.save_report('4k-isolated-decode',self.fixture.reports['4k-isolated-decode']); self.validate()
        p['parentTimingUptimes'].update(terminalFrameReadReturned=103.2, terminalFrameDecodedAtReceipt=103.3)
        self.fixture.save_report('4k-isolated-decode',self.fixture.reports['4k-isolated-decode']); self.validate()

    def test_missing_phase_or_timeline_overflow_fails(self):
        cell='5k-native-ui-isolated'
        self.reject(lambda r:r['mainQueue']['timing'].update(overflowed=True),cell)
        self.reject(lambda r:r['mainQueue']['timing'].update(invalidTimestampObserved=True),cell)
        self.reject(lambda r:r['mainQueue']['timing']['phaseTransitions'].pop(2),cell)
        self.reject(lambda r:r['mainQueue']['timing'].update(phaseTransitions=r['mainQueue']['timing']['phaseTransitions']*6),cell)

    def test_incorrect_phase_overlap_delay_or_worst_cap_fails(self):
        cell='5k-native-ui-isolated'
        self.reject(lambda r:r['mainQueue']['timing']['worstAcknowledgements'][0].update(queuedPhase='cleanup'),cell)
        self.reject(lambda r:r['mainQueue']['timing']['worstAcknowledgements'][0].update(delaySeconds=0.5),cell)
        self.reject(lambda r:r['mainQueue']['timing']['worstAcknowledgements'].pop(),cell)
        self.reject(lambda r:r['mainQueue']['timing']['worstAcknowledgements'].append(r['mainQueue']['timing']['worstAcknowledgements'][0]),cell)

    def test_worst_delay_must_match_original_queue_maximum(self):
        self.reject(lambda r:r['mainQueue'].update(maximumDelaySeconds=0.03),'5k-native-ui-isolated')


if __name__ == '__main__': unittest.main()
