#!/usr/bin/env python3
"""Validate combined installed annotation evidence and its bounded file inventory.

This checker verifies identity, required native assertions, cleanup, file hashes,
PNG integrity/dimensions, and resource arithmetic. It does NOT independently
establish renderer correctness from hashes or screenshots. Native assertions are
reported by the three functional fixtures. Unit inputs are never native proof.
"""
import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import stat
import struct

# Reuse the repository's bounded, standard-library PNG decoder (CRC, filters,
# exact inflated length). Apply the tighter annotation bounds before decoding.
_SPEC = importlib.util.spec_from_file_location('annotation_png_decoder', Path(__file__).with_name('check-automatic-mosaic-report.py'))
_PNG = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_PNG)

EDGES = ('top-left', 'top-right', 'bottom-left', 'bottom-right')
FREEHAND_PENCIL = {
    'nativeControlsReachable', 'previewMatchesCommittedPixels', 'draftExcludedFromExport',
    'repeatReleaseNoDuplicate', 'twoUndoRedoCyclesPixelIdentical', 'escapePreservesRedo',
    'toolSwitchDiscardsDraft', 'midStrokeShiftStraight', 'mouseUpEndpointPreserved',
    'singlePointAndTinyMarksVisible', 'selectedSmoothingUndoRedoExact',
}
FREEHAND_HIGHLIGHTER = {
    'nativeControlsReachable', 'freehandAndRectangleReachable', 'blendChangesDarkPixels',
    'selectedBlendUndoRedoExact', 'smoothedReversalRetainsInkAndBlend', 'rectangleHidesStrokeOnlyControls',
}
POINT_CHECKS = {'boundedDuringGesture', 'endpointsPreserved', 'simplificationDisclosed', 'singleUndoState'}
LINE_CHECKS = {
    'nativeEndpointAndStrokeControls', 'draftExcludedFromExport', 'translucentLineCompositedOnce',
    'twoUndoRedoCyclesPixelIdentical', 'cancelledDraftPreservesCommittedPath',
    'selectedHeadEditChangesPixels', 'cancelledVertexDragPreservesRedo',
}
TEXT_CHECKS = {
    'nativeMultilingualInlineInput', 'independentOutlineAndBackground',
    'inlineTypingAndExistingTextOutline', 'inlineInspectorUsesCurrentStyle',
    'continuedEditPreservesIdentityAndRotation', 'cancelledTextAndStylePreservesRedo',
    'twoUndoRedoCyclesPixelIdentical',
}
EDGE_CHECKS = {'frozenImageAnchored', 'paletteInsideWorkspace', 'toolbarPaletteDoNotOverlap'}
CALLOUT_CHECKS = {
    'nativeApplyCallbackMatchesFlattenedPixels', 'allFourEdgePalettesVisibleAndImageAnchored',
    'sourcePixelsUnchanged', 'repeatedControllerAndInlineInputCleanup',
    'manualSevenCreationDeleteUndoRedoAndDocumentCounter',
    'alphaRomanValuesMultilingualCommentsBoundsAndCancelledEdits',
    'moveResizeRotateLeaderEditAndCancelPreserveRedoPixels',
    'explicitRenumberTwoUndoRedoCyclesAndExactPNGCanvasPixels',
    'maximumValueExhaustionUndoAndCancelledCreation',
    'windowTextUndoRedoCopyAndCancelStayWithTextResponder',
    'resizedCommentPreservesImageGeometryAcrossZoomAndResize',
    'activeCommentSaveAndCommandSPreparedPixelsPreserveMosaicGate',
}
STYLES = {'smoothed-pencil', 'multiply-freehand-marker', 'outlined-multilingual-text',
          'diamond-and-filled-triangle-arrow', 'numbered-comment-and-leader'}
REPORTS = {'freehand': 'annotation-freehand-preview.json', 'text-line': 'annotation-text-line-preview.json',
           'callouts': 'annotation-callouts.json'}
