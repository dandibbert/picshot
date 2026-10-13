#!/usr/bin/env python3
"""Current-source interaction evidence only; never grant memory/testing eligibility."""
import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import re
import subprocess
import struct
import zipfile

# Reuse the existing bounded native PNG decoder directly. The capture-chain
# reader imports this module, so importing that reader here would be circular.
_PNG_SPEC = importlib.util.spec_from_file_location('scroll_recovery_png', Path(__file__).with_name('check-automatic-mosaic-report.py'))
_PNG = importlib.util.module_from_spec(_PNG_SPEC)
_PNG_SPEC.loader.exec_module(_PNG)

MARKER = '[experimental-scroll-interactions]'
ROOT = Path('dist/experimental-scroll-interactions')
EVIDENCE = Path('dist/live-scroll-installed')
SCRIPT = Path('scripts/live-scroll-installed.sh')
OMITTED = b'bash scripts/run-live-scroll-resource.sh "$app" "$evidence/resource" "$source_sha"\n'
SCRIPT_SHA = '7099c8c469de1f03cdc82f6589c04da69d07627276ae17a8bfe48b36922bdec8'
PREFIX_SHA = '44ee48f13fdfe6ec558a8d6adb63de52494f0650ca13dddf3fc4329ae7f63c1c'
PRIOR_FAILURE = dict(runID='38130153505', build=227, warmRSSBytes=10780672,
                     warmLimitBytes=9830400, lateThreeRSSBytes=5177344,
                     lateLimitBytes=4915200, preserved=True)
PREVIEW_RECOVERY_VISUALS = tuple('live-scroll-preview-' + state + '-' + appearance + '.png'
    for state in ('failed', 'recovered') for appearance in ('light', 'dark'))
REJECTED_MOVE_VISUALS = tuple('live-scroll-rejected-move-' + state + '-' + appearance + '.png'
    for state in ('active', 'paused') for appearance in ('light', 'dark'))
FLAGS = dict(distribution='user-opted-experimental', userOptedExperimentalDistribution=True,
             installerAcceptance=False, fullMemoryQualification=False, testingPackageEligible=False,
             partialMemoryQualification=False, stable214Unchanged=True, stableInstallerReplacement=False,
             disputedResourceCellRerun=False, scrollingResourceClassifierRun=False,
             publicRelease=False, mainMerged=False, realScreenCaptureAcceptance=False)
# Every ordinary executable gate is required; only the original resource/classifier
# branch and its testing-only distribution/budget are replaced in opt-in mode.
REQUIRED_GATES = ('current_gate_01', 'current_gate_02', 'current_gate_03', 'current_gate_04', 'current_gate_05', 'current_gate_06', 'current_gate_07', 'current_gate_08', 'current_gate_09', 'current_gate_10', 'current_gate_11', 'current_gate_12', 'current_gate_13', 'current_gate_14', 'current_gate_15', 'current_gate_16', 'current_gate_17', 'current_gate_18', 'current_gate_19', 'current_gate_20', 'current_gate_21', 'current_gate_22', 'current_gate_23', 'current_gate_24', 'current_gate_25', 'experimental_scroll_contract', 'experimental_scroll_prepare', 'experimental_scroll_demo', 'experimental_scroll_receipt', 'text_script_contracts')


def need(value, message):
    if not value:
        raise ValueError(message)


def fields(row, expected, label):
    need(type(row) is dict, label + ': missing object')
    for key, value in expected.items():
        actual = row.get(key)
        need(key in row and type(actual) is type(value) and actual == value, label + '.' + key + ': differs/missing')


def number(value, label, low=0, high=float('inf')):
    need(type(value) in (int, float) and math.isfinite(value) and low <= value <= high,
         label + ': invalid number')
    return value


def read(path, limit=16 * 1024**2):
    need(path.is_file() and not path.is_symlink() and 0 < path.stat().st_size <= limit,
         'Missing, symlinked or oversized input: ' + str(path))
    raw = path.read_bytes()
    need(len(raw) <= limit, 'Input grew beyond bound: ' + str(path))
    return raw


def recovery_png(path):
    """Decode only the eight added native visuals within the existing file bound."""
    raw = read(path)
    need(len(raw) >= 33 and raw[:8] == b'\x89PNG\r\n\x1a\n', 'Invalid recovery PNG signature: ' + str(path))
    width, height = struct.unpack_from('>II', raw, 16)
    need(0 < width <= 4096 and 0 < height <= 4096 and width*height <= 4_000_000,
         'Recovery PNG raster exceeds bound: ' + str(path))
    return _PNG.png_rgba(raw)


def sha(path, limit=128 * 1024**2):
    return hashlib.sha256(read(path, limit)).hexdigest()


def load(path):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            need(key not in result, 'Duplicate JSON field: ' + key)
            result[key] = value
        return result
    def invalid(value):
        raise ValueError('Nonfinite JSON number: ' + value)
    value = json.loads(read(path), object_pairs_hook=unique, parse_constant=invalid)
    need(type(value) is dict, 'Expected JSON object: ' + str(path))
    return value


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def selected_prefix(original):
    need(hashlib.sha256(original).hexdigest() == SCRIPT_SHA, 'Installed script bytes changed')
    need(original.endswith(OMITTED) and original.count(OMITTED) == 1, 'Expected one final resource command')
    prefix = original[:-len(OMITTED)]
    need(hashlib.sha256(prefix).hexdigest() == PREFIX_SHA, 'Selected prefix bytes changed')
    need(b'run-live-scroll-resource' not in prefix, 'Resource invocation in selected prefix')
    return prefix


def git(*args):
    return subprocess.check_output(['git', *args], text=True, timeout=10).strip()


def context():
    need(os.environ.get('PICSHOT_EXPERIMENTAL_SCROLL_INTERACTIONS') == 'true'
         and MARKER in os.environ.get('PICSHOT_TRIGGER_MESSAGE', '')
         and os.environ.get('GITHUB_EVENT_NAME') == 'push', 'Explicit experimental push marker required')
    source, build = os.environ['GITHUB_SHA'], os.environ['GITHUB_RUN_NUMBER']
    need(re.fullmatch('[0-9a-f]{40}', source) and re.fullmatch('[1-9][0-9]*', build)
         and int(build) > 231, 'Fresh current-source build after231 required')
    need(platform.system() == 'Darwin' and platform.machine() in ('arm64', 'x86_64'), 'Native macOS required')
    need(git('rev-parse', 'HEAD') == source and not git('status', '--porcelain', '--untracked-files=no'),
         'Current tracked checkout must match triggering source exactly')
    return dict(sourceCommit=source, sourceTree=git('rev-parse', 'HEAD^{tree}'), build=build,
                architecture=platform.machine(), version='0.22.0', workflowCommit=source,
                workflowSHA256=sha(Path('.github/workflows/macos.yml')),
                checkerSHA256=sha(Path(__file__)), selectedScriptSHA256=sha(SCRIPT),
                selectedPrefixSHA256=PREFIX_SHA, workflowRunID=os.environ['GITHUB_RUN_ID'],
                workflowRunAttempt=os.environ['GITHUB_RUN_ATTEMPT'])


def packages(identity):
    app = Path('dist/PicShot.app')
    info = plistlib.loads(read(app/'Contents/Info.plist'))
    fields(info, dict(PicShotSourceCommit=identity['sourceCommit'], CFBundleVersion=identity['build'],
                     CFBundleShortVersionString='0.22.0', CFBundleExecutable='PicShot'), 'packaged plist')
    build = load(app/'Contents/Resources/build-info.json')
    fields(build, {key: identity[key] for key in ('sourceCommit', 'architecture', 'version')}, 'packaged build')
    metadata = Path('dist/PicShot-0.22.0-macos-' + identity['architecture'] + '.build-info.json')
    need(read(metadata) == read(app/'Contents/Resources/build-info.json'), 'Package metadata differs from app')
    need(read(Path(str(metadata) + '.sha256')).decode().split() == [sha(metadata), metadata.name],
         'Package metadata checksum differs')
    result = {}
    for extension in ('zip', 'dmg'):
        path = Path('dist/PicShot-0.22.0-macos-' + identity['architecture'] + '.' + extension)
        digest = sha(path, 32 * 1024**2 - 65536)
        need(read(Path(str(path) + '.sha256')).decode().split() == [digest, path.name], 'Package checksum differs')
        result[extension] = dict(path=str(path.resolve()), sha256=digest, bytes=path.stat().st_size)
    return dict(packages=result, executableSHA256=sha(app/'Contents/MacOS/PicShot'),
                plistSHA256=sha(app/'Contents/Info.plist'), buildInfoSHA256=sha(app/'Contents/Resources/build-info.json'))


def forbid_resource():
    for path in (EVIDENCE/'resource', Path('dist/live-scroll-testing-qualification.json')):
        need(not path.exists() and not path.is_symlink(), 'Disputed resource/classification must not run: ' + str(path))


def source_record():
    forbid_resource()
    identity = context()
    current = dict(identity, **packages(identity))
    saved = load(ROOT/'source-identity.json')
    need(saved == current, 'Source, workflow, build or package changed since preparation')
    need(read(ROOT/'installed-demo-prefix.sh') == selected_prefix(read(SCRIPT)), 'Selected prefix changed')
    return saved


def runner(row, timeout, grace, label):
    fields(row, dict(status='exited', child_returncode=0, exit_code=0, cancel_signal=None,
                     sigterm_sent=False, sigkill_sent=False, descendant_cleanup=False,
                     termination_reason='exited', log_truncated=False), label)
    need(not row.get('error') and not row.get('cleanup_errors'), label + ': cleanup/error')
    need(number(row.get('timeout_seconds'), label) == timeout
         and number(row.get('grace_seconds'), label) == grace, label + ': deadline changed')
    number(row.get('duration_seconds'), label + '.duration', 0, timeout)


