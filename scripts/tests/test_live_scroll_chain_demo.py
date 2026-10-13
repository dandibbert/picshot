"""Portable adversarial reader inputs. Never evidence of installed native execution."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

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

def artifacts(phase):
    result=[]
    for mode,pixels in [('light',T.LIGHT_PIXELS),('dark',T.DARK_PIXELS)]:
        controls=[]
        for index,name in enumerate(sorted(C.PHASES[phase])):
            kind='NSTextField' if name.endswith('status') or 'receipt-' in name else 'NSPopUpButton' if name.endswith('choice') else 'NSButton'
            row=T.control(name,index,kind)
            row['identifierIsExplicit']=True
            if name=='scroll.live.more':row['class']='LiveScrollMoreButton'
            controls.append(row)
        result.append(dict(filename='scroll-chain-'+phase+'-'+mode+'.png',appearance=mode,rendering=C.C.RENDERING,
            width=600,height=300,canonicalRGBAPixelSHA256=pixels,layout=dict(passed=True,phase='scroll-chain-'+phase,
                windowTitle='Owned synthetic alert',windowVisible=True,windowNumber=12,nativeControlCount=len(controls),
                windowFrame=T.rect(20,20,600,322),visibleScreenFrame=T.rect(0,0,1200,900),
                contentBounds=T.rect(0,0,600,300),violations=[],fullNativeFramesMeasured=True,
                alignmentRectanglesSubstituted=False,fullVisibleFramesChecked=True,controlsDoNotOverlap=True,controls=controls)))
    return result


def report():
    path=f'/private/tmp/PicShot-LiveChain-{UUID}/saved/owned-live-chain-1.png'
    save=dict(output='quickSavePNG',savedURL=path,byteCount=len(PNG))
    case=dict(status='passed',viewportOffsets=C.OFFSETS,definitionOutputs=C.OUTPUTS,
        viewportTrace=[dict(offset=offset,height=320+offset,acceptedObservations=i+1) for i,offset in enumerate(C.OFFSETS)],
        pausedStatus='已完成 1/3；继续不会重复',replacementWarning=path+' 再次执行',abandonWarning=path+' 仍保留',
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
    for phase in C.PHASES:case[phase+'Artifacts']=artifacts(phase)
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
            (root/artifact['filename']).write_bytes(T.LIGHT_PNG if artifact['appearance']=='light' else T.DARK_PNG)
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
