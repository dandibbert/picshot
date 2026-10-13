#!/usr/bin/env python3
"""Read bounded current-long-image → saved text-script evidence.

Portable synthetic inputs test this reader; they are never installed execution
proof. The optional proof/root pair binds the genuine enclosing text-script
launcher and production package. Standalone child input makes no such claim.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import stat
import struct


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


T = module('current_long_image_text_reader', 'check-text-script-demo.py')
L = module('current_long_image_png_reader', 'check-live-scroll-chain-demo.py')
C = T.C
need, fields, number = C.need, C.fields, C.number
integer, text, digest, uuid = C.integer, C.text, C.digest, C.uuid
exact_keys = T.exact_keys
EXPECTED = T.EXPECTED
WIDTH, HEIGHT = 720, 1056
OFFSETS = [0, 144, 288, 432, 528, 576]
FRONTIER = dict(width=720, acceptedHeight=1056, committedHeight=1008, committedLowerBound=0,
    committedUpperBound=1008, viewportOffset=576, viewportLength=480, pendingPixelRows=48,
    previewIsTransient=True, committedSources=5, acceptedObservations=6)
MAX_FILE, MAX_TOTAL = 16 * 1024**2, 96 * 1024**2
RAW_NAME = 'live-scroll-text-script.json'
RECEIPT_NAME = 'live-scroll-text-script-receipt.json'

# Authored producer constants, never report-defined scope or expected output.
NAME = '提取长图工单编号'
SOURCE_BODY = 'const ids = text.match(/\\b[A-Z]{2,8}-\\d+\\b/g) || []; return [...new Set(ids)].join("\\n");'
SCOPE = 'Installed current-long-image/saved-script/Apple-Vision/signed-helper/checked-private-Copy witness over generated acquisition'
LIMITATIONS = ['Owned acquisition does not prove desktop selection, ScreenCaptureKit, TCC or third-party scrolling',
    'First checked private clipboard write is deliberately rejected',
    'Native images cache owned content only; no desktop screenshot',
    T.LIMITATIONS[-1]]
OWNERS = ('app', 'session', 'manager', 'runner', 'renderedImage', 'runtime', 'provider')
LIMITS = dict(maximumRasterPixels=32_000_000, sourceBytes=16*1024, inputUTF16Units=32768,
    outputUTF16Units=32768, outputUTF8Bytes=128*1024, helperAcceptanceSeconds=3,
    sampledResidentLimitBytes=256*1024**2, ownerDrainSeconds=5, ocrHelperWaitSeconds=25, maximumUIPhases=3)
TOP_FIXED = dict(schemaVersion=1, status='passed', scope=SCOPE, source=L.SOURCE,
    acquisition='LiveScrollVerificationFrameSource; actual AppDelegate, live session, assembler and prepared text runner',
    installerAcceptance=False, original227MemoryAcceptance=False, hardMemoryCapClaimed=False,
    realScreenCaptureClaimed=False, screenCaptureAPICalled=False, permissionRequested=False,
    networkUsed=False, globalInputPosted=False, userHistoryReadOrWritten=False,
    standardDefaultsReadOrWritten=False, generalPasteboardReadOrWritten=False,
    runtimeGateBuild=False, transportFixtureUsed=False, limitations=LIMITATIONS,
    generatedExpectedOutput=EXPECTED, productAppDelegateExercised=True,
    productSessionControllerExercised=True, productSessionClosed=True, realAppleVisionRan=True,
    productionHelperRan=True, canonicalPrivateTemporaryRoot=True, ownershipReleased=True,
    privateTemporaryRootRemoved=True, finalVisionActiveJobs=0, finalVisionWaitingJobs=0,
    finalHelperAdmissionOccupied=False, cleanupSafe=True)
CASE_FIXED = dict(status='passed', case='copyRetry', viewportOffsets=OFFSETS,
    actionRoute='Production More NSApp.sendAction; owned native chooser Run/Retry/Close mouseDown with queued mouseUp',
    copyRejectionInjectedAtCheckedWriter=True, recognitionLanguage='en-US', savedDefinitionReloaded=True,
    finalAcceptedWidth=WIDTH, finalAcceptedHeight=HEIGHT, noOutputOnSelection=True,
    failurePhase='copy', failureCode='clipboardRejected', failureReceiptCount=0, failureReceipts=[],
    failedRetainedTextBytes=len(EXPECTED.encode()), failedImageReleased=True, providerStagingReleased=True,
    rejectedPasteboardEmpty=True, paused=True, nonAuto=True, textRenderCount=1,
    isExistingScrollImage=True, isTextScript=True, generatedActualOutput=EXPECTED,
    receiptCharacterCount=len(EXPECTED), committedReceiptCount=1,
    receipts=[dict(kind='textCopy', characterCount=len(EXPECTED))], copiedTextBytes=len(EXPECTED.encode()),
    cacheRetry=True, sourceProviderStayedPaused=True, finalRetainedBytes=0, finalRetainedTextBytes=0,
    terminalStatus='completed', catalogDefinitionsOnly=True, isolatedDefaultsUnchanged=True,
    historyUnchanged=True, chainCatalogUnchanged=True, noEditorHistoryOrPinOutput=True,
    productSessionClosed=True, spoolDirectoryEmpty=True, visionJobsDrained=True,
    helperAdmissionDrained=True, privatePasteboardReleased=True, isolatedDefaultsRemoved=True,
    cleanupSafe=True, recognitionTruncated=False, comparedBeforeOCR=True, savedDefinitionFrozen=True)
PHASES = {
    'choice': {'scroll.live.textScript.sheet.title':'使用文字脚本处理当前长图',
        'scroll.live.textScript.sheet.description':'来源：本次长截图。识别后执行所选文字脚本，并复制处理后的文字。',
        'scroll.live.textScript.choice':'1. '+NAME, 'scroll.live.textScript.choice.name':NAME,
        'scroll.live.textScript.choice.outputs':'本机文字识别 → 文字脚本 → 复制文字',
        'scroll.live.textScript.run':'处理当前长图', 'scroll.live.textScript.choice.cancel':'取消'},
    'failure': {'capture-chain-close':'关闭', 'capture-chain-retry':'重试未完成操作',
        'capture-chain-run-status':NAME+' · 操作未完成：无法将文字写入剪贴板，请重试。 · 来源：本次长截图',
        'capture-chain-receipt-0':'复制失败；重试只复制已准备好的文字，不会重新识别当前长图或执行脚本。'},
    'result': {'capture-chain-close':'关闭', 'capture-chain-run-status':NAME+' · 全部完成 · 来源：本次长截图',
        'capture-chain-receipt-0':'已复制文字到剪贴板（15 个字符）'}}
ACTIONS = [dict(index=index, action=action, identifier=identifier, route=route)
    for index,(action,identifier,route) in enumerate([
        ('more-open-choice','scroll.live.textScript','NSApp.sendAction on production More menu item'),
        ('select-saved-definition','scroll.live.textScript.choice','NSPopUpButton.selectItem; no output command'),
        ('run-current-long-image','scroll.live.textScript.run',C.ROUTE.split('; ')[0]),
        ('retry-copy','capture-chain-retry',C.ROUTE.split('; ')[0]),
        ('close-result','capture-chain-close',C.ROUTE.split('; ')[0])])]

EVIDENCE_FILES = tuple(sorted([RAW_NAME,
    'scroll-text-script-owned-numbered.png', 'scroll-text-script-accepted.png',
    'scroll-text-script-source.js', 'scroll-text-script-ocr.txt', 'scroll-text-script-copied.txt',
    'scroll-text-script-catalog.json', 'scroll-text-script-case.json', 'scroll-text-script-actions.json'] +
    ['scroll-text-script-'+phase+'-'+mode+suffix for phase in PHASES for mode in ('light','dark')
     for suffix in ('.png','-layout.json')]))

ARTIFACT_KEYS = {'filename', 'appearance', 'width', 'height', 'canonicalRGBAPixelSHA256', 'layout'}
LAYOUT_KEYS = {'phase', 'passed', 'windowVisible', 'windowNumber', 'windowFrame', 'screenFrame',
               'contentBounds', 'controls', 'violations', 'fullNativeFramesMeasured', 'alignmentRectanglesSubstituted'}
CONTROL_KEYS = {'id', 'class', 'kind', 'viewPath', 'ancestorIDs', 'ownerWindowNumber', 'owned', 'fullFrame',
                'screenFrame', 'hidden', 'enabled', 'insideViewport', 'text', 'tooltip', 'accessibilityValue', 'accessibilityLabel'}
VISIBLE_KEYS = {'contained', 'cellSize', 'wrappedSize', 'textFits'}
FIELD_KEYS = {'wraps', 'editableScrollable', 'alignmentWidth', 'nameAlternative', 'truncates', 'accessibleAlternative', 'fontSize'}
RECT_KEYS = {'x', 'y', 'width', 'height'}
# The retained image-chain manager remains in the progress window's owned view
# tree. Its region-capture guidance must stay hidden throughout this text route.
GUIDANCE_ID = 'capture-chain-guidance'
GUIDANCE_TEXT = '一次截图，按顺序执行 1–3 个操作；仅在本机保存定义。'
GUIDANCE_FIELDS = {'id':GUIDANCE_ID, 'class':'NSTextField', 'kind':'field', 'hidden':True,
    'enabled':True, 'insideViewport':True, 'text':GUIDANCE_TEXT, 'tooltip':'',
    'accessibilityValue':GUIDANCE_TEXT, 'accessibilityLabel':''}
CONTROL_IDS = set(PHASES['choice']) | {'capture-chain-'+name for name in (
    'name','source','list','create','save','discard','delete','select','run','retry','cancel','close',
    'manage','result','text-scripts','current','status','run-status','receipt-0')}
CONTROL_IDS |= {'capture-chain-'+action+'-'+output for action in ('output','up','down')
               for output in ('quickSavePNG','copy','pin')}


def rect(value, label, empty=False):
    exact_keys(value, RECT_KEYS, label)
    return C.rectangle(value, label, empty=empty)


def image_reference(value, label):
    exact_keys(value, ('width', 'height', 'canonicalRGBAPixelSHA256'), label)
    fields(value, dict(width=WIDTH, height=HEIGHT), label)
    return digest(value['canonicalRGBAPixelSHA256'], label+'.pixels')


def layout(artifact, phase):
    """Use the existing native frame, fit and ancestry predicates unchanged."""
    value = artifact.get('layout')
    exact_keys(value, LAYOUT_KEYS, 'native layout')
    fields(value, dict(phase='scroll-text-script-'+phase, passed=True, windowVisible=True, violations=[],
        fullNativeFramesMeasured=True, alignmentRectanglesSubstituted=False), 'native layout')
    window_id = integer(value['windowNumber'], 'owned window', 1)
    window = rect(value['windowFrame'], 'window')
    screen = rect(value['screenFrame'], 'screen')
    bounds = rect(value['contentBounds'], 'content')
    need(C.contains(screen, window), 'owned native window offscreen')
    need(bounds == (0, 0, artifact['width'], artifact['height']), 'native PNG omits content')
    rows = value['controls']
    need(type(rows) is list and 3 <= len(rows) <= 160, 'bounded native control census')
    by_id, paths, leaves = {}, {}, []
    classes = {'button': {'NSButton', 'NSPopUpButton', 'CaptureChainRunButton', 'TextScriptRunButton'},
               'field': {'NSTextField', 'NSButtonTextField'}, 'table': {'NSTableView'}, 'other': {'NSScroller'}}
    for row in rows:
        need(type(row) is dict, 'invalid native control')
        identifier = text(row.get('id'), 'native ID', 128)
        need(identifier not in by_id, 'duplicate native ID')
        by_id[identifier] = row
        kind = row.get('kind')
        need(kind in classes and row.get('class') in classes[kind], 'unknown/forged native kind')
        if identifier == GUIDANCE_ID:
            need(phase in ('failure', 'result'), 'retained manager guidance is outside its progress phase')
            fields(row, GUIDANCE_FIELDS, 'hidden retained manager guidance')
        else:
            need(identifier in CONTROL_IDS or re.fullmatch('native-[0-9]+', identifier), 'foreign or unknown native identifier')
        hidden = C.boolean(row, 'hidden', identifier)
        C.boolean(row, 'enabled', identifier)
        visible = C.boolean(row, 'insideViewport', identifier)
        expected_keys = CONTROL_KEYS | (VISIBLE_KEYS if not hidden and visible and kind in ('button', 'field') else set())
        if not hidden and visible:
            if kind == 'button': expected_keys |= {'hitTest'}
            if kind == 'field': expected_keys |= FIELD_KEYS
        exact_keys(row, expected_keys, identifier)
        path = row['viewPath']
        need(type(path) is list and 1 <= len(path) <= 32, 'native view path absent')
        for part in path: integer(part, 'view path', 0, 4096)
        need(tuple(path) not in paths.values(), 'duplicate view path')
        paths[identifier] = tuple(path)
        fields(row, dict(ownerWindowNumber=window_id, owned=True), 'owned native view')
        frame = rect(row['fullFrame'], identifier, empty=hidden or not visible)
        on_screen = rect(row['screenFrame'], identifier+'.screen', empty=hidden or not visible)
        need(frame[2:] == on_screen[2:], 'native screen dimensions differ')
        for key in ('text', 'tooltip', 'accessibilityValue', 'accessibilityLabel'):
            text(row[key], identifier+'.'+key, 16384, nonempty=False)
        if hidden or not visible or kind not in ('button', 'field'): continue
        fields(row, dict(contained=True), identifier)
        need(C.contains(bounds, frame) and C.contains(window, on_screen) and C.contains(screen, on_screen), 'full native frame clipped')
        cell, wrapped = C.pair(row['cellSize'], 'untruncated cell'), C.pair(row['wrappedSize'], 'wrapped cell')
        fits = C.boolean(row, 'textFits', identifier)
        if kind == 'button':
            fields(row, dict(hitTest=True, textFits=True), identifier)
            need(frame[2]+.5 >= cell[0] and frame[3]+.5 >= cell[1], 'button text clipped')
        else:
            wraps = C.boolean(row, 'wraps', identifier)
            actual_fit = wrapped[1] <= frame[3]+.5 and (wraps or cell[0] <= frame[2]+.5)
            need(fits == actual_fit, 'text fit differs from raw native metrics')
            C.boolean(row, 'editableScrollable', identifier)
            number(row['alignmentWidth'], 'alignment width', 0, frame[2]+.5)
            fields(row, dict(nameAlternative=False), 'no editor name alternative')
            truncates = C.boolean(row, 'truncates', identifier)
            accessible = C.boolean(row, 'accessibleAlternative', identifier)
            if row['text']:
                need(accessible == (row['tooltip'] == row['text'] and row['text'] in (row['accessibilityValue'], row['accessibilityLabel'])), 'forged accessible text alternative')
            number(row['fontSize'], 'native font', 11, 96)
            need(not row['text'] or fits or (truncates and accessible and row['tooltip'] == row['text']), 'native text unreadable')
        leaves.append((identifier, frame))
    ancestry = {}
    for identifier, row in by_id.items():
        path = paths[identifier]
        parents = sorted((other for other in paths if len(paths[other]) < len(path) and path[:len(paths[other])] == paths[other]), key=lambda other: len(paths[other]), reverse=True)
        need(row['ancestorIDs'] == parents, 'forged native ancestry')
        if not identifier.startswith('native-'): need(not parents, 'product control forged as native descendant')
        if parents:
            owner = by_id[parents[0]]
            need(row['kind'] == 'field' and owner['kind'] in ('button', 'table'), 'unsupported native descendant')
            need(not owner['hidden'] or row['hidden'], 'visible child of hidden native control')
            if owner['kind'] == 'button':
                need(row['text'] == owner['text'], 'native title differs from owning button')
                if not row['hidden'] and row['insideViewport']: need(row['textFits'], 'button title child clipped')
        elif row['class'] == 'NSButtonTextField': need(False, 'unowned private title control')
        ancestry[identifier] = set(parents)
    C.check_control_overlap(leaves, ancestry)
    if phase in ('failure', 'result'):
        fields(by_id.get(GUIDANCE_ID), GUIDANCE_FIELDS, 'required hidden retained manager guidance')
    for identifier, expected_text in PHASES[phase].items():
        row = by_id.get(identifier)
        is_field = identifier.endswith(('.title', '.description', '.name', '.outputs', '-status')) or '-receipt-' in identifier
        expected_kind = 'field' if is_field else 'button'
        expected_class = 'NSTextField' if is_field else 'NSPopUpButton' if identifier.endswith('.choice') else 'NSButton'
        fields(row, {'hidden':False, 'insideViewport':True, 'text':expected_text,
                     'kind':expected_kind, 'class':expected_class}, identifier)
        if row['kind'] == 'button': fields(row, dict(enabled=True, hitTest=True), identifier)
        else:
            need(row['tooltip'] == expected_text and expected_text in (row['accessibilityValue'], row['accessibilityLabel']), 'visible text lacks full accessible alternative')
            if phase == 'choice' and not identifier.endswith('.description'): fields(row, dict(textFits=True), identifier)
    if phase == 'choice':
        fields(artifact, dict(width=460), 'owned chooser width')
        fields(by_id['scroll.live.textScript.choice'],
            dict(tooltip=NAME+' · '+PHASES['choice']['scroll.live.textScript.choice.outputs'],
                 accessibilityValue=NAME+' · '+PHASES['choice']['scroll.live.textScript.choice.outputs']), 'saved script summary')
    return by_id


def artifacts(rows, phase):
    need(type(rows) is list and len(rows) == 2, 'light and dark native artifacts required')
    hashes = []
    for artifact, mode in zip(rows, ('light', 'dark')):
        exact_keys(artifact, ARTIFACT_KEYS, phase+' artifact')
        fields(artifact, dict(filename='scroll-text-script-'+phase+'-'+mode+'.png', appearance=mode), phase)
        width, height = integer(artifact['width'], 'image width', 1, 4096), integer(artifact['height'], 'image height', 1, 4096)
        need(width*height <= 4_000_000, 'owned image bound')
        hashes.append(digest(artifact['canonicalRGBAPixelSHA256'], 'native pixels'))
        layout(artifact, phase)
    need(hashes[0] != hashes[1], 'identical native appearances')


def png(raw, label, ui=False):
    # Keep the shared bounded decoder's formats/CRC/filter/alpha predicates.
    # Reject unsupported critical semantics instead of letting a decoder silently
    # ignore them (including RGB/gray tRNS transparency and animated PNG frames).
    need(33 <= len(raw) <= MAX_FILE and raw[:8] == b'\x89PNG\r\n\x1a\n', label+': PNG signature/bound')
    offset, seen_idat, ended_idat = 8, False, False
    while offset < len(raw):
        need(offset+12 <= len(raw), label+': truncated chunk')
        size = struct.unpack_from('>I', raw, offset)[0]
        kind = raw[offset+4:offset+8]
        need(offset+12+size <= len(raw), label+': truncated chunk data')
        need(re.fullmatch(b'[A-Za-z]{4}', kind) and not kind[2] & 32, label+': invalid PNG chunk kind')
        need(kind not in (b'tRNS', b'acTL', b'fcTL', b'fdAT'), label+': unsupported PNG semantics')
        need(kind[0] & 32 or kind in (b'IHDR', b'IDAT', b'IEND'), label+': unknown critical PNG chunk')
        if kind == b'IDAT':
            need(not ended_idat, label+': noncontiguous image data')
            seen_idat = True
        elif seen_idat: ended_idat = True
        offset += 12+size
    need(seen_idat, label+': absent image data')
    return L.native_ui_png(raw, label) if ui else C.decoded_png(raw, label)


def same(actual, expected):
    """Preserved raw JSON cannot substitute Boolean values for integer counters."""
    if type(actual) is not type(expected): return False
    if type(expected) is dict:
        return actual.keys() == expected.keys() and all(same(actual[k], v) for k, v in expected.items())
    if type(expected) is list:
        return len(actual) == len(expected) and all(same(a, b) for a, b in zip(actual, expected))
    return actual == expected



def contract(report, source):
    need(type(source) is str and re.fullmatch('[0-9a-f]{40}', source), 'exact source commit required')
    exact_keys(report, set(TOP_FIXED) | {'sourceCommit', 'limits', 'sourceReference', 'sourcePNGFileSHA256',
        'ownership', 'elapsedSeconds', 'copyRetry'}, 'current-long-image report')
    fields(report, TOP_FIXED, 'current-long-image report')
    fields(report, dict(sourceCommit=source), 'child source identity')
    exact_keys(report['limits'], LIMITS, 'bounded limits')
    for key,expected in LIMITS.items():
        if key == 'helperAcceptanceSeconds': need(number(report['limits'][key], key) == expected, 'helper acceptance bound changed')
        else: fields(report['limits'], {key:expected}, 'fixed limit')
    exact_keys(report['ownership'], OWNERS, 'weak owners')
    fields(report['ownership'], {key:True for key in OWNERS}, 'weak owner release')
    number(report['elapsedSeconds'], 'bounded witness elapsed', .001, 180)
    expected_pixels = image_reference(report['sourceReference'], 'source reference')
    digest(report['sourcePNGFileSHA256'], 'source file')
    case = report['copyRetry']
    dynamic = {'definitionID', 'requestID', 'runID', 'catalogBeforeSHA256', 'catalogAfterSHA256',
        'isolatedDefaultsBeforeSHA256', 'isolatedDefaultsAfterSHA256', 'generatedActualOCR',
        'ocrTextSHA256', 'ocrTextBytes', 'helperMetrics', 'acceptedImageReference', 'acceptedPNGFileSHA256',
        'sourceImageComparison', 'failureAttempts', 'attempts', 'viewportTrace', 'actionTrace',
        'sourceProviderCallsAtFailure', 'sourceProviderCallsAfterRetry', 'copiedTextSHA256', 'preRunFrontier'}
    exact_keys(case, set(CASE_FIXED) | dynamic | {phase+'Artifacts' for phase in PHASES}, 'current-long-image case')
    fields(case, CASE_FIXED, 'current-long-image case')
    need(same(case['viewportOffsets'], OFFSETS), 'viewport offset types differ')
    exact_keys(case['preRunFrontier'], FRONTIER, 'pre-run final frontier')
    fields(case['preRunFrontier'], FRONTIER, 'pre-run final frontier')
    # Nested receipt values need exact types, including the integer character count.
    need(same(case['receipts'], CASE_FIXED['receipts']), 'text Copy receipt differs')
    for key in ('definitionID', 'requestID', 'runID'): uuid(case[key], key)
    need(len({case[key].lower() for key in ('definitionID', 'requestID', 'runID')}) == 3, 'definition/run/request identity reused')
    for before,after,label in [('catalogBeforeSHA256','catalogAfterSHA256','saved catalog'),
                               ('isolatedDefaultsBeforeSHA256','isolatedDefaultsAfterSHA256','isolated defaults')]:
        need(digest(case[before], label+' before') == digest(case[after], label+' after'), label+' changed')
    for key,copy_count,committed in [('failureAttempts',1,0),('attempts',2,1)]:
        expected = dict(capture=0, ocr=1, transform=1, copy=copy_count, committedCopy=committed)
        exact_keys(case[key], expected, key); fields(case[key], expected, key)
    provider_calls = integer(case['sourceProviderCallsAtFailure'], 'source provider calls', 1, 10_000)
    need(integer(case['sourceProviderCallsAfterRetry'], 'source calls after retry', 1, 10_000) == provider_calls,
         'source provider acquired after failure')
    trace = case['viewportTrace']
    need(type(trace) is list and len(trace) == len(OFFSETS), 'viewport frontier trace absent')
    previous = 0
    for row,offset in zip(trace, OFFSETS):
        exact_keys(row, ('offset','height','acceptedObservations'), 'viewport row')
        fields(row, dict(offset=offset, height=480+offset), 'viewport frontier')
        previous = integer(row['acceptedObservations'], 'accepted observation progress', previous+1, 6)
    need(previous == case['preRunFrontier']['acceptedObservations'], 'final frontier observation count differs')
    need(type(case['actionTrace']) is list and len(case['actionTrace']) == len(ACTIONS), 'action trace absent')
    for row,expected in zip(case['actionTrace'], ACTIONS):
        exact_keys(row, expected, 'owned action'); fields(row, expected, 'owned action')
    need(image_reference(case['acceptedImageReference'], 'accepted reference') == expected_pixels, 'accepted frontier hash differs')
    digest(case['acceptedPNGFileSHA256'], 'accepted file')
    comparison = dict(passed=True, dimensionsMatch=True, exactCanonicalRGBAEquality=True,
        width=WIDTH, height=HEIGHT, expectedWidth=WIDTH, expectedHeight=HEIGHT,
        outputPixelSHA256=expected_pixels, sourcePixelSHA256=expected_pixels, method=C.COMPARISON)
    exact_keys(case['sourceImageComparison'], comparison, 'full source comparison')
    fields(case['sourceImageComparison'], comparison, 'full source comparison')
    ocr = text(case['generatedActualOCR'], 'generated OCR', 128*1024)
    need(len(ocr.encode('utf-16-le'))//2 <= 32768, 'OCR UTF16 bound exceeded')
    ids = re.findall(r'\b[A-Z]{2,8}-\d+\b', ocr, flags=re.ASCII)
    need('\n'.join(dict.fromkeys(ids)) == EXPECTED, 'authored OCR identifiers/order differ from exact saved-script output')
    fields(case, dict(ocrTextSHA256=hashlib.sha256(ocr.encode()).hexdigest(), ocrTextBytes=len(ocr.encode()),
        copiedTextSHA256=hashlib.sha256(EXPECTED.encode()).hexdigest()), 'generated text bytes')
    helpers = case['helperMetrics']
    need(type(helpers) is list and len(helpers) == 1, 'exactly one helper execution required')
    T.metrics(helpers[0], case['requestID'])
    for phase in PHASES: artifacts(case[phase+'Artifacts'], phase)
    return case


# The legacy producer has a stable outer envelope; its two case schemas stay
# owned by its existing reader. Only the additive child is accepted here.
OUTER_KEYS = set('canonicalPrivateTemporaryRoot cleanupSafe closeAfterFailure closeOwnershipReleased copyRetry elapsedSeconds finalHelperAdmissionOccupied finalVisionActiveJobs finalVisionWaitingJobs generalPasteboardReadOrWritten generatedExpectedOutput globalInputPosted hardMemoryCapClaimed installerAcceptance limitations networkUsed original227MemoryAcceptance ownershipReleased permissionRequested privateTemporaryRootRemoved productAppDelegateExercised productionHelperRan realAppleVisionRan realScreenCaptureClaimed runtimeGateBuild schemaVersion scope screenCaptureAPICalled sourceCommit sourceReference standardDefaultsReadOrWritten status successOwnershipReleased transportFixtureUsed userHistoryReadOrWritten currentLongImage'.split())
INSTALLED_KEYS = set('version build bundlePath executablePath arguments independentValidationRequired historyDirectoryRemoved'.split())
LAUNCH_KEYS = set('schemaVersion status launcherExitCode selectedAppPath createsNewApplicationInstance timeoutSeconds elapsedSeconds callbackReceived ownedExitConfirmed processStartMemoryCaptured scope earlyWitnessOnly liveScrollDiagnosticOnly captureChainDiagnosticOnly textScriptDiagnosticOnly expectedExecutablePath launchedIdentityMatches processIdentifier launchedAppPath launchedExecutablePath'.split())
LAUNCH_SCOPE = 'LaunchServices-owned application lifecycle only; no child memory read and no application exit-code inference'

def validate(report_path, source, package_proof=None, source_root=None):
    path = Path(report_path)
    need((package_proof is None) == (source_root is None), 'package proof and source root are required together')
    installed, package = None, None
    files = {}
    def read(path, name, limit=MAX_FILE):
        need(name not in files, 'duplicate evidence name')
        raw = C.COMMON.read(path, limit)
        files[name] = raw
        need(len(files) <= 48 and sum(map(len, files.values())) <= MAX_TOTAL, 'evidence aggregate bound')
        return raw
    if package_proof is not None:
        need(path.name not in (RAW_NAME, RECEIPT_NAME, 'text-script-demo.json', 'text-script-receipt.json'), 'installed wrapper required')
        outer = C.COMMON.load(path)
        raw_outer_path = path.parent/'text-script-demo.json'
        raw_outer = C.COMMON.load(raw_outer_path)
        exact_keys(raw_outer, OUTER_KEYS, 'raw enclosing text-script report')
        exact_keys(outer, OUTER_KEYS | INSTALLED_KEYS, 'installed enclosing text-script report')
        T.report_fields(raw_outer, source); T.report_fields(outer, source)
        need(all(k in outer and same(outer[k], v) for k, v in raw_outer.items()), 'raw and installed text-script reports differ')
        launch_path = path.with_name(path.name+'.launcher.json')
        launch = C.COMMON.load(launch_path)
        exact_keys(launch, LAUNCH_KEYS, 'owned launcher report')
        fields(launch, dict(scope=LAUNCH_SCOPE), 'owned launcher scope')
        package = C.COMMON.load(Path(package_proof))
        installed = T.identity(outer, launch, package, source, source_root)
        inventory = {row['path'] for row in package['sources']}
        need(REQUIRED_SOURCES <= inventory, 'current-long-image source identity incomplete')
        read(path, path.name)
        read(raw_outer_path, raw_outer_path.name)
        read(launch_path, launch_path.name)
        read(Path(package_proof), 'package-proof')
        child_path = path.parent/'current-long-image'/RAW_NAME
        need(child_path.parent.resolve() == path.parent.resolve()/'current-long-image', 'child evidence directory is symlinked')
        child = C.COMMON.load(child_path)
        need(same(outer.get('currentLongImage'), child), 'raw child and installed currentLongImage differ')
        path, prefix = child_path, 'current-long-image/'
    else:
        need(path.name == RAW_NAME, 'standalone raw child report required')
        child, prefix = C.COMMON.load(path), ''
    read(path, prefix+path.name)
    case = contract(child, source)
    if package is not None:
        for old_key in ('copyRetry', 'closeAfterFailure'):
            need(case['requestID'].lower() != outer[old_key]['requestID'].lower(), 'legacy helper request identity reused')
            need(case['definitionID'].lower() != outer[old_key]['definitionID'].lower(), 'legacy catalog identity reused')
        fields(case['helperMetrics'][0]['signature'], dict(helperCDHash=package['helper']['cdHash']), 'current-long-image runtime helper bound to package')
    root = path.parent
    actual = {entry.name:entry for entry in root.iterdir()}
    need(set(EVIDENCE_FILES) <= set(actual) <= set(EVIDENCE_FILES) | {RECEIPT_NAME}, 'missing or unknown physical evidence file')
    for entry in actual.values():
        need(not entry.is_symlink() and stat.S_ISREG(entry.stat().st_mode) and entry.stat().st_nlink == 1,
             'evidence is not an owned regular file')
        need(0 < entry.stat().st_size <= MAX_FILE, 'physical evidence file bound')
    need(sum(entry.stat().st_size for entry in actual.values()) <= MAX_TOTAL, 'physical evidence aggregate bound')
    def evidence(name, limit=MAX_FILE):
        need(Path(name).name == name and name not in ('', '.', '..'), 'unsafe evidence name')
        return read(root/name, prefix+name, limit)
    source_bytes = evidence('scroll-text-script-owned-numbered.png')
    need(hashlib.sha256(source_bytes).hexdigest() == child['sourcePNGFileSHA256'], 'physical source PNG digest differs')
    source_image = png(source_bytes, 'source')
    need(source_image[:2] == (WIDTH, HEIGHT) and hashlib.sha256(source_image[2]).hexdigest() == child['sourceReference']['canonicalRGBAPixelSHA256'], 'independently decoded source pixels differ')
    accepted_bytes = evidence('scroll-text-script-accepted.png')
    need(hashlib.sha256(accepted_bytes).hexdigest() == case['acceptedPNGFileSHA256'], 'physical accepted PNG digest differs')
    need(png(accepted_bytes, 'accepted') == source_image, 'independently decoded full final frontier pixels differ')
    need(evidence('scroll-text-script-source.js', 128*1024) == SOURCE_BODY.encode(), 'physical saved script source differs')
    need(evidence('scroll-text-script-ocr.txt', 128*1024) == case['generatedActualOCR'].encode(), 'physical generated OCR differs')
    need(evidence('scroll-text-script-copied.txt', 128*1024) == EXPECTED.encode(), 'physical checked Copy differs')
    catalog_bytes = evidence('scroll-text-script-catalog.json', 128*1024)
    need(hashlib.sha256(catalog_bytes).hexdigest() == case['catalogBeforeSHA256'] == case['catalogAfterSHA256'], 'saved catalog physical bytes differ')
    catalog = C.COMMON.load(root/'scroll-text-script-catalog.json')
    exact_keys(catalog, ('version', 'selectedID', 'definitions'), 'catalog')
    fields(catalog, dict(version=1, selectedID=case['definitionID']), 'catalog')
    need(same(catalog['definitions'], [dict(id=case['definitionID'], name=NAME, source=SOURCE_BODY)]), 'saved catalog source/identity differs or contains runtime payload')
    evidence('scroll-text-script-case.json', 2*1024**2)
    need(same(C.COMMON.load(root/'scroll-text-script-case.json'), case), 'preserved raw case differs')
    evidence('scroll-text-script-actions.json', 128*1024)
    need(same(C.COMMON.load(root/'scroll-text-script-actions.json'), dict(actionTrace=case['actionTrace'], failureReceipts=case['failureReceipts'], receipts=case['receipts'])), 'preserved raw action trace differs')
    for phase in PHASES:
        images = []
        for artifact in case[phase+'Artifacts']:
            filename = artifact['filename']
            pixels = png(evidence(filename), filename, ui=True)
            need(pixels[:2] == (artifact['width'], artifact['height']) and hashlib.sha256(pixels[2]).hexdigest() == artifact['canonicalRGBAPixelSHA256'], 'physical native PNG/layout differs')
            layout_name = filename[:-4]+'-layout.json'
            evidence(layout_name, 2*1024**2)
            need(same(C.COMMON.load(root/layout_name), artifact), 'persisted raw native layout differs')
            images.append(pixels)
        need(images[0] != images[1], 'physical native appearances identical')
    need({name[len(prefix):] for name in files if name.startswith(prefix)} == set(EVIDENCE_FILES), 'physical evidence inventory differs')
    result = dict(schemaVersion=1, status='passed', sourceCommit=source, scope=SCOPE,
        installerAcceptance=False, realScreenCaptureAcceptance=False, original227MemoryAcceptance=False,
        hardMemoryCapClaimed=False, fullMemoryQualification=False, sourceAndFinalPackageBound=installed is not None,
        installedIdentityBound=installed is not None, exactGeneratedTextOutputVerified=True,
        sameFinalFrontierPixelsVerified=True, onceOnlyOCRAndHelperVerified=True,
        checkedCopyRetryVerified=True, zeroAcquisitionVerified=True, nativeControlGeometryVerified=True,
        evidenceSHA256={name: hashlib.sha256(data).hexdigest() for name, data in sorted(files.items())})
    if installed is not None: result['sourceIdentity'] = installed
    return result


REQUIRED_SOURCES = {'Sources/PicShot/LiveScrollTextScriptDemoFixture.swift',
    'Sources/PicShot/LiveScrollTextDependencies.swift', 'Sources/PicShot/LiveScrollSessionController.swift',
    'Sources/PicShot/LiveScrollCaptureController.swift', 'Sources/PicShot/LiveScrollChainChoiceController.swift',
    'Sources/PicShot/AppMain.swift', 'Sources/PicShot/CaptureChainRunner.swift',
    'Sources/PicShot/CaptureChainController.swift', 'scripts/check-live-scroll-text-script-demo.py'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--source', required=True)
    parser.add_argument('--package-proof', type=Path)
    parser.add_argument('--source-root', type=Path)
    args = parser.parse_args()
    result = validate(args.report, args.source, args.package_proof, args.source_root)
    receipt = args.report.parent/RECEIPT_NAME
    need(not receipt.is_symlink(), 'receipt destination is symlinked')
    C.COMMON.save(receipt, result)
    print(json.dumps(dict(status=result['status'], sourceCommit=args.source, receipt=str(receipt))))


if __name__ == '__main__': main()