def demo_fields(demo):
    fields(demo, dict(status='passed', installerAcceptance=False, permissionRequested=False,
                     globalInputPosted=False, privateUserContent=False, networkUsed=False), 'demo')
    for name in ('illustratedCase', 'ordinaryTextCase', 'movementCase', 'automaticCase'):
        case = demo.get(name)
        fields(case, dict(status='passed', productSessionClosed=True), name)
        fields(case, {'finishCallbacks' if name == 'movementCase' else 'finishButtonCompletionCallbacks': 1}, name)
        comparison = case.get('referenceComparison' if name == 'movementCase' else 'nativeReferenceComparison')
        fields(comparison, dict(passed=True, dimensionsMatch=True, exactEquality=True), name + '.comparison')
        for key in ('meanAbsoluteRGBAError', 'fractionOfChannelsDifferingByMoreThan8'):
            need(number(comparison.get(key), name + '.' + key) == 0, 'Reference pixels differ')
    fields(demo['ordinaryTextCase'], dict(addedAlignmentMarkers=False), 'ordinary text')
    fields(demo['illustratedCase'], dict(extendedAfterReversal=True), 'reversal')
    fields(demo['illustratedCase'], dict(gapMarkerUnverified=True, gapMarkerAmber=True,
           gapAccessibilityDescribesUnverifiedPosition=True, gapRecoveryMarkerVerified=True,
           gapRecoveryMarkerGreen=True, gapRecoveryAccessibilityDescribesVerifiedPosition=True), 'gap preview')
    number(demo['illustratedCase'].get('acceptedReverseObservations'), 'reverse observations', 2)
    recovery_fields(demo)
    move = demo['movementCase']
    fields(move, dict(moveAppliedThroughReturn=False, moveAppliedThroughMouseRelease=True,
                     actualSourcePixelsChanged=True, ownedTargetIdentityUnchanged=True), 'movement')
    need(number(move.get('matchedMoveDisplacement'), 'matched displacement') == 48, 'Move displacement differs')
    fields(move.get('drag'), dict(crossAxisUnchanged=True, sizeUnchanged=True,
                                finalReleasePositionApplied=True), 'direct release')
    need(number(move['drag'].get('alongAxisDelta'), 'along-axis delta') == 48, 'Release delta differs')
    fields(move.get('duringDrag'), dict(toolbarVisible=True, previewVisible=True, handleVisible=True,
           lastGoodPreviewPixelsPreserved=True, previewPositionUnverified=True, previewMarkerAmber=True,
           previewAccessibilityUnverified=True, sourceRegionUnchanged=True, fullscreenMoveViewAbsent=True), 'during drag')
    fields(move.get('escapeRollback'), dict(passed=True, sourceRegionPreserved=True, acceptedHeightPreserved=True,
           acceptedOffsetPreserved=True, lastGoodPreviewPixelsPreserved=True, captureResumed=True,
           trailingMouseUpIgnored=True), 'Escape rollback')
    fields(move.get('dragAppearanceEvidence'), dict(light='live-scroll-movement-native-drag.png',
           dark='live-scroll-movement-native-dark-drag.png', restoredAppearance='aqua'), 'drag appearance')
    auto = demo['automaticCase']
    fields(auto, dict(productSessionControllerExercised=True, sessionSamplingLoopReimplementedByFixture=False,
        automaticInputLoopReimplementedByFixture=False, captureMode='injected-rendered-owned-window',
        globalInputPosted=False, realScreenCaptureClaimed=False, permissionRequested=False,
        autoDisabledBeforeVerifiedSeed=True, nativeAutoButtonStartedSession=True,
        nativeStopButtonStoppedInput=True, nativeAutoButtonRestartedSession=True,
        manualCaptureActiveAfterStopButton=True, manualCaptureActiveAfterNoProgress=True,
        manualRecoveryAfterNoProgress=True, noProgressStoppedAtNativeEnd=True,
        noProgressTerminalInputCount=1, matchedForwardProgressBeforeEveryFollowingInput=True,
        completionCallbacksBeforeFinish=0, outputWidth=640, outputHeight=1120,
        fixedHeaderDetectedPixels=36, ownedWindowClosed=True), 'automatic')
    number(auto.get('noProgressStopSecondsSinceLastInput'), 'automatic stop', 3, 22)
    number(auto.get('minimumAutomaticIntervalWithinRunSeconds'), 'automatic interval', .35 - .000001)
    number(auto.get('minimumAutomaticIntervalSeconds'), 'automatic global interval', .35 - .000001)
    number(auto.get('nativeAutomaticInputCount'), 'automatic input count', 6, 64)
    number(auto.get('observedGrowingPreviewUpdates'), 'automatic preview growth', 4)
    number(auto.get('storyFrames'), 'automatic story frames', 1, 36)
    calibration = auto.get('referenceInitialViewportCalibration')
    fields(calibration, dict(passed=True, dimensionsMatch=True, exactEquality=True), 'automatic initial reference')
    for key in ('meanAbsoluteRGBAError', 'fractionOfChannelsDifferingByMoreThan8'):
        need(number(calibration.get(key), 'automatic calibration.' + key) == 0, 'Initial reference pixels differ')
    output_fields(demo.get('outputCase'))
    real = demo.get('realStream', {})
    need(type(real) is dict, 'Missing real stream report')
    need(real.get('status') == 'passed' or (real.get('status') == 'blocked'
         and real.get('permissionAlreadyGranted') is False), 'Real stream failed for another reason')
    need(type(demo.get('realScreenCaptureValidated')) is bool
         and demo['realScreenCaptureValidated'] == (real['status'] == 'passed'), 'Real capture report differs')



def recovery_fields(demo):
    """Require the native stationary-preview and resumed-error Pause witnesses."""
    preview = demo['illustratedCase'].get('stationaryPreviewRecovery')
    fields(preview, dict(status='passed', injectedPreviewFailures=1,
        nativeWheelEventsToFailure=1, nativeWheelEventsDuringRecovery=0,
        failurePreviewUnavailable=True, failureMatched=True, failureRetainedPreviewPixels=True,
        failureMarkerUnverified=True, failureMarkerAmber=True, failureAccessibilityUnverified=True,
        failureAutoOff=True, failureAutoDisabled=True, failureAutoLabel='自动滚动',
        recoveryRequiresFurtherInput=False, recoveryPreviewAvailable=True,
        recoveryMarkerVerified=True, recoveryMarkerGreen=True, recoveryMarkerAtAcceptedViewport=True,
        recoveryAccessibilityVerified=True, recoveryAutoOff=True, recoveryAutoLabel='自动滚动',
        durableSourceCountUnchanged=True, durableStripCountUnchanged=True, durableDiskBytesUnchanged=True,
        sourcePacingMaximumSeconds=2), 'stationary preview recovery')
    for key in ('beforeFailureAcceptedObservations', 'failureAcceptedObservations', 'recoveryAcceptedObservations',
                'beforeFailureOffset', 'failureOffset', 'failureNativeOffset', 'recoveryOffset', 'recoveryNativeOffset',
                'failureHeight', 'recoveryHeight', 'stationaryFramesObserved'):
        need(type(preview.get(key)) is int, 'Stationary preview recovery.' + key + ': integer required')
    before_count = number(preview.get('beforeFailureAcceptedObservations'), 'before failure accepted', 1)
    failure_count = number(preview.get('failureAcceptedObservations'), 'failed accepted', 2)
    need(failure_count == before_count + 1, 'Preview failure did not follow exactly one accepted viewport')
    before_offset = number(preview.get('beforeFailureOffset'), 'before failure offset')
    failure_offset = number(preview.get('failureOffset'), 'failed viewport offset')
    need(failure_offset == before_offset + 48, 'Preview failure did not follow the native 48px wheel input')
    need(number(preview.get('failureNativeOffset'), 'failed native offset') == failure_offset,
         'Failed accepted viewport differs from native source')
    for first, second in [('failureAcceptedObservations', 'recoveryAcceptedObservations'),
                          ('failureOffset', 'recoveryOffset'), ('failureHeight', 'recoveryHeight'),
                          ('failureNativeOffset', 'recoveryNativeOffset')]:
        need(number(preview.get(first), first) == number(preview.get(second), second),
             'Stationary preview recovery changed ' + first)
    number(preview.get('failureHeight'), 'failed output height', 480)
    number(preview.get('stationaryFramesObserved'), 'stationary recovery observations', 1)
    for key, state in [('failureAppearanceEvidence', 'failed'), ('recoveryAppearanceEvidence', 'recovered')]:
        fields(preview.get(key), {appearance: 'live-scroll-preview-' + state + '-' + appearance + '.png'
            for appearance in ('light', 'dark')}, 'preview ' + key)
    move = demo['movementCase'].get('rejectedMovePause')
    fields(move, dict(status='passed', injectedMoveFailures=1, resumeCallsAfterRejection=1, pauseCallsForDrag=1,
        moveRoute='owned handle NSWindow.sendEvent mouseDown/mouseDragged/mouseUp with hit-test',
        pauseButtonRoute='accepted native hit-test/mouse helper PortableSettingsUIPreviewFixture.click',
        activeErrorStatus=True, activeSourceResumed=True, activePauseLabel='暂停捕获', activePauseTooltip='暂停捕获',
        activePauseEnabled=True, sourceRegionPreserved=True, ownedTargetIdentityUnchanged=True,
        pauseClickDrainedSource=True, pauseStoppedProviderCalls=True, pauseStoppedSamples=True,
        pausedPreviewPixelsPreserved=True, pausedSourceRegionPreserved=True, pausedLabel='继续捕获',
        nativeResumeRejoined=True, sourcePacingMaximumSeconds=2), 'rejected move Pause')
    fields(demo['movementCase'], dict(ownedSourceStopped=True), 'movement source lifetime')
    for first, second, low in [('retainedHeight', 'pausedHeight', 480),
                               ('retainedOffset', 'pausedOffset', 1),
                               ('retainedAcceptedObservations', 'pausedAcceptedObservations', 2)]:
        need(type(move.get(first)) is int and type(move.get(second)) is int, 'Rejected move counts/geometry must be integers')
        need(number(move.get(first), first, low) == number(move.get(second), second, low),
             'Rejected move Pause changed ' + first)
    for key, state in [('activeAppearanceEvidence', 'active'), ('pausedAppearanceEvidence', 'paused')]:
        fields(move.get(key), {appearance: 'live-scroll-rejected-move-' + state + '-' + appearance + '.png'
            for appearance in ('light', 'dark')}, 'move ' + key)


