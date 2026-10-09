#!/usr/bin/env python3
"""Two independent unchanged output guards with actual effect-context evidence."""
import argparse
import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import stat


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


E = module('effect_guard_pair', 'check-effect-context-pair.py')
D, C, N, R = E.D, E.C, E.N, E.R
FILENAME = 'effect-context-output-guard.json'
KEYS = {'schemaVersion', 'status', 'diagnosticOnly', 'comparisonKind', 'observationBoundary',
    'sourceCommit', 'version', 'buildVersion', 'bundlePath', 'executablePath', 'executableSHA256',
    'executableBytes', 'processIdentifier', 'nativeReportPath', 'nativeReportBytes', 'nativeReportSHA256',
    'drawingReportSHA256', 'requestedPolicy', 'effectContextPolicy', 'productionDefaultPolicy',
    'rendererStorageStrategy', 'rendererAutoreleaseScope', 'rendererProductionDefaultStrategy',
    'drawingStrategy', 'scalarAdditionalRasterObservations', 'additionalMemoryObservations',
    'contextOwnershipScope', 'effectContext', 'rendererStorage', 'positiveControl'}
LAUNCHER_KEYS = {'schemaVersion', 'status', 'launcherExitCode', 'drawingStrategy', 'rendererStorageStrategy',
    'comparisonKind', 'rendererAutoreleaseScope', 'effectContextPolicy', 'selectedAppPath',
    'createsNewApplicationInstance', 'timeoutSeconds', 'elapsedSeconds', 'launchBeganUptimeSeconds',
    'finishUptimeSeconds', 'callbackReceived', 'ownedExitConfirmed', 'processStartMemoryCaptured',
    'scope', 'processIdentifier', 'launchedAppPath', 'launchedExecutablePath'}
WRAPPER_KEYS = {'schema_version', 'status', 'command', 'started_at', 'timeout_seconds', 'grace_seconds',
    'max_log_bytes', 'pid', 'child_returncode', 'exit_code', 'cancel_signal', 'sigterm_sent', 'sigkill_sent',
    'descendant_cleanup', 'output_bytes', 'log_bytes', 'log_truncated', 'termination_reason',
    'duration_seconds', 'group_observation'}



def control_metadata(value):
    required = {'width', 'height', 'bitsPerComponent', 'bitsPerPixel', 'bytesPerRow', 'bitmapInfo',
        'alphaInfo', 'renderingIntent', 'colorSpaceModel', 'shouldInterpolate', 'hasDecodeArray', 'isMask'}
    optional = {'colorSpaceName', 'colorSpaceICCSHA256'}
    N.need(type(value) is dict and required <= set(value) <= required | optional, 'positive control metadata schema differs')
    for field, expected in [('width', 129), ('height', 101), ('bitsPerComponent', 8), ('bitsPerPixel', 32), ('colorSpaceModel', 1)]:
        C.equal_int(value[field], expected, 'positive control metadata ' + field)
    N.integer(value['bytesPerRow'], 129 * 4, 4096)
    N.need(value['bytesPerRow'] % 4 == 0, 'positive control row alignment differs')
    bitmap = N.integer(value['bitmapInfo'], 0, 2**32 - 1)
    alpha = N.integer(value['alphaInfo'], 1, 4)
    N.need(bitmap & 31 == alpha and bitmap & 256 == 0 and bitmap & 28672 in (0, 8192, 16384),
           'positive control channel layout differs')
    N.integer(value['renderingIntent'], 0, 4)
    N.need(type(value['shouldInterpolate']) is bool and value['hasDecodeArray'] is False and value['isMask'] is False,
           'positive control metadata flags differ')
    if 'colorSpaceName' in value:
        N.string(value['colorSpaceName'])
    if 'colorSpaceICCSHA256' in value:
        N.sha(value['colorSpaceICCSHA256'])
    return value


