"""Synthetic checker contracts and mutations, not native installed-app evidence."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
from unittest import mock
import zlib


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result)
    return result


ROOT = Path(__file__).resolve().parents[1]
C = module('annotation_preferences_check', ROOT / 'check-annotation-preferences.py')
OLD = module('portable_test_helpers', Path(__file__).with_name('test_check_portable_settings.py'))


def raster(blue=False):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    color = b'\x00\x70\xff\xff' if blue else b'\xff\x30\x30\xff'
    width = 10 if blue else 4
    rows = [b'\0' + b'\xff\xff\xff\xff' * 70 + color * width + b'\xff\xff\xff\xff' * (570-width)
            for _ in range(360)]
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 640, 360, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(b''.join(rows))) + chunk(b'IEND', b'')


class AnnotationPreferencesCheckerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.app = self.root/'PicShot.app'
        (self.app/'Contents/MacOS').mkdir(parents=True)
        self.executable = self.app/'Contents/MacOS/PicShot'; self.executable.write_bytes(b'synthetic executable identity only')
        info = dict(CFBundleExecutable='PicShot', PicShotSourceCommit='source', CFBundleShortVersionString='0.19.2', CFBundleVersion='186')
        plist = plistlib.dumps(info); (self.app/'Contents/Info.plist').write_bytes(plist)
        base = OLD.report()
        self.r = dict(schemaVersion=1, status='passed', bundlePath=str(self.app), sourceCommit='source', version='0.19.2', buildVersion='186',
            executableSHA256=hashlib.sha256(self.executable.read_bytes()).hexdigest(), infoPlistSHA256=hashlib.sha256(plist).hexdigest(),
            elapsedSeconds=4, overallDeadlineSeconds=120, maximumRasterPixels=4_000_000, checks=sorted(C.CHECKS),
            ownership=dict(controllerCount=20, releaseDeadlineSeconds=4, retainedControllers=0, retainedWindows=0, retainedContentViews=0, allOwnedWindowsClosed=True),
            settings=[], imports=[], styles=[], visuals=[], keyEvents=[], menuEvents=[], fileSHA256={})
        for field in ('userPreferencesReadOrWritten', 'globalInputPosted', 'globalHotkeysRegistered', 'permissionRequests',
                      'networkUsed', 'liveScreenCaptured', 'ordinaryTextCaptured', 'memoryStabilityAssessed'):
            self.r[field] = False
        for index, mode in enumerate(C.MODES):
            settings = dict(appearance=mode, rowSelection=base['tableSelectionEvents'][index], saveCallbacks=1)
            for field in 'remap duplicateRejected reservedRejected clearReset cancelPreserved immutableOldEditor newEditorMap fieldTypingPreserved markedIMEPreserved'.split(): settings[field] = True
            self.r['settings'].append(settings)
            imports = dict(appearance=mode, oldValue='颜色 #FF0000FF', newValue='颜色 #0000FFFF', rollbackWriteCount=2, callbacks=0)
            for field in 'colorDetailVisible previewReadOnly cancelPreservedDraft rollbackPreservedDraft rollbackErrorVisible oldMissingSectionsPreserved'.split(): imports[field] = True
            self.r['imports'].append(imports)
            styles = dict(appearance=mode, defaultLineWidth=4, savedLineWidth=10, defaultPixelSHA256='a'*64, resetPixelSHA256='a'*64, reopenedPixelSHA256='b'*64)
            for field in 'existingLayerUnchanged savedStyleRestored futureMarksOnly reopenedStyleMatches nativeOutputPNGExact resetRestoresOriginal'.split(): styles[field] = True
            self.r['styles'].append(styles)
            for purpose, code, modifiers in C.KEYS:
                self.r['keyEvents'].append(dict(purpose=purpose+'-'+mode, keyCode=code, modifiers=modifiers, windowNumber=100,
                    eventType=10, ownedQuartzTimestamp=12345, dequeuedQuartzTimestamp=12345, ownedWindowIsKey=True, dispatchRoute='NSApplication.nextEvent/sendEvent'))
            for item in ('width.10', 'save', 'restore', 'reset'):
                self.r['menuEvents'].append(dict(appearance=mode, itemID=item if item.startswith('width.') else 'annotation.savedStyles.'+item,
                    controlID='annotation.lineWidth' if item.startswith('width.') else 'annotation.savedStyles', opened=True, closed=True,
                    nativeKeyboardSelection=True, postedKeyCount=3, timeoutSeconds=2, dispatchRoute='owned-mouseDown/native-menu-tracking'))
            for category in C.CATEGORIES:
                v = copy.deepcopy(next(v for v in base['visuals'] if v['category'] == ('review' if category == 'import' else 'configuration') and v['appearance'] == mode))
                v.update(category=category, file=f'annotation-preferences-{category}-{mode}.png')
                if category == 'styles': v.update(paletteFrame=[10, 20, 760, 55], toolbarFrame=[10, 90, 760, 40])
                ids = {'shortcuts': ['localShortcuts.capture', 'localShortcuts.clear', 'localShortcuts.restoreDefaults', 'settings.save', 'settings.cancel'],
                       'import': ['settings.importReview.cancel', 'settings.importReview.apply'], 'styles': ['annotation.savedStyles', 'annotation.lineWidth']}[category]
                v['controls'] = [dict(id=value, frame=[20+index*150, 30, 140, 32], hitTest=True) for index, value in enumerate(ids)]
                if category == 'import':
                    opening = v['openingReview']; opening['firstChangeID'] = opening['expectedFirstChangeID'] = 'settings.importReview.change.annotationStyle.rectangle'
                    for row, text in zip(opening['firstChangeLabels'], ['矩形默认样式', '当前：'+imports['oldValue'], '导入：'+imports['newValue']]): row['text'] = text
                self.r['visuals'].append(v)
                self.replace(v['file'], OLD.png(800, 570, 16+index*48))
            for name in ('default', 'reopened', 'reset'):
                self.replace(f'annotation-preferences-{name}-{mode}.png', raster(name == 'reopened'))

    def replace(self, name, data):
        (self.root/name).write_bytes(data); self.r['fileSHA256'][name] = hashlib.sha256(data).hexdigest()

    def check(self):
        C.validate(self.r, expected_commit='source', expected_version='0.19.2', expected_build='186', installed_app=self.app, evidence_directory=self.root)

    def reject(self, mutation):
        prior = copy.deepcopy(self.r); mutation(self.r)
        with mock.patch.object(C.P.PNG, 'png_rgba', wraps=C.P.PNG.png_rgba) as decoder:
            with self.assertRaises((ValueError, KeyError, TypeError)): self.check()
            decoder.assert_not_called()
        self.r = prior

    def test_accept_complete_contract_and_canonical_bundle_alias(self):
        alias = self.root/'alias.app'; alias.symlink_to(self.app)
        self.r['bundlePath'] = str(alias)
        with mock.patch.object(C.P.PNG, 'png_rgba', wraps=C.P.PNG.png_rgba) as decoder:
            self.check(); self.assertEqual(decoder.call_count, 12)

    def test_reject_identity_tampering(self):
        for key, value in [('sourceCommit', 'old'), ('buildVersion', '185'), ('executableSHA256', '0'*64), ('infoPlistSHA256', '0'*64)]:
            self.reject(lambda r: r.update({key: value}))
        self.executable.write_bytes(b'changed binary')
        with self.assertRaisesRegex(ValueError, 'executable hash'): self.check()

    def test_reject_scope_deadline_coverage_and_cleanup(self):
        for mutation in [lambda r: r.update(elapsedSeconds=float('nan')), lambda r: r.update(elapsedSeconds=120), lambda r: r['checks'].pop(),
                         lambda r: r.update(globalInputPosted=True), lambda r: r.update(ordinaryTextCaptured=True),
                         lambda r: r['ownership'].update(retainedWindows=1), lambda r: r['ownership'].update(controllerCount=19),
                         lambda r: r['styles'][0].update(futureMarksOnly=False), lambda r: r['settings'][0].update(markedIMEPreserved=False),
                         lambda r: r['imports'][0].update(rollbackWriteCount=1)]: self.reject(mutation)

    def test_reject_event_forgery_or_bypassed_menu(self):
        for mutation in [lambda r: r['keyEvents'].pop(), lambda r: r['keyEvents'][0].update(keyCode=True),
                         lambda r: r['keyEvents'][0].update(dequeuedQuartzTimestamp=12346), lambda r: r['keyEvents'][0].update(ownedWindowIsKey=False),
                         lambda r: r['menuEvents'][0].update(dispatchRoute='performAction'), lambda r: r['menuEvents'][0].update(closed=False),
                         lambda r: r['settings'][0]['rowSelection'].update(selectedRowAfter=0)]: self.reject(mutation)

    def test_reject_clipped_or_obscured_controls_and_color_preview(self):
        for mutation in [lambda r: r['visuals'][0]['controls'][0].update(frame=[-5, 30, 140, 32]),
                         lambda r: r['visuals'][0]['controls'][0].update(hitTest=False),
                         lambda r: r['visuals'][0]['controls'][1].update(frame=r['visuals'][0]['controls'][0]['frame']),
                         lambda r: r['visuals'][1]['openingReview']['firstChangeLabels'][1].update(text='当前：矩形'),
                         lambda r: r['imports'][0].update(newValue=r['imports'][0]['oldValue'])]: self.reject(mutation)

    def test_reject_file_substitution_and_path_escape(self):
        self.reject(lambda r: r['fileSHA256'].update({'../escape.png': '0'*64}))
        first = sorted(C.FILES)[0]; self.r['fileSHA256'][first] = '0'*64
        with self.assertRaisesRegex(ValueError, 'evidence hash'): self.check()

    def test_reject_decoded_reset_pixels(self):
        self.replace('annotation-preferences-reset-light.png', raster(True))
        with self.assertRaisesRegex(ValueError, 'decoded saved/reset'): self.check()


if __name__ == '__main__':
    unittest.main()
