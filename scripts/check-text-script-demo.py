#!/usr/bin/env python3
"""Strict reader for the generated-acquisition installed text-script witness.

Portable mutation fixtures are checker tests, never native execution evidence.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import re
import stat


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


C = module('text_script_chain_reader', 'check-capture-chain-demo.py')
need, fields, number = C.need, C.fields, C.number
integer, text, digest, uuid, rectangle, contains, overlap = C.integer, C.text, C.digest, C.uuid, C.rectangle, C.contains, C.overlap
EXPECTED = 'ABC-123\nXYZ-987'
NAME = '提取工单编号 · ' + '本机文字脚本' * 8
SOURCE_BODY = ('const ids = text.match(/\\b[A-Z]{2,8}-\\d+\\b/g) || [];\n'
               'return [...new Set(ids)].join("\\n");\n' + '\n'.join(
               '// Owned editor line ' + str(i) + ': ' + 'readable wrapped source ' * 8 for i in range(1, 25)))
SCOPE = 'Installed saved editor and region/OCR/script/Copy owner; generated acquisition, actual Apple Vision and signed production helper, checked private clipboard'
LIMITATIONS = ['Generated acquisition does not prove desktop selection, ScreenCaptureKit or TCC',
               'First checked private clipboard write is deliberately rejected',
               'Native images cache owned content only; no desktop screenshot',
               '256 MiB child RSS is sampled, not a hard allocation cap; bounded weak-owner drainage is not a leak or original227 memory pass']
ROUTE = 'Owned native Save/Run/Retry/Close mouseDown with queued mouseUp; owned table nextEvent/sendEvent; native text insertion'
OWNERS = ('app', 'editor', 'progress', 'runner', 'selectedImage', 'runtime')
PACKAGE_SCOPE = 'experimental package identity/signatures only; installed runtime and UI acceptance are separate'
PACKAGE_KEYS = {'schemaVersion','sourceCommit','version','build','architectures','appIdentifier','appCDHash','appTeamIdentifier',
    'executableSHA256','appInfoPlistSHA256','buildInfoSHA256','appSignatureVerified','helper','sameTeamIdentifierVerified',
    'helperEntitlementsVerifiedAfterOuterSigning','helperSignedInfoPlistVerifiedAfterOuterSigning','sources','scope',
    'embeddedInfoPlistSHA256','entitlementsSourceSHA256','relocationVerified','installedRuntimeAcceptanceVerified'}
HELPER_PLIST = {'CFBundleIdentifier':'com.picshot.TextScriptHelper','CFBundleExecutable':'PicShotTextScriptHelper',
    'CFBundleName':'PicShotScript','CFBundleInfoDictionaryVersion':'6.0','CFBundleVersion':'1'}
RSS_SCOPE = 'parent-polled child RSS; sampled maximum, not a hard allocation cap'
METRIC_KEYS = {'requestID', 'outcome', 'childLaunched', 'childPID', 'childExitConfirmed', 'pipesDrained',
    'admissionReleased', 'terminationStatus', 'terminationReason', 'terminateSent', 'killSent', 'elapsedSeconds',
    'launchSeconds', 'requestSentSeconds', 'exitObservedSeconds', 'acceptedSeconds', 'sampledPeakResidentBytes',
    'residentSamples', 'residentObservationFailures', 'maximumResidentSampleGapSeconds', 'stdinBytes', 'stdoutBytes',
    'stderrBytes', 'discardedResponseBytes', 'retainedResponseBytesAfterFinish', 'responseIdentityMatched',
    'pipeDescriptorsCloseOnExec', 'parentEndpointsNonblocking', 'inputSuppressesSIGPIPE', 'signature',
    'acceptanceDeadlineSeconds', 'rssLimitBytes', 'rssSampleIntervalSeconds', 'terminateGraceSeconds',
    'killedObservationSeconds', 'observationScope'}


def exact_keys(row, keys, label):
    need(type(row) is dict and set(row) == set(keys), label + ': unexpected or missing fields')


def metrics(row, request_id):
    # Optional cleanupSeconds is absent for successful helpers. No diagnostic,
    # exception/source/OCR payload or arbitrary property is accepted here.
    exact_keys(row, METRIC_KEYS, 'helper metrics')
    fields(row, dict(requestID=request_id, outcome='succeeded', childLaunched=True, childExitConfirmed=True,
        pipesDrained=True, admissionReleased=True, terminationStatus=0, terminationReason='exit',
        terminateSent=False, killSent=False, residentObservationFailures=0, stderrBytes=0,
        retainedResponseBytesAfterFinish=0, responseIdentityMatched=True, pipeDescriptorsCloseOnExec=True,
        parentEndpointsNonblocking=True, inputSuppressesSIGPIPE=True,
        rssLimitBytes=256*1024**2, observationScope=RSS_SCOPE), 'helper')
    for key, expected in [('acceptanceDeadlineSeconds', 3), ('rssSampleIntervalSeconds', .05), ('terminateGraceSeconds', .25), ('killedObservationSeconds', .75)]:
        need(number(row.get(key), key) == expected, 'fixed runtime bound changed: '+key)
    integer(row.get('childPID'), 'helper PID', 1)
    integer(row.get('residentSamples'), 'RSS observations', 1, 1000)
    integer(row.get('sampledPeakResidentBytes'), 'sampled RSS', 1, 256*1024**2)
    elapsed = number(row.get('elapsedSeconds'), 'helper elapsed', .000001, 3)
    times = [number(row.get(key), key, 0, elapsed) for key in
             ('launchSeconds', 'requestSentSeconds', 'exitObservedSeconds', 'acceptedSeconds')]
    need(times == sorted(times), 'helper timing order')
    number(row.get('maximumResidentSampleGapSeconds'), 'RSS observation gap', 0, 3)
    integer(row.get('stdinBytes'), 'request byte count', 1, 512*1024)
    size = integer(row.get('stdoutBytes'), 'response byte count', 1, 256*1024)
    fields(row, dict(discardedResponseBytes=size), 'response discarded')
    signature = row.get('signature')
    exact_keys(signature, ('appIdentifier', 'helperIdentifier', 'helperCDHash', 'helperEntitlements', 'appAndHelperStrictlyValidated'), 'runtime signature')
    fields(signature, dict(appIdentifier='local.picshot.app', helperIdentifier='com.picshot.TextScriptHelper',
        helperEntitlements=['com.apple.security.app-sandbox'], appAndHelperStrictlyValidated=True), 'runtime signature')
    need(type(signature.get('helperCDHash')) is str and re.fullmatch('[0-9a-f]{40}', signature['helperCDHash']), 'helper CDHash')


def layout(artifact, phase):
    value = artifact.get('layout')
    fields(value, dict(phase=phase, passed=True, windowVisible=True, violations=[],
        fullNativeFramesMeasured=True, alignmentRectanglesSubstituted=False), 'native layout')
    window_id = integer(value.get('windowNumber'), 'owned window', 1)
    window = rectangle(value.get('windowFrame'), 'window')
    screen = rectangle(value.get('screenFrame'), 'screen')
    bounds = rectangle(value.get('contentBounds'), 'content')
    need(contains(screen, window), 'owned native window offscreen')
    need(bounds == (0, 0, artifact['width'], artifact['height']), 'native PNG omits content')
    rows = value.get('controls')
    need(type(rows) is list and 5 <= len(rows) <= 160, 'bounded native control census')
    by_id, paths, leaves = {}, {}, []
    classes = {'button': {'NSButton', 'NSPopUpButton', 'CaptureChainRunButton', 'TextScriptRunButton'},
        'field': {'NSTextField', 'NSButtonTextField'}, 'source': {'TextScriptBoundedTextView'},
        'table': {'NSTableView'}, 'other': {'NSScroller'}}
    for row in rows:
        identifier = text(row.get('id'), 'native ID', 128)
        need(identifier not in by_id, 'duplicate native ID')
        by_id[identifier] = row
        kind = row.get('kind')
        need(kind in classes and row.get('class') in classes[kind], 'unknown/forged native kind')
        need(identifier.startswith(('text-script-', 'capture-chain-')) or re.fullmatch('native-[0-9]+', identifier), 'foreign identifier')
        path = row.get('viewPath')
        need(type(path) is list and 1 <= len(path) <= 32, 'native view path absent')
        for part in path: integer(part, 'view path', 0, 4096)
        path = tuple(path)
        need(path not in paths.values(), 'duplicate view path')
        paths[identifier] = path
        fields(row, dict(ownerWindowNumber=window_id, owned=True), 'owned native view')
        hidden = C.boolean(row, 'hidden', identifier)
        C.boolean(row, 'enabled', identifier)
        visible = C.boolean(row, 'insideViewport', identifier)
        frame = rectangle(row.get('fullFrame'), identifier, empty=hidden or not visible)
        on_screen = rectangle(row.get('screenFrame'), identifier + '.screen', empty=hidden or not visible)
        need(frame[2:] == on_screen[2:], 'native screen dimensions differ')
        for key in ('text', 'tooltip', 'accessibilityValue', 'accessibilityLabel'): text(row.get(key), identifier + '.' + key, 16384, nonempty=False)
        if hidden: continue
        if kind in ('button', 'field') and visible:
            fields(row, dict(contained=True), identifier)
            need(contains(bounds, frame) and contains(window, on_screen) and contains(screen, on_screen), 'full native frame clipped')
            cell = C.pair(row.get('cellSize'), 'untruncated cell')
            wrapped = C.pair(row.get('wrappedSize'), 'wrapped cell')
            fits = C.boolean(row, 'textFits', identifier)
            if kind == 'button':
                fields(row, dict(hitTest=True, textFits=True), identifier)
                need(frame[2]+.5 >= cell[0] and frame[3]+.5 >= cell[1], 'button text clipped')
            else:
                wraps = C.boolean(row, 'wraps', identifier)
                actual_fit = wrapped[1] <= frame[3]+.5 and (wraps or cell[0] <= frame[2]+.5)
                need(fits == actual_fit, 'text fit differs from raw native metrics')
                editable = C.boolean(row, 'editableScrollable', identifier)
                alignment = number(row.get('alignmentWidth'), 'alignment width', 0, frame[2]+.5)
                alternative = C.boolean(row, 'nameAlternative', identifier)
                name_alternative = identifier == 'text-script-name' and editable and alignment >= 320 and wrapped[1] <= frame[3]+.5 and row['tooltip'] == row['accessibilityValue'] == row['text']
                need(alternative == name_alternative, 'forged name alternative')
                truncates = C.boolean(row, 'truncates', identifier)
                accessible = C.boolean(row, 'accessibleAlternative', identifier)
                if row['text']:
                    need(accessible == (row['tooltip'] == row['text'] and row['text'] in (row['accessibilityValue'], row['accessibilityLabel'])), 'forged full accessible text alternative')
                number(row.get('fontSize'), 'native font', 11, 96)
                need(not row['text'] or fits or alternative or (truncates and accessible and row['tooltip'] == row['text']), 'native text unreadable')
            leaves.append((identifier, frame))
        if kind == 'source':
            fields(row, dict(wraps=True, verticalScroll=True, editableSelectable=True, completeSourceAccessible=True), 'source editor')
            viewport = rectangle(row.get('viewport'), 'source viewport')
            used = rectangle(row.get('usedTextRect'), 'source text', empty=True)
            width = number(row.get('textContainerWidth'), 'source container width', 1, 4096)
            insets = C.pair(row.get('textInset'), 'source inset')
            need(viewport[2] >= 320 and viewport[3] >= 120 and contains(bounds, viewport), 'source viewport clipped')
            need(used[2] <= width+.5 and width+2*insets[0] <= frame[2]+.5, 'source horizontal overflow')
            fields(row, dict(text=SOURCE_BODY, accessibilityValue=SOURCE_BODY), 'complete source')
            number(row.get('fontSize'), 'source font', 11, 96)
            leaves.append((identifier, viewport))
    ancestry = {}
    for identifier, row in by_id.items():
        path = paths[identifier]
        parents = sorted((other for other in paths if len(paths[other]) < len(path) and path[:len(paths[other])] == paths[other]), key=lambda other: len(paths[other]), reverse=True)
        need(row.get('ancestorIDs') == parents, 'forged native ancestry')
        if identifier.startswith(('text-script-', 'capture-chain-')): need(not parents, 'product control forged as native descendant')
        if parents:
            need(row['kind'] == 'field' and by_id[parents[0]]['kind'] in ('button', 'table'), 'unsupported native descendant')
            if by_id[parents[0]]['kind'] == 'button':
                need(row['text'] == by_id[parents[0]]['text'], 'native title differs from owning button')
                if not row['hidden'] and row['insideViewport']: need(row['textFits'], 'button title child clipped')
        elif row['class'] == 'NSButtonTextField': need(False, 'unowned private title control')
        ancestry[identifier] = set(parents)
    C.check_control_overlap(leaves, ancestry)
    required = {'text-script-create', 'text-script-save', 'text-script-close', 'text-script-run', 'text-script-name', 'text-script-source', 'text-script-list'} if phase == 'text-script-editor' else {'capture-chain-close', 'capture-chain-run-status', 'capture-chain-receipt-0'}
    if phase.endswith('-failure'): required.add('capture-chain-retry')
    for identifier in required:
        row = by_id.get(identifier)
        fields(row, dict(hidden=False), identifier)
        if identifier != 'text-script-source': fields(row, dict(insideViewport=True), identifier)
        if identifier.endswith(('-run', '-close', '-retry', '-create')): fields(row, dict(enabled=True, hitTest=True), identifier)
    if phase == 'text-script-editor': fields(by_id['text-script-name'], dict(text=NAME), 'saved long name')
    elif phase.endswith('-failure'):
        fields(by_id['capture-chain-run-status'], dict(text=NAME+' · 操作未完成：无法将文字写入剪贴板，请重试。'), 'fixed copy error')
        fields(by_id['capture-chain-receipt-0'], dict(text='复制失败；重试只复制已准备好的文字，不会重新截图、识别或执行脚本。'), 'fixed retry guidance')
    else:
        fields(by_id['capture-chain-run-status'], dict(text=NAME+' · 全部完成'), 'fixed completed state')
        fields(by_id['capture-chain-receipt-0'], dict(text='已复制文字到剪贴板（15 个字符）'), 'native committed receipt')


def artifacts(rows, phase):
    need(type(rows) is list and len(rows) == 2, 'light and dark native artifacts required')
    hashes = []
    for artifact, mode in zip(rows, ('light', 'dark')):
        fields(artifact, dict(filename=phase+'-'+mode+'.png', appearance=mode), phase)
        width = integer(artifact.get('width'), 'image width', 1, 4096)
        height = integer(artifact.get('height'), 'image height', 1, 4096)
        need(width*height <= 4_000_000, 'owned image bound')
        hashes.append(digest(artifact.get('canonicalRGBAPixelSHA256'), 'native pixels'))
        layout(artifact, phase)
    need(hashes[0] != hashes[1], 'identical native appearances')


def case_fields(row, retry):
    name = 'retry' if retry else 'close'
    fields(row, dict(status='passed', case=name, actionRoute=ROUTE, copyRejectionInjectedAtCheckedWriter=True,
        appInitialized=True, nativeSaveControlIdentifier='text-script-save', nativeSourceInsertion=True,
        savedDefinitionReloaded=True, runControlIdentifier='text-script-run', failureCode='clipboardRejected',
        failurePhase='copy', failedRetainedTextBytes=len(EXPECTED.encode()), failedImageReleased=True,
        failureReceiptCount=0, rejectedPasteboardEmpty=True, closeControlIdentifier='capture-chain-close',
        catalogDefinitionsOnly=True, editorHiddenDuringCapture=True, progressHiddenDuringCapture=True,
        historyHiddenDuringCapture=True, noEditorHistoryOrPinOutput=True, finalRetainedBytes=0,
        finalRetainedTextBytes=0, terminalStatus='completed' if retry else 'cancelled',
        editorCloseControlIdentifier='text-script-close', recognitionTruncated=False, cleanupSafe=True,
        visionJobsDrained=True, helperAdmissionDrained=True, privatePasteboardReleased=True,
        isolatedDefaultsRemoved=True, committedReceiptCount=1 if retry else 0), name)
    need(not any(key in row for key in ('fixtureFailureCode', 'cleanupFailureCode', 'error')), name+': recorded failure')
    fields(row.get('failureAttempts'), dict(capture=1, ocr=1, transform=1, copy=1, committedCopy=0), 'first attempt')
    fields(row.get('attempts'), dict(capture=1, ocr=1, transform=1, copy=2 if retry else 1, committedCopy=1 if retry else 0), 'final attempt')
    uuid(row.get('definitionID'), 'saved script identity')
    request_id = uuid(row.get('requestID'), 'request identity')
    need(digest(row.get('catalogBeforeSHA256'), 'catalog before') == digest(row.get('catalogAfterSHA256'), 'catalog after'), 'saved catalog changed')
    ocr = text(row.get('generatedActualOCR'), 'generated OCR', 4096)
    need(set(re.findall(r'\b[A-Z]{2,8}-\d+\b', ocr)) == {'ABC-123', 'XYZ-987'}, 'actual Vision did not recognize authored identifiers')
    helpers = row.get('helperMetrics')
    need(type(helpers) is list and len(helpers) == 1, 'exactly one helper execution per run')
    metrics(helpers[0], request_id)
    C.row_selection(row.get('rowSelection'))
    artifacts(row.get('failureArtifacts'), 'text-script-'+name+'-failure')
    if retry:
        fields(row, dict(retryControlIdentifier='capture-chain-retry', generatedActualOutput=EXPECTED,
            receiptCharacterCount=len(EXPECTED), copiedTextSHA256=hashlib.sha256(EXPECTED.encode()).hexdigest(), copiedTextBytes=len(EXPECTED.encode())), 'checked Copy')
        artifacts(row.get('editorArtifacts'), 'text-script-editor')
        artifacts(row.get('resultArtifacts'), 'text-script-result')
    else:
        fields(row, dict(privatePasteboardEmptyAfterClose=True), 'closed failed Copy')
        need(not any(key in row for key in ('generatedActualOutput', 'retryControlIdentifier', 'resultArtifacts', 'copiedTextSHA256')), 'close published an output')


def report_fields(value, source):
    need(type(source) is str and re.fullmatch('[0-9a-f]{40}', source), 'exact source commit required')
    fields(value, dict(schemaVersion=1, status='passed', sourceCommit=source, scope=SCOPE, limitations=LIMITATIONS,
        installerAcceptance=False, original227MemoryAcceptance=False, hardMemoryCapClaimed=False,
        realScreenCaptureClaimed=False, screenCaptureAPICalled=False, permissionRequested=False,
        networkUsed=False, globalInputPosted=False, userHistoryReadOrWritten=False,
        standardDefaultsReadOrWritten=False, generalPasteboardReadOrWritten=False,
        runtimeGateBuild=False, transportFixtureUsed=False, generatedExpectedOutput=EXPECTED,
        productAppDelegateExercised=True, realAppleVisionRan=True, productionHelperRan=True,
        canonicalPrivateTemporaryRoot=True, ownershipReleased=True, privateTemporaryRootRemoved=True,
        finalVisionActiveJobs=0, finalVisionWaitingJobs=0, finalHelperAdmissionOccupied=False, cleanupSafe=True), 'fixture')
    need(not any(key in value for key in ('failureCode', 'cleanupFailureCode', 'error', 'launcherCleanupError')), 'recorded fixture failure')
    number(value.get('elapsedSeconds'), 'fixture elapsed', .001, 180)
    for group in ('successOwnershipReleased', 'closeOwnershipReleased'):
        exact_keys(value.get(group), OWNERS, group)
        fields(value[group], {key: True for key in OWNERS}, group)
    fields(value.get('sourceReference'), dict(width=900, height=300), 'generated input')
    digest(value['sourceReference'].get('canonicalRGBAPixelSHA256'), 'generated input pixels')
    case_fields(value.get('copyRetry'), True); case_fields(value.get('closeAfterFailure'), False)
    need(value['copyRetry']['requestID'] != value['closeAfterFailure']['requestID'], 'request identity reused')
    need(value['copyRetry']['definitionID'] != value['closeAfterFailure']['definitionID'], 'case catalog identity reused')


def identity(smoke, launch, proof, source, source_root):
    fields(smoke, dict(sourceCommit=source, historyDirectoryRemoved=True, independentValidationRequired=True), 'smoke')
    app = C.absolute(smoke.get('bundlePath'), 'app path')
    need(app.name == 'PicShot.app' and app.resolve() == app, 'wrong or symlinked app')
    executable = app/'Contents/MacOS/PicShot'
    helper = app/'Contents/Helpers/PicShotTextScriptHelper'
    fields(smoke, dict(executablePath=str(executable), arguments=[str(executable)]), 'smoke executable')
    build, version = text(smoke.get('build'), 'build', 32), text(smoke.get('version'), 'version', 32)
    need(re.fullmatch('[1-9][0-9]*', build) and re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version), 'invalid version/build')
    fields(launch, dict(schemaVersion=1, status='exited', launcherExitCode=0, callbackReceived=True,
        createsNewApplicationInstance=True, ownedExitConfirmed=True, launchedIdentityMatches=True,
        textScriptDiagnosticOnly=True, captureChainDiagnosticOnly=False, liveScrollDiagnosticOnly=False,
        earlyWitnessOnly=False, processStartMemoryCaptured=False, timeoutSeconds=240,
        selectedAppPath=str(app), launchedAppPath=str(app), expectedExecutablePath=str(executable),
        launchedExecutablePath=str(executable)), 'owned launch')
    need(not any(key in launch for key in ('error', 'interruptedSignal')), 'launch failure')
    integer(launch.get('processIdentifier'), 'app PID', 1); number(launch.get('elapsedSeconds'), 'launch elapsed', .001, 240)
    fields(plistlib.loads(C.COMMON.read(app/'Contents/Info.plist', 1024**2)),
        dict(PicShotSourceCommit=source, CFBundleVersion=build, CFBundleShortVersionString=version,
             CFBundleExecutable='PicShot', CFBundleIdentifier='local.picshot.app'), 'current app plist')
    info = C.COMMON.load(app/'Contents/Resources/build-info.json')
    fields(info, dict(app='PicShot', sourceCommit=source, version=version), 'build info')
    need(info.get('architecture') in ('arm64', 'x86_64'), 'native architecture absent')
    exact_keys(proof, PACKAGE_KEYS, 'package proof schema')
    fields(proof, dict(scope=PACKAGE_SCOPE, schemaVersion=1, sourceCommit=source, version=version, build=build,
        architectures=[info['architecture']], appIdentifier='local.picshot.app', appSignatureVerified=True,
        sameTeamIdentifierVerified=True, helperEntitlementsVerifiedAfterOuterSigning=True,
        helperSignedInfoPlistVerifiedAfterOuterSigning=True, relocationVerified=True,
        installedRuntimeAcceptanceVerified=False), 'production package proof')
    for field, path in [('executableSHA256', executable), ('appInfoPlistSHA256', app/'Contents/Info.plist'),
                        ('buildInfoSHA256', app/'Contents/Resources/build-info.json')]:
        need(digest(proof.get(field), field) == C.COMMON.sha(path), field+': current app differs from package proof')
    need(type(proof.get('appCDHash')) is str and re.fullmatch('[0-9a-f]{40,64}', proof['appCDHash']), 'app CDHash')
    need(proof['appTeamIdentifier'] is None or type(proof['appTeamIdentifier']) is str and bool(proof['appTeamIdentifier']), 'app team identity')
    signed = proof.get('helper')
    exact_keys(signed, ('path','identifier','teamIdentifier','cdHash','sha256','bytes','entitlements','signedInfoPlist','linkedLibraries','strictSignatureVerified'), 'helper proof schema')
    fields(signed, dict(path='Contents/Helpers/PicShotTextScriptHelper', identifier='com.picshot.TextScriptHelper',
        entitlements={'com.apple.security.app-sandbox': True}, strictSignatureVerified=True), 'packaged helper')
    exact_keys(signed['entitlements'], ('com.apple.security.app-sandbox',), 'sole sandbox entitlement')
    need(signed['entitlements']['com.apple.security.app-sandbox'] is True, 'sandbox entitlement must be a Boolean true')
    need(type(signed['teamIdentifier']) is type(proof['appTeamIdentifier']) and signed['teamIdentifier'] == proof['appTeamIdentifier'], 'helper signing team differs')
    need(helper.resolve() == helper and stat.S_ISREG(helper.stat().st_mode) and helper.stat().st_nlink == 1, 'helper path is not owned regular code')
    need(digest(signed.get('sha256'), 'helper SHA256') == C.COMMON.sha(helper), 'current helper differs from package proof')
    integer(signed.get('bytes'), 'helper bytes', 1, 64*1024**2)
    need(helper.stat().st_size == signed['bytes'], 'helper size differs')
    need(type(signed.get('cdHash')) is str and re.fullmatch('[0-9a-f]{40}', signed['cdHash']), 'packaged helper CDHash')
    exact_keys(signed.get('signedInfoPlist'), HELPER_PLIST, 'signed helper plist schema')
    fields(signed['signedInfoPlist'], HELPER_PLIST, 'signed helper plist')
    libraries = signed['linkedLibraries']
    need(type(libraries) is list and 1 <= len(libraries) <= 32 and len(set(libraries)) == len(libraries), 'helper linked libraries absent')
    for library in libraries:
        need(text(library, 'linked library', 1024).startswith(('/usr/lib/', '/System/Library/')) and '..' not in Path(library).parts, 'non-system helper dependency')
    inventory = proof.get('sources')
    need(type(inventory) is list and 3 <= len(inventory) <= 128, 'package source inventory absent')
    seen = set()
    root = Path(source_root).resolve()
    for row in inventory:
        exact_keys(row, ('path', 'bytes', 'sha256'), 'source inventory row')
        relative = Path(text(row.get('path'), 'source path'))
        need(not relative.is_absolute() and '..' not in relative.parts and str(relative) not in seen, 'unsafe or duplicate source path')
        seen.add(str(relative)); path = root/relative
        need(path.resolve().is_relative_to(root), 'source path escapes root')
        data = C.COMMON.read(path, 8*1024**2)
        need(len(data) == integer(row.get('bytes'), 'source bytes', 1, 8*1024**2) and hashlib.sha256(data).hexdigest() == digest(row.get('sha256'), 'source digest'), 'package source bytes changed')
    required_sources = {'Sources/PicShotTextScriptHelper/TextScriptHelperMain.swift', 'Sources/PicShotTextScriptHelper/TextScriptEngine.swift',
        'Sources/PicShotTextScriptProcess/TextScriptProcessService.swift',
        'Sources/PicShot/AppMain.swift', 'Sources/PicShot/SmokeVerification.swift',
        'Sources/PicShot/CaptureChainRunner.swift', 'Sources/PicShot/CaptureChainTextRuntime.swift',
        'Sources/PicShot/CaptureChainController.swift', 'Sources/PicShot/TextScriptController.swift',
        'Sources/PicShot/TextScriptStore.swift', 'Sources/PicShot/TextScriptUIPreviewFixture.swift',
        'Sources/PicShotCore/TextScriptDefinition.swift', 'scripts/check-text-script-demo.py'}
    required_sources |= {'scripts/text-script-helper-Info.plist','scripts/text-script-helper.entitlements'}
    need(required_sources <= seen, 'production helper source identity incomplete')
    for key, relative in [('embeddedInfoPlistSHA256','scripts/text-script-helper-Info.plist'),('entitlementsSourceSHA256','scripts/text-script-helper.entitlements')]:
        need(digest(proof.get(key), key) == C.COMMON.sha(root/relative), 'signed metadata source digest differs')
    fields(plistlib.loads(C.COMMON.read(root/'scripts/text-script-helper-Info.plist')), HELPER_PLIST, 'embedded source plist')
    source_entitlements = plistlib.loads(C.COMMON.read(root/'scripts/text-script-helper.entitlements'))
    exact_keys(source_entitlements, ('com.apple.security.app-sandbox',), 'entitlement source')
    need(source_entitlements['com.apple.security.app-sandbox'] is True, 'source sandbox entitlement must be Boolean true')
    for name in ('PicShotTextScriptGate', 'PicShotTextScriptTransportFixture'):
        need(not (app/'Contents/Helpers'/name).exists(), 'gate/test executable in installed app')
    for case in ('copyRetry', 'closeAfterFailure'):
        fields(smoke[case]['helperMetrics'][0]['signature'], dict(helperCDHash=signed['cdHash']), 'runtime helper bound to packaged signature')
    return dict(sourceCommit=source, version=version, build=build, architecture=info['architecture'],
        appPath=str(app), executableSHA256=proof['executableSHA256'], helperSHA256=signed['sha256'], helperCDHash=signed['cdHash'])


def validate(report_path, source, package_proof, source_root):
    path = Path(report_path); root = path.parent.resolve()
    need(path.name not in ('text-script-demo.json', 'text-script-receipt.json'), 'smoke report must differ from raw fixture')
    smoke = C.COMMON.load(path); raw_path = root/'text-script-demo.json'; raw = C.COMMON.load(raw_path)
    launch_path = root/(path.name+'.launcher.json'); launch = C.COMMON.load(launch_path)
    proof_path = Path(package_proof); proof = C.COMMON.load(proof_path)
    report_fields(raw, source); report_fields(smoke, source)
    need(all(type(smoke.get(k)) is type(v) and smoke.get(k) == v for k, v in raw.items()), 'raw and smoke report differ')
    installed = identity(smoke, launch, proof, source, source_root)
    files = {path.name: C.COMMON.read(path), raw_path.name: C.COMMON.read(raw_path),
             launch_path.name: C.COMMON.read(launch_path), 'package-proof': C.COMMON.read(proof_path)}
    def read(name, limit=16*1024**2):
        need(Path(name).name == name and name not in files, 'unsafe/duplicate evidence name')
        data = C.COMMON.read(root/name, limit); files[name] = data
        need(len(files) <= 48 and sum(map(len, files.values())) <= 96*1024**2, 'evidence aggregate bound')
        return data
    image = C.decoded_png(read('text-script-source.png'), 'generated source')
    need(image[:2] == (900, 300) and hashlib.sha256(image[2]).hexdigest() == raw['sourceReference']['canonicalRGBAPixelSHA256'], 'generated pixels differ')
    need(read('text-script-copied.txt', 128*1024) == EXPECTED.encode(), 'physical checked Copy differs')
    for name, key in [('retry', 'copyRetry'), ('close', 'closeAfterFailure')]:
        row = raw[key]
        catalog_bytes = read('text-script-'+name+'-catalog.json', 128*1024)
        need(hashlib.sha256(catalog_bytes).hexdigest() == row['catalogBeforeSHA256'] == row['catalogAfterSHA256'], 'saved catalog bytes differ')
        catalog = C.COMMON.load(root/('text-script-'+name+'-catalog.json'))
        exact_keys(catalog, ('version', 'selectedID', 'definitions'), 'catalog')
        fields(catalog, dict(version=1, selectedID=row['definitionID']), 'catalog')
        need(catalog['definitions'] == [dict(id=row['definitionID'], name=NAME, source=SOURCE_BODY)], 'catalog source/identity differs or contains runtime payload')
        case_bytes = read('text-script-'+name+'-case.json', 2*1024**2)
        need(C.COMMON.load(root/('text-script-'+name+'-case.json')) == row, 'preserved case report differs')
        for artifact_key in (('editorArtifacts', 'failureArtifacts', 'resultArtifacts') if name == 'retry' else ('failureArtifacts',)):
            images = []
            for artifact in row[artifact_key]:
                filename = artifact['filename']; pixels = C.decoded_png(read(filename), filename)
                need(pixels[:2] == (artifact['width'], artifact['height']) and hashlib.sha256(pixels[2]).hexdigest() == artifact['canonicalRGBAPixelSHA256'], 'native PNG differs from layout')
                read(filename[:-4]+'-layout.json', 2*1024**2)
                need(C.COMMON.load(root/(filename[:-4]+'-layout.json')) == artifact, 'persisted raw layout differs')
                images.append(pixels)
            need(images[0] != images[1], 'physical native appearances identical')
    # The additive child is produced by this same installed process. Its reader
    # calls report_fields/identity, never validate, so both contracts stay intact.
    current = module('installed_current_long_image_reader', 'check-live-scroll-text-script-demo.py')
    child = current.validate(path, source, proof_path, source_root)
    fields(child.get('sourceIdentity'), installed, 'current-long-image installed identity')
    expected_child = {'current-long-image/' + name for name in current.EVIDENCE_FILES}
    need(set(child['evidenceSHA256']) == expected_child | {path.name, raw_path.name, launch_path.name, 'package-proof'},
         'current-long-image evidence inventory differs')
    for name, expected in child['evidenceSHA256'].items():
        if name not in files:
            need(name in expected_child, 'unsafe current-long-image evidence name')
            files[name] = C.COMMON.read(root/name)
            need(len(files) <= 48 and sum(map(len, files.values())) <= 96*1024**2, 'evidence aggregate bound')
        need(hashlib.sha256(files[name]).hexdigest() == expected, 'current-long-image evidence changed during validation')
    need(len(files) <= 48 and sum(map(len, files.values())) <= 96*1024**2, 'evidence aggregate bound')
    return dict(schemaVersion=1, status='passed', sourceIdentity=installed, installerAcceptance=False,
        realScreenCaptureAcceptance=False, original227MemoryAcceptance=False, hardMemoryCapClaimed=False,
        scope=SCOPE, exactGeneratedTextOutputVerified=True, onceOnlyCaptureOCRTransformVerified=True,
        checkedCopyRetryAndCloseVerified=True, sourceAndFinalPackageBound=True,
        currentLongImageTextScriptVerified=True, currentLongImage=child,
        evidenceSHA256={name: hashlib.sha256(data).hexdigest() for name, data in sorted(files.items())})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--source', required=True)
    parser.add_argument('--package-proof', type=Path, required=True)
    parser.add_argument('--source-root', type=Path, required=True)
    args = parser.parse_args()
    value = validate(args.report, args.source, args.package_proof, args.source_root)
    output = args.report.parent/'text-script-receipt.json'
    need(not output.is_symlink(), 'receipt destination is symlinked')
    C.COMMON.save(output, value)
    print(json.dumps(dict(status=value['status'], sourceCommit=args.source, receipt=str(output))))


if __name__ == '__main__':
    main()
