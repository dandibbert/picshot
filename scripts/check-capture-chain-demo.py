#!/usr/bin/env python3
"""Check the bounded, synthetic-acquisition installed native capture-chain witness.

This is an evidence reader, not an execution harness or installer, real-capture,
RSS, or zero-leak qualification. Portable test inputs never constitute native proof.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import re
import struct


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


COMMON = module('chain_common', 'check-experimental-scroll-interactions.py')
PNG = module('chain_png', 'check-automatic-mosaic-report.py')
need, fields, number = COMMON.need, COMMON.fields, COMMON.number
OUTPUTS = ['quickSavePNG', 'copy', 'pin']
OWNERS = ('app', 'manager', 'runner', 'selectedImage', 'saveJob', 'pinController',
          'presenter', 'delivery', 'pinCoordinator')
ROUTE = ('PortableSettingsUIPreviewFixture.click: owned NSButton.mouseDown with queued mouseUp; '
         'NSTableView: owned-nextEvent-sendEvent')
SOURCE = 'Fixture-owned native numbered image; one independent decoded selection per run'
ACQUISITION = 'Injected CaptureChainRunner.Dependencies.capture; no ScreenCaptureKit acquisition'
RENDERING = 'Actual native owned content over resolved effective-appearance window background'
COMPARISON = 'Independent ImageIO PNG decode followed by full canonical sRGB RGBA equality'
LIMITATIONS = ['Synthetic acquisition does not prove desktop selection or ScreenCaptureKit',
              'The first checked clipboard recipient write is deliberately rejected',
              'Images show cached owned native content, not a desktop screenshot',
              'Weak-owner checks and bounded reservations are not an RSS or zero-leak claim']
MAX_FILE = 16 * 1024**2
MAX_TOTAL = 96 * 1024**2


def integer(value, label, low=0, high=2**63-1):
    need(type(value) is int and low <= value <= high, label + ': invalid integer')
    return value


def text(value, label, maximum=4096, nonempty=True):
    need(type(value) is str and (bool(value) or not nonempty) and len(value.encode()) <= maximum
         and '\0' not in value, label + ': invalid text')
    return value


def digest(value, label):
    need(type(value) is str and re.fullmatch(r'[0-9a-f]{64}', value), label + ': invalid SHA256')
    return value


def uuid(value, label):
    need(type(value) is str and re.fullmatch(r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}', value),
         label + ': invalid UUID')
    return value


def absolute(value, label):
    text(value, label)
    path = Path(value)
    need(path.is_absolute() and '..' not in path.parts and str(path) == value, label + ': noncanonical path')
    return path


def rectangle(row, label, empty=False):
    need(type(row) is dict and set(row) == {'x', 'y', 'width', 'height'}, label + ': missing full frame')
    return tuple(number(row.get(key), label + '.' + key,
                        -4_000_000 if key in ('x', 'y') else (0 if empty else .01), 4_000_000)
                 for key in ('x', 'y', 'width', 'height'))


def contains(outer, inner):
    x, y, w, h = outer
    a, b, c, d = inner
    # This is the fixture's explicit native half-point rounding allowance,
    # never a pixel-comparison tolerance or an allowance for another text line.
    return a >= x-.5 and b >= y-.5 and a+c <= x+w+.5 and b+d <= y+h+.5


def overlap(a, b):
    x, y, w, h = a
    u, v, s, t = b
    return min(x+w, u+s)-max(x, u) > .5 and min(y+h, v+t)-max(y, v) > .5


def pair(value, label):
    need(type(value) is list and len(value) == 2, label + ': missing pair')
    return [number(x, label, 0, 4_000_000) for x in value]


def boolean(row, key, label):
    need(type(row.get(key)) is bool, label + '.' + key + ': missing boolean')
    return row[key]


def row_selection(row):
    fields(row, dict(status='passed-local-row-selection', dispatchRoute='owned-nextEvent-sendEvent',
        requestedRow=0, rowAtDispatch=0, selectedRowAfter=0, ownedDownVerified=True,
        ownedDownType=1, targetPointVisible=True, windowIsKey=True, numberOfRows=1), 'row selection')
    window = integer(row.get('windowNumber'), 'row window', 1)
    fields(row, dict(ownedDownWindowNumber=window, keyWindowNumber=window), 'row window identity')
    for key in ('selectedRowBefore', 'selectedRowAtDispatch', 'currentEventType', 'currentEventWindowNumber',
                'modalWindowNumber', 'attachedSheetNumber'):
        integer(row.get(key), 'row.' + key, -1)
    for key in ('applicationIsActive', 'applicationIsRunning', 'currentEventIsSuppliedDown'):
        boolean(row, key, 'row')
    for key in ('rowFrameBeforeFinalLayout', 'tableBounds', 'tableVisibleRect', 'rowFrameAtDispatch', 'rowFrameAfter'):
        pair_value = row.get(key)
        need(type(pair_value) is list and len(pair_value) == 4, 'row.' + key + ': rectangle missing')
        for value in pair_value: number(value, 'row geometry', -4_000_000, 4_000_000)
        need(pair_value[2] > 0 and pair_value[3] > 0, 'empty row geometry')
    point = pair(row.get('pointAtDispatch'), 'row point')
    x, y, w, h = row['rowFrameAtDispatch']
    need(x <= point[0] <= x+w and y <= point[1] <= y+h, 'owned click outside selected row')
    identity = row.get('eventIdentity')
    fields(identity, {key: True for key in ('sameType', 'sameWindow', 'sameQuartzTimestamp', 'sameLocation',
           'sameEventNumber', 'sameClickCount', 'sameModifiers', 'ownedWindowIsKey')}, 'owned event')
    for key in ('sameTimestamp', 'sameObject'): boolean(identity, key, 'owned event')
    number(identity.get('timestampDifference'), 'event timestamp difference', -1, 1)
    for label in ('expected', 'dequeued'):
        event = identity.get(label)
        fields(event, dict(type=1, windowNumber=window, eventNumber=1, clickCount=1, modifierFlags=0), label)
        integer(event.get('quartzTimestampNanoseconds'), label + '.clock', 1, 2**64-1)
        number(event.get('timestamp'), label + '.timestamp', 0)
        pair(event.get('location'), label + '.location')
    for key in ('type', 'windowNumber', 'quartzTimestampNanoseconds', 'location', 'eventNumber', 'clickCount', 'modifierFlags'):
        need(identity['expected'][key] == identity['dequeued'][key], 'owned event changed: ' + key)


def layout(artifact, phase):
    row = artifact.get('layout')
    fields(row, dict(passed=True, phase=phase, windowTitle='截图链', windowVisible=True, violations=[],
        fullNativeFramesMeasured=True, alignmentRectanglesSubstituted=False,
        fullVisibleFramesChecked=True, controlsDoNotOverlap=True), phase + '.layout')
    bounds = rectangle(row.get('contentBounds'), 'content')
    screen = rectangle(row.get('visibleScreenFrame'), 'visible display')
    window = rectangle(row.get('windowFrame'), 'window')
    need(contains(screen, window), 'full native window is offscreen')
    need(bounds == (0, 0, artifact['width'], artifact['height']), 'PNG omits native content extent')
    controls = row.get('controls')
    need(type(controls) is list and 3 <= len(controls) <= 128, 'bounded native controls missing')
    by_id, leaves = {}, []
    for control in controls:
        need(type(control) is dict, 'invalid native control')
        identifier = text(control.get('id'), 'control ID', 128)
        need(identifier not in by_id, 'duplicate control: ' + identifier)
        by_id[identifier] = control
        kind = text(control.get('class'), 'control class', 128)
        need(kind in ('NSButton', 'NSPopUpButton', 'CaptureChainRunButton', 'NSTextField',
                      'NSTableView', 'NSScroller'), 'unrecognized native control class: '+kind)
        hidden = boolean(control, 'hidden', identifier)
        boolean(control, 'enabled', identifier)
        in_viewport = boolean(control, 'insideScrollableViewport', identifier)
        frame = rectangle(control.get('fullFrame'), identifier, empty=hidden or not in_viewport)
        on_screen = rectangle(control.get('fullScreenFrame'), identifier + '.screen', empty=hidden or not in_viewport)
        rectangle(control.get('visibleRect'), identifier + '.visibleRect', empty=True)
        size = pair(control.get('untruncatedCellSize'), identifier + '.cell')
        wrapped = pair(control.get('requiredTextSizeAtActualWidth'), identifier + '.textSize')
        for key in ('text', 'toolTip', 'accessibilityLabel', 'accessibilityValue'):
            text(control.get(key), identifier + '.' + key, nonempty=False)
        if hidden or not in_viewport: continue
        if kind not in ('NSButton', 'NSPopUpButton', 'CaptureChainRunButton', 'NSTextField'): continue
        fields(control, dict(fullFrameContained=True), identifier)
        need(contains(bounds, frame) and contains(screen, on_screen) and contains(window, on_screen),
             identifier + ': full frame clipped')
        need(frame[2:] == on_screen[2:], identifier + ': full native screen frame differs')
        need(not any(overlap(frame, prior) for prior in leaves), identifier + ': full controls overlap')
        leaves.append(frame)
        if kind != 'NSTextField':
            fields(control, dict(hitTest=True, titleFits=True), identifier)
            need(frame[2]+.5 >= size[0] and frame[3]+.5 >= size[1], identifier + ': button title clipped')
        elif control['text']:
            fits = boolean(control, 'textFits', identifier)
            wraps = boolean(control, 'textWraps', identifier)
            truncation = boolean(control, 'intentionalTruncation', identifier)
            alternative = boolean(control, 'fullTextTooltipAndAccessibility', identifier)
            line_break = integer(control.get('lineBreakMode'), identifier+'.lineBreakMode', 0, 5)
            integer(control.get('maximumNumberOfLines'), identifier+'.maximumNumberOfLines', 0, 100)
            actual_fit = wrapped[1] <= frame[3]+.5 and (wraps or size[0] <= frame[2]+.5)
            need(fits == actual_fit, identifier + ': text metrics contradict fit')
            need(truncation == (line_break in (3, 4, 5) and not fits), identifier + ': truncation metrics contradict mode')
            need(fits or (truncation and alternative and control['toolTip'] == control['text']
                 and control['text'] in (control['accessibilityLabel'], control['accessibilityValue'])),
                 identifier + ': unreadable text has no complete accessible alternative')
            number(control.get('fontPointSize'), identifier + '.font', 11, 128)
    required = {'capture-chain-close'}
    if phase == 'chain-manager':
        required |= {'capture-chain-run', 'capture-chain-list', 'capture-chain-name', 'capture-chain-source'}
    else:
        required |= {'capture-chain-run-status', 'capture-chain-receipt-0', 'capture-chain-receipt-1', 'capture-chain-receipt-2'}
        if 'failure' in phase: required.add('capture-chain-retry')
    for identifier in required:
        fields(by_id.get(identifier), dict(hidden=False, insideScrollableViewport=True), 'required ' + identifier)
        if identifier in ('capture-chain-run', 'capture-chain-retry', 'capture-chain-close'):
            fields(by_id[identifier], dict(enabled=True, hitTest=True, titleFits=True), identifier)
        expected_class = ('NSTableView' if identifier.endswith('-list') else
                          'NSPopUpButton' if identifier.endswith('-source') else
                          'CaptureChainRunButton' if identifier.endswith('-run') else
                          'NSButton' if identifier.endswith(('-close', '-retry')) else 'NSTextField')
        fields(by_id[identifier], {'class': expected_class}, identifier)
    return row


def artifacts(rows, phase):
    need(type(rows) is list and len(rows) == 2, phase + ': two appearances required')
    hashes = []
    for row, mode in zip(rows, ('light', 'dark')):
        fields(row, dict(filename=phase+'-'+mode+'.png', appearance=mode, rendering=RENDERING), phase)
        width = integer(row.get('width'), phase+'.width', 1, 4096)
        height = integer(row.get('height'), phase+'.height', 1, 4096)
        need(width*height <= 4_000_000, 'native image raster bound')
        hashes.append(digest(row.get('canonicalRGBAPixelSHA256'), phase+'.pixels'))
        layout(row, phase)
    need(hashes[0] != hashes[1], phase + ': appearances have identical pixels')


def comparison(row, expected_hash, label):
    fields(row, dict(passed=True, dimensionsMatch=True, exactCanonicalRGBAEquality=True,
        width=480, height=320, expectedWidth=480, expectedHeight=320,
        outputPixelSHA256=expected_hash, sourcePixelSHA256=expected_hash, method=COMPARISON), label)


def case_fields(row, retry, expected_hash):
    name = 'retry' if retry else 'close'
    fields(row, dict(status='passed', case=name, definitionOutputs=OUTPUTS, actionRoute=ROUTE,
        copyRejectionInjectedAtCheckedWriter=True, runControlIdentifier='capture-chain-run',
        closeControlIdentifier='capture-chain-close', failureReceiptOutputs=['quickSavePNG'],
        saveReceiptByteCountMatchesFile=True, saveDrainedBeforeRetryOrClose=True,
        catalogDefinitionsOnly=True, managerHiddenDuringCapture=True, historyHiddenDuringCapture=True,
        sameOwnedImageAtEveryOutput=True, noEditorHistoryOrTransientPinOutput=True,
        cleanupSafe=True, saveJobsDrained=True, privatePasteboardReleased=True, isolatedDefaultsRemoved=True,
        savedFileCount=1, savedPNGUnchangedAfterRetryOrClose=True, finalRetainedBytes=0,
        terminalStatus='completed' if retry else 'cancelled'), name)
    need(not any(key in row for key in ('error', 'cleanupError')), name+': recorded failure')
    fields(row.get('failureAttempts'), dict(capture=1, save=1, saveAdmissions=1, copy=1, pin=0), name+'.failureAttempts')
    fields(row.get('attempts'), dict(capture=1, save=1, saveAdmissions=1, copy=2 if retry else 1,
        pin=1 if retry else 0), name+'.attempts')
    integer(row.get('failedRetainedBytes'), name+'.retained bytes', 480*320*4, 4*1024**2)
    path = absolute(row.get('savedPath'), name+'.savedPath')
    need(path.parent.name == 'saved' and path.parent.parent.name == name and path.suffix == '.png'
         and path.name.startswith('owned-chain-') and '截图链-' in path.name,
         name + ': Save path outside owned case or wrong authored filename')
    integer(row.get('savedPNGByteCount'), name+'.saved bytes', 1, MAX_FILE)
    digest(row.get('savedPNGFileSHA256'), name+'.saved hash')
    before = digest(row.get('catalogBeforeSHA256'), name+'.catalog before')
    need(before == digest(row.get('catalogAfterSHA256'), name+'.catalog after'), 'saved catalog changed')
    comparison(row.get('savedPNGComparison'), expected_hash, name+'.Save comparison')
    row_selection(row.get('rowSelection'))
    artifacts(row.get('failureArtifacts'), 'chain-copy-failure' if retry else 'chain-close-failure')
    receipts = row.get('receipts')
    need(type(receipts) is list and len(receipts) == (3 if retry else 1), name+': receipt count')
    need(all(type(receipt) is dict for receipt in receipts), name+': invalid receipts')
    need(set(receipts[0]) == {'output', 'savedURL', 'byteCount'}, name+': Save receipt fields')
    fields(receipts[0], dict(output='quickSavePNG', savedURL=str(path), byteCount=row['savedPNGByteCount']), name+'.Save receipt')
    if retry:
        fields(row, dict(retryControlIdentifier='capture-chain-retry', pinOriginalAndCurrentShareOneAsset=True,
            visibleNativePinCount=1), name)
        pin_id = uuid(row.get('pinID'), 'Pin identity')
        need(set(receipts[1]) == {'output', 'checkedPrivatePasteboard'} and set(receipts[2]) == {'output', 'pinID'},
             'unexpected Copy/Pin receipt fields')
        fields(receipts[1], dict(output='copy', checkedPrivatePasteboard=True), 'Copy receipt')
        fields(receipts[2], dict(output='pin', pinID=pin_id), 'Pin receipt')
        for key in ('copiedPNGComparison', 'publishedPinComparison', 'reloadedPinComparison'):
            comparison(row.get(key), expected_hash, key)
        for key in ('copiedPNGFileSHA256', 'pinPNGFileSHA256', 'reloadedPinPNGFileSHA256'):
            digest(row.get(key), key)
        artifacts(row.get('managerArtifacts'), 'chain-manager')
        artifacts(row.get('resultArtifacts'), 'chain-result')
    else:
        fields(row, dict(committedFilePreservedAfterClose=True), 'Close preservation')
        need(not any(key in row for key in ('pinID', 'copiedPNGComparison', 'publishedPinComparison',
            'reloadedPinComparison', 'retryControlIdentifier', 'resultArtifacts')), 'Close executed a later output')
    return row


def report_fields(report, source):
    need(type(source) is str and re.fullmatch(r'[0-9a-f]{40}', source), 'exact source commit required')
    fields(report, dict(schemaVersion=1, status='passed', sourceCommit=source, installerAcceptance=False,
        source=SOURCE, acquisition=ACQUISITION, realScreenCaptureClaimed=False, screenCaptureAPICalled=False,
        permissionRequested=False, globalInputPosted=False, networkUsed=False, userHistoryReadOrWritten=False,
        standardDefaultsReadOrWritten=False, generalPasteboardReadOrWritten=False, productAppDelegateExercised=True,
        productSaveWorkflowDeliveryExercised=True, productPersistentPinExercised=True,
        canonicalPrivateTemporaryRoot=True, ownershipReleased=True, privateTemporaryRootRemoved=True,
        cleanupSafe=True, limitations=LIMITATIONS), 'fixture')
    need(not any(key in report for key in ('error', 'cleanupError', 'launcherCleanupError')), 'fixture recorded error')
    number(report.get('elapsedSeconds'), 'fixture elapsed', .001, 180)
    for key in ('successOwnershipReleased', 'closeOwnershipReleased'):
        fields(report.get(key), {owner: True for owner in OWNERS}, key)
        need(set(report[key]) == set(OWNERS), key+': unexpected/missing ownership probe')
    reference = report.get('sourceReference')
    fields(reference, dict(width=480, height=320), 'source reference')
    expected_hash = digest(reference.get('canonicalRGBAPixelSHA256'), 'source pixels')
    case_fields(report.get('saveCopyRetryPin'), True, expected_hash)
    case_fields(report.get('closeAfterFailure'), False, expected_hash)
    first, second = report['saveCopyRetryPin'], report['closeAfterFailure']
    need(Path(first['savedPath']).parents[2] == Path(second['savedPath']).parents[2], 'cases use different private roots')
    need(Path(first['savedPath']).parents[2].name.startswith('PicShot-CaptureChain-'), 'unowned private root')


def identity(report, launch, source):
    fields(report, dict(sourceCommit=source, historyDirectoryRemoved=True, independentValidationRequired=True), 'smoke')
    app = absolute(report.get('bundlePath'), 'bundlePath')
    need(app.name == 'PicShot.app', 'wrong bundle')
    executable = app/'Contents/MacOS/PicShot'
    fields(report, dict(executablePath=str(executable), arguments=[str(executable)]), 'smoke executable')
    build = text(report.get('build'), 'build', 32)
    need(re.fullmatch('[1-9][0-9]*', build), 'invalid build identity')
    version = text(report.get('version'), 'version', 32)
    need(re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version), 'invalid version identity')
    fields(launch, dict(schemaVersion=1, status='exited', launcherExitCode=0, callbackReceived=True,
        createsNewApplicationInstance=True, ownedExitConfirmed=True, launchedIdentityMatches=True,
        captureChainDiagnosticOnly=True, liveScrollDiagnosticOnly=False, earlyWitnessOnly=False,
        processStartMemoryCaptured=False, timeoutSeconds=600, selectedAppPath=str(app), launchedAppPath=str(app),
        expectedExecutablePath=str(executable), launchedExecutablePath=str(executable)), 'owned launch')
    need(not any(key in launch for key in ('error', 'interruptedSignal')), 'launch error/interruption')
    integer(launch.get('processIdentifier'), 'owned process', 1)
    number(launch.get('elapsedSeconds'), 'launch elapsed', .001, 600)
    fields(plistlib.loads(COMMON.read(app/'Contents/Info.plist', 1024**2)),
        dict(PicShotSourceCommit=source, CFBundleVersion=build, CFBundleShortVersionString=version,
             CFBundleExecutable='PicShot', CFBundleIdentifier='local.picshot.app'), 'installed plist')
    metadata = COMMON.load(app/'Contents/Resources/build-info.json')
    fields(metadata, dict(app='PicShot', sourceCommit=source, version=version), 'installed build')
    need(metadata.get('architecture') in ('arm64', 'x86_64'), 'missing native architecture')
    return dict(sourceCommit=source, build=build, version=version, architecture=metadata['architecture'],
        bundlePath=str(app), executablePath=str(executable), executableSHA256=COMMON.sha(executable),
        plistSHA256=COMMON.sha(app/'Contents/Info.plist'), buildInfoSHA256=COMMON.sha(app/'Contents/Resources/build-info.json'))


def catalog(row, value):
    need(set(value) == {'version', 'definitions', 'selectedID'}, 'catalog contains runtime data')
    fields(value, dict(version=1), 'catalog')
    need(type(value.get('definitions')) is list and len(value['definitions']) == 1, 'catalog definition count')
    definition = value['definitions'][0]
    need(type(definition) is dict and set(definition) == {'id', 'name', 'source', 'outputs'}, 'definition contains runtime data')
    identifier = uuid(definition.get('id'), 'definition id')
    fields(definition, dict(name='编号截图 · 保存、复制、贴图', source={'kind': 'region'}, outputs=OUTPUTS), 'saved definition')
    fields(value, dict(selectedID=identifier), 'deliberate selection')


def decoded_png(raw, label):
    need(len(raw) >= 33 and raw[:8] == b'\x89PNG\r\n\x1a\n', label+': PNG signature')
    width, height = struct.unpack_from('>II', raw, 16)
    need(0 < width <= 4096 and 0 < height <= 4096 and width*height <= 4_000_000, label+': PNG raster bound')
    result = PNG.png_rgba(raw)
    # Native fixture composites an opaque sRGB image. Requiring opacity keeps
    # raw PNG RGBA identical to canonical premultiplied RGBA without tolerance.
    need(all(alpha == 255 for alpha in result[2][3::4]), label+': native raster is not opaque')
    return result


def validate(report_path, source):
    report_path = Path(report_path)
    root = report_path.parent.resolve()
    need(report_path.name not in ('capture-chain-demo.json', 'capture-chain-receipt.json'), 'smoke and fixture reports must be distinct')
    report = COMMON.load(report_path)
    raw = COMMON.load(root/'capture-chain-demo.json')
    launch_path = root/(report_path.name+'.launcher.json')
    launch = COMMON.load(launch_path)
    report_fields(raw, source)
    report_fields(report, source)
    need(all(key in report and report[key] == value and type(report[key]) is type(value) for key, value in raw.items()),
         'raw fixture and smoke report disagree')
    installed = identity(report, launch, source)
    files = {report_path.name: COMMON.read(report_path), 'capture-chain-demo.json': COMMON.read(root/'capture-chain-demo.json'),
             launch_path.name: COMMON.read(launch_path)}

    def read(name, limit=MAX_FILE):
        need(Path(name).name == name and name not in files, 'unsafe or duplicate evidence name')
        value = COMMON.read(root/name, limit)
        files[name] = value
        need(len(files) <= 40 and sum(map(len, files.values())) <= MAX_TOTAL, 'evidence exceeds aggregate bound')
        return value

    source_image = decoded_png(read('chain-source-numbered.png'), 'source')
    need(source_image[:2] == (480, 320), 'source PNG extent differs')
    pixel_hash = hashlib.sha256(source_image[2]).hexdigest()
    need(pixel_hash == raw['sourceReference']['canonicalRGBAPixelSHA256'], 'source PNG pixels do not match report')
    pairs = [('saveCopyRetryPin', 'chain-saved.png', 'savedPNGFileSHA256'),
             ('saveCopyRetryPin', 'chain-copied.png', 'copiedPNGFileSHA256'),
             ('saveCopyRetryPin', 'chain-pin.png', 'pinPNGFileSHA256'),
             ('saveCopyRetryPin', 'chain-pin-reloaded.png', 'reloadedPinPNGFileSHA256'),
             ('closeAfterFailure', 'chain-close-saved.png', 'savedPNGFileSHA256')]
    for case_name, name, hash_key in pairs:
        case = raw[case_name]
        data = read(name)
        need(hashlib.sha256(data).hexdigest() == case[hash_key], name+': physical file hash differs')
        if hash_key == 'savedPNGFileSHA256':
            need(len(data) == case['savedPNGByteCount'] == case['receipts'][0]['byteCount'], name+': Save receipt bytes differ')
        need(decoded_png(data, name) == source_image, name+': independently decoded exact pixels differ')
    for case_name, filename in [('saveCopyRetryPin', 'chain-catalog.json'), ('closeAfterFailure', 'chain-close-catalog.json')]:
        data = read(filename, 128*1024)
        need(hashlib.sha256(data).hexdigest() == raw[case_name]['catalogBeforeSHA256']
             == raw[case_name]['catalogAfterSHA256'], 'catalog physical bytes changed')
        catalog(raw[case_name], COMMON.load(root/filename))
    for case_name, keys in [('saveCopyRetryPin', ('managerArtifacts', 'failureArtifacts', 'resultArtifacts')),
                           ('closeAfterFailure', ('failureArtifacts',))]:
        for key in keys:
            actual_images = []
            for artifact in raw[case_name][key]:
                name = artifact['filename']
                data = read(name)
                image = decoded_png(data, name)
                need(image[:2] == (artifact['width'], artifact['height']), name+': PNG/layout extent mismatch')
                need(hashlib.sha256(image[2]).hexdigest() == artifact['canonicalRGBAPixelSHA256'], name+': native pixel digest differs')
                layout_name = name[:-4]+'-layout.json'
                read(layout_name, 1024**2)
                need(COMMON.load(root/layout_name) == artifact, 'persisted raw layout differs')
                actual_images.append(image)
            need(actual_images[0] != actual_images[1], 'decoded native light/dark PNGs are identical')
    return dict(schemaVersion=1, status='passed', sourceIdentity=installed,
        installerAcceptance=False, realScreenCaptureAcceptance=False, memoryQualification=False,
        exactDecodedOutputPixels=True, savedReceiptPhysicalBytesVerified=True,
        unchangedMetadataOnlyCatalogVerified=True, nativeOwnedActionRoute=ROUTE,
        scope='Installed native controls and output recipients with injected acquisition; bounded ownership observations only',
        evidenceSHA256={name: hashlib.sha256(data).hexdigest() for name, data in sorted(files.items())})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--source', required=True)
    args = parser.parse_args()
    result = validate(args.report, args.source)
    path = args.report.parent/'capture-chain-receipt.json'
    need(not path.is_symlink(), 'receipt destination is symlinked')
    COMMON.save(path, result)
    print(json.dumps(dict(status=result['status'], sourceCommit=args.source, receipt=str(path))))


if __name__ == '__main__':
    main()