FILES = {
    'freehand': {'annotation-freehand-preview.json', 'ui-annotation-pencil-light.png', 'annotation-pencil-result.png',
                 'ui-annotation-highlighter-dark.png', 'annotation-highlighter-result.png', 'annotation-freehand-limit-result.png',
                 *('ui-annotation-freehand-edge-' + edge + '.png' for edge in EDGES),
                 *('annotation-freehand-edge-' + edge + '-result.png' for edge in EDGES)},
    'text-line': {'annotation-text-line-preview.json',
                  *('ui-textline-' + kind + '-' + theme + '.png' for theme in ('light', 'dark') for kind in ('line', 'text', 'inline')),
                  *('textline-' + theme + '-result.png' for theme in ('light', 'dark')),
                  *('ui-textline-edge-' + edge + '.png' for edge in EDGES),
                  *('textline-' + edge + '-result.png' for edge in EDGES)},
    'callouts': {'annotation-callouts.json', 'annotation-callouts-result.png', 'annotation-callout-active-comment-save.png',
                 'ui-callout-light.png', 'ui-callout-dark.png',
                 *('ui-callout-' + edge + '.png' for edge in EDGES)},
}
MAX_FILE_BYTES = 20 * 1024 * 1024
MAX_PNG_PIXELS = 4_000_000


def need(condition, detail):
    if not condition:
        raise ValueError(detail)


def integer(value, minimum=0, maximum=(1 << 63) - 1):
    need(type(value) is int and minimum <= value <= maximum, f'invalid integer: {value!r}')
    return value


def number(value, minimum=0, maximum=120):
    need(type(value) in (float, int) and math.isfinite(value) and minimum < value <= maximum, 'invalid bounded number')
    return value


def exact_integer(value, expected, label):
    need(integer(value) == expected, label)


def flags(obj, keys, value=True):
    for key in keys:
        need(obj[key] is value, ('missing/failed assertion: ' if value else 'unsupported side effect/claim: ') + key)


def hash_string(value):
    need(isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value) is not None, 'invalid SHA256')
    return value


def exact_items(items, expected, label):
    need(type(items) is list and all(isinstance(item, str) for item in items), label)
    need(len(items) == len(expected) and set(items) == set(expected), label)


def no_promoted_claims(obj):
    # Unknown future fields cannot silently promote this observational evidence.
    forbidden = {'processMemoryStabilityVerified', 'stabilityAssessed', 'zeroLeakClaim', 'physicalRetinaVerified',
                 'plateauVerified', 'independentRendererCorrectnessVerified', 'wholeSystemStabilityVerified'}
    if isinstance(obj, dict):
        for key, value in obj.items():
            if key in forbidden:
                need(value is False, 'unsupported promoted claim: ' + key)
            no_promoted_claims(value)
    elif isinstance(obj, list):
        for value in obj:
            no_promoted_claims(value)


