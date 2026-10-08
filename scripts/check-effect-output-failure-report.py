#!/usr/bin/env python3
"""Strict installed-app guard contract; checks remain active under python -O."""
import json
import pathlib
import plistlib
import re
import sys

ROUTES = ['copy', 'history', 'pin', 'quickSave', 'saveCopy', 'applyToPin', 'recognition', 'translation', 'export']
SELECTORS = ['copyResult', 'saveResult', 'pinResult', 'quickSaveResult', 'saveCopyResult',
             'recognizeResult', 'translateResult', 'applyResult', 'exportResult']
FALSE_FLAGS = ['generalPasteboardReadOrWritten', 'screenCaptureStarted', 'permissionRequests',
               'networkUsed', 'userFilesReadOrWritten', 'standardUserDefaultsChanged']
ZERO_COUNTS = ['activeProjectionJobsAfter', 'projectionReservedBytesAfter', 'projectionJobsStarted',
               'projectionJobsCompleted', 'queuedOperationsAfter', 'activeExportSessionsAfter']


def need(condition, message):
    if not condition:
        raise ValueError(message)


def count(report, key, expected):
    need(type(report.get(key)) is int and report[key] == expected, 'Invalid ' + key)


def same_path(actual, expected, label):
    need(isinstance(actual, str) and pathlib.Path(actual).is_absolute(), 'Missing absolute ' + label)
    need(pathlib.Path(actual).resolve() == pathlib.Path(expected).resolve(), 'Incorrect ' + label)


def validate(report, info, app, source, launcher):
    need(report.get('status') == 'passed', 'Effect guard did not pass')
    count(report, 'schemaVersion', 1)
    need(re.fullmatch(r'[0-9a-f]{40}', source) is not None, 'Invalid source commit')
    need(report.get('sourceCommit') == source == info.get('PicShotSourceCommit'), 'Source mismatch')
    need(report.get('version') == info.get('CFBundleShortVersionString') and bool(report.get('version')), 'Version mismatch')
    need(report.get('buildVersion') == info.get('CFBundleVersion') and bool(report.get('buildVersion')), 'Build mismatch')
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
    for key in ('syntheticSource', 'perCanvasFailureInjection', 'productionOutputActions', 'temporaryDirectoryRemoved'):
        need(report.get(key) is True, key)
    for key in ZERO_COUNTS:
        count(report, key, 0)
    count(report, 'caseCount', 8)
    count(report, 'controllerReleaseCount', 8)
    cases = report.get('cases')
    need(isinstance(cases, list) and len(cases) == 8, 'Incomplete case matrix')
    expected = {(tool, decorated, original) for tool in ('blur', 'pixelate')
                for decorated in (False, True) for original in (False, True)}
    seen = set()
    for case in cases:
        need(case.get('status') == 'passed', 'Case did not pass')
        need(type(case.get('decorated')) is bool and type(case.get('originalAwarePin')) is bool, 'Case variant missing')
        key = (case.get('tool'), case['decorated'], case['originalAwarePin'])
        need(key in expected and key not in seen, 'Missing, unexpected or duplicate case')
        seen.add(key)
        need(case.get('rejectedRoutes') == ROUTES, 'Output-route coverage changed')
        need(case.get('rejectedNativeSelectors') == SELECTORS, 'Native-selector coverage changed')
        for name in ('failedRenderRequests', 'errorCallbacks'):
            count(case, name, 18)
        for name in ('sinkDeliveriesDuringFailures', 'wrongErrorCallbacks', 'closeCallbacksDuringFailures'):
            count(case, name, 0)
        for name in ('successControlDeliveries', 'retryDeliveries'):
            count(case, name, 1)
        count(case, 'failedPatchPosition', 2)
        for name in ('draftPreserved', 'undoRedoPreserved', 'sourcePixelsUnchanged', 'priorOutputPreserved'):
            need(case.get(name) is True, name)
        need(re.fullmatch(r'[0-9a-f]{64}', case.get('priorOutputSHA256', '')) is not None, 'Missing prior-output hash')
        need(type(case.get('priorOutputBytes')) is int and 24 < case['priorOutputBytes'] <= 128 * 1024, 'Invalid prior PNG size')
    need(seen == expected, 'Incomplete case matrix')
    return report


def read_json(path, maximum):
    path = pathlib.Path(path)
    need(path.is_file() and not path.is_symlink() and 0 < path.stat().st_size <= maximum, 'Missing/oversized report')
    return json.loads(path.read_text())


def check(path, app, source, launcher_path):
    app = pathlib.Path(app)
    return validate(read_json(path, 128 * 1024), plistlib.loads((app / 'Contents/Info.plist').read_bytes()),
                    app, source, read_json(launcher_path, 16 * 1024))


if __name__ == '__main__':
    need(len(sys.argv) == 5, 'REPORT APP SOURCE LAUNCHER_REPORT')
    report = check(*sys.argv[1:])
    print(json.dumps({'status': 'passed', 'sourceCommit': report['sourceCommit'], 'caseCount': report['caseCount'],
                      'rejectedOutputAttempts': 144, 'controllerReleaseCount': report['controllerReleaseCount'],
                      'processIdentifier': report['processIdentifier']}))
