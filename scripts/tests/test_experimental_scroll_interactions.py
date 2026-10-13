"""Adversarial portable contracts; synthetic receipts are never macOS evidence."""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import struct
import tempfile
import unittest
import zlib
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('experimental', REPO/'scripts/check-experimental-scroll-interactions.py')
C = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(C)


def png_chunk(kind, payload):
    return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload) & 0xffffffff)


def fixture_png(width=2, height=2):
    # Actual tiny opaque PNG bytes, solely a portable evidence-reader fixture.
    rows = (b'\0' + bytes((24, 80, 160, 255)) * width) * height
    return (b'\x89PNG\r\n\x1a\n' + png_chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
            + png_chunk(b'IDAT', zlib.compress(rows)) + png_chunk(b'IEND', b''))


def malformed_recovery_pngs(valid):
    idat = valid.index(b'IDAT')
    length = struct.unpack_from('>I', valid, idat - 4)[0]
    bad_crc = bytearray(valid); bad_crc[idat + 4 + length] ^= 1
    return dict(signature_only=valid[:8], header_only=valid[:33],
                truncated_idat=valid[:idat + 4 + length - 1], missing_iend=valid[:-12],
                truncated_iend=valid[:-1], corrupt_idat_crc=bytes(bad_crc))


def demo():
    comparison = dict(passed=True, dimensionsMatch=True, exactEquality=True,
                      meanAbsoluteRGBAError=0.0, fractionOfChannelsDifferingByMoreThan8=0.0)
    result = dict(status='passed', installerAcceptance=False, permissionRequested=False,
                  globalInputPosted=False, privateUserContent=False, networkUsed=False,
                  realStream=dict(status='blocked', permissionAlreadyGranted=False),
                  realScreenCaptureValidated=False)
    for name in ('illustratedCase', 'ordinaryTextCase', 'movementCase', 'automaticCase'):
        result[name] = dict(status='passed', productSessionClosed=True,
            **{'finishCallbacks' if name == 'movementCase' else 'finishButtonCompletionCallbacks': 1},
            **{'referenceComparison' if name == 'movementCase' else 'nativeReferenceComparison': copy.deepcopy(comparison)})
    result['illustratedCase'].update(extendedAfterReversal=True, acceptedReverseObservations=2,
        gapMarkerUnverified=True, gapMarkerAmber=True, gapAccessibilityDescribesUnverifiedPosition=True,
        gapRecoveryMarkerVerified=True, gapRecoveryMarkerGreen=True,
        gapRecoveryAccessibilityDescribesVerifiedPosition=True)
    result['illustratedCase']['stationaryPreviewRecovery'] = dict(status='passed', injectedPreviewFailures=1,
        nativeWheelEventsToFailure=1, nativeWheelEventsDuringRecovery=0,
        beforeFailureAcceptedObservations=30, beforeFailureOffset=1248,
        failureAcceptedObservations=31, failureOffset=1296, failureHeight=1776, failureNativeOffset=1296,
        failurePreviewUnavailable=True, failureMatched=True, failureRetainedPreviewPixels=True,
        failureMarkerUnverified=True, failureMarkerAmber=True, failureAccessibilityUnverified=True,
        failureAutoOff=True, failureAutoDisabled=True, failureAutoLabel='自动滚动', recoveryRequiresFurtherInput=False,
        recoveryAcceptedObservations=31, recoveryOffset=1296, recoveryHeight=1776, recoveryNativeOffset=1296,
        stationaryFramesObserved=1, recoveryPreviewAvailable=True, recoveryMarkerVerified=True,
        recoveryMarkerGreen=True, recoveryMarkerAtAcceptedViewport=True, recoveryAccessibilityVerified=True,
        recoveryAutoOff=True, recoveryAutoLabel='自动滚动', durableSourceCountUnchanged=True,
        durableStripCountUnchanged=True, durableDiskBytesUnchanged=True, sourcePacingMaximumSeconds=2,
        failureAppearanceEvidence={a: 'live-scroll-preview-failed-' + a + '.png' for a in ('light', 'dark')},
        recoveryAppearanceEvidence={a: 'live-scroll-preview-recovered-' + a + '.png' for a in ('light', 'dark')})
    result['ordinaryTextCase']['addedAlignmentMarkers'] = False
    result['movementCase'].update(moveAppliedThroughReturn=False, moveAppliedThroughMouseRelease=True,
        actualSourcePixelsChanged=True, ownedTargetIdentityUnchanged=True, matchedMoveDisplacement=48,
        drag=dict(crossAxisUnchanged=True, sizeUnchanged=True, finalReleasePositionApplied=True, alongAxisDelta=48),
        duringDrag=dict(toolbarVisible=True, previewVisible=True, handleVisible=True,
                       lastGoodPreviewPixelsPreserved=True, previewPositionUnverified=True, previewMarkerAmber=True,
                       previewAccessibilityUnverified=True, sourceRegionUnchanged=True, fullscreenMoveViewAbsent=True),
        escapeRollback=dict(passed=True, sourceRegionPreserved=True, acceptedHeightPreserved=True,
                            acceptedOffsetPreserved=True, lastGoodPreviewPixelsPreserved=True,
                            captureResumed=True, trailingMouseUpIgnored=True),
        dragAppearanceEvidence=dict(light='live-scroll-movement-native-drag.png',
                                    dark='live-scroll-movement-native-dark-drag.png', restoredAppearance='aqua'))
    result['movementCase']['ownedSourceStopped'] = True
    result['movementCase']['rejectedMovePause'] = dict(status='passed', injectedMoveFailures=1,
        moveRoute='owned handle NSWindow.sendEvent mouseDown/mouseDragged/mouseUp with hit-test',
        pauseButtonRoute='accepted native hit-test/mouse helper PortableSettingsUIPreviewFixture.click',
        resumeCallsAfterRejection=1, pauseCallsForDrag=1, activeErrorStatus=True, activeSourceResumed=True,
        activePauseLabel='暂停捕获', activePauseTooltip='暂停捕获', activePauseEnabled=True, sourceRegionPreserved=True,
        ownedTargetIdentityUnchanged=True, retainedHeight=888, retainedOffset=408, retainedAcceptedObservations=31,
        pauseClickDrainedSource=True, pauseStoppedProviderCalls=True, pauseStoppedSamples=True,
        pausedHeight=888, pausedOffset=408, pausedAcceptedObservations=31, pausedPreviewPixelsPreserved=True,
        pausedSourceRegionPreserved=True, pausedLabel='继续捕获', nativeResumeRejoined=True, sourcePacingMaximumSeconds=2,
        activeAppearanceEvidence={a: 'live-scroll-rejected-move-active-' + a + '.png' for a in ('light', 'dark')},
        pausedAppearanceEvidence={a: 'live-scroll-rejected-move-paused-' + a + '.png' for a in ('light', 'dark')})
    result['automaticCase'].update(productSessionControllerExercised=True,
        sessionSamplingLoopReimplementedByFixture=False, automaticInputLoopReimplementedByFixture=False,
        captureMode='injected-rendered-owned-window', globalInputPosted=False, realScreenCaptureClaimed=False,
        permissionRequested=False, autoDisabledBeforeVerifiedSeed=True, nativeAutoButtonStartedSession=True,
        nativeStopButtonStoppedInput=True, nativeAutoButtonRestartedSession=True,
        manualCaptureActiveAfterStopButton=True, manualCaptureActiveAfterNoProgress=True,
        manualRecoveryAfterNoProgress=True, noProgressStoppedAtNativeEnd=True, noProgressTerminalInputCount=1,
        matchedForwardProgressBeforeEveryFollowingInput=True, completionCallbacksBeforeFinish=0,
        outputWidth=640, outputHeight=1120, fixedHeaderDetectedPixels=36, ownedWindowClosed=True,
        noProgressStopSecondsSinceLastInput=3.1, minimumAutomaticIntervalWithinRunSeconds=.4, minimumAutomaticIntervalSeconds=.4,
        nativeAutomaticInputCount=12, observedGrowingPreviewUpdates=9, storyFrames=24,
        referenceInitialViewportCalibration=copy.deepcopy(comparison))
    result['outputCase'] = output_demo()
    return result


