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
import zipfile

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
FLAGS = dict(distribution='user-opted-experimental', userOptedExperimentalDistribution=True,
             installerAcceptance=False, fullMemoryQualification=False, testingPackageEligible=False,
             partialMemoryQualification=False, stable214Unchanged=True, stableInstallerReplacement=False,
             disputedResourceCellRerun=False, scrollingResourceClassifierRun=False,
             publicRelease=False, mainMerged=False, realScreenCaptureAcceptance=False)
# Every ordinary executable gate is required; only the original resource/classifier
# branch and its testing-only distribution/budget are replaced in opt-in mode.
REQUIRED_GATES = ('current_gate_01', 'current_gate_02', 'current_gate_03', 'current_gate_04', 'current_gate_05', 'current_gate_06', 'current_gate_07', 'current_gate_08', 'current_gate_09', 'current_gate_10', 'current_gate_11', 'current_gate_12', 'current_gate_13', 'current_gate_14', 'current_gate_15', 'current_gate_16', 'current_gate_17', 'current_gate_18', 'current_gate_19', 'current_gate_20', 'current_gate_21', 'current_gate_22', 'current_gate_23', 'current_gate_24', 'current_gate_25', 'experimental_scroll_contract', 'experimental_scroll_prepare', 'experimental_scroll_demo', 'experimental_scroll_receipt')


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
    real = demo.get('realStream', {})
    need(type(real) is dict, 'Missing real stream report')
    need(real.get('status') == 'passed' or (real.get('status') == 'blocked'
         and real.get('permissionAlreadyGranted') is False), 'Real stream failed for another reason')
    need(type(demo.get('realScreenCaptureValidated')) is bool
         and demo['realScreenCaptureValidated'] == (real['status'] == 'passed'), 'Real capture report differs')


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
    files = [EVIDENCE/'package-identity.json', EVIDENCE/'demo/demo.json',
             EVIDENCE/'demo/demo.json.launcher.json', EVIDENCE/'demo-launch.json',
             Path('dist/experimental-scroll-installed-report.json')]
    for filename in ('live-scroll-movement-native-drag.png', 'live-scroll-movement-native-dark-drag.png',
                     'live-scroll-movement-native-rollback.png', 'live-scroll-movement-finished.png',
                     'live-scroll-movement-reference.png', 'live-scroll-movement-interaction.gif'):
        path = EVIDENCE/'demo/movement'/filename
        raw = read(path)
        need(raw.startswith(b'\x89PNG\r\n\x1a\n' if filename.endswith('.png') else b'GIF8'), 'Invalid visual: ' + filename)
        files.append(path)
    return dict(FLAGS, status='passed', sourceIdentity=source, originalSelectedAssertionsPreserved=True,
                directDragReleaseEscapeAndStalePreviewVerified=True,
                observedRealStreamStatus=demo['realStream']['status'],
                observedRealScreenCaptureValidated=demo['realScreenCaptureValidated'],
                evidenceSHA256={str(path): sha(path) for path in files})


def validate_outcomes(steps):
    for name in REQUIRED_GATES:
        fields(steps.get(name), dict(outcome='success', conclusion='success'), 'required gate ' + name)
    for name in ('live_scroll_resource', 'scroll_testing_classification', 'scroll_testing_contract'):
        fields(steps.get(name), dict(outcome='skipped', conclusion='skipped'), 'excluded gate ' + name)


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
    spec = importlib.util.spec_from_file_location('native', Path('scripts/native-test-shards.py'))
    native = importlib.util.module_from_spec(spec); spec.loader.exec_module(native)
    for kind, planfile, directory, reportfile in (
            ('full', 'native-tests-plan.json', 'native-test-shards', 'test-report.json'),
            ('focused', 'focused-tests-plan.json', 'focused-test-shards', 'critical-tests-report.json')):
        plan = native.checked_plan(Path('dist')/planfile, source['sourceCommit'])
        need(len(plan['discoveredTests']) == 2178, 'Current2178 native inventory required')
        if kind == 'full':
            live = json.loads(read(Path('scripts/live-scroll-additive-tests.json')))
            need(len(live) == 131 and set(live).issubset(plan['discoveredTests']), 'Current131 live methods required')
            stable = [name for name in plan['discoveredTests'] if name not in set(live)]
            need(len(stable) == 2047 and hashlib.sha256(('\n'.join(stable)+'\n').encode()).hexdigest()
                 == '926ac5674df90163b949fe461f0d4589ef72c8fc3215fa00b927564aae57cb44', 'Stable214 inventory changed')
            need(plan['selectedTests'] == plan['discoveredTests'], 'Full suite narrowed')
        need(native.aggregate(plan, Path('dist')/directory) == load(Path('dist')/reportfile),
             'Native aggregate differs: ' + kind)
    record = dict(FLAGS, status='ready-for-user-opted-experimental-distribution', **source,
                  resourceFailurePreserved=PRIOR_FAILURE, remainingWorkflowChecksCompleted=True,
                  currentSourceFullAndFocusedNativeRepeated=True, currentSourceModelSuiteRepeated=True,
                  currentSourceUIAndActualZIPAndDMGChecked=True, ordinaryDefaultResourceGatesRequired=True,
                  requiredWorkflowOutcomes={key: steps[key] for key in REQUIRED_GATES},
                  interactionReceiptSHA256=sha(ROOT/'interaction-receipt.json'),
                  installedFormatsSHA256=sha(Path('dist/evidence/installed-format-identity.json')),
                  requiresUserRealCaptureValidation=True, deliveryRepacked=False)
    save(ROOT/'experimental-distribution.json', record)
    for extension in ('zip', 'dmg'):
        package = Path(source['packages'][extension]['path'])
        metadata = package.with_suffix('.build-info.json')
        files = (package, Path(str(package)+'.sha256'), metadata, Path(str(metadata)+'.sha256'),
                 ROOT/'source-identity.json', ROOT/'interaction-receipt.json', ROOT/'experimental-distribution.json')
        need(sum(path.stat().st_size for path in files) < 32 * 1024**2 - 65536, 'Experimental installer artifact exceeds32MiB')


def archive():
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
    parser.add_argument('action', choices=('prepare', 'qualify', 'final', 'archive'))
    action = parser.parse_args().action
    if action == 'prepare':
        forbid_resource()
        need(not ROOT.exists(), 'Fresh experimental evidence directory required')
        identity = context()
        prefix = selected_prefix(read(SCRIPT))
        save(ROOT/'source-identity.json', dict(identity, **packages(identity)))
        (ROOT/'installed-demo-prefix.sh').write_bytes(prefix)
    elif action == 'qualify':
        save(ROOT/'interaction-receipt.json', qualify())
    elif action == 'final':
        final()
    else:
        archive()


if __name__ == '__main__':
    main()
