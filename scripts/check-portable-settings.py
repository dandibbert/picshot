#!/usr/bin/env python3
"""Validate installed portable-settings evidence, complete control frames and PNGs.

The fixture owns isolated preferences and windows. Its bounded weak-reference
observations make no process-memory stability or zero-leak claim. Checker unit
fixtures are synthetic schema inputs, never substitutes for native execution.
"""
import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path

SPEC = importlib.util.spec_from_file_location('portable_png', Path(__file__).with_name('check-automatic-mosaic-report.py'))
PNG = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PNG)

CHECKS = {'export-saved-values', 'file-round-trip', 'preview-read-only', 'cancel-preserves-draft',
          'apply-once-closes', 'duplicate-apply-ignored', 'stale-preview-rejected', 'os-conflict-rejected',
          'write-failure-rollback', 'malformed-no-sheet', 'parent-close-dismisses-sheet',
          'native-toolbar-reorder', 'native-sidebar-selection', 'light-dark-full-frame-layout'}
ORDER = ['rectangle', 'ellipse', 'freehand', 'arrow', 'text', 'number', 'pixelate',
         'redact', 'eraser', 'spotlight', 'line', 'highlighter', 'select', 'crop']
PREFERENCES = {'appearance', 'screenshotDelaySeconds', 'screenshotShowsCursor', 'pinDesktopVisibility',
               'restorePinsOnLaunch', 'automaticallyRecognizePinText', 'historyDays', 'historyCount', 'historyMegabytes'}


def need(condition, message):
    if not condition:
        raise ValueError(message)


def number(value):
    need(type(value) in (int, float) and math.isfinite(value), 'nonfinite/nonnumeric geometry')
    return value


def rectangle(value):
    need(isinstance(value, list) and len(value) == 4, 'invalid full frame')
    x, y, w, h = map(number, value)
    need(w > 0 and h > 0, 'empty full frame')
    return x, y, w, h


def contains(outer, inner, tolerance=1):
    x, y, w, h = rectangle(outer)
    a, b, c, d = rectangle(inner)
    return a >= x-tolerance and b >= y-tolerance and a+c <= x+w+tolerance and b+d <= y+h+tolerance


def overlaps(a, b):
    x, y, w, h = a
    u, v, s, t = b
    return min(x+w-.5, u+s-.5) > max(x+.5, u+.5) and min(y+h-.5, v+t-.5) > max(y+.5, v+.5)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        need(key not in result, 'duplicate JSON field')
        result[key] = value
    return result


def check_export(data):
    need(0 < len(data) <= 65536, 'export byte bound')
    value = json.loads(data, object_pairs_hook=unique_object)
    need(set(value) == {'format', 'schemaVersion', 'preferences', 'hotkeys', 'annotationToolOrder',
                        'annotationStyles', 'annotationShortcuts'}, 'export allowlist')
    need(value['format'] == 'picshot.preferences' and value['schemaVersion'] == 1, 'export format/version')
    prefs = value['preferences']
    need(set(prefs) == PREFERENCES, 'export preference allowlist')
    need(prefs['appearance'] == 'system' and prefs['screenshotDelaySeconds'] == 0 and prefs['screenshotShowsCursor'] is False,
         'export contains unsaved/imported values')
    need(value['annotationToolOrder'] == ORDER, 'export contains unsaved toolbar draft')
    need(value['annotationStyles'] == {'version': 1, 'styles': []}, 'export contains unexpected annotation style data')
    need(type(value['annotationStyles']['version']) is int, 'style version must be an integer')
    need(value['annotationShortcuts'] == {'schemaVersion': 1, 'bindings': []}, 'export contains unexpected local shortcuts')
    need(type(value['annotationShortcuts']['schemaVersion']) is int, 'shortcut version must be an integer')
    shortcuts = value['hotkeys']
    need(len(shortcuts) == 6 and {item['action'] for item in shortcuts} ==
         {'capture', 'clipboardPin', 'restoreLastPin', 'history', 'recordingPauseResume', 'recordingStopSave'}, 'six exported actions')
    for item in shortcuts:
        need(set(item) == {'action', 'binding'}, 'shortcut export allowlist')
        if item['binding'] is not None:
            need(set(item['binding']) == {'keyCode', 'modifiers'}, 'binding export allowlist')


