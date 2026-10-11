#!/usr/bin/env python3
"""Strict bounded installed-app pin-isolation evidence gate.

Synthetic unit reports test this checker; they never replace native Mac evidence.
Unavailable system-hosted menu pixels are explicit, not visual verification.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib

SPEC = importlib.util.spec_from_file_location('pin_management', Path(__file__).with_name('check-pin-management.py'))
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)
P = M.P
need, number, rectangle, contains, overlaps = P.need, P.number, P.rectangle, P.contains, P.overlaps
fields, integer, sha, identifier, yes, array, read = M.fields, M.integer, M.sha, M.identifier, M.yes, M.array, M.read
MODES = ('light', 'dark')
FALSE_FIELDS = ('networkUsed globalInputPosted permissionRequests userPreferencesWritten liveScreenCaptured '
                'memoryStabilityAssessed globalHotkeysRegistered ordinaryTextCaptured')
ROOT_FIELDS = ('schema status scope inputRoute sourceCommit bundlePath version buildVersion overallDeadlineSeconds '
               'menuDeadlineSeconds ownershipDeadlineSeconds maximumRasterPixels cyclesPerAppearance executableSHA256 '
               'infoPlistSHA256 ownership resourceCounts modes elapsedSeconds ' + FALSE_FIELDS)
OLD_IDS = {'pin-group-' + suffix for suffix in ('picker', 'order', 'heading', 'entries', 'move-pin', 'show',
    'hide-all', 'open-pin', 'rename-pin', 'remove-pin', 'transform', 'align', 'undo', 'redo')}
CONTROL_IDS = (OLD_IDS - {'pin-group-heading', 'pin-group-entries', 'pin-group-transform',
    'pin-group-align', 'pin-group-undo', 'pin-group-redo'}) | {
    'pin-group-add', 'pin-group-rename', '删除组…', '隐藏此组', '保护此组', '启动时恢复上次显示的贴图组'}
EVENTS = [('empty', 'isolate-selected', True, False), ('cancel', 'isolate-selected', True, True)]
for cycle in range(4):
    EVENTS.append((f'isolate-{cycle}', 'isolate-selected', False, True))
    if cycle == 0: EVENTS.append(('restore-refusal', 'restore-isolation', False, True))
    EVENTS.append((f'restore-{cycle}', 'restore-isolation', False, True))
EVENTS += [('restore-inactive', 'restore-isolation', True, False), ('refusal', 'isolate-selected', False, True),
           ('before-show', 'isolate-selected', False, True), ('archived', 'isolate-selected', True, False),
           ('hidden', 'isolate-selected', True, False)]
CAPTURE_PHASES = {'cancel', 'isolate-0', 'restore-0'}
VISUAL_FIELDS = ('status file sha256 pixelWidth pixelHeight windowNumber windowFrame contentBounds '
                 'opaqueWindowBackgroundComposited')
MODE_FIELDS = ('appearance oldControlIDs minimumWindowSize menuEvents cycles isolateCallbacks restoreCallbacks showCallbacks '
               'openCallbacks errors errorModalStates liveIDs visibleIDs selectedIDs isolationActive visual '
               'groupPromptCancellations groupPromptCollisions status')
COLLISION_FEEDBACK = '已存在同名贴图组。组名不区分大小写，且忽略首尾空白，请使用其他名称。'


def ids(value, count=None):
    need(type(value) is list and (count is None or len(value) == count), 'pin identity count')
    for item in value: identifier(item)
    need(value == sorted(set(value)), 'pin identities duplicate/unsorted')
    return set(value)


def validate(report, *, expected_commit, expected_version, expected_build, installed_app, evidence_directory):
    r = fields(report, ROOT_FIELDS)
    need(integer(r['schema']) == 1 and r['status'] == 'passed', 'native report did not pass')
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
    for key, value in {'overallDeadlineSeconds': 120, 'menuDeadlineSeconds': 2, 'ownershipDeadlineSeconds': 4,
                       'maximumRasterPixels': 4_000_000, 'cyclesPerAppearance': 4}.items():
        need(integer(r[key]) == value, 'native bound changed: ' + key)
    need(0 < number(r['elapsedSeconds']) < 120, 'native overall deadline')
    for key in FALSE_FIELDS.split(): need(r[key] is False, 'unexpected side effect/claim: ' + key)
    need(r['scope'] == 'Owned native group-manager context menu, real coordinator, synthetic image and rich pins', 'fixture scope')
    need(r['inputRoute'] == 'owned-nextEvent-sendEvent/native-context-menu-tracking', 'native input route')
    counts = fields(r['resourceCounts'], 'observedOwners releasedOwners appearanceCount completedIsolateRestoreCycles')
    for key, value in {'observedOwners': 12, 'releasedOwners': 12, 'appearanceCount': 2, 'completedIsolateRestoreCycles': 8}.items():
        need(integer(counts[key]) == value, 'finite resource count mismatch')
    expected_owners, visuals = set(), []
    for flow, mode in zip(array(r['modes'], 2), MODES):
        fields(flow, MODE_FIELDS)
        need(flow['appearance'] == mode and flow['status'] == 'passed', 'appearance status/order')
        need(flow['oldControlIDs'] == sorted(OLD_IDS) and flow['minimumWindowSize'] == [680, 600], 'compact controls/minimum changed')
        for value in flow['minimumWindowSize']: integer(value, 1)
        for key, value in {'isolateCallbacks': 6, 'restoreCallbacks': 5, 'showCallbacks': 1, 'openCallbacks': 0}.items():
            need(integer(flow[key]) == value, 'native action callback count')
        original, selected = validate_cycles(flow['cycles'])
        need(ids(flow['liveIDs'], 2) == ids(flow['visibleIDs'], 2) == selected and flow['isolationActive'] is False,
             'final native visibility/isolation mismatch')
        need(ids(flow['selectedIDs']).issubset(selected), 'final selection includes foreign pin')
        window = integer(flow['visual']['windowNumber'], 1)
        selections = []
        for row, event in zip(array(flow['menuEvents'], 16), EVENTS):
            validate_event(row, event, mode, window, visuals)
            selections.append(row['selectionBefore'])
        need(selections[0] == [] and all(len(value) == 2 for value in selections[1:14]) and
             all(value == selections[1] for value in selections[1:14]) and
             len(selections[14]) == len(selections[15]) == 1, 'native selection coverage changed')
        validate_prompts(flow)
        validate_visual(flow['visual'], f'pin-isolation-manager-{mode}.png', compact=True)
        visuals.append(flow['visual'])
        expected_owners.add(mode + '.manager')
        # The rich owner and the image kept through isolation reopen once each.
        owners = [o for o in array(r['ownership'], 12) if type(o) is dict and str(o.get('label', '')).startswith(mode + '.')]
        labels = [o.get('label') for o in owners]
        rich = [label.removeprefix(mode + '.rich.') for label in labels if type(label) is str and label.startswith(mode + '.rich.')]
        need(len(rich) == 1 and identifier(rich[0]) in selected, 'rich native owner missing')
        for pin in original:
            expected_owners.add(mode + ('.rich.' if pin == rich[0] else '.image.') + pin)
        for pin in selected:
            expected_owners.add(mode + ('.reopened-rich.' if pin == rich[0] else '.reopened-image.') + pin)
    labels = []
    for owner in array(r['ownership'], 12):
        fields(owner, 'label controllerReleased windowReleased contentReleased')
        yes(owner, 'controllerReleased windowReleased contentReleased')
        need(type(owner['label']) is str, 'owner label type'); labels.append(owner['label'])
    need(len(set(labels)) == 12 and set(labels) == expected_owners, 'ownership identity/coverage mismatch')
    validate_pngs(visuals, evidence_directory)


def validate_cycles(rows):
    original, selected = None, None
    for index, row in enumerate(array(rows, 8)):
        fields(row, 'cycle phase visibility selectionPreserved sameControllers manifestUnchanged assetsUnchanged entriesUnchanged')
        need(integer(row['cycle']) == index // 2 and row['phase'] == ('isolated' if index % 2 == 0 else 'restored'), 'cycle order/phase')
        yes(row, 'selectionPreserved sameControllers manifestUnchanged assetsUnchanged entriesUnchanged')
        visibility = array(row['visibility'], 3)
        for pin in visibility:
            fields(pin, 'id visible'); identifier(pin['id']); need(type(pin['visible']) is bool, 'native visibility type')
        current = ids([pin['id'] for pin in visibility], 3)
        shown = {pin['id'] for pin in visibility if pin['visible']}
        if original is None: original, selected = current, shown
        need(current == original and shown == (selected if index % 2 == 0 else original), 'isolation restored wrong native owners')
        need(len(shown) == (2 if index % 2 == 0 else 3), 'isolate/restore visibility count')
    return original, selected


def validate_event(row, event, mode, window, visuals):
    phase, suffix, cancel, enabled = event
    fields(row, 'itemID cancelledWithEscape opened closed trackingBeginCount trackingEndCount exactOwnedMenu '
           'returnHighlightVerified postedKeyCount lastKeyCode failed clickReturnedSeconds deadlineSeconds '
           'failureCancellationIssued mouseDispatch menuPixels windowNumber selectionBefore selectionAfter expectedEnabled '
           'trackingBeginElapsedSeconds trackingEndElapsedSeconds trackingIdentityVerified delegateOpenElapsedSeconds '
           'delegateOpenIdentityVerified delegateCloseElapsedSeconds delegateCloseIdentityVerified returnHighlightElapsedSeconds '
           'returnTargetMenuIdentityVerified returnTargetEnabled returnTargetHighlighted returnHighlightedItemID')
    need(row['itemID'] == 'pin-group-' + suffix and row['expectedEnabled'] is enabled, 'native menu action/enabled order')
    need(integer(row['windowNumber'], 1) == window, 'menu belongs to another window')
    yes(row, 'exactOwnedMenu trackingIdentityVerified')
    need(type(row['opened']) is bool and type(row['closed']) is bool and (cancel or row['closed']), 'native close observation missing')
    need(integer(row['trackingBeginCount']) == integer(row['trackingEndCount']) == 1, 'missing/duplicate native tracking')
    need(row['cancelledWithEscape'] is cancel and row['returnHighlightVerified'] is (not cancel), 'Escape/Return witness mismatch')
    need(row['failed'] is False and row['failureCancellationIssued'] is False, 'native tracking failure')
    need(integer(row['deadlineSeconds']) == 2 and 0 < number(row['clickReturnedSeconds']) <= 2, 'native menu deadline')
    began, ended = number(row['trackingBeginElapsedSeconds']), number(row['trackingEndElapsedSeconds'])
    need(0 < began <= ended <= 2, 'native tracking late/reordered')
    for state, prefix in [('opened', 'delegateOpen'), ('closed', 'delegateClose')]:
        if row[state]:
            need(row[prefix+'IdentityVerified'] is True and 0 < number(row[prefix+'ElapsedSeconds']) <= 2,
                 'native delegate identity/deadline')
        else:
            need(row[prefix+'IdentityVerified'] is False and row[prefix+'ElapsedSeconds'] is None, 'unobserved delegate callback fabricated')
    for key in ('returnTargetMenuIdentityVerified', 'returnTargetEnabled', 'returnTargetHighlighted'):
        need(row[key] is (not cancel), 'missing/fabricated native Return witness')
    if cancel:
        need(row['returnHighlightElapsedSeconds'] is None and row['returnHighlightedItemID'] is None, 'Escape fabricated Return highlight')
    else:
        need(row['returnHighlightedItemID'] == row['itemID'] and
             began <= number(row['returnHighlightElapsedSeconds']) <= min(ended, row['delegateCloseElapsedSeconds'], row['clickReturnedSeconds']),
             'Return highlight outside exact tracking/close interval')
    integer(row['postedKeyCount'], 1, 40)
    need(integer(row['lastKeyCode']) == (53 if cancel else 36) and (not cancel or row['postedKeyCount'] == 1), 'native menu key dispatch')
    before = row['selectionBefore']
    need(type(before) is list and len(before) <= 2, 'selection bound')
    for value in before: integer(value, 0, 3)
    need(before == sorted(set(before)) and type(row['selectionAfter']) is list and row['selectionAfter'] == before, 'native selection changed')
    for value in row['selectionAfter']: integer(value, 0, 3)
    validate_mouse(row['mouseDispatch'], window)
    pixels = row['menuPixels']
    need(type(pixels) is dict, 'native menu pixel receipt missing')
    if phase not in CAPTURE_PHASES:
        fields(pixels, 'status'); need(pixels['status'] == 'not-requested', 'unexpected menu pixel claim')
    elif pixels.get('status') == 'unavailable':
        absent_window = pixels.get('reason') == 'Native menu is not exposed as one owned AppKit content window'
        fields(pixels, 'status reason candidateCount' if absent_window else 'status reason')
        need(type(pixels['reason']) is str and 0 < len(pixels['reason']) <= 1000, 'missing menu capture limitation')
        if 'candidateCount' in pixels:
            integer(pixels['candidateCount'], 0, 100)
    else:
        validate_visual(pixels, f'pin-isolation-menu-{mode}-{phase}-native-menu.png', compact=False)
        need(type(pixels['ownedWindowClass']) is str and 0 < len(pixels['ownedWindowClass']) <= 200 and
             'menu' in pixels['ownedWindowClass'].lower(), 'foreign menu window class')
        need(pixels['observation'] == 'single-new-owned-menu-window-during-exact-menu-tracking' and
             pixels['windowNumber'] != window, 'menu pixels not owned tracking window')
        visuals.append(pixels)


def validate_mouse(row, window):
    fields(row, 'route type windowNumber quartzTimestamp currentQuartzTimestamp hitTestVerified sameEventIdentity location modifiers '
           'eventNumber clickCount dequeuedType dequeuedWindowNumber dequeuedQuartzTimestamp dequeuedLocation dequeuedModifiers '
           'dequeuedEventNumber dequeuedClickCount currentType currentWindowNumber currentLocation currentModifiers currentEventNumber currentClickCount')
    need(row['route'] == 'owned-nextEvent-sendEvent', 'native right-click route')
    yes(row, 'hitTestVerified sameEventIdentity')
    for key, value in {'Type': 3, 'WindowNumber': window, 'Modifiers': 0, 'EventNumber': 1, 'ClickCount': 1}.items():
        for name in (key[0].lower() + key[1:], 'dequeued' + key, 'current' + key):
            need(integer(row[name]) == value, 'owned right-click identity mismatch: ' + name)
    need(integer(row['quartzTimestamp'], 1, 2**64-1) == integer(row['dequeuedQuartzTimestamp'], 1, 2**64-1) ==
         integer(row['currentQuartzTimestamp'], 1, 2**64-1), 'owned current Quartz identity mismatch')
    points = [tuple(number(v) for v in array(row[key], 2)) for key in ('location', 'dequeuedLocation', 'currentLocation')]
    need(points[0] == points[1] == points[2], 'owned current-event location mismatch')


def validate_prompts(flow):
    need(flow['errors'] == ['injected-restore-refusal', 'injected-isolation-refusal', COLLISION_FEEDBACK, COLLISION_FEEDBACK],
         'native refusal/collision feedback mismatch')
    need(all(value is False for value in array(flow['errorModalStates'], 4)), 'native error presented modally')
    common = 'controlID promptObserved draftWasExistingGroupName manifestUnchanged groupIDsUnchanged indexUnchanged'
    flags = 'promptObserved draftWasExistingGroupName manifestUnchanged groupIDsUnchanged indexUnchanged'
    for key, saved in [('groupPromptCancellations', False), ('groupPromptCollisions', True)]:
        for row, control in zip(array(flow[key], 2), ('pin-group-add', 'pin-group-rename')):
            fields(row, common + (' nativeSaveClicked errorCount errorCase feedback errorModal' if saved else ' nativeCancelClicked'))
            need(row['controlID'] == control, 'native group prompt action/order')
            yes(row, flags + (' nativeSaveClicked' if saved else ' nativeCancelClicked'))
            if saved:
                need(integer(row['errorCount']) == 1 and row['errorCase'] == 'duplicateGroupName' and
                     row['feedback'] == COLLISION_FEEDBACK and row['errorModal'] is False, 'native duplicate Save did not refuse exactly once')


def validate_visual(v, name, *, compact):
    fields(v, VISUAL_FIELDS + (' controls visibleFrame fullVisibleFramesChecked controlsDoNotOverlap controlGeometryScope' if compact else ' ownedWindowClass observation'))
    need(v['status'] == 'captured' and v['file'] == name, 'native PNG status/name')
    sha(v['sha256']); integer(v['windowNumber'], 1)
    yes(v, 'opaqueWindowBackgroundComposited')
    bounds = rectangle(v['contentBounds']); frame = rectangle(v['windowFrame'])
    need(bounds[:2] == (0, 0) and bounds[2:] == (integer(v['pixelWidth'], 1), integer(v['pixelHeight'], 1)) and
         bounds[2] * bounds[3] <= 4_000_000, 'native PNG extent/bound')
    if not compact: return
    need(frame[2:] == (680, 600) and bounds[2] == 680 and bounds[3] <= 600, 'compact minimum frame changed')
    need(contains(v['visibleFrame'], v['windowFrame'], 1), 'compact whole window clipped')
    need(v['controlGeometryScope'] == 'catalog-header-visibility-item-actions-restore-checkbox', 'compact geometry scope changed')
    yes(v, 'fullVisibleFramesChecked controlsDoNotOverlap')
    controls = array(v['controls'], len(CONTROL_IDS)); labels, seen = [], []
    for row in controls:
        fields(row, 'id frame minimumSize hitTest'); yes(row, 'hitTest')
        need(type(row['id']) is str and row['id'] in CONTROL_IDS and row['id'] not in labels, 'missing/duplicate compact control')
        labels.append(row['id']); control = rectangle(row['frame'])
        need(contains(list(bounds), list(control), .5) and min(control[2:]) >= 18, 'compact full control clipped')
        size = array(row['minimumSize'], 2)
        need(0 <= number(size[0]) <= control[2] + 1 and 0 <= number(size[1]) <= control[3] + 1, 'compact native cell clipped')
        need(not any(overlaps(control, other) for other in seen), 'compact controls overlap'); seen.append(control)


def validate_pngs(visuals, evidence_directory):
    directory = Path(evidence_directory).resolve(strict=True)
    data_by_name, total = {}, 0
    for v in visuals:
        name = v['file']; need(name not in data_by_name, 'duplicate native image')
        path = directory/name
        need(path.resolve(strict=True).parent == directory, 'evidence path escaped directory')
        data = read(path, 1_048_576); total += len(data)
        need(hashlib.sha256(data).hexdigest() == v['sha256'], 'native PNG hash mismatch')
        need(len(data) >= 33 and data[:8] == b'\x89PNG\r\n\x1a\n', 'native PNG header')
        width, height = int.from_bytes(data[16:20], 'big'), int.from_bytes(data[20:24], 'big')
        need(0 < width * height <= 4_000_000 and (width, height) == (v['pixelWidth'], v['pixelHeight']), 'native PNG extent/bound')
        data_by_name[name] = data
    need(total <= 4_194_304, 'aggregate native image bound')
    # Validate every schema, hash and raster bound before decoding any pixels.
    images = {name: P.PNG.png_rgba(data) for name, data in data_by_name.items()}
    for name, (_, _, pixels) in images.items():
        need(all(alpha == 255 for alpha in pixels[3::4]), 'transparent native image')
        if name.startswith('pin-isolation-manager-'): need(len(set(pixels[::4])) > 7, 'blank manager image')
    need(images['pin-isolation-manager-light.png'][2] != images['pin-isolation-manager-dark.png'][2], 'light/dark native pixels identical')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ('report', 'app', 'source', 'version', 'build'):
        parser.add_argument(key, type=Path if key in ('report', 'app') else str)
    args = parser.parse_args()
    report = json.loads(read(args.report, 262_144), object_pairs_hook=P.unique_object)
    validate(report, expected_commit=args.source, expected_version=args.version, expected_build=args.build,
             installed_app=args.app, evidence_directory=args.report.parent)
    print('pin-isolation: installed native evidence passed; unavailable menu pixels do not establish menu appearance')


if __name__ == '__main__': main()