def output_fields(output):
    fields(output, dict(status='passed', productSessionClosed=True, privateTemporaryRootRemoved=True, cleanupSafe=True,
        canonicalPrivateTemporaryRoot=True, realScreenCaptureClaimed=False, screenCaptureAPICalled=False,
        permissionRequested=False, globalInputPosted=False, networkUsed=False,
        userHistoryReadOrWritten=False, standardDefaultsReadOrWritten=False,
        generalPasteboardReadOrWritten=False), 'output')
    save = output.get('stitchedCopyFailureThenSave')
    fields(save, dict(status='passed', productSessionClosed=True, saveJobsDrained=True, cleanupSafe=True,
        copyFailurePausedDraftAndAlternativePreserved=True, savePublicationRetiredSession=True,
        savedInsideApprovedPrivateDirectory=True, independentPublishedPNGDecode=True,
        copyRecipientAttempts=1, saveJobAdmissions=1, editorCallbacks=0, importCallbacks=0,
        saveMenuIdentifier='scroll.live.quickSave', saveSelector='quickSavePressed'), 'saved output')
    pin = output.get('singleViewportPin')
    fields(pin, dict(status='passed', productSessionClosed=True, pinControllersClosed=True, cleanupSafe=True,
        singleViewportUnchanged=True, persistedAndReopened=True, independentPublishedPNGDecode=True, pinCallbacks=1, unexpectedCallbacks=0,
        visibleNativePinCount=1, menuIdentifier='scroll.live.pin', selector='pinPressed'), 'pin output')
    for row, key, height in [(save, 'rejectedCopyComparison', 704), (save, 'savedPNGComparison', 704),
                             (pin, 'publishedPinComparison', 320), (pin, 'reopenedPinComparison', 320)]:
        comparison = row.get(key)
        fields(comparison, dict(passed=True, dimensionsMatch=True, exactCanonicalRGBAEquality=True,
            width=480, height=height, expectedWidth=480, expectedHeight=height), key)
        pixel_hash = comparison.get('outputPixelSHA256')
        need(type(pixel_hash) is str and re.fullmatch('[0-9a-f]{64}', pixel_hash) is not None
             and pixel_hash == comparison.get('sourcePixelSHA256'), key + ': exact pixel digest differs')
    for row, key in [(save, 'controlArtifacts'), (save, 'saveFeedbackArtifacts'), (save, 'saveFeedbackNarrowArtifacts'),
                     (pin, 'controlArtifacts'), (pin, 'nativePinArtifacts')]:
        artifacts = row.get(key)
        need(type(artifacts) is list and len(artifacts) == 2
             and [x.get('appearance') for x in artifacts if type(x) is dict] == ['light', 'dark'],
             key + ': both native appearances required')
        for artifact in artifacts:
            name = artifact.get('filename')
            need(type(name) is str and name.startswith('output-') and Path(name).name == name
                 and name.endswith('.png'), 'Unsafe or absent native output image')
            number(artifact.get('width'), 'output image width', 1, 4000000)
            number(artifact.get('height'), 'output image height', 1, 4000000)


    save_feedback_fields(save)


def save_feedback_fields(save):
    """Recompute full-frame/text-fit claims from native measurements, not flags."""
    outcome = '文件已安全保存'
    fields(save, dict(saveFeedback=outcome), 'save feedback')
    path, filename = save.get('savedPath'), save.get('savedFilename')
    need(type(path) is str and path.startswith('/') and '..' not in Path(path).parts
         and len(path.encode('utf-8')) <= 1024, 'Missing or invalid saved path')
    need(type(filename) is str and Path(path).name == filename and Path(filename).name == filename
         and 100 <= len(filename.encode('utf-8')) <= 180
         and 'capture-segment-' in filename and '长截图保存结果-' in filename
         and filename.endswith('.png'), 'Bounded long ASCII/Unicode save filename required')

    def rect(row, label):
        need(type(row) is dict and set(row) == {'x', 'y', 'width', 'height'}, label + ': missing full frame')
        return (number(row.get('x'), label + '.x', -4000000, 4000000),
                number(row.get('y'), label + '.y', -4000000, 4000000),
                number(row.get('width'), label + '.width', .01, 4000000),
                number(row.get('height'), label + '.height', .01, 4000000))

    for key, width, stem in [('saveFeedbackArtifacts', 460, 'output-save-feedback-'),
                             ('saveFeedbackNarrowArtifacts', 320, 'output-save-feedback-narrow-')]:
        for artifact in save[key]:
            fields(artifact, dict(width=width, height=190, filename=stem + artifact['appearance'] + '.png'), key)
            digest = artifact.get('canonicalRGBAPixelSHA256')
            need(type(digest) is str and re.fullmatch('[0-9a-f]{64}', digest) is not None,
                 key + ': native snapshot pixel digest missing')
            layout = artifact.get('layout')
            fields(layout, dict(passed=True, windowVisible=True, controlsVisible=True,
                statusText=outcome, statusAccessibilityValue=outcome,
                detailText=path, detailToolTip=path, detailAccessibilityValue=path,
                detailMaximumNumberOfLines=1, detailTruncatesMiddle=True), key + '.layout')
            bounds = rect(layout.get('contentBounds'), 'save content')
            need(bounds == (0, 0, width, 190), 'Compact Save content bounds differ')
            frames = layout.get('frames')
            need(type(frames) is dict and set(frames) == {'status', 'detail', 'note', 'close'},
                 'Every Save text/control full frame is required')
            measured = {name: rect(frame, name) for name, frame in frames.items()}
            for name, (x, y, w, h) in measured.items():
                need(x >= -.5 and y >= -.5 and x + w <= width + .5 and y + h <= 190.5,
                     name + ': full frame clipped outside Save window')
            values = list(measured.items())
            for index, (name, (x, y, w, h)) in enumerate(values):
                for previous, (ox, oy, ow, oh) in values[:index]:
                    overlap_w, overlap_h = min(x+w, ox+ow)-max(x, ox), min(y+h, oy+oh)-max(y, oy)
                    need(overlap_w <= .5 or overlap_h <= .5, name + '/' + previous + ': full frames overlap')
            # 0.5 point allows native subpixel rounding, never another text line.
            for role, height_key in [('status', 'statusRequiredTextHeight'), ('note', 'noteRequiredTextHeight')]:
                required = number(layout.get(height_key), height_key, .01, 10000)
                need(required <= measured[role][3] + .5, role + ': native required text height is clipped')
            status_width = number(layout.get('statusRequiredUntruncatedWidth'), 'status native width', .01, 10000)
            need(status_width <= measured['status'][2] + .5, 'Save outcome text is horizontally clipped')
            detail_width = number(layout.get('detailRequiredUntruncatedWidth'), 'detail native width', .01, 10000)
            need(detail_width > measured['detail'][2], 'Saved path did not exercise native truncation')


def check_parent(report, app, source, version, build):
    """Fail the installed smoke before child qualification if its parent failed."""
    need(type(source) is str and re.fullmatch('[0-9a-f]{40}', source), 'Invalid expected parent source')
    need(type(app) is str and app.startswith('/') and str(Path(app)) == app
         and '..' not in Path(app).parts and app.endswith('/PicShot.app'), 'Invalid expected parent bundle')
    need(type(version) is str and re.fullmatch('[0-9]+(?:\\.[0-9]+)+', version)
         and type(build) is str and re.fullmatch('[1-9][0-9]*', build), 'Invalid expected parent version/build')
    need(report.parent.is_dir() and not report.parent.is_symlink(), 'Missing/symlinked parent evidence directory')
    demo = load(report)
    demo_fields(demo)
    identity = dict(bundlePath=app, sourceCommit=source, version=version, build=build)
    fields(demo, identity, 'installed live-scroll parent identity')
    root = report.parent/'saved-image-chain'
    need(root.is_dir() and not root.is_symlink(), 'Missing/symlinked saved-image-chain evidence directory')
    child = load(root/'live-scroll-chain.json')
    fields(child, dict(status='passed', sourceCommit=source), 'installed live-scroll child identity')
    need(child == demo.get('scrollChainCase'), 'Saved-image-chain subreport differs from installed session')
    # Native pixels and geometry remain the existing, separately bounded child
    # check. This precheck cannot create its qualification receipt or relax it.
    return dict(status='passed', sourceIdentity=identity, parentAndChildMatched=True)


def scroll_chain_evidence(root, demo, source):
    """Independently decode the exact new subreport and bind it to its parent."""
    need(root.is_dir() and not root.is_symlink(), 'Missing/symlinked saved-image-chain evidence directory')
    report_path = root/'live-scroll-chain.json'
    need(load(report_path) == demo.get('scrollChainCase'), 'Saved-image-chain subreport differs from installed session')
    spec = importlib.util.spec_from_file_location('live_scroll_chain_evidence',
        Path(__file__).with_name('check-live-scroll-chain-demo.py'))
    reader = importlib.util.module_from_spec(spec); spec.loader.exec_module(reader)
    receipt = reader.validate(report_path, source)
    receipt_path = root/'live-scroll-chain-receipt.json'
    need(receipt == load(receipt_path), 'Saved-image-chain bytes changed after strict qualification')
    return [root/name for name in receipt['evidenceSHA256']] + [receipt_path]


