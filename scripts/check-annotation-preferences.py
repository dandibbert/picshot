#!/usr/bin/env python3
"""Verify bounded installed annotation-preference native UI evidence and PNGs.

Synthetic mutation tests validate this checker, never substitute for a macOS run.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import re

SPEC = importlib.util.spec_from_file_location('annotation_portable', Path(__file__).with_name('check-portable-settings.py'))
P = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(P)
need, number, rectangle, contains, overlaps = P.need, P.number, P.rectangle, P.contains, P.overlaps
CHECKS = {'native-local-tools-panel', 'remap-duplicate-reserved', 'clear-reset-cancel-save', 'immutable-editor-map',
          'canvas-field-ime-focus', 'same-tool-color-preview', 'old-import-preserves-sections', 'import-cancel-preserves-draft',
          'import-write-rollback', 'native-style-menu', 'future-marks-only', 'reopened-render-export', 'reset-render-export',
          'light-dark-hit-layout', 'owned-cleanup'}
MODES = ('light', 'dark')
CATEGORIES = ('shortcuts', 'import', 'styles', 'styles-narrow-number')
COMPACT_TOOLS = ('text', 'line', 'number')
COMPACT_CONTROLS = {'text': ['annotation.savedStyles', 'annotation.fontSize'],
                    'line': ['annotation.savedStyles', 'annotation.lineWidth'],
                    'number': ['annotation.savedStyles', 'annotation.numberValue', 'annotation.numberStyle', 'annotation.numberComment']}
FILES = {f'annotation-preferences-{name}-{mode}.png' for name in (*CATEGORIES, 'default', 'reopened', 'reset') for mode in MODES}
KEYS = [('recorder', 11, 0), ('recorder', 11, 0), ('reserved', 0, 0), ('reserved', 36, 0),
        ('reserved', 8, 1 << 20), ('cancel-recording', 53, 0), ('recorder', 15, 1 << 17),
        ('recorder', 11, 0), ('save-remap', 11, 0), ('old-map', 15, 0), ('removed-map', 15, 0),
        ('new-map', 11, 0), ('field-focus', 11, 0), ('ime-focus', 11, 0)]


def integer(value, minimum=0):
    need(type(value) is int and value >= minimum, 'invalid integer')
    return value


def sha(value):
    need(type(value) is str and re.fullmatch('[0-9a-f]{64}', value), 'invalid SHA256')
    return value


def read(path, limit):
    need(path.is_file() and 0 < path.stat().st_size <= limit, 'missing/oversized file: ' + str(path))
    value = path.read_bytes()
    need(len(value) <= limit, 'file grew beyond limit')
    return value


def rows(value):
    need(type(value) is list and len(value) == 2 and [row['appearance'] for row in value] == list(MODES), 'light/dark action coverage')
    return value


def true_fields(row, fields):
    for field in fields.split():
        need(row[field] is True, 'missing native check: ' + field)


def saved_style_title(row, frame=None):
    need(row['controlID'] == 'annotation.savedStyles', 'title control identity')
    for field in ('expectedTitle', 'buttonTitle', 'cellTitle', 'attributedTitle', 'firstItemTitle'):
        need(row[field] == '样式', 'saved-style display title mismatch: ' + field)
    need(row['measurement'] == 'NSPopUpButtonCell.titleRect+CoreText-untruncated-attributed-title', 'native title measurement route')
    bounds, title = rectangle(row['controlBounds']), rectangle(row['titleRect'])
    need(bounds[:2] == (0, 0) and contains(list(bounds), list(title), 0), 'native title rectangle clipped')
    need(0 < number(row['titleAdvance']) <= title[2], 'saved-style title advance exceeds native title rectangle')
    need(type(row['cellFontName']) is str and 0 < len(row['cellFontName']) <= 128 and
         0 < number(row['cellFontSize']) <= 72, 'native title font absent/invalid')
    true_fields(row, 'fullTitleFits')
    if frame is not None:
        need(bounds[2:] == rectangle(frame)[2:], 'title measurement detached from control frame')


def compact_palettes(style):
    rows = style['compactPalettes']
    need(type(rows) is list and len(rows) == 3 and [row['tool'] for row in rows] == list(COMPACT_TOOLS), 'compact tool coverage/order')
    true_fields(style, 'compactPaletteStateRestored')
    for row in rows:
        tool = row['tool']
        need(row['activeTool'] == ('select' if tool == 'number' else tool) and row['selectedNumber'] is (tool == 'number'),
             'compact selected-number state')
        bounds = rectangle(row['contentBounds'])
        need(bounds == (0, 0, 760, 600), 'compact viewport must be exactly 760 by 600')
        true_fields(row, 'fullVisibleFramesChecked controlsDoNotOverlap')
        need(contains(list(bounds), row['paletteFrame'], 0) and contains(list(bounds), row['toolbarFrame'], 0) and
             not overlaps(rectangle(row['paletteFrame']), rectangle(row['toolbarFrame'])), 'compact palette clipped/overlapping toolbar')
        controls = row['controls']
        need([control['id'] for control in controls] == COMPACT_CONTROLS[tool], 'compact native control coverage/order')
        seen = []
        for control in controls:
            frame = rectangle(control['frame']); true_fields(control, 'hitTest')
            need(frame[2] >= 16 and frame[3] >= 16 and contains(row['paletteFrame'], list(frame), 0), 'compact control clipped')
            need(not any(overlaps(frame, other) for other in seen), 'compact controls overlap'); seen.append(frame)
        saved_style_title(row['savedStyleTitle'], controls[0]['frame'])


def validate(report, *, expected_commit, expected_version, expected_build, installed_app, evidence_directory):
    r = report
    need(r['schemaVersion'] == 1 and type(r['schemaVersion']) is int and r['status'] == 'passed', 'native report not passed')
    app = Path(installed_app).resolve(strict=True)
    need(Path(r['bundlePath']).resolve(strict=True) == app and app.is_dir(), 'installed app mismatch')
    info_path = app / 'Contents/Info.plist'
    need(info_path.resolve(strict=True).is_relative_to(app), 'plist escaped bundle')
    info_data = read(info_path, 1_048_576)
    info = plistlib.loads(info_data)
    identity = (expected_commit, expected_version, expected_build)
    need((r['sourceCommit'], r['version'], r['buildVersion']) == identity, 'report identity mismatch')
    need(tuple(info.get(key) for key in ('PicShotSourceCommit', 'CFBundleShortVersionString', 'CFBundleVersion')) == identity,
         'actual installed plist identity mismatch')
    executable_name = info.get('CFBundleExecutable')
    need(executable_name == 'PicShot', 'unexpected executable name')
    executable = app / 'Contents/MacOS' / executable_name
    need(executable.resolve(strict=True).is_relative_to(app), 'executable escaped bundle')
    need(hashlib.sha256(info_data).hexdigest() == sha(r['infoPlistSHA256']), 'actual plist hash mismatch')
    need(hashlib.sha256(read(executable, 128 * 1024 * 1024)).hexdigest() == sha(r['executableSHA256']), 'actual executable hash mismatch')
    need(0 < number(r['elapsedSeconds']) < integer(r['overallDeadlineSeconds']) == 120, 'native deadline')
    need(integer(r['maximumRasterPixels']) == 4_000_000, 'raster bound')
    for field in ('userPreferencesReadOrWritten', 'globalInputPosted', 'globalHotkeysRegistered', 'permissionRequests',
                  'networkUsed', 'liveScreenCaptured', 'ordinaryTextCaptured', 'memoryStabilityAssessed'):
        need(r[field] is False, 'unexpected side effect/claim: ' + field)
    need(set(r['checks']) == CHECKS and len(r['checks']) == len(CHECKS), 'native check coverage')
    owner = r['ownership']
    need(integer(owner['controllerCount']) == 20 and integer(owner['releaseDeadlineSeconds']) == 4, 'owner coverage/bound')
    need(all(integer(owner[field]) == 0 for field in ('retainedControllers', 'retainedWindows', 'retainedContentViews')),
         'owned object retained')
    true_fields(owner, 'allOwnedWindowsClosed')
    for row in rows(r['settings']):
        true_fields(row, 'remap duplicateRejected reservedRejected clearReset cancelPreserved immutableOldEditor newEditorMap fieldTypingPreserved markedIMEPreserved')
        need(integer(row['saveCallbacks']) == 1, 'save callback count')
        selected = row['rowSelection']
        need(selected['status'] == 'passed-local-row-selection' and selected['dispatchRoute'] == 'owned-nextEvent-sendEvent', 'table dispatch route')
        need(all(integer(selected[key]) == 1 for key in ('requestedRow', 'rowAtDispatch', 'selectedRowAfter')), 'actual rectangle row selection')
        true_fields(selected, 'windowIsKey targetPointVisible ownedDownVerified')
        identity = selected['eventIdentity']
        true_fields(identity, 'sameType sameWindow sameQuartzTimestamp sameLocation sameEventNumber sameClickCount sameModifiers ownedWindowIsKey')
        a, b = identity['expected'], identity['dequeued']
        for field in ('type', 'windowNumber', 'quartzTimestampNanoseconds', 'eventNumber', 'clickCount', 'modifierFlags'):
            integer(a[field]); integer(b[field]); need(a[field] == b[field], 'table event identity mismatch')
        need(a['type'] == 1 and a['windowNumber'] > 0 and a['quartzTimestampNanoseconds'] > 0 and a['location'] == b['location'], 'table event identity')
    events = r['keyEvents']
    need(len(events) == len(KEYS) * 2, 'key event count')
    for row, (mode, (purpose, code, modifiers)) in zip(events, ((mode, item) for mode in MODES for item in KEYS)):
        need(row['purpose'] == purpose + '-' + mode and integer(row['keyCode']) == code and integer(row['modifiers']) == modifiers, 'key action/order')
        need(integer(row['windowNumber'], 1) > 0 and integer(row['eventType']) == 10, 'key window/type')
        need(integer(row['ownedQuartzTimestamp'], 1) == integer(row['dequeuedQuartzTimestamp'], 1), 'key event clock mismatch')
        need(row['dispatchRoute'] == 'NSApplication.nextEvent/sendEvent' and row['ownedWindowIsKey'] is True, 'key route/focus')
    need(len(r['menuEvents']) == 8, 'native menu event count')
    for row, (mode, item) in zip(r['menuEvents'], ((mode, item) for mode in MODES for item in ('width.10', 'save', 'restore', 'reset'))):
        expected = item if item.startswith('width.') else 'annotation.savedStyles.' + item
        need(row['appearance'] == mode and row['itemID'] == expected, 'menu action/order')
        need(row['controlID'] == ('annotation.lineWidth' if item.startswith('width.') else 'annotation.savedStyles'), 'menu control')
        true_fields(row, 'opened closed nativeKeyboardSelection')
        need(1 <= integer(row['postedKeyCount']) <= 40 and integer(row['timeoutSeconds']) == 2 and
             row['dispatchRoute'] == 'owned-mouseDown/native-menu-tracking', 'menu route/bound')
        if item != 'width.10': saved_style_title(row['savedStyleTitle'])
    for row in rows(r['imports']):
        true_fields(row, 'colorDetailVisible previewReadOnly cancelPreservedDraft rollbackPreservedDraft rollbackErrorVisible oldMissingSectionsPreserved')
        need(integer(row['rollbackWriteCount']) == 2 and integer(row['callbacks']) == 0, 'rollback count')
        need(row['oldValue'] != row['newValue'] and '#FF0000FF' in row['oldValue'] and '#0000FFFF' in row['newValue'], 'same-tool color detail')
    for row in rows(r['styles']):
        saved_style_title(row['initialSavedStyleTitle']); compact_palettes(row)
        true_fields(row, 'existingLayerUnchanged savedStyleRestored futureMarksOnly reopenedStyleMatches nativeOutputPNGExact resetRestoresOriginal')
        need(number(row['defaultLineWidth']) == 4 and number(row['savedLineWidth']) == 10, 'style widths')
        need(sha(row['defaultPixelSHA256']) == sha(row['resetPixelSHA256']) != sha(row['reopenedPixelSHA256']), 'native render digest relation')
    visuals = r['visuals']
    need(len(visuals) == len(CATEGORIES) * 2 and {(v['category'], v['appearance']) for v in visuals} == {(c, m) for c in CATEGORIES for m in MODES}, 'visual coverage')
    for v in visuals:
        need(v['file'] == f"annotation-preferences-{v['category']}-{v['appearance']}.png", 'visual filename')
        true_fields(v, 'fullVisibleFramesChecked controlsDoNotOverlap opaqueWindowBackgroundComposited')
        bounds = rectangle(v['contentBounds'])
        need(list(bounds[2:]) == [integer(v['pixelWidth']), integer(v['pixelHeight'])] and 0 < bounds[2] * bounds[3] <= 4_000_000, 'visual dimensions')
        controls = v['controls']; ids = [row['id'] for row in controls]
        need(len(ids) == len(set(ids)) and 2 <= len(ids) <= 80, 'control geometry bound/duplicates')
        expected = {'shortcuts': {'localShortcuts.capture', 'localShortcuts.clear', 'localShortcuts.restoreDefaults', 'settings.save', 'settings.cancel'},
                    'import': {'settings.importReview.cancel', 'settings.importReview.apply'}, 'styles': {'annotation.savedStyles', 'annotation.lineWidth'},
                    'styles-narrow-number': set(COMPACT_CONTROLS['number'])}[v['category']]
        need(expected.issubset(ids), 'missing native controls')
        seen = []
        for row in controls:
            frame = rectangle(row['frame']); true_fields(row, 'hitTest')
            need(contains(list(bounds), list(frame), .5) and frame[2] >= 16 and frame[3] >= 16, 'full control clipped')
            need(not any(overlaps(frame, other) for other in seen), 'native controls overlap'); seen.append(frame)
        if v['category'] not in ('styles', 'styles-narrow-number'):
            need(contains(v['visibleFrame'], v['windowFrame']), 'window clipped')
            true_fields(v, 'scrollViewportsChecked'); need(integer(v['readableLabelCount'], 1) > 0, 'unreadable labels')
        else:
            saved_style_title(v['savedStyleTitle'], next(row['frame'] for row in controls if row['id'] == 'annotation.savedStyles'))
            need(contains(list(bounds), v['paletteFrame'], 0) and contains(list(bounds), v['toolbarFrame'], 0)
                 and not overlaps(rectangle(v['paletteFrame']), rectangle(v['toolbarFrame'])), 'style palette clipped/overlapping toolbar')
        if v['category'] == 'styles-narrow-number':
            number_row = next(row for row in r['styles'] if row['appearance'] == v['appearance'])['compactPalettes'][2]
            need(v == number_row, 'number snapshot detached from compact palette evidence')
        if v['category'] == 'import':
            opening = v['openingReview']
            need(opening['checkMoment'] == 'immediately-after-opening-before-any-scroll' and opening['firstChangeID'] ==
                 opening['expectedFirstChangeID'] == 'settings.importReview.change.annotationStyle.rectangle', 'opening color row identity')
            need(contains(opening['clipBounds'], opening['firstChangeFrameInClip'], 0), 'opening color row clipped')
            labels = opening['firstChangeLabels']; need(len(labels) == 3, 'preview value labels')
            imported = next(row for row in r['imports'] if row['appearance'] == v['appearance'])
            need([label['text'] for label in labels] == ['矩形默认样式', '当前：' + imported['oldValue'], '导入：' + imported['newValue']], 'native preview text mismatch')
            for label in labels:
                need(contains(opening['clipBounds'], label['frameInClip'], 0), 'preview label clipped')
    need(set(r['fileSHA256']) == FILES, 'evidence file set')
    images, total_bytes = {}, 0
    for name in sorted(FILES):
        path = evidence_directory / name
        need(path.resolve(strict=True).parent == evidence_directory.resolve(strict=True), 'evidence escaped directory')
        data = read(path, 1_048_576); total_bytes += len(data)
        need(hashlib.sha256(data).hexdigest() == sha(r['fileSHA256'][name]), 'evidence hash mismatch')
        # Check IHDR dimensions before the shared decoder allocates its raster.
        need(data[:8] == b'\x89PNG\r\n\x1a\n' and len(data) >= 33, 'PNG header')
        width, height = int.from_bytes(data[16:20], 'big'), int.from_bytes(data[20:24], 'big')
        need(0 < width * height <= 4_000_000, 'PNG raster bound')
        images[name] = P.PNG.png_rgba(data)
    need(total_bytes <= 1_000_000, 'fixture evidence exceeds compact archive budget')
    for v in visuals:
        width, height, pixels = images[v['file']]
        need((width, height) == (v['pixelWidth'], v['pixelHeight']) and width >= 550 and height >= 300, 'native image extent')
        need(len(set(pixels[::4])) > 7 and all(a == 255 for a in pixels[3::4]), 'blank/transparent UI snapshot')
    for category in CATEGORIES:
        need(images[f'annotation-preferences-{category}-light.png'][2] != images[f'annotation-preferences-{category}-dark.png'][2], 'light/dark pixels identical')
    for mode in MODES:
        a, b, c = [images[f'annotation-preferences-{name}-{mode}.png'] for name in ('default', 'reopened', 'reset')]
        need(a[:2] == b[:2] == c[:2] == (640, 360) and a[2] == c[2] != b[2], 'decoded saved/reset output mismatch')
        red = sum(a[2][i] > a[2][i+2] + 40 for i in range(0, len(a[2]), 4))
        blue = sum(b[2][i+2] > b[2][i] + 40 for i in range(0, len(b[2]), 4))
        need(500 <= red < blue <= 10_000, 'saved color/width pixels absent')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for argument in ('report', 'app', 'source', 'version', 'build'):
        parser.add_argument(argument, type=Path if argument in ('report', 'app') else str)
    args = parser.parse_args()
    report = json.loads(read(args.report, 262_144), object_pairs_hook=P.unique_object)
    validate(report, expected_commit=args.source, expected_version=args.version, expected_build=args.build,
             installed_app=args.app, evidence_directory=args.report.parent)
    print('Installed annotation preferences passed; owned synthetic UI and bounded cleanup only')


if __name__ == '__main__':
    main()