def check_opening_review(opening):
    need(opening['checkMoment'] == 'immediately-after-opening-before-any-scroll', 'opening review observation moment')
    need(opening['firstChangeID'] == opening['expectedFirstChangeID'] == 'settings.importReview.change.appearance',
         'opening first change identity')
    clip, document = opening['clipBounds'], opening['documentBounds']
    document_in_clip, visible = opening['documentFrameInClip'], opening['documentVisibleRect']
    row_in_clip, row_in_document = opening['firstChangeFrameInClip'], opening['firstChangeFrameInDocument']
    for frame in (clip, document, document_in_clip, visible, row_in_clip, row_in_document):
        rectangle(frame)
    need(opening['scrollOffset'] == clip[:2] and type(opening['documentIsFlipped']) is bool, 'opening scroll offset observation')
    need(contains(clip, row_in_clip, 0) and contains(document, row_in_document, 0) and contains(visible, row_in_document, 0),
         'opening complete first change clipped')
    need(contains(document_in_clip, row_in_clip, 0) and row_in_clip[2:] == row_in_document[2:], 'opening first row coordinate mismatch')
    labels = opening['firstChangeLabels']
    need(len(labels) == 3, 'opening first change labels missing')
    need([label['text'] for label in labels] == ['界面主题', '当前：跟随系统', '导入：深色'], 'opening first change content mismatch')
    for label in labels:
        need(isinstance(label['text'], str) and label['text'], 'opening first change text missing')
        need(contains(clip, label['frameInClip'], 0) and contains(visible, label['frameInDocument'], 0),
             'opening first change text clipped')


