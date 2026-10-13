"""Portable adversarial reader inputs. Never evidence of installed native execution."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import struct
import sys
import tempfile
import unittest
import zlib

SCRIPTS=Path(__file__).resolve().parents[1]

def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value

C=module('live_scroll_chain_reader',SCRIPTS/'check-live-scroll-chain-demo.py')
T=module('capture_chain_reader_inputs',SCRIPTS/'tests/test_capture_chain_demo.py')
SOURCE='a'*40
UUID='A1111111-2222-3333-4444-555555555555'
RUN2='B1111111-2222-3333-4444-555555555555'
PNG,PIXELS=T.png(480,704)
SHEET_LIGHT_PNG,SHEET_LIGHT_PIXELS=T.png(460,300,(240,240,240,255))
SHEET_DARK_PNG,SHEET_DARK_PIXELS=T.png(460,300,(30,30,30,255))
RETAINED=Path(__file__).with_name('fixtures')/'live-scroll-chain-retained271'

def artifacts(phase):
    result=[]
    sheet=phase in ('choice','replacement','abandon')
    width=460 if sheet else 600
    for mode,pixels in [('light',SHEET_LIGHT_PIXELS if sheet else T.LIGHT_PIXELS),
                        ('dark',SHEET_DARK_PIXELS if sheet else T.DARK_PIXELS)]:
        controls=[]
        for index,name in enumerate(sorted(C.PHASES[phase])):
            kind=('NSTextField' if name.endswith(('status','.name','.outputs','.title','.description','.warning')) or 'receipt-' in name
                  else 'NSPopUpButton' if name.endswith('choice') else 'NSButton')
            row=T.control(name,index,kind)
            row['identifierIsExplicit']=True
            if name=='scroll.live.more':
                row.update(**{'class':'LiveScrollMoreButton'},text='',untruncatedCellSize=[74,25],
                    requiredTextSizeAtActualWidth=[34,25],titleFits=False,
                    fullFrame=T.rect(12,10,34,34),fullScreenFrame=T.rect(32,30,34,34),
                    accessibilityLabel='更多滚动截图选项',toolTip='移动选区 · 方向 · 导入 · 帮助',
                    moreIconPullsDown=True,moreIconImagePosition='imageOnly',moreIconArrowPosition='noArrow',
                    moreIconImageScaling='scaleNone',moreIconAnchorPresent=True,moreIconAnchorTitle='',
                    moreIconDisplayedItemIsAnchor=True,moreIconImagePresent=True,moreIconFits=True,
                    moreIconNativeBounds=T.rect(0,0,34,34),moreIconImageSize=[18,4],
                    moreIconImageRect=T.rect(8,15,18,4))
            controls.append(row)
        result.append(dict(filename='scroll-chain-'+phase+'-'+mode+'.png',appearance=mode,rendering=C.C.RENDERING,
            width=width,height=300,canonicalRGBAPixelSHA256=pixels,layout=dict(passed=True,phase='scroll-chain-'+phase,
                windowTitle='Owned synthetic alert',windowVisible=True,windowNumber=12,nativeControlCount=len(controls),
                windowFrame=T.rect(20,20,width,322),visibleScreenFrame=T.rect(0,0,1200,900),
                contentBounds=T.rect(0,0,width,300),violations=[],fullNativeFramesMeasured=True,
                alignmentRectanglesSubstituted=False,fullVisibleFramesChecked=True,controlsDoNotOverlap=True,controls=controls)))
    return result


def report():
    path=f'/private/tmp/PicShot-LiveChain-{UUID}/saved/owned-live-chain-1.png'
    save=dict(output='quickSavePNG',savedURL=path,byteCount=len(PNG))
    case=dict(status='passed',viewportOffsets=C.OFFSETS,definitionOutputs=C.OUTPUTS,
        viewportTrace=[dict(offset=offset,height=320+offset,acceptedObservations=i+1) for i,offset in enumerate(C.OFFSETS)],
        pausedStatus='已完成 1/3；继续不会重复',replacementWarning=C.REPLACEMENT_WARNING+'\n\n'+path,
        abandonWarning=C.ABANDON_WARNING+'\n\n'+path,replacementDetails=path,abandonDetails=path,
        replacementConsequence=C.REPLACEMENT_WARNING,abandonConsequence=C.ABANDON_WARNING,
        noOutputOnSelectionOrChoiceCancel=True,noOutputOnReplacementOrAbandonCancel=True,noOutputOnManage=True,
        oneFrozenImageAcrossAttempts=True,renderCount=1,pausedDraftRetained=True,pausedMutationControlsDisabled=True,
        saveDrainedBeforeCancel=True,savedFileCount=1,savedPNGUnchanged=True,pinEntryCount=1,reloadedPinEntryCount=1,
        pinOriginalAndCurrentShareOneAsset=True,visibleNativePinCount=1,catalogDefinitionsOnly=True,
        noEditorHistoryOrTransientPinOutput=True,saveJobsDrained=True,privatePasteboardReleased=True,isolatedDefaultsRemoved=True,
        spoolDirectoryEmpty=True,productSessionClosed=True,cleanupSafe=True,terminalStatus='completed',finalRetainedBytes=0,
        failureAttempts=dict(capture=0,save=1,saveAdmissions=1,copy=1,pin=0),
        attempts=dict(capture=0,save=1,saveAdmissions=1,copy=2,pin=1),firstRunID=UUID,continuedRunID=RUN2,
        revisionID=UUID,continuedRevisionID=UUID,transactionID=UUID,continuedTransactionID=UUID,
        savedPath=path,savedPNGByteCount=len(PNG),pinID=UUID,failureReceipts=[copy.deepcopy(save)],pausedReceipts=[copy.deepcopy(save)],
        receipts=[save,dict(output='copy',checkedPrivatePasteboard=True),dict(output='pin',pinID=UUID)],
        savedPNGFileSHA256=T.sha(PNG),copiedPNGFileSHA256=T.sha(PNG),pinPNGFileSHA256=T.sha(PNG),reloadedPinPNGFileSHA256=T.sha(PNG),
        catalogBeforeSHA256='b'*64,catalogAfterSHA256='b'*64)
    comparison=dict(passed=True,dimensionsMatch=True,exactCanonicalRGBAEquality=True,width=480,height=704,
        expectedWidth=480,expectedHeight=704,outputPixelSHA256=PIXELS,sourcePixelSHA256=PIXELS,method=C.C.COMPARISON)
    for key in ('savedPNGComparison','copiedPNGComparison','publishedPinComparison','reloadedPinComparison'):case[key]=copy.deepcopy(comparison)
    case['actionTrace']=[dict(index=i,action=action,identifier=identifier,
        route='NSApp.sendAction on production More menu item' if action.startswith('more-') else
            'NSPopUpButton.selectItem; no output command' if action.startswith('select-') else
            'PortableSettingsUIPreviewFixture.click: owned NSButton.mouseDown with queued mouseUp')
        for i,(action,identifier) in enumerate(zip(C.ACTIONS,C.IDS))]
    for phase in C.PHASES:
        case[phase+'Artifacts']=artifacts(phase)
        if phase not in ('choice','replacement','abandon'):continue
        title={'choice':'使用截图链处理当前长图','replacement':'选择其他动作链重新处理','abandon':'放弃未完成操作并继续采集？'}[phase]
        description=('来源：本次长截图。仅执行所选链的图片输出，按保存的顺序处理。' if phase=='choice'
                     else case['replacementDetails'] if phase=='replacement' else case['abandonDetails'])
        texts={'scroll.live.imageChain.sheet.title':title,'scroll.live.imageChain.sheet.description':description,
               'scroll.live.imageChain.choice.name':C.CHAIN_NAME,'scroll.live.imageChain.choice.outputs':C.OUTPUT_TITLE}
        if phase!='choice':texts['scroll.live.imageChain.sheet.warning']=case[phase+'Consequence']
        for artifact in case[phase+'Artifacts']:
            for row in artifact['layout']['controls']:
                if row['id'] in texts:
                    text=texts[row['id']]
                    row.update(text=text,toolTip=text,accessibilityLabel=text,accessibilityValue=text,textSelectable=True,textWraps=True)
                    if row['id'].endswith('.description'):
                        row.update(textWraps=False,lineBreakMode=4,maximumNumberOfLines=9)
                    if row['id'].endswith('.warning'):
                        row.update(lineBreakMode=0,maximumNumberOfLines=0)
                if row['id']=='scroll.live.imageChain.choice':
                    row.update(toolTip=C.CHAIN_NAME+' · '+C.OUTPUT_TITLE,accessibilityValue=C.CHAIN_NAME+' · '+C.OUTPUT_TITLE)
    return dict(schemaVersion=1,status='passed',sourceCommit=SOURCE,source=C.SOURCE,acquisition=C.ACQUISITION,
        installerAcceptance=False,realScreenCaptureClaimed=False,screenCaptureAPICalled=False,permissionRequested=False,
        globalInputPosted=False,networkUsed=False,userHistoryReadOrWritten=False,standardDefaultsReadOrWritten=False,
        generalPasteboardReadOrWritten=False,productAppDelegateExercised=True,productSessionControllerExercised=True,
        productSaveWorkflowDeliveryExercised=True,productPersistentPinExercised=True,canonicalPrivateTemporaryRoot=True,
        cleanupSafe=True,productSessionClosed=True,privateTemporaryRootRemoved=True,ownershipReleased=True,limitations=C.LIMITATIONS,
        elapsedSeconds=5.0,ownership={key:True for key in C.OWNERS},sourceReference=dict(width=480,height=704,canonicalRGBAPixelSHA256=PIXELS),
        saveFailCancelContinue=case)


def fixture(root):
    value=report(); case=value['saveFailCancelContinue']
    for name in ('owned-numbered','saved','copied','pin','pin-reloaded'):(root/f'scroll-chain-{name}.png').write_bytes(PNG)
    T.dump(root/'scroll-chain-catalog.json',dict(version=1,selectedID=UUID,
        definitions=[dict(id=UUID,name='编号长图 · 保存、复制、贴图',source={'kind':'region'},outputs=C.OUTPUTS)]))
    case['catalogBeforeSHA256']=case['catalogAfterSHA256']=T.sha((root/'scroll-chain-catalog.json').read_bytes())
    T.dump(root/'scroll-chain-actions.json',{key:case[key] for key in ('actionTrace','failureReceipts','pausedReceipts','receipts')})
    for phase in C.PHASES:
        for artifact in case[phase+'Artifacts']:
            light,dark=(SHEET_LIGHT_PNG,SHEET_DARK_PNG) if artifact['width']==460 else (T.LIGHT_PNG,T.DARK_PNG)
            (root/artifact['filename']).write_bytes(light if artifact['appearance']=='light' else dark)
            T.dump(root/(artifact['filename'][:-4]+'-layout.json'),artifact)
    path=root/'live-scroll-chain.json';T.dump(path,value);return path


class ContractTests(unittest.TestCase):
    def test_complete_contract(self):C.contract(report(),SOURCE)

    def test_identity_counts_privacy_receipts_and_cleanup_mutations_fail(self):
        mutations=[('capture',lambda r:r['saveFailCancelContinue']['attempts'].update(capture=1)),
            ('repeat-save',lambda r:r['saveFailCancelContinue']['attempts'].update(save=2)),
            ('repeat-render',lambda r:r['saveFailCancelContinue'].update(renderCount=2)),
            ('run-reuse',lambda r:r['saveFailCancelContinue'].update(continuedRunID=UUID)),
            ('revision-change',lambda r:r['saveFailCancelContinue'].update(continuedRevisionID=RUN2)),
            ('transaction-change',lambda r:r['saveFailCancelContinue'].update(continuedTransactionID=RUN2)),
            ('lost-prefix',lambda r:r['saveFailCancelContinue'].update(pausedReceipts=[])),
            ('foreign-path',lambda r:r['saveFailCancelContinue'].update(savedPath='/tmp/foreign.png')),
            ('clipboard-claim',lambda r:r.update(generalPasteboardReadOrWritten=True)),
            ('real-sck-claim',lambda r:r.update(realScreenCaptureClaimed=True)),
            ('missing-owner',lambda r:r['ownership'].pop('frozenImage')),
            ('retained-owner',lambda r:r['ownership'].update(session=False)),
            ('spool-retained',lambda r:r['saveFailCancelContinue'].update(spoolDirectoryEmpty=False)),
            ('boolean-counter',lambda r:r['saveFailCancelContinue']['attempts'].update(save=True)),
            ('action-reordered',lambda r:r['saveFailCancelContinue']['actionTrace'].reverse()),
            ('bypassed-control',lambda r:r['saveFailCancelContinue']['actionTrace'][4].update(route='direct-method')),
            ('budget-expansion',lambda r:r.update(elapsedSeconds=60.01)),
            ('selection-ran',lambda r:r['saveFailCancelContinue'].update(noOutputOnSelectionOrChoiceCancel=False))]
        for name,mutate in mutations:
            value=report();mutate(value)
            with self.subTest(name=name),self.assertRaises(ValueError):C.contract(value,SOURCE)

    def test_every_case_observation_is_required(self):
        original=report()
        for key in original['saveFailCancelContinue']:
            value=copy.deepcopy(original);del value['saveFailCancelContinue'][key]
            with self.subTest(key=key),self.assertRaises(ValueError):C.contract(value,SOURCE)

    def test_every_required_top_field_is_required(self):
        original=report()
        for key in original:
            value=copy.deepcopy(original);del value[key]
            with self.subTest(key=key),self.assertRaises(ValueError):C.contract(value,SOURCE)

    def test_native_geometry_hit_text_and_ancestry_mutations_fail(self):
        mutations=[lambda x:x['layout']['controls'][0].update(hitTest=False),
            lambda x:x['layout']['controls'][0]['fullFrame'].update(x=599),
            lambda x:x['layout']['controls'][0].update(parentControlID='foreign'),
            lambda x:x['layout']['controls'][0].update(ownerWindowNumber=42),
            lambda x:x['layout']['controls'][0].update(identifierIsExplicit=False),
            lambda x:x['layout']['controls'][1].update(viewPath=x['layout']['controls'][0]['viewPath']),
            lambda x:x['layout']['controls'][1].update(fullFrame=x['layout']['controls'][0]['fullFrame']),
            lambda x:x['layout']['controls'][0].update(titleFits=False,untruncatedCellSize=[999,20]),
            lambda x:x.update(width=599),lambda x:x['layout'].update(fullNativeFramesMeasured=False)]
        for index,mutate in enumerate(mutations):
            value=artifacts('choice')[0];mutate(value)
            with self.subTest(index=index),self.assertRaises(ValueError):C.layout(value,'choice')

    def test_retained269_popup_metrics_and_full_button_overlap_remain_rejected(self):
        # Actual269 light-layout SHA256:
        # 02cdc70355ecb0a13e682985dfb62e5c73854da2aa4f661f8978c2fd82aed579
        # Reuse only those raw full-frame/cell measurements in portable inputs;
        # these constructed rows are not native acceptance evidence.
        value=artifacts('choice')[0]
        controls={row['id']:row for row in value['layout']['controls']}
        popup=controls['scroll.live.imageChain.choice']
        popup.update(fullFrame=T.rect(16,60,420,28),fullScreenFrame=T.rect(36,80,420,28),
                     untruncatedCellSize=[452,25],requiredTextSizeAtActualWidth=[442,25],titleFits=False)
        with self.assertRaisesRegex(ValueError,'button title clipped'):C.layout(value,'choice')
        # The visible bezels had a gap; the native full frames overlap four points.
        frames=[('scroll.live.imageChain.choice.cancel',(106,10,122,40)),
                ('scroll.live.imageChain.run',(224,10,122,40))]
        with self.assertRaisesRegex(ValueError,'full controls overlap'):
            C.C.check_control_overlap(frames,{name:set() for name,_ in frames})

    def test_owned_sheet_full_name_order_and_warning_cannot_be_replaced_by_short_popup(self):
        for phase,identifier in [('choice','scroll.live.imageChain.choice.name'),
                                 ('choice','scroll.live.imageChain.choice.outputs'),
                                 ('replacement','scroll.live.imageChain.sheet.description'),
                                 ('abandon','scroll.live.imageChain.sheet.description')]:
            value=report()
            row=next(row for row in value['saveFailCancelContinue'][phase+'Artifacts'][0]['layout']['controls']
                     if row['id']==identifier)
            row.update(text='Incomplete',toolTip='Incomplete',accessibilityLabel='Incomplete',accessibilityValue='Incomplete')
            with self.subTest(phase=phase,identifier=identifier),self.assertRaises(ValueError):C.contract(value,SOURCE)

    def test_more_icon_requires_exact_owned_control_and_public_visible_image_facts(self):
        artifact=artifacts('paused')[0]
        C.layout(artifact,'paused')
        valid=artifact['layout']['controls'][0]
        self.assertEqual(valid['untruncatedCellSize'],[74,25]);self.assertFalse(valid['titleFits'])
        mutations=[('class','NSPopUpButton'),('class','UnknownButton'),('controlKind','textField'),
            ('id','scroll.live.other'),('identifierIsExplicit',False),('parentControlID','foreign'),
            ('controlAncestorIDs',['foreign']),('enabled',False),('hidden',True),('hitTest',False),
            ('insideScrollableViewport',False),('text','Hidden title'),('accessibilityLabel',''),('toolTip',''),
            ('moreIconPullsDown',False),('moreIconImagePosition','imageLeading'),('moreIconArrowPosition','arrowAtBottom'),
            ('moreIconImageScaling','scaleProportionallyDown'),('moreIconAnchorPresent',False),('moreIconAnchorTitle','Other'),
            ('moreIconDisplayedItemIsAnchor',False),('moreIconImagePresent',False),('moreIconFits',False),
            ('moreIconImageSize',[0,4]),('moreIconImageSize',[18,float('nan')]),('moreIconImageSize',[35,4]),
            ('moreIconImageRect',T.rect(8,15,0,4)),('moreIconImageRect',T.rect(30,15,18,4)),
            ('moreIconImageRect',T.rect(8,15,17,4)),('moreIconImageRect',T.rect(float('inf'),15,18,4)),
            ('moreIconNativeBounds',T.rect(0,0,35,34)),('fullFrame',T.rect(599,10,34,34))]
        for key,bad in mutations:
            changed=copy.deepcopy(artifact);changed['layout']['controls'][0][key]=bad
            with self.subTest(key=key,bad=bad),self.assertRaises(ValueError):C.layout(changed,'paused')
        for key in [key for key in valid if key.startswith('moreIcon')]:
            changed=copy.deepcopy(artifact);del changed['layout']['controls'][0][key]
            with self.subTest(missing=key),self.assertRaises(ValueError):C.layout(changed,'paused')

    def test_consequence_warning_must_be_visible_complete_and_above_bounded_details(self):
        identifier='scroll.live.imageChain.sheet.warning'
        mutations=[('hidden',True),('textFits',False),('intentionalTruncation',True),('textWraps',False),
            ('lineBreakMode',4),('maximumNumberOfLines',2),('text','...'),('toolTip','...'),
            ('accessibilityLabel','...'),('accessibilityValue','...'),('insideScrollableViewport',False),
            ('fullFrame',T.rect(12,290,320,30)),('requiredTextSizeAtActualWidth',[100,31])]
        for phase in ('replacement','abandon'):
            for key,bad in mutations:
                value=report();artifact=value['saveFailCancelContinue'][phase+'Artifacts'][0]
                row=next(row for row in artifact['layout']['controls'] if row['id']==identifier);row[key]=bad
                with self.subTest(phase=phase,key=key),self.assertRaises(ValueError):C.contract(value,SOURCE)
            value=report();artifact=value['saveFailCancelContinue'][phase+'Artifacts'][0]
            artifact['layout']['controls']=[row for row in artifact['layout']['controls'] if row['id']!=identifier]
            artifact['layout']['nativeControlCount']-=1
            with self.subTest(phase=phase,missing=True),self.assertRaises(ValueError):C.contract(value,SOURCE)
            value=report();case=value['saveFailCancelContinue'];artifact=case[phase+'Artifacts'][0]
            controls={row['id']:row for row in artifact['layout']['controls']}
            controls[identifier]['fullFrame']=T.rect(12,0,320,30)
            with self.subTest(phase=phase,below=True),self.assertRaises(ValueError):C.sheet_content(artifact,controls,phase,case)
        value=report();case=value['saveFailCancelContinue'];artifact=case['choiceArtifacts'][0]
        controls=C.layout(artifact,'choice');controls[identifier]={'hidden':True}
        with self.assertRaisesRegex(ValueError,'redundant consequence'):C.sheet_content(artifact,controls,'choice',case)

    def test_retained271_description_and_concrete_toolbar_ancestry(self):
        artifact=C.C.COMMON.load(RETAINED/'scroll-chain-choice-light-layout.json')
        controls=C.layout(artifact,'choice');C.sheet_content(artifact,controls,'choice',{})
        description=controls['scroll.live.imageChain.sheet.description']
        self.assertFalse(description['textWraps']);self.assertEqual(description['maximumNumberOfLines'],9)
        for identifier,key,bad in [('scroll.live.imageChain.sheet.description','lineBreakMode',2),
                ('scroll.live.imageChain.sheet.description','maximumNumberOfLines',0),
                ('scroll.live.imageChain.sheet.description','textWraps',True),
                ('scroll.live.imageChain.sheet.description','toolTip','...'),
                ('scroll.live.imageChain.sheet.description','accessibilityValue','...'),
                ('scroll.live.imageChain.choice.name','textWraps',False)]:
            changed=copy.deepcopy(controls);changed[identifier][key]=bad
            with self.subTest(identifier=identifier,key=key),self.assertRaises(ValueError):C.sheet_content(artifact,changed,'choice',{})
        raw=C.C.COMMON.load(RETAINED/'scroll-chain-paused-light-layout.json')
        rows=raw['layout']['controls'];number=raw['layout']['windowNumber']
        C.ancestry(rows,number)
        index=next(i for i,row in enumerate(rows) if row['class']=='LiveScrollButton')
        for key,bad in [('class','UnknownLiveScrollButton'),('controlKind','textField'),
                        ('parentControlID','scroll.live.more'),('identifierIsExplicit',False)]:
            changed=copy.deepcopy(rows);changed[index][key]=bad
            with self.subTest(key=key),self.assertRaises(ValueError):C.ancestry(changed,number)
        # Historical paused evidence lacks the new public icon measurements and
        # remains failed; it cannot become a current successful layout retroactively.
        with self.assertRaises(ValueError):C.layout(raw,'paused')


class NativeAlphaTests(unittest.TestCase):
    def test_retained271_full_alpha_normalization_exactly_matches_both_native_hashes(self):
        provenance=C.C.COMMON.load(RETAINED/'provenance.json')
        for name,digest in provenance['files'].items():
            self.assertEqual(T.sha((RETAINED/name).read_bytes()),digest)
        for mode in ('light','dark'):
            artifact=provenance[mode];raw=(RETAINED/artifact['filename']).read_bytes()
            pixels=C.check_ui_artifact(raw,artifact)
            self.assertEqual(pixels[:2],(310,82))
            self.assertEqual(sum(alpha!=255 for alpha in pixels[2][3::4]),820)
            with self.assertRaisesRegex(ValueError,'not opaque'):C.C.decoded_png(raw,'delivered output')

    def test_retained_ui_corruption_alpha_and_identity_mutations_fail(self):
        provenance=C.C.COMMON.load(RETAINED/'provenance.json');artifact=provenance['light']
        raw=(RETAINED/artifact['filename']).read_bytes()
        for damaged in (raw[:20],raw[:-1],raw+b'x',raw[:60]+bytes([raw[60]^1])+raw[61:]):
            with self.subTest(size=len(damaged)),self.assertRaises(ValueError):C.check_ui_artifact(damaged,artifact)
        width,height,original=C.C.PNG.png_rgba(raw);pixels=bytearray(original)
        offset=next(i for i in range(3,len(pixels),4) if pixels[i]<255);pixels[offset]+=1
        scan=b''.join(b'\0'+pixels[y*width*4:(y+1)*width*4] for y in range(height))
        changed=(b'\x89PNG\r\n\x1a\n'+T.chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,6,0,0,0))
                 +T.chunk(b'IDAT',zlib.compress(scan))+T.chunk(b'IEND',b''))
        with self.assertRaisesRegex(ValueError,'raster/layout differs'):C.check_ui_artifact(changed,artifact)
        for key,bad in [('width',311),('canonicalRGBAPixelSHA256','0'*64)]:
            wrong=dict(artifact);wrong[key]=bad
            with self.subTest(key=key),self.assertRaises(ValueError):C.check_ui_artifact(raw,wrong)
        huge=(b'\x89PNG\r\n\x1a\n'+T.chunk(b'IHDR',struct.pack('>IIBBBBB',4096,4096,8,6,0,0,0))+T.chunk(b'IEND',b''))
        with self.assertRaisesRegex(ValueError,'raster exceeds bound'):C.native_ui_png(huge,'oversized')


class FileTests(unittest.TestCase):
    def test_full_portable_evidence_and_cli(self):
        with tempfile.TemporaryDirectory() as temp:
            path=fixture(Path(temp));result=C.validate(path,SOURCE)
            self.assertTrue(result['sameRevisionReceiptContinuationVerified'])
            self.assertFalse(result['installerAcceptance']);self.assertFalse(result['realScreenCaptureAcceptance'])
            self.assertEqual(len(result['evidenceSHA256']),32)
            cli=subprocess.run([sys.executable,str(SCRIPTS/'check-live-scroll-chain-demo.py'),'--report',str(path),'--source',SOURCE],
                capture_output=True,text=True,timeout=20)
            self.assertEqual(cli.returncode,0,cli.stderr)
            self.assertEqual(C.C.COMMON.load(path.parent/'live-scroll-chain-receipt.json'),result)

    def test_changed_output_pixels_fail_even_with_updated_digest(self):
        with tempfile.TemporaryDirectory() as temp:
            path=fixture(Path(temp));value=C.C.COMMON.load(path)
            changed=T.png(480,704,(121,140,160,255))[0]
            (path.parent/'scroll-chain-copied.png').write_bytes(changed)
            value['saveFailCancelContinue']['copiedPNGFileSHA256']=T.sha(changed);T.dump(path,value)
            with self.assertRaisesRegex(ValueError,'exact output pixels differ'):C.validate(path,SOURCE)

    def test_raw_trace_layout_and_catalog_cannot_be_replaced_by_pass_flags(self):
        mutations=[('scroll-chain-actions.json',lambda x:x['pausedReceipts'].clear()),
            ('scroll-chain-choice-light-layout.json',lambda x:x['layout']['controls'][0].update(hitTest=False)),
            ('scroll-chain-catalog.json',lambda x:x.update(runtimeReceipt='private'))]
        for filename,mutate in mutations:
            with self.subTest(filename=filename),tempfile.TemporaryDirectory() as temp:
                path=fixture(Path(temp));value=C.C.COMMON.load(path.parent/filename);mutate(value);T.dump(path.parent/filename,value)
                with self.assertRaises(ValueError):C.validate(path,SOURCE)

    def test_missing_symlink_duplicate_nonfinite_and_wrong_source_fail(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);path=fixture(root)
            with self.assertRaises(ValueError):C.validate(path,'b'*40)
            image=root/'scroll-chain-pin.png';image.unlink();image.symlink_to(root/'scroll-chain-saved.png')
            with self.assertRaises(ValueError):C.validate(path,SOURCE)
            for raw in ('{"status":"passed","status":"passed"}','{"x":NaN}'):
                path.write_text(raw)
                with self.assertRaises(ValueError):C.validate(path,SOURCE)

    def test_runtime_payload_in_catalog_rejected_even_with_matching_hashes(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);path=fixture(root);value=C.C.COMMON.load(path)
            catalog=C.C.COMMON.load(root/'scroll-chain-catalog.json');catalog['definitions'][0]['receipts']=[]
            T.dump(root/'scroll-chain-catalog.json',catalog)
            sha=T.sha((root/'scroll-chain-catalog.json').read_bytes())
            value['saveFailCancelContinue'].update(catalogBeforeSHA256=sha,catalogAfterSHA256=sha);T.dump(path,value)
            with self.assertRaisesRegex(ValueError,'runtime payload'):C.validate(path,SOURCE)


if __name__=='__main__':unittest.main()
