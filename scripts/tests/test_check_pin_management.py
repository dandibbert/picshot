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
                    activated=not boundary, postedKeyCount=1 if boundary else 3, timeoutSeconds=2,
                    windowNumber=100, expectedWindowMode='key-window',
                    dispatchRoute='owned-nextEvent-sendEvent/native-menu-tracking', disabledDismissedWithEscape=boundary,
                    mouseDispatch=dict(route='owned-nextEvent-sendEvent', elapsedSeconds=0.005,
                        eventType=1, windowNumber=100, eventNumber=1, clickCount=1, modifierFlags=0,
                        expectedQuartzTimestamp=12345, dequeuedQuartzTimestamp=12345, currentQuartzTimestamp=12345,
                        expectedLocation=[240.5, 420], dequeuedLocation=[240.5, 420], currentLocation=[240.5, 420],
                        currentEventType=1, currentWindowNumber=100, currentEventNumber=1, currentClickCount=1,
                        currentModifierFlags=0, ownedWindowIsKey=True, hitTestVerified=True,
                        expectedWindowMode='key-window', windowModeVerifiedAtDispatch=True,
                        buttonWindowIdentityVerified=True, ownedWindowIsVisible=True, ownedWindowCanBecomeKey=True,
                        ownedWindowIsPanel=False, ownedWindowHasNonactivatingStyle=False),
                    lastPostedKeyCode=53 if boundary else 36, trackingBeginCount=1, trackingEndCount=1,
                    trackingIdentityVerified=True, trackingBeginElapsedSeconds=0.01, trackingEndElapsedSeconds=0.30 if boundary else 0.26,
                    trackingEndedBeforeClickReturn=not boundary, delegateCloseObserved=not boundary,
                    delegateOpenObserved=True, delegateOpenIdentityVerified=True, delegateOpenElapsedSeconds=0.02,
                    delegateCloseIdentityVerified=not boundary, delegateCloseElapsedSeconds=None if boundary else 0.25,
                    clickReturnElapsedSeconds=0.28, lifecycleObservation='exact-root-menu-begin-end-notifications',
                    highlightObservation='exact-owned-menu-current-state', returnHighlightVerified=not boundary,
                    returnHighlightElapsedSeconds=None if boundary else 0.20,
                    returnHighlightedItemID=None if boundary else 'pin-group-order-'+direction,
                    returnTargetEnabled=not boundary, returnTargetHighlighted=not boundary, returnTargetMenuIdentityVerified=not boundary,
                    delegateHighlightEvents=[dict(itemID=None, elapsedSeconds=0.05, ownedMenuIdentityVerified=True),
                                             dict(itemID='pin-group-order-'+direction, elapsedSeconds=0.10, ownedMenuIdentityVerified=True)]))
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
        # A genuine cancellation delegate callback remains valid when observed;
        # the native tracking-end witness is required in either case.
        for flow in self.r['flows']:
            for row in flow['order']['menuEvents']:
                if row['boundary']:
                    row.update(delegateCloseObserved=True, delegateCloseIdentityVerified=True, delegateCloseElapsedSeconds=0.29)
        self.check()
        for flow in self.r['flows']:
            for row in flow['order']['menuEvents']:
                row.update(delegateOpenObserved=False, delegateOpenIdentityVerified=False, delegateOpenElapsedSeconds=None)
        self.check()
        # Current-state Return witnesses work without any highlight delegate
        # callback, including the fourth popup that previously exhausted Down.
        for flow in self.r['flows']:
            for row in flow['order']['menuEvents']:
                row['delegateHighlightEvents'] = []
        self.check()
        # These are about-to-highlight events, not a proxy for current state:
        # null, an earlier/later item other than the Return target, and equal
        # timestamps are all valid. Exercise the inclusive 96-row/time bounds.
        for flow in self.r['flows']:
            for row in flow['order']['menuEvents']:
                opposite = 'pin-group-order-later' if row['itemID'].endswith('earlier') else 'pin-group-order-earlier'
                row['delegateHighlightEvents'] = [dict(itemID=None if index % 2 else opposite,
                    elapsedSeconds=2, ownedMenuIdentityVerified=True) for index in range(96)]
                row.update(trackingEndElapsedSeconds=2, clickReturnElapsedSeconds=2, delegateCloseElapsedSeconds=2)
                if not row['boundary']:
                    row.update(returnHighlightElapsedSeconds=2, postedKeyCount=40)
        self.check()

        # The dispatch witness may equal the tracking-begin timestamp, including
        # the inclusive two-second limit; UInt64 Quartz values remain exact.
        for mode, flow in enumerate(self.r['flows']):
            for row in flow['order']['menuEvents']:
                row['trackingBeginElapsedSeconds'] = 2
                row['mouseDispatch'].update(elapsedSeconds=2,
                    expectedQuartzTimestamp=1 if mode == 0 else 2**64-1,
                    dequeuedQuartzTimestamp=1 if mode == 0 else 2**64-1,
                    currentQuartzTimestamp=1 if mode == 0 else 2**64-1,
                    expectedLocation=[0, -0.5], dequeuedLocation=[0.0, -0.5], currentLocation=[0, -0.5])
        self.check()

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
        # The queued/down/current-event receipt is required on every popup,
        # including both disabled boundaries and both appearance modes.
        for mode in range(2):
            for index in range(5):
                def event(r): return r['flows'][mode]['order']['menuEvents'][index]
                with self.subTest(mode=mode, event=index, missing='mouseDispatch'):
                    self.reject(lambda r:event(r).pop('mouseDispatch'))
                for key in list(event(self.r)['mouseDispatch']):
                    with self.subTest(mode=mode, event=index, missing=key):
                        self.reject(lambda r:event(r)['mouseDispatch'].pop(key))
                self.reject(lambda r:event(r)['mouseDispatch'].update(unrecognized=True))
                self.reject(lambda r:event(r).update(dispatchRoute='owned-mouseDown/native-menu-tracking'))

        def mouse(r): return r['flows'][0]['order']['menuEvents'][0]['mouseDispatch']
        for value in [None, [], (), '', True, 1]:
            self.reject(lambda r:r['flows'][0]['order']['menuEvents'][0].update(mouseDispatch=value))
        for value in [None, True, 1, '', 'owned-mouseDown', 'sendAction', 'owned-nextEvent-sendEvent/native-menu-tracking']:
            self.reject(lambda r:mouse(r).update(route=value))
        for key, foreign in [('eventType', 10), ('currentEventType', 10), ('windowNumber', 101),
                             ('currentWindowNumber', 101), ('eventNumber', 2), ('currentEventNumber', 2),
                             ('clickCount', 2), ('currentClickCount', 2), ('modifierFlags', 1), ('currentModifierFlags', 1)]:
            for value in [None, True, False, 1.0, '1', -1, 2**63, foreign]:
                with self.subTest(mouseField=key, invalid=value):
                    self.reject(lambda r:mouse(r).update({key:value}))
        # Matching but foreign windows/identities cannot hide behind equality.
        for updates in [dict(windowNumber=101, currentWindowNumber=101), dict(eventType=10, currentEventType=10),
                        dict(eventNumber=2, currentEventNumber=2), dict(clickCount=2, currentClickCount=2),
                        dict(modifierFlags=1, currentModifierFlags=1)]:
            self.reject(lambda r:mouse(r).update(updates))
        for key in ['expectedQuartzTimestamp', 'dequeuedQuartzTimestamp', 'currentQuartzTimestamp']:
            for value in [None, True, False, 12345.0, '12345', -1, 0, 2**64, 12346]:
                with self.subTest(mouseField=key, invalid=value):
                    self.reject(lambda r:mouse(r).update({key:value}))
        for value in [None, True, False, 12345.0, '12345', -1, 0, 2**64]:
            self.reject(lambda r:mouse(r).update(expectedQuartzTimestamp=value,
                dequeuedQuartzTimestamp=value, currentQuartzTimestamp=value))
        for key in ['expectedLocation', 'dequeuedLocation', 'currentLocation']:
            for value in [None, True, 1, {}, (), (240.5, 420), '240.5,420', [], [240.5], [240.5, 420, 0],
                          [240.5, 421], [241.5, 420], [True, 420], [240.5, False], ['240.5', 420],
                          [240.5, None], [float('nan'), 420], [240.5, float('inf')], [float('-inf'), 420]]:
                with self.subTest(mouseField=key, invalid=value):
                    self.reject(lambda r:mouse(r).update({key:value}))
        for value in [[True, 420], [240.5, False], ['240.5', 420], [240.5, None],
                      [float('nan'), 420], [240.5, float('inf')], [float('-inf'), 420]]:
            self.reject(lambda r:mouse(r).update(expectedLocation=value, dequeuedLocation=value, currentLocation=value))
        for value in [None, True, False, '0.005', float('nan'), float('inf'), float('-inf'), -0.1, 0, 0.010001, 2.000001]:
            self.reject(lambda r:mouse(r).update(elapsedSeconds=value))
        self.reject(lambda r:r['flows'][0]['order']['menuEvents'][0].update(trackingBeginElapsedSeconds=0.004))
        for key in ['ownedWindowIsKey', 'hitTestVerified']:
            for value in [False, None, 0, 1, 'true']:
                self.reject(lambda r:mouse(r).update({key:value}))
        for key in ['trackingIdentityVerified', 'trackingBeginCount', 'trackingEndCount', 'trackingEndedBeforeClickReturn',
                    'clickReturnElapsedSeconds', 'trackingBeginElapsedSeconds', 'trackingEndElapsedSeconds',
                    'delegateCloseObserved', 'delegateCloseIdentityVerified', 'delegateCloseElapsedSeconds', 'lifecycleObservation', 'lastPostedKeyCode']:
            self.reject(lambda r,key=key:r['flows'][0]['order']['menuEvents'][0].pop(key))
        for key in ['delegateOpenObserved', 'delegateOpenIdentityVerified', 'delegateOpenElapsedSeconds']:
            self.reject(lambda r,key=key:r['flows'][0]['order']['menuEvents'][0].pop(key))
        for mode in range(2):
            for index in range(5):
                for key in ['highlightObservation', 'returnHighlightVerified', 'returnHighlightElapsedSeconds', 'returnHighlightedItemID',
                            'returnTargetEnabled', 'returnTargetHighlighted', 'returnTargetMenuIdentityVerified', 'delegateHighlightEvents']:
                    with self.subTest(mode=mode, event=index, missing=key):
                        self.reject(lambda r:r['flows'][mode]['order']['menuEvents'][index].pop(key))
        for key in ['clickReturnElapsedSeconds', 'trackingBeginElapsedSeconds', 'trackingEndElapsedSeconds', 'delegateCloseElapsedSeconds',
                    'delegateOpenElapsedSeconds', 'returnHighlightElapsedSeconds']:
            for value in [None, True, False, '0.2', float('nan'), float('inf'), float('-inf'), -0.1, 0, 2.000001]:
                self.reject(lambda r,key=key,value=value:r['flows'][0]['order']['menuEvents'][0].update({key:value}))
        for key in ['trackingIdentityVerified', 'delegateCloseIdentityVerified', 'delegateCloseObserved', 'delegateOpenIdentityVerified',
                    'returnHighlightVerified', 'returnTargetEnabled', 'returnTargetHighlighted', 'returnTargetMenuIdentityVerified']:
            for value in [False, None, 0, 1, 'true']:
                self.reject(lambda r,key=key,value=value:r['flows'][0]['order']['menuEvents'][0].update({key:value}))
        for key in ['trackingBeginCount', 'trackingEndCount']:
            for value in [0, 2, True, 1.0, None, '1']:
                self.reject(lambda r,key=key,value=value:r['flows'][0]['order']['menuEvents'][0].update({key:value}))
        for value in [None, 1, 'true']:
            self.reject(lambda r,value=value:r['flows'][0]['order']['menuEvents'][0].update(trackingEndedBeforeClickReturn=value))
            self.reject(lambda r,value=value:r['flows'][0]['order']['menuEvents'][0].update(delegateOpenObserved=value))
        self.reject(lambda r:r['flows'][0]['order']['menuEvents'][0].update(delegateOpenObserved=False))
        for mutation in [lambda r:r['flows'][0]['order']['menuEvents'][0].update(trackingEndedBeforeClickReturn=False),
                         lambda r:r['flows'][0]['order']['menuEvents'][1].update(trackingEndedBeforeClickReturn=True),
                         lambda r:r['flows'][0]['order']['menuEvents'][0].update(trackingBeginElapsedSeconds=0.27),
                         lambda r:r['flows'][0]['order']['menuEvents'][0].update(lastPostedKeyCode=53),
                         lambda r:r['flows'][0]['order']['menuEvents'][1].update(lastPostedKeyCode=36),
                         lambda r:r['flows'][0]['order']['menuEvents'][1].update(postedKeyCount=2),
                         lambda r:r['flows'][0]['order']['menuEvents'][1].update(delegateCloseElapsedSeconds=0.3),
                         lambda r:r['flows'][0]['order']['menuEvents'][1].update(delegateCloseIdentityVerified=True),
                         lambda r:r['flows'][0]['order']['menuEvents'][0].update(lifecycleObservation='mouseDown-return')]:self.reject(mutation)
        for value in [None, True, 1, '', 'delegate-about-to-highlight', 'exact-root-menu-begin-end-notifications']:
            self.reject(lambda r:r['flows'][0]['order']['menuEvents'][0].update(highlightObservation=value))
        for value in [None, True, 1, '', 'pin-group-order-later', 'foreign-menu-item']:
            self.reject(lambda r:r['flows'][0]['order']['menuEvents'][0].update(returnHighlightedItemID=value))
        for key in ['returnHighlightVerified', 'returnTargetEnabled', 'returnTargetHighlighted', 'returnTargetMenuIdentityVerified']:
            for value in [True, None, 0, 1, 'false']:
                self.reject(lambda r:r['flows'][0]['order']['menuEvents'][1].update({key:value}))
        for value in [0.20, 0, False, True, '0.2', float('nan'), float('inf')]:
            self.reject(lambda r:r['flows'][0]['order']['menuEvents'][1].update(returnHighlightElapsedSeconds=value))
        for value in [0.005, 0.255]:
            self.reject(lambda r,value=value:r['flows'][0]['order']['menuEvents'][0].update(returnHighlightElapsedSeconds=value))
        for value in ['pin-group-order-earlier', '', False, 0]:
            self.reject(lambda r:r['flows'][0]['order']['menuEvents'][1].update(returnHighlightedItemID=value))
        # A valid-looking delegate observation cannot replace a missing current
        # Return witness, and an enabled-style witness cannot exist on Escape.
        self.reject(lambda r:r['flows'][0]['order']['menuEvents'][0].update(returnHighlightVerified=False,
            returnHighlightElapsedSeconds=None, returnHighlightedItemID=None, returnTargetEnabled=False,
            returnTargetHighlighted=False, returnTargetMenuIdentityVerified=False))
        self.reject(lambda r:r['flows'][0]['order']['menuEvents'][1].update(returnHighlightVerified=True,
            returnHighlightElapsedSeconds=0.20, returnHighlightedItemID='pin-group-order-earlier', returnTargetEnabled=True,
            returnTargetHighlighted=True, returnTargetMenuIdentityVerified=True))
        for value in [None, {}, (), 'events', True, 96, [None], [[]]]:
            self.reject(lambda r:r['flows'][0]['order']['menuEvents'][0].update(delegateHighlightEvents=value))
        raw = dict(itemID='pin-group-order-earlier', elapsedSeconds=0.10, ownedMenuIdentityVerified=True)
        self.reject(lambda r:r['flows'][0]['order']['menuEvents'][0].update(delegateHighlightEvents=[copy.deepcopy(raw) for _ in range(97)]))
        for key in raw:
            self.reject(lambda r:r['flows'][0]['order']['menuEvents'][0]['delegateHighlightEvents'][0].pop(key))
        self.reject(lambda r:r['flows'][0]['order']['menuEvents'][0]['delegateHighlightEvents'][0].update(unrecognized=True))
        for value in [True, False, 1, {}, [], '', 'foreign-menu-item']:
            self.reject(lambda r:r['flows'][0]['order']['menuEvents'][0]['delegateHighlightEvents'][0].update(itemID=value))
        for value in [None, True, False, '0.2', float('nan'), float('inf'), float('-inf'), -0.1, 0, 2.000001]:
            self.reject(lambda r:r['flows'][0]['order']['menuEvents'][0]['delegateHighlightEvents'][0].update(elapsedSeconds=value))
        for value in [False, None, 0, 1, 'true']:
            self.reject(lambda r:r['flows'][0]['order']['menuEvents'][0]['delegateHighlightEvents'][0].update(ownedMenuIdentityVerified=value))
        self.reject(lambda r:r['flows'][0]['order']['menuEvents'][0]['delegateHighlightEvents'].reverse())
        self.reject(lambda r:r['flows'][0]['order']['menuEvents'][1]['delegateHighlightEvents'].reverse())

    def test_reject_menu_window_mode_schema_and_value_mutations(self):
        # Require the pin-management key-window contract independently at both
        # levels, on every enabled selection and disabled boundary in both modes.
        for mode in range(2):
            for index in range(5):
                def event(r): return r['flows'][mode]['order']['menuEvents'][index]
                for nested in (False, True):
                    def witness(r): return event(r)['mouseDispatch'] if nested else event(r)
                    with self.subTest(mode=mode, event=index, mouse=nested, change='missing'):
                        self.reject(lambda r:witness(r).pop('expectedWindowMode'))
                    with self.subTest(mode=mode, event=index, mouse=nested, change='unknown'):
                        self.reject(lambda r:witness(r).update(unrecognized=True))
                    for value in [None, True, False, 0, 1, [], {}, '', 'KEY-WINDOW',
                                  'key-window ', 'visible-nonactivating-panel']:
                        with self.subTest(mode=mode, event=index, mouse=nested, invalid=value):
                            self.reject(lambda r:witness(r).update(expectedWindowMode=value))
                # Agreement on the shared helper's panel mode is still wrong
                # for this group-order gate; matching labels cannot substitute.
                def panel_mode(r):
                    event(r)['expectedWindowMode'] = 'visible-nonactivating-panel'
                    event(r)['mouseDispatch']['expectedWindowMode'] = 'visible-nonactivating-panel'
                with self.subTest(mode=mode, event=index, change='matching-panel-modes'):
                    self.reject(panel_mode)

    def test_reject_menu_window_state_mutations(self):
        expected = dict(windowModeVerifiedAtDispatch=True, buttonWindowIdentityVerified=True,
                        ownedWindowIsVisible=True, ownedWindowCanBecomeKey=True,
                        ownedWindowIsPanel=False, ownedWindowHasNonactivatingStyle=False)
        for mode in range(2):
            for index in range(5):
                def mouse(r): return r['flows'][mode]['order']['menuEvents'][index]['mouseDispatch']
                for key, required in expected.items():
                    with self.subTest(mode=mode, event=index, missing=key):
                        self.reject(lambda r:mouse(r).pop(key))
                    for value in [not required, None, 0, 1, 0.0, 1.0, 'true', 'false', [], {}]:
                        with self.subTest(mode=mode, event=index, field=key, invalid=value):
                            self.reject(lambda r:mouse(r).update({key:value}))

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