def positive_control(value, before_guard, policy):
    N.keys(value, {'schemaVersion', 'status', 'stage', 'comparisonKind', 'selectedPolicy', 'processBefore',
        'processAfter', 'processControlCallCount', 'independentReferenceContextCount', 'independentReferenceCallCount',
        'rasterObservationCount', 'memoryObservationCount', 'records'})
    C.equal_int(value['schemaVersion'], 1, 'positive control schema')
    N.need(value['status'] == 'passed' and value['stage'] == 'separate-positive-effect-control-after-output-guard'
           and value['comparisonKind'] == E.KIND and value['selectedPolicy'] == policy, 'positive control selection/stage differs')
    for field, expected in [('processControlCallCount', 2), ('independentReferenceContextCount', 1),
            ('independentReferenceCallCount', 2), ('rasterObservationCount', 5), ('memoryObservationCount', 0)]:
        C.equal_int(value[field], expected, 'positive control ' + field)
    before = E.snapshot(value['processBefore'], policy, released=True)
    after = E.snapshot(value['processAfter'], policy, previous=before, released=True)
    N.need(C.canonical_json(before) == C.canonical_json(before_guard), 'positive control does not follow original guard snapshot')
    for field in ('attemptCount', 'publishCount'):
        N.need(after[field] - before[field] == 2, 'positive control process call delta differs: ' + field)
    records = value['records']
    N.need(type(records) is list and len(records) == 2, 'positive control effect matrix differs')
    for record, effect in zip(records, ('blur', 'pixelate')):
        N.keys(record, {'effect', 'inputWidth', 'inputHeight', 'outputWidth', 'outputHeight', 'inputRGBASHA256',
            'referenceRGBASHA256', 'candidateRGBASHA256', 'referenceStoredPixelsSHA256', 'candidateStoredPixelsSHA256',
            'referenceMetadata', 'candidateMetadata', 'pixelsEqual', 'rgbaEqual', 'metadataEqual', 'outputDiffersFromInput'})
        N.need(record['effect'] == effect, 'positive control effects missing/reordered')
        for field, expected in [('inputWidth', 129), ('inputHeight', 101), ('outputWidth', 129), ('outputHeight', 101)]:
            C.equal_int(record[field], expected, 'positive control ' + field)
        for field in ('inputRGBASHA256', 'referenceRGBASHA256', 'candidateRGBASHA256',
                      'referenceStoredPixelsSHA256', 'candidateStoredPixelsSHA256'):
            N.sha(record[field])
        N.need(record['referenceRGBASHA256'] == record['candidateRGBASHA256'] != record['inputRGBASHA256']
               and record['referenceStoredPixelsSHA256'] == record['candidateStoredPixelsSHA256'],
               'positive control exact pixels or effective output differ')
        for field in ('pixelsEqual', 'rgbaEqual', 'metadataEqual', 'outputDiffersFromInput'):
            N.need(record[field] is True, 'positive control missing native assertion: ' + field)
        first, second = control_metadata(record['referenceMetadata']), control_metadata(record['candidateMetadata'])
        N.need(C.canonical_json(first) == C.canonical_json(second), 'positive control exact metadata differs')
    N.need(records[0]['inputRGBASHA256'] == records[1]['inputRGBASHA256'], 'positive control synthetic inputs differ')
    return value


