"""Synthetic checker contracts only; no claim of native AppKit execution."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest import mock
import uuid


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result)
    return result


ROOT = Path(__file__).resolve().parents[1]
C = module('pin_management_check', ROOT/'check-pin-management.py')
OLD = module('pin_management_png_test', Path(__file__).with_name('test_check_portable_settings.py'))


def uid(index): return str(uuid.UUID(int=index)).upper()


class PinManagementCheckerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.app = self.root/'PicShot.app'
        (self.app/'Contents/MacOS').mkdir(parents=True)
        self.executable = self.app/'Contents/MacOS/PicShot'; self.executable.write_bytes(b'synthetic executable identity only')
        info = dict(CFBundleExecutable='PicShot', PicShotSourceCommit='source', CFBundleShortVersionString='0.21', CFBundleVersion='192')
        plist = plistlib.dumps(info); (self.app/'Contents/Info.plist').write_bytes(plist)
        self.r = dict(schemaVersion=1, status='passed', bundlePath=str(self.app), sourceCommit='source', version='0.21', buildVersion='192',
            executableSHA256=hashlib.sha256(self.executable.read_bytes()).hexdigest(), infoPlistSHA256=hashlib.sha256(plist).hexdigest(),
            elapsedSeconds=8, overallDeadlineSeconds=120, maximumRasterPixels=4_000_000,
            preferenceReadScope='group manager reads restorePinSessionOnLaunch only', canonicalTemporaryRoot=True,
            scope='Synthetic managed pins; owned local AppKit events and cached complete content views; weak ownership only',
            checks=sorted(C.CHECKS), flows=[], actions=[], visuals=[], fileSHA256={},
            ownership=dict(controllerCount=56, retainedControllers=0, retainedWindows=0, retainedContentViews=0,
                           releaseDeadlineSeconds=4, allOwnedWindowsClosed=True),
            resourceCycles=dict(warmupCycles=2, measuredCycles=10, releaseProbeCount=24, releaseDeadlineSeconds=4,
                                maximumHistoryLevels=12, maximumHistoryBytes=524_288, rows=[]))
        for field in C.FALSE_FIELDS.split(): self.r[field] = False
        for index in range(12):
            action = C.CYCLE_ACTIONS[index % 6]
            self.r['resourceCycles']['rows'].append(dict(index=index, action=action, warmup=index<2,
                callbacks=int(action.endswith('save')), releasedControllers=2, releasedWindows=2, releasedContentViews=2))
        for mode_index, mode in enumerate(C.MODES):
            text_id, group_id, image_id = uid(1+mode_index*10), uid(2+mode_index*10), uid(3+mode_index*10)
            identity = dict(id=text_id, groupID=group_id, title='文字便笺', presentationSHA256='a'*64)
            text = dict(id=text_id, groupID=group_id, initialText=C.INITIAL, savedText=C.SAVED,
                beforeIdentity=copy.deepcopy(identity), afterIdentity=copy.deepcopy(identity),
                refusalCount=1, duplicateAdditionalWrites=0, maximumHistoryLevels=12, maximumHistoryBytes=524_288,
                historyLevels=1, historyBytes=len(C.INITIAL.encode()))
            for field in C.TEXT_FLAGS.split(): text[field] = True
            renames = [dict(kind=kind, id=text_id if kind=='text' else image_id,
                           beforeTitle='文字便笺' if kind=='text' else '图片参考', afterTitle='文字已命名 🧪' if kind=='text' else '图片已命名 🖼️',
                           callbacks=1, refusalCount=1, duplicateAdditionalWrites=0, cancelPreserved=True, refusalPreserved=True,
                           sameSheetOnRepeat=True, contentPresentationUnchanged=True) for kind in ('text','image')]
            a,b,c = uid(100),group_id,uid(101)
            order = dict(activeGroupID=b, selectedPinIDs=[image_id], states=[[a,b,c],[b,a,c],[b,a,c],[a,b,c],[a,c,b],[a,c,b]],
                menuEvents=[], callbacks=3, entriesUnchanged=True, selectionPreserved=True, pickerOrder=[a,c,b], minimumWindowSize=[680,600],
                rowSelection=dict(requestedRow=1, selectedRowAfter=1, eventType=1, windowNumber=100, ownedWindowIsKey=True,
                                  sameQuartzTimestamp=True, expectedQuartzTimestamp=12345, dequeuedQuartzTimestamp=12345,
                                  dispatchRoute='owned-nextEvent-sendEvent', targetPointVisible=True))
            for direction,boundary in [('earlier',False),('earlier',True),('later',False),('later',False),('later',True)]:
                order['menuEvents'].append(dict(itemID='pin-group-order-'+direction, boundary=boundary, enabled=not boundary,
                    opened=True, closed=True, activated=not boundary, postedKeyCount=1 if boundary else 3, timeoutSeconds=2,
                    windowNumber=100, dispatchRoute='owned-mouseDown/native-menu-tracking', disabledDismissedWithEscape=boundary))
            self.r['flows'].append(dict(appearance=mode,text=text,renames=renames,order=order))
            for name,control in C.ACTION_PAIRS:
                self.r['actions'].append(dict(appearance=mode,action=name,controlID=control,windowNumber=100,
                    route='PortableSettingsUIPreviewFixture.click/owned-hitTest-mouseDown',hitTest=True))
            for category in C.CATEGORIES:
                width,height = {'draft':(460,352),'text-rename':(420,176),'image-rename':(420,176),'order':(680,578)}[category]
                ids = {'draft':['pin.textEdit.undo','pin.textEdit.redo','pin.textEdit.cancel','pin.textEdit.save'],
                       'text-rename':['pin.rename.name','pin.rename.cancel','pin.rename.save'],
                       'image-rename':['pin.rename.name','pin.rename.cancel','pin.rename.save'],
                       'order':['pin-group-picker','pin-group-order','pin-group-move-pin']}[category]
                v = dict(category=category,appearance=mode,file=f'pin-management-{category}-{mode}.png',pixelWidth=width,pixelHeight=height,
                    contentBounds=[0,0,width,height],windowFrame=[100,100,width,600 if category=='order' else height+22],visibleFrame=[0,0,1440,900],
                    controls=[dict(id=value,frame=[16+i*100,20,90,24],minimumSize=[75,20],hitTest=True) for i,value in enumerate(ids)],
                    fullVisibleFramesChecked=True,controlsDoNotOverlap=True,opaqueWindowBackgroundComposited=True,text={})
                if category=='draft': v['text'] = dict(text=C.SAVED,viewportFrame=[16,65,428,210],usedTextHeight=60,viewportHeight=208,fullTextFits=True)
                self.r['visuals'].append(v); self.replace(v['file'],OLD.png(width,height,32+mode_index*50))
            for stage,value,seed in [('before',C.INITIAL,20),('after',C.SAVED,80)]:
                data = json.dumps(dict(kind='text',text=dict(runs=[dict(text=value,bold=False,italic=False,code=False)],importedHTML=False)),ensure_ascii=False).encode()
                name=f'pin-management-text-{stage}-{mode}.json'; self.replace(name,data); text[stage+'DataSHA256']=self.r['fileSHA256'][name]
                name=f'pin-management-poster-{stage}-{mode}.png'; self.replace(name,OLD.png(480,280,seed)); text[stage+'PosterSHA256']=self.r['fileSHA256'][name]

    def replace(self,name,data):
        (self.root/name).write_bytes(data); self.r['fileSHA256'][name]=hashlib.sha256(data).hexdigest()

    def check(self):
        C.validate(self.r,expected_commit='source',expected_version='0.21',expected_build='192',installed_app=self.app,evidence_directory=self.root)

    def reject(self,mutation,decode=False):
        prior=copy.deepcopy(self.r); mutation(self.r)
        with mock.patch.object(C.P.PNG,'png_rgba',wraps=C.P.PNG.png_rgba) as decoder:
            with self.assertRaises((ValueError,KeyError,TypeError)): self.check()
            if not decode: decoder.assert_not_called()
        self.r=prior

    def test_accept_complete_contract_and_canonical_bundle_alias(self):
        alias=self.root/'alias.app'; alias.symlink_to(self.app); self.r['bundlePath']=str(alias)
        with mock.patch.object(C.P.PNG,'png_rgba',wraps=C.P.PNG.png_rgba) as decoder:
            self.check(); self.assertEqual(decoder.call_count,12)

    def test_every_dictionary_rejects_unknown_and_missing_fields(self):
        paths=[]
        def walk(value,path=()):
            if isinstance(value,dict):
                paths.append(path)
                for key,child in value.items(): walk(child,path+(key,))
            elif isinstance(value,list):
                for index,child in enumerate(value): walk(child,path+(index,))
        walk(self.r)
        for path in paths:
            def lookup(r):
                for key in path: r=r[key]
                return r
            with self.subTest(path=path,change='unknown'): self.reject(lambda r:lookup(r).update(unrecognized=True))
            if lookup(self.r):
                key=next(iter(lookup(self.r)))
                with self.subTest(path=path,change='missing'): self.reject(lambda r:lookup(r).pop(key))

    def test_reject_identity_and_binary_tampering(self):
        for key,value in [('sourceCommit','old'),('version','0.20'),('buildVersion','191'),('executableSHA256','0'*64),('infoPlistSHA256','0'*64)]:
            self.reject(lambda r:r.update({key:value}))
        self.executable.write_bytes(b'changed binary')
        with self.assertRaisesRegex(ValueError,'executable hash'): self.check()

    def test_reject_scope_budget_and_lifecycle_mutations(self):
        mutations=[lambda r:r.update(elapsedSeconds=float('nan')),lambda r:r.update(elapsedSeconds=120),lambda r:r.update(globalInputPosted=True),
                   lambda r:r.update(memoryStabilityAssessed=True),lambda r:r['ownership'].update(controllerCount=55),
                   lambda r:r['ownership'].update(retainedWindows=1),lambda r:r['resourceCycles'].update(measuredCycles=9),
                   lambda r:r['resourceCycles']['rows'][4].update(action='text-cancel'),lambda r:r['resourceCycles']['rows'][1].update(callbacks=0),
                   lambda r:r['resourceCycles']['rows'][3].update(releasedContentViews=1),lambda r:r['checks'].pop()]
        for mutation in mutations:self.reject(mutation)

    def test_reject_text_identity_and_preservation_mutations(self):
        for mode in range(2):
            for key in C.TEXT_FLAGS.split():self.reject(lambda r:r['flows'][mode]['text'].update({key:False}))
            for key,value in [('savedText',C.SAVED.replace('\n',' ')),('historyLevels',13),('historyBytes',524289),('maximumHistoryBytes',1048576),
                              ('duplicateAdditionalWrites',1),('refusalCount',0),('id',uid(999)),('beforeDataSHA256','0'*64),('afterPosterSHA256','0'*64)]:
                self.reject(lambda r:r['flows'][mode]['text'].update({key:value}))
            self.reject(lambda r:r['flows'][mode]['text']['afterIdentity'].update(presentationSHA256='b'*64))
            self.reject(lambda r:r['flows'][mode]['renames'][0].update(callbacks=2))
            self.reject(lambda r:r['flows'][mode]['renames'][1].update(contentPresentationUnchanged=False))

    def test_reject_native_action_and_event_forgery(self):
        for mutation in [lambda r:r['actions'][0].update(route='performClick'),lambda r:r['actions'][1].update(controlID='pin.textEdit.save'),
                         lambda r:r['actions'][0].update(windowNumber=True),lambda r:r['actions'][0].update(hitTest=False),
                         lambda r:r['flows'][0]['order']['rowSelection'].update(dequeuedQuartzTimestamp=12346),
                         lambda r:r['flows'][0]['order']['rowSelection'].update(eventType=10),
                         lambda r:r['flows'][0]['order']['rowSelection'].update(ownedWindowIsKey=False),
                         lambda r:r['flows'][0]['order']['menuEvents'][1].update(activated=True),
                         lambda r:r['flows'][0]['order']['menuEvents'][0].update(dispatchRoute='sendAction'),
                         lambda r:r['flows'][0]['order']['menuEvents'][0].update(postedKeyCount=41)]:self.reject(mutation)

    def test_reject_group_order_selection_and_boundary_tampering(self):
        for mutation in [lambda r:r['flows'][0]['order']['states'][1].reverse(),lambda r:r['flows'][0]['order'].update(callbacks=4),
                         lambda r:r['flows'][0]['order'].update(selectionPreserved=False),lambda r:r['flows'][0]['order'].update(activeGroupID=uid(999)),
                         lambda r:r['flows'][0]['order']['pickerOrder'].reverse(),lambda r:r['flows'][0]['order'].update(minimumWindowSize=[780,640]),
                         lambda r:r['flows'][0]['order']['menuEvents'][4].update(enabled=True)]:self.reject(mutation)

    def test_reject_geometry_hit_fit_and_text_clipping(self):
        for mutation in [lambda r:r['visuals'][0]['controls'][0].update(frame=[-5,20,90,24]),
                         lambda r:r['visuals'][0]['controls'][1].update(frame=r['visuals'][0]['controls'][0]['frame']),
                         lambda r:r['visuals'][0]['controls'][0].update(hitTest=False),
                         lambda r:r['visuals'][0]['controls'][0].update(minimumSize=[200,24]),
                         lambda r:r['visuals'][0]['text'].update(usedTextHeight=400),
                         lambda r:r['visuals'][3].update(windowFrame=[100,100,780,640]),
                         lambda r:r['visuals'][0].update(pixelWidth=4000),lambda r:r['visuals'].pop()]:self.reject(mutation)

    def test_reject_missing_changed_or_outside_evidence(self):
        name='pin-management-draft-light.png'; path=self.root/name
        original=path.read_bytes();path.write_bytes(original+b'tamper')
        with self.assertRaisesRegex(ValueError,'SHA256'):self.check()
        path.unlink()
        with self.assertRaises((ValueError,FileNotFoundError)):self.check()
        outside=self.root.parent/(self.root.name+'-outside.png')
        outside.write_bytes(original);self.addCleanup(outside.unlink);path.symlink_to(outside)
        with self.assertRaisesRegex(ValueError,'escaped'):self.check()

    def test_reject_json_flattening_unknown_fields_and_duplicate_fields(self):
        name='pin-management-text-after-light.json';original=(self.root/name).read_bytes()
        for content in [original.replace(b'"importedHTML": false',b'"importedHTML": true'),
                        original.replace(b'"bold": false',b'"bold": true'),
                        original[:-1]+b',"extra":1}',original[:-1]+b',"kind":"text"}']:
            self.replace(name,content);self.r['flows'][0]['text']['afterDataSHA256']=self.r['fileSHA256'][name]
            with mock.patch.object(C.P.PNG,'png_rgba',wraps=C.P.PNG.png_rgba) as decoder:
                with self.assertRaises(ValueError):self.check()
                decoder.assert_not_called()

    def test_reject_raster_bombs_before_decoding(self):
        name='pin-management-draft-light.png';data=bytearray((self.root/name).read_bytes());data[16:20]=(4_000_001).to_bytes(4,'big')
        self.replace(name,bytes(data))
        with mock.patch.object(C.P.PNG,'png_rgba',wraps=C.P.PNG.png_rgba) as decoder:
            with self.assertRaisesRegex(ValueError,'raster bound'):self.check()
            decoder.assert_not_called()

    def test_reject_blank_transparent_or_identical_appearance_pixels(self):
        name='pin-management-draft-light.png';self.replace(name,OLD.png(460,352,32,alpha=0))
        with self.assertRaisesRegex(ValueError,'transparent'):self.check()
        self.replace(name,OLD.png(460,352,82))
        with self.assertRaisesRegex(ValueError,'light/dark'):self.check()

    def test_reject_duplicate_json_report_keys(self):
        with self.assertRaisesRegex(ValueError,'duplicate JSON'):json.loads('{"status":"passed","status":"passed"}',object_pairs_hook=C.P.unique_object)


if __name__=='__main__':unittest.main()
