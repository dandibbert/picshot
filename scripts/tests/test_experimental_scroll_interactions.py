"""Adversarial portable contracts; synthetic receipts are never macOS evidence."""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('experimental', REPO/'scripts/check-experimental-scroll-interactions.py')
C = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(C)


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
                visual=b'\x89PNG\r\n\x1a\nfixture'
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
                    path.write_bytes(b'\x89PNG\r\n\x1a\nfixture' if filename.endswith('.png') else b'GIF89afixture')
                with patch.object(C,'source_record',return_value=source):
                    receipt=C.qualify();self.assertEqual(receipt['status'],'passed')
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

    def test_current_2208_inventory_and_original_2047_ids(self):
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
        self.assertEqual(len(inventory),2303)
        self.assertEqual(len(set(inventory)),2303)
        live=json.loads((REPO/'scripts/live-scroll-additive-tests.json').read_text())
        self.assertEqual(len(live),156);self.assertTrue(set(live).issubset(inventory))
        feedback=json.loads((REPO/'scripts/save-feedback-native-tests.json').read_text())
        with patch.object(C, 'load', return_value=feedback):
            feedback_added=C.feedback_additions(inventory)
        self.assertEqual(len(feedback_added),5)
        chain=json.loads((REPO/'scripts/capture-chain-native-tests.json').read_text())
        with patch.object(C, 'load', return_value=chain):
            chain_added=C.chain_additions(inventory)
        self.assertEqual(len(chain_added),95)
        for bad in ({}, {'added':chain['added'][:-1], 'focused':chain['focused']},
                    {**chain,'unexpected':0}):
            with patch.object(C, 'load', return_value=bad), self.assertRaises(ValueError):
                C.chain_additions(inventory)
        original=[name for name in inventory if name not in set(live) | feedback_added | chain_added]
        self.assertEqual(len(original),2047)
        self.assertEqual(hashlib.sha256(('\n'.join(original)+'\n').encode()).hexdigest(),
                         '926ac5674df90163b949fe461f0d4589ef72c8fc3215fa00b927564aae57cb44')


if __name__=='__main__':unittest.main()
