"""Test ui-preview.sh's ordinary-Python assertion gate, never native evidence.

Compile at optimize=0 to match that shell command even if this unittest runner
uses -O. This does not claim that the production gate is safe under python -O.
"""
import copy
import json
import pathlib
import struct
import tempfile
import types
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = (ROOT / 'scripts/ui-preview.sh').read_text()
CHECK = compile(SCRIPT.split("inputs=r['recordingInputControls']", 1)[1].split("save=r['saveWorkflowUI']", 1)[0],
                'ui-preview.sh:recording-input-check', 'exec', optimize=0)


def geometry(identifier):
    return dict(identifier=identifier, x=1, y=1, width=10, height=10, insideContent=True,
                nonoverlapping=True, accessibilityIdentifierVerified=True,
                nativeHitTargetVerified=identifier != 'recording-input-status')


def dismissal(phase, observed=(0.155,)):
    # Synthetic monotonic values for checker tests, never native observations.
    start=100.0
    samples=[]
    for index,elapsed in enumerate(observed):
        scheduled=start+0.151 if index==0 else min(start+observed[index-1]+0.025,start+1)
        actual=start+elapsed
        samples.append(dict(checkpoint='original-post-settle' if index==0 else 'visibility-poll',
            isVisible=index<len(observed)-1, scheduledUptimeSeconds=scheduled, observedUptimeSeconds=actual,
            scheduledMilliseconds=(scheduled-start)*1000, observedMilliseconds=(actual-start)*1000,
            schedulingDelayMilliseconds=(actual-scheduled)*1000))
    return dict(schema='recording-help-dismissal-v1', phase=phase, status='passed',
        outcome='hidden-after-original-post-settle' if len(samples)>1 else 'hidden-at-original-post-settle',
        acceptanceContract='owned-help-first-hidden-observed-within-1000ms-v1',
        timingOrigin='before-native-dismissal-request-hit-test-and-performClick',
        interactionRoute='NSButton.performClick', visibilityRoute='NSWindow.isVisible',
        originalSettleMilliseconds=150, deadlineMilliseconds=1000, pollMilliseconds=25,
        strict150MillisecondLatencyEstablished=False, windowVisibleBeforeClick=True,
        ownedWindowNumber=12, ownerWindowNumber=11, ownedWindowIdentity='synthetic-unit-window',
        actionStartedUptimeSeconds=start, actionReturnedUptimeSeconds=start+0.001,
        settleStartedUptimeSeconds=start+0.001, deadlineUptimeSeconds=start+1,
        firstHiddenObservedMilliseconds=samples[-1]['observedMilliseconds'],
        visibleAtOriginalCheckpoint=samples[0]['isVisible'], finalVisible=False, observations=samples)


def context(theme, prefix):
    value = dict(appearance=theme, status='passed', interactionStatus='passed', layoutStatus='passed',
                 defaultOff=True, initialPermissionChecks=0, nativeMonitorRegistrations=0,
                 nativeTogglePresses=12, finalOptionsMatchInitial=True, helpAndRefreshVerified=True,
                 nativeHelpPresses=4, nativeRefreshPresses=2)
    phases=['dismiss-help-after-grant','dismiss-help-after-revocation']
    value['helpDismissals']=[dismissal(phase) for phase in phases]
    value['helpDismissalFiles']=[f'{prefix}-{phase}-{theme}.json' for phase in phases]
    state = dict(clicks=False, scrolls=False, shortcuts=False)
    actions = [(control, enabled) for control in state for enabled in [True, False, True]]
    actions += [(control, False) for control in state]
    value['optionRoundTrips'] = []
    for control, enabled in actions:
        state[control] = enabled
        value['optionRoundTrips'].append(dict(control=control, enabled=enabled, **state))
    buttons = ['recording-input-' + control for control in ['clicks', 'scrolls', 'shortcuts', 'help']]
    for key in ['defaultOffGeometry', 'deniedGeometry', 'allowedGeometry', 'restoredOffGeometry', 'helpGeometry']:
        identifiers = ['recording-input-refresh'] if key == 'helpGeometry' else buttons + (
            ['recording-input-status'] if key in ['deniedGeometry', 'allowedGeometry'] else [])
        value[key] = [geometry(identifier) for identifier in identifiers]
    value['files'] = [f'{prefix}-{state}-{theme}.png' for state in
                      ['default-off', 'denied', 'help-denied', 'help-allowed', 'allowed', 'restored-off']]
    value['geometryFiles'] = [filename[:-4] + '-geometry.json' for filename in value['files']]
    return value