def qualify():
    source = source_record()
    installed = load(EVIDENCE/'package-identity.json')
    fields(installed, dict(status='passed', **{key: source[key] for key in
           ('sourceCommit', 'build', 'version', 'architecture', 'executableSHA256')},
           archiveSHA256=source['packages']['zip']['sha256']), 'installed ZIP')
    app = installed.get('bundlePath')
    need(type(app) is str and app.startswith('/') and '..' not in Path(app).parts
         and app.endswith('/PicShot.app'), 'Invalid installed bundle path')
    fields(installed, dict(executablePath=app + '/Contents/MacOS/PicShot'), 'installed executable')
    demo = load(EVIDENCE/'demo/demo.json')
    fields(demo, dict(bundlePath=app, **{key: source[key] for key in ('sourceCommit', 'build', 'version')}), 'demo identity')
    demo_fields(demo)
    launch = load(EVIDENCE/'demo/demo.json.launcher.json')
    fields(launch, dict(status='exited', launcherExitCode=0, callbackReceived=True,
           createsNewApplicationInstance=True, ownedExitConfirmed=True, launchedIdentityMatches=True,
           timeoutSeconds=600, selectedAppPath=app, launchedAppPath=app,
           launchedExecutablePath=installed['executablePath']), 'owned launch')
    number(launch.get('processIdentifier'), 'owned pid', 1)
    number(launch.get('elapsedSeconds'), 'owned launch duration', 0, 600)
    outer = load(Path('dist/experimental-scroll-installed-report.json'))
    runner(outer, 780, 10, 'selected prefix runner')
    prefix = read(ROOT/'installed-demo-prefix.sh').decode().rstrip('\n')
    fields(outer, dict(command=['bash', '-c', prefix, str(SCRIPT), source['packages']['zip']['path'],
                              str(EVIDENCE.resolve()), source['sourceCommit']]), 'selected prefix command')
    inner = load(EVIDENCE/'demo-launch.json')
    runner(inner, 660, 10, 'demo runner')
    fields(inner, dict(command=['swift', 'scripts/launch-smoke-app.swift', app,
                               str((EVIDENCE/'demo/demo.json').resolve())]), 'demo command')
    chain_files = scroll_chain_evidence(EVIDENCE/'demo/saved-image-chain', demo, source['sourceCommit'])
    files = [EVIDENCE/'package-identity.json', EVIDENCE/'demo/demo.json',
             EVIDENCE/'demo/demo.json.launcher.json', EVIDENCE/'demo-launch.json',
             Path('dist/experimental-scroll-installed-report.json')]
    files += chain_files
    for filename in PREVIEW_RECOVERY_VISUALS:
        path = EVIDENCE/'demo'/filename
        recovery_png(path)
        files.append(path)
    for filename in REJECTED_MOVE_VISUALS:
        path = EVIDENCE/'demo/movement'/filename
        recovery_png(path)
        files.append(path)
    for filename in ('live-scroll-movement-native-drag.png', 'live-scroll-movement-native-dark-drag.png',
                     'live-scroll-movement-native-rollback.png', 'live-scroll-movement-finished.png',
                     'live-scroll-movement-reference.png', 'live-scroll-movement-interaction.gif'):
        path = EVIDENCE/'demo/movement'/filename
        raw = read(path)
        need(raw.startswith(b'\x89PNG\r\n\x1a\n' if filename.endswith('.png') else b'GIF8'), 'Invalid visual: ' + filename)
        files.append(path)
    output_root = EVIDENCE/'demo/output-actions'
    output_report = load(output_root/'live-scroll-output.json')
    need(output_report == demo['outputCase'], 'Output subreport differs from installed session report')
    files.append(output_root/'live-scroll-output.json')
    feedback_layout_path = output_root/'output-save-feedback-layout.json'
    saved_output = output_report['stitchedCopyFailureThenSave']
    need(load(feedback_layout_path) == dict(normal=saved_output['saveFeedbackArtifacts'],
         narrow=saved_output['saveFeedbackNarrowArtifacts']), 'Persisted Save layout differs from session evidence')
    files.append(feedback_layout_path)
    output_names = {'output-owned-numbered-reference.png', 'output-published-long.png', 'output-published-single-pin.png'}
    for row, key in [(output_report['stitchedCopyFailureThenSave'], 'controlArtifacts'),
                     (output_report['stitchedCopyFailureThenSave'], 'saveFeedbackArtifacts'),
                     (output_report['stitchedCopyFailureThenSave'], 'saveFeedbackNarrowArtifacts'),
                     (output_report['singleViewportPin'], 'controlArtifacts'),
                     (output_report['singleViewportPin'], 'nativePinArtifacts')]:
        output_names.update(x['filename'] for x in row[key])
    for filename in sorted(output_names):
        path = output_root/filename
        need(read(path).startswith(b'\x89PNG\r\n\x1a\n'), 'Invalid output evidence PNG')
        files.append(path)
    need(sha(output_root/'output-published-long.png') == output_report['stitchedCopyFailureThenSave']['savedPNGFileSHA256'],
         'Published long PNG bytes differ')
    need(sha(output_root/'output-published-single-pin.png') == output_report['singleViewportPin']['pinPNGFileSHA256'],
         'Published pin PNG bytes differ')
    return dict(FLAGS, status='passed', sourceIdentity=source, originalSelectedAssertionsPreserved=True,
                directDragReleaseEscapeAndStalePreviewVerified=True,
                stationaryPreviewRecoveryAndRejectedMovePauseVerified=True,
                existingLongImageSavedChainContinuationVerified=True,
                observedRealStreamStatus=demo['realStream']['status'],
                observedRealScreenCaptureValidated=demo['realScreenCaptureValidated'],
                evidenceSHA256={str(path): sha(path) for path in files})


def validate_outcomes(steps):
    for name in REQUIRED_GATES:
        fields(steps.get(name), dict(outcome='success', conclusion='success'), 'required gate ' + name)
    for name in ('live_scroll_resource', 'scroll_testing_classification', 'scroll_testing_contract'):
        fields(steps.get(name), dict(outcome='skipped', conclusion='skipped'), 'excluded gate ' + name)



SAVE_PAYLOAD_CLASSES = {
    'PicShotTests.ImageExportPNGStagingTests', 'PicShotTests.SaveWorkflowServiceTests',
    'PicShotTests.SaveWorkflowDeliveryTests', 'PicShotTests.LiveScrollSaveDeliveryTests',
    'PicShotTests.SaveWorkflowUITests',
}


def save_payload_additions(inventory):
    """Exact additive266 coverage; the existing five classes remain complete."""
    record = load(Path('scripts/save-payload-native-tests.json'))
    need(type(record) is dict and set(record) == {'added', 'focused'}, 'Save payload inventory schema differs')
    for key, count, digest in [
            ('added', 25, 'fb6caa647da701ca40cb44139a26229052f2c204f4838cf756a4701b11fd63c1'),
            ('focused', 93, 'ed9db8041ef5f823b3f2ae655a32192359454e8c2fb7b49aad542c19a8d1b1a8')]:
        methods = record[key]
        need(type(methods) is list and len(methods) == count and methods == sorted(set(methods))
             and all(type(name) is str and re.fullmatch(r'PicShotTests\.\w+Tests/test\w+', name)
                     and name.split('/')[0] in SAVE_PAYLOAD_CLASSES for name in methods)
             and hashlib.sha256(('\n'.join(methods)+'\n').encode()).hexdigest() == digest,
             'Save payload ' + key + ' inventory differs')
    need(set(record['added']).issubset(record['focused'])
         and record['focused'] == [name for name in inventory if name.split('/')[0] in SAVE_PAYLOAD_CLASSES],
         'Save payload methods lost or added outside explicit inventory')
    return set(record['added'])


def feedback_additions(inventory):
    payload = save_payload_additions(inventory)
    feedback = load(Path('scripts/save-feedback-native-tests.json'))
    need(set(feedback) == {'baseline241', 'added'}, 'Save feedback native inventory schema differs')
    for key, count in [('baseline241', 9), ('added', 5)]:
        methods = feedback[key]
        need(type(methods) is list and len(methods) == count
             and all(type(name) is str and re.fullmatch(r'PicShotTests\.SaveWorkflowUITests/test\w+', name) for name in methods)
             and methods == sorted(set(methods)), 'Save feedback ' + key + ' inventory differs')
    need(not set(feedback['baseline241']) & set(feedback['added'])
         and sorted(feedback['baseline241'] + feedback['added'])
         == [name for name in inventory if name not in payload and name.startswith('PicShotTests.SaveWorkflowUITests/')],
         'Save feedback class lost or added an unrecorded test')
    return set(feedback['added'])


def chain_additions(inventory):
    payload = save_payload_additions(inventory)
    chain = load(Path('scripts/capture-chain-native-tests.json'))
    need(type(chain) is dict and set(chain) == {'added', 'focused'}, 'Chain inventory schema differs')
    added = chain['added']
    current = {name for name in SCROLL_CHAIN_ADDITIONS if '.CaptureChain' in name or '.SaveWorkflowDeliveryTests/' in name}
    need(type(added) is list and len(added) == 95 + len(current) and added == sorted(set(added))
         and all(type(name) is str and re.fullmatch(r'(?:PicShotCoreTests|PicShotTests)\.(?:CaptureChain\w*Tests|SaveWorkflowDeliveryTests)/test\w+', name) for name in added),
         'Chain additions differ')
    preserved = [name for name in added if name not in current]
    need(len(preserved) == 95 and hashlib.sha256(('\n'.join(preserved)+'\n').encode()).hexdigest()
         == '1d0981cda725cf988eadd9252851f4ae56d4c97a8fb6f6989a253598e8b0e57f',
         'Preserved capture-chain IDs differ')
    need(added == [name for name in inventory if name not in payload and ('.CaptureChain' in name or '.SaveWorkflowDeliveryTests/' in name)],
         'Chain methods lost or added outside explicit inventory')
    return set(added)


SCROLL_RECOVERY_ADDITIONS = (
    'PicShotTests.LiveScrollAssemblerTransactionTests/testMismatchCannotSpendRecoveryAndFailedStationaryRetryIsBoundedBothAxes',
    'PicShotTests.LiveScrollAssemblerTransactionTests/testStationaryPreviewRecoveryPreservesAcceptedStateAndSpoolBothDirectionsAndAxes',
    'PicShotTests.LiveScrollAssemblerTransactionTests/testStationaryPreviewRecoveryPropagatesCancellationAndCloseCannotResurrectBothAxes',
    'PicShotTests.LiveScrollAutomaticInteractionTests/testCommittedAndPendingPreviewRecoveryEnablesAutoWithoutRearmingOrChangingOutput',
    'PicShotTests.LiveScrollAutomaticInteractionTests/testFailedStationaryRetryKeepsLastGoodThumbnailAndAutoDisabled',
    'PicShotTests.LiveScrollAutomaticInteractionTests/testInitialPreviewFailureRecoversStationaryPositionWithoutStartingAuto',
    'PicShotTests.LiveScrollAutomaticInteractionTests/testStationaryPreviewRecoveryAfterPauseOrMoveStillRequiresExplicitAutoToggle',
)


