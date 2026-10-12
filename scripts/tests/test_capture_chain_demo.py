"""Adversarial portable checker inputs, never evidence of native macOS execution."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

SCRIPTS = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('capture_chain_demo', SCRIPTS/'check-capture-chain-demo.py')
C = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(C)
SOURCE = 'a'*40
UUID = 'A1111111-2222-3333-4444-555555555555'


def sha(value):
    return hashlib.sha256(value).hexdigest()


def dump(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, sort_keys=True))


def chunk(kind, payload):
    return struct.pack('>I', len(payload))+kind+payload+struct.pack('>I', zlib.crc32(kind+payload)&0xffffffff)


def png(width, height, rgba=(120, 140, 160, 255)):
    pixels = bytes(rgba)*width*height
    rows = b''.join(b'\0'+pixels[y*width*4:(y+1)*width*4] for y in range(height))
    raw = (b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
           +chunk(b'IDAT', zlib.compress(rows))+chunk(b'IEND', b''))
    return raw, sha(pixels)


SOURCE_PNG, SOURCE_PIXELS = png(480, 320)
LIGHT_PNG, LIGHT_PIXELS = png(600, 300, (240, 240, 240, 255))
DARK_PNG, DARK_PIXELS = png(600, 300, (30, 30, 30, 255))


def rect(x, y, w, h):
    return dict(x=x, y=y, width=w, height=h)


def control(identifier, index, kind='NSButton'):
    x, y = 12, 10+index*35
    value = dict(id=identifier, **{'class': kind}, fullFrame=rect(x, y, 320, 30),
        fullScreenFrame=rect(x+20, y+20, 320, 30), visibleRect=rect(0, 0, 320, 30),
        hidden=False, enabled=True, insideScrollableViewport=True,
        text='完整文本', toolTip='完整文本', accessibilityLabel='完整文本', accessibilityValue='',
        untruncatedCellSize=[100, 20], requiredTextSizeAtActualWidth=[100, 20])
    value.update(controlKind='tableView' if kind == 'NSTableView' else 'textField' if kind == 'NSTextField' else 'button',
        identifierIsExplicit=identifier.startswith('capture-chain-'), viewPath=[index+1],
        ownerWindowNumber=12, descendantOfOwnedContent=True, parentControlID=None, controlAncestorIDs=[])
    if kind != 'NSTableView':
        value['fullFrameContained'] = True
        if kind == 'NSTextField':
            value.update(textFits=True, textWraps=False, intentionalTruncation=False,
                         fullTextTooltipAndAccessibility=True, fontPointSize=12,
                         lineBreakMode=4, maximumNumberOfLines=2,
                         textEditable=False, textSelectable=False, textScrollable=False, inheritedSourceTitleAlternative=False)
        else:
            value.update(hitTest=True, titleFits=True)
    if identifier in ('capture-chain-name', 'capture-chain-source'):
        value.update(alignmentFrame=rect(x, y, 320, 30), accessibilityValue=value['text'])
        if identifier == 'capture-chain-name':
            value.update(textEditable=True, textSelectable=True, textScrollable=True, editableNameLongTextAlternative=True)
        else:
            value.update(selectedItemTitle=value['text'], titleLineBreakMode=4, sourcePopupLongTitleAlternative=True)
    return value


def artifacts(phase):
    ids = [('capture-chain-close', 'NSButton')]
    if phase == 'chain-manager':
        ids += [('capture-chain-run', 'CaptureChainRunButton'), ('capture-chain-list', 'NSTableView'),
                ('capture-chain-name', 'NSTextField'), ('capture-chain-source', 'NSPopUpButton')]
    else:
        ids += [('capture-chain-run-status', 'NSTextField')]
        ids += [(f'capture-chain-receipt-{i}', 'NSTextField') for i in range(3)]
        if 'failure' in phase: ids += [('capture-chain-retry', 'NSButton')]
    result = []
    for mode, pixel_hash in [('light', LIGHT_PIXELS), ('dark', DARK_PIXELS)]:
        result.append(dict(filename=phase+'-'+mode+'.png', appearance=mode, rendering=C.RENDERING,
            width=600, height=300, canonicalRGBAPixelSHA256=pixel_hash,
            layout=dict(passed=True, phase=phase, windowTitle='截图链', windowVisible=True, windowNumber=12, nativeControlCount=len(ids),
                windowFrame=rect(20, 20, 600, 322), visibleScreenFrame=rect(0, 0, 1200, 900),
                contentBounds=rect(0, 0, 600, 300), violations=[], fullNativeFramesMeasured=True,
                alignmentRectanglesSubstituted=False, fullVisibleFramesChecked=True, controlsDoNotOverlap=True,
                controls=[control(identifier, i, kind) for i, (identifier, kind) in enumerate(ids)])))
    return result


def selection():
    event = dict(type=1, windowNumber=12, eventNumber=1, clickCount=1, modifierFlags=0,
                 quartzTimestampNanoseconds=1000000000, timestamp=1., location=[100, 30])
    identity = dict(expected=copy.deepcopy(event), dequeued=copy.deepcopy(event),
                    sameTimestamp=True, sameObject=False, timestampDifference=0.)
    identity.update({key: True for key in ('sameType', 'sameWindow', 'sameQuartzTimestamp', 'sameLocation',
        'sameEventNumber', 'sameClickCount', 'sameModifiers', 'ownedWindowIsKey')})
    row = dict(status='passed-local-row-selection', dispatchRoute='owned-nextEvent-sendEvent',
        requestedRow=0, rowAtDispatch=0, selectedRowAfter=0, ownedDownVerified=True, ownedDownType=1,
        targetPointVisible=True, windowIsKey=True, numberOfRows=1, windowNumber=12,
        ownedDownWindowNumber=12, keyWindowNumber=12, selectedRowBefore=-1, selectedRowAtDispatch=-1,
        currentEventType=2, currentEventWindowNumber=12, modalWindowNumber=-1, attachedSheetNumber=-1,
        applicationIsActive=True, applicationIsRunning=True, currentEventIsSuppliedDown=False,
        pointAtDispatch=[100, 20], eventIdentity=identity)
    for key in ('rowFrameBeforeFinalLayout', 'tableBounds', 'tableVisibleRect', 'rowFrameAtDispatch', 'rowFrameAfter'):
        row[key] = [0, 0, 550, 36]
    return row


def comparison():
    return dict(passed=True, dimensionsMatch=True, exactCanonicalRGBAEquality=True,
        width=480, height=320, expectedWidth=480, expectedHeight=320,
        outputPixelSHA256=SOURCE_PIXELS, sourcePixelSHA256=SOURCE_PIXELS, method=C.COMPARISON)


def catalog():
    return dict(version=1, selectedID=UUID, definitions=[dict(id=UUID, name='编号截图 · 保存、复制、贴图',
                                                          source={'kind': 'region'}, outputs=C.OUTPUTS.copy())])


def case(retry):
    name = 'retry' if retry else 'close'
    path = f'/private/tmp/PicShot-CaptureChain-{UUID}/{name}/saved/owned-chain-numbered-output-截图链-1.png'
    value = dict(status='passed', case=name, definitionOutputs=C.OUTPUTS.copy(), actionRoute=C.ROUTE,
        copyRejectionInjectedAtCheckedWriter=True, runControlIdentifier='capture-chain-run',
        closeControlIdentifier='capture-chain-close', failureReceiptOutputs=['quickSavePNG'],
        saveReceiptByteCountMatchesFile=True, saveDrainedBeforeRetryOrClose=True,
        catalogDefinitionsOnly=True, managerHiddenDuringCapture=True, historyHiddenDuringCapture=True,
        sameOwnedImageAtEveryOutput=True, noEditorHistoryOrTransientPinOutput=True,
        cleanupSafe=True, saveJobsDrained=True, privatePasteboardReleased=True, isolatedDefaultsRemoved=True,
        savedFileCount=1, savedPNGUnchangedAfterRetryOrClose=True, finalRetainedBytes=0,
        terminalStatus='completed' if retry else 'cancelled',
        failureAttempts=dict(capture=1, save=1, saveAdmissions=1, copy=1, pin=0),
        attempts=dict(capture=1, save=1, saveAdmissions=1, copy=2 if retry else 1, pin=1 if retry else 0),
        failedRetainedBytes=480*320*4, savedPath=path, savedPNGByteCount=len(SOURCE_PNG),
        savedPNGFileSHA256=sha(SOURCE_PNG), savedPNGComparison=comparison(), rowSelection=selection(),
        catalogBeforeSHA256='b'*64, catalogAfterSHA256='b'*64,
        failureArtifacts=artifacts('chain-copy-failure' if retry else 'chain-close-failure'),
        receipts=[dict(output='quickSavePNG', savedURL=path, byteCount=len(SOURCE_PNG))])
    if retry:
        value.update(retryControlIdentifier='capture-chain-retry', pinOriginalAndCurrentShareOneAsset=True,
            visibleNativePinCount=1, pinID=UUID, copiedPNGComparison=comparison(),
            publishedPinComparison=comparison(), reloadedPinComparison=comparison(),
            copiedPNGFileSHA256=sha(SOURCE_PNG), pinPNGFileSHA256=sha(SOURCE_PNG),
            reloadedPinPNGFileSHA256=sha(SOURCE_PNG), managerArtifacts=artifacts('chain-manager'),
            resultArtifacts=artifacts('chain-result'))
        value['receipts'] += [dict(output='copy', checkedPrivatePasteboard=True), dict(output='pin', pinID=UUID)]
    else:
        value['committedFilePreservedAfterClose'] = True
    return value


def report():
    value = dict(schemaVersion=1, status='passed', sourceCommit=SOURCE, installerAcceptance=False,
        source=C.SOURCE, acquisition=C.ACQUISITION, realScreenCaptureClaimed=False, screenCaptureAPICalled=False,
        permissionRequested=False, globalInputPosted=False, networkUsed=False, userHistoryReadOrWritten=False,
        standardDefaultsReadOrWritten=False, generalPasteboardReadOrWritten=False,
        productAppDelegateExercised=True, productSaveWorkflowDeliveryExercised=True,
        productPersistentPinExercised=True, canonicalPrivateTemporaryRoot=True, ownershipReleased=True,
        privateTemporaryRootRemoved=True, cleanupSafe=True, limitations=C.LIMITATIONS.copy(), elapsedSeconds=10.,
        sourceReference=dict(width=480, height=320, canonicalRGBAPixelSHA256=SOURCE_PIXELS),
        saveCopyRetryPin=case(True), closeAfterFailure=case(False))
    for key in ('successOwnershipReleased', 'closeOwnershipReleased'):
        value[key] = {owner: True for owner in C.OWNERS}
    return value


def fixture(root):
    app = root/'PicShot.app'
    executable = app/'Contents/MacOS/PicShot'
    executable.parent.mkdir(parents=True)
    executable.write_bytes(b'portable-identity-input-not-a-native-executable')
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(PicShotSourceCommit=SOURCE, CFBundleVersion='245',
        CFBundleShortVersionString='0.22.0', CFBundleExecutable='PicShot', CFBundleIdentifier='local.picshot.app')))
    dump(app/'Contents/Resources/build-info.json', dict(app='PicShot', sourceCommit=SOURCE, version='0.22.0', architecture='arm64'))
    evidence = root/'evidence'
    evidence.mkdir()
    value = report()
    for name, filename in [('saveCopyRetryPin', 'chain-catalog.json'), ('closeAfterFailure', 'chain-close-catalog.json')]:
        dump(evidence/filename, catalog())
        value[name]['catalogBeforeSHA256'] = value[name]['catalogAfterSHA256'] = sha((evidence/filename).read_bytes())
    dump(evidence/'capture-chain-demo.json', value)
    value.update(historyDirectoryRemoved=True, independentValidationRequired=True, bundlePath=str(app),
                 executablePath=str(executable), arguments=[str(executable)], build='245', version='0.22.0')
    dump(evidence/'demo.json', value)
    dump(evidence/'demo.json.launcher.json', dict(schemaVersion=1, status='exited', launcherExitCode=0,
        callbackReceived=True, createsNewApplicationInstance=True, ownedExitConfirmed=True, launchedIdentityMatches=True,
        captureChainDiagnosticOnly=True, liveScrollDiagnosticOnly=False, earlyWitnessOnly=False,
        processStartMemoryCaptured=False, timeoutSeconds=240, selectedAppPath=str(app), launchedAppPath=str(app),
        expectedExecutablePath=str(executable), launchedExecutablePath=str(executable), processIdentifier=100,
        elapsedSeconds=11.))
    for name in ('chain-source-numbered.png', 'chain-saved.png', 'chain-copied.png', 'chain-pin.png',
                 'chain-pin-reloaded.png', 'chain-close-saved.png'):
        (evidence/name).write_bytes(SOURCE_PNG)
    for case_name, keys in [('saveCopyRetryPin', ('managerArtifacts', 'failureArtifacts', 'resultArtifacts')),
                           ('closeAfterFailure', ('failureArtifacts',))]:
        for key in keys:
            for artifact in value[case_name][key]:
                name = artifact['filename']
                (evidence/name).write_bytes(LIGHT_PNG if artifact['appearance'] == 'light' else DARK_PNG)
                dump(evidence/(name[:-4]+'-layout.json'), artifact)
    return evidence/'demo.json'


class SchemaTests(unittest.TestCase):
    def test_complete_schema(self):
        C.report_fields(report(), SOURCE)

    def test_every_required_top_level_field_is_required_and_typed(self):
        original = report()
        for key in original:
            with self.subTest(key=key):
                value = copy.deepcopy(original)
                del value[key]
                with self.assertRaises(ValueError): C.report_fields(value, SOURCE)
        for key, before in original.items():
            if type(before) in (bool, int):
                value = copy.deepcopy(original)
                value[key] = int(before) if type(before) is bool else True
                with self.subTest(type=key), self.assertRaises(ValueError): C.report_fields(value, SOURCE)

    def test_every_required_case_field_is_required(self):
        for case_name in ('saveCopyRetryPin', 'closeAfterFailure'):
            original = report()
            for key in original[case_name]:
                with self.subTest(case=case_name, key=key):
                    value = copy.deepcopy(original)
                    del value[case_name][key]
                    with self.assertRaises(ValueError): C.report_fields(value, SOURCE)

    def test_synthetic_scope_and_owned_drains_are_mandatory(self):
        original = report()
        for key in ('installerAcceptance', 'realScreenCaptureClaimed', 'screenCaptureAPICalled', 'permissionRequested',
                    'globalInputPosted', 'networkUsed', 'userHistoryReadOrWritten', 'standardDefaultsReadOrWritten',
                    'generalPasteboardReadOrWritten', 'ownershipReleased', 'cleanupSafe', 'privateTemporaryRootRemoved'):
            value = copy.deepcopy(original)
            value[key] = not value[key]
            with self.subTest(key=key), self.assertRaises(ValueError): C.report_fields(value, SOURCE)
        for owner in C.OWNERS:
            for group in ('successOwnershipReleased', 'closeOwnershipReleased'):
                value = copy.deepcopy(original)
                value[group][owner] = False
                with self.subTest(group=group, owner=owner), self.assertRaises(ValueError): C.report_fields(value, SOURCE)

    def test_receipts_attempts_and_terminal_state_cannot_be_faked(self):
        for name in ('saveCopyRetryPin', 'closeAfterFailure'):
            for group in ('attempts', 'failureAttempts'):
                for output in ('capture', 'save', 'saveAdmissions', 'copy', 'pin'):
                    value = report()
                    value[name][group][output] += 1
                    with self.subTest(name=name, group=group, output=output), self.assertRaises(ValueError):
                        C.report_fields(value, SOURCE)
            for key, bad in [('failureReceiptOutputs', []), ('savedPNGByteCount', True), ('savedFileCount', 2),
                             ('failedRetainedBytes', 0), ('finalRetainedBytes', 1), ('terminalStatus', 'running'),
                             ('actionRoute', 'performClick'), ('catalogAfterSHA256', 'c'*64),
                             ('savedPath', '/private/tmp/outside.png')]:
                value = report(); value[name][key] = bad
                with self.subTest(name=name, key=key), self.assertRaises(ValueError): C.report_fields(value, SOURCE)
        value = report(); value['saveCopyRetryPin']['receipts'].reverse()
        with self.assertRaises(ValueError): C.report_fields(value, SOURCE)
        value = report(); value['closeAfterFailure']['pinID'] = UUID
        with self.assertRaises(ValueError): C.report_fields(value, SOURCE)

    def test_raw_window_geometry_is_recomputed(self):
        for mutation in ('offscreen', 'clipped', 'overlap', 'missing', 'duplicate', 'hidden', 'wrong-class', 'zero-height'):
            value = report()
            layout = value['saveCopyRetryPin']['failureArtifacts'][0]['layout']
            controls = layout['controls']
            if mutation == 'offscreen': layout['windowFrame']['x'] = 1199
            if mutation == 'clipped': controls[0]['fullFrame']['x'] = 590
            if mutation == 'overlap': controls[1]['fullFrame'] = copy.deepcopy(controls[0]['fullFrame'])
            if mutation == 'missing': controls.pop(0)
            if mutation == 'duplicate': controls.append(copy.deepcopy(controls[0]))
            if mutation == 'hidden': controls[0]['hidden'] = True
            if mutation == 'wrong-class': controls[1]['class'] = 'NSTableView'
            if mutation == 'zero-height': controls[0]['fullFrame']['height'] = 0
            with self.subTest(mutation=mutation), self.assertRaises(ValueError): C.report_fields(value, SOURCE)

    def test_native_text_needs_actual_fit_or_full_accessible_alternative(self):
        value = report()
        target = value['saveCopyRetryPin']['failureArtifacts'][0]['layout']['controls'][2]
        target['untruncatedCellSize'][0] = 1200
        with self.assertRaises(ValueError): C.report_fields(value, SOURCE)
        target.update(textFits=False, intentionalTruncation=True)
        C.report_fields(value, SOURCE)
        target['toolTip'] = '…'
        with self.assertRaises(ValueError): C.report_fields(value, SOURCE)
        target['toolTip'] = target['text']; target['fontPointSize'] = 10
        with self.assertRaises(ValueError): C.report_fields(value, SOURCE)

    def test_actual_owned_row_event_identity_is_required(self):
        for mutation in ('clock', 'window', 'route', 'row', 'visible', 'bool-int'):
            value = report(); row = value['saveCopyRetryPin']['rowSelection']
            if mutation == 'clock': row['eventIdentity']['dequeued']['quartzTimestampNanoseconds'] += 1
            if mutation == 'window': row['ownedDownWindowNumber'] += 1
            if mutation == 'route': row['dispatchRoute'] = 'selectRowIndexes'
            if mutation == 'row': row['selectedRowAfter'] = -1
            if mutation == 'visible': row['targetPointVisible'] = False
            if mutation == 'bool-int': row['requestedRow'] = False
            with self.subTest(mutation=mutation), self.assertRaises(ValueError): C.report_fields(value, SOURCE)

    def test_catalog_rejects_runtime_payloads_and_bad_selection(self):
        C.catalog({}, catalog())
        for mutation in ('raster', 'receipts', 'bad-selection', 'definition-path', 'wrong-source', 'bool-version'):
            value = catalog()
            if mutation in ('raster', 'receipts'): value[mutation] = 'payload'
            if mutation == 'bad-selection': value['selectedID'] = 'B'+UUID[1:]
            if mutation == 'definition-path': value['definitions'][0]['savedPath'] = '/private/tmp/a.png'
            if mutation == 'wrong-source': value['definitions'][0]['source'] = {'kind': 'preset', 'presetID': UUID}
            if mutation == 'bool-version': value['version'] = True
            with self.subTest(mutation=mutation), self.assertRaises(ValueError): C.catalog({}, value)


class FileTests(unittest.TestCase):
    def test_complete_portable_contract_and_cli(self):
        with tempfile.TemporaryDirectory() as temp:
            path = fixture(Path(temp))
            result = subprocess.run([sys.executable, str(SCRIPTS/'check-capture-chain-demo.py'), '--report', str(path),
                                     '--source', SOURCE], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            receipt = C.COMMON.load(path.parent/'capture-chain-receipt.json')
            self.assertTrue(receipt['exactDecodedOutputPixels'])
            self.assertFalse(receipt['installerAcceptance'])
            self.assertFalse(receipt['realScreenCaptureAcceptance'])
            self.assertFalse(receipt['memoryQualification'])
            self.assertEqual(len(receipt['evidenceSHA256']), 27)

    def test_launcher_deadline_cannot_exceed_the_owned_chain_budget(self):
        with tempfile.TemporaryDirectory() as temp:
            path = fixture(Path(temp))
            launch_path = path.parent/'demo.json.launcher.json'
            original = C.COMMON.load(launch_path)
            for key, bad in [('timeoutSeconds', 600), ('timeoutSeconds', 241), ('timeoutSeconds', 239),
                             ('elapsedSeconds', 240.001)]:
                changed = copy.deepcopy(original); changed[key] = bad; dump(launch_path, changed)
                with self.subTest(key=key, bad=bad), self.assertRaises(ValueError):
                    C.validate(path, SOURCE)

    def test_exact_png_decoder_rejects_damage_bounds_and_transparency(self):
        self.assertEqual(C.decoded_png(SOURCE_PNG, 'test')[:2], (480, 320))
        for raw in [SOURCE_PNG[:-1], SOURCE_PNG+b'x', b'\x89PNG\r\n\x1a\nfixture',
                    SOURCE_PNG[:30]+b'x'+SOURCE_PNG[31:], png(1, 1, (0, 0, 0, 0))[0],
                    b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR', struct.pack('>IIBBBBB', 4096, 4096, 8, 6, 0, 0, 0))+chunk(b'IEND', b'')]:
            with self.subTest(length=len(raw)), self.assertRaises(ValueError): C.decoded_png(raw, 'bad')

    def test_changed_output_pixels_fail_even_if_file_hash_is_updated(self):
        with tempfile.TemporaryDirectory() as temp:
            path = fixture(Path(temp))
            changed = png(480, 320, (121, 140, 160, 255))[0]
            (path.parent/'chain-copied.png').write_bytes(changed)
            for name in ('demo.json', 'capture-chain-demo.json'):
                value = C.COMMON.load(path.parent/name)
                value['saveCopyRetryPin']['copiedPNGFileSHA256'] = sha(changed)
                dump(path.parent/name, value)
            with self.assertRaisesRegex(ValueError, 'exact pixels differ'): C.validate(path, SOURCE)

    def test_identity_and_raw_report_disagreements_fail_before_pixels(self):
        with tempfile.TemporaryDirectory() as temp:
            path = fixture(Path(temp))
            original = C.COMMON.load(path)
            for key, bad in [('sourceCommit', 'b'*40), ('bundlePath', '/outside/PicShot.app'),
                             ('arguments', [original['executablePath'], '--fake']), ('historyDirectoryRemoved', False),
                             ('build', '244'), ('version', '0.21.0'), ('elapsedSeconds', 99)]:
                value = copy.deepcopy(original); value[key] = bad; dump(path, value)
                with self.subTest(key=key), self.assertRaises((ValueError, OSError)): C.validate(path, SOURCE)
            dump(path, original)
            launch_path = path.parent/'demo.json.launcher.json'; launch = C.COMMON.load(launch_path)
            for key in launch:
                changed = copy.deepcopy(launch); del changed[key]; dump(launch_path, changed)
                with self.subTest(launch=key), self.assertRaises(ValueError): C.validate(path, SOURCE)

    def test_symlink_oversize_duplicate_json_nonfinite_missing_input_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); path = fixture(root)
            saved = path.parent/'chain-source-numbered.png'; saved.unlink(); saved.symlink_to(root/'absent')
            with self.assertRaises(ValueError): C.validate(path, SOURCE)
            for raw in (b'{"x":1,"x":2}', b'{"x":NaN}', b'{"x":Infinity}'):
                bad = root/'bad.json'; bad.write_bytes(raw)
                with self.assertRaises(ValueError): C.COMMON.load(bad)
            big = root/'too-big'; big.write_bytes(b'12345')
            with self.assertRaises(ValueError): C.COMMON.read(big, 4)
            with self.assertRaises(ValueError): C.COMMON.read(root/'missing')


# Retained246 chain-close-failure-dark-layout.json SHA256: 5ae6117a90b7e09a739ece74c954b6a1ad092adeaddc86dfa7364b78601b91bf
RETAINED246_CLOSE_CONTROLS = [{'accessibilityLabel': '关闭',
  'accessibilityValue': '',
  'class': 'NSButton',
  'enabled': True,
  'fullFrame': {'height': 32, 'width': 60, 'x': 11, 'y': 9},
  'fullFrameContained': True,
  'fullScreenFrame': {'height': 32, 'width': 60, 'x': 213, 'y': 440},
  'hidden': False,
  'hitTest': True,
  'id': 'capture-chain-close',
  'insideScrollableViewport': True,
  'requiredTextSizeAtActualWidth': [60, 32],
  'text': '关闭',
  'titleFits': True,
  'toolTip': '',
  'untruncatedCellSize': [60, 32],
  'visibleRect': {'height': 298, 'width': 620, 'x': -11, 'y': -257}},
 {'accessibilityLabel': '',
  'accessibilityValue': '关闭',
  'class': 'NSButtonTextField',
  'enabled': True,
  'fontPointSize': 13,
  'fullFrame': {'height': 16, 'width': 38, 'x': 22, 'y': 19},
  'fullFrameContained': True,
  'fullScreenFrame': {'height': 16, 'width': 38, 'x': 224, 'y': 450},
  'fullTextTooltipAndAccessibility': False,
  'hidden': False,
  'id': 'native-control-86',
  'insideScrollableViewport': True,
  'intentionalTruncation': False,
  'lineBreakMode': 4,
  'maximumNumberOfLines': 0,
  'requiredTextSizeAtActualWidth': [33.797665369649806, 16],
  'text': '关闭',
  'textFits': True,
  'textWraps': False,
  'toolTip': '',
  'untruncatedCellSize': [33.797665369649806, 16],
  'visibleRect': {'height': 298, 'width': 620, 'x': -22, 'y': -263}},
 {'accessibilityLabel': '返回管理',
  'accessibilityValue': '',
  'class': 'NSButton',
  'enabled': False,
  'fullFrame': {'height': 32, 'width': 86, 'x': 69, 'y': 9},
  'fullFrameContained': True,
  'fullScreenFrame': {'height': 32, 'width': 86, 'x': 271, 'y': 440},
  'hidden': False,
  'hitTest': True,
  'id': 'capture-chain-manage',
  'insideScrollableViewport': True,
  'requiredTextSizeAtActualWidth': [86, 32],
  'text': '返回管理',
  'titleFits': True,
  'toolTip': '',
  'untruncatedCellSize': [86, 32],
  'visibleRect': {'height': 298, 'width': 620, 'x': -69, 'y': -257}},
 {'accessibilityLabel': '',
  'accessibilityValue': '返回管理',
  'class': 'NSButtonTextField',
  'enabled': False,
  'fontPointSize': 13,
  'fullFrame': {'height': 16, 'width': 64, 'x': 80, 'y': 19},
  'fullFrameContained': True,
  'fullScreenFrame': {'height': 16, 'width': 64, 'x': 282, 'y': 450},
  'fullTextTooltipAndAccessibility': False,
  'hidden': False,
  'id': 'native-control-89',
  'insideScrollableViewport': True,
  'intentionalTruncation': False,
  'lineBreakMode': 4,
  'maximumNumberOfLines': 0,
  'requiredTextSizeAtActualWidth': [59.59533073929961, 16],
  'text': '返回管理',
  'textFits': True,
  'textWraps': False,
  'toolTip': '',
  'untruncatedCellSize': [59.59533073929961, 16],
  'visibleRect': {'height': 298, 'width': 620, 'x': -80, 'y': -263}}]

class NativeAncestryTests(unittest.TestCase):
    def with_child(self, phase='chain-copy-failure'):
        artifact=artifacts(phase)[0]
        rows=artifact['layout']['controls'];parent=rows[0]
        child=control('native-control-999',99,'NSTextField')
        child.update(**{'class':'NSButtonTextField'},controlKind='textField',
            viewPath=parent['viewPath']+[0,0],parentControlID=parent['id'],controlAncestorIDs=[parent['id']],
            fullFrame=rect(22,15,100,20),fullScreenFrame=rect(42,35,100,20),visibleRect=rect(0,0,100,20))
        rows.append(child);artifact['layout']['nativeControlCount']=len(rows)
        return artifact,parent,child

    def test_native_button_text_descendant_keeps_full_text_and_geometry_checks(self):
        artifact,parent,child=self.with_child()
        C.layout(artifact,'chain-copy-failure')
        child['class']='AnotherNativeTextFieldSubclass'
        C.layout(artifact,'chain-copy-failure')
        child['requiredTextSizeAtActualWidth'][1]=30
        with self.assertRaises(ValueError):C.layout(artifact,'chain-copy-failure')
        child['requiredTextSizeAtActualWidth'][1]=20
        child['fullFrame']['x']=599
        with self.assertRaises(ValueError):C.layout(artifact,'chain-copy-failure')

    def test_ordinary_button_title_child_cannot_gain_truncation_by_own_tooltip(self):
        artifact,parent,child=self.with_child()
        child.update(untruncatedCellSize=[1200,20],textFits=False,intentionalTruncation=True,
                     fullTextTooltipAndAccessibility=True,toolTip=child['text'],accessibilityValue=child['text'])
        with self.assertRaisesRegex(ValueError,'button title descendant is clipped'):
            C.layout(artifact,'chain-copy-failure')

    def test_missing_foreign_cyclic_duplicate_and_forged_ancestry_fail_closed(self):
        for mutation in ('missing-parent','missing-path','missing-kind','missing-ancestors','foreign-parent','cycle',
                         'forged-parent','duplicate-path','foreign-window','unowned-root','forged-origin',
                         'wrong-role','wrong-title','hidden-owner','unnested-private-class','nested-product-button'):
            artifact,parent,child=self.with_child();rows=artifact['layout']['controls']
            if mutation=='missing-parent':del child['parentControlID']
            elif mutation=='missing-path':del child['viewPath']
            elif mutation=='missing-kind':del child['controlKind']
            elif mutation=='missing-ancestors':del child['controlAncestorIDs']
            elif mutation=='foreign-parent':child['parentControlID']='not-in-owned-window'
            elif mutation=='cycle':child.update(parentControlID=child['id'],controlAncestorIDs=[child['id']])
            elif mutation=='forged-parent':child.update(parentControlID=rows[1]['id'],controlAncestorIDs=[rows[1]['id']])
            elif mutation=='duplicate-path':child['viewPath']=parent['viewPath'].copy()
            elif mutation=='foreign-window':child['ownerWindowNumber']=13
            elif mutation=='unowned-root':child['descendantOfOwnedContent']=False
            elif mutation=='forged-origin':child['identifierIsExplicit']=True
            elif mutation=='wrong-role':child['controlKind']='button'
            elif mutation=='wrong-title':child['text']='Different independent label'
            elif mutation=='hidden-owner':parent['hidden']=True
            elif mutation=='unnested-private-class':child.update(viewPath=[99],parentControlID=None,controlAncestorIDs=[])
            else:parent.update(viewPath=rows[1]['viewPath']+[1],parentControlID=rows[1]['id'],controlAncestorIDs=[rows[1]['id']])
            with self.subTest(mutation=mutation),self.assertRaises(ValueError):C.layout(artifact,'chain-copy-failure')

    def test_native_child_may_overlap_only_its_own_ancestors(self):
        artifact,parent,child=self.with_child()
        # A non-clipping native descendant may extend beyond its owner; it still
        # must fit the owned window and cannot overlap any independent control.
        child['fullFrame']=rect(22,25,100,30)
        child['fullScreenFrame']=rect(42,45,100,30)
        with self.assertRaisesRegex(ValueError,'independent full controls overlap'):
            C.layout(artifact,'chain-copy-failure')
        artifact,parent,child=self.with_child()
        sibling=copy.deepcopy(child);sibling.update(id='native-control-998',viewPath=parent['viewPath']+[1])
        artifact['layout']['controls'].append(sibling);artifact['layout']['nativeControlCount']+=1
        with self.assertRaisesRegex(ValueError,'independent full controls overlap'):
            C.layout(artifact,'chain-copy-failure')

    def test_retained246_native_metrics_still_reject_real_sibling_overlap(self):
        # Frame/text measurements below are verbatim246 observations. Only the
        # new tree metadata is synthetic, so this never certifies the old run.
        rows=[]
        for index,observed in enumerate(RETAINED246_CLOSE_CONTROLS):
            kind='NSButton' if index%2==0 else 'NSTextField'
            row=control(observed['id'],index,kind);row.update(copy.deepcopy(observed))
            row['controlKind']='button' if index%2==0 else 'textField'
            if index%2:
                owner=rows[index-1]
                row.update(viewPath=owner['viewPath']+[0],parentControlID=owner['id'],controlAncestorIDs=[owner['id']])
            rows.append(row)
        ancestry=C.control_ancestry(rows,12)
        leaves=[(row['id'],C.rectangle(row['fullFrame'],'retained frame')) for row in rows]
        C.check_control_overlap(leaves[:2],ancestry)
        with self.assertRaisesRegex(ValueError,'independent full controls overlap'):
            C.check_control_overlap(leaves,ancestry)
        self.assertEqual(rows[0]['fullFrame'],dict(x=11,y=9,width=60,height=32))
        self.assertEqual(rows[1]['fullFrame'],dict(x=22,y=19,width=38,height=16))
        self.assertEqual(rows[2]['fullFrame'],dict(x=69,y=9,width=86,height=32))

    def long_manager(self):
        artifact=artifacts('chain-manager')[0]
        rows={row['id']:row for row in artifact['layout']['controls']}
        for identifier in ('capture-chain-name','capture-chain-source'):
            row=rows[identifier];row['text']='长名称'*20
            row.update(toolTip=row['text'],accessibilityValue=row['text'],untruncatedCellSize=[1200,20])
            if identifier=='capture-chain-name':row.update(textFits=False,intentionalTruncation=True)
            else:row.update(titleFits=False,selectedItemTitle=row['text'])
        return artifact,rows

    def test_only_known_editable_name_and_source_popup_allow_long_text(self):
        artifact,rows=self.long_manager()
        C.layout(artifact,'chain-manager')
        rows['capture-chain-name'].update(lineBreakMode=2,intentionalTruncation=False)
        C.layout(artifact,'chain-manager')
        rows['capture-chain-close'].update(titleFits=False,untruncatedCellSize=[1200,20],
            sourcePopupLongTitleAlternative=True,toolTip=rows['capture-chain-close']['text'],
            accessibilityValue=rows['capture-chain-close']['text'])
        with self.assertRaisesRegex(ValueError,'button title clipped'):C.layout(artifact,'chain-manager')

    def test_long_name_rejects_missing_scrollability_or_full_text_and_forged_role(self):
        for key,bad in [('textScrollable',False),('textEditable',False),('textSelectable',False),
                        ('accessibilityValue','…'),('toolTip','…'),('class','NSButton'),
                        ('editableNameLongTextAlternative',False)]:
            artifact,rows=self.long_manager();rows['capture-chain-name'][key]=bad
            with self.subTest(key=key),self.assertRaises(ValueError):C.layout(artifact,'chain-manager')
        artifact,rows=self.long_manager();del rows['capture-chain-name']['textScrollable']
        with self.assertRaises(ValueError):C.layout(artifact,'chain-manager')
        artifact,rows=self.long_manager();rows['capture-chain-name']['alignmentFrame']['width']=319
        with self.assertRaises(ValueError):C.layout(artifact,'chain-manager')

    def test_long_source_rejects_missing_alternative_small_width_and_clipped_hit(self):
        for key,bad in [('accessibilityValue','…'),('toolTip','…'),('selectedItemTitle','…'),
                        ('titleLineBreakMode',2),('hitTest',False),('class','NSButton'),
                        ('sourcePopupLongTitleAlternative',False)]:
            artifact,rows=self.long_manager();rows['capture-chain-source'][key]=bad
            with self.subTest(key=key),self.assertRaises(ValueError):C.layout(artifact,'chain-manager')
        for target in ('alignmentFrame','fullFrame'):
            artifact,rows=self.long_manager();rows['capture-chain-source'][target]['width']=319
            with self.subTest(target=target),self.assertRaises(ValueError):C.layout(artifact,'chain-manager')
        artifact,rows=self.long_manager();rows['capture-chain-source']['fullFrame']['height']=10
        with self.assertRaises(ValueError):C.layout(artifact,'chain-manager')

    def test_only_verified_source_title_child_can_inherit_full_accessible_title(self):
        artifact,rows=self.long_manager();parent=rows['capture-chain-source']
        child=control('native-control-997',97,'NSTextField')
        child.update(**{'class':'NSButtonTextField'},viewPath=parent['viewPath']+[0],
            parentControlID=parent['id'],controlAncestorIDs=[parent['id']],
            text=parent['text'],toolTip='',accessibilityLabel='',accessibilityValue='',
            fullFrame=rect(22,155,100,20),fullScreenFrame=rect(42,175,100,20),visibleRect=rect(0,0,100,20),
            untruncatedCellSize=[1200,20],requiredTextSizeAtActualWidth=[100,20],
            lineBreakMode=2,textFits=False,intentionalTruncation=False,
            fullTextTooltipAndAccessibility=False,inheritedSourceTitleAlternative=True)
        artifact['layout']['controls'].append(child);artifact['layout']['nativeControlCount']+=1
        C.layout(artifact,'chain-manager')
        for mutation in ('foreign-parent','mismatched-title','parent-missing-AX','bad-height','false-inheritance','unrelated-overlap'):
            changed=copy.deepcopy(artifact);item=changed['layout']['controls'][-1]
            if mutation=='foreign-parent':item['parentControlID']='capture-chain-close'
            elif mutation=='mismatched-title':item['text']='other'
            elif mutation=='parent-missing-AX':changed['layout']['controls'][4]['accessibilityValue']='…'
            elif mutation=='bad-height':item['requiredTextSizeAtActualWidth'][1]=40
            elif mutation=='false-inheritance':item['inheritedSourceTitleAlternative']=False
            else:item['fullFrame']['y']=120;item['fullScreenFrame']['y']=140
            with self.subTest(mutation=mutation),self.assertRaises(ValueError):C.layout(changed,'chain-manager')

    def test_fixture_emits_real_paths_roles_and_parent_identity_without_class_skip(self):
        source=(SCRIPTS.parent/'Sources/PicShot/CaptureChainUIPreviewFixture.swift').read_text()
        for token in ('recordViewPaths(root, path: [])','control.window?.windowNumber',
                      'control.isDescendant(of: root) && control.window === window',
                      'controlAncestors.append(controlIDs[ObjectIdentifier(parent)]',
                      'row["parentControlID"] = controlAncestors.first',
                      'row["controlAncestorIDs"] = controlAncestors',
                      'lhs.0.isDescendant(of: rhs.0) || rhs.0.isDescendant(of: lhs.0)',
                      'overlap.width > 0.5 && overlap.height > 0.5'):
            self.assertIn(token,source)
        self.assertNotIn('NSButtonTextField',source)



if __name__ == '__main__':
    unittest.main()
