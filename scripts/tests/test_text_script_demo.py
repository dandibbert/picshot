"""Mutation inputs for the portable reader. Never native macOS proof."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value)
    return value

C = load('text_script_demo', SCRIPTS/'check-text-script-demo.py')
T = load('chain_test_inputs', SCRIPTS/'tests/test_capture_chain_demo.py')
SOURCE = 'a'*40
IDS = ['A1111111-2222-3333-4444-555555555555', 'B1111111-2222-3333-4444-555555555555',
       'C1111111-2222-3333-4444-555555555555', 'D1111111-2222-3333-4444-555555555555']
sha, dump, rect = T.sha, T.dump, T.rect
SOURCE_PNG, SOURCE_HASH = T.png(900, 300)
LIGHT_PNG, LIGHT_HASH = T.png(600, 600, (240, 240, 240, 255))
DARK_PNG, DARK_HASH = T.png(600, 600, (30, 30, 30, 255))


def metrics(request):
    return dict(requestID=request, outcome='succeeded', childLaunched=True, childPID=200,
        childExitConfirmed=True, pipesDrained=True, admissionReleased=True, terminationStatus=0,
        terminationReason='exit', terminateSent=False, killSent=False, elapsedSeconds=.2,
        launchSeconds=.01, requestSentSeconds=.03, exitObservedSeconds=.1, acceptedSeconds=.11,
        sampledPeakResidentBytes=20*1024**2, residentSamples=2, residentObservationFailures=0,
        maximumResidentSampleGapSeconds=.06, stdinBytes=6000, stdoutBytes=150, stderrBytes=0,
        discardedResponseBytes=150, retainedResponseBytesAfterFinish=0, responseIdentityMatched=True,
        pipeDescriptorsCloseOnExec=True, parentEndpointsNonblocking=True, inputSuppressesSIGPIPE=True,
        signature=dict(appIdentifier='local.picshot.app', helperIdentifier='com.picshot.TextScriptHelper',
            helperCDHash='c'*40, helperEntitlements=['com.apple.security.app-sandbox'], appAndHelperStrictlyValidated=True),
        acceptanceDeadlineSeconds=3, rssLimitBytes=256*1024**2, rssSampleIntervalSeconds=.05,
        terminateGraceSeconds=.25, killedObservationSeconds=.75, observationScope=C.RSS_SCOPE)


def control(identifier, index, kind='button'):
    y = 10+index*35
    row = dict(id=identifier, **{'class': {'button':'NSButton', 'field':'NSTextField',
        'source':'TextScriptBoundedTextView', 'table':'NSTableView'}[kind]}, kind=kind,
        viewPath=[index+1], ancestorIDs=[], ownerWindowNumber=12, owned=True,
        fullFrame=rect(12,y,500,30), screenFrame=rect(32,y+20,500,30), hidden=False,
        enabled=True, insideViewport=True, text='固定文字', tooltip='固定文字', accessibilityValue='固定文字', accessibilityLabel='固定文字')
    if kind in ('button','field'):
        row.update(contained=True,cellSize=[100,20],wrappedSize=[100,20],textFits=True)
    if kind=='button': row['hitTest']=True
    if kind=='field':
        row.update(wraps=False,editableScrollable=False,alignmentWidth=480,nameAlternative=False,
                   truncates=True,accessibleAlternative=True,fontSize=12)
    if identifier=='text-script-name':
        row.update(text=C.NAME,tooltip=C.NAME,accessibilityValue=C.NAME,cellSize=[1500,20],
                   textFits=False,editableScrollable=True,nameAlternative=True)
    if kind=='source':
        row.update(text=C.SOURCE_BODY,tooltip='',accessibilityValue=C.SOURCE_BODY,insideViewport=False,
            fullFrame=rect(12,y,500,1200),screenFrame=rect(32,y+20,500,1200),viewport=rect(12,y,500,150),
            usedTextRect=rect(0,0,470,1100),textContainerWidth=484,textInset=[8,8],wraps=True,
            verticalScroll=True,editableSelectable=True,fontSize=12,completeSourceAccessible=True)
    return row


def artifacts(phase):
    if phase=='text-script-editor':
        ids = [('text-script-create','button'),('text-script-save','button'),('text-script-close','button'),
               ('text-script-run','button'),('text-script-name','field'),('text-script-list','table'),('text-script-source','source')]
    else:
        ids = [('capture-chain-close','button'),('capture-chain-run-status','field'),
               ('capture-chain-receipt-0','field'),('capture-chain-status','field'),('capture-chain-guidance','field')]
        if phase.endswith('-failure'): ids.append(('capture-chain-retry','button'))
    rows=[control(i,j,k) for j,(i,k) in enumerate(ids)]
    if phase != 'text-script-editor':
        rows[1]['text'] = C.NAME + (' · 操作未完成：无法将文字写入剪贴板，请重试。' if phase.endswith('-failure') else ' · 全部完成')
        rows[2]['text'] = '复制失败；重试只复制已准备好的文字，不会重新截图、识别或执行脚本。' if phase.endswith('-failure') else '已复制文字到剪贴板（15 个字符）'
    for row in rows:
        if row['kind'] == 'field': row.update(tooltip=row['text'],accessibilityValue=row['text'],accessibilityLabel=row['text'])
    return [dict(filename=phase+'-'+mode+'.png',appearance=mode,width=600,height=600,
        canonicalRGBAPixelSHA256=pixel_hash,layout=dict(phase=phase,passed=True,windowVisible=True,
            violations=[],fullNativeFramesMeasured=True,alignmentRectanglesSubstituted=False,
            windowNumber=12,windowFrame=rect(20,20,600,622),screenFrame=rect(0,0,1200,900),
            contentBounds=rect(0,0,600,600),controls=copy.deepcopy(rows)))
        for mode,pixel_hash in [('light',LIGHT_HASH),('dark',DARK_HASH)]]


def case(retry):
    name='retry' if retry else 'close'
    request=IDS[2 if retry else 3]
    row=dict(status='passed',case=name,actionRoute=C.ROUTE,copyRejectionInjectedAtCheckedWriter=True,
        appInitialized=True,nativeSaveControlIdentifier='text-script-save',nativeSourceInsertion=True,
        savedDefinitionReloaded=True,runControlIdentifier='text-script-run',failureCode='clipboardRejected',
        failurePhase='copy',failedRetainedTextBytes=len(C.EXPECTED.encode()),failedImageReleased=True,
        failureReceiptCount=0,rejectedPasteboardEmpty=True,closeControlIdentifier='capture-chain-close',
        catalogDefinitionsOnly=True,editorHiddenDuringCapture=True,progressHiddenDuringCapture=True,
        historyHiddenDuringCapture=True,noEditorHistoryOrPinOutput=True,finalRetainedBytes=0,
        finalRetainedTextBytes=0,terminalStatus='completed' if retry else 'cancelled',
        editorCloseControlIdentifier='text-script-close',recognitionTruncated=False,cleanupSafe=True,
        visionJobsDrained=True,helperAdmissionDrained=True,privatePasteboardReleased=True,isolatedDefaultsRemoved=True,
        committedReceiptCount=1 if retry else 0,definitionID=IDS[0 if retry else 1],requestID=request,
        failureAttempts=dict(capture=1,ocr=1,transform=1,copy=1,committedCopy=0),
        attempts=dict(capture=1,ocr=1,transform=1,copy=2 if retry else 1,committedCopy=1 if retry else 0),
        catalogBeforeSHA256='b'*64,catalogAfterSHA256='b'*64,generatedActualOCR='ABC-123\nXYZ-987\nABC-123',
        helperMetrics=[metrics(request)],rowSelection=T.selection(),failureArtifacts=artifacts('text-script-'+name+'-failure'))
    if retry:
        row.update(retryControlIdentifier='capture-chain-retry',generatedActualOutput=C.EXPECTED,
            receiptCharacterCount=len(C.EXPECTED),copiedTextSHA256=sha(C.EXPECTED.encode()),copiedTextBytes=len(C.EXPECTED.encode()),
            editorArtifacts=artifacts('text-script-editor'),resultArtifacts=artifacts('text-script-result'))
    else: row['privatePasteboardEmptyAfterClose']=True
    return row


def report():
    return dict(schemaVersion=1,status='passed',sourceCommit=SOURCE,scope=C.SCOPE,limitations=C.LIMITATIONS.copy(),
        installerAcceptance=False,original227MemoryAcceptance=False,hardMemoryCapClaimed=False,realScreenCaptureClaimed=False,
        screenCaptureAPICalled=False,permissionRequested=False,networkUsed=False,globalInputPosted=False,userHistoryReadOrWritten=False,
        standardDefaultsReadOrWritten=False,generalPasteboardReadOrWritten=False,runtimeGateBuild=False,transportFixtureUsed=False,
        generatedExpectedOutput=C.EXPECTED,productAppDelegateExercised=True,realAppleVisionRan=True,productionHelperRan=True,
        canonicalPrivateTemporaryRoot=True,ownershipReleased=True,privateTemporaryRootRemoved=True,finalVisionActiveJobs=0,
        finalVisionWaitingJobs=0,finalHelperAdmissionOccupied=False,cleanupSafe=True,elapsedSeconds=10.,
        successOwnershipReleased={key:True for key in C.OWNERS},closeOwnershipReleased={key:True for key in C.OWNERS},
        sourceReference=dict(width=900,height=300,canonicalRGBAPixelSHA256=SOURCE_HASH),copyRetry=case(True),closeAfterFailure=case(False))


def fixture(root):
    # Our already-created TemporaryDirectory may use macOS /var aliases.
    # Construct every synthetic identity from its physical owned root.
    root = Path(root).resolve(strict=True)
    app=root/'PicShot.app'; executable=app/'Contents/MacOS/PicShot'; helper=app/'Contents/Helpers/PicShotTextScriptHelper'
    executable.parent.mkdir(parents=True); helper.parent.mkdir(parents=True)
    executable.write_bytes(b'portable-app-placeholder-not-native-proof');helper.write_bytes(b'portable-helper-placeholder-not-native-proof')
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(PicShotSourceCommit=SOURCE,CFBundleVersion='255',
        CFBundleShortVersionString='0.23.0',CFBundleExecutable='PicShot',CFBundleIdentifier='local.picshot.app')))
    dump(app/'Contents/Resources/build-info.json',dict(app='PicShot',sourceCommit=SOURCE,version='0.23.0',architecture='arm64'))
    evidence=root/'evidence';evidence.mkdir();value=report()
    for name,key in [('retry','copyRetry'),('close','closeAfterFailure')]:
        catalog=dict(version=1,selectedID=value[key]['definitionID'],definitions=[dict(id=value[key]['definitionID'],name=C.NAME,source=C.SOURCE_BODY)])
        filename='text-script-'+name+'-catalog.json';dump(evidence/filename,catalog)
        value[key]['catalogBeforeSHA256']=value[key]['catalogAfterSHA256']=sha((evidence/filename).read_bytes())
        dump(evidence/('text-script-'+name+'-case.json'),value[key])
        for artifact_key in (('editorArtifacts','failureArtifacts','resultArtifacts') if name=='retry' else ('failureArtifacts',)):
            for artifact in value[key][artifact_key]:
                filename=artifact['filename'];(evidence/filename).write_bytes(LIGHT_PNG if artifact['appearance']=='light' else DARK_PNG)
                dump(evidence/(filename[:-4]+'-layout.json'),artifact)
    dump(evidence/'text-script-demo.json',value)
    value.update(historyDirectoryRemoved=True,independentValidationRequired=True,bundlePath=str(app),
        executablePath=str(executable),arguments=[str(executable)],build='255',version='0.23.0')
    dump(evidence/'installed.json',value)
    dump(evidence/'installed.json.launcher.json',dict(schemaVersion=1,status='exited',launcherExitCode=0,
        callbackReceived=True,createsNewApplicationInstance=True,ownedExitConfirmed=True,launchedIdentityMatches=True,
        textScriptDiagnosticOnly=True,captureChainDiagnosticOnly=False,liveScrollDiagnosticOnly=False,earlyWitnessOnly=False,
        processStartMemoryCaptured=False,timeoutSeconds=240,selectedAppPath=str(app),launchedAppPath=str(app),
        expectedExecutablePath=str(executable),launchedExecutablePath=str(executable),processIdentifier=100,elapsedSeconds=11.))
    (evidence/'text-script-source.png').write_bytes(SOURCE_PNG);(evidence/'text-script-copied.txt').write_text(C.EXPECTED)
    source_root=root/'source';source_root.mkdir()
    source_paths=['Sources/PicShotTextScriptHelper/TextScriptHelperMain.swift','Sources/PicShotTextScriptHelper/TextScriptEngine.swift',
        'Sources/PicShotTextScriptProcess/TextScriptProcessService.swift','Sources/PicShot/AppMain.swift','Sources/PicShot/SmokeVerification.swift',
        'Sources/PicShot/CaptureChainRunner.swift','Sources/PicShot/CaptureChainTextRuntime.swift','Sources/PicShot/CaptureChainController.swift',
        'Sources/PicShot/TextScriptController.swift','Sources/PicShot/TextScriptStore.swift','Sources/PicShot/TextScriptUIPreviewFixture.swift',
        'Sources/PicShotCore/TextScriptDefinition.swift','scripts/check-text-script-demo.py',
        'scripts/text-script-helper-Info.plist','scripts/text-script-helper.entitlements']
    sources=[]
    for filename in source_paths:
        path=source_root/filename;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(b'portable source inventory input')
        if filename.endswith('helper-Info.plist'):path.write_bytes(plistlib.dumps(C.HELPER_PLIST))
        if filename.endswith('helper.entitlements'):path.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True}))
        sources.append(dict(path=filename,bytes=path.stat().st_size,sha256=sha(path.read_bytes())))
    proof=dict(scope=C.PACKAGE_SCOPE,embeddedInfoPlistSHA256=sha((source_root/'scripts/text-script-helper-Info.plist').read_bytes()),
        entitlementsSourceSHA256=sha((source_root/'scripts/text-script-helper.entitlements').read_bytes()),schemaVersion=1,sourceCommit=SOURCE,version='0.23.0',build='255',architectures=['arm64'],appIdentifier='local.picshot.app',
        appCDHash='d'*40,appTeamIdentifier=None,appSignatureVerified=True,sameTeamIdentifierVerified=True,
        helperEntitlementsVerifiedAfterOuterSigning=True,helperSignedInfoPlistVerifiedAfterOuterSigning=True,
        relocationVerified=True,installedRuntimeAcceptanceVerified=False,executableSHA256=sha(executable.read_bytes()),
        appInfoPlistSHA256=sha((app/'Contents/Info.plist').read_bytes()),buildInfoSHA256=sha((app/'Contents/Resources/build-info.json').read_bytes()),
        helper=dict(path='Contents/Helpers/PicShotTextScriptHelper',identifier='com.picshot.TextScriptHelper',teamIdentifier=None,
            cdHash='c'*40,sha256=sha(helper.read_bytes()),bytes=helper.stat().st_size,entitlements={'com.apple.security.app-sandbox':True},
            signedInfoPlist=C.HELPER_PLIST.copy(),
            linkedLibraries=['/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/JavaScriptCore'],strictSignatureVerified=True),sources=sources)
    proof_path=root/'text-script-package-proof.json';dump(proof_path,proof)
    return evidence/'installed.json',proof_path,source_root


class SchemaMutations(unittest.TestCase):
    def test_complete_generated_schema(self): C.report_fields(report(),SOURCE)

    def test_every_required_top_level_field(self):
        original=report()
        for key in original:
            changed=copy.deepcopy(original);del changed[key]
            with self.subTest(key=key),self.assertRaises(ValueError):C.report_fields(changed,SOURCE)

    def test_every_required_case_field(self):
        original=report()
        for case_name in ('copyRetry','closeAfterFailure'):
            for key in original[case_name]:
                changed=copy.deepcopy(original);del changed[case_name][key]
                with self.subTest(case=case_name,key=key),self.assertRaises(ValueError):C.report_fields(changed,SOURCE)

    def test_every_metric_and_signature_field_required(self):
        for key in metrics(IDS[2]):
            changed=metrics(IDS[2]);del changed[key]
            with self.subTest(key=key),self.assertRaises(ValueError):C.metrics(changed,IDS[2])
        for key in metrics(IDS[2])['signature']:
            changed=metrics(IDS[2]);del changed['signature'][key]
            with self.subTest(signature=key),self.assertRaises(ValueError):C.metrics(changed,IDS[2])

    def test_boolean_type_and_success_flags(self):
        original=report()
        for key,value in original.items():
            if type(value) in (bool,int):
                for bad in (int(value) if type(value) is bool else True, not value if type(value) is bool else value+1):
                    changed=copy.deepcopy(original);changed[key]=bad
                    with self.subTest(key=key,bad=bad),self.assertRaises(ValueError):C.report_fields(changed,SOURCE)
        for name in ('copyRetry','closeAfterFailure'):
            for group in ('attempts','failureAttempts'):
                for key in original[name][group]:
                    changed=copy.deepcopy(original);changed[name][group][key]+=1
                    with self.subTest(name=name,group=group,key=key),self.assertRaises(ValueError):C.report_fields(changed,SOURCE)

    def test_cleanup_ownership_and_retained_output(self):
        for group in ('successOwnershipReleased','closeOwnershipReleased'):
            for key in C.OWNERS:
                changed=report();changed[group][key]=False
                with self.subTest(group=group,key=key),self.assertRaises(ValueError):C.report_fields(changed,SOURCE)
        for key,bad in [('finalRetainedBytes',1),('finalRetainedTextBytes',1),('failedRetainedTextBytes',0),
                        ('failureReceiptCount',1),('committedReceiptCount',2),('recognitionTruncated',True),
                        ('generatedActualOutput','ABC-123'),('generatedActualOCR','fixture not recognized')]:
            changed=report();changed['copyRetry'][key]=bad
            with self.subTest(key=key),self.assertRaises(ValueError):C.report_fields(changed,SOURCE)

    def test_helper_security_protocol_deadline_and_fixed_payloads(self):
        mutations=[('outcome','helperRejected'),('childExitConfirmed',False),('admissionReleased',False),
            ('pipesDrained',False),('responseIdentityMatched',False),('sampledPeakResidentBytes',256*1024**2+1),
            ('residentSamples',0),('residentObservationFailures',1),('acceptedSeconds',3.1),('stderrBytes',1),
            ('retainedResponseBytesAfterFinish',1),('requestID',IDS[3]),('rssLimitBytes',512*1024**2),
            ('observationScope','hard memory cap'),('pipeDescriptorsCloseOnExec',False),('inputSuppressesSIGPIPE',False)]
        for key,bad in mutations:
            changed=metrics(IDS[2]);changed[key]=bad
            with self.subTest(key=key),self.assertRaises(ValueError):C.metrics(changed,IDS[2])
        for payload in ('source','text','stderr','exception','output','cleanupSeconds'):
            changed=metrics(IDS[2]);changed[payload]='arbitrary payload'
            with self.subTest(payload=payload),self.assertRaises(ValueError):C.metrics(changed,IDS[2])
        changed=metrics(IDS[2]);changed['signature']['helperEntitlements'].append('com.apple.security.network.client')
        with self.assertRaises(ValueError):C.metrics(changed,IDS[2])

    def test_layout_geometry_and_native_ownership_mutations(self):
        for mutation in ('offscreen','clipped','overlap','missing','duplicate','wrong-class','foreign-window','forged-path','forged-parent','hidden','hit-test'):
            value=artifacts('text-script-retry-failure')[0];layout=value['layout'];rows=layout['controls']
            if mutation=='offscreen':layout['windowFrame']['x']=1199
            elif mutation=='clipped':rows[0]['fullFrame']['x']=599
            elif mutation=='overlap':rows[1]['fullFrame']=copy.deepcopy(rows[0]['fullFrame'])
            elif mutation=='missing':rows.pop(0)
            elif mutation=='duplicate':rows.append(copy.deepcopy(rows[0]))
            elif mutation=='wrong-class':rows[0]['class']='NSTextField'
            elif mutation=='foreign-window':rows[0]['ownerWindowNumber']=99
            elif mutation=='forged-path':rows[1]['viewPath']=rows[0]['viewPath']
            elif mutation=='forged-parent':rows[0]['ancestorIDs']=[rows[1]['id']]
            elif mutation=='hidden':rows[0]['hidden']=True
            else:rows[0]['hitTest']=False
            with self.subTest(mutation=mutation),self.assertRaises(ValueError):C.layout(value,'text-script-retry-failure')

    def test_native_popup_subclass_keeps_hidden_ownership_and_title_ancestry_checks(self):
        value=artifacts('text-script-retry-failure')[0]
        rows=value['layout']['controls']
        popup=control('capture-chain-source',6)
        popup.update(**{'class':'NSPopUpButton'},hidden=True)
        child=control('native-999',7,'field')
        child.update(**{'class':'NSButtonTextField'},hidden=True,
            viewPath=popup['viewPath']+[0],ancestorIDs=[popup['id']])
        rows.extend([popup,child])
        C.layout(value,'text-script-retry-failure')
        for mutation in ('unknown-class','wrong-kind','foreign-window','unowned','missing-path',
                         'duplicate-path','forged-parent','title-mismatch'):
            changed=copy.deepcopy(value);controls=changed['layout']['controls']
            target=controls[-2]
            if mutation=='unknown-class':target['class']='NSUnreviewedButton'
            elif mutation=='wrong-kind':target['kind']='field'
            elif mutation=='foreign-window':target['ownerWindowNumber']=99
            elif mutation=='unowned':target['owned']=False
            elif mutation=='missing-path':del target['viewPath']
            elif mutation=='duplicate-path':target['viewPath']=controls[0]['viewPath']
            elif mutation=='forged-parent':controls[-1]['ancestorIDs']=[]
            else:controls[-1]['text']='unrelated title'
            with self.subTest(mutation=mutation),self.assertRaises(ValueError):
                C.layout(changed,'text-script-retry-failure')
        # A visible instance still needs complete geometry and a real hit target.
        rows.pop();popup['hidden']=False
        C.layout(value,'text-script-retry-failure')
        popup['hitTest']=False
        with self.assertRaises(ValueError):C.layout(value,'text-script-retry-failure')

    def test_long_name_and_source_remain_usable(self):
        for key,bad in [('wraps',False),('verticalScroll',False),('completeSourceAccessible',False),
                        ('editableSelectable',False),('accessibilityValue','truncated'),('fontSize',10)]:
            value=artifacts('text-script-editor')[0];value['layout']['controls'][-1][key]=bad
            with self.subTest(key=key),self.assertRaises(ValueError):C.layout(value,'text-script-editor')
        for key,bad in [('editableScrollable',False),('alignmentWidth',200),('tooltip','truncated'),('nameAlternative',False)]:
            value=artifacts('text-script-editor')[0];value['layout']['controls'][4][key]=bad
            with self.subTest(key=key),self.assertRaises(ValueError):C.layout(value,'text-script-editor')
        value=artifacts('text-script-editor')[0];value['layout']['controls'][-1]['usedTextRect']['width']=1000
        with self.assertRaises(ValueError):C.layout(value,'text-script-editor')

    def test_fixture_has_only_production_paths_and_fixed_failure_codes(self):
        source=(SCRIPTS.parent/'Sources/PicShot/TextScriptUIPreviewFixture.swift').read_text()
        for token in ('RecognitionService.recognize(image','CaptureChainTextRuntime(onMetrics:',
                      'CheckedTextClipboard.copy(text, pasteboard: board','PortableSettingsUIPreviewFixture.click(retryButton)',
                      'PortableSettingsUIPreviewFixture.click(close)','TextScriptStore(directory: scripts.directory)',
                      'first.allReleased','second.allReleased','fixedCode(error)'):
            self.assertIn(token,source)
        for forbidden in ('pasteboard: .general','TextScriptNativeGateOptions','transportMode:',
                          'error.localizedDescription','NSPasteboard.general','UserDefaults.standard'):
            self.assertNotIn(forbidden,source)


class FileBindingMutations(unittest.TestCase):
    def test_complete_fixture_is_checker_input_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            report_path,proof,source_root=fixture(Path(temporary))
            result=C.validate(report_path,SOURCE,proof,source_root)
            self.assertEqual(result['status'],'passed');self.assertFalse(result['installerAcceptance'])
            self.assertFalse(result['original227MemoryAcceptance']);self.assertFalse(result['hardMemoryCapClaimed'])

    def test_owned_temporary_alias_resolves_but_checker_rejects_aliased_app_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary).resolve(strict=True)
            physical=root/'physical';physical.mkdir()
            alias=root/'temporary-alias';alias.symlink_to(physical,target_is_directory=True)
            report_path,proof,source_root=fixture(alias)
            for path in (report_path,proof,source_root):
                self.assertEqual(path,path.resolve(strict=True))
                self.assertTrue(path.is_relative_to(physical))
            self.assertEqual(C.validate(report_path,SOURCE,proof,source_root)['status'],'passed')
            smoke=json.loads(report_path.read_text())
            smoke['bundlePath']=str(alias/'PicShot.app')
            dump(report_path,smoke)
            with self.assertRaisesRegex(ValueError,'wrong or symlinked app'):
                C.validate(report_path,SOURCE,proof,source_root)

    def test_every_physical_evidence_file_is_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            report_path,proof,source_root=fixture(Path(temporary));files=list(report_path.parent.iterdir())
            for path in files:
                original=path.read_bytes();path.unlink()
                with self.subTest(file=path.name),self.assertRaises(ValueError):C.validate(report_path,SOURCE,proof,source_root)
                path.write_bytes(original)

    def test_current_app_helper_and_source_tampering(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);report_path,proof,source_root=fixture(root)
            targets=[root/'PicShot.app/Contents/MacOS/PicShot',root/'PicShot.app/Contents/Helpers/PicShotTextScriptHelper',
                     source_root/'Sources/PicShot/AppMain.swift',source_root/'Sources/PicShot/TextScriptUIPreviewFixture.swift']
            for target in targets:
                original=target.read_bytes();target.write_bytes(original+b'changed')
                with self.subTest(path=target),self.assertRaises(ValueError):C.validate(report_path,SOURCE,proof,source_root)
                target.write_bytes(original)

    def test_final_signature_entitlement_and_source_inventory_binding(self):
        with tempfile.TemporaryDirectory() as temporary:
            report_path,proof_path,source_root=fixture(Path(temporary));original=json.loads(proof_path.read_text())
            for mutation in ('helper-cdhash','app-hash','extra-entitlement','missing-source','source-hash','signature-false','gate','wrong-commit','int-entitlement','plist-hash','plist-extra','helper-link'):
                changed=copy.deepcopy(original)
                if mutation=='helper-cdhash':changed['helper']['cdHash']='e'*40
                elif mutation=='app-hash':changed['executableSHA256']='e'*64
                elif mutation=='extra-entitlement':changed['helper']['entitlements']['com.apple.security.network.client']=True
                elif mutation=='missing-source':changed['sources']=[row for row in changed['sources'] if row['path']!='Sources/PicShot/AppMain.swift']
                elif mutation=='source-hash':changed['sources'][0]['sha256']='e'*64
                elif mutation=='signature-false':changed['helper']['strictSignatureVerified']=False
                elif mutation=='wrong-commit':changed['sourceCommit']='e'*40
                elif mutation=='int-entitlement':changed['helper']['entitlements']['com.apple.security.app-sandbox']=1
                elif mutation=='plist-hash':changed['embeddedInfoPlistSHA256']='e'*64
                elif mutation=='plist-extra':changed['helper']['signedInfoPlist']['unexpected']='value'
                elif mutation=='helper-link':changed['helper']['linkedLibraries']=['/tmp/unsigned.dylib']
                else:(Path(temporary)/'PicShot.app/Contents/Helpers/PicShotTextScriptGate').write_bytes(b'gate')
                dump(proof_path,changed)
                with self.subTest(mutation=mutation),self.assertRaises(ValueError):C.validate(report_path,SOURCE,proof_path,source_root)
                if mutation=='gate':(Path(temporary)/'PicShot.app/Contents/Helpers/PicShotTextScriptGate').unlink()
            dump(proof_path,original)

    def test_every_package_and_helper_proof_field_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            report_path,proof_path,source_root=fixture(Path(temporary));original=json.loads(proof_path.read_text())
            for key in original:
                changed=copy.deepcopy(original);del changed[key];dump(proof_path,changed)
                with self.subTest(key=key),self.assertRaises(ValueError):C.validate(report_path,SOURCE,proof_path,source_root)
            for key in original['helper']:
                changed=copy.deepcopy(original);del changed['helper'][key];dump(proof_path,changed)
                with self.subTest(helper=key),self.assertRaises(ValueError):C.validate(report_path,SOURCE,proof_path,source_root)

    def test_catalog_runtime_injection_and_physical_output_mutation(self):
        with tempfile.TemporaryDirectory() as temporary:
            report_path,proof,source_root=fixture(Path(temporary));root=report_path.parent
            for name in ('text-script-copied.txt','text-script-retry-catalog.json','text-script-source.png',
                         'text-script-retry-case.json','text-script-editor-light-layout.json','text-script-result-dark.png'):
                path=root/name;original=path.read_bytes();path.write_bytes(original+b'corrupt')
                with self.subTest(file=name),self.assertRaises((ValueError,json.JSONDecodeError)):C.validate(report_path,SOURCE,proof,source_root)
                path.write_bytes(original)

    def test_raw_smoke_and_launcher_identity_cannot_diverge(self):
        with tempfile.TemporaryDirectory() as temporary:
            report_path,proof,source_root=fixture(Path(temporary));launch_path=report_path.with_name(report_path.name+'.launcher.json')
            original=json.loads(launch_path.read_text())
            for key,bad in [('textScriptDiagnosticOnly',False),('ownedExitConfirmed',False),('timeoutSeconds',45),
                            ('launchedExecutablePath','/wrong/PicShot'),('earlyWitnessOnly',True)]:
                changed=copy.deepcopy(original);changed[key]=bad;dump(launch_path,changed)
                with self.subTest(key=key),self.assertRaises(ValueError):C.validate(report_path,SOURCE,proof,source_root)
            dump(launch_path,original)
            raw_path=report_path.parent/'text-script-demo.json';raw=json.loads(raw_path.read_text());raw['elapsedSeconds']=11.
            dump(raw_path,raw)
            with self.assertRaisesRegex(ValueError,'raw and smoke'):C.validate(report_path,SOURCE,proof,source_root)


if __name__=='__main__':unittest.main()
