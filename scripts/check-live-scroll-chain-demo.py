#!/usr/bin/env python3
"""Read bounded native existing-long-image chain evidence; never installer/TCC/RSS proof.

Acquisition is fixture-owned. This reader independently decodes all delivered PNGs,
checks raw receipts and action ordering, and recomputes native full-frame geometry.
The caller owns installed bundle/launcher qualification; --source binds this report.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import struct


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


C = module('existing_scroll_chain_shared', 'check-capture-chain-demo.py')
need, fields, number = C.need, C.fields, C.number
integer, text, digest, uuid = C.integer, C.text, C.digest, C.uuid
SOURCE = 'Fixture-owned native numbered scrolling document; deterministic viewport crops'
ACQUISITION = 'LiveScrollVerificationFrameSource; actual AppDelegate, live session, assembler and prepared chain runner'
OUTPUTS = ['quickSavePNG', 'copy', 'pin']
CHAIN_NAME = '编号长图 · 保存、复制、贴图'
OUTPUT_TITLE = '快速保存 PNG → 复制 → 贴图'
REPLACEMENT_WARNING = '开始新动作链会从第一步执行，可能再次保存、复制或贴图。'
ABANDON_WARNING = '已保存的文件和贴图仍保留。放弃后将清除本次续传记录，再次处理长图可能重复输出。'
OFFSETS = [0, 96, 192, 288, 384]
OWNERS = ('app', 'session', 'manager', 'firstRunner', 'continuedRunner', 'frozenImage',
          'provider', 'saveJob', 'pinController', 'presenter', 'delivery', 'pinCoordinator')
LIMITATIONS = ['Owned acquisition does not prove ScreenCaptureKit or third-party scrolling',
              'The first checked private-pasteboard write is deliberately rejected',
              'Images show cached owned native content, not a desktop screenshot',
              'Weak-owner and spool checks are bounded observations, not an RSS or zero-leak claim']
ACTIONS = ['more-open-choice', 'select-saved-definition', 'cancel-choice', 'more-open-choice',
           'run-current-image', 'cancel-remaining', 'manage-saved-chains', 'show-prior-receipt',
           'more-open-replacement', 'cancel-replacement',
           'more-open-abandon', 'cancel-abandon', 'more-continue']
IDS = ['scroll.live.imageChain', 'scroll.live.imageChain.choice', 'scroll.live.imageChain.choice.cancel',
       'scroll.live.imageChain', 'scroll.live.imageChain.run', 'capture-chain-cancel',
       'capture-chain-manage', 'capture-chain-result',
       'scroll.live.imageChain.replace', 'scroll.live.imageChain.choice.cancel',
       'scroll.live.imageChain.abandon', 'scroll.live.imageChain.abandon.cancel',
       'scroll.live.imageChain.continue']
PHASES = {
    'choice': {'scroll.live.imageChain.choice', 'scroll.live.imageChain.run', 'scroll.live.imageChain.choice.cancel',
               'scroll.live.imageChain.sheet.title', 'scroll.live.imageChain.sheet.description',
               'scroll.live.imageChain.choice.name', 'scroll.live.imageChain.choice.outputs'},
    'failure': {'capture-chain-cancel', 'capture-chain-run-status', 'capture-chain-receipt-0',
                'capture-chain-receipt-1', 'capture-chain-receipt-2'},
    'paused': {'scroll.live.more', 'scroll.live.status'},
    'replacement': {'scroll.live.imageChain.choice', 'scroll.live.imageChain.run', 'scroll.live.imageChain.choice.cancel',
                    'scroll.live.imageChain.sheet.title', 'scroll.live.imageChain.sheet.description',
                    'scroll.live.imageChain.choice.name', 'scroll.live.imageChain.choice.outputs', 'scroll.live.imageChain.sheet.warning'},
    'abandon': {'scroll.live.imageChain.abandon.confirm', 'scroll.live.imageChain.abandon.cancel',
                'scroll.live.imageChain.sheet.title', 'scroll.live.imageChain.sheet.description', 'scroll.live.imageChain.sheet.warning'},
    'result': {'capture-chain-close', 'capture-chain-run-status', 'capture-chain-receipt-0',
               'capture-chain-receipt-1', 'capture-chain-receipt-2'},
}
MAX_FILE = 16 * 1024**2
MAX_TOTAL = 64 * 1024**2


def ancestry(controls, window_number):
    by_id, paths = {}, {}
    classes = {'NSButton': 'button', 'NSPopUpButton': 'button', 'LiveScrollMoreButton': 'button', 'LiveScrollButton': 'button',
               'CaptureChainRunButton': 'button', 'NSTextField': 'textField', 'NSTableView': 'tableView',
               'NSScroller': 'scroller', 'NSImageView': 'other'}
    for row in controls:
        need(type(row) is dict, 'invalid native control')
        name = text(row.get('id'), 'control ID', 128)
        need(name not in by_id, 'duplicate control ID')
        by_id[name] = row
        native_class = text(row.get('class'), name+'.class', 128)
        role = text(row.get('controlKind'), name+'.kind', 32)
        need(role in ('button', 'textField', 'tableView', 'scroller', 'other'), 'invalid native role')
        if native_class in classes: need(role == classes[native_class], 'class/role mismatch')
        explicit = C.boolean(row, 'identifierIsExplicit', name)
        need(explicit == name.startswith(('capture-chain-', 'scroll.live.'))
             and (explicit or re.fullmatch(r'native-control-[0-9]+', name)), 'invalid identifier provenance')
        fields(row, dict(ownerWindowNumber=window_number, descendantOfOwnedContent=True), name)
        path = row.get('viewPath')
        need(type(path) is list and 1 <= len(path) <= 32, 'missing native view path')
        for part in path: integer(part, 'view path', 0, 4095)
        need(tuple(path) not in paths.values(), 'duplicate native view path')
        paths[name] = tuple(path)
    result = {}
    for name, row in by_id.items():
        parents = sorted((other for other in by_id if len(paths[other]) < len(paths[name])
                          and paths[name][:len(paths[other])] == paths[other]),
                         key=lambda other: len(paths[other]), reverse=True)
        need('parentControlID' in row and row['parentControlID'] == (parents[0] if parents else None)
             and row.get('controlAncestorIDs') == parents, 'forged native ancestry')
        if row['identifierIsExplicit']: need(not parents, 'product control nested as native title')
        if parents:
            owner = by_id[parents[0]]
            need(not row['identifierIsExplicit'] and row['controlKind'] == 'textField'
                 and owner['controlKind'] in ('button', 'tableView'), 'invalid native child role')
            need(not owner['hidden'] or row['hidden'], 'visible child of hidden native control')
            if owner['controlKind'] == 'button': need(row.get('text') == owner.get('text'), 'button title differs')
        if row['class'] not in classes:
            need(parents and row['controlKind'] == 'textField'
                 and by_id[parents[0]]['controlKind'] == 'button', 'unowned native class')
        result[name] = set(parents)
    return by_id, result


def layout(artifact, phase):
    row = artifact.get('layout')
    fields(row, dict(passed=True, phase='scroll-chain-'+phase, windowVisible=True, violations=[],
        fullNativeFramesMeasured=True, alignmentRectanglesSubstituted=False,
        fullVisibleFramesChecked=True, controlsDoNotOverlap=True), phase+'.layout')
    text(row.get('windowTitle'), 'window title', nonempty=False)
    bounds = C.rectangle(row.get('contentBounds'), 'native content')
    screen = C.rectangle(row.get('visibleScreenFrame'), 'native screen')
    window = C.rectangle(row.get('windowFrame'), 'native window')
    need(C.contains(screen, window), 'native window offscreen')
    need(bounds == (0, 0, artifact['width'], artifact['height']), 'PNG omits native content')
    controls = row.get('controls')
    need(type(controls) is list and 2 <= len(controls) <= 128, 'native control census bound')
    fields(row, dict(nativeControlCount=len(controls)), 'native census')
    by_id, tree = ancestry(controls, integer(row.get('windowNumber'), 'window number', 1))
    leaves = []
    for control in controls:
        name, role = control['id'], control['controlKind']
        hidden = C.boolean(control, 'hidden', name)
        C.boolean(control, 'enabled', name)
        visible = C.boolean(control, 'insideScrollableViewport', name)
        frame = C.rectangle(control.get('fullFrame'), name, empty=hidden or not visible)
        absolute = C.rectangle(control.get('fullScreenFrame'), name+'.screen', empty=hidden or not visible)
        C.rectangle(control.get('visibleRect'), name+'.visible', empty=True)
        size = C.pair(control.get('untruncatedCellSize'), name+'.cell')
        wrapped = C.pair(control.get('requiredTextSizeAtActualWidth'), name+'.text')
        for key in ('text', 'toolTip', 'accessibilityLabel', 'accessibilityValue'):
            text(control.get(key), name+'.'+key, nonempty=False)
        if hidden or not visible or role not in ('button', 'textField'): continue
        fields(control, dict(fullFrameContained=True), name)
        need(C.contains(bounds, frame) and C.contains(window, absolute) and C.contains(screen, absolute)
             and frame[2:] == absolute[2:], 'full native control clipped')
        leaves.append((name, frame))
        if role == 'button':
            fields(control, dict(hitTest=True), name)
            fit = frame[2]+.5 >= size[0] and frame[3]+.5 >= size[1]
            fields(control, dict(titleFits=fit), name)
            icon = more_icon(control, frame) if name == 'scroll.live.more' else False
            need(fit or icon, 'native button title clipped')
        elif control['text']:
            wraps = C.boolean(control, 'textWraps', name)
            fit = wrapped[1] <= frame[3]+.5 and (wraps or size[0] <= frame[2]+.5)
            mode = integer(control.get('lineBreakMode'), name+'.line break', 0, 5)
            alternative = control['toolTip'] == control['text'] and control['text'] in (
                control['accessibilityLabel'], control['accessibilityValue'])
            fields(control, dict(textFits=fit, intentionalTruncation=not fit and mode in (3,4,5),
                                 fullTextTooltipAndAccessibility=alternative), name)
            parent = by_id.get(control['parentControlID'])
            need(fit or (mode in (3,4,5) and alternative and not (parent and parent['controlKind']=='button')),
                 'native text clipped without full accessible alternative')
            number(control.get('fontPointSize'), name+'.font', 11, 128)
    C.check_control_overlap(leaves, tree)
    for name in PHASES[phase]:
        control = by_id.get(name)
        fields(control, dict(hidden=False, insideScrollableViewport=True), phase+'.required '+name)
        if control['controlKind'] == 'button':
            fields(control, dict(enabled=True, hitTest=True), name)
            if name != 'scroll.live.more': fields(control, dict(titleFits=True), name)
    return by_id


def more_icon(control, frame):
    """Only this owned image-only More control uses its public image rectangle."""
    fields(control, {'id': 'scroll.live.more', 'class': 'LiveScrollMoreButton', 'controlKind': 'button',
        'identifierIsExplicit': True, 'parentControlID': None, 'controlAncestorIDs': [],
        'hidden': False, 'enabled': True, 'insideScrollableViewport': True, 'hitTest': True,
        'text': '', 'accessibilityLabel': '更多滚动截图选项', 'toolTip': '移动选区 · 方向 · 导入 · 帮助',
        'moreIconPullsDown': True, 'moreIconImagePosition': 'imageOnly', 'moreIconArrowPosition': 'noArrow',
        'moreIconImageScaling': 'scaleNone', 'moreIconAnchorPresent': True, 'moreIconAnchorTitle': '',
        'moreIconDisplayedItemIsAnchor': True, 'moreIconImagePresent': True, 'moreIconFits': True}, 'More icon')
    bounds = C.rectangle(control.get('moreIconNativeBounds'), 'More native bounds')
    image_rect = C.rectangle(control.get('moreIconImageRect'), 'More public image rectangle')
    size = C.pair(control.get('moreIconImageSize'), 'More unscaled image size')
    need(bounds == (0, 0, frame[2], frame[3]), 'More native bounds differ from full frame')
    need(size[0] > 0 and size[1] > 0 and C.contains(bounds, image_rect)
         and image_rect[2]+.5 >= size[0] and image_rect[3]+.5 >= size[1], 'More image clipped or scaled')
    return True


def comparison(row, expected_hash, label):
    fields(row, dict(passed=True, dimensionsMatch=True, exactCanonicalRGBAEquality=True,
        width=480, height=704, expectedWidth=480, expectedHeight=704,
        outputPixelSHA256=expected_hash, sourcePixelSHA256=expected_hash, method=C.COMPARISON), label)


def sheet_content(artifact, controls, phase, case):
    """The visible owned sheet must preserve the name/order outside its short popup."""
    if phase not in ('choice', 'replacement', 'abandon'): return
    fields(artifact, dict(width=460), phase+'.owned sheet width')
    title = {'choice': '使用截图链处理当前长图', 'replacement': '选择其他动作链重新处理',
             'abandon': '放弃未完成操作并继续采集？'}[phase]
    description = ('来源：本次长截图。仅执行所选链的图片输出，按保存的顺序处理。' if phase == 'choice'
                   else case['replacementDetails'] if phase == 'replacement' else case['abandonDetails'])
    expected = {'scroll.live.imageChain.sheet.title': title,
                'scroll.live.imageChain.sheet.description': description}
    warning_id = 'scroll.live.imageChain.sheet.warning'
    if phase == 'choice':
        need(warning_id not in controls, 'initial choice includes redundant consequence warning')
    else:
        expected[warning_id] = REPLACEMENT_WARNING if phase == 'replacement' else ABANDON_WARNING
    if phase != 'abandon':
        expected.update({'scroll.live.imageChain.choice.name': CHAIN_NAME,
                         'scroll.live.imageChain.choice.outputs': OUTPUT_TITLE})
        fields(controls['scroll.live.imageChain.choice'],
            {'class': 'NSPopUpButton', 'toolTip': CHAIN_NAME+' · '+OUTPUT_TITLE,
             'accessibilityValue': CHAIN_NAME+' · '+OUTPUT_TITLE}, phase+'.choice')
    for identifier, value in expected.items():
        fields(controls[identifier], {'class': 'NSTextField', 'text': value, 'toolTip': value,
            'accessibilityLabel': value, 'accessibilityValue': value, 'textEditable': False,
            'textSelectable': True}, phase+'.full text '+identifier)
        if identifier.endswith('.description'):
            fields(controls[identifier], dict(textWraps=False, lineBreakMode=4,
                maximumNumberOfLines=9, fullTextTooltipAndAccessibility=True), identifier)
        else:
            fields(controls[identifier], dict(textWraps=True, textFits=True, intentionalTruncation=False), identifier)
        if identifier == warning_id:
            fields(controls[identifier], dict(hidden=False, insideScrollableViewport=True,
                lineBreakMode=0, maximumNumberOfLines=0), identifier)
            warning_frame = C.rectangle(controls[identifier]['fullFrame'], 'consequence warning')
            details_frame = C.rectangle(controls['scroll.live.imageChain.sheet.description']['fullFrame'], 'receipt details')
            need(warning_frame[1]+.5 >= details_frame[1]+details_frame[3], 'consequence warning is not above receipt details')


def native_ui_png(raw, label):
    """Canonical native UI pixels retain alpha; source and delivered PNGs stay opaque."""
    need(33 <= len(raw) <= MAX_FILE and raw[:8] == b'\x89PNG\r\n\x1a\n', label+': PNG signature/bound')
    width, height = struct.unpack_from('>II', raw, 16)
    need(0 < width <= 4096 and 0 < height <= 4096 and width*height <= 4_000_000,
         label+': native UI raster exceeds bound')
    width, height, pixels = C.PNG.png_rgba(raw)
    canonical = bytearray(pixels)
    for offset in range(0, len(canonical), 4):
        alpha = canonical[offset+3]
        for channel in range(3):
            canonical[offset+channel] = (canonical[offset+channel]*alpha+127)//255
    return width, height, bytes(canonical)


def check_ui_artifact(raw, artifact):
    name = artifact['filename']
    pixels = native_ui_png(raw, name)
    need(pixels[:2] == (artifact['width'], artifact['height'])
         and hashlib.sha256(pixels[2]).hexdigest() == artifact['canonicalRGBAPixelSHA256'],
         'physical native raster/layout differs')
    return pixels


def contract(report, source):
    need(type(source) is str and re.fullmatch(r'[0-9a-f]{40}', source), 'exact source commit required')
    fields(report, dict(schemaVersion=1, status='passed', sourceCommit=source,
        source=SOURCE, acquisition=ACQUISITION, installerAcceptance=False,
        realScreenCaptureClaimed=False, screenCaptureAPICalled=False, permissionRequested=False,
        globalInputPosted=False, networkUsed=False, userHistoryReadOrWritten=False,
        standardDefaultsReadOrWritten=False, generalPasteboardReadOrWritten=False,
        productAppDelegateExercised=True, productSessionControllerExercised=True,
        productSaveWorkflowDeliveryExercised=True, productPersistentPinExercised=True,
        canonicalPrivateTemporaryRoot=True, cleanupSafe=True, productSessionClosed=True,
        privateTemporaryRootRemoved=True, ownershipReleased=True, limitations=LIMITATIONS), 'live chain')
    need(not any(key in report for key in ('error', 'cleanupError')), 'fixture recorded error')
    number(report.get('elapsedSeconds'), 'bounded witness elapsed', .001, 60)
    fields(report.get('ownership'), {key: True for key in OWNERS}, 'weak owner release')
    need(set(report['ownership']) == set(OWNERS), 'owner probe set changed')
    fields(report.get('sourceReference'), dict(width=480, height=704), 'source pixels')
    expected = digest(report['sourceReference'].get('canonicalRGBAPixelSHA256'), 'source pixels')
    case = report.get('saveFailCancelContinue')
    fields(case, dict(status='passed', viewportOffsets=OFFSETS, definitionOutputs=OUTPUTS,
        noOutputOnSelectionOrChoiceCancel=True, noOutputOnReplacementOrAbandonCancel=True, noOutputOnManage=True,
        oneFrozenImageAcrossAttempts=True, renderCount=1, pausedDraftRetained=True,
        pausedMutationControlsDisabled=True, saveDrainedBeforeCancel=True,
        savedFileCount=1, savedPNGUnchanged=True, pinEntryCount=1, reloadedPinEntryCount=1,
        pinOriginalAndCurrentShareOneAsset=True, visibleNativePinCount=1,
        catalogDefinitionsOnly=True, noEditorHistoryOrTransientPinOutput=True,
        saveJobsDrained=True, privatePasteboardReleased=True, isolatedDefaultsRemoved=True,
        spoolDirectoryEmpty=True, productSessionClosed=True, cleanupSafe=True,
        terminalStatus='completed', finalRetainedBytes=0), 'continuation')
    need(not any(key in case for key in ('error', 'cleanupError')), 'case recorded error')
    fields(case.get('failureAttempts'), dict(capture=0, save=1, saveAdmissions=1, copy=1, pin=0), 'failure counts')
    fields(case.get('attempts'), dict(capture=0, save=1, saveAdmissions=1, copy=2, pin=1), 'final counts')
    viewports = case.get('viewportTrace')
    need(type(viewports) is list and len(viewports) == len(OFFSETS), 'owned viewport trace missing')
    accepted = 0
    for row, offset in zip(viewports, OFFSETS):
        fields(row, dict(offset=offset, height=320+offset), 'owned scrolling viewport')
        observed = integer(row.get('acceptedObservations'), 'accepted viewport observations', 1, 2400)
        need(observed >= accepted, 'owned observations moved backwards')
        accepted = observed
    first = uuid(case.get('firstRunID'), 'first run')
    need(first != uuid(case.get('continuedRunID'), 'continued run'), 'run identity reused')
    for key in ('revisionID', 'transactionID'):
        need(uuid(case.get(key), key) == uuid(case.get('continued'+key[0].upper()+key[1:]), 'continued '+key),
             key+' changed during continuation')
    path = C.absolute(case.get('savedPath'), 'saved path')
    need(path.parent.name == 'saved' and path.parent.parent.name.startswith('PicShot-LiveChain-')
         and path.name.startswith('owned-live-chain-') and path.suffix=='.png', 'unowned Save path')
    count = integer(case.get('savedPNGByteCount'), 'saved bytes', 1, MAX_FILE)
    for key, required in (('pausedStatus', ('1/3', '继续')),
                          ('replacementWarning', (str(path), '再次')),
                          ('abandonWarning', (str(path), '仍保留')),
                          ('replacementDetails', (str(path),)), ('abandonDetails', (str(path),))):
        message = text(case.get(key), key)
        need(all(token in message for token in required), key+': warning omitted receipt or consequence')
    fields(case, dict(replacementConsequence=REPLACEMENT_WARNING, abandonConsequence=ABANDON_WARNING), 'visible consequence warning')
    for phase in ('replacement', 'abandon'):
        need(case[phase+'Consequence'] in case[phase+'Warning'] and case[phase+'Details'] in case[phase+'Warning'],
             'combined warning omitted its exact visible consequence or receipt details')
    pin = uuid(case.get('pinID'), 'pin receipt identity')
    save = dict(output='quickSavePNG', savedURL=str(path), byteCount=count)
    receipts = [save, dict(output='copy', checkedPrivatePasteboard=True), dict(output='pin', pinID=pin)]
    need(case.get('failureReceipts') == [save] and case.get('pausedReceipts') == [save]
         and case.get('receipts') == receipts, 'receipt prefix lost, reordered or expanded')
    for key in ('savedPNGComparison','copiedPNGComparison','publishedPinComparison','reloadedPinComparison'):
        comparison(case.get(key), expected, key)
    for key in ('savedPNGFileSHA256','copiedPNGFileSHA256','pinPNGFileSHA256','reloadedPinPNGFileSHA256'):
        digest(case.get(key), key)
    need(digest(case.get('catalogBeforeSHA256'),'catalog before') == digest(case.get('catalogAfterSHA256'),'catalog after'),
         'catalog bytes changed')
    trace = case.get('actionTrace')
    need(type(trace) is list and len(trace)==len(ACTIONS), 'bounded native action trace missing')
    for index, (action, identifier) in enumerate(zip(ACTIONS,IDS)):
        row = trace[index]
        fields(row, dict(index=index, action=action, identifier=identifier), 'action trace')
        need(row.get('route') == ('NSApp.sendAction on production More menu item' if action.startswith('more-')
             else 'NSPopUpButton.selectItem; no output command' if action.startswith('select-')
             else 'PortableSettingsUIPreviewFixture.click: owned NSButton.mouseDown with queued mouseUp'), 'action bypassed native route')
    for phase in PHASES:
        rows = case.get(phase+'Artifacts')
        need(type(rows) is list and len(rows)==2, phase+': light/dark evidence missing')
        hashes=[]
        for row, mode in zip(rows, ('light','dark')):
            fields(row, dict(filename='scroll-chain-'+phase+'-'+mode+'.png', appearance=mode, rendering=C.RENDERING), phase)
            w=integer(row.get('width'), 'UI width',1,4096); h=integer(row.get('height'),'UI height',1,4096)
            need(w*h<=4_000_000,'UI raster exceeds existing bound')
            hashes.append(digest(row.get('canonicalRGBAPixelSHA256'),phase+' pixels'))
            sheet_content(row, layout(row,phase), phase, case)
        need(hashes[0]!=hashes[1],phase+': identical light/dark pixels')
    return case


def validate(report_path, source):
    report_path=Path(report_path)
    need(report_path.name=='live-scroll-chain.json','wrong raw report name')
    report=C.COMMON.load(report_path)
    case=contract(report,source)
    root=report_path.parent
    files={report_path.name:C.COMMON.read(report_path)}
    def read(name, limit=MAX_FILE):
        need(Path(name).name==name and name not in files,'unsafe/duplicate evidence name')
        raw=C.COMMON.read(root/name,limit); files[name]=raw
        need(len(files)<=40 and sum(map(len,files.values()))<=MAX_TOTAL,'aggregate evidence bound')
        return raw
    reference=C.decoded_png(read('scroll-chain-owned-numbered.png'),'reference')
    need(reference[:2]==(480,704) and hashlib.sha256(reference[2]).hexdigest()==report['sourceReference']['canonicalRGBAPixelSHA256'],
         'independently decoded reference differs')
    for stem,key in [('saved','savedPNGFileSHA256'),('copied','copiedPNGFileSHA256'),
                     ('pin','pinPNGFileSHA256'),('pin-reloaded','reloadedPinPNGFileSHA256')]:
        name='scroll-chain-'+stem+'.png'; raw=read(name)
        need(hashlib.sha256(raw).hexdigest()==case[key],'physical output digest differs')
        need(C.decoded_png(raw,name)==reference,'independently decoded exact output pixels differ')
        if stem=='saved':need(len(raw)==case['savedPNGByteCount'],'physical Save receipt bytes differ')
    raw=read('scroll-chain-catalog.json',128*1024)
    need(hashlib.sha256(raw).hexdigest()==case['catalogBeforeSHA256']==case['catalogAfterSHA256'],'physical catalog changed')
    catalog=C.COMMON.load(root/'scroll-chain-catalog.json')
    need(set(catalog)=={'version','definitions','selectedID'},'catalog contains runtime data')
    fields(catalog,dict(version=1),'catalog')
    definitions=catalog.get('definitions')
    need(type(definitions) is list and len(definitions)==1,'definition count')
    definition=definitions[0]
    need(type(definition) is dict and set(definition)=={'id','name','source','outputs'},'definition runtime payload')
    fields(definition,dict(name=CHAIN_NAME,source={'kind':'region'},outputs=OUTPUTS),'saved definition')
    need(uuid(definition.get('id'),'definition ID')==catalog['selectedID'],'selected definition differs')
    trace=read('scroll-chain-actions.json',128*1024)
    need(C.COMMON.load(root/'scroll-chain-actions.json')==dict(actionTrace=case['actionTrace'],failureReceipts=case['failureReceipts'],
         pausedReceipts=case['pausedReceipts'],receipts=case['receipts']),'persisted action/receipt evidence differs')
    for phase in PHASES:
        for artifact in case[phase+'Artifacts']:
            name=artifact['filename']; check_ui_artifact(read(name),artifact)
            name=name[:-4]+'-layout.json'; read(name,1024**2)
            need(C.COMMON.load(root/name)==artifact,'persisted raw native geometry differs')
    return dict(schemaVersion=1,status='passed',sourceCommit=source,installerAcceptance=False,
        realScreenCaptureAcceptance=False,memoryQualification=False,exactDecodedOutputPixels=True,
        savedReceiptPhysicalBytesVerified=True,unchangedMetadataOnlyCatalogVerified=True,
        sameRevisionReceiptContinuationVerified=True,nativeControlGeometryVerified=True,
        scope='Owned native long-image chain and output recipients with injected acquisition; installed identity is qualified by caller',
        evidenceSHA256={name:hashlib.sha256(raw).hexdigest() for name,raw in sorted(files.items())})


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report',required=True,type=Path); parser.add_argument('--source',required=True)
    args=parser.parse_args(); result=validate(args.report,args.source)
    receipt=args.report.parent/'live-scroll-chain-receipt.json'
    need(not receipt.is_symlink(),'symlinked receipt destination')
    C.COMMON.save(receipt,result)
    print(json.dumps(dict(status='passed',sourceCommit=args.source,receipt=str(receipt))))


if __name__=='__main__':main()
