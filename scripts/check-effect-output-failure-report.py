#!/usr/bin/env python3
"""Strict installed-app guard contract; checks remain active under python -O.

Synthetic checker inputs validate the schema, never native runtime acceptance.
"""
import json
import pathlib
import plistlib
import re
import sys

ROUTES = ['copy', 'history', 'pin', 'quickSave', 'saveCopy', 'applyToPin', 'recognition', 'translation', 'export']
SELECTORS = ['copyResult', 'saveResult', 'pinResult', 'quickSaveResult', 'saveCopyResult',
             'recognizeResult', 'translateResult', 'applyResult', 'exportResult']
FALSE_FLAGS = ['generalPasteboardReadOrWritten', 'screenCaptureStarted', 'permissionRequests',
               'networkUsed', 'userFilesReadOrWritten', 'standardUserDefaultsChanged',
               'originalImageCopyTestedAsAnnotatedOutput', 'nonNilGPUCorruptionCovered',
               'onscreenConcealmentCovered']
TRUE_FLAGS = ['syntheticSource', 'perCanvasFailureInjection', 'productionOutputActions', 'temporaryDirectoryRemoved']
ZERO_COUNTS = ['activeProjectionJobsAfter', 'projectionReservedBytesAfter', 'queuedOperationsAfter',
               'activeExportSessionsAfter', 'projectionJobsStartedDuringFailures']
CASE_TRUE_FLAGS = ['draftPreserved', 'undoRedoPreserved', 'existingRedoBranchPreserved',
                   'sourcePixelsUnchanged', 'priorOutputPreserved',
                   'originalIdentityPreserved', 'baseIdentityPreserved', 'originalPixelsUnchanged',
                   'basePixelsUnchanged', 'editableDocumentPreserved', 'cropViewportPreserved',
                   'baseCropPreserved', 'numberSequencePreserved', 'decorationsPreserved',
                   'priorEditableDocumentPreserved', 'presentationCacheCleared', 'failureNeverCached',
                   'retryMatchesExpectedProjection', 'retryPreservesEditableDocument']
CASE_HASHES = ['priorOutputSHA256', 'priorEditableDocumentSHA256', 'editableDocumentSHA256',
               'originalSHA256', 'baseSHA256']
MAX_REPORT_BYTES = 128 * 1024
MAX_LAUNCHER_BYTES = 16 * 1024


def need(condition, message):
    if not condition:
        raise ValueError(message)


def count(report, key, expected):
    need(type(report.get(key)) is int and report[key] == expected, 'Invalid ' + key)


def same_path(actual, expected, label):
    need(type(actual) is str and pathlib.Path(actual).is_absolute(), 'Missing absolute ' + label)
    need(pathlib.Path(actual).resolve() == pathlib.Path(expected).resolve(), 'Incorrect ' + label)