PRESERVED278_NATIVE_INVENTORY = (2440, 272, 'd951f8ac10252217989e958a6e216662f9f700dfbfd8ce7546ce9df263d2e0fe')
PRESERVED278_FOCUSED_INVENTORY = (1908, '93709150a83a2a3a8c09cc3f79cc9531651f570892ca581b51c7d890886c09ad')
CURRENT_NATIVE_INVENTORY = (2446, 272, 'cb4c7562b61acbe85a76baab2cfad28c601de3b197eb97340c74f134075da8f0')
CURRENT_FOCUSED_INVENTORY = (1914, 'a2b347f3dcdc7e010730706a8db5ba5886392dd41bb69daa7dd1f79c2eb05e6a')
SCROLL_GUIDANCE_ADDITIONS = (
    'PicShotTests.LiveScrollAssemblerTransactionTests/testLostOverlapAdvicePreservesLastGoodPixelsAndAnchorBothAxes',
    'PicShotTests.LiveScrollAssemblerTransactionTests/testUncertainPlainTextBoundaryAdvicePreservesSeedAndRecoversForwardBothAxes',
    'PicShotTests.LiveScrollAssemblerTransactionTests/testUnsupportedFixedContentAdviceKeepsAcceptedImageFinishableBothAxes',
    'PicShotTests.LiveScrollAutomaticInteractionTests/testLostOverlapWarningSurvivesManualAndAutomaticSessionAndKeepsFinishPixels',
    'PicShotTests.LiveScrollAutomaticInteractionTests/testUncertainArticleWarningSurvivesAutoStopAndForwardRecoveryRequiresExplicitAuto',
    'PicShotTests.LiveScrollAutomaticInteractionTests/testUnsupportedFixedContentWarningSurvivesAutoStopAndKeepsFinishPixels',
)
SCROLL_CHAIN_ADDITIONS = (
    'PicShotTests.CaptureChainPreparedInputTests/testAll15OrdersAndEveryReceiptPrefixDispatchOnlySuffixUsingIdenticalPreparedImage',
    'PicShotTests.CaptureChainPreparedInputTests/testCancellationAtEveryOutputBoundaryContinuesWithFreshRunIDAndNoPrefixReplay',
    'PicShotTests.CaptureChainPreparedInputTests/testCommittedSaveBeforeCancelDrainRemainsInContinuationAndDoesNotSaveAgain',
    'PicShotTests.CaptureChainPreparedInputTests/testEachFailedOutputReentrantRetryPreservesCommittedPrefixAndNeverAcquires',
    'PicShotTests.CaptureChainPreparedInputTests/testFinalCommitReentrantCancelHasCompleteReceiptAndPreparedReplayDispatchesNothing',
    'PicShotTests.CaptureChainPreparedInputTests/testPinThenSavePickerCancellationContinuesOnlySaveAndCopy',
    'PicShotTests.CaptureChainPreparedInputTests/testPreparedCompletionReleasesProviderWithoutKeepingImageInTerminalSnapshot',
    'PicShotTests.CaptureChainPreparedInputTests/testPreparedReceiptValidationRejectsOutOfOrderMismatchedAndOverlongPrefixesBeforeDispatch',
    'PicShotTests.CaptureChainPreparedInputTests/testSharedCheckpointProviderSurvivesCancelledSaveOnlyUntilBothOwnersRelease',
    'PicShotTests.LiveScrollChainAppIntegrationTests/testAppCountsSharedRasterOnceAcrossCancelAndBlocksUnrelatedCaptureUntilAbandoned',
    'PicShotTests.LiveScrollChainAppIntegrationTests/testDirectEditorAdmissionIncludesCancelledCheckpointAtExactByteBoundary',
    'PicShotTests.LiveScrollChainAppIntegrationTests/testFullCloseDuringSaveKeepsAppReservationUntilDrainAndNeverMutatesCatalogOrDefaults',
    'PicShotTests.LiveScrollChainAppIntegrationTests/testStaleRunnerManagerAndOldSessionCloseCannotCancelContinuationOrSuccessorSession',
    'PicShotTests.LiveScrollChainChoiceControllerTests/testLongNamesAndReceiptWarningsFitFullNativeFramesAt460PointsInBothAppearances',
    'PicShotTests.LiveScrollChainChoiceControllerTests/testNativeReturnConfirmsExplicitSelectionOnceAndEscapeCancelsWithoutAutomaticRun',
    'PicShotTests.LiveScrollChainChoiceControllerTests/testRetiredSheetCommandsCannotCompleteOrCancelReentrantlyPresentedSuccessor',
    'PicShotTests.LiveScrollChainSessionTests/testActualExactly32MillionPixelsPassesPostDrainAndRenderedImageChecksOnce',
    'PicShotTests.LiveScrollChainSessionTests/testActualPostDrainPixelCrossingRejectsSaveThenPinBeforeRenderAndAnyOutput',
    'PicShotTests.LiveScrollChainSessionTests/testAll15OrdersRenderOnceAcquireNothingAndDeliverIdenticalFrozenPixels',
    'PicShotTests.LiveScrollChainSessionTests/testCancellationAtFinalCommitFinishesOwnerWithoutOfferingReplayForEveryOutputType',
    'PicShotTests.LiveScrollChainSessionTests/testContinuationPreflightChecksOnlyUncommittedOutputsAfterPinAlreadyCommitted',
    'PicShotTests.LiveScrollChainSessionTests/testExplicitAbandonReleasesCheckpointBeforeResumeAndStaleTransactionCannotControlSuccessor',
    'PicShotTests.LiveScrollChainSessionTests/testFullCloseAndRunnerCancelAwaitOneOwnedSaveDrainBeforeReleasingProviderAndClosingOnce',
    'PicShotTests.LiveScrollChainSessionTests/testFullCloseWaitsForHeldPreparationAndLateCompletionCannotRenderOrOutput',
    'PicShotTests.LiveScrollChainSessionTests/testOwnedChoiceSelectionAndEscapeDoNotRunAndRetiredSheetCannotAffectReopenedSession',
    'PicShotTests.LiveScrollChainSessionTests/testPendingCheckpointRejectsForcedOrdinaryOutputCaptureMoveAndAxisActions',
    'PicShotTests.LiveScrollChainSessionTests/testPreflightRefusalAtEachPreparationBoundaryDispatchesNoOutputs',
    'PicShotTests.LiveScrollChainSessionTests/testReplacementWarningCancelAndInvalidSelectionPreserveCheckpointThenExplicitNewChainReusesRaster',
    'PicShotTests.LiveScrollChainSessionTests/testSaveFailureCancelBackReopenAndContinueKeepsFrozenDefinitionPrefixAndFreshAttemptID',
    'PicShotTests.LiveScrollChainSessionTests/testUnconfirmedStopAfterCompleteChainRemainsTerminalAndStaleMoreCannotReplay',
    'PicShotTests.LiveScrollChainTransactionTests/testCancelledAttemptExtendsOnlyMatchingPrefixAndKeepsFrozenIdentitiesAndRaster',
    'PicShotTests.LiveScrollChainTransactionTests/testFullCommittedPrefixIsCompleteDespiteCancellationAndNewTransactionIntentionallyResetsOnlyReceipts',
    'PicShotTests.LiveScrollChainTransactionTests/testStaleNonterminalWrongModeDefinitionAndRewrittenReceiptCallbacksLeaveCheckpointUntouched',
)
SCROLL_CHAIN_CHOICE_ADDITIONS = (
    'PicShotTests.LiveScrollChainChoiceControllerTests/testLongNamesAndReceiptWarningsFitFullNativeFramesAt460PointsInBothAppearances',
    'PicShotTests.LiveScrollChainChoiceControllerTests/testNativeReturnConfirmsExplicitSelectionOnceAndEscapeCancelsWithoutAutomaticRun',
    'PicShotTests.LiveScrollChainChoiceControllerTests/testRetiredSheetCommandsCannotCompleteOrCancelReentrantlyPresentedSuccessor',
    'PicShotTests.LiveScrollChainSessionTests/testOwnedChoiceSelectionAndEscapeDoNotRunAndRetiredSheetCannotAffectReopenedSession',
)


def scroll_guidance_additions(inventory):
    """The six guidance methods preserve the exact delivered278 native union."""
    need(type(inventory) is list and all(type(name) is str for name in inventory)
         and inventory == sorted(set(inventory)), 'Native discovery must contain unique sorted IDs')
    added = set(SCROLL_GUIDANCE_ADDITIONS)
    need(added.issubset(inventory), 'Explicit279 scroll guidance methods missing or renamed')
    preserved = [name for name in inventory if name not in added]
    need((len(preserved), len({name.split('/')[0] for name in preserved}),
          hashlib.sha256(('\n'.join(preserved)+'\n').encode()).hexdigest()) == PRESERVED278_NATIVE_INVENTORY,
         'Preserved278 native IDs changed')
    return added


def check_focused_inventory(inventory):
    need(type(inventory) is list and all(type(name) is str for name in inventory)
         and inventory == sorted(set(inventory)), 'Focused discovery must contain unique sorted IDs')
    guidance = set(SCROLL_GUIDANCE_ADDITIONS)
    need(guidance.issubset(inventory), 'All6 guidance methods must be selected in both plans')
    preserved = [name for name in inventory if name not in guidance]
    need((len(preserved), hashlib.sha256(('\n'.join(preserved)+'\n').encode()).hexdigest())
         == PRESERVED278_FOCUSED_INVENTORY, 'Preserved278 focused native IDs changed')
    need((len(inventory), hashlib.sha256(('\n'.join(inventory)+'\n').encode()).hexdigest())
         == CURRENT_FOCUSED_INVENTORY, 'Current focused native inventory changed')


def scroll_chain_additions(inventory):
    """The new source slice is additive to every delivered268 method identity."""
    added = set(SCROLL_CHAIN_ADDITIONS)
    need(added and added.issubset(inventory), 'Existing-image chain additions are missing or renamed')
    classes = {name.split('/')[0] for name in added}
    need(sorted(added) == [name for name in inventory if name.split('/')[0] in classes],
         'Existing-image chain class has an unrecorded method')
    return added


