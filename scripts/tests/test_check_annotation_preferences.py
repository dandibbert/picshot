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


def title_evidence():
    # Synthetic numeric schema input only; these values are not AppKit measurements.
    return dict(controlID='annotation.savedStyles', expectedTitle='样式', buttonTitle='样式', cellTitle='样式',
        attributedTitle='样式', firstItemTitle='样式',
        measurement='NSPopUpButtonCell.titleRect+CoreText-untruncated-attributed-title',
        controlBounds=[0, 0, 140, 32], titleRect=[8, 5, 108, 22], titleAdvance=26,
        cellFontName='Synthetic Font', cellFontSize=13, fullTitleFits=True)


def compact_evidence(tool):
    return dict(tool=tool, activeTool='select' if tool == 'number' else tool, selectedNumber=tool == 'number',
        contentBounds=[0, 0, 760, 600], paletteFrame=[10, 20, 740, 55], toolbarFrame=[10, 90, 740, 40],
        fullVisibleFramesChecked=True, controlsDoNotOverlap=True, savedStyleTitle=title_evidence(),
        controls=[dict(id=value, frame=[20+index*150, 30, 140, 32], hitTest=True)
                  for index, value in enumerate(C.COMPACT_CONTROLS[tool])])


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
            styles.update(initialSavedStyleTitle=title_evidence(), compactPaletteStateRestored=True,
                          compactPalettes=[compact_evidence(tool) for tool in C.COMPACT_TOOLS])
            self.r['styles'].append(styles)
            for purpose, code, modifiers in C.KEYS:
                self.r['keyEvents'].append(dict(purpose=purpose+'-'+mode, keyCode=code, modifiers=modifiers, windowNumber=100,
                    eventType=10, ownedQuartzTimestamp=12345, dequeuedQuartzTimestamp=12345, ownedWindowIsKey=True, dispatchRoute='NSApplication.nextEvent/sendEvent'))
            for item in ('width.10', 'save', 'restore', 'reset'):
                self.r['menuEvents'].append(dict(appearance=mode, itemID=item if item.startswith('width.') else 'annotation.savedStyles.'+item,
                    controlID='annotation.lineWidth' if item.startswith('width.') else 'annotation.savedStyles', opened=True, closed=True,
                    nativeKeyboardSelection=True, postedKeyCount=3, timeoutSeconds=2, dispatchRoute='owned-mouseDown/native-menu-tracking'))
                if item != 'width.10': self.r['menuEvents'][-1]['savedStyleTitle'] = title_evidence()
            for category in C.CATEGORIES:
                v = copy.deepcopy(next(v for v in base['visuals'] if v['category'] == ('review' if category == 'import' else 'configuration') and v['appearance'] == mode))
                v.update(category=category, file=f'annotation-preferences-{category}-{mode}.png')
                if category == 'styles': v.update(paletteFrame=[10, 20, 760, 55], toolbarFrame=[10, 90, 760, 40], savedStyleTitle=title_evidence())
                ids = {'shortcuts': ['localShortcuts.capture', 'localShortcuts.clear', 'localShortcuts.restoreDefaults', 'settings.save', 'settings.cancel'],
                       'import': ['settings.importReview.cancel', 'settings.importReview.apply'], 'styles': ['annotation.savedStyles', 'annotation.lineWidth'],
                       'styles-narrow-number': C.COMPACT_CONTROLS['number']}[category]
                v['controls'] = [dict(id=value, frame=[20+index*150, 30, 140, 32], hitTest=True) for index, value in enumerate(ids)]
                if category == 'styles-narrow-number':
                    v.update(styles['compactPalettes'][2], pixelWidth=760, pixelHeight=600)
                    styles['compactPalettes'][2] = copy.deepcopy(v)
                if category == 'import':
                    opening = v['openingReview']; opening['firstChangeID'] = opening['expectedFirstChangeID'] = 'settings.importReview.change.annotationStyle.rectangle'
                    for row, text in zip(opening['firstChangeLabels'], ['矩形默认样式', '当前：'+imports['oldValue'], '导入：'+imports['newValue']]): row['text'] = text
                self.r['visuals'].append(v)
                self.replace(v['file'], OLD.png(v['pixelWidth'], v['pixelHeight'], 16+index*48))
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
            self.check(); self.assertEqual(decoder.call_count, 14)

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

    def test_reject_saved_style_title_rewrite_at_each_observation(self):
        paths = [('styles', index, 'initialSavedStyleTitle') for index in range(2)]
        paths += [('menuEvents', index, 'savedStyleTitle') for index in (1, 2, 3, 5, 6, 7)]
        paths += [('visuals', index, 'savedStyleTitle') for index in (2, 3, 6, 7)]
        for section, index, key in paths:
            for field in ('expectedTitle', 'buttonTitle', 'cellTitle', 'attributedTitle', 'firstItemTitle'):
                with self.subTest(section=section, index=index, field=field):
                    self.reject(lambda r: r[section][index][key].update({field: '保存为矩形默认样式'}))
        for index in range(2):
            for tool in range(3):
                self.reject(lambda r: r['styles'][index]['compactPalettes'][tool]['savedStyleTitle'].update(cellTitle='…'))

    def test_reject_unmeasured_or_clipped_saved_style_title(self):
        for key, value in [('measurement', 'accessibility-label'), ('controlID', 'annotation.lineWidth'),
                           ('titleAdvance', 109), ('titleAdvance', 0), ('titleAdvance', float('nan')),
                           ('titleRect', [8, 5, 133, 22]), ('titleRect', [0, 0, 0, 22]),
                           ('cellFontName', ''), ('cellFontSize', 0), ('fullTitleFits', False)]:
            self.reject(lambda r: r['styles'][0]['initialSavedStyleTitle'].update({key: value}))
        self.reject(lambda r: r['visuals'][2]['savedStyleTitle'].update(controlBounds=[0, 0, 150, 32]))
        self.reject(lambda r: r['styles'][0].pop('initialSavedStyleTitle'))
        self.reject(lambda r: r['menuEvents'][1].pop('savedStyleTitle'))
        # The gate uses measured advance and title rect, with no fixed button width
        # requirement or extra tolerance. Exact fit passes; any shortfall fails.
        row = title_evidence(); row.update(controlBounds=[0, 0, 54, 32], titleRect=[8, 5, 26, 22])
        C.saved_style_title(row, [20, 30, 54, 32])
        row['titleAdvance'] = 26.01
        with self.assertRaisesRegex(ValueError, 'title advance'): C.saved_style_title(row)

    def test_reject_missing_narrow_selected_number_or_detached_pixels(self):
        for mutation in [lambda r: r['styles'][0]['compactPalettes'].pop(),
                         lambda r: r['styles'][0]['compactPalettes'].reverse(),
                         lambda r: r['styles'][0]['compactPalettes'][0].update(contentBounds=[0, 0, 761, 600]),
                         lambda r: r['styles'][0]['compactPalettes'][2].update(activeTool='number'),
                         lambda r: r['styles'][0]['compactPalettes'][2].update(selectedNumber=False),
                         lambda r: r['styles'][0]['compactPalettes'][1].update(paletteFrame=[10, 20, 751, 55]),
                         lambda r: r['styles'][0]['compactPalettes'][1]['controls'][0].update(frame=[745, 30, 54, 22]),
                         lambda r: r['styles'][0]['compactPalettes'][2]['controls'][1].update(hitTest=False),
                         lambda r: r['styles'][0]['compactPalettes'][2]['controls'].pop(),
                         lambda r: r['styles'][0].update(compactPaletteStateRestored=False),
                         lambda r: r['visuals'][3].update(tool='text'),
                         lambda r: r['visuals'].pop(3),
                         lambda r: r['fileSHA256'].pop('annotation-preferences-styles-narrow-number-light.png')]: self.reject(mutation)

    def test_reject_file_substitution_and_path_escape(self):
        self.reject(lambda r: r['fileSHA256'].update({'../escape.png': '0'*64}))
        first = sorted(C.FILES)[0]; self.r['fileSHA256'][first] = '0'*64
        with self.assertRaisesRegex(ValueError, 'evidence hash'): self.check()

    def test_reject_decoded_reset_pixels(self):
        self.replace('annotation-preferences-reset-light.png', raster(True))
        with self.assertRaisesRegex(ValueError, 'decoded saved/reset'): self.check()


if __name__ == '__main__':
    unittest.main()