def validate(report, *, expected_commit, expected_version, expected_build, installed_app, evidence_directory):
    r = report
    need(r['status'] == 'passed' and r['schemaVersion'] == 1, 'native report not passed')
    need((r['sourceCommit'], r['version'], r['buildVersion']) == (expected_commit, expected_version, expected_build), 'bundle identity mismatch')
    need(Path(r['bundlePath']).resolve() == installed_app.resolve(), 'installed bundle mismatch')
    need(0 < number(r['elapsedSeconds']) < r['overallDeadlineSeconds'] == 120, 'native deadline')
    for field in ('userPreferencesReadOrWritten', 'globalHotkeysRegistered', 'globalInputPosted',
                  'permissionRequests', 'networkUsed', 'liveScreenCaptured'):
        need(r[field] is False, 'unexpected side effect: ' + field)
    need(r['canonicalTemporaryRoot'] is True, 'uncanonical fixture root')
    need(set(r['checks']) == CHECKS and len(r['checks']) == len(CHECKS), 'native action coverage')
    need(r['interactionRoute'] == 'NSView.hitTest and owned local NSEvents; buttons use mouseDown, tables use NSApplication.nextEvent/sendEvent with queued mouseUp', 'native mouse route missing')
    selections = r.get('tableSelectionEvents', [])
    need(len(selections) == 2 and {row['appearance'] for row in selections} == {'light', 'dark'}, 'native table event coverage')
    for row in selections:
        for field in ('requestedRow', 'rowAtDispatch', 'selectedRowAfter', 'selectedRowBefore',
                      'ownedDownType', 'windowNumber', 'ownedDownWindowNumber', 'keyWindowNumber',
                      'currentEventType', 'currentEventWindowNumber'):
            need(type(row[field]) is int, 'noninteger native table event field: ' + field)
        need(row['status'] == 'passed-local-row-selection' and row['dispatchRoute'] == 'owned-nextEvent-sendEvent'
             and row['ownedDownVerified'] is True and row['ownedDownType'] == 1, 'owned table down event')
        need(row['requestedRow'] == row['rowAtDispatch'] == row['selectedRowAfter'] == 1
             and row['selectedRowBefore'] == 0 and row['targetPointVisible'] is True, 'actual native table selection')
        need(row['windowIsKey'] is True and row['windowNumber'] > 0
             and row['windowNumber'] == row['ownedDownWindowNumber'] == row['keyWindowNumber'], 'owned table key window')
        for field in ('applicationIsActive', 'applicationIsRunning', 'currentEventIsSuppliedDown'):
            need(type(row[field]) is bool, 'missing table event state: ' + field)
        number(row['currentEventType']); number(row['currentEventWindowNumber'])
        identity = row['eventIdentity']
        for field in ('sameType', 'sameWindow', 'sameQuartzTimestamp', 'sameLocation',
                      'sameEventNumber', 'sameClickCount', 'sameModifiers', 'ownedWindowIsKey'):
            need(identity[field] is True, 'native table event identity: ' + field)
        need(type(identity['sameTimestamp']) is bool and type(identity['sameObject']) is bool, 'event representation observation')
        number(identity['timestampDifference'])
        expected, dequeued = identity['expected'], identity['dequeued']
        for event in (expected, dequeued):
            for field in ('type', 'windowNumber', 'quartzTimestampNanoseconds', 'eventNumber', 'clickCount', 'modifierFlags'):
                need(type(event[field]) is int, 'noninteger event identity: ' + field)
            need(event['type'] == 1 and event['windowNumber'] == row['windowNumber']
                 and 0 < event['quartzTimestampNanoseconds'] <= 2**64-1
                 and event['eventNumber'] == event['clickCount'] == 1 and event['modifierFlags'] == 0, 'invalid owned event identity')
            number(event['timestamp'])
            need(type(event['location']) is list and len(event['location']) == 2, 'event location shape')
            for coordinate in event['location']: number(coordinate)
        for field in ('type', 'windowNumber', 'quartzTimestampNanoseconds', 'eventNumber', 'clickCount', 'modifierFlags', 'location'):
            need(expected[field] == dequeued[field], 'event identity changed: ' + field)
    roundtrip = r['fileRoundTrip']
    need(roundtrip['readbackMatchesWritten'] is True and roundtrip['savedOnlyExport'] is True and
         0 < roundtrip['readbackByteCount'] <= roundtrip['maximumFileBytes'] == 65536, 'bounded file round trip')
    for appearance in ('Light', 'Dark'):
        row = r['commitObservation' + appearance]
        need(row['callbacks'] == row['hotkeyValidations'] == 1 and row['preferenceWrites'] > 1 and row['duplicateAdditionalWrites'] == 0,
             'single-commit observation')
    failures = r['failureCases']
    need(len(failures) == 5 and {row['case'] for row in failures} == {'stale', 'os-conflict', 'rollback', 'malformed', 'parent-close'}, 'failure coverage')
    for row in failures:
        need(row['preserved'] is True, 'failure did not preserve saved state')
        if row['case'] == 'malformed':
            need(row['sheetOpened'] is False, 'malformed file opened sheet')
        elif row['case'] == 'parent-close':
            need(row['ownedSheetDismissed'] is True, 'closed parent retained sheet')
        else:
            probes, writes = {'stale': (0, 0), 'os-conflict': (1, 0), 'rollback': (1, 2)}[row['case']]
            need((row['hotkeyValidations'], row['writeAttempts'], row['callbacks']) == (probes, writes, 0) and row['errorVisible'] is True,
                 'rejection/rollback ordering')
    resource = r['resourceCycles']
    need(resource['warmupCycles'] == 2 and resource['measuredCycles'] == 12 and resource['releaseProbeCount'] == 28,
         'ownership cycle coverage')
    need(resource['memoryStabilityAssessed'] is False and resource['releaseDeadlinePerCycleSeconds'] == 4, 'ownership claim/bound changed')
    need(all(resource[key] == 0 for key in ('retainedControllers', 'retainedWindows', 'retainedContentViews')), 'retained owned objects')
    need(len(resource['rows']) == 14, 'missing ownership cycle')
    for index, row in enumerate(resource['rows']):
        need(row['index'] == index and row['warmup'] is (index < 2) and row['action'] == ('apply' if index % 2 else 'cancel') and
             row['callbacks'] == index % 2, 'ownership cycle action/order')
        need(row['releasedControllers'] == row['releasedWindows'] == row['releasedContentViews'] == 2, 'unreleased cycle owner')
    visuals = r['visuals']
    need(len(visuals) == 6 and {(v['category'], v['appearance']) for v in visuals} ==
         {(category, appearance) for category in ('configuration', 'annotations', 'review') for appearance in ('light', 'dark')}, 'light/dark visual coverage')
    expected_files = {'portable-settings-export.json'} | {
        f'portable-settings-{category}-{appearance}.png'
        for category in ('configuration', 'annotations', 'review') for appearance in ('light', 'dark')}
    need(set(r['fileSHA256']) == expected_files, 'evidence file set')
    # Reject invalid report geometry before decoding any evidence raster. A
    # valid report still rereads, hashes and fully decodes every file below;
    # nothing is cached across calls or substituted for the decoded pixels.
    for visual in visuals:
        name = f"portable-settings-{visual['category']}-{visual['appearance']}.png"
        need(visual['file'] == name, 'visual file mismatch')
        need(visual['opaqueWindowBackgroundComposited'] is True, 'transparent native window background')
        need(contains(visual['visibleFrame'], visual['windowFrame']), 'full window outside usable display')
        bounds = visual['contentBounds']
        need(bounds[2:] == [visual['pixelWidth'], visual['pixelHeight']], 'snapshot omitted content bounds')
        need(visual['fullVisibleFramesChecked'] is True and visual['controlsDoNotOverlap'] is True and
             visual['scrollViewportsChecked'] is True and visual['readableLabelCount'] > 0, 'full visible layout contract')
        if visual['category'] == 'review':
            need(isinstance(visual.get('openingReview'), dict), 'opening review evidence missing')
            check_opening_review(visual['openingReview'])
        controls = visual['controls']; need(len(controls) >= 2, 'missing native controls')
        ids = [row['id'] for row in controls]; need(len(set(ids)) == len(ids), 'duplicate control geometry')
        required = {'configuration': {'settings.configuration.export', 'settings.configuration.import'},
                    'annotations': {'annotationToolbar.moveUp', 'annotationToolbar.moveDown', 'annotationToolbar.restoreDefaults'},
                    'review': {'settings.importReview.apply', 'settings.importReview.cancel'}}[visual['category']]
        need(required.issubset(ids), 'required native control missing')
        seen = []
        for row in controls:
            frame = rectangle(row['frame'])
            need(contains(bounds, list(frame), .5) and contains(visual['visibleFrame'], row['screenFrame']), 'full control clipped')
            need(frame[2] >= 20 and frame[3] >= 18 and len(row['minimumSize']) == 2 and
                 frame[2]+1 >= number(row['minimumSize'][0]) and frame[3]+1 >= number(row['minimumSize'][1]), 'unreadable control')
            need(row['hitTest'] is True and row['readable'] is True and bool(row['title']), 'native hit/readability missing')
            need(not any(overlaps(frame, other) for other in seen), 'full controls overlap')
            seen.append(frame)
    data = {}
    for name in expected_files:
        blob = PNG.file_bytes(evidence_directory, name)
        need(hashlib.sha256(blob).hexdigest() == r['fileSHA256'][name], 'evidence digest mismatch: ' + name)
        data[name] = blob
    check_export(data['portable-settings-export.json'])
    for visual in visuals:
        name = f"portable-settings-{visual['category']}-{visual['appearance']}.png"
        width, height, pixels = PNG.png_rgba(data[name])
        need((width, height) == (visual['pixelWidth'], visual['pixelHeight']) and width >= 550 and height >= 400, 'native PNG extent')
        need(width * height <= 4_000_000 and len(set(pixels[::4])) > 7, 'blank/oversized native PNG')
        need(all(alpha == 255 for alpha in pixels[3::4]), 'transparent native window background')
    for category in ('configuration', 'annotations', 'review'):
        need(data[f'portable-settings-{category}-light.png'] != data[f'portable-settings-{category}-dark.png'], 'light/dark PNGs identical')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', type=Path)
    parser.add_argument('app', type=Path)
    parser.add_argument('source')
    parser.add_argument('version')
    parser.add_argument('build')
    args = parser.parse_args()
    validate(json.loads(args.report.read_text(), object_pairs_hook=unique_object), expected_commit=args.source,
             expected_version=args.version, expected_build=args.build, installed_app=args.app, evidence_directory=args.report.parent)
    print('Installed portable-settings native evidence passed; weak ownership observations only')


if __name__ == '__main__':
    main()