def output_demo():
    def comparison(height):
        return dict(passed=True, dimensionsMatch=True, exactCanonicalRGBAEquality=True, width=480,
                    height=height, expectedWidth=480, expectedHeight=height,
                    outputPixelSHA256='a'*64, sourcePixelSHA256='a'*64)
    def artifacts():
        return [dict(appearance=x, filename='output-fixture-'+x+'.png', width=480, height=60) for x in ('light','dark')]
    filename = 'owned-long-output-' + 'capture-segment-' * 6 + '长截图保存结果-1.png'
    saved_path = '/private/tmp/PicShot-LiveOutput-owned/saved/' + filename
    def feedback_artifacts(width):
        def rect(x, y, w, h): return dict(x=x, y=y, width=w, height=h)
        stem = 'output-save-feedback-' if width == 460 else 'output-save-feedback-narrow-'
        return [dict(appearance=appearance, filename=stem+appearance+'.png', width=width, height=190,
            canonicalRGBAPixelSHA256=('c' if appearance == 'light' else 'd')*64,
            layout=dict(passed=True, contentBounds=rect(0, 0, width, 190),
                windowVisible=True, controlsVisible=True,
                frames=dict(status=rect(18, 152, width-36, 20), detail=rect(18, 128, width-36, 18),
                            note=rect(18, 78, width-36, 32), close=rect(width-88, 32, 70, 32)),
                statusText='文件已安全保存', statusAccessibilityValue='文件已安全保存',
                statusRequiredTextHeight=20, statusRequiredUntruncatedWidth=110, noteRequiredTextHeight=32,
                detailRequiredUntruncatedWidth=1200, detailText=saved_path, detailToolTip=saved_path,
                detailAccessibilityValue=saved_path, detailMaximumNumberOfLines=1, detailTruncatesMiddle=True))
            for appearance in ('light', 'dark')]
    return dict(status='passed', productSessionClosed=True, privateTemporaryRootRemoved=True, cleanupSafe=True,
        canonicalPrivateTemporaryRoot=True, realScreenCaptureClaimed=False, screenCaptureAPICalled=False,
        permissionRequested=False, globalInputPosted=False, networkUsed=False,
        userHistoryReadOrWritten=False, standardDefaultsReadOrWritten=False, generalPasteboardReadOrWritten=False,
        stitchedCopyFailureThenSave=dict(status='passed', productSessionClosed=True, saveJobsDrained=True,
            cleanupSafe=True, copyFailurePausedDraftAndAlternativePreserved=True, savePublicationRetiredSession=True,
            savedInsideApprovedPrivateDirectory=True, independentPublishedPNGDecode=True,
            copyRecipientAttempts=1, saveJobAdmissions=1, editorCallbacks=0, importCallbacks=0,
            saveMenuIdentifier='scroll.live.quickSave', saveSelector='quickSavePressed',
            rejectedCopyComparison=comparison(704), savedPNGComparison=comparison(704),
            savedPath=saved_path, savedFilename=filename, saveFeedback='文件已安全保存',
            controlArtifacts=artifacts(), saveFeedbackArtifacts=feedback_artifacts(460),
            saveFeedbackNarrowArtifacts=feedback_artifacts(320)),
        singleViewportPin=dict(status='passed', productSessionClosed=True, pinControllersClosed=True,
            cleanupSafe=True, singleViewportUnchanged=True, persistedAndReopened=True, independentPublishedPNGDecode=True, pinCallbacks=1,
            unexpectedCallbacks=0, visibleNativePinCount=1, menuIdentifier='scroll.live.pin', selector='pinPressed',
            publishedPinComparison=comparison(320), reopenedPinComparison=comparison(320),
            controlArtifacts=artifacts(), nativePinArtifacts=artifacts()))