def report():
    value = dict(status='passed', interactionStatus='passed', contentWidthPoints=440,
                 interactionRoute='NSButton.performClick', hitTestRoute='NSView.hitTest',
                 nativeMonitorRegistrations=0, injectedPermissions=True, recordingStarted=False,
                 screenCaptureStarted=False, permissionRequested=False, globalInputPosted=False, appearances=[])
    for theme in ['light', 'dark']:
        isolated = context(theme, 'recording-input')
        isolated['ownership'] = dict(status='passed', retainedObjects=0, weakProbeCount=34,
                                     releaseMilliseconds=10, deadlineMilliseconds=3000)
        isolated['representableLifecycle'] = dict(status='passed', replacementBindingVerified=True,
            externalStateVerified=True, replacementActionVerified=True, inheritedDisableVerified=True, nativeControlAndCoordinatorReuseVerified=True)
        full = context(theme, 'recording-panel')
        full.update(contentWidthPoints=480, contentHeightPoints=490, syntheticTarget=True,
                    syntheticTargetChecks=1, cameraRequested=False, recordingStarted=False)
        full['panelSectionGeometry'] = {state: [dict(section=section, x=18, y=18 + index * 30,
            width=400, height=20, insideContent=True, nonoverlapping=True, coordinateSystem='top-left')
            for index, section in enumerate(['options', 'start', 'divider', 'effects', 'status', 'previewHint', 'privacyHint'])]
            for state in ['default-off', 'denied', 'allowed', 'restored-off']}
        isolated['fullPanel'] = full
        value['appearances'].append(isolated)
    return value


class RecordingInputUIGateTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='recording-input-check-unit-')
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        self.valid = report()
        # The checker reads PNG dimensions; these are explicit unit stubs, not
        # renderings, native run artifacts, or evidence offered for release.
        for appearance in self.valid['appearances']:
            for node, size in [(appearance, (440, 100)), (appearance['fullPanel'], (480, 490))]:
                for filename in node['files']:
                    (self.root / filename).write_bytes(b'\x89PNG\r\n\x1a\n' + b'unitstub' + struct.pack('>II', *size))
                for filename in node['geometryFiles']:
                    frame = dict(x=12, y=12, width=40, height=20)
                    measurement = dict(status='measured-before-validation', coordinateSystem='top-left',
                        controls=[dict(identifier='unit-stub', matchCount=1, views=[dict(frame=frame,
                            alignmentFrame=frame, alignmentInsets=dict(top=0, left=0, bottom=0, right=0))])], intersections=[])
                    (self.root / filename).write_text(json.dumps(measurement))

    def check(self, value, write_dismissals=True):
        if write_dismissals:
            for appearance in value['appearances']:
                for node in [appearance]+([appearance['fullPanel']] if 'fullPanel' in appearance else []):
                    for filename,row in zip(node.get('helpDismissalFiles',[]),node.get('helpDismissals',[])):
                        (self.root/filename).write_text(json.dumps(row))
        exec(CHECK, dict(inputs=value, pathlib=pathlib, json=json,
                         sys=types.SimpleNamespace(argv=['checker', str(self.root / 'preview.json')])))

    def testCompleteUnitContractIsAccepted(self):
        self.check(self.valid)

    def testLayoutOnlyPendingAndMissingFullPanelAreRejected(self):
        for change in ['layout-only', 'pending', 'missing-panel']:
            value = copy.deepcopy(self.valid)
            if change == 'layout-only': value['status'] = change
            elif change == 'pending': value['appearances'][0]['interactionStatus'] = change
            else: del value['appearances'][0]['fullPanel']
            with self.subTest(change=change), self.assertRaises((AssertionError, KeyError)):
                self.check(value)

    def testStaleBindingMissingHitTargetClippingAndLeakAreRejected(self):
        for change in ['binding', 'hit-target', 'clipped-section', 'retained', 'disabled', 'recreated', 'dimensions']:
            value = copy.deepcopy(self.valid)
            appearance = value['appearances'][0]
            if change == 'binding': appearance['optionRoundTrips'][0]['scrolls'] = True
            elif change == 'hit-target': appearance['allowedGeometry'][0]['nativeHitTargetVerified'] = False
            elif change == 'clipped-section': appearance['fullPanel']['panelSectionGeometry']['allowed'][0]['width'] = 800
            elif change == 'retained': appearance['ownership']['retainedObjects'] = 1
            elif change == 'disabled': appearance['representableLifecycle']['inheritedDisableVerified'] = False
            elif change == 'recreated': appearance['representableLifecycle']['nativeControlAndCoordinatorReuseVerified'] = False
            else: appearance['fullPanel']['contentHeightPoints'] = 491
            with self.subTest(change=change), self.assertRaises(AssertionError):
                self.check(value)

    def testRawFrameExpansionAndOverlapDiagnosticsAreRejected(self):
        path = self.root / self.valid['appearances'][0]['geometryFiles'][0]
        original = json.loads(path.read_text())
        for change in ['inset', 'expanded-frame', 'overlap']:
            measurement = copy.deepcopy(original)
            if change == 'inset': measurement['controls'][0]['views'][0]['alignmentInsets']['bottom'] = 4
            elif change == 'expanded-frame': measurement['controls'][0]['views'][0]['alignmentFrame']['y'] += 2
            else: measurement['intersections'] = [dict(intersection=dict(width=20, height=2))]
            path.write_text(json.dumps(measurement))
            with self.subTest(change=change), self.assertRaises(AssertionError):
                self.check(self.valid)
        path.write_text(json.dumps(original))

    def testConditionBasedDismissalPreservesOriginalVisibleObservation(self):
        row=dismissal('dismiss-help-after-revocation',(0.155,0.185,0.250))
        self.valid['appearances'][0]['fullPanel']['helpDismissals'][1]=row
        self.check(self.valid)
        self.assertTrue(row['visibleAtOriginalCheckpoint'])
        self.assertEqual(row['outcome'],'hidden-after-original-post-settle')

    def testLateHiddenAndStalledOriginalSampleCannotPass(self):
        for observations in [(1.010,), (0.155,1.010)]:
            value=copy.deepcopy(self.valid)
            value['appearances'][0]['fullPanel']['helpDismissals'][1]=dismissal('dismiss-help-after-revocation',observations)
            with self.subTest(observations=observations), self.assertRaises(AssertionError):
                self.check(value)

    def testMissingVisibilityFalseTimingAndUnownedWindowAreRejected(self):
        changes=['missing-reopen','visible','binding-only','wrong-clock','false-elapsed','missing-original',
                 'wrong-original-time','owner-window','latency-claim','nonfinite','after-deadline','wrong-outcome']
        for change in changes:
            value=copy.deepcopy(self.valid)
            node=value['appearances'][0]['fullPanel']; row=node['helpDismissals'][1]
            if change=='missing-reopen': node['helpDismissals'].pop()
            elif change=='visible': row['finalVisible']=True
            elif change=='binding-only': row['visibilityRoute']='showsHelp=false'
            elif change=='wrong-clock': row['deadlineUptimeSeconds']+=10
            elif change=='false-elapsed': row['observations'][0]['observedMilliseconds']=100
            elif change=='missing-original': row['observations'][0]['checkpoint']='visibility-poll'
            elif change=='wrong-original-time': row['observations'][0]['scheduledUptimeSeconds']-=0.050
            elif change=='owner-window': row['ownedWindowNumber']=row['ownerWindowNumber']
            elif change=='latency-claim': row['strict150MillisecondLatencyEstablished']=True
            elif change=='nonfinite': row['observations'][0]['observedUptimeSeconds']=float('nan')
            elif change=='after-deadline': row['firstHiddenObservedMilliseconds']=1001
            else: row['outcome']='hidden-after-original-post-settle'
            with self.subTest(change=change), self.assertRaises((AssertionError,KeyError)):
                self.check(value)

    def testDismissalReportMustMatchPersistedObservation(self):
        self.check(self.valid)
        path=self.root/self.valid['appearances'][0]['helpDismissalFiles'][0]
        row=json.loads(path.read_text()); row['finalVisible']=True
        path.write_text(json.dumps(row))
        with self.assertRaises(AssertionError):
            self.check(self.valid,write_dismissals=False)


if __name__ == '__main__':
    unittest.main()