def lifecycle(directory, native, identity, policy):
    launcher_bytes = D.read_bytes(directory / 'launch.json.launcher.json', D.NATIVE.MAX_LAUNCHER_BYTES)
    wrapper_bytes = D.read_bytes(directory / 'bounded-launch.json', N.MAX_BYTES)
    launcher, wrapper = D.parse_json(launcher_bytes), D.parse_json(wrapper_bytes)
    N.keys(launcher, LAUNCHER_KEYS); N.keys(wrapper, WRAPPER_KEYS)
    for field, expected in [('schemaVersion', 1), ('launcherExitCode', 0), ('processIdentifier', native['processIdentifier'])]:
        C.equal_int(launcher[field], expected, 'effect guard launcher ' + field)
    N.need(launcher['status'] == 'exited' and launcher['createsNewApplicationInstance'] is True
           and launcher['callbackReceived'] is True and launcher['ownedExitConfirmed'] is True,
           'fresh owned effect guard exit unverified')
    N.need(launcher['processStartMemoryCaptured'] is False, 'effect guard claims process birth memory')
    N.need(launcher['effectContextPolicy'] == policy and launcher['comparisonKind'] == E.KIND
           and launcher['drawingStrategy'] == 'owned-srgb8' and launcher['rendererStorageStrategy'] == 'native'
           and launcher['rendererAutoreleaseScope'] == 'caller', 'effect guard launcher selection differs')
    N.need(launcher['selectedAppPath'] == launcher['launchedAppPath'] == identity['bundlePath']
           and launcher['launchedExecutablePath'] == str(Path(identity['bundlePath']) / 'Contents/MacOS/PicShot'),
           'effect guard owned paths differ')
    C.equal_int(launcher['timeoutSeconds'], 600, 'effect guard launch deadline')
    elapsed = N.number(launcher['elapsedSeconds'], 0, 600)
    began = N.number(launcher['launchBeganUptimeSeconds'])
    finished = N.number(launcher['finishUptimeSeconds'], began, began + 600)
    N.need(elapsed > 0 and abs((finished - began) - elapsed) <= 1, 'effect guard launch interval differs')
    N.string(launcher['scope'])
    for field, expected in [('schema_version', 1), ('child_returncode', 0), ('exit_code', 0), ('max_log_bytes', N.MAX_BYTES)]:
        C.equal_int(wrapper[field], expected, 'effect guard wrapper ' + field)
    N.need(wrapper['status'] == wrapper['termination_reason'] == 'exited' and wrapper['cancel_signal'] is None,
           'effect guard bounded command did not exit normally')
    for field in ('sigterm_sent', 'sigkill_sent', 'descendant_cleanup'):
        N.need(wrapper[field] is False, 'effect guard wrapper needed cleanup')
    N.need(N.number(wrapper['timeout_seconds']) == 620 and N.number(wrapper['grace_seconds']) == 5,
           'effect guard wrapper deadline changed')
    N.integer(wrapper['pid'], 1, 2**31 - 1)
    total = N.integer(wrapper['output_bytes']); size = N.integer(wrapper['log_bytes'], 0, N.MAX_BYTES)
    N.need(size == min(total, N.MAX_BYTES) and wrapper['log_truncated'] is (total > size), 'effect guard log accounting differs')
    log = directory / 'launcher.log'; info = log.lstat()
    N.need(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_size == size, 'effect guard log missing/linked/size differs')
    duration = N.number(wrapper['duration_seconds'], 0, 620)
    N.need(duration > 0 and duration + .1 >= elapsed, 'effect guard wrapper interval shorter than launch')
    C.C.validate_group_observation(wrapper['group_observation'], duration)
    N.need(wrapper['command'] == ['swift', 'scripts/launch-effect-context-guard.swift', identity['bundlePath'],
        str(directory / 'launch.json'), policy], 'effect guard bounded command selection differs')
    N.string(wrapper['started_at'])
    started = datetime.datetime.fromisoformat(wrapper['started_at'])
    N.need(started.tzinfo is not None and started.utcoffset() == datetime.timedelta(0), 'effect guard wrapper start is not UTC')
    return {'launchBeganUptimeSeconds': began, 'finishUptimeSeconds': finished,
        'wrapperStartEpochSeconds': started.timestamp(), 'wrapperDurationSeconds': duration,
        'launcherReportSHA256': hashlib.sha256(launcher_bytes).hexdigest(),
        'wrapperReportSHA256': hashlib.sha256(wrapper_bytes).hexdigest()}