def text_script_additions(inventory):
    """Bind exact266 additions while preserving all265/263 and accepted248 IDs."""
    current_inventory = inventory
    guidance_ids = scroll_guidance_additions(inventory)
    preserved278 = [name for name in inventory if name not in guidance_ids]
    inventory = preserved278
    scroll_ids = scroll_chain_additions(inventory)
    inventory = [name for name in inventory if name not in scroll_ids]
    added = json.loads(read(Path('scripts/text-script-integration-tests.json')))
    need(type(added) is list and len(added) == 72
         and all(type(name) is str and re.fullmatch(r'PicShot(?:CoreTests|Tests|TextScriptCoreTests|TextScriptHelperTests)\.TextScript\w+Tests/test\w+', name) for name in added)
         and added == sorted(set(added))
         and hashlib.sha256(('\n'.join(added)+'\n').encode()).hexdigest()
         == 'fabb6746e6dff19fa4aae030f48b722260a4f648f7223d685ee449120d1b6ebf',
         'Explicit72 text script IDs differ')
    need(type(inventory) is list and all(type(name) is str for name in inventory)
         and inventory == sorted(set(inventory)), 'Native discovery must contain unique sorted IDs')
    need(added == [name for name in inventory if '.TextScript' in name],
         'Text script methods lost or added outside the explicit inventory')
    payload = save_payload_additions(inventory)
    preserved265 = [name for name in inventory if name not in payload]
    recovery = set(SCROLL_RECOVERY_ADDITIONS)
    need(recovery.issubset(inventory), 'Explicit264 scroll recovery methods missing or renamed')
    baseline = [name for name in preserved265 if name not in recovery]
    original = [name for name in baseline if name not in set(added)]
    need(len(original) == 2303 and hashlib.sha256(('\n'.join(original)+'\n').encode()).hexdigest()
         == '7366868482823631d5939adc3b411ff4d538c2c59090c2e35ebdea396b9e41ca',
         'Accepted248 native IDs changed')
    need(len(baseline) == 2375 and len({name.split('/')[0] for name in baseline}) == 267 and hashlib.sha256(('\n'.join(baseline)+'\n').encode()).hexdigest()
         == '0f19081756c225e5b0fede62805ee01693d1409bf6552979ac74db409e3e4aab',
         'Preserved263 native discovery differs from the exact2375 ID union')
    need(len(preserved265) == 2382 and len({name.split('/')[0] for name in preserved265}) == 267
         and hashlib.sha256(('\n'.join(preserved265)+'\n').encode()).hexdigest()
         == 'a88b82f2a8e8828ee7e0ce31b52340106f32f37b8e831599d2859281ed876f7c', 'Preserved265 native discovery differs from the exact2382 ID union')
    need(len(inventory) == 2407 and len({name.split('/')[0] for name in inventory}) == 267
         and hashlib.sha256(('\n'.join(inventory)+'\n').encode()).hexdigest()
         == '5c7d51efe5e1fc16a1d3dd5c5d5fc4ae35948893fc7e5feb92aaf7c83c9f5539', 'Current native discovery differs from the exact2407 ID union')
    need((len(current_inventory), len({name.split('/')[0] for name in current_inventory}),
          hashlib.sha256(('\n'.join(current_inventory)+'\n').encode()).hexdigest()) == CURRENT_NATIVE_INVENTORY,
         'Current native discovery differs from the exact additive guidance union')
    preserved269 = [name for name in preserved278 if name not in SCROLL_CHAIN_CHOICE_ADDITIONS]
    need(len(preserved269) == 2436 and hashlib.sha256(('\n'.join(preserved269)+'\n').encode()).hexdigest()
         == '38a94e9f556705bb7b34260cca519f70d8058e59ef4f12b0701cf1a65ad79d07',
         'Preserved269 native IDs changed')
    return set(added)


TEXT_SCRIPT_EVIDENCE_FILES = {'text-script-installed.json', 'text-script-installed.json.launcher.json',
    'text-script-demo.json', 'package-proof', 'text-script-source.png', 'text-script-copied.txt',
    'text-script-retry-catalog.json', 'text-script-close-catalog.json',
    'text-script-retry-case.json', 'text-script-close-case.json'} | {
    phase + '-' + mode + suffix for phase in ('text-script-editor', 'text-script-retry-failure',
                                             'text-script-result', 'text-script-close-failure')
    for mode in ('light', 'dark') for suffix in ('.png', '-layout.json')}


def installed_text_scripts(source, formats):
    """Rebind both strict native receipts after smoke removes its working apps."""
    need(type(formats.get('formats')) is dict and set(formats['formats']) == {'zip', 'dmg'},
         'Both actual installed formats required for text scripts')
    proof_path = Path('dist/text-script-package-proof.json')
    proof = load(proof_path)
    fields(proof, dict(schemaVersion=1, sourceCommit=source['sourceCommit'], version=source['version'],
        build=source['build'], architectures=[source['architecture']], executableSHA256=source['executableSHA256'],
        appInfoPlistSHA256=source['plistSHA256'], buildInfoSHA256=source['buildInfoSHA256'],
        appSignatureVerified=True, sameTeamIdentifierVerified=True, relocationVerified=True,
        helperEntitlementsVerifiedAfterOuterSigning=True, helperSignedInfoPlistVerifiedAfterOuterSigning=True,
        installedRuntimeAcceptanceVerified=False), 'original signed text script package')
    helper = proof.get('helper')
    fields(helper, dict(path='Contents/Helpers/PicShotTextScriptHelper', identifier='com.picshot.TextScriptHelper',
        strictSignatureVerified=True), 'text helper')
    entitlements = helper.get('entitlements')
    need(type(entitlements) is dict and set(entitlements) == {'com.apple.security.app-sandbox'}
         and entitlements['com.apple.security.app-sandbox'] is True,
         'Text helper requires the sole Boolean sandbox entitlement')
    need(type(helper.get('sha256')) is str and re.fullmatch('[0-9a-f]{64}', helper['sha256'])
         and type(helper.get('cdHash')) is str and re.fullmatch('[0-9a-f]{40}', helper['cdHash']), 'Text helper hashes differ')
    checked = {}
    for extension in ('zip', 'dmg'):
        root = Path('dist/evidence')/extension/'text-script'
        need(root.is_dir() and not root.is_symlink(), 'Missing/symlinked installed text directory')
        installed = formats['formats'][extension]
        app = installed.get('bundlePath')
        need(type(app) is str and app.startswith('/') and '..' not in Path(app).parts
             and app.endswith('/' + extension + '/PicShot.app'), 'Installed text bundle path differs')
        fields(installed, dict(buildVersion=source['build'], **{key: source[key] for key in
            ('sourceCommit', 'version', 'architecture', 'executableSHA256', 'plistSHA256', 'buildInfoSHA256')}),
            extension + ' text installed identity')
        path = root/'text-script-receipt.json'
        receipt = load(path)
        fields(receipt, dict(schemaVersion=1, status='passed', installerAcceptance=False,
            realScreenCaptureAcceptance=False, original227MemoryAcceptance=False, hardMemoryCapClaimed=False,
            exactGeneratedTextOutputVerified=True, onceOnlyCaptureOCRTransformVerified=True,
            checkedCopyRetryAndCloseVerified=True, sourceAndFinalPackageBound=True,
            scope='Installed saved editor and region/OCR/script/Copy owner; generated acquisition, actual Apple Vision and signed production helper, checked private clipboard'),
            extension + ' installed text receipt')
        identity = dict(appPath=app, helperSHA256=helper['sha256'], helperCDHash=helper['cdHash'],
            **{key: source[key] for key in ('sourceCommit', 'build', 'version', 'architecture', 'executableSHA256')})
        fields(receipt.get('sourceIdentity'), identity, extension + ' text source identity')
        need(read(root/'package-proof.json') == read(proof_path), 'Installed helper proof differs from original signed package')
        hashes = receipt.get('evidenceSHA256')
        need(type(hashes) is dict and set(hashes) == TEXT_SCRIPT_EVIDENCE_FILES, 'Complete fixed text evidence set required')
        total = 0
        for name, expected in hashes.items():
            need(type(expected) is str and re.fullmatch('[0-9a-f]{64}', expected), 'Invalid retained text digest')
            data = read(root/('package-proof.json' if name == 'package-proof' else name))
            total += len(data)
            need(total <= 96*1024**2, 'Retained text evidence exceeds96MiB')
            need(hashlib.sha256(data).hexdigest() == expected, 'Installed text evidence changed: '+name)
        command_hashes = {}
        for stem, timeout, command in (
            ('proof', 180, ['python3', 'scripts/verify-text-script-package.py', '--app', app,
                            '--source', source['sourceCommit'], '--report', str((root/'package-proof.json').resolve()), '--verify-relocation']),
            ('launch', 270, ['swift', 'scripts/launch-smoke-app.swift', app, str((root/'text-script-installed.json').resolve())]),
            ('check', 120, ['python3', 'scripts/check-text-script-demo.py', '--report',
                            str((root/'text-script-installed.json').resolve()), '--source', source['sourceCommit'],
                            '--package-proof', str((root/'package-proof.json').resolve()), '--source-root', str(Path.cwd())])):
            report_path, log_path = root/(stem+'-report.json'), root/(stem+'.log')
            run = load(report_path)
            runner(run, timeout, 10, extension + ' text '+stem)
            fields(run, dict(schema_version=1, max_log_bytes=1048576, command=command), 'bounded text '+stem)
            need(log_path.is_file() and not log_path.is_symlink() and log_path.stat().st_size <= 1048576,
                 'Missing/symlinked/oversized text command log')
            log = log_path.read_bytes()
            need(type(run.get('log_bytes')) is int and type(run.get('output_bytes')) is int
                 and run['log_bytes'] == run['output_bytes'] == len(log), 'Text command log byte counts differ')
            command_hashes[report_path.name] = sha(report_path)
            command_hashes[log_path.name] = hashlib.sha256(log).hexdigest()
        checked[extension] = dict(receiptPath=str(path), receiptSHA256=sha(path), sourceIdentity=identity,
            evidenceSHA256=hashes, boundedCommandSHA256=command_hashes)
    need(checked['zip']['sourceIdentity']['appPath'] != checked['dmg']['sourceIdentity']['appPath'],
         'Installed text formats reused one bundle')
    return checked