def validate(report, info, app, source, launcher):
    need(type(report) is dict, 'Report must be an object')
    need(type(info) is dict, 'App identity must be an object')
    need(type(launcher) is dict, 'Launcher report must be an object')
    need(report.get('status') == 'passed', 'Effect guard did not pass')
    count(report, 'schemaVersion', 2)
    need(type(source) is str and re.fullmatch(r'[0-9a-f]{40}', source) is not None, 'Invalid source commit')
    need(report.get('sourceCommit') == source == info.get('PicShotSourceCommit'), 'Source mismatch')
    for key, info_key, label in [('version', 'CFBundleShortVersionString', 'Version'),
                                  ('buildVersion', 'CFBundleVersion', 'Build')]:
        value = report.get(key)
        need(type(value) is str and bool(value) and value == info.get(info_key), label + ' mismatch')
    same_path(report.get('bundlePath'), app, 'installed app')
    need(info.get('CFBundleExecutable') == 'PicShot', 'Unexpected app executable')
    executable = pathlib.Path(app) / 'Contents/MacOS/PicShot'
    same_path(report.get('executablePath'), executable, 'guard executable')
    need(type(report.get('processIdentifier')) is int and report['processIdentifier'] > 0, 'Invalid guard PID')
    need(launcher.get('status') == 'exited', 'LaunchServices did not confirm exit')
    count(launcher, 'schemaVersion', 1)
    count(launcher, 'launcherExitCode', 0)
    count(launcher, 'processIdentifier', report['processIdentifier'])
    for key in ('createsNewApplicationInstance', 'callbackReceived', 'ownedExitConfirmed'):
        need(launcher.get(key) is True, 'Missing launcher ' + key)
    same_path(launcher.get('selectedAppPath'), app, 'selected app')
    same_path(launcher.get('launchedAppPath'), app, 'launched app')
    same_path(launcher.get('launchedExecutablePath'), executable, 'launched executable')
    for key in FALSE_FLAGS:
        need(report.get(key) is False, key)
    for key in TRUE_FLAGS:
        need(report.get(key) is True, key)
    for key in ZERO_COUNTS:
        count(report, key, 0)
    # Only successful decorated retries may start projection work.
    for key in ('projectionJobsStarted', 'projectionJobsCompleted'):
        count(report, key, 12)
    count(report, 'caseCount', 24)
    count(report, 'controllerReleaseCount', 24)
    cases = report.get('cases')
    need(type(cases) is list and len(cases) == 24, 'Incomplete case matrix')
    expected = {(tool, decorated, cropped, sink) for tool in ('blur', 'pixelate')
                for decorated in (False, True) for cropped in (False, True)
                for sink in ('legacy', 'originalAware', 'editable')}
    seen = set()
    for case in cases:
        need(type(case) is dict, 'Case must be an object')
        need(case.get('status') == 'passed', 'Case did not pass')
        need(type(case.get('decorated')) is bool and type(case.get('cropped')) is bool, 'Case variant missing')
        need(type(case.get('tool')) is str and type(case.get('sinkMode')) is str, 'Case mode missing')
        key = (case['tool'], case['decorated'], case['cropped'], case['sinkMode'])
        need(key in expected and key not in seen, 'Missing, unexpected or duplicate case')
        seen.add(key)
        need(case.get('rejectedRoutes') == ROUTES, 'Output-route coverage changed')
        need(case.get('rejectedNativeSelectors') == SELECTORS, 'Native-selector coverage changed')
        for name in ('failedRenderRequests', 'errorCallbacks'):
            count(case, name, 18)
        for name in ('sinkDeliveriesDuringFailures', 'wrongErrorCallbacks', 'closeCallbacksDuringFailures',
                     'projectionJobsStartedDuringFailures'):
            count(case, name, 0)
        for name in ('successControlDeliveries', 'retryDeliveries'):
            count(case, name, 1)
        count(case, 'failedPatchPosition', 2)
        count(case, 'cacheFailureAttempts', 2)
        count(case, 'existingRedoBranchRoundTrips', 2)
        count(case, 'undoRedoSteps', 2 + int(case['cropped']) + int(case['decorated']))
        for name in CASE_TRUE_FLAGS:
            need(case.get(name) is True, name)
        for name in CASE_HASHES:
            value = case.get(name)
            need(type(value) is str and re.fullmatch(r'[0-9a-f]{64}', value) is not None, 'Invalid ' + name)
        for name, minimum in [('priorOutputBytes', 25), ('priorEditableDocumentBytes', 1),
                              ('editableDocumentBytes', 1)]:
            value = case.get(name)
            need(type(value) is int and minimum <= value <= 128 * 1024, 'Invalid ' + name)
    need(seen == expected, 'Incomplete case matrix')
    return report


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        need(key not in result, 'Duplicate JSON key: ' + key)
        result[key] = value
    return result


def reject_constant(value):
    raise ValueError('Invalid JSON constant: ' + value)


def read_json(path, maximum):
    path = pathlib.Path(path)
    need(path.is_file() and not path.is_symlink() and 0 < path.stat().st_size <= maximum, 'Missing/oversized report')
    with path.open('rb') as stream:
        data = stream.read(maximum + 1)
    need(0 < len(data) <= maximum, 'Missing/oversized report')
    result = json.loads(data.decode('utf-8'), object_pairs_hook=unique_object, parse_constant=reject_constant)
    need(type(result) is dict, 'Report must be an object')
    return result


def check(path, app, source, launcher_path):
    app = pathlib.Path(app)
    return validate(read_json(path, MAX_REPORT_BYTES), plistlib.loads((app / 'Contents/Info.plist').read_bytes()),
                    app, source, read_json(launcher_path, MAX_LAUNCHER_BYTES))


if __name__ == '__main__':
    need(len(sys.argv) == 5, 'REPORT APP SOURCE LAUNCHER_REPORT')
    report = check(*sys.argv[1:])
    print(json.dumps({'status': 'passed', 'sourceCommit': report['sourceCommit'], 'caseCount': report['caseCount'],
                      'rejectedOutputAttempts': sum(case['failedRenderRequests'] for case in report['cases']),
                      'controllerReleaseCount': report['controllerReleaseCount'],
                      'processIdentifier': report['processIdentifier']}))