def check_directory(directory, app, source, policy):
    N.need(type(policy) is str and policy in E.POLICIES, 'unknown effect guard policy')
    directory = Path(directory).absolute()
    N.need(directory.resolve(strict=True) == directory and directory.is_dir(), 'effect guard evidence directory linked/missing')
    identity = N.bundle_identity(Path(app), source)
    executable_bytes = D.read_bytes(Path(identity['bundlePath']) / 'Contents/MacOS/PicShot', 512 * 1024 * 1024)
    N.need(len(executable_bytes) == identity['executableBytes']
           and hashlib.sha256(executable_bytes).hexdigest() == identity['executableSHA256'],
           'effect guard installed executable changed during identity read')
    drawing_result = D.check_directory(directory, app, source)
    native_path = directory / 'effect-output-failure.json'
    native_bytes = D.read_bytes(native_path, D.NATIVE.MAX_REPORT_BYTES)
    drawing_bytes = D.read_bytes(directory / 'drawing-raster-output-guard.json', D.MAX_SIDECAR_BYTES)
    raw = D.read_bytes(directory / FILENAME, D.MAX_SIDECAR_BYTES)
    native, report = D.parse_json(native_bytes), D.parse_json(raw)
    N.keys(report, KEYS)
    C.equal_int(report['schemaVersion'], 1, 'effect guard schema')
    N.need(report['status'] == 'observed' and report['diagnosticOnly'] is True, 'effect guard is not raw evidence')
    N.need(report['comparisonKind'] == E.KIND and report['observationBoundary'] == 'after-effect-output-failure-fixture-return',
           'effect guard observation differs')
    N.need(report['requestedPolicy'] == policy, 'effect guard requested policy differs')
    E.fixed_configuration(report, policy)
    for field in ('scalarAdditionalRasterObservations', 'additionalMemoryObservations'):
        C.equal_int(report[field], 0, field)
    for field in ('sourceCommit', 'version', 'buildVersion'):
        N.need(type(report[field]) is str and report[field] == native[field], 'effect guard identity differs: ' + field)
    for field in ('bundlePath', 'executablePath'):
        D.NATIVE.same_path(report[field], native[field], field)
    C.equal_int(report['processIdentifier'], native['processIdentifier'], 'effect guard PID')
    D.NATIVE.same_path(report['nativeReportPath'], native_path, 'effect native report')
    C.equal_int(report['nativeReportBytes'], len(native_bytes), 'effect guard native byte count')
    N.need(report['nativeReportSHA256'] == drawing_result['nativeReportSHA256'] == hashlib.sha256(native_bytes).hexdigest(),
           'effect guard native byte binding differs')
    N.need(report['drawingReportSHA256'] == hashlib.sha256(drawing_bytes).hexdigest(), 'effect guard drawing byte binding differs')
    C.equal_int(report['executableBytes'], identity['executableBytes'], 'effect guard executable byte count')
    N.need(report['executableSHA256'] == identity['executableSHA256'], 'effect guard executable SHA differs')
    effect = E.snapshot(report['effectContext'], policy, released=True)
    control = positive_control(report['positiveControl'], effect, policy)
    renderer = R.snapshot(report['rendererStorage'], 'native', released=True, allow_failures=True)
    N.need(renderer['nativeCount'] == renderer['attemptCount'], 'effect guard native renderer work omitted')
    expected_failures = sum(case['failedRenderRequests'] + case['cacheFailureAttempts'] for case in native['cases'])
    minimum_successes = sum(case['successControlDeliveries'] + case['retryDeliveries'] for case in native['cases'])
    N.need(renderer['failureCount'] >= expected_failures and renderer['publishCount'] >= minimum_successes,
           'effect guard native renderer failures or successes omitted')
    result = {**drawing_result, 'comparisonKind': E.KIND, 'effectContextPolicy': policy,
        'productionDefaultPolicy': 'reference', 'rendererStorageStrategy': 'native', 'rendererAutoreleaseScope': 'caller',
        'executableSHA256': identity['executableSHA256'], 'executableBytes': identity['executableBytes'],
        'architecture': identity['architecture'], 'drawingReportSHA256': report['drawingReportSHA256'],
        'effectReportSHA256': hashlib.sha256(raw).hexdigest(), 'effectContext': effect, 'rendererStorage': renderer,
        'positiveControl': control,
        'drawingTracker': drawing_result['tracker'], 'lifecycle': lifecycle(directory, native, identity, policy),
        'injectedRefusalsAreEffectContextFailures': False, 'nativeExecutionAttestedByChecker': False,
        'privateFrameworkReleaseClaim': False, 'productMemoryRemedyClaim': False}
    return result


def compare_guards(root, app, source):
    root = Path(root).absolute()
    N.need(root.resolve(strict=True) == root and root.is_dir(), 'effect guard root linked/missing')
    arms = {policy: check_directory(root / policy, app, source, policy) for policy in E.POLICIES}
    reference, candidate = (arms[policy] for policy in E.POLICIES)
    N.need(reference['processIdentifier'] != candidate['processIdentifier'], 'effect guards reused a process')
    N.need(reference['lifecycle']['finishUptimeSeconds'] <= candidate['lifecycle']['launchBeganUptimeSeconds'],
           'effect guard launches overlap or reordered')
    for field in ('sourceCommit', 'executableSHA256', 'executableBytes', 'architecture'):
        N.need(reference[field] == candidate[field], 'effect guard paired identity differs: ' + field)
    N.need(C.canonical_json(reference['positiveControl']['records']) == C.canonical_json(candidate['positiveControl']['records']),
           'positive control corresponding policy pixels/metadata differ')
    return {'status': 'passed', 'comparisonKind': E.KIND, 'arms': arms, 'nativeExecutionAttestedByChecker': False,
        'memoryStabilityAssessed': False, 'productMemoryRemedyClaim': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path); parser.add_argument('app', type=Path); parser.add_argument('source')
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument('--policy', choices=E.POLICIES); selection.add_argument('--pair', action='store_true')
    args = parser.parse_args()
    result = compare_guards(args.directory, args.app, args.source) if args.pair else check_directory(args.directory, args.app, args.source, args.policy)
    print(json.dumps(result, sort_keys=True, allow_nan=False))
