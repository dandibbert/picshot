#!/usr/bin/env python3
"""Strict bounded installed-app pin-management evidence gate.

Synthetic unit fixtures exercise this validator, never replace native Mac CI.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import re
import uuid

SPEC = importlib.util.spec_from_file_location('pin_portable', Path(__file__).with_name('check-portable-settings.py'))
P = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(P)
need, number, rectangle, contains, overlaps = P.need, P.number, P.rectangle, P.contains, P.overlaps
MODES = ('light', 'dark')
CATEGORIES = ('draft', 'text-rename', 'image-rename', 'order')
INITIAL = 'Original note\n原始文字 🖼️'
SAVED = 'Updated first line\n第二行：中文与 emoji 🧪✨\nThird line stays separate'
CHECKS = {'text-cancel-preserves-output', 'text-save-reload-reopen', 'text-undo-redo-bounded',
          'text-refusal-preserves-draft', 'html-never-flattened', 'image-and-text-direct-rename',
          'rename-cancel-refusal-duplicate', 'native-group-order-boundaries-selection',
          'light-dark-complete-layout', 'finite-owned-retirement'}
FILES = {f'pin-management-{category}-{mode}.png' for category in (*CATEGORIES, 'poster-before', 'poster-after') for mode in MODES}
FILES |= {f'pin-management-text-{stage}-{mode}.json' for stage in ('before', 'after') for mode in MODES}
FALSE_FIELDS = 'userPreferencesWritten globalInputPosted globalHotkeysRegistered permissionRequests networkUsed liveScreenCaptured ordinaryTextCaptured memoryStabilityAssessed'
ROOT_FIELDS = ('schemaVersion status bundlePath sourceCommit version buildVersion executableSHA256 infoPlistSHA256 overallDeadlineSeconds '
               'maximumRasterPixels preferenceReadScope canonicalTemporaryRoot scope flows resourceCycles ownership checks visuals actions elapsedSeconds fileSHA256 ' + FALSE_FIELDS)
TEXT_FLAGS = ('cancelPreserved refusalPreserved copyDisplayPersistedAgree reopenedMatches reopenControllerStable otherPinsUnchanged '
              'htmlImported htmlEditorUnavailable appKitUndoDisabled')
TEXT_FIELDS = ('id groupID initialText savedText beforeIdentity afterIdentity refusalCount duplicateAdditionalWrites beforeDataSHA256 '
               'afterDataSHA256 beforePosterSHA256 afterPosterSHA256 historyLevels historyBytes maximumHistoryLevels maximumHistoryBytes ' + TEXT_FLAGS)
ACTION_PAIRS = [('text-cancel', 'pin.textEdit.cancel'), ('text-undo', 'pin.textEdit.undo'), ('text-redo', 'pin.textEdit.redo'),
                ('text-save', 'pin.textEdit.save'), ('text-refused-save', 'pin.textEdit.save'), ('text-refused-cancel', 'pin.textEdit.cancel')]
ACTION_PAIRS += [(f'{kind}-rename-{action}', 'pin.rename.' + ('save' if action.endswith('save') else 'cancel'))
                 for kind in ('text', 'image') for action in ('cancel', 'refused-save', 'refused-cancel', 'save')]
CYCLE_ACTIONS = ('text-cancel', 'text-save', 'rename-cancel', 'rename-save', 'text-parent-close', 'rename-parent-close')


def fields(value, expected):
    need(type(value) is dict and set(value) == set(expected.split()), 'missing or unknown fields: ' + expected)
    return value


def integer(value, minimum=0, maximum=2**63-1):
    need(type(value) is int and minimum <= value <= maximum, 'invalid bounded integer')
    return value


def sha(value):
    need(type(value) is str and re.fullmatch('[0-9a-f]{64}', value), 'invalid SHA256')
    return value


def identifier(value):
    need(type(value) is str and str(uuid.UUID(value)).upper() == value, 'invalid canonical UUID')
    return value


def yes(row, names):
    for key in names.split():
        need(row[key] is True, 'missing native evidence: ' + key)


def array(value, count):
    need(type(value) is list and len(value) == count, 'array coverage/bound')
    return value


def read(path, limit):
    need(path.is_file() and 0 < path.stat().st_size <= limit, 'missing/oversized file: ' + str(path))
    with path.open('rb') as handle:
        data = handle.read(limit + 1)
    need(0 < len(data) <= limit, 'file changed beyond bound')
    return data


def validate(report, *, expected_commit, expected_version, expected_build, installed_app, evidence_directory):
    r = fields(report, ROOT_FIELDS)
    need(integer(r['schemaVersion']) == 1 and r['status'] == 'passed', 'native report did not pass')
    app = Path(installed_app).resolve(strict=True)
    need(type(r['bundlePath']) is str and Path(r['bundlePath']).resolve(strict=True) == app and app.is_dir(), 'installed bundle mismatch')
    plist_path, executable = app/'Contents/Info.plist', app/'Contents/MacOS/PicShot'
    need(plist_path.resolve(strict=True).is_relative_to(app) and executable.resolve(strict=True).is_relative_to(app), 'bundle file escaped app')
    plist_data = read(plist_path, 1_048_576); info = plistlib.loads(plist_data)
    identity = (expected_commit, expected_version, expected_build)
    need((r['sourceCommit'], r['version'], r['buildVersion']) == identity, 'report source/version/build mismatch')
    need(tuple(info.get(k) for k in ('PicShotSourceCommit', 'CFBundleShortVersionString', 'CFBundleVersion')) == identity,
         'actual installed plist identity mismatch')
    need(info.get('CFBundleExecutable') == 'PicShot', 'executable name mismatch')
    need(hashlib.sha256(plist_data).hexdigest() == sha(r['infoPlistSHA256']), 'actual plist hash mismatch')
    need(hashlib.sha256(read(executable, 134_217_728)).hexdigest() == sha(r['executableSHA256']), 'actual executable hash mismatch')
    need(0 < number(r['elapsedSeconds']) < number(r['overallDeadlineSeconds']) == 120, 'native deadline')
    need(integer(r['maximumRasterPixels']) == 4_000_000, 'raster bound changed')
    for key in FALSE_FIELDS.split(): need(r[key] is False, 'unexpected side effect/claim: ' + key)
    yes(r, 'canonicalTemporaryRoot')
    need(r['preferenceReadScope'] == 'group manager reads restorePinSessionOnLaunch only', 'preference read scope')
    need(r['scope'] == 'Synthetic managed pins; owned local AppKit events and cached complete content views; weak ownership only', 'fixture scope')
    need(array(r['checks'], len(CHECKS)) == sorted(CHECKS), 'native check coverage/order')
    owner = fields(r['ownership'], 'controllerCount retainedControllers retainedWindows retainedContentViews releaseDeadlineSeconds allOwnedWindowsClosed')
    need(integer(owner['controllerCount']) == 56 and integer(owner['releaseDeadlineSeconds']) == 4, 'ownership coverage/bound')
    for key in ('retainedControllers', 'retainedWindows', 'retainedContentViews'): need(integer(owner[key]) == 0, 'owned object retained')
    yes(owner, 'allOwnedWindowsClosed')
    for flow, mode in zip(array(r['flows'], 2), MODES):
        fields(flow, 'appearance text renames order'); need(flow['appearance'] == mode, 'flow appearance/order')
        t = fields(flow['text'], TEXT_FIELDS); yes(t, TEXT_FLAGS)
        identifier(t['id']); identifier(t['groupID'])
        need(t['initialText'] == INITIAL and t['savedText'] == SAVED, 'multiline/CJK/emoji content changed')
        for stage in ('beforeIdentity', 'afterIdentity'):
            identity_row = fields(t[stage], 'id groupID title presentationSHA256')
            need(identity_row['id'] == t['id'] and identity_row['groupID'] == t['groupID'] and identity_row['title'] == '文字便笺', 'text pin identity changed')
            sha(identity_row['presentationSHA256'])
        need(t['beforeIdentity'] == t['afterIdentity'], 'text save changed identity/presentation')
        need(integer(t['refusalCount']) == 1 and integer(t['duplicateAdditionalWrites']) == 0, 'text commit/refusal count')
        need(integer(t['maximumHistoryLevels']) == 12 and integer(t['maximumHistoryBytes']) == 524_288, 'history limit changed')
        integer(t['historyLevels'], 1, 12); integer(t['historyBytes'], 1, 524_288)
        need(sha(t['beforeDataSHA256']) != sha(t['afterDataSHA256']) and sha(t['beforePosterSHA256']) != sha(t['afterPosterSHA256']), 'text/poster unchanged')
        for row, kind in zip(array(flow['renames'], 2), ('text', 'image')):
            fields(row, 'kind id beforeTitle afterTitle callbacks refusalCount duplicateAdditionalWrites cancelPreserved refusalPreserved sameSheetOnRepeat contentPresentationUnchanged')
            need(row['kind'] == kind, 'rename kind/order'); identifier(row['id'])
            need(row['id'] == t['id'] if kind == 'text' else row['id'] != t['id'], 'rename wrong pin')
            need((row['beforeTitle'], row['afterTitle']) == (('文字便笺', '文字已命名 🧪') if kind == 'text' else ('图片参考', '图片已命名 🖼️')), 'rename content')
            need(integer(row['callbacks']) == integer(row['refusalCount']) == 1 and integer(row['duplicateAdditionalWrites']) == 0, 'rename commit count')
            yes(row, 'cancelPreserved refusalPreserved sameSheetOnRepeat contentPresentationUnchanged')
        validate_order(flow['order'], t['groupID'])
    for row, (mode, pair) in zip(array(r['actions'], len(ACTION_PAIRS)*2), ((mode, pair) for mode in MODES for pair in ACTION_PAIRS)):
        fields(row, 'appearance action controlID windowNumber route hitTest')
        need((row['appearance'], row['action'], row['controlID']) == (mode, *pair), 'native action identity/order')
        integer(row['windowNumber'], 1); yes(row, 'hitTest')
        need(row['route'] == 'PortableSettingsUIPreviewFixture.click/owned-hitTest-mouseDown', 'bypassed native button route')
    cycles = fields(r['resourceCycles'], 'warmupCycles measuredCycles rows releaseProbeCount releaseDeadlineSeconds maximumHistoryLevels maximumHistoryBytes')
    for key, value in {'warmupCycles': 2, 'measuredCycles': 10, 'releaseProbeCount': 24, 'releaseDeadlineSeconds': 4,
                       'maximumHistoryLevels': 12, 'maximumHistoryBytes': 524_288}.items():
        need(integer(cycles[key]) == value, 'resource bound/coverage changed')
    for index, row in enumerate(array(cycles['rows'], 12)):
        fields(row, 'index warmup action callbacks releasedControllers releasedWindows releasedContentViews')
        action = CYCLE_ACTIONS[index % 6]
        need(integer(row['index']) == index and row['warmup'] is (index < 2) and row['action'] == action, 'lifecycle action/order')
        need(integer(row['callbacks']) == int(action.endswith('save')), 'lifecycle callback count')
        for key in ('releasedControllers', 'releasedWindows', 'releasedContentViews'): need(integer(row[key]) == 2, 'incomplete lifecycle retirement')
    visuals = array(r['visuals'], 8)
    need([(v.get('appearance'), v.get('category')) for v in visuals] == [(mode, category) for mode in MODES for category in CATEGORIES], 'visual coverage/order')
    for visual in visuals: validate_visual(visual)
    need(type(r['fileSHA256']) is dict and set(r['fileSHA256']) == FILES, 'evidence file set')
    directory = Path(evidence_directory).resolve(strict=True)
    data_by_name, total = {}, 0
    for name in sorted(FILES):
        path = directory/name
        need(path.resolve(strict=True).parent == directory, 'evidence path escaped directory')
        data = read(path, 1_048_576); total += len(data)
        need(hashlib.sha256(data).hexdigest() == sha(r['fileSHA256'][name]), 'evidence SHA256 mismatch')
        data_by_name[name] = data
    need(total <= 4_194_304, 'aggregate evidence byte bound')
    for flow in r['flows']:
        mode, t = flow['appearance'], flow['text']
        for stage, prefix, text in [('before', 'before', INITIAL), ('after', 'after', SAVED)]:
            name = f'pin-management-text-{stage}-{mode}.json'
            need(r['fileSHA256'][name] == t[prefix+'DataSHA256'], 'text artifact binding')
            document = fields(json.loads(data_by_name[name], object_pairs_hook=P.unique_object), 'kind text')
            need(document['kind'] == 'text', 'document kind/version')
            content = fields(document['text'], 'runs importedHTML'); need(content['importedHTML'] is False, 'saved text flattened HTML')
            run = fields(array(content['runs'], 1)[0], 'text bold italic code')
            need(run['text'] == text and all(run[key] is False for key in ('bold', 'italic', 'code')), 'persisted content/runs mismatch')
            need(r['fileSHA256'][f'pin-management-poster-{stage}-{mode}.png'] == t[prefix+'PosterSHA256'], 'poster artifact binding')
    # All schema, file hashes and dimensions pass before the bounded PNG decoder.
    for name, data in data_by_name.items():
        if name.endswith('.png'):
            need(len(data) >= 33 and data[:8] == b'\x89PNG\r\n\x1a\n', 'PNG header')
            width, height = int.from_bytes(data[16:20], 'big'), int.from_bytes(data[20:24], 'big')
            need(0 < width * height <= 4_000_000, 'PNG raster bound')
    images = {name: P.PNG.png_rgba(data) for name, data in data_by_name.items() if name.endswith('.png')}
    for v in visuals:
        width, height, pixels = images[v['file']]
        need((width, height) == (v['pixelWidth'], v['pixelHeight']), 'PNG/geometry extent mismatch')
        need(len(set(pixels[::4])) > 7 and all(a == 255 for a in pixels[3::4]), 'blank/transparent native image')
    for category in CATEGORIES:
        need(images[f'pin-management-{category}-light.png'][2] != images[f'pin-management-{category}-dark.png'][2], 'light/dark pixels identical')
    for mode in MODES:
        before, after = (images[f'pin-management-poster-{stage}-{mode}.png'] for stage in ('before', 'after'))
        need(before[:2] == after[:2] == (480, 280) and before[2] != after[2], 'poster pixels missing/unchanged')


def validate_order(order, group):
    o = fields(order, 'activeGroupID selectedPinIDs states menuEvents callbacks entriesUnchanged selectionPreserved pickerOrder minimumWindowSize rowSelection')
    need(o['activeGroupID'] == group, 'active group changed'); identifier(array(o['selectedPinIDs'], 1)[0])
    yes(o, 'entriesUnchanged selectionPreserved')
    need(integer(o['callbacks']) == 3 and o['minimumWindowSize'] == [680, 600], 'group callback/minimum size')
    states = array(o['states'], 6)
    initial = array(states[0], 3)
    for value in initial: identifier(value)
    need(len(set(initial)) == 3 and initial[1] == group, 'initial active group position')
    a, b, c = initial
    need(states == [[a,b,c], [b,a,c], [b,a,c], [a,b,c], [a,c,b], [a,c,b]], 'one-step native order/boundary transition')
    need(o['pickerOrder'] == states[-1], 'picker order detached from stored order')
    for row, (direction, boundary) in zip(array(o['menuEvents'], 5), [('earlier',False), ('earlier',True), ('later',False), ('later',False), ('later',True)]):
        fields(row, 'itemID boundary enabled opened closed activated postedKeyCount timeoutSeconds windowNumber dispatchRoute disabledDismissedWithEscape')
        need(row['itemID'] == 'pin-group-order-' + direction and row['boundary'] is boundary and row['enabled'] is (not boundary), 'order action/boundary state')
        yes(row, 'opened closed')
        need(row['activated'] is (not boundary) and row['disabledDismissedWithEscape'] is boundary, 'disabled native menu action fired')
        integer(row['postedKeyCount'], 1, 40); integer(row['windowNumber'], 1)
        need(integer(row['timeoutSeconds']) == 2 and row['dispatchRoute'] == 'owned-mouseDown/native-menu-tracking', 'native menu route/bound')
    row = fields(o['rowSelection'], 'requestedRow selectedRowAfter windowNumber ownedWindowIsKey sameQuartzTimestamp expectedQuartzTimestamp dequeuedQuartzTimestamp eventType dispatchRoute targetPointVisible')
    yes(row, 'ownedWindowIsKey sameQuartzTimestamp targetPointVisible')
    need(integer(row['requestedRow']) == integer(row['selectedRowAfter']) == integer(row['eventType']) == 1, 'native row/type mismatch')
    integer(row['windowNumber'], 1)
    need(integer(row['expectedQuartzTimestamp'], 1, 2**64-1) == integer(row['dequeuedQuartzTimestamp'], 1, 2**64-1), 'table event identity mismatch')
    need(row['dispatchRoute'] == 'owned-nextEvent-sendEvent', 'native row dispatch bypass')
    need(all(event['windowNumber'] == row['windowNumber'] for event in o['menuEvents']), 'order/selection window mismatch')


def validate_visual(v):
    fields(v, 'category appearance file pixelWidth pixelHeight windowFrame visibleFrame contentBounds controls fullVisibleFramesChecked controlsDoNotOverlap opaqueWindowBackgroundComposited text')
    need(v['file'] == f"pin-management-{v['category']}-{v['appearance']}.png", 'snapshot filename')
    yes(v, 'fullVisibleFramesChecked controlsDoNotOverlap opaqueWindowBackgroundComposited')
    bounds = rectangle(v['contentBounds'])
    need(bounds[:2] == (0, 0) and bounds[2:] == (integer(v['pixelWidth'], 1), integer(v['pixelHeight'], 1)) and bounds[2]*bounds[3] <= 4_000_000, 'snapshot extent')
    need(contains(v['visibleFrame'], v['windowFrame']), 'whole window clipped')
    if v['category'] == 'order': need(rectangle(v['windowFrame'])[2:] == (680, 600), 'order window is not exact minimum')
    need(type(v['controls']) is list and 2 <= len(v['controls']) <= 40, 'control count bound')
    ids, seen = [], []
    for row in v['controls']:
        fields(row, 'id frame minimumSize hitTest'); yes(row, 'hitTest')
        need(type(row['id']) is str and 0 < len(row['id']) <= 100 and row['id'] not in ids, 'control identity/duplicate'); ids.append(row['id'])
        frame = rectangle(row['frame']); size = array(row['minimumSize'], 2)
        need(contains(list(bounds), list(frame), .5) and min(frame[2:]) >= 18, 'full control clipped')
        need(0 <= number(size[0]) <= frame[2]+1 and 0 <= number(size[1]) <= frame[3]+1, 'control title does not fit')
        need(not any(overlaps(frame, other) for other in seen), 'control frames overlap'); seen.append(frame)
    expected = {'draft': {'pin.textEdit.undo','pin.textEdit.redo','pin.textEdit.cancel','pin.textEdit.save'},
                'text-rename': {'pin.rename.name','pin.rename.cancel','pin.rename.save'},
                'image-rename': {'pin.rename.name','pin.rename.cancel','pin.rename.save'},
                'order': {'pin-group-picker','pin-group-order','pin-group-move-pin'}}[v['category']]
    need(expected.issubset(ids), 'missing measured native controls')
    if v['category'] != 'order': need(set(ids) == expected, 'unexpected draft/rename controls')
    if v['category'] == 'draft':
        t = fields(v['text'], 'text viewportFrame usedTextHeight viewportHeight fullTextFits'); yes(t, 'fullTextFits')
        need(t['text'] == SAVED and contains(list(bounds), t['viewportFrame']), 'draft text/viewport evidence')
        need(rectangle(t['viewportFrame'])[2] >= 300 and rectangle(t['viewportFrame'])[3] >= 120, 'draft viewport too small')
        need(0 < number(t['usedTextHeight']) + 16 <= number(t['viewportHeight']) <= rectangle(t['viewportFrame'])[3], 'draft multiline content clipped')
    else: fields(v['text'], '')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ('report', 'app', 'source', 'version', 'build'): parser.add_argument(key, type=Path if key in ('report','app') else str)
    args = parser.parse_args()
    report = json.loads(read(args.report, 262_144), object_pairs_hook=P.unique_object)
    validate(report, expected_commit=args.source, expected_version=args.version, expected_build=args.build,
             installed_app=args.app, evidence_directory=args.report.parent)
    print('pin-management: installed native evidence passed')


if __name__ == '__main__': main()