class ExperimentalInteractionTests(unittest.TestCase):
    def test_output_rejection_lost_draft_duplicate_callback_and_changed_pixels_fail(self):
        for path, value in [
            (('stitchedCopyFailureThenSave','copyFailurePausedDraftAndAlternativePreserved'), False),
            (('stitchedCopyFailureThenSave','saveJobAdmissions'), 2),
            (('singleViewportPin','persistedAndReopened'), False),
            (('singleViewportPin','pinCallbacks'), 2),
            (('singleViewportPin','reopenedPinComparison','sourcePixelSHA256'), 'b'*64),
            (('stitchedCopyFailureThenSave','savedPNGComparison','height'), 703),
        ]:
            with self.subTest(path=path):
                row=output_demo(); parent=row
                for key in path[:-1]: parent=parent[key]
                parent[path[-1]]=value
                with self.assertRaises(ValueError): C.output_fields(row)
        for key in output_demo():
            changed=output_demo(); del changed[key]
            with self.subTest(missing=key), self.assertRaises(ValueError): C.output_fields(changed)

    def test_output_native_appearances_and_safe_paths_are_required(self):
        for value in [[], [dict(appearance='light')],
                      [dict(appearance=x,filename='../outside.png',width=480,height=60) for x in ('light','dark')]]:
            changed=output_demo(); changed['stitchedCopyFailureThenSave']['controlArtifacts']=value
            with self.assertRaises(ValueError): C.output_fields(changed)

    def test_save_feedback_missing_and_invalid_geometry_fail_closed(self):
        for key in ('saveFeedbackArtifacts', 'saveFeedbackNarrowArtifacts'):
            baseline = output_demo()['stitchedCopyFailureThenSave'][key][0]
            paths = []
            def visit(row, path=()):
                for name, value in row.items():
                    current = path + (name,)
                    paths.append(current)
                    if type(value) is dict: visit(value, current)
            visit({name: value for name, value in baseline.items() if name != 'appearance'})
            for path in paths:
                for replacement in ('DELETE', None, float('nan'), True):
                    if replacement is True and self.lookup(baseline, path) is True: continue
                    with self.subTest(artifacts=key, path=path, replacement=replacement):
                        changed = output_demo(); artifact = changed['stitchedCopyFailureThenSave'][key][0]
                        row = artifact
                        for name in path[:-1]: row = row[name]
                        if replacement == 'DELETE': del row[path[-1]]
                        else: row[path[-1]] = replacement
                        with self.assertRaises(ValueError): C.output_fields(changed)

    def test_save_feedback_rejects_clipping_overlap_and_path_lost_from_accessibility(self):
        mutations = [
            (('frames', 'status', 'y'), 175),
            (('frames', 'detail', 'x'), -1),
            (('frames', 'note', 'width'), 460),
            (('frames', 'close', 'height'), 170),
            (('frames', 'detail', 'y'), 145),
            (('statusRequiredTextHeight',), 20.51),
            (('noteRequiredTextHeight',), 32.51),
            (('statusRequiredUntruncatedWidth',), 1000),
            (('detailRequiredUntruncatedWidth',), 200),
            (('statusText',), '/private/tmp/a-long-path.png 文件已安全保存'),
            (('statusAccessibilityValue',), ''),
            (('detailText',), '…/result.png'),
            (('detailToolTip',), '…/result.png'),
            (('detailAccessibilityValue',), '…/result.png'),
            (('detailMaximumNumberOfLines',), 3),
            (('detailTruncatesMiddle',), False),
            (('windowVisible',), False),
            (('controlsVisible',), False),
            (('passed',), False),
        ]
        for key in ('saveFeedbackArtifacts', 'saveFeedbackNarrowArtifacts'):
            for index in (0, 1):
                for path, value in mutations:
                    with self.subTest(artifacts=key, index=index, path=path):
                        changed = output_demo(); row = changed['stitchedCopyFailureThenSave'][key][index]['layout']
                        for name in path[:-1]: row = row[name]
                        row[path[-1]] = value
                        with self.assertRaises(ValueError): C.output_fields(changed)
        changed = output_demo()
        layout = changed['stitchedCopyFailureThenSave']['saveFeedbackArtifacts'][0]['layout']
        layout['statusRequiredTextHeight'] = 20.5
        C.output_fields(changed)  # A half point of native rounding, never an extra line.

    def test_save_feedback_requires_both_widths_appearances_and_bounded_mixed_script_path(self):
        for key in ('saveFeedbackArtifacts', 'saveFeedbackNarrowArtifacts'):
            for value in ([], None):
                changed = output_demo(); changed['stitchedCopyFailureThenSave'][key] = value
                with self.assertRaises(ValueError): C.output_fields(changed)
            for field, value in [('width', 461), ('height', 191), ('appearance', 'light'),
                                 ('filename', '../outside.png'), ('canonicalRGBAPixelSHA256', 'broken')]:
                changed = output_demo(); changed['stitchedCopyFailureThenSave'][key][1][field] = value
                with self.subTest(key=key, field=field), self.assertRaises(ValueError): C.output_fields(changed)
        for field, value in [('savedPath', 'relative/path.png'), ('savedPath', '/'+'a'*1024),
                             ('savedFilename', 'short.png'), ('savedFilename', 'a'*181+'.png'),
                             ('saveFeedback', '已完成')]:
            changed = output_demo(); changed['stitchedCopyFailureThenSave'][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError): C.output_fields(changed)

    def test_complete_interaction_contract_without_memory_eligibility(self):
        C.demo_fields(demo())
        for key in ('installerAcceptance', 'fullMemoryQualification', 'testingPackageEligible',
                    'partialMemoryQualification', 'disputedResourceCellRerun', 'scrollingResourceClassifierRun',
                    'publicRelease', 'mainMerged'):
            self.assertIs(C.FLAGS[key], False)
        self.assertIs(C.FLAGS['stable214Unchanged'], True)
        self.assertEqual(C.PRIOR_FAILURE, dict(runID='38130153505', build=227, warmRSSBytes=10780672,
            warmLimitBytes=9830400, lateThreeRSSBytes=5177344, lateLimitBytes=4915200, preserved=True))

    def test_missing_invalid_or_boolean_like_fields_fail_closed(self):
        value = demo()
        paths = []
        def visit(row, parent=()):
            for key, child in row.items():
                path = parent + (key,)
                if isinstance(child, dict):
                    paths.append(path); visit(child, path)
                else:
                    paths.append(path)
        visit(value)
        for path in paths:
            for replacement in ('DELETE', None, 'passed' if type(self.lookup(value, path)) is bool else float('nan')):
                with self.subTest(path=path, replacement=replacement):
                    changed = copy.deepcopy(value); row = changed
                    for key in path[:-1]: row = row[key]
                    if replacement == 'DELETE': del row[path[-1]]
                    else: row[path[-1]] = replacement
                    with self.assertRaises((ValueError, KeyError, TypeError)):
                        C.demo_fields(changed)
        for path in [('movementCase', 'matchedMoveDisplacement'), ('movementCase', 'drag', 'alongAxisDelta')]:
            changed = copy.deepcopy(value); row = changed
            for key in path[:-1]: row = row[key]
            row[path[-1]] = True
            with self.assertRaises(ValueError): C.demo_fields(changed)

    @staticmethod
    def lookup(value, path):
        for key in path: value = value[key]
        return value

    def test_illustrated_gap_fields_are_emitted_and_reject_missing_or_false(self):
        source=(REPO/'Sources/PicShot/LiveScrollUsabilityDemoFixture.swift').read_text()
        for key in ('gapMarkerUnverified', 'gapMarkerAmber',
                    'gapAccessibilityDescribesUnverifiedPosition', 'gapRecoveryMarkerVerified',
                    'gapRecoveryMarkerGreen', 'gapRecoveryAccessibilityDescribesVerifiedPosition'):
            self.assertIn('report["'+key+'"]',source)
            for remove in (True,False):
                with self.subTest(field=key,missing=remove):
                    changed=demo()
                    if remove:del changed['illustratedCase'][key]
                    else:changed['illustratedCase'][key]=False
                    with self.assertRaises(ValueError):C.demo_fields(changed)

    def test_stationary_preview_and_rejected_move_require_every_native_observation(self):
        for case, key in [('illustratedCase', 'stationaryPreviewRecovery'), ('movementCase', 'rejectedMovePause')]:
            baseline = demo()[case][key]
            for field, value in baseline.items():
                mutations = ['DELETE']
                if type(value) is bool: mutations += [not value, int(value)]
                elif type(value) is int: mutations += [True, -1, float(value), float('nan')]
                elif type(value) is str: mutations += ['wrong']
                for mutation in mutations:
                    with self.subTest(case=case, field=field, mutation=mutation):
                        changed = demo()
                        if mutation == 'DELETE': del changed[case][key][field]
                        else: changed[case][key][field] = mutation
                        with self.assertRaises(ValueError): C.demo_fields(changed)
            for key2 in (x for x in baseline if x.endswith('AppearanceEvidence')):
                for appearance in ('light', 'dark'):
                    for mutation in ('DELETE', 'unrelated.png', '../escape.png'):
                        changed = demo()
                        if mutation == 'DELETE': del changed[case][key][key2][appearance]
                        else: changed[case][key][key2][appearance] = mutation
                        with self.assertRaises(ValueError): C.demo_fields(changed)
        for value in (False, 1, None):
            changed = demo(); changed['movementCase']['ownedSourceStopped'] = value
            with self.assertRaises(ValueError): C.demo_fields(changed)

    def test_stationary_recovery_cannot_accept_motion_rearm_auto_or_change_output(self):
        for field in ('recoveryAcceptedObservations', 'recoveryOffset', 'recoveryHeight', 'recoveryNativeOffset',
                      'beforeFailureAcceptedObservations', 'beforeFailureOffset', 'failureNativeOffset'):
            changed = demo(); changed['illustratedCase']['stationaryPreviewRecovery'][field] += 1
            with self.assertRaises(ValueError): C.demo_fields(changed)
        for field, value in [('nativeWheelEventsDuringRecovery', 1), ('recoveryAutoOff', False),
                             ('recoveryAutoLabel', '停止自动滚动'), ('stationaryFramesObserved', 0)]:
            changed = demo(); changed['illustratedCase']['stationaryPreviewRecovery'][field] = value
            with self.assertRaises(ValueError): C.demo_fields(changed)
        for field in ('pausedHeight', 'pausedOffset', 'pausedAcceptedObservations'):
            changed = demo(); changed['movementCase']['rejectedMovePause'][field] += 1
            with self.assertRaises(ValueError): C.demo_fields(changed)
        for field, value in [('activePauseLabel', '重试捕获'), ('activePauseTooltip', '重试捕获'),
                             ('resumeCallsAfterRejection', 0), ('pauseCallsForDrag', 2), ('pauseClickDrainedSource', False)]:
            changed = demo(); changed['movementCase']['rejectedMovePause'][field] = value
            with self.assertRaises(ValueError): C.demo_fields(changed)

    def test_wrong_drag_or_falsely_verified_stale_preview_rejected(self):
        for path in [('movementCase', 'moveAppliedThroughMouseRelease'),
                     ('movementCase', 'duringDrag', 'previewPositionUnverified'),
                     ('movementCase', 'duringDrag', 'previewMarkerAmber'),
                     ('movementCase', 'duringDrag', 'previewAccessibilityUnverified'),
                     ('movementCase', 'escapeRollback', 'trailingMouseUpIgnored')]:
            with self.subTest(path=path):
                changed=demo(); row=changed
                for key in path[:-1]: row=row[key]
                row[path[-1]]=False
                with self.assertRaises(ValueError): C.demo_fields(changed)
        changed=demo();changed['movementCase']['moveAppliedThroughReturn']=True
        with self.assertRaises(ValueError): C.demo_fields(changed)

    def test_selected_prefix_is_exact_and_has_no_resource_command(self):
        original=(REPO/C.SCRIPT).read_bytes(); prefix=C.selected_prefix(original)
        self.assertEqual(prefix+C.OMITTED, original)
        self.assertNotIn(b'run-live-scroll-resource',prefix)
        self.assertEqual(hashlib.sha256(prefix).hexdigest(), C.PREFIX_SHA)
        for invalid in (original+b'\n', original.replace(C.OMITTED,b''),
                        C.OMITTED+original, original.replace(b'660',b'661')):
            with self.assertRaises(ValueError):C.selected_prefix(invalid)

    def test_selected_prefix_execution_never_calls_memory_cell(self):
        # Execute the actual selected Bash prefix with no-op owned tool fixtures.
        # Any resource command would appear in the call log and fail the test.
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'scripts').mkdir();(root/'dist').mkdir();(root/'bin').mkdir()
            for command in ('ditto','codesign','python3'):
                stub=root/'bin'/command
                stub.write_text('#!/bin/bash\nprintf "%s\\n" "$0 $*" >> "$CALL_LOG"\n')
                stub.chmod(0o755)
            guard=root/'scripts/run-live-scroll-resource.sh'
            guard.write_text('#!/bin/bash\necho RESOURCE >> "$CALL_LOG"\nexit 99\n')
            environment=dict(os.environ, PATH=str(root/'bin')+os.pathsep+os.environ['PATH'], CALL_LOG=str(root/'calls'))
            result=subprocess.run(['bash','-c',C.selected_prefix((REPO/C.SCRIPT).read_bytes()).decode(),
                                   'scripts/live-scroll-installed.sh','unused.zip',str(root/'evidence'),'a'*40],
                                  cwd=root,env=environment,capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,0,result.stderr)
            calls=(root/'calls').read_text()
            self.assertNotIn('RESOURCE',calls)
            self.assertNotIn('run-live-scroll-resource',calls)
            self.assertNotIn('classify-live-scroll-testing',calls)
            self.assertIn('--timeout-seconds 660',calls)

    def test_every_required_gate_success_and_resource_classification_skipped(self):
        rows={name:dict(outcome='success',conclusion='success') for name in C.REQUIRED_GATES}
        rows.update({name:dict(outcome='skipped',conclusion='skipped') for name in
                     ('live_scroll_resource','scroll_testing_classification','scroll_testing_contract')})
        C.validate_outcomes(rows)
        for name in rows:
            for state in ('missing','failure','cancelled','success' if name.startswith(('live_scroll','scroll_testing')) else 'skipped'):
                with self.subTest(name=name,state=state):
                    changed=copy.deepcopy(rows)
                    if state=='missing':del changed[name]
                    else:changed[name]['outcome']=state
                    with self.assertRaises(ValueError):C.validate_outcomes(changed)

    def test_resource_or_classifier_evidence_is_forbidden(self):
        with tempfile.TemporaryDirectory() as tmp:
            previous=Path.cwd();os.chdir(tmp)
            try:
                C.forbid_resource()
                for path in (C.EVIDENCE/'resource',Path('dist/live-scroll-testing-qualification.json')):
                    path.parent.mkdir(parents=True,exist_ok=True);path.touch()
                    with self.assertRaises(ValueError):C.forbid_resource()
                    path.unlink()
            finally:os.chdir(previous)

    def test_duplicate_json_and_nonfinite_numbers_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'report.json'
            for raw in ('{"status":"passed","status":"failed"}', '{"value":NaN}', '{"value":Infinity}'):
                path.write_text(raw)
                with self.assertRaises(ValueError):C.load(path)

    def test_recovery_png_requires_decodable_bounded_raster(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'recovery.png'
            valid = fixture_png(); path.write_bytes(valid)
            self.assertEqual(C.recovery_png(path), (2, 2, bytes((24, 80, 160, 255))*4))
            for name, invalid in malformed_recovery_pngs(valid).items():
                with self.subTest(mutation=name):
                    path.write_bytes(invalid)
                    with self.assertRaises(ValueError): C.recovery_png(path)
            for width, height in ((0, 2), (2, 0), (4097, 1), (1, 4097), (2001, 2000)):
                # Oversized declarations fail before allocating/decoding a raster.
                invalid = (valid[:8] + png_chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
                           + valid[33:])
                path.write_bytes(invalid)
                with self.assertRaises(ValueError): C.recovery_png(path)
            # Valid chunks/CRCs do not excuse an invalid compressed raster length.
            invalid = (valid[:33] + png_chunk(b'IDAT', zlib.compress(b'\0' + bytes(4))) + png_chunk(b'IEND', b''))
            path.write_bytes(invalid)
            with self.assertRaises(ValueError): C.recovery_png(path)
            path.write_bytes(valid)
            with path.open('r+b') as handle: handle.truncate(16*1024**2+1)
            with self.assertRaises(ValueError): C.recovery_png(path)

    def test_qualify_rejects_identity_and_runner_mutations(self):
        with tempfile.TemporaryDirectory() as tmp:
            previous=Path.cwd();os.chdir(tmp)
            try:
                source=dict(sourceCommit='a'*40,build='232',version='0.22.0',architecture='arm64',
                            executableSHA256='b'*64,packages=dict(zip=dict(path=str(Path('input.zip').resolve()),sha256='c'*64)))
                app=str(Path('installed/PicShot.app').resolve())
                installed=dict(status='passed',bundlePath=app,executablePath=app+'/Contents/MacOS/PicShot',
                               archiveSHA256='c'*64,**{key:source[key] for key in
                               ('sourceCommit','build','version','architecture','executableSHA256')})
                d=demo();d.update(bundlePath=app,**{key:source[key] for key in ('sourceCommit','build','version')})
                prefix=C.selected_prefix((REPO/C.SCRIPT).read_bytes())
                C.ROOT.mkdir(parents=True);(C.ROOT/'installed-demo-prefix.sh').write_bytes(prefix)
                outer=dict(status='exited',child_returncode=0,exit_code=0,cancel_signal=None,
                           sigterm_sent=False,sigkill_sent=False,descendant_cleanup=False,
                           termination_reason='exited',log_truncated=False,timeout_seconds=780.0,
                           grace_seconds=10.0,duration_seconds=100.0,
                           command=['bash','-c',prefix.decode().rstrip('\n'),str(C.SCRIPT),
                                    source['packages']['zip']['path'],str(C.EVIDENCE.resolve()),source['sourceCommit']])
                inner=dict(outer,timeout_seconds=660.0, command=['swift','scripts/launch-smoke-app.swift',
                           app,str((C.EVIDENCE/'demo/demo.json').resolve())])
                launcher=dict(status='exited',launcherExitCode=0,callbackReceived=True,
                    createsNewApplicationInstance=True,ownedExitConfirmed=True,launchedIdentityMatches=True,
                    timeoutSeconds=600,selectedAppPath=app,launchedAppPath=app,
                    launchedExecutablePath=installed['executablePath'],processIdentifier=123,elapsedSeconds=80.0)
                output_root=C.EVIDENCE/'demo/output-actions';output_root.mkdir(parents=True)
                visual=fixture_png()
                output=d['outputCase']
                output['stitchedCopyFailureThenSave']['savedPNGFileSHA256']=hashlib.sha256(visual).hexdigest()
                output['singleViewportPin']['pinPNGFileSHA256']=hashlib.sha256(visual).hexdigest()
                names={'output-owned-numbered-reference.png','output-published-long.png','output-published-single-pin.png'}
                for row,key in [(output['stitchedCopyFailureThenSave'],'controlArtifacts'),
                                (output['stitchedCopyFailureThenSave'],'saveFeedbackArtifacts'),
                                (output['stitchedCopyFailureThenSave'],'saveFeedbackNarrowArtifacts'),
                                (output['singleViewportPin'],'controlArtifacts'),(output['singleViewportPin'],'nativePinArtifacts')]:
                    names.update(x['filename'] for x in row[key])
                for name in names:(output_root/name).write_bytes(visual)
                C.save(output_root/'live-scroll-output.json',output)
                C.save(output_root/'output-save-feedback-layout.json',
                       dict(normal=output['stitchedCopyFailureThenSave']['saveFeedbackArtifacts'],
                            narrow=output['stitchedCopyFailureThenSave']['saveFeedbackNarrowArtifacts']))
                records={C.EVIDENCE/'package-identity.json':installed,C.EVIDENCE/'demo/demo.json':d,
                         C.EVIDENCE/'demo/demo.json.launcher.json':launcher,
                         C.EVIDENCE/'demo-launch.json':inner,Path('dist/experimental-scroll-installed-report.json'):outer}
                for path,value in records.items():C.save(path,value)
                for filename in ('live-scroll-movement-native-drag.png','live-scroll-movement-native-dark-drag.png',
                                 'live-scroll-movement-native-rollback.png','live-scroll-movement-finished.png',
                                 'live-scroll-movement-reference.png','live-scroll-movement-interaction.gif'):
                    path=C.EVIDENCE/'demo/movement'/filename;path.parent.mkdir(exist_ok=True)
                    path.write_bytes(visual if filename.endswith('.png') else b'GIF89afixture')
                recovery_paths = [C.EVIDENCE/'demo'/name for name in C.PREVIEW_RECOVERY_VISUALS]
                recovery_paths += [C.EVIDENCE/'demo/movement'/name for name in C.REJECTED_MOVE_VISUALS]
                for path in recovery_paths: path.write_bytes(visual)
                with patch.object(C,'source_record',return_value=source):
                    receipt=C.qualify();self.assertEqual(receipt['status'],'passed')
                    self.assertTrue(receipt['stationaryPreviewRecoveryAndRejectedMovePauseVerified'])
                    for path in recovery_paths:
                        self.assertIn(str(path), receipt['evidenceSHA256'])
                        path.unlink()
                        with self.assertRaises(ValueError): C.qualify()
                        for mutation, invalid in dict(not_png=b'not a PNG', **malformed_recovery_pngs(visual)).items():
                            with self.subTest(visual=path.name, mutation=mutation):
                                path.write_bytes(invalid)
                                with self.assertRaises(ValueError): C.qualify()
                        path.write_bytes(visual)
                    layout_path=output_root/'output-save-feedback-layout.json'
                    layout=C.load(layout_path);changed_layout=copy.deepcopy(layout)
                    del changed_layout['narrow'][1]['layout']['statusRequiredTextHeight']
                    C.save(layout_path,changed_layout)
                    with self.assertRaises(ValueError):C.qualify()
                    C.save(layout_path,layout)
                    narrow_image=output_root/output['stitchedCopyFailureThenSave']['saveFeedbackNarrowArtifacts'][1]['filename']
                    narrow_image.unlink()
                    with self.assertRaises(ValueError):C.qualify()
                    narrow_image.write_bytes(visual)
                    for path,value in records.items():
                        for key in value:
                            if key in ('illustratedCase','ordinaryTextCase','movementCase','realStream'):continue
                            with self.subTest(file=path,key=key):
                                changed=copy.deepcopy(value);del changed[key];C.save(path,changed)
                                with self.assertRaises((ValueError,KeyError,TypeError)):C.qualify()
                                C.save(path,value)
                    for key in ('archiveSHA256','executableSHA256','sourceCommit','build','architecture'):
                        changed=dict(installed);changed[key]='wrong';C.save(C.EVIDENCE/'package-identity.json',changed)
                        with self.assertRaises(ValueError):C.qualify()
                    C.save(C.EVIDENCE/'package-identity.json',installed)
                    changed=dict(outer);changed['command']=['bash',str(C.SCRIPT)]
                    C.save(Path('dist/experimental-scroll-installed-report.json'),changed)
                    with self.assertRaises(ValueError):C.qualify()
            finally:os.chdir(previous)

    def test_source_record_rejects_changed_source_build_package_and_prefix(self):
        with tempfile.TemporaryDirectory() as tmp:
            previous=Path.cwd();os.chdir(tmp)
            try:
                identity=dict(sourceCommit='a'*40,build='232',workflowSHA256='b'*64)
                package=dict(packages=dict(zip=dict(sha256='c'*64)))
                C.SCRIPT.parent.mkdir();C.SCRIPT.write_bytes((REPO/C.SCRIPT).read_bytes())
                C.save(C.ROOT/'source-identity.json',dict(identity,**package))
                (C.ROOT/'installed-demo-prefix.sh').write_bytes(C.selected_prefix(C.SCRIPT.read_bytes()))
                with patch.object(C,'context',return_value=identity),patch.object(C,'packages',return_value=package):
                    self.assertEqual(C.source_record(),dict(identity,**package))
                    for changed in (dict(identity,sourceCommit='d'*40,**package),
                                    dict(identity,build='233',**package),
                                    dict(identity,packages=dict(zip=dict(sha256='e'*64)))):
                        C.save(C.ROOT/'source-identity.json',changed)
                        with self.assertRaises(ValueError):C.source_record()
                    C.save(C.ROOT/'source-identity.json',dict(identity,**package))
                    (C.ROOT/'installed-demo-prefix.sh').write_bytes(b'echo omitted')
                    with self.assertRaises(ValueError):C.source_record()
            finally:os.chdir(previous)

    def test_bounded_evidence_archive_and_oversized_file_rejection(self):
        with tempfile.TemporaryDirectory() as tmp:
            previous=Path.cwd();os.chdir(tmp)
            try:
                C.save(C.ROOT/'source-identity.json',dict(syntheticFixture=True))
                C.archive()
                result=Path('dist/experimental-scroll-evidence/evidence.zip')
                self.assertTrue(result.is_file());self.assertLess(result.stat().st_size,20*1024**2)
                result.unlink()
                huge=C.ROOT/'oversized'
                with huge.open('wb') as output:output.truncate(18*1024**2)
                with self.assertRaises(ValueError):C.archive()
            finally:os.chdir(previous)


class WorkflowSelectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow=(REPO/'.github/workflows/macos.yml').read_text()
        cls.build=cls.workflow.split('  build:\n',1)[1].split('\n  codec-dependencies:',1)[0]
        cls.steps={part.splitlines()[0]:part for part in cls.build.split('      - name: ')[1:]}

    def test_opt_in_resource_and_classifier_are_mutually_exclusive(self):
        for name in ('Verify continuous scrolling and bounded resources from the actual ZIP',
                     'Classify explicit scrolling testing eligibility without changing resource results',
                     'Check explicit live scrolling testing classification',
                     'Record testing-only distribution after all remaining qualification steps',
                     'Check split installer transfer budgets','Upload ZIP installer and provenance',
                     'Upload DMG installer and provenance'):
            condition=next(line for line in self.steps[name].splitlines() if line.strip().startswith('if:'))
            self.assertIn("!contains(github.event.head_commit.message || '', '"+C.MARKER+"')",condition)
        step=self.steps['Verify current experimental scrolling interactions from the actual ZIP']
        self.assertIn('installed-demo-prefix.sh',step)
        self.assertNotIn('-- bash scripts/live-scroll-installed.sh',step)
        self.assertNotIn('run-live-scroll-resource',step)
        self.assertIn('-- bash -c "$picshot_scroll_prefix" scripts/live-scroll-installed.sh',step)

    def test_all_ordinary_commands_before_final_are_required(self):
        final='Record current experimental distribution after every ordinary remaining gate'
        excluded={'Check explicit live scrolling testing classification',
                  'Verify continuous scrolling and bounded resources from the actual ZIP',
                  'Classify explicit scrolling testing eligibility without changing resource results'}
        required=[]
        for name,step in self.steps.items():
            if name==final:break
            if '\n        run:' in step and name not in excluded:
                match=re.search(r'^        id: (\w+)$',step,re.M)
                self.assertIsNotNone(match,name);required.append(match.group(1))
        self.assertEqual(set(required),set(C.REQUIRED_GATES))
        self.assertIn('bash scripts/smoke.sh',self.steps['Install and launch both formats, render native UI, measure repeated cycles'])
        smoke=(REPO/'scripts/smoke.sh').read_text()
        self.assertIn('editable-product-installed-default.sh',smoke)
        self.assertIn('for format in zip dmg',smoke)
        for extension in ('ZIP','DMG'):
            step=self.steps['Upload current experimental '+extension+' installer and provenance']
            self.assertIn("success() && contains",step)
            self.assertIn("steps.experimental_scroll_distribution.outcome == 'success'",step)
            self.assertIn('PicShot-EXPERIMENTAL-macos-',step)
            self.assertNotIn('testing-qualification.json',step)

    def test_current_2375_inventory_and_original_2047_ids(self):
        # Same portable source sentinel as native-test-shards; actual discovery
        # and all current native IDs still execute in the unchanged workflow.
        inventory=[]
        for path in sorted((REPO/'Tests').rglob('*.swift')):
            source=path.read_text()
            if source.startswith('#if PICSHOT_CALLOUT_RETIREMENT_DIAGNOSTICS\n'):continue
            methods=re.findall(r'\bfunc\s+(test\w+)\s*\(',source)
            if not methods:continue
            classes=re.findall(r'\bclass\s+(\w+)\s*:\s*\w*TestCase\b',source)
            self.assertEqual(len(classes),1,str(path))
            module=path.relative_to(REPO/'Tests').parts[0]
            inventory.extend(module+'.'+classes[0]+'/'+method for method in methods)
        inventory=sorted(inventory)
        self.assertEqual(len(inventory),2407)
        self.assertEqual(len(set(inventory)),2407)
        self.assertEqual(len({name.split('/')[0] for name in inventory}),267)
        self.assertEqual(hashlib.sha256(('\n'.join(inventory)+'\n').encode()).hexdigest(),
                         '89da6aece2514cafafdeea83cebf09a2a927400df4ee4cc4324d923183cf1b9a')
        payload=json.loads((REPO/'scripts/save-payload-native-tests.json').read_text())
        with patch.object(C,'load',return_value=payload):
            payload_added=C.save_payload_additions(inventory)
        self.assertEqual((len(payload_added),len(payload['focused'])),(25,93))
        preserved265=[name for name in inventory if name not in payload_added]
        self.assertEqual(len(preserved265),2382)
        self.assertEqual(hashlib.sha256(('\n'.join(preserved265)+'\n').encode()).hexdigest(),
                         'a88b82f2a8e8828ee7e0ce31b52340106f32f37b8e831599d2859281ed876f7c')
        for bad in ({}, {**payload,'added':payload['added'][:-1]},
                    {**payload,'focused':payload['focused'][:-1]}, {**payload,'unexpected':0}):
            with patch.object(C,'load',return_value=bad),self.assertRaises(ValueError):
                C.save_payload_additions(inventory)
        for changed in ([name for name in inventory if name!=payload['focused'][0]],
                        sorted(inventory+['PicShotTests.SaveWorkflowUITests/testUnrecorded'])):
            with patch.object(C,'load',return_value=payload),self.assertRaises(ValueError):
                C.save_payload_additions(changed)
        recovery=set(C.SCROLL_RECOVERY_ADDITIONS)
        self.assertEqual(len(recovery),7);self.assertTrue(recovery.issubset(inventory))
        baseline=[name for name in preserved265 if name not in recovery]
        self.assertEqual((len(baseline),len({name.split('/')[0] for name in baseline})),(2375,267))
        self.assertEqual(hashlib.sha256(('\n'.join(baseline)+'\n').encode()).hexdigest(),
                         '0f19081756c225e5b0fede62805ee01693d1409bf6552979ac74db409e3e4aab')
        live=json.loads((REPO/'scripts/live-scroll-additive-tests.json').read_text())
        self.assertEqual(len(live),165);self.assertTrue(set(live).issubset(inventory))
        self.assertTrue(recovery.issubset(live))
        prior_live=[name for name in live if name not in recovery and name not in payload_added]
        self.assertEqual(len(prior_live),156)
        self.assertEqual(hashlib.sha256(('\n'.join(prior_live)+'\n').encode()).hexdigest(),
                         'a9c4eb4840fe1716651b164c9fc4c27c639738360adcb1a1d20030366b682f64')
        feedback=json.loads((REPO/'scripts/save-feedback-native-tests.json').read_text())
        with patch.object(C,'load',side_effect=lambda path: payload if path.name=='save-payload-native-tests.json' else feedback):
            feedback_added=C.feedback_additions(inventory)
        self.assertEqual(len(feedback_added),5)
        chain=json.loads((REPO/'scripts/capture-chain-native-tests.json').read_text())
        with patch.object(C,'load',side_effect=lambda path: payload if path.name=='save-payload-native-tests.json' else chain):
            chain_added=C.chain_additions(inventory)
        self.assertEqual(len(chain_added),95)
        for bad in ({}, {'added':chain['added'][:-1], 'focused':chain['focused']},
                    {**chain,'unexpected':0}):
            with patch.object(C,'load',side_effect=lambda path: payload if path.name=='save-payload-native-tests.json' else bad), self.assertRaises(ValueError):
                C.chain_additions(inventory)
        script_ids=json.loads((REPO/'scripts/text-script-integration-tests.json').read_text())
        with patch.object(C,'read',side_effect=lambda path: (REPO/path).read_bytes()):
            script_added=C.text_script_additions(inventory)
        self.assertEqual(len(script_added),72)
        original=[name for name in inventory if name not in set(live) | feedback_added | chain_added | script_added | payload_added]
        self.assertEqual(len(original),2047)
        self.assertEqual(hashlib.sha256(('\n'.join(original)+'\n').encode()).hexdigest(),
                         '926ac5674df90163b949fe461f0d4589ef72c8fc3215fa00b927564aae57cb44')


if __name__=='__main__':unittest.main()
