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
    value = dict(id=identifier, **{'class': kind}, fullFrame=rect(x, y, 300, 30),
        fullScreenFrame=rect(x+20, y+20, 300, 30), visibleRect=rect(0, 0, 300, 30),
        hidden=False, enabled=True, insideScrollableViewport=True,
        text='完整文本', toolTip='完整文本', accessibilityLabel='完整文本', accessibilityValue='',
        untruncatedCellSize=[100, 20], requiredTextSizeAtActualWidth=[100, 20])
    if kind != 'NSTableView':
        value['fullFrameContained'] = True
        if kind == 'NSTextField':
            value.update(textFits=True, textWraps=False, intentionalTruncation=False,
                         fullTextTooltipAndAccessibility=True, fontPointSize=12,
                         lineBreakMode=4, maximumNumberOfLines=2)
        else:
            value.update(hitTest=True, titleFits=True)
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
            layout=dict(passed=True, phase=phase, windowTitle='截图链', windowVisible=True,
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
        processStartMemoryCaptured=False, timeoutSeconds=600, selectedAppPath=str(app), launchedAppPath=str(app),
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


if __name__ == '__main__':
    unittest.main()
