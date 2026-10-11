"""Synthetic checker contracts only; these are not native AppKit observations."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import uuid


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result)
    return result


ROOT = Path(__file__).resolve().parents[1]
C = module('pin_isolation_check', ROOT/'check-pin-isolation.py')
OLD = module('pin_isolation_png_test', Path(__file__).with_name('test_check_portable_settings.py'))


def uid(index): return str(uuid.UUID(int=index)).upper()


class PinIsolationCheckerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.app = self.root/'PicShot.app'
        (self.app/'Contents/MacOS').mkdir(parents=True)
        self.executable = self.app/'Contents/MacOS/PicShot'
        self.executable.write_bytes(b'synthetic installed executable, not native proof')
        self.plist = self.app/'Contents/Info.plist'
        self.plist.write_bytes(plistlib.dumps(dict(CFBundleExecutable='PicShot', PicShotSourceCommit='source',
            CFBundleShortVersionString='0.21.0', CFBundleVersion='216')))
        self.r = dict(schema=1, status='passed', bundlePath=str(self.app), sourceCommit='source', version='0.21.0', buildVersion='216',
            executableSHA256=hashlib.sha256(self.executable.read_bytes()).hexdigest(),
            infoPlistSHA256=hashlib.sha256(self.plist.read_bytes()).hexdigest(),
            overallDeadlineSeconds=120, menuDeadlineSeconds=2, ownershipDeadlineSeconds=4, maximumRasterPixels=4_000_000,
            cyclesPerAppearance=4, elapsedSeconds=12,
            scope='Owned native group-manager context menu, real coordinator, synthetic image and rich pins',
            inputRoute='owned-nextEvent-sendEvent/native-context-menu-tracking', modes=[], ownership=[],
            resourceCounts=dict(observedOwners=12, releasedOwners=12, appearanceCount=2, completedIsolateRestoreCycles=8))
        for key in C.FALSE_FIELDS.split(): self.r[key] = False
        for mode_index, mode in enumerate(('light', 'dark')):
            image, rich, sibling = [uid(mode_index*10 + index) for index in (1, 2, 3)]
            window = 100 + mode_index
            controls = [dict(id=label, frame=[10+(i % 4)*160, 20+(i // 4)*45, 150, 24],
                             minimumSize=[145, 24], hitTest=True) for i, label in enumerate(sorted(C.CONTROL_IDS))]
            visual = dict(status='captured', file=f'pin-isolation-manager-{mode}.png', sha256='', pixelWidth=680, pixelHeight=578,
                windowNumber=window, windowFrame=[100, 100, 680, 600], contentBounds=[0, 0, 680, 578],
                opaqueWindowBackgroundComposited=True, controls=controls, visibleFrame=[0, 0, 1440, 900],
                fullVisibleFramesChecked=True, controlsDoNotOverlap=True,
                controlGeometryScope='catalog-header-visibility-item-actions-restore-checkbox')
            self.replace(visual, OLD.png(680, 578, 32 + mode_index*50))
            flow = dict(appearance=mode, status='passed', oldControlIDs=sorted(C.OLD_IDS), minimumWindowSize=[680, 600],
                menuEvents=[], cycles=[], isolateCallbacks=6, restoreCallbacks=5, showCallbacks=1, openCallbacks=0,
                errors=['injected-restore-refusal', 'injected-isolation-refusal', C.COLLISION_FEEDBACK, C.COLLISION_FEEDBACK],
                errorModalStates=[False]*4, liveIDs=[image, rich], visibleIDs=[image, rich], selectedIDs=[], isolationActive=False,
                visual=visual, groupPromptCancellations=[], groupPromptCollisions=[])
            for index in range(8):
                flow['cycles'].append(dict(cycle=index//2, phase='isolated' if index % 2 == 0 else 'restored',
                    visibility=[dict(id=pin, visible=pin != sibling or index % 2 == 1) for pin in (image, rich, sibling)],
                    selectionPreserved=True, sameControllers=True, manifestUnchanged=True, assetsUnchanged=True, entriesUnchanged=True))
            for index, (phase, suffix, cancel, enabled) in enumerate(C.EVENTS):
                selection = [] if index == 0 else [0, 2] if index < 14 else [1]
                mouse = dict(route='owned-nextEvent-sendEvent', type=3, windowNumber=window, quartzTimestamp=1000+index,
                    hitTestVerified=True, sameEventIdentity=True, location=[100.25, 320], modifiers=0, eventNumber=1, clickCount=1)
                for prefix in ('dequeued', 'current'):
                    mouse.update({prefix+'Type': 3, prefix+'WindowNumber': window, prefix+'QuartzTimestamp': 1000+index,
                        prefix+'Location': [100.25, 320], prefix+'Modifiers': 0, prefix+'EventNumber': 1, prefix+'ClickCount': 1})
                menu_pixels = dict(status='unavailable', reason='Native menu is not exposed as one owned AppKit content window',
                                   candidateCount=0) if phase in C.CAPTURE_PHASES else dict(status='not-requested')
                flow['menuEvents'].append(dict(itemID='pin-group-'+suffix, cancelledWithEscape=cancel, opened=True, closed=not cancel,
                    trackingBeginCount=1, trackingEndCount=1, exactOwnedMenu=True, returnHighlightVerified=not cancel,
                    postedKeyCount=1 if cancel else 2, lastKeyCode=53 if cancel else 36, failed=False, clickReturnedSeconds=0.25,
                    deadlineSeconds=2, failureCancellationIssued=False, mouseDispatch=mouse, menuPixels=menu_pixels,
                    trackingBeginElapsedSeconds=0.01, trackingEndElapsedSeconds=0.24, trackingIdentityVerified=True,
                    delegateOpenElapsedSeconds=0.02, delegateOpenIdentityVerified=True,
                    delegateCloseElapsedSeconds=None if cancel else 0.23, delegateCloseIdentityVerified=not cancel,
                    returnHighlightElapsedSeconds=None if cancel else 0.18, returnTargetMenuIdentityVerified=not cancel,
                    returnTargetEnabled=not cancel, returnTargetHighlighted=not cancel,
                    returnHighlightedItemID=None if cancel else 'pin-group-'+suffix,
                    windowNumber=window, selectionBefore=selection.copy(), selectionAfter=selection.copy(), expectedEnabled=enabled))
            for control in ('pin-group-add', 'pin-group-rename'):
                common = dict(controlID=control, promptObserved=True, draftWasExistingGroupName=True, manifestUnchanged=True,
                              groupIDsUnchanged=True, indexUnchanged=True)
                flow['groupPromptCancellations'].append(dict(common, nativeCancelClicked=True))
                flow['groupPromptCollisions'].append(dict(common, nativeSaveClicked=True, errorCount=1, errorCase='duplicateGroupName',
                                                         feedback=C.COLLISION_FEEDBACK, errorModal=False))
            self.r['modes'].append(flow)
            for suffix in ('manager', 'image.'+image, 'image.'+sibling, 'rich.'+rich, 'reopened-image.'+image, 'reopened-rich.'+rich):
                self.r['ownership'].append(dict(label=mode+'.'+suffix, controllerReleased=True, windowReleased=True, contentReleased=True))

    def replace(self, visual, data):
        (self.root/visual['file']).write_bytes(data); visual['sha256'] = hashlib.sha256(data).hexdigest()

    def check(self):
        C.validate(self.r, expected_commit='source', expected_version='0.21.0', expected_build='216',
                   installed_app=self.app, evidence_directory=self.root)

    def reject(self, path, value, *, decode=False, delete=False):
        prior = copy.deepcopy(self.r); row = self.r
        for key in path[:-1]: row = row[key]
        if delete: del row[path[-1]]
        else: row[path[-1]] = value
        try:
            with mock.patch.object(C.P.PNG, 'png_rgba', wraps=C.P.PNG.png_rgba) as decoder:
                with self.assertRaises((ValueError, KeyError, TypeError, OSError)): self.check()
                if not decode: decoder.assert_not_called()
        finally: self.r = prior

    def test_complete_contract_and_explicit_unavailable_menu_pixels(self):
        alias = self.root/'alias.app'; alias.symlink_to(self.app); self.r['bundlePath'] = str(alias)
        with mock.patch.object(C.P.PNG, 'png_rgba', wraps=C.P.PNG.png_rgba) as decoder:
            self.check(); self.assertEqual(decoder.call_count, 2)
        for flow in self.r['modes']:
            for event in flow['menuEvents']:
                # Delegate open is optional, but exact begin/end notifications
                # and the actual close on selected actions are mandatory.
                event.update(opened=False, delegateOpenElapsedSeconds=None, delegateOpenIdentityVerified=False,
                    closed=True, delegateCloseElapsedSeconds=2, delegateCloseIdentityVerified=True,
                    clickReturnedSeconds=2, trackingEndElapsedSeconds=2)
                for key in ('quartzTimestamp', 'dequeuedQuartzTimestamp', 'currentQuartzTimestamp'):
                    event['mouseDispatch'][key] = 2**64-1
                if not event['cancelledWithEscape']: event['postedKeyCount'] = 40
                if event['menuPixels']['status'] == 'unavailable':
                    event['menuPixels'] = dict(status='unavailable', reason='Native owned content cache unavailable')
        self.check()

    def test_real_owned_menu_png_receipt_is_checked_when_available(self):
        visual = dict(status='captured', file='pin-isolation-menu-light-cancel-native-menu.png', sha256='',
            pixelWidth=220, pixelHeight=70, windowNumber=120, windowFrame=[100, 100, 220, 70],
            contentBounds=[0, 0, 220, 70], opaqueWindowBackgroundComposited=True,
            ownedWindowClass='NSMenuWindow', observation='single-new-owned-menu-window-during-exact-menu-tracking')
        self.replace(visual, OLD.png(220, 70, 14)); self.r['modes'][0]['menuEvents'][1]['menuPixels'] = visual
        self.check()
        for key, value in [('windowNumber', 100), ('ownedWindowClass', 'NSWindow'), ('observation', 'fake-render'),
                           ('file', '../fake.png'), ('sha256', 'a'*64)]:
            with self.subTest(key=key): self.reject(('modes', 0, 'menuEvents', 1, 'menuPixels', key), value)

    def test_every_schema_rejects_missing_and_unknown_fields(self):
        paths = [(), ('resourceCounts',), ('ownership', 0), ('modes', 0), ('modes', 0, 'cycles', 0),
                 ('modes', 0, 'cycles', 0, 'visibility', 0), ('modes', 0, 'menuEvents', 0),
                 ('modes', 0, 'menuEvents', 0, 'mouseDispatch'), ('modes', 0, 'menuEvents', 0, 'menuPixels'),
                 ('modes', 0, 'menuEvents', 1, 'menuPixels'), ('modes', 0, 'visual'), ('modes', 0, 'visual', 'controls', 0),
                 ('modes', 0, 'groupPromptCancellations', 0), ('modes', 0, 'groupPromptCollisions', 0)]
        for path in paths:
            row = self.r
            for key in path: row = row[key]
            for key in list(row):
                with self.subTest(path=path, missing=key): self.reject((*path, key), None, delete=True)
            with self.subTest(path=path, unknown=True): self.reject((*path, 'unexpected'), False)

    def test_fixed_bounds_types_and_side_effects(self):
        for key in ('schema', 'overallDeadlineSeconds', 'menuDeadlineSeconds', 'ownershipDeadlineSeconds',
                    'maximumRasterPixels', 'cyclesPerAppearance'):
            for value in (0, True, float(self.r[key]), float('nan'), float('inf'), self.r[key]+1):
                with self.subTest(key=key, value=value): self.reject((key,), value)
        for value in (0, -1, 120, float('nan'), float('inf'), True, '1'):
            self.reject(('elapsedSeconds',), value)
        for key in C.FALSE_FIELDS.split():
            for value in (True, 0, None): self.reject((key,), value)
        for key in self.r['resourceCounts']:
            self.reject(('resourceCounts', key), self.r['resourceCounts'][key]+1)

    def test_actual_installed_identity_and_hashes(self):
        for key, value in [('sourceCommit', 'wrong'), ('version', 'wrong'), ('buildVersion', 'wrong'),
                           ('executableSHA256', 'a'*64), ('infoPlistSHA256', 'a'*64), ('status', 'failed'),
                           ('scope', 'synthetic-only'), ('inputRoute', 'performClick')]:
            self.reject((key,), value)
        self.executable.write_bytes(b'changed installed executable')
        with self.assertRaises(ValueError): self.check()
        self.r['executableSHA256'] = hashlib.sha256(self.executable.read_bytes()).hexdigest()
        info = plistlib.loads(self.plist.read_bytes()); info['CFBundleVersion'] = '215'
        self.plist.write_bytes(plistlib.dumps(info)); self.r['infoPlistSHA256'] = hashlib.sha256(self.plist.read_bytes()).hexdigest()
        with self.assertRaisesRegex(ValueError, 'actual installed plist identity'): self.check()

    def test_cycle_identity_visibility_and_persistence_tampering(self):
        for key, value in [('cycle', 1), ('phase', 'restored'), ('sameControllers', False), ('selectionPreserved', False),
                           ('manifestUnchanged', False), ('assetsUnchanged', False), ('entriesUnchanged', False)]:
            self.reject(('modes', 0, 'cycles', 0, key), value)
        for path, value in [(('cycles',), []), (('cycles', 0, 'visibility', 0, 'id'), uid(99)),
                            (('cycles', 0, 'visibility', 2, 'visible'), True), (('cycles', 1, 'visibility', 2, 'visible'), False),
                            (('cycles', 0, 'visibility', 0, 'visible'), 1), (('liveIDs',), [uid(1), uid(3)]),
                            (('visibleIDs',), [uid(1)]), (('selectedIDs',), [uid(99)]), (('isolationActive',), True)]:
            self.reject(('modes', 0, *path), value)
        for key in ('isolateCallbacks', 'restoreCallbacks', 'showCallbacks', 'openCallbacks'):
            self.reject(('modes', 0, key), self.r['modes'][0][key]+1)
        self.reject(('modes',), self.r['modes'][::-1])
        self.reject(('modes', 1, 'appearance'), 'light')

    def test_native_menu_lifecycle_keys_and_selection(self):
        for key, value in [('itemID', 'pin-group-restore-isolation'), ('expectedEnabled', False), ('cancelledWithEscape', True),
                           ('closed', False), ('trackingBeginCount', 0), ('trackingEndCount', 2), ('exactOwnedMenu', False),
                           ('returnHighlightVerified', False), ('postedKeyCount', 41), ('lastKeyCode', 125), ('failed', True),
                           ('clickReturnedSeconds', 2.001), ('deadlineSeconds', 3), ('failureCancellationIssued', True),
                           ('windowNumber', 101), ('selectionAfter', []), ('selectionBefore', [2, 0]), ('opened', 1)]:
            self.reject(('modes', 0, 'menuEvents', 2, key), value)
        self.reject(('modes', 0, 'menuEvents', 0, 'postedKeyCount'), 2)
        self.reject(('modes', 0, 'menuEvents', 1, 'menuPixels', 'status'), 'not-requested')
        self.reject(('modes', 0, 'menuEvents', 1, 'menuPixels', 'candidateCount'), -1)
        self.reject(('modes', 0, 'menuEvents', 1, 'menuPixels', 'reason'), '')
        self.reject(('modes', 0, 'menuEvents'), self.r['modes'][0]['menuEvents'][:-1])
        for value in (True, float('nan'), float('inf'), -1):
            self.reject(('modes', 0, 'menuEvents', 2, 'clickReturnedSeconds'), value)

    def test_frozen_native_lifecycle_identity_and_deadlines(self):
        path = ('modes', 0, 'menuEvents', 2)
        for key in ('trackingBeginElapsedSeconds', 'trackingEndElapsedSeconds', 'delegateOpenElapsedSeconds',
                    'delegateCloseElapsedSeconds', 'returnHighlightElapsedSeconds'):
            for value in (None, True, float('nan'), float('inf'), 0, 2.001):
                self.reject((*path, key), value)
        for key in ('trackingIdentityVerified', 'delegateOpenIdentityVerified', 'delegateCloseIdentityVerified',
                    'returnTargetMenuIdentityVerified', 'returnTargetEnabled', 'returnTargetHighlighted'):
            self.reject((*path, key), False)
        self.reject((*path, 'trackingBeginElapsedSeconds'), 0.245)
        self.reject((*path, 'returnHighlightElapsedSeconds'), 0.235)
        self.reject((*path, 'returnHighlightedItemID'), 'pin-group-restore-isolation')
        self.reject(('modes', 0, 'menuEvents', 0, 'delegateCloseIdentityVerified'), True)
        self.reject(('modes', 0, 'menuEvents', 0, 'delegateCloseElapsedSeconds'), 0.2)
        self.reject(('modes', 0, 'menuEvents', 0, 'returnTargetMenuIdentityVerified'), True)
        self.reject(('modes', 0, 'menuEvents', 0, 'returnHighlightElapsedSeconds'), 0.15)

    def test_owned_current_event_identity_is_not_replaceable_by_boolean_claim(self):
        path = ('modes', 0, 'menuEvents', 2, 'mouseDispatch')
        for prefix in ('', 'dequeued', 'current'):
            for suffix, bad in [('Type', 1), ('WindowNumber', 999), ('Modifiers', 1), ('EventNumber', 2), ('ClickCount', 2),
                                ('QuartzTimestamp', 555), ('Location', [100.25, 321])]:
                key = prefix + suffix if prefix else suffix[0].lower()+suffix[1:]
                self.reject((*path, key), bad)
        for key, value in [('route', 'sendAction'), ('sameEventIdentity', False), ('hitTestVerified', False),
                           ('quartzTimestamp', True), ('currentQuartzTimestamp', 2**64), ('currentLocation', [float('nan'), 320])]:
            self.reject((*path, key), value)

    def test_actual_group_prompt_cancel_and_duplicate_save_receipts(self):
        for section in ('groupPromptCancellations', 'groupPromptCollisions'):
            for key in ('promptObserved', 'draftWasExistingGroupName', 'manifestUnchanged', 'groupIDsUnchanged', 'indexUnchanged'):
                self.reject(('modes', 0, section, 0, key), False)
            self.reject(('modes', 0, section), self.r['modes'][0][section][::-1])
        self.reject(('modes', 0, 'groupPromptCancellations', 0, 'nativeCancelClicked'), False)
        for key, value in [('nativeSaveClicked', False), ('errorCount', 0), ('errorCase', 'other'), ('feedback', 'wrong'), ('errorModal', True)]:
            self.reject(('modes', 0, 'groupPromptCollisions', 0, key), value)
        self.reject(('modes', 0, 'errorModalStates'), [False, False, False, True])
        self.reject(('modes', 0, 'errors'), ['injected-restore-refusal', 'injected-isolation-refusal'])

    def test_all_twelve_exact_owners_must_release(self):
        for index in range(12):
            for key in ('controllerReleased', 'windowReleased', 'contentReleased'):
                self.reject(('ownership', index, key), False)
        self.reject(('ownership',), self.r['ownership'][:-1])
        self.reject(('ownership', 0, 'label'), self.r['ownership'][1]['label'])
        self.reject(('ownership', 1, 'label'), 'light.image.'+uid(99))
        self.reject(('ownership', 3, 'label'), 'light.rich.'+uid(3))

    def test_compact_geometry_has_fixed_nonweakened_limits(self):
        path = ('modes', 0, 'visual')
        for key, value in [('windowFrame', [100, 100, 681, 600]), ('visibleFrame', [200, 200, 600, 500]),
                           ('contentBounds', [0, 0, 680, 579]), ('pixelWidth', 679), ('fullVisibleFramesChecked', False),
                           ('controlsDoNotOverlap', False), ('controlGeometryScope', 'relaxed'), ('opaqueWindowBackgroundComposited', False)]:
            self.reject((*path, key), value)
        for key, value in [('frame', [-1, 20, 150, 24]), ('frame', [10, 20, 150, 17]), ('frame', [170, 20, 150, 24]),
                           ('frame', [10, float('nan'), 150, 24]), ('minimumSize', [152, 24]), ('hitTest', False), ('id', 'missing')]:
            self.reject((*path, 'controls', 0, key), value)
        self.reject(('modes', 0, 'oldControlIDs'), sorted(C.OLD_IDS)[:-1])
        self.reject(('modes', 0, 'minimumWindowSize'), [680, 601])

    def test_png_hash_pixels_alpha_and_bounds(self):
        visual = self.r['modes'][0]['visual']; data = (self.root/visual['file']).read_bytes()
        (self.root/visual['file']).write_bytes(data+b'tampered')
        with self.assertRaisesRegex(ValueError, 'hash'): self.check()
        self.replace(visual, data)
        self.replace(self.r['modes'][1]['visual'], data)
        with self.assertRaisesRegex(ValueError, 'pixels identical'): self.check()
        self.replace(self.r['modes'][1]['visual'], OLD.png(680, 578, 70, alpha=254))
        with self.assertRaisesRegex(ValueError, 'transparent'): self.check()
        self.replace(self.r['modes'][1]['visual'], OLD.png(680, 578, 70))
        oversized = bytearray(data); oversized[16:20] = (4_000_001).to_bytes(4, 'big')
        self.replace(visual, oversized)
        with mock.patch.object(C.P.PNG, 'png_rgba') as decoder:
            with self.assertRaisesRegex(ValueError, 'extent/bound'): self.check()
            decoder.assert_not_called()

    def test_symlink_escapes_and_duplicate_json_are_rejected(self):
        outside = self.root/'outside'; outside.mkdir(); target = outside/'manager.png'
        visual = self.r['modes'][0]['visual']; path = self.root/visual['file']; path.rename(target); path.symlink_to(target)
        with self.assertRaisesRegex(ValueError, 'escaped'): self.check()
        with self.assertRaisesRegex(ValueError, 'duplicate JSON'):
            json.loads('{"schema":1,"schema":1}', object_pairs_hook=C.P.unique_object)

    def test_cli_uses_same_five_arguments_and_reports_menu_limit(self):
        path = self.root/'pin-isolation-menu.json'; path.write_text(json.dumps(self.r))
        result = subprocess.run([sys.executable, str(ROOT/'check-pin-isolation.py'), str(path), str(self.app),
                                 'source', '0.21.0', '216'], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('unavailable menu pixels do not establish menu appearance', result.stdout)
        path.write_text(path.read_text().replace('"elapsedSeconds": 12', '"elapsedSeconds": NaN'))
        result = subprocess.run([sys.executable, str(ROOT/'check-pin-isolation.py'), str(path), str(self.app),
                                 'source', '0.21.0', '216'], text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__': unittest.main()