def archive_text_scripts():
    """Keep separate bounded diagnostics, including failed/incomplete witnesses."""
    output = Path('dist/text-script-installed-evidence')
    for extension in ('zip', 'dmg'):
        root = Path('dist/evidence')/extension/'text-script'
        if not root.exists():
            continue
        need(root.is_dir() and not root.is_symlink(), 'Unsafe installed text evidence directory')
        files = sorted(root.iterdir())
        need(files and len(files) <= 48, 'Installed text evidence file-count bound')
        total = 0
        for path in files:
            need(path.is_file() and not path.is_symlink() and path.suffix in ('.json', '.png', '.log', '.txt')
                 and path.stat().st_size <= 16*1024**2, 'Unsafe/oversized installed text evidence file')
            total += path.stat().st_size
        need(total <= 96*1024**2, 'Installed text evidence exceeds96MiB')
        for identity in (Path('dist/text-script-package-proof.json'), Path('dist/evidence/installed-format-identity.json'),
                         ROOT/'source-identity.json', ROOT/'experimental-distribution.json'):
            if identity.exists():
                read(identity, 1024**2)
                files.append(identity)
        output.mkdir(parents=True, exist_ok=True)
        target, partial = output/(extension+'.zip'), output/(extension+'.partial.zip')
        need(not target.exists() and not target.is_symlink() and not partial.exists() and not partial.is_symlink(),
             'Fresh installed text archive destination required')
        with zipfile.ZipFile(partial, 'x', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for path in files:
                archive.write(path, str(path))
        need(partial.stat().st_size < 20*1024**2 - 65536, 'Installed text archive exceeds20MiB')
        partial.rename(target)


CHAIN_EVIDENCE_FILES = {'demo.json', 'demo.json.launcher.json', 'capture-chain-demo.json',
    'chain-source-numbered.png', 'chain-saved.png', 'chain-copied.png', 'chain-pin.png',
    'chain-pin-reloaded.png', 'chain-close-saved.png', 'chain-catalog.json', 'chain-close-catalog.json'} | {
    phase + '-' + mode + suffix for phase in ('chain-manager', 'chain-copy-failure', 'chain-result', 'chain-close-failure')
    for mode in ('light', 'dark') for suffix in ('.png', '-layout.json')}


def installed_capture_chains(source, formats):
    """Rebind retained receipts after smoke removed its installed working bundles.

    The strict chain checker already decoded every raster while each exact app
    existed. This final read requires those unchanged bytes, identities and both
    successful bounded commands; it does not rerun native work or memory cells.
    """
    need(type(formats.get('formats')) is dict and set(formats['formats']) == {'zip', 'dmg'},
         'Both actual installed formats required for capture chains')
    checked = {}
    for extension in ('zip', 'dmg'):
        root = Path('dist/evidence')/extension/'capture-chain'
        need(root.is_dir() and not root.is_symlink(), 'Missing/symlinked installed chain directory')
        installed = formats['formats'][extension]
        app = installed.get('bundlePath')
        need(type(app) is str and app.startswith('/') and '..' not in Path(app).parts
             and app.endswith('/' + extension + '/PicShot.app'), 'Installed chain bundle path differs')
        path = root/'capture-chain-receipt.json'
        receipt = load(path)
        fields(receipt, dict(schemaVersion=1, status='passed', installerAcceptance=False,
            realScreenCaptureAcceptance=False, memoryQualification=False, exactDecodedOutputPixels=True,
            savedReceiptPhysicalBytesVerified=True, unchangedMetadataOnlyCatalogVerified=True,
            nativeOwnedActionRoute='PortableSettingsUIPreviewFixture.click: owned NSButton.mouseDown with queued mouseUp; NSTableView: owned-nextEvent-sendEvent',
            scope='Installed native controls and output recipients with injected acquisition; bounded ownership observations only'),
            extension + ' installed chain receipt')
        identity = dict(bundlePath=app, executablePath=app+'/Contents/MacOS/PicShot',
            **{key: source[key] for key in ('sourceCommit', 'build', 'version', 'architecture',
                'executableSHA256', 'plistSHA256', 'buildInfoSHA256')})
        fields(receipt.get('sourceIdentity'), identity, extension + ' chain source identity')
        fields(installed, dict(buildVersion=source['build'], **{key: source[key] for key in
            ('sourceCommit', 'version', 'architecture', 'executableSHA256', 'plistSHA256', 'buildInfoSHA256')}),
            extension + ' chain installed identity')
        hashes = receipt.get('evidenceSHA256')
        need(type(hashes) is dict and set(hashes) == CHAIN_EVIDENCE_FILES, 'Complete fixed chain evidence set required')
        total = 0
        for name, expected in hashes.items():
            need(type(expected) is str and re.fullmatch('[0-9a-f]{64}', expected), 'Invalid retained chain digest')
            data = read(root/name)
            total += len(data)
            need(total <= 96*1024**2, 'Retained chain evidence exceeds96MiB')
            need(hashlib.sha256(data).hexdigest() == expected, 'Installed chain evidence changed: '+name)
        command_hashes = {}
        for stem, timeout, command in (
            ('launch', 270, ['swift', 'scripts/launch-smoke-app.swift', app, str((root/'demo.json').resolve())]),
            ('check', 120, ['python3', 'scripts/check-capture-chain-demo.py', '--report',
                            str((root/'demo.json').resolve()), '--source', source['sourceCommit']])):
            report_path, log_path = root/(stem+'-report.json'), root/(stem+'.log')
            run = load(report_path)
            runner(run, timeout, 10, extension + ' chain '+stem)
            fields(run, dict(schema_version=1, max_log_bytes=1048576, command=command), 'bounded chain '+stem)
            need(log_path.is_file() and not log_path.is_symlink() and log_path.stat().st_size <= 1048576,
                 'Missing/symlinked/oversized chain command log')
            log = log_path.read_bytes()
            need(len(log) <= 1048576 and type(run.get('log_bytes')) is int
                 and type(run.get('output_bytes')) is int and run['log_bytes'] == run['output_bytes'] == len(log),
                 'Chain command log byte counts differ')
            command_hashes[report_path.name] = sha(report_path)
            command_hashes[log_path.name] = hashlib.sha256(log).hexdigest()
        checked[extension] = dict(receiptPath=str(path), receiptSHA256=sha(path), sourceIdentity=identity,
            evidenceSHA256=hashes, boundedCommandSHA256=command_hashes)
    need(checked['zip']['sourceIdentity']['bundlePath'] != checked['dmg']['sourceIdentity']['bundlePath'],
         'Installed chain formats reused one bundle')
    return checked


def archive_capture_chains():
    """Retain bounded per-format diagnostics even when a native witness failed."""
    output = Path('dist/capture-chain-installed-evidence')
    for extension in ('zip', 'dmg'):
        root = Path('dist/evidence')/extension/'capture-chain'
        if not root.exists():
            continue
        need(root.is_dir() and not root.is_symlink(), 'Unsafe installed chain evidence directory')
        files = sorted(root.iterdir())
        need(files and len(files) <= 40, 'Installed chain evidence file-count bound')
        total = 0
        for path in files:
            need(path.is_file() and not path.is_symlink() and path.suffix in ('.json', '.png', '.log')
                 and path.stat().st_size <= 16*1024**2, 'Unsafe/oversized installed chain evidence file')
            total += path.stat().st_size
        need(total <= 96*1024**2, 'Installed chain evidence exceeds96MiB')
        for identity in (Path('dist/evidence/installed-format-identity.json'), ROOT/'source-identity.json',
                         ROOT/'experimental-distribution.json'):
            if identity.exists():
                read(identity, 1024**2)
                files.append(identity)
        output.mkdir(parents=True, exist_ok=True)
        target, partial = output/(extension+'.zip'), output/(extension+'.partial.zip')
        need(not target.exists() and not target.is_symlink() and not partial.exists() and not partial.is_symlink(),
             'Fresh installed chain archive destination required')
        with zipfile.ZipFile(partial, 'x', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for path in files:
                archive.write(path, str(path))
        need(partial.stat().st_size < 20*1024**2 - 65536, 'Installed chain archive exceeds20MiB')
        partial.rename(target)


def installed_scroll_chains(source, formats):
    """Bind the new route to both actual installed bundles without new launches."""
    need(type(formats.get('formats')) is dict and set(formats['formats']) == {'zip', 'dmg'},
         'Both actual installed formats required for existing-image chains')
    checked = {}
    for extension in ('zip', 'dmg'):
        root = Path('dist/evidence')/extension/'live-scroll'
        need(root.is_dir() and not root.is_symlink(), 'Missing/symlinked installed live-scroll directory')
        installed = formats['formats'][extension]
        app = installed.get('bundlePath')
        need(type(app) is str and app.startswith('/') and '..' not in Path(app).parts
             and app.endswith('/' + extension + '/PicShot.app'), 'Installed live-scroll bundle path differs')
        identity = dict(bundlePath=app, executablePath=app+'/Contents/MacOS/PicShot',
            **{key: source[key] for key in ('sourceCommit', 'build', 'version', 'architecture',
                'executableSHA256', 'plistSHA256', 'buildInfoSHA256')})
        fields(installed, dict(buildVersion=source['build'], **{key: source[key] for key in
            ('sourceCommit', 'version', 'architecture', 'executableSHA256', 'plistSHA256', 'buildInfoSHA256')}),
            extension + ' existing-image chain installed identity')
        demo = load(root/'demo.json')
        fields(demo, dict(bundlePath=app, **{key: source[key] for key in ('sourceCommit', 'build', 'version')}),
               extension + ' live-scroll demo identity')
        demo_fields(demo)
        files = scroll_chain_evidence(root/'saved-image-chain', demo, source['sourceCommit'])
        launcher_path = root/'demo.json.launcher.json'
        launcher = load(launcher_path)
        fields(launcher, dict(status='exited', launcherExitCode=0, callbackReceived=True,
            createsNewApplicationInstance=True, ownedExitConfirmed=True, launchedIdentityMatches=True,
            timeoutSeconds=600, selectedAppPath=app, launchedAppPath=app,
            launchedExecutablePath=identity['executablePath']), extension + ' live-scroll launcher')
        number(launcher.get('processIdentifier'), extension + ' live-scroll pid', 1)
        number(launcher.get('elapsedSeconds'), extension + ' live-scroll elapsed', 0, 600)
        files += [root/'demo.json', launcher_path]
        command_hashes = {}
        for stem, timeout, command in (
            ('launch', 660, ['swift', 'scripts/launch-smoke-app.swift', app, str((root/'demo.json').resolve())]),
            ('check', 120, ['python3', 'scripts/check-live-scroll-chain-demo.py', '--report',
                str((root/'saved-image-chain/live-scroll-chain.json').resolve()), '--source', source['sourceCommit']])):
            report_path, log_path = root/(stem+'-report.json'), root/(stem+'.log')
            run = load(report_path)
            runner(run, timeout, 10, extension + ' existing-image chain '+stem)
            fields(run, dict(schema_version=1, max_log_bytes=1048576, command=command), 'bounded live-scroll '+stem)
            need(log_path.is_file() and not log_path.is_symlink() and log_path.stat().st_size <= 1048576,
                 'Missing/symlinked/oversized live-scroll command log')
            raw = log_path.read_bytes()
            need(len(raw) <= 1048576 and type(run.get('log_bytes')) is int
                 and type(run.get('output_bytes')) is int and run['log_bytes'] == run['output_bytes'] == len(raw),
                 'Live-scroll command log byte counts differ')
            command_hashes[report_path.name] = sha(report_path)
            command_hashes[log_path.name] = hashlib.sha256(raw).hexdigest()
        checked[extension] = dict(sourceIdentity=identity, boundedCommandSHA256=command_hashes,
            evidenceSHA256={str(path.relative_to(root)): sha(path) for path in files})
    need(checked['zip']['sourceIdentity']['bundlePath'] != checked['dmg']['sourceIdentity']['bundlePath'],
         'Installed existing-image chain formats reused one bundle')
    return checked


def archive_scroll_chains():
    # Keep all raw demo failures, native images and bounded logs even when a
    # strict reader refused them. Archive bounds are the existing evidence caps.
    output = Path('dist/live-scroll-chain-installed-evidence')
    for extension in ('zip', 'dmg'):
        root = Path('dist/evidence')/extension/'live-scroll'
        if not root.exists():
            continue
        need(root.is_dir() and not root.is_symlink(), 'Unsafe installed live-scroll evidence directory')
        files = []
        for path in root.rglob('*'):
            need(not path.is_symlink(), 'Symlinked installed live-scroll evidence')
            if path.is_dir():
                continue
            need(path.is_file() and path.stat().st_size <= 16*1024**2, 'Unsafe/oversized installed live-scroll file')
            files.append(path)
        for path in (Path('dist/evidence/installed-format-identity.json'), ROOT/'source-identity.json',
                     ROOT/'experimental-distribution.json'):
            if path.is_file():
                read(path); files.append(path)
        need(files and len(files) <= 500 and sum(path.stat().st_size for path in files) < 256*1024**2,
             'Installed live-scroll archive exceeds raw evidence bound')
        output.mkdir(parents=True, exist_ok=True)
        target, partial = output/(extension+'.zip'), output/(extension+'.partial.zip')
        need(not target.exists() and not partial.exists() and not target.is_symlink() and not partial.is_symlink(),
             'Fresh installed live-scroll archive destination required')
        with zipfile.ZipFile(partial, 'x', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for path in sorted(files):
                archive.write(path, str(path))
        need(partial.stat().st_size < 20*1024**2 - 65536, 'Installed live-scroll archive exceeds20MiB')
        partial.rename(target)


def final():
    source = source_record()
    receipt = qualify()
    need(receipt == load(ROOT/'interaction-receipt.json'), 'Interaction evidence changed after qualification')
    steps = json.loads(os.environ['PICSHOT_WORKFLOW_STEPS'])
    validate_outcomes(steps)
    formats = load(Path('dist/evidence/installed-format-identity.json'))
    fields(formats, dict(status='passed', exactInstalledBinaryIdentity=True), 'actual ZIP+DMG')
    for extension in ('zip', 'dmg'):
        fields(formats.get('formats', {}).get(extension), dict(buildVersion=source['build'],
               **{key: source[key] for key in ('sourceCommit', 'version', 'architecture', 'executableSHA256',
                                             'plistSHA256', 'buildInfoSHA256')}), 'actual ' + extension)
    chain_receipts = installed_capture_chains(source, formats)
    text_receipts = installed_text_scripts(source, formats)
    scroll_chain_receipts = installed_scroll_chains(source, formats)
    spec = importlib.util.spec_from_file_location('native', Path('scripts/native-test-shards.py'))
    native = importlib.util.module_from_spec(spec); spec.loader.exec_module(native)
    for kind, planfile, directory, reportfile in (
            ('full', 'native-tests-plan.json', 'native-test-shards', 'test-report.json'),
            ('focused', 'focused-tests-plan.json', 'focused-test-shards', 'critical-tests-report.json')):
        plan = native.checked_plan(Path('dist')/planfile, source['sourceCommit'])
        text_ids = text_script_additions(plan['discoveredTests'])
        guidance_ids = scroll_guidance_additions(plan['discoveredTests'])
        need(guidance_ids <= set(plan['selectedTests']), 'All6 guidance methods must be selected in both plans')
        scroll_ids = scroll_chain_additions(plan['discoveredTests'])
        need(scroll_ids <= set(plan['selectedTests']), 'All existing-image chain methods must be selected in both plans')
        need(text_ids <= set(plan['selectedTests']), 'All72 script methods must be selected in both plans')
        payload_ids = save_payload_additions(plan['discoveredTests'])
        need(payload_ids <= set(plan['selectedTests']), 'All25 Save payload methods must be selected in both plans')
        recovery_ids = set(SCROLL_RECOVERY_ADDITIONS)
        need(recovery_ids <= set(plan['selectedTests']), 'All7 recovery methods must be selected in both plans')
        if kind == 'full':
            live = json.loads(read(Path('scripts/live-scroll-additive-tests.json')))
            need(live == [name for name in plan['discoveredTests'] if '.LiveScroll' in name]
                 and len(live) == 195, 'All preserved and new live methods required')
            feedback = feedback_additions(plan['discoveredTests'])
            chains = chain_additions(plan['discoveredTests'])
            stable = [name for name in plan['discoveredTests'] if name not in set(live) | feedback | chains | text_ids | payload_ids | scroll_ids]
            need(len(stable) == 2047 and hashlib.sha256(('\n'.join(stable)+'\n').encode()).hexdigest()
                 == '926ac5674df90163b949fe461f0d4589ef72c8fc3215fa00b927564aae57cb44', 'Stable214 inventory changed')
            need(plan['selectedTests'] == plan['discoveredTests'], 'Full suite narrowed')
        if kind == 'focused':
            check_focused_inventory(plan['selectedTests'])
        aggregate = native.aggregate(plan, Path('dist')/directory)
        need(aggregate == load(Path('dist')/reportfile), 'Native aggregate differs: ' + kind)
        need(not (text_ids & set(aggregate['skippedTests'])), 'Script methods must pass without skips: ' + kind)
        need(not (recovery_ids & set(aggregate['skippedTests'])), 'Recovery methods must pass without skips: ' + kind)
        need(not (guidance_ids & set(aggregate['skippedTests'])), 'Guidance methods must pass without skips: ' + kind)
        need(not (payload_ids & set(aggregate['skippedTests'])), 'Save payload methods must pass without skips: ' + kind)
        need(not (scroll_ids & set(aggregate['skippedTests'])), 'Existing-image chain methods must pass without skips: ' + kind)
    record = dict(FLAGS, status='ready-for-user-opted-experimental-distribution', **source,
                  resourceFailurePreserved=PRIOR_FAILURE, remainingWorkflowChecksCompleted=True,
                  currentSourceFullAndFocusedNativeRepeated=True, currentSourceModelSuiteRepeated=True,
                  currentSourceUIAndActualZIPAndDMGChecked=True, ordinaryDefaultResourceGatesRequired=True,
                  requiredWorkflowOutcomes={key: steps[key] for key in REQUIRED_GATES},
                  interactionReceiptSHA256=sha(ROOT/'interaction-receipt.json'),
                  installedFormatsSHA256=sha(Path('dist/evidence/installed-format-identity.json')),
                  currentSourceInstalledChainFormats=chain_receipts,
                  currentSourceInstalledTextScriptFormats=text_receipts,
                  currentSourceInstalledExistingImageChainFormats=scroll_chain_receipts,
                  currentSourceTextScriptMethods=sorted(text_ids),
                  currentSourceScrollGuidanceMethods=sorted(guidance_ids),
                  currentSourceExistingImageChainMethods=sorted(scroll_ids),
                  requiresUserRealCaptureValidation=True, deliveryRepacked=False)
    save(ROOT/'experimental-distribution.json', record)
    for extension in ('zip', 'dmg'):
        package = Path(source['packages'][extension]['path'])
        metadata = package.with_suffix('.build-info.json')
        files = (package, Path(str(package)+'.sha256'), metadata, Path(str(metadata)+'.sha256'),
                 ROOT/'source-identity.json', ROOT/'interaction-receipt.json', ROOT/'experimental-distribution.json')
        need(sum(path.stat().st_size for path in files) < 32 * 1024**2 - 65536, 'Experimental installer artifact exceeds32MiB')


def archive():
    archive_capture_chains()
    archive_text_scripts()
    archive_scroll_chains()
    # Only new experimental evidence is packed here. Ordinary evidence stays intact.
    files = sorted(path for root in (ROOT, EVIDENCE) if root.exists() for path in root.rglob('*') if path.is_file())
    files += [path for path in (Path('dist/experimental-scroll-installed.log'),
                               Path('dist/experimental-scroll-installed-report.json')) if path.is_file()]
    need(files and len(files) <= 500 and sum(path.stat().st_size for path in files) < 256 * 1024**2,
         'Experimental evidence missing or exceeds total bound')
    output = Path('dist/experimental-scroll-evidence'); output.mkdir(parents=True, exist_ok=True)
    need(not list(output.iterdir()), 'Experimental evidence archive output must be fresh')
    target = output/'evidence.partial.zip'
    with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as out:
        for path in files:
            need(not path.is_symlink() and path.stat().st_size < 18 * 1024**2,
                 'Oversized/symlinked evidence: ' + str(path))
            out.write(path, str(path))
    need(target.stat().st_size < 20 * 1024**2 - 65536, 'Experimental evidence exceeds20MiB')
    target.rename(output/'evidence.zip')



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest='action', required=True)
    for action in ('prepare', 'qualify', 'final', 'archive'):
        actions.add_parser(action)
    parent = actions.add_parser('check-parent')
    parent.add_argument('--report', type=Path, required=True)
    for name in ('app', 'source', 'version', 'build'):
        parent.add_argument('--' + name, required=True)
    args = parser.parse_args()
    if args.action == 'check-parent':
        print(json.dumps(check_parent(args.report, args.app, args.source, args.version, args.build), sort_keys=True))
    elif args.action == 'prepare':
        forbid_resource()
        need(not ROOT.exists(), 'Fresh experimental evidence directory required')
        identity = context()
        prefix = selected_prefix(read(SCRIPT))
        save(ROOT/'source-identity.json', dict(identity, **packages(identity)))
        (ROOT/'installed-demo-prefix.sh').write_bytes(prefix)
    elif args.action == 'qualify':
        save(ROOT/'interaction-receipt.json', qualify())
    elif args.action == 'final':
        final()
    else:
        archive()


if __name__ == '__main__':
    main()
