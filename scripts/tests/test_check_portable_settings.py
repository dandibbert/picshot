"""Synthetic schema and tamper tests. These are not installed native UI evidence."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest import mock
import zlib

SPEC = importlib.util.spec_from_file_location('portable_check', Path(__file__).resolve().parents[1] / 'check-portable-settings.py')
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


def png(width, height, seed, alpha=255):
    def chunk(kind, value):
        return struct.pack('>I', len(value)) + kind + value + struct.pack('>I', zlib.crc32(kind + value) & 0xffffffff)
    row = b'\x00' + bytes(v for x in range(width) for v in ((x+seed) % 256, x % 256, seed, alpha))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(row * height)) + chunk(b'IEND', b''))


def document():
    return dict(format='picshot.preferences', schemaVersion=1,
                preferences=dict(appearance='system', screenshotDelaySeconds=0, screenshotShowsCursor=False,
                                 pinDesktopVisibility='currentDesktop', restorePinsOnLaunch=False,
                                 automaticallyRecognizePinText=False, historyDays=30, historyCount=500, historyMegabytes=1024),
                hotkeys=[dict(action=action, binding=None) for action in
                         ('capture', 'clipboardPin', 'restoreLastPin', 'history', 'recordingPauseResume', 'recordingStopSave')],
                annotationToolOrder=CHECK.ORDER)


def report():
    commit = dict(callbacks=1, hotkeyValidations=1, preferenceWrites=4, duplicateAdditionalWrites=0)
    failures = [dict(case=kind, preserved=True, callbacks=0, errorVisible=True, hotkeyValidations=probes, writeAttempts=writes)
                for kind, probes, writes in [('stale', 0, 0), ('os-conflict', 1, 0), ('rollback', 1, 2)]]
    failures += [dict(case='malformed', preserved=True, sheetOpened=False),
                 dict(case='parent-close', preserved=True, ownedSheetDismissed=True)]
    rows = [dict(index=index, warmup=index < 2, action='apply' if index % 2 else 'cancel', callbacks=index % 2,
                 releasedControllers=2, releasedWindows=2, releasedContentViews=2) for index in range(14)]
    visuals = []
    ids = {'configuration': ['settings.configuration.export', 'settings.configuration.import'],
           'annotations': ['annotationToolbar.moveUp', 'annotationToolbar.moveDown', 'annotationToolbar.restoreDefaults'],
           'review': ['settings.importReview.cancel', 'settings.importReview.apply']}
    for category in ids:
        for appearance in ('light', 'dark'):
            controls = [dict(id=value, title='Synthetic control', frame=[20+index*150, 30, 140, 32],
                             screenFrame=[120+index*150, 130, 140, 32], minimumSize=[120, 28],
                             enabled=True, hitTest=True, readable=True) for index, value in enumerate(ids[category])]
            visuals.append(dict(category=category, appearance=appearance,
                                file=f'portable-settings-{category}-{appearance}.png', pixelWidth=800, pixelHeight=570,
                                windowFrame=[100, 100, 800, 592], visibleFrame=[0, 0, 1280, 800], contentBounds=[0, 0, 800, 570],
                                controls=controls, readableLabelCount=3, fullVisibleFramesChecked=True,
                                controlsDoNotOverlap=True, scrollViewportsChecked=True, opaqueWindowBackgroundComposited=True))
            if category == 'review':
                visuals[-1]['openingReview'] = dict(checkMoment='immediately-after-opening-before-any-scroll',
                    firstChangeID='settings.importReview.change.appearance', expectedFirstChangeID='settings.importReview.change.appearance',
                    clipBounds=[0, 0, 560, 300], documentBounds=[0, 0, 560, 600], documentFrameInClip=[0, 0, 560, 600],
                    documentVisibleRect=[0, 0, 560, 300], scrollOffset=[0, 0], documentIsFlipped=True,
                    firstChangeFrameInClip=[12, 10, 536, 60], firstChangeFrameInDocument=[12, 10, 536, 60],
                    firstChangeLabels=[dict(text=text, frameInClip=[12, 10+index*20, 536, 18],
                        frameInDocument=[12, 10+index*20, 536, 18]) for index, text in enumerate(['界面主题', '当前：跟随系统', '导入：深色'])])
    return dict(schemaVersion=1, status='passed', sourceCommit='source', version='1.6.9', buildVersion='169',
                bundlePath='/tmp/PicShot.app', elapsedSeconds=2.5, overallDeadlineSeconds=120,
                userPreferencesReadOrWritten=False, globalHotkeysRegistered=False, globalInputPosted=False,
                permissionRequests=False, networkUsed=False, liveScreenCaptured=False, canonicalTemporaryRoot=True,
                interactionRoute='NSView.hitTest and owned local NSEvents; buttons use mouseDown, tables use NSApplication.nextEvent/sendEvent with queued mouseUp',
                tableSelectionEvents=[dict(appearance=appearance, status='passed-local-row-selection',
                    dispatchRoute='owned-nextEvent-sendEvent', ownedDownVerified=True, ownedDownType=1,
                    requestedRow=1, rowAtDispatch=1, selectedRowAfter=1, selectedRowBefore=0,
                    targetPointVisible=True, windowIsKey=True, windowNumber=100, ownedDownWindowNumber=100,
                    keyWindowNumber=100, applicationIsActive=True, applicationIsRunning=True,
                    currentEventIsSuppliedDown=True, currentEventType=1, currentEventWindowNumber=100,
                    eventIdentity=dict(sameType=True, sameWindow=True, sameQuartzTimestamp=True, sameLocation=True,
                        sameEventNumber=True, sameClickCount=True, sameModifiers=True, ownedWindowIsKey=True,
                        sameTimestamp=False, sameObject=False, timestampDifference=-0.0000000003,
                        expected=dict(type=1, windowNumber=100, quartzTimestampNanoseconds=2838590167208,
                            eventNumber=1, clickCount=1, modifierFlags=0, timestamp=2838.5901672083, location=[473.5, 417]),
                        dequeued=dict(type=1, windowNumber=100, quartzTimestampNanoseconds=2838590167208,
                            eventNumber=1, clickCount=1, modifierFlags=0, timestamp=2838.590167208, location=[473.5, 417])))
                    for appearance in ('light', 'dark')],
                checks=sorted(CHECK.CHECKS), fileRoundTrip=dict(readbackMatchesWritten=True, savedOnlyExport=True,
                                                             readbackByteCount=1400, maximumFileBytes=65536),
                commitObservationLight=commit.copy(), commitObservationDark=commit.copy(), failureCases=failures,
                resourceCycles=dict(warmupCycles=2, measuredCycles=12, releaseProbeCount=28, retainedControllers=0,
                                    retainedWindows=0, retainedContentViews=0, releaseDeadlinePerCycleSeconds=4,
                                    memoryStabilityAssessed=False, rows=rows), visuals=visuals, fileSHA256={})


class PortableSettingsCheckerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.blobs = {'portable-settings-export.json': json.dumps(document()).encode()}
        for category in ('configuration', 'annotations', 'review'):
            for appearance, seed in [('light', 16), ('dark', 64)]:
                cls.blobs[f'portable-settings-{category}-{appearance}.png'] = png(800, 570, seed)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.report = report()
        for name, blob in self.blobs.items():
            (self.root/name).write_bytes(blob)
            self.report['fileSHA256'][name] = hashlib.sha256(blob).hexdigest()

    def check(self):
        CHECK.validate(self.report, expected_commit='source', expected_version='1.6.9', expected_build='169',
                       installed_app=Path('/tmp/PicShot.app'), evidence_directory=self.root)

    def reject(self, mutation, pattern=None):
        original = copy.deepcopy(self.report)
        mutation(self.report)
        with mock.patch.object(CHECK.PNG, 'png_rgba', wraps=CHECK.PNG.png_rgba) as decode:
            with self.assertRaisesRegex(ValueError, pattern or '.'):
                self.check()
            decode.assert_not_called()
        self.report = original

    def replace(self, name, data):
        (self.root/name).write_bytes(data)
        self.report['fileSHA256'][name] = hashlib.sha256(data).hexdigest()

    def test_accept_complete_synthetic_schema(self):
        with mock.patch.object(CHECK.PNG, 'png_rgba', wraps=CHECK.PNG.png_rgba) as decode:
            self.check()
            self.assertEqual(decode.call_count, 6, 'Every valid visual must still decode actual PNG pixels')

    def test_reject_missing_coverage_or_wrong_bundle(self):
        for mutation in [lambda r: r['checks'].pop(), lambda r: r.update(sourceCommit='old'),
                         lambda r: r.update(buildVersion='168'), lambda r: r.update(bundlePath='/elsewhere/PicShot.app')]:
            self.reject(mutation)
        for field in ('requestedRow', 'rowAtDispatch', 'selectedRowAfter', 'selectedRowBefore',
                      'ownedDownType', 'windowNumber', 'ownedDownWindowNumber', 'keyWindowNumber',
                      'currentEventType', 'currentEventWindowNumber'):
            for invalid in (True, False, 1.0, '1', None):
                with self.subTest(field=field, invalid=invalid):
                    self.reject(lambda r: r['tableSelectionEvents'][0].update({field: invalid}))
        for field, invalid in [('quartzTimestampNanoseconds', True), ('quartzTimestampNanoseconds', 2838590167209),
                               ('quartzTimestampNanoseconds', None), ('eventNumber', 2), ('clickCount', 2),
                               ('modifierFlags', 1), ('location', [473.5, 418])]:
            with self.subTest(identityField=field, invalid=invalid):
                self.reject(lambda r: r['tableSelectionEvents'][0]['eventIdentity']['dequeued'].update({field: invalid}))
        for mutation in [lambda r: r.pop('tableSelectionEvents'),
                         lambda r: r['tableSelectionEvents'][0].update(selectedRowAfter=0),
                         lambda r: r['tableSelectionEvents'][0].update(ownedDownVerified=False),
                         lambda r: r['tableSelectionEvents'][0].update(windowIsKey=False),
                         lambda r: r['tableSelectionEvents'][0].update(ownedDownWindowNumber=101)]:
            self.reject(mutation)

    def test_reject_unbounded_runtime_and_unsafe_side_effects(self):
        for mutation in [lambda r: r.update(elapsedSeconds=120), lambda r: r.update(elapsedSeconds=float('nan')),
                         lambda r: r.update(globalHotkeysRegistered=True), lambda r: r.update(globalInputPosted=True),
                         lambda r: r.update(userPreferencesReadOrWritten=True), lambda r: r.update(canonicalTemporaryRoot=False)]:
            self.reject(mutation)

    def test_reject_duplicate_apply_and_incomplete_rollback(self):
        for mutation in [lambda r: r['commitObservationLight'].update(callbacks=2),
                         lambda r: r['commitObservationDark'].update(duplicateAdditionalWrites=1),
                         lambda r: r['failureCases'][2].update(writeAttempts=1),
                         lambda r: r['failureCases'][1].update(writeAttempts=1),
                         lambda r: r['failureCases'][0].update(preserved=False)]:
            self.reject(mutation)

    def test_reject_missing_cycles_or_retained_owners(self):
        for mutation in [lambda r: r['resourceCycles']['rows'].pop(),
                         lambda r: r['resourceCycles'].update(retainedWindows=1),
                         lambda r: r['resourceCycles']['rows'][3].update(releasedControllers=1),
                         lambda r: r['resourceCycles'].update(memoryStabilityAssessed=True),
                         lambda r: r['resourceCycles']['rows'][1].update(action='cancel')]:
            self.reject(mutation)

    def test_reject_full_frame_outside_root_even_if_alignment_would_fit(self):
        self.reject(lambda r: r['visuals'][0]['controls'][0].update(frame=[-3, 30, 140, 32]), 'full control clipped')

    def test_reject_full_window_outside_display(self):
        self.reject(lambda r: r['visuals'][0].update(windowFrame=[-20, 100, 800, 592]), 'full window')

    def test_reject_overlapping_visible_controls(self):
        self.reject(lambda r: r['visuals'][0]['controls'][1].update(frame=[150, 30, 140, 32]), 'overlap')

    def test_reject_truncated_titles_or_missing_hit_test(self):
        self.reject(lambda r: r['visuals'][0]['controls'][0].update(minimumSize=[170, 28]), 'unreadable')
        self.reject(lambda r: r['visuals'][0]['controls'][0].update(hitTest=False), 'hit/readability')
        self.reject(lambda r: r['visuals'][4].pop('openingReview'), 'opening review evidence')
        self.reject(lambda r: r['visuals'][4]['openingReview'].update(firstChangeFrameInClip=[12, -1, 536, 60]), 'complete first change clipped')
        self.reject(lambda r: r['visuals'][4]['openingReview']['firstChangeLabels'][0].update(frameInClip=[12, -18, 536, 18]), 'first change text clipped')
        self.reject(lambda r: r['visuals'][5]['openingReview'].update(clipBounds=[0, 40, 560, 300], scrollOffset=[0, 40]), 'complete first change clipped')
        self.reject(lambda r: r['visuals'][5]['openingReview']['firstChangeLabels'].pop(), 'labels missing')
        self.reject(lambda r: r['visuals'][4]['openingReview'].update(firstChangeID='settings.importReview.change.screenshotDelaySeconds',
                    expectedFirstChangeID='settings.importReview.change.screenshotDelaySeconds'), 'first change identity')

    def test_reject_unknown_export_field_and_draft_order_even_with_updated_hash(self):
        name = 'portable-settings-export.json'
        value = document(); value['localPath'] = '/synthetic/private'
        self.replace(name, json.dumps(value).encode())
        with self.assertRaisesRegex(ValueError, 'allowlist'): self.check()
        value = document(); value['annotationToolOrder'] = list(reversed(CHECK.ORDER))
        self.replace(name, json.dumps(value).encode())
        with self.assertRaisesRegex(ValueError, 'draft'): self.check()

    def test_reject_duplicate_export_fields(self):
        self.replace('portable-settings-export.json', b'{"format":"picshot.preferences","format":"picshot.preferences"}')
        with self.assertRaisesRegex(ValueError, 'duplicate JSON'): self.check()

    def test_reject_digest_change_and_identical_light_dark(self):
        name = 'portable-settings-review-dark.png'
        (self.root/name).write_bytes(self.blobs[name]+b'x')
        with self.assertRaisesRegex(ValueError, 'digest mismatch'): self.check()
        self.replace(name, self.blobs['portable-settings-review-light.png'])
        with self.assertRaisesRegex(ValueError, 'identical'): self.check()

    def test_reject_png_corruption_even_with_updated_digest(self):
        name = 'portable-settings-review-dark.png'
        blob = bytearray(self.blobs[name]); blob[30] ^= 1
        with mock.patch.object(CHECK.PNG, 'png_rgba', wraps=CHECK.PNG.png_rgba) as decode:
            self.replace(name, bytes(blob))
            with self.assertRaisesRegex(ValueError, 'CRC'): self.check()
            self.assertEqual(decode.call_count, 6)
            self.replace(name, png(800, 570, 64, alpha=0))
            with self.assertRaisesRegex(ValueError, 'transparent'): self.check()
            self.assertEqual(decode.call_count, 12, 'Changed files must be reread and decoded on the next validation')

    def test_reject_evidence_symlink_escape(self):
        with tempfile.TemporaryDirectory() as outside:
            name = 'portable-settings-export.json'
            target = Path(outside)/name; target.write_bytes(self.blobs[name])
            path = self.root/name; path.unlink(); path.symlink_to(target)
            with self.assertRaisesRegex(ValueError, 'escaped directory'): self.check()


if __name__ == '__main__':
    unittest.main()