def load_json(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            need(key not in result, 'duplicate JSON key: ' + key)
            result[key] = value
        return result
    def invalid(value):
        raise ValueError('nonfinite JSON value: ' + value)
    need(len(data) <= 2 * 1024 * 1024, 'JSON report exceeds bound')
    return json.loads(data, object_pairs_hook=unique, parse_constant=invalid)


def file_bytes(root, folder, name):
    need(folder in FILES and name in FILES[folder] and Path(name).name == name, 'unexpected/unsafe evidence path')
    directory, path = root / folder, root / folder / name
    need(not directory.is_symlink() and directory.resolve().parent == root.resolve(), 'unsafe evidence directory')
    info = path.lstat()
    need(stat.S_ISREG(info.st_mode) and not path.is_symlink() and path.resolve().parent == directory.resolve(), 'unsafe evidence file')
    need(0 < info.st_size <= MAX_FILE_BYTES, 'evidence file exceeds bound')
    with path.open('rb') as stream:
        result = stream.read(MAX_FILE_BYTES + 1)
    need(len(result) == info.st_size and len(result) <= MAX_FILE_BYTES, 'evidence changed/exceeds bound')
    return result


def png_dimensions(data):
    need(len(data) >= 33 and data[:8] == b'\x89PNG\r\n\x1a\n'
         and data[8:16] == b'\x00\x00\x00\rIHDR', 'invalid PNG header')
    width, height = struct.unpack_from('>II', data, 16)
    need(0 < width <= 4096 and 0 < height <= 4096 and width * height <= MAX_PNG_PIXELS, 'PNG dimensions exceed annotation bound')
    offset, idat, ended_data, palette, chunks = 8, False, False, False, 0
    while offset < len(data):
        chunks += 1
        need(chunks <= 16384, 'PNG chunk count exceeds bound')
        need(offset + 12 <= len(data), 'truncated PNG chunk')
        size = struct.unpack_from('>I', data, offset)[0]
        kind = data[offset + 4:offset + 8]
        need(offset + size + 12 <= len(data), 'truncated PNG payload')
        need(all(65 <= c <= 90 or 97 <= c <= 122 for c in kind) and not (kind[2] & 32), 'invalid PNG chunk type')
        need(kind not in (b'acTL', b'fcTL', b'fdAT'), 'animated evidence PNG')
        need(kind[0] & 32 or kind in (b'IHDR', b'PLTE', b'IDAT', b'IEND'), 'unknown critical PNG chunk')
        if kind == b'PLTE':
            need(not palette and not idat and data[25] not in (0, 4) and 0 < size <= 768 and size % 3 == 0, 'invalid PNG palette')
            palette = True
        if kind == b'IDAT':
            need(not ended_data, 'noncontiguous PNG image data')
            idat = True
        elif idat:
            ended_data = True
        offset += size + 12
    need(idat, 'PNG has no image data')
    w, h, _ = _PNG.png_rgba(data)
    need((w, h) == (width, height), 'PNG decoder extent mismatch')
    return w, h


def result_checks(obj, filename, *, freehand):
    exact_integer(obj['nativeSaveCallbackCount'], 1, 'native save callback count')
    need(obj['resultFile'] == filename, 'result file mismatch')
    hash_string(obj['flattenedSHA256'])  # Native normalized pixel digest; not file-byte SHA256.
    flags(obj, {'nativeCancelPreservedInput', 'ownedWindowDetachedOnClose', 'presentationCacheReleasedOnClose',
                'pngRoundTripExact' if freehand else 'pngRoundtripPixelIdentical',
                'pendingStrokeReleasedOnClose' if freehand else 'pendingPathReleasedOnClose'})


def module_common(obj, *, synthetic):
    need(obj['status'] == 'passed', 'native child did not pass')
    flags(obj, {synthetic})
    exact_integer(obj['maximumConcurrentOwnedEditors'], 1, 'editor concurrency changed')
    exact_integer(obj['maximumFixtureRasterPixels'], MAX_PNG_PIXELS, 'native raster bound changed')
    need(isinstance(obj['limitations'], list) and all(isinstance(v, str) for v in obj['limitations']) and obj['limitations'], 'child limitations absent')


def validate_freehand(r):
    module_common(r, synthetic='syntheticDesktop')
    flags(r, {'originalRasterPreserved', 'allOwnedEditorsClosed'})
    flags(r, {'screenCaptureAttempted', 'networkAttempted', 'preferencesWritten', 'pasteboardAccessed'}, False)
    exact_integer(r['maximumGesturePoints'], 2048, 'gesture cap changed')
    width = integer(r['desktopPixelWidth'], 760, 1180)
    height = integer(r['desktopPixelHeight'], 600, 760)
    need(r['resultPixelWidth'] == width - 80 and r['resultPixelHeight'] == height - 240, 'freehand crop dimensions changed')
    exact_items(r['completedChecks'], {'pencil', 'highlighter', 'pointLimit', 'edgePlacement'}, 'missing freehand module check')
    for key, checks, name in [('pencil', FREEHAND_PENCIL, 'pencil'), ('highlighter', FREEHAND_HIGHLIGHTER, 'highlighter'),
                              ('pointLimit', POINT_CHECKS, 'freehand-limit')]:
        flags(r[key], checks)
        result_checks(r[key], 'annotation-' + name + '-result.png', freehand=True)
    integer(r['pointLimit']['retainedPointCount'], 1, 2048)
    need(type(r['edges']) is list and len(r['edges']) == 4, 'freehand edge count')
    exact_items([e['edge'] for e in r['edges']], EDGES, 'freehand edge set')
    for edge in r['edges']:
        flags(edge, EDGE_CHECKS)
        result_checks(edge, 'annotation-freehand-edge-' + edge['edge'] + '-result.png', freehand=True)


def validate_text_line(r):
    module_common(r, synthetic='syntheticDesktop')
    flags(r, {'originalRasterPreserved', 'allOwnedEditorsClosed'})
    flags(r, {'screenCaptureAttempted', 'networkAttempted', 'preferencesWritten', 'generalPasteboardUsed'}, False)
    for key, value in [('sourcePixelsPerPoint', 1), ('snapshotPixelsPerPoint', 1), ('desktopPixelWidth', 760), ('desktopPixelHeight', 600)]:
        exact_integer(r[key], value, 'text/line dimensions changed')
    number(r['nativeDisplayBackingScale'], maximum=4)
    need(type(r['themes']) is list and len(r['themes']) == 2, 'text/line theme count')
    exact_items([e['appearance'] for e in r['themes']], {'light', 'dark'}, 'text/line themes')
    for theme in r['themes']:
        flags(theme['line'], LINE_CHECKS); flags(theme['text'], TEXT_CHECKS)
        exact_integer(theme['line']['committedPointCount'], 4, 'native line point count')
        number(theme['text']['textBoxWidth'], maximum=4096)
        result_checks(theme, 'textline-' + theme['appearance'] + '-result.png', freehand=False)
    need(type(r['edges']) is list and len(r['edges']) == 4, 'text/line edge count')
    exact_items([e['edge'] for e in r['edges']], EDGES, 'text/line edge set')
    for edge in r['edges']:
        flags(edge, EDGE_CHECKS | {'requiredControlsInsidePalette'})
        need(edge['appearance'] == ('light' if EDGES.index(edge['edge']) % 2 == 0 else 'dark'), 'text/line edge theme')
        result_checks(edge, 'textline-' + edge['edge'] + '-result.png', freehand=False)


def validate_callouts(r):
    module_common(r, synthetic='syntheticOwnedWindows')
    flags(r, {'globalInputAttempted', 'screenCaptureAttempted', 'networkAttempted', 'generalPasteboardTouched', 'standardDefaultsWritten'}, False)
    need(type(r['checks']) is dict and set(r['checks']) == CALLOUT_CHECKS, 'missing/unknown callout checks')
    flags(r['checks'], CALLOUT_CHECKS)
    exact_integer(r['closedControllerCount'], 12, 'callout closed controller count')
    exact_integer(r['releasedControllerCount'], 12, 'callout released controller count')
    hash_string(r['exportedSHA256'])
    validate_comment_lifecycle(r['commentLifecycle'])


def lifecycle_milliseconds(value):
    need(type(value) in (float, int) and value >= 0, 'invalid lifecycle milliseconds')
    try:
        finite = math.isfinite(value)
    except OverflowError:
        finite = False
    need(finite, 'nonfinite lifecycle milliseconds')
    return value


def validate_comment_lifecycle(e):
    """Check the bounded observations, never infer native proof from JSON alone.

    Owned graph acceptance remains the scheduled 10 ms prompt check. The earlier
    synchronous observation is reported without asserting immediate retirement.
    The separate 2 s bound applies only to native input/context retirement: the
    307e native minimal control retained inputs at 10/100 ms and not at 1000 ms.
    This is a new framework-only bound, not a widened general leak timeout.
    """
    required = {'contract', 'status', 'expectedCycles', 'pollIntervalMilliseconds',
                'promptOwnershipCheckMilliseconds', 'deferredInputDeadlineMilliseconds',
                'maximumSamples', 'zeroLeakClaim', 'frameworkRetirementOnly', 'cycles',
                'samples', 'peakDeferredInputs', 'peakDeferredContexts',
                'finalDeferredInputs', 'finalDeferredContexts', 'boundRationale'}
    need(type(e) is dict and set(e) == required, 'comment lifecycle fields')
    need(e['contract'] == 'owned-graph-prompt_native-input-deadline-v2', 'comment lifecycle contract')
    need(e['status'] == 'passed', 'comment lifecycle status')
    for key, expected in [('expectedCycles', 6), ('pollIntervalMilliseconds', 10),
                          ('promptOwnershipCheckMilliseconds', 10),
                          ('deferredInputDeadlineMilliseconds', 2000), ('maximumSamples', 256)]:
        exact_integer(e[key], expected, 'comment lifecycle bound changed: ' + key)
    flags(e, {'zeroLeakClaim'}, False)
    flags(e, {'frameworkRetirementOnly'})
    need(type(e['boundRationale']) is str and e['boundRationale'].strip(), 'comment lifecycle bound rationale')

    rows = e['cycles']
    need(type(rows) is list and len(rows) == 6, 'comment lifecycle cycle count')
    row_fields = {'cycle', 'closedAtMilliseconds', 'synchronousCheckedAtMilliseconds',
                  'synchronousRetainedOwners', 'synchronousRetainedTextSystemObjects',
                  'promptCheckedAtMilliseconds', 'promptRetainedOwners',
                  'promptRetainedTextSystemObjects', 'requiredGraphTracked', 'contextWasTracked',
                  'textKit1WasTracked', 'textKit2WasTracked', 'releasedAfterMilliseconds'}
    for cycle, row in enumerate(rows, 1):
        need(type(row) is dict and row_fields <= set(row)
             and set(row) <= row_fields | {'lastRetainedAfterMilliseconds'}, 'comment lifecycle cycle fields')
        exact_integer(row['cycle'], cycle, 'comment lifecycle cycle order')
        closed = lifecycle_milliseconds(row['closedAtMilliseconds'])
        synchronous = lifecycle_milliseconds(row['synchronousCheckedAtMilliseconds'])
        prompt = lifecycle_milliseconds(row['promptCheckedAtMilliseconds'])
        need(closed <= synchronous <= prompt, 'comment lifecycle observation order')
        need(prompt - synchronous >= 10, 'comment lifecycle prompt check preceded scheduled 10 ms')
        integer(row['synchronousRetainedOwners'], 0, 5)
        integer(row['synchronousRetainedTextSystemObjects'], 0, 4)
        exact_integer(row['promptRetainedOwners'], 0, 'comment lifecycle retained prompt owners')
        exact_integer(row['promptRetainedTextSystemObjects'], 0, 'comment lifecycle retained prompt text system')
        flags(row, {'requiredGraphTracked'})
        for key in ('contextWasTracked', 'textKit1WasTracked', 'textKit2WasTracked'):
            need(type(row[key]) is bool, 'comment lifecycle tracking flag: ' + key)
        need(row['textKit1WasTracked'] != row['textKit2WasTracked'], 'comment lifecycle missing/ambiguous TextKit graph')
        released = lifecycle_milliseconds(row['releasedAfterMilliseconds'])
        need(released <= 2000, 'comment lifecycle release exceeded native input deadline')
        if 'lastRetainedAfterMilliseconds' in row:
            lifecycle_milliseconds(row['lastRetainedAfterMilliseconds'])

    samples = e['samples']
    need(type(samples) is list and 1 <= len(samples) <= 256, 'comment lifecycle sample count')
    sample_fields = {'elapsedMilliseconds', 'createdCycles', 'pendingInputCycles',
                     'pendingContextCycles', 'retainedOwnedGraphObjects'}
    previous_created, previous_time = 0, 0
    peak_inputs = peak_contexts = 0
    first_release, last_pending = {}, {}
    for sample in samples:
        need(type(sample) is dict and set(sample) == sample_fields, 'comment lifecycle sample fields')
        elapsed = lifecycle_milliseconds(sample['elapsedMilliseconds'])
        need(elapsed >= previous_time, 'comment lifecycle sample time order')
        created = integer(sample['createdCycles'], 1, 6)
        need(previous_created <= created <= previous_created + 1, 'comment lifecycle sample creation order')
        if created != previous_created:
            row = rows[created - 1]
            need(row['closedAtMilliseconds'] >= previous_time, 'comment lifecycle close preceded previous sample')
            need(elapsed == row['promptCheckedAtMilliseconds'], 'comment lifecycle first sample is not prompt observation')
        exact_integer(sample['retainedOwnedGraphObjects'], 0, 'comment lifecycle retained owned graph')
        for key in ('pendingInputCycles', 'pendingContextCycles'):
            pending = sample[key]
            need(type(pending) is list, 'comment lifecycle pending list')
            for cycle in pending:
                integer(cycle, 1, created)
                if key == 'pendingContextCycles':
                    need(rows[cycle - 1]['contextWasTracked'], 'comment lifecycle pending untracked context')
            need(pending == sorted(set(pending)), 'comment lifecycle pending IDs not unique/sorted')
        peak_inputs = max(peak_inputs, len(sample['pendingInputCycles']))
        peak_contexts = max(peak_contexts, len(sample['pendingContextCycles']))
        pending = set(sample['pendingInputCycles']) | set(sample['pendingContextCycles'])
        for cycle in range(1, created + 1):
            after_close = elapsed - rows[cycle - 1]['closedAtMilliseconds']
            need(after_close >= 0, 'comment lifecycle sample preceded close')
            if cycle in pending:
                need(cycle not in first_release, 'comment lifecycle input/context reappeared after release')
                need(after_close <= 2000, 'comment lifecycle pending beyond native input deadline')
                last_pending[cycle] = after_close
            elif cycle not in first_release:
                first_release[cycle] = after_close
        previous_created, previous_time = created, elapsed

    need(previous_created == 6, 'comment lifecycle missing created cycle evidence')
    for key, count in [('peakDeferredInputs', peak_inputs), ('peakDeferredContexts', peak_contexts),
                       ('finalDeferredInputs', len(samples[-1]['pendingInputCycles'])),
                       ('finalDeferredContexts', len(samples[-1]['pendingContextCycles']))]:
        exact_integer(e[key], count, 'comment lifecycle inconsistent sample count: ' + key)
    need(e['finalDeferredInputs'] == e['finalDeferredContexts'] == 0, 'comment lifecycle final deferred objects')
    for cycle, row in enumerate(rows, 1):
        need(cycle in first_release, 'comment lifecycle missing release observation')
        need(first_release[cycle] <= 2000, 'comment lifecycle observed release exceeded native input deadline')
        need(math.isclose(row['releasedAfterMilliseconds'], first_release[cycle], rel_tol=0, abs_tol=1e-6),
             'comment lifecycle release duration differs from first release sample')
        if cycle in last_pending:
            need('lastRetainedAfterMilliseconds' in row, 'comment lifecycle missing last retained observation')
            need(math.isclose(row['lastRetainedAfterMilliseconds'], last_pending[cycle], rel_tol=0, abs_tol=1e-6),
                 'comment lifecycle last retained duration differs from sample')
        else:
            need('lastRetainedAfterMilliseconds' not in row, 'comment lifecycle invented last retained observation')


def reading(r):
    need(type(r) is dict and set(r) == {'residentBytes', 'physicalFootprintBytes'}, 'memory reading fields')
    integer(r['residentBytes'], 1); integer(r['physicalFootprintBytes'], 1)


def validate_resources(e, *, full):
    need(type(e) is dict, 'missing resource evidence')
    if not full:
        need(set(e) == {'status', 'reason', 'warmupCycles', 'completedMeasuredCycles', 'completedRenderCycles'}, 'early resource scope promoted')
        need(e['status'] == 'not-run' and isinstance(e['reason'], str) and e['reason'], 'early resource status/reason')
        for field in ('warmupCycles', 'completedMeasuredCycles', 'completedRenderCycles'):
            exact_integer(e[field], 0, 'early resources ran')
        return
    need(e['status'] == 'passed', 'resource observations did not pass')
    flags(e, {'observationsComplete', 'sourceByteIdentityVerified', 'sameAuthoredRasterEachCycle', 'sameVectorsEachCycle', 'memoryIsObservational'})
    flags(e, {'nativeGestureActionsExercisedInResourceLoop', 'screenCaptureStarted', 'permissionRequests', 'globalInputPosted',
              'networkUsed', 'generalPasteboardUsed', 'standardDefaultsWritten', 'memoryPressureOrSystemSettingsChanged',
              'allocatorPurgeAttempted', 'stabilityAssessed', 'zeroLeakClaim'}, False)
    counts = {'warmupCycles': 2, 'measuredCycles': 12, 'completedMeasuredCycles': 12, 'completedRenderCycles': 14,
              'sourceWidth': 720, 'sourceHeight': 480, 'sourceBytes': 720 * 480 * 4,
              'marksPerCycle': 5, 'pointsPerCycle': 45, 'maximumPointsPerMark': 128, 'maximumTotalPoints': 256,
              'maximumTextUTF16PerMark': 128, 'maximumRasterPixels': 720 * 480, 'maximumConcurrentOwnedEditors': 1,
              'fixedInputRasterCountAtBaselineAndEveryCycleEnd': 1, 'liveEditorsAtBaselineAndEveryCycleEnd': 0,
              'activeJobsAtBaselineAndEveryCycleEnd': 0, 'fixtureOwnedOutputRastersAtBaselineAndEveryCycleEnd': 0,
              'asyncAnnotationJobsStarted': 0, 'lateIntervalCycles': 1, 'warmupReleaseProbes': 2,
              'measuredReleaseProbes': 12, 'retainedObjects': 0, 'snapshotsInsideMeasuredLoop': 0, 'pngEncodesInsideMeasuredLoop': 0}
    for key, expected in counts.items():
        exact_integer(e[key], expected, 'resource count/bound changed: ' + key)
    need(e['vectorSetup'] == 'direct setContent injection; production canvas preview and flattened renderer', 'resource injection mislabeled')
    exact_items(e['representativeStyles'], STYLES, 'resource styles changed')
    need(hash_string(e['sourceSHA256Before']) == hash_string(e['sourceSHA256After']), 'resource source changed')
    hashes = e['renderSHA256PerCycle']
    need(type(hashes) is list and len(hashes) == 14, 'missing render observations')
    need(len({hash_string(value) for value in hashes}) == 1 and hashes[0] != e['sourceSHA256Before'], 'resource render changed/absent')
    need(type(e['cycleEndStates']) is list and len(e['cycleEndStates']) == 14, 'missing cycle endpoints')
    for index, end in enumerate(e['cycleEndStates'], 1):
        expected = dict(cycle=index, fixedInputRasterCount=1, liveEditors=0, activeJobs=0, fixtureOwnedOutputRasters=0, retainedObjects=0)
        need(type(end) is dict and set(end) == set(expected), 'cycle endpoint fields')
        for key, count in expected.items():
            exact_integer(end[key], count, 'unequal cycle endpoint: ' + key)
    release = e['releaseEvidence']
    need(type(release) is dict and set(release) == {'probeCount', 'retainedControllers', 'retainedCanvases', 'retainedContentViews'}, 'release fields')
    for key in release:
        exact_integer(release[key], 14 if key == 'probeCount' else 0, 'retained resource objects: ' + key)
    need(e['sampleIntervalSeconds'] == 0.05 and e['settlingDelaySeconds'] == 0.15, 'resource sampling interval changed')
    need(e['overallDeadlineSeconds'] == 120 and 0 < number(e['measuredElapsedSeconds']) <= number(e['elapsedSeconds']) < 120, 'resource deadline/duration')
    integer(e['processIdentifier'], 1)
    need(type(e['settledAfterWarmups']) is list and len(e['settledAfterWarmups']) == 2, 'warmup boundaries')
    need(type(e['settledAfterCycles']) is list and len(e['settledAfterCycles']) == 12, 'measured boundaries')
    need(e['settledAfterCycles'][-1] == e['afterMeasuredCycles'], 'measured endpoint mismatch')
    for point in [e['beforeWarmup'], e['baselineAfterWarmup'], *e['settledAfterWarmups'], *e['settledAfterCycles'], e['afterMeasuredCycles'], e['finalAfterCleanup']]:
        reading(point)
    for key, minimum_boundaries in [('warmupSampledMemory', 4), ('sampledMemory', 15)]:
        s = e[key]
        integer(s['timerTickCount'], 1)
        integer(s['boundarySampleCount'], minimum_boundaries)
        total = s['timerTickCount'] + s['boundarySampleCount']
        for field in ('residentSampleCount', 'physicalFootprintSampleCount'):
            exact_integer(s[field], total, 'missing memory samples')
        for field in ('failedResidentSampleCount', 'failedPhysicalFootprintSampleCount'):
            exact_integer(s[field], 0, 'failed memory samples')
        integer(s['peakResidentBytes'], 1); integer(s['peakPhysicalFootprintBytes'], 1)
        # Timer and boundary reads occur separately from settled reads; do not
        # assume a reported peak must exceed a different, unsampled observation.
    for field, label in [('residentBytes', 'resident'), ('physicalFootprintBytes', 'physicalFootprint')]:
        values = [point[field] for point in e['settledAfterCycles']]
        deltas = {'GrowthFromWarmupBytes': values[-1] - e['baselineAfterWarmup'][field],
                  'LastIntervalGrowthBytes': values[-1] - values[-2],
                  'CleanupDeltaBytes': e['finalAfterCleanup'][field] - values[-1]}
        for suffix, expected in deltas.items():
            need(integer(e[label + suffix], -(1 << 63)) == expected, 'inconsistent ' + label + suffix)
        late = e[label + 'LateThreeIntervalGrowthBytes']
        need(type(late) is list and len(late) == 3, 'missing late increments')
        need([integer(v, -(1 << 63)) for v in late] == [values[i] - values[i - 1] for i in range(9, 12)], 'inconsistent late increments')


def validate(r, *, expected_commit, expected_version, expected_build, installed_app, evidence_directory, full):
    need(type(r) is dict and r['status'] == 'passed', 'combined report not passed')
    exact_integer(r['schemaVersion'], 1, 'unknown combined schema')
    need(isinstance(expected_commit, str) and re.fullmatch('[0-9a-f]{40}', expected_commit), 'expected full source commit required')
    need(r['sourceCommit'] == expected_commit and r['version'] == expected_version and r['buildVersion'] == expected_build, 'bundle identity mismatch')
    need(isinstance(r['bundlePath'], str) and Path(r['bundlePath']).is_absolute()
         and Path(r['bundlePath']).resolve() == installed_app.resolve(), 'installed app mismatch')
    need(r['includeResourceCycles'] is full, 'resource scope mismatch')
    flags(r, {'screenCaptureStarted', 'permissionRequests', 'networkUsed', 'globalInputPosted',
              'generalPasteboardUsed', 'standardDefaultsWritten', 'physicalRetinaVerified', 'processMemoryStabilityVerified'}, False)
    no_promoted_claims(r)
    validate_freehand(r['freehand']); validate_text_line(r['textLine']); validate_callouts(r['callouts'])
    validate_resources(r['resourceEvidence'], full=full)
    expected_paths = {folder + '/' + filename for folder, names in FILES.items() for filename in names}
    need(type(r['fileSHA256']) is dict and set(r['fileSHA256']) == expected_paths, 'missing/unknown file hashes')
    children = {'freehand': r['freehand'], 'text-line': r['textLine'], 'callouts': r['callouts']}
    for folder, child in children.items():
        exact_items(child['files'], FILES[folder], 'declared file set mismatch: ' + folder)
        for name in sorted(FILES[folder]):
            data = file_bytes(evidence_directory, folder, name)
            need(hashlib.sha256(data).hexdigest() == hash_string(r['fileSHA256'][folder + '/' + name]), 'file SHA256 mismatch: ' + folder + '/' + name)
            if name.endswith('.json'):
                disk_child = load_json(data)
                need(name == REPORTS[folder] and json.dumps(disk_child, sort_keys=True, allow_nan=False)
                     == json.dumps(child, sort_keys=True, allow_nan=False), 'child report differs from combined report: ' + folder)
                continue
            width, height = png_dimensions(data)
            if folder == 'freehand' and name.endswith('-result.png'):
                expected = (180, 120) if '-edge-' in name else (child['resultPixelWidth'], child['resultPixelHeight'])
                need((width, height) == expected, 'freehand export dimensions')
            elif folder == 'text-line' and name.endswith('-result.png'):
                expected = (680, 360) if name in ('textline-light-result.png', 'textline-dark-result.png') else (180, 120)
                need((width, height) == expected, 'text/line export dimensions')
            elif folder == 'callouts' and name in ('annotation-callouts-result.png', 'annotation-callout-active-comment-save.png'):
                need(700 <= width <= 1120 and 430 <= height <= 590, 'callout export dimensions')
            else:
                need(width >= 760 and height >= 600, 'native UI snapshot is not the declared owned workspace')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', type=Path)
    parser.add_argument('app', type=Path)
    parser.add_argument('source')
    parser.add_argument('version')
    parser.add_argument('build')
    parser.add_argument('--full', action='store_true', help='Require the separately completed 2+12 resource observations')
    args = parser.parse_args()
    need(args.report.stat().st_size <= 2 * 1024 * 1024, 'combined report exceeds bound')
    validate(load_json(args.report.read_bytes()), expected_commit=args.source, expected_version=args.version,
             expected_build=args.build, installed_app=args.app, evidence_directory=args.report.parent, full=args.full)
    print('Installed annotation evidence inventory and native assertions validated; renderer semantics rely on native fixtures; memory remains observational')


if __name__ == '__main__':
    main()
