"""Adversarial schema/file inputs only, never installed macOS evidence."""
import copy
import functools
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import zlib

SPEC = importlib.util.spec_from_file_location('annotation_check', Path(__file__).resolve().parents[1] / 'check-annotation-details-report.py')
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)


def png(width, height, *, mode=0, color=6):
    channels = {0: 1, 2: 3, 4: 2, 6: 4}[color]
    pixel = {0: b'\x80', 2: b'\x80\x70\x60', 4: b'\x80\xff', 6: b'\x80\x70\x60\xff'}[color]
    row = pixel * width
    previous = bytes(len(row))
    raw = bytearray()
    for _ in range(height):
        raw.append(mode)
        for x, value in enumerate(row):
            a, b, c = (row[x - channels] if x >= channels else 0), previous[x], (previous[x - channels] if x >= channels else 0)
            if mode == 0: predictor = 0
            elif mode == 1: predictor = a
            elif mode == 2: predictor = b
            elif mode == 3: predictor = (a + b) // 2
            elif mode == 4:
                p = a + b - c
                distances = (abs(p-a), abs(p-b), abs(p-c))
                predictor = (a, b, c)[distances.index(min(distances))]
            else: predictor = 0
            raw.append((value - predictor) & 255)
        previous = row
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, color, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


def memory(rss, footprint):
    return dict(residentBytes=rss, physicalFootprintBytes=footprint)


def resources():
    # Positive late increments deliberately pass: this is not a plateau gate.
    ends = [memory(1_000_000 + i * 100, 900_000 + i * 70) for i in range(12)]
    stats = dict(timerTickCount=20, boundarySampleCount=15, residentSampleCount=35, physicalFootprintSampleCount=35,
                 failedResidentSampleCount=0, failedPhysicalFootprintSampleCount=0,
                 peakResidentBytes=2_000_000, peakPhysicalFootprintBytes=1_800_000)
    r = dict(status='passed', observationsComplete=True, warmupCycles=2, measuredCycles=12,
             completedMeasuredCycles=12, completedRenderCycles=14, sourceWidth=720, sourceHeight=480, sourceBytes=720*480*4,
             sourceSHA256Before='b'*64, sourceSHA256After='b'*64, sourceByteIdentityVerified=True,
             renderSHA256PerCycle=['c'*64]*14, sameAuthoredRasterEachCycle=True, sameVectorsEachCycle=True,
             vectorSetup='direct setContent injection; production canvas preview and flattened renderer',
             nativeGestureActionsExercisedInResourceLoop=False, representativeStyles=sorted(CHECK.STYLES),
             marksPerCycle=5, pointsPerCycle=45, maximumPointsPerMark=128, maximumTotalPoints=256,
             maximumTextUTF16PerMark=128, maximumRasterPixels=720*480, maximumConcurrentOwnedEditors=1,
             fixedInputRasterCountAtBaselineAndEveryCycleEnd=1, liveEditorsAtBaselineAndEveryCycleEnd=0,
             activeJobsAtBaselineAndEveryCycleEnd=0, fixtureOwnedOutputRastersAtBaselineAndEveryCycleEnd=0,
             asyncAnnotationJobsStarted=0,
             cycleEndStates=[dict(cycle=i, fixedInputRasterCount=1, liveEditors=0, activeJobs=0,
                                  fixtureOwnedOutputRasters=0, retainedObjects=0) for i in range(1, 15)],
             sampleIntervalSeconds=0.05, settlingDelaySeconds=0.15, overallDeadlineSeconds=120,
             elapsedSeconds=8, measuredElapsedSeconds=6, processIdentifier=123,
             beforeWarmup=memory(800_000, 700_000), baselineAfterWarmup=memory(1_000_000, 900_000),
             settledAfterWarmups=[memory(900_000, 800_000), memory(1_000_000, 900_000)],
             warmupSampledMemory=copy.deepcopy(stats), sampledMemory=copy.deepcopy(stats),
             settledAfterCycles=ends, afterMeasuredCycles=ends[-1], finalAfterCleanup=memory(1_000_900, 900_700),
             lateIntervalCycles=1, warmupReleaseProbes=2, measuredReleaseProbes=12, retainedObjects=0,
             releaseEvidence=dict(probeCount=14, retainedControllers=0, retainedCanvases=0, retainedContentViews=0),
             snapshotsInsideMeasuredLoop=0, pngEncodesInsideMeasuredLoop=0, memoryIsObservational=True)
    for key in ('screenCaptureStarted', 'permissionRequests', 'globalInputPosted', 'networkUsed', 'generalPasteboardUsed',
                'standardDefaultsWritten', 'memoryPressureOrSystemSettingsChanged', 'allocatorPurgeAttempted', 'stabilityAssessed', 'zeroLeakClaim'):
        r[key] = False
    for field, label in [('residentBytes', 'resident'), ('physicalFootprintBytes', 'physicalFootprint')]:
        values = [end[field] for end in ends]
        r[label+'GrowthFromWarmupBytes'] = values[-1] - r['baselineAfterWarmup'][field]
        r[label+'LastIntervalGrowthBytes'] = values[-1] - values[-2]
        r[label+'LateThreeIntervalGrowthBytes'] = [values[i] - values[i-1] for i in range(9, 12)]
        r[label+'CleanupDeltaBytes'] = r['finalAfterCleanup'][field] - values[-1]
    return r


def saved_result(filename, *, freehand):
    r = dict(nativeSaveCallbackCount=1, resultFile=filename, flattenedSHA256='d'*64,
             nativeCancelPreservedInput=True, ownedWindowDetachedOnClose=True, presentationCacheReleasedOnClose=True)
    r['pngRoundTripExact' if freehand else 'pngRoundtripPixelIdentical'] = True
    r['pendingStrokeReleasedOnClose' if freehand else 'pendingPathReleasedOnClose'] = True
    return r


def comment_lifecycle():
    """Synthetic staggered retirement, including overlapping native objects.

    This fixture tests the JSON contract only. It supplies no macOS lifecycle
    evidence and cannot establish that a prompt/native deadline actually passes.
    """
    rows = []
    released = [50.25, 50.25, 70.25, 10.25, 50.25, 30.25]
    retained = [40.25, 40.25, 40.25, None, 40.25, 20.25]
    for cycle in range(1, 7):
        closed = (cycle - 1) * 30
        row = dict(cycle=cycle, closedAtMilliseconds=closed,
                   synchronousCheckedAtMilliseconds=closed + 0.25,
                   synchronousRetainedOwners=5, synchronousRetainedTextSystemObjects=4,
                   promptCheckedAtMilliseconds=closed + 10.25,
                   promptRetainedOwners=0, promptRetainedTextSystemObjects=0,
                   requiredGraphTracked=True, contextWasTracked=cycle not in (2, 6),
                   textKit1WasTracked=cycle % 2 == 1, textKit2WasTracked=cycle % 2 == 0,
                   releasedAfterMilliseconds=released[cycle - 1])
        if retained[cycle - 1] is not None:
            row['lastRetainedAfterMilliseconds'] = retained[cycle - 1]
        rows.append(row)
    observations = [
        (10.25, 1, [1], [1]), (20.25, 1, [1], [1]),
        (40.25, 2, [1, 2], [1]), (50.25, 2, [2], []),
        (70.25, 3, [2, 3], [3]), (80.25, 3, [3], [3]),
        (100.25, 4, [3], [3]), (130.25, 5, [5], [5]),
        (160.25, 6, [5, 6], [5]), (170.25, 6, [6], []),
        (180.25, 6, [], []),
    ]
    samples = [dict(elapsedMilliseconds=elapsed, createdCycles=created,
                    pendingInputCycles=inputs, pendingContextCycles=contexts,
                    retainedOwnedGraphObjects=0) for elapsed, created, inputs, contexts in observations]
    return dict(contract='owned-graph-prompt_native-input-deadline-v2', status='passed', expectedCycles=6,
                pollIntervalMilliseconds=10, promptOwnershipCheckMilliseconds=10,
                deferredInputDeadlineMilliseconds=2000, maximumSamples=256,
                zeroLeakClaim=False, frameworkRetirementOnly=True, cycles=rows, samples=samples,
                peakDeferredInputs=2, peakDeferredContexts=1, finalDeferredInputs=0, finalDeferredContexts=0,
                boundRationale='New framework-only 2 s retirement bound: native 307e minimal control retained inputs '
                               'at 10/100 ms and released them by 1000 ms; scheduled prompt ownership stays at 10 ms. '
                               'This synthetic schema fixture is not native evidence.')


def modules():
    common = dict(status='passed', syntheticDesktop=True, maximumConcurrentOwnedEditors=1, maximumFixtureRasterPixels=4_000_000,
                  screenCaptureAttempted=False, networkAttempted=False, preferencesWritten=False,
                  originalRasterPreserved=True, allOwnedEditorsClosed=True,
                  limitations=['Schema fixture only; not a native test'])
    free = dict(common, pasteboardAccessed=False, maximumGesturePoints=2048,
                desktopPixelWidth=760, desktopPixelHeight=600, resultPixelWidth=680, resultPixelHeight=360,
                completedChecks=['pencil', 'highlighter', 'pointLimit', 'edgePlacement'], files=sorted(CHECK.FILES['freehand']), edges=[])
    for key, checks, name in [('pencil', CHECK.FREEHAND_PENCIL, 'pencil'), ('highlighter', CHECK.FREEHAND_HIGHLIGHTER, 'highlighter'),
                              ('pointLimit', CHECK.POINT_CHECKS, 'freehand-limit')]:
        free[key] = saved_result('annotation-' + name + '-result.png', freehand=True)
        free[key].update({key: True for key in checks})
    free['pointLimit']['retainedPointCount'] = 2048
    text = dict(common, generalPasteboardUsed=False, sourcePixelsPerPoint=1, snapshotPixelsPerPoint=1,
                desktopPixelWidth=760, desktopPixelHeight=600, nativeDisplayBackingScale=2,
                files=sorted(CHECK.FILES['text-line']), themes=[], edges=[])
    for appearance in ('light', 'dark'):
        theme = saved_result('textline-' + appearance + '-result.png', freehand=False)
        theme.update(appearance=appearance, line={key: True for key in CHECK.LINE_CHECKS}, text={key: True for key in CHECK.TEXT_CHECKS})
        theme['line']['committedPointCount'] = 4; theme['text']['textBoxWidth'] = 300
        text['themes'].append(theme)
    for index, edge in enumerate(CHECK.EDGES):
        value = saved_result('annotation-freehand-edge-' + edge + '-result.png', freehand=True)
        value.update({key: True for key in CHECK.EDGE_CHECKS}); value['edge'] = edge
        free['edges'].append(value)
        value = saved_result('textline-' + edge + '-result.png', freehand=False)
        value.update({key: True for key in CHECK.EDGE_CHECKS | {'requiredControlsInsidePalette'}})
        value.update(edge=edge, appearance='light' if index % 2 == 0 else 'dark')
        text['edges'].append(value)
    call = dict(status='passed', syntheticOwnedWindows=True, maximumConcurrentOwnedEditors=1, maximumFixtureRasterPixels=4_000_000,
                globalInputAttempted=False, screenCaptureAttempted=False, networkAttempted=False,
                generalPasteboardTouched=False, standardDefaultsWritten=False,
                checks={key: True for key in CHECK.CALLOUT_CHECKS}, files=sorted(CHECK.FILES['callouts']), exportedSHA256='e'*64,
                closedControllerCount=12, releasedControllerCount=12, commentLifecycle=comment_lifecycle(),
                limitations=['Schema fixture only; not native evidence'])
    return free, text, call


class CommentLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.lifecycle = comment_lifecycle()

    def reject(self, mutate, message=None):
        candidate = copy.deepcopy(self.lifecycle)
        mutate(candidate)
        # Validate the lifecycle directly: child JSON/hash disagreement must not
        # hide an acceptance hole in the lifecycle validator under test.
        with self.assertRaisesRegex(ValueError, message or '.'):
            CHECK.validate_comment_lifecycle(candidate)

    def test_overlapping_framework_retirement_and_nonzero_synchronous_observations_pass(self):
        CHECK.validate_comment_lifecycle(self.lifecycle)
        self.assertEqual(self.lifecycle['cycles'][0]['releasedAfterMilliseconds'], 50.25)
        self.assertGreater(self.lifecycle['cycles'][0]['synchronousRetainedOwners'], 0)
        self.assertNotIn('lastRetainedAfterMilliseconds', self.lifecycle['cycles'][3])

    def test_zero_synchronous_observations_and_context_only_retirement_pass(self):
        for row in self.lifecycle['cycles']:
            row.update(synchronousRetainedOwners=0, synchronousRetainedTextSystemObjects=0)
        self.lifecycle['samples'][0]['pendingInputCycles'] = []
        CHECK.validate_comment_lifecycle(self.lifecycle)

    def test_callout_contract_requires_lifecycle_and_preserves_original_checks(self):
        callouts = modules()[2]
        CHECK.validate_callouts(callouts)
        del callouts['commentLifecycle']
        with self.assertRaises(KeyError): CHECK.validate_callouts(callouts)
        for field in ('closedControllerCount', 'releasedControllerCount'):
            callouts = modules()[2]
            callouts[field] = 6
            with self.assertRaisesRegex(ValueError, 'controller count'): CHECK.validate_callouts(callouts)
        for key in CHECK.CALLOUT_CHECKS:
            with self.subTest(check=key):
                callouts = modules()[2]
                callouts['checks'].pop(key)
                with self.assertRaisesRegex(ValueError, 'callout checks'): CHECK.validate_callouts(callouts)

    def test_missing_unknown_or_partial_lifecycle_fields_rejected(self):
        for key in self.lifecycle:
            with self.subTest(missing=key): self.reject(lambda e: e.pop(key), 'lifecycle fields')
        for key in self.lifecycle['cycles'][0]:
            if key != 'lastRetainedAfterMilliseconds':
                with self.subTest(missing_cycle=key): self.reject(lambda e: e['cycles'][0].pop(key), 'cycle fields')
        for key in self.lifecycle['samples'][0]:
            with self.subTest(missing_sample=key): self.reject(lambda e: e['samples'][0].pop(key), 'sample fields')
        for mutate in [lambda e: e.update(ownedGraphDelayMilliseconds=0),
                       lambda e: e['cycles'][0].update(unverifiedGraph=True),
                       lambda e: e['samples'][0].update(retainedOwners=0),
                       lambda e: e['cycles'].pop(), lambda e: e.update(cycles=[]),
                       lambda e: e.update(samples=[]), lambda e: e.update(samples=[e['samples'][-1]])]:
            with self.subTest(mutation=mutate): self.reject(mutate)

    def test_fixed_contract_bounds_status_and_claims(self):
        for key, values in [
                ('contract', ['owned-graph-immediate_native-input-deadline-v2', 'v1']),
                ('status', ['not-run', 'failed']), ('expectedCycles', [5, 7, True, 6.0]),
                ('pollIntervalMilliseconds', [0, 11, 100]),
                ('promptOwnershipCheckMilliseconds', [0, 9, 11, 2000]),
                ('deferredInputDeadlineMilliseconds', [1000, 2001, 10_000]),
                ('maximumSamples', [255, 257, True]), ('zeroLeakClaim', [True, 0]),
                ('frameworkRetirementOnly', [False, 1]), ('boundRationale', ['', '  \n', None, 1])]:
            for value in values:
                with self.subTest(field=key, value=value): self.reject(lambda e: e.update({key: value}))

    def test_prompt_and_owned_graph_retention_rejected(self):
        for key in ('promptRetainedOwners', 'promptRetainedTextSystemObjects'):
            for value in (1, -1, False, 0.0):
                with self.subTest(field=key, value=value): self.reject(lambda e: e['cycles'][0].update({key: value}))
        self.reject(lambda e: e['cycles'][0].update(promptCheckedAtMilliseconds=0.25), 'scheduled 10 ms')
        self.reject(lambda e: e['cycles'][0].update(synchronousCheckedAtMilliseconds=1), 'scheduled 10 ms')
        self.reject(lambda e: e['cycles'][0].update(synchronousCheckedAtMilliseconds=11), 'observation order')
        self.reject(lambda e: e['cycles'][0].update(closedAtMilliseconds=1), 'observation order')
        self.reject(lambda e: e['cycles'][0].update(promptCheckedAtMilliseconds=11), 'first sample')
        for value in (1, -1, False, 0.0):
            with self.subTest(sample_retention=value):
                self.reject(lambda e: e['samples'][4].update(retainedOwnedGraphObjects=value), 'integer|retained owned graph')
        for key, bad in [('synchronousRetainedOwners', 6), ('synchronousRetainedTextSystemObjects', 5)]:
            for value in (-1, bad, True, 0.5):
                with self.subTest(synchronous=key, value=value): self.reject(lambda e: e['cycles'][0].update({key: value}))

    def test_false_or_ambiguous_tracking_rejected(self):
        for value in (False, 1, None):
            with self.subTest(required=value): self.reject(lambda e: e['cycles'][0].update(requiredGraphTracked=value))
        for key in ('contextWasTracked', 'textKit1WasTracked', 'textKit2WasTracked'):
            with self.subTest(flag=key): self.reject(lambda e: e['cycles'][0].update({key: 1}), 'tracking flag')
        self.reject(lambda e: e['cycles'][0].update(contextWasTracked=False), 'untracked context')
        self.reject(lambda e: e['cycles'][0].update(textKit1WasTracked=False), 'TextKit graph')
        self.reject(lambda e: e['cycles'][0].update(textKit2WasTracked=True), 'TextKit graph')

    def test_nonfinite_negative_or_nonnumeric_times_rejected(self):
        for key in ('closedAtMilliseconds', 'synchronousCheckedAtMilliseconds', 'promptCheckedAtMilliseconds',
                    'releasedAfterMilliseconds', 'lastRetainedAfterMilliseconds'):
            for value in (float('nan'), float('inf'), -float('inf'), -1, True, '10', None, 10 ** 1000):
                with self.subTest(field=key, value=value): self.reject(lambda e: e['cycles'][0].update({key: value}))
        for value in (float('nan'), float('inf'), -float('inf'), -1, True, '10', None, 10 ** 1000):
            with self.subTest(sample_time=value): self.reject(lambda e: e['samples'][0].update(elapsedMilliseconds=value))

    def test_cycle_and_sample_order_rejected(self):
        self.reject(lambda e: e['cycles'].reverse(), 'cycle order')
        self.reject(lambda e: e['cycles'][1].update(cycle=1), 'cycle order')
        self.reject(lambda e: e['samples'][1].update(elapsedMilliseconds=9), 'time order')
        self.reject(lambda e: e['samples'][0].update(createdCycles=2), 'creation order')
        self.reject(lambda e: e['samples'][4].update(createdCycles=2), 'integer')
        self.reject(lambda e: e['samples'][3].update(createdCycles=1), 'creation order')
        self.reject(lambda e: e['samples'][2].update(createdCycles=3), 'creation order')
        self.reject(lambda e: e['samples'][1].update(elapsedMilliseconds=31), 'close preceded previous sample')
        for value in (0, 7, True, 1.0):
            with self.subTest(created=value): self.reject(lambda e: e['samples'][0].update(createdCycles=value))

    def test_pending_ids_must_be_valid_unique_sorted_and_created(self):
        for key in ('pendingInputCycles', 'pendingContextCycles'):
            for value in (None, (1,), [0], [7], [True], [1.0], [1, 1], [2, 1]):
                with self.subTest(field=key, value=value): self.reject(lambda e: e['samples'][2].update({key: value}))
            self.reject(lambda e: e['samples'][0].update({key: [2]}))

    def test_input_or_context_cannot_reappear_after_union_released(self):
        for key in ('pendingInputCycles', 'pendingContextCycles'):
            with self.subTest(field=key):
                self.reject(lambda e: e['samples'][4][key].insert(0, 1), 'reappeared after release')
        self.reject(lambda e: e['samples'][8]['pendingInputCycles'].insert(0, 4), 'reappeared after release')

    def test_missing_or_invented_retention_and_release_evidence(self):
        self.reject(lambda e: e['cycles'][0].pop('lastRetainedAfterMilliseconds'), 'missing last retained')
        self.reject(lambda e: e['cycles'][3].update(lastRetainedAfterMilliseconds=0), 'invented last retained')
        self.reject(lambda e: e['cycles'][0].update(lastRetainedAfterMilliseconds=20.25), 'last retained duration')
        self.reject(lambda e: e['cycles'][0].update(releasedAfterMilliseconds=40.25), 'first release sample')
        self.reject(lambda e: e['cycles'][0].update(releasedAfterMilliseconds=70.25), 'first release sample')
        self.reject(lambda e: e['samples'].pop(), 'inconsistent sample count')
        self.reject(lambda e: e.update(samples=e['samples'][:8]), 'missing created cycle')

    def test_late_pending_and_late_release_rejected(self):
        for key in ('pendingInputCycles', 'pendingContextCycles'):
            def late(e):
                e['samples'][-1].update(elapsedMilliseconds=2150.01, **{key: [6]})
                e['cycles'][5]['contextWasTracked'] = True
            with self.subTest(field=key): self.reject(late, 'pending beyond native input deadline')
        self.reject(lambda e: e['samples'][-1].update(elapsedMilliseconds=2150.01), 'observed release exceeded')
        self.reject(lambda e: e['cycles'][5].update(releasedAfterMilliseconds=2000.01), 'release exceeded')

    def test_exact_deadline_and_small_duration_roundoff_pass(self):
        self.lifecycle['samples'][-1]['elapsedMilliseconds'] = 2150
        self.lifecycle['cycles'][5]['releasedAfterMilliseconds'] = 2000
        CHECK.validate_comment_lifecycle(self.lifecycle)
        self.lifecycle['cycles'][0]['releasedAfterMilliseconds'] += 0.0000005
        self.lifecycle['cycles'][0]['lastRetainedAfterMilliseconds'] -= 0.0000005
        CHECK.validate_comment_lifecycle(self.lifecycle)
        self.reject(lambda e: e['cycles'][0].update(releasedAfterMilliseconds=50.250002), 'release duration')
        self.reject(lambda e: e['cycles'][0].update(lastRetainedAfterMilliseconds=40.249998), 'last retained duration')

    def test_peak_final_counts_and_final_retirement_must_match_samples(self):
        for key in ('peakDeferredInputs', 'peakDeferredContexts', 'finalDeferredInputs', 'finalDeferredContexts'):
            for value in (99, True, -1, 0.5):
                with self.subTest(field=key, value=value): self.reject(lambda e: e.update({key: value}))
        self.reject(lambda e: e.update(peakDeferredInputs=1), 'inconsistent sample count')
        self.reject(lambda e: e.update(peakDeferredContexts=2), 'inconsistent sample count')
        def retained_final(e):
            e['samples'][-1]['pendingInputCycles'] = [6]
            e['finalDeferredInputs'] = 1
        self.reject(retained_final, 'final deferred objects')

    def test_sample_bound_is_enforced_including_extra_valid_polls(self):
        final = self.lifecycle['samples'][-1]
        self.lifecycle['samples'].extend(copy.deepcopy(final) for _ in range(256 - len(self.lifecycle['samples'])))
        CHECK.validate_comment_lifecycle(self.lifecycle)
        self.reject(lambda e: e['samples'].append(copy.deepcopy(e['samples'][-1])), 'sample count')


class AnnotationReportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Many native screenshots share dimensions. Reuse synthetic PNG bytes;
        # cached decoding below still runs the real CRC/filter decoder for each
        # distinct byte string, including every tamper case.
        cls.pngs = {(w, h): png(w, h) for w, h in [(760, 600), (680, 360), (180, 120), (700, 430)]}
        cls.cached_dimensions = functools.lru_cache(maxsize=16)(CHECK.png_dimensions)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='annotation-checker-schema-only-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.freehand, self.text, self.callouts = modules()
        self.report = dict(status='passed', schemaVersion=1, sourceCommit='a'*40, version='0.13.0', buildVersion='13',
                           bundlePath=str(self.root/'PicShot.app'), includeResourceCycles=True,
                           freehand=self.freehand, textLine=self.text, callouts=self.callouts, resourceEvidence=resources(), fileSHA256={})
        for key in ('screenCaptureStarted', 'permissionRequests', 'networkUsed', 'globalInputPosted', 'generalPasteboardUsed',
                    'standardDefaultsWritten', 'physicalRetinaVerified', 'processMemoryStabilityVerified'):
            self.report[key] = False
        for folder, names in CHECK.FILES.items():
            (self.root/folder).mkdir()
            for name in names:
                if name.endswith('.json'):
                    continue
                size = (760, 600)
                if name.endswith('-result.png') or name == 'annotation-callout-active-comment-save.png':
                    if folder == 'callouts': size = (700, 430)
                    elif ('edge-' in name or any(edge in name for edge in CHECK.EDGES)): size = (180, 120)
                    else: size = (680, 360)
                self.replace_file(folder, name, self.pngs[size])
        self.sync_children()
        self.addCleanup(patch.stopall)
        patch.object(CHECK, 'png_dimensions', type(self).cached_dimensions).start()

    def replace_file(self, folder, name, data):
        (self.root/folder/name).write_bytes(data)
        self.report['fileSHA256'][folder+'/'+name] = hashlib.sha256(data).hexdigest()

    def sync_children(self):
        for folder, key in [('freehand', 'freehand'), ('text-line', 'textLine'), ('callouts', 'callouts')]:
            self.replace_file(folder, CHECK.REPORTS[folder], json.dumps(self.report[key]).encode())

    def check(self, report=None, *, full=True):
        CHECK.validate(self.report if report is None else report, expected_commit='a'*40, expected_version='0.13.0', expected_build='13',
                       installed_app=self.root/'PicShot.app', evidence_directory=self.root, full=full)

    def reject(self, mutate):
        candidate = copy.deepcopy(self.report)
        mutate(candidate)
        with self.assertRaises((ValueError, KeyError, TypeError, FileNotFoundError)):
            self.check(candidate)

    def test_complete_full_schema_and_positive_memory_growth_pass(self):
        self.check()
        self.assertGreater(self.report['resourceEvidence']['residentLastIntervalGrowthBytes'], 0)

    def test_early_is_explicitly_unrun_and_cannot_pass_full(self):
        self.report['includeResourceCycles'] = False
        self.report['resourceEvidence'] = dict(status='not-run', reason='Early functional evidence only',
                                               warmupCycles=0, completedMeasuredCycles=0, completedRenderCycles=0)
        self.check(full=False)
        with self.assertRaises(ValueError): self.check(full=True)
        self.report['includeResourceCycles'] = True
        with self.assertRaises((ValueError, KeyError)): self.check(full=True)

    def test_early_cannot_include_observations_or_promote_claims(self):
        self.report['includeResourceCycles'] = False
        self.report['resourceEvidence'] = dict(status='not-run', reason='Early only', warmupCycles=0,
                                               completedMeasuredCycles=0, completedRenderCycles=0, observationsComplete=True)
        with self.assertRaises(ValueError): self.check(full=False)

    def test_identity_status_and_false_claim_tampering(self):
        for mutate in [lambda r: r.update(sourceCommit='f'*40), lambda r: r.update(version='0.12.0'),
                       lambda r: r.update(buildVersion='12'), lambda r: r.update(bundlePath=str(self.root/'Other.app')),
                       lambda r: r.update(bundlePath='PicShot.app'), lambda r: r.update(status='running'),
                       lambda r: r.update(includeResourceCycles=False), lambda r: r.update(schemaVersion=True)]:
            with self.subTest(mutate=mutate): self.reject(mutate)
        for key in ('screenCaptureStarted', 'permissionRequests', 'networkUsed', 'globalInputPosted', 'generalPasteboardUsed',
                    'standardDefaultsWritten', 'physicalRetinaVerified', 'processMemoryStabilityVerified', 'zeroLeakClaim', 'plateauVerified'):
            with self.subTest(key=key): self.reject(lambda r: r.update({key: True}))
        self.reject(lambda r: r.update(networkUsed=0))

    def test_every_required_native_check_is_required(self):
        paths = [('freehand', 'pencil', key) for key in CHECK.FREEHAND_PENCIL]
        paths += [('freehand', 'highlighter', key) for key in CHECK.FREEHAND_HIGHLIGHTER]
        paths += [('freehand', 'pointLimit', key) for key in CHECK.POINT_CHECKS]
        paths += [('callouts', 'checks', key) for key in CHECK.CALLOUT_CHECKS]
        for path in paths:
            with self.subTest(path=path): self.reject(lambda r: r[path[0]][path[1]].pop(path[2]))
        for group, keys in [('line', CHECK.LINE_CHECKS), ('text', CHECK.TEXT_CHECKS)]:
            for key in keys:
                with self.subTest(group=group, key=key): self.reject(lambda r: r['textLine']['themes'][0][group].pop(key))
        self.reject(lambda r: r['freehand']['completedChecks'].remove('edgePlacement'))
        self.reject(lambda r: r['textLine']['themes'].pop())
        self.reject(lambda r: r['freehand']['edges'].pop())
        self.reject(lambda r: r['textLine']['edges'][0].update(requiredControlsInsidePalette=False))

    def test_native_cleanup_and_callback_failures(self):
        for mutate in [lambda r: r['freehand']['pencil'].update(ownedWindowDetachedOnClose=False),
                       lambda r: r['freehand']['pointLimit'].update(pendingStrokeReleasedOnClose=False),
                       lambda r: r['textLine']['themes'][0].update(pendingPathReleasedOnClose=False),
                       lambda r: r['textLine']['themes'][1].update(nativeSaveCallbackCount=2),
                       lambda r: r['textLine']['edges'][0].update(presentationCacheReleasedOnClose=False),
                       lambda r: r['callouts'].update(releasedControllerCount=11),
                       lambda r: r['freehand'].update(allOwnedEditorsClosed=False),
                       lambda r: r['freehand']['pointLimit'].update(retainedPointCount=2049),
                       lambda r: r['textLine']['themes'][0]['line'].update(committedPointCount=3)]:
            with self.subTest(mutate=mutate): self.reject(mutate)

    def test_resources_missing_unrun_retained_or_mislabeled(self):
        changes = [lambda e: e.update(status='not-run'), lambda e: e.update(completedMeasuredCycles=11),
                   lambda e: e.update(completedRenderCycles=13), lambda e: e.update(observationsComplete=False),
                   lambda e: e.update(sourceSHA256After='f'*64), lambda e: e.update(renderSHA256PerCycle=['b'*64]*14),
                   lambda e: e['renderSHA256PerCycle'].pop(), lambda e: e.update(retainedObjects=1),
                   lambda e: e['releaseEvidence'].update(retainedCanvases=1),
                   lambda e: e['cycleEndStates'][5].update(retainedObjects=1),
                   lambda e: e['cycleEndStates'][5].update(activeJobs=1),
                   lambda e: e['cycleEndStates'][5].update(fixedInputRasterCount=2),
                   lambda e: e['cycleEndStates'][5].update(fixtureOwnedOutputRasters=1),
                   lambda e: e.update(nativeGestureActionsExercisedInResourceLoop=True),
                   lambda e: e.update(vectorSetup='native gestures'), lambda e: e.update(stabilityAssessed=True),
                   lambda e: e.update(zeroLeakClaim=True), lambda e: e.update(allocatorPurgeAttempted=True),
                   lambda e: e.update(snapshotsInsideMeasuredLoop=1), lambda e: e.update(pngEncodesInsideMeasuredLoop=1),
                   lambda e: e.update(elapsedSeconds=121), lambda e: e.update(measuredElapsedSeconds=float('nan')),
                   lambda e: e.update(sourceWidth=4096), lambda e: e.update(maximumTextUTF16PerMark=100000)]
        for mutate in changes:
            with self.subTest(mutate=mutate): self.reject(lambda r: mutate(r['resourceEvidence']))
        self.reject(lambda r: r.pop('resourceEvidence'))

    def test_inconsistent_rss_footprint_samples_and_deltas(self):
        for label in ('resident', 'physicalFootprint'):
            for suffix in ('GrowthFromWarmupBytes', 'LastIntervalGrowthBytes', 'CleanupDeltaBytes'):
                key = label + suffix
                with self.subTest(key=key): self.reject(lambda r: r['resourceEvidence'].update({key: 777}))
            self.reject(lambda r: r['resourceEvidence'].update({label+'LateThreeIntervalGrowthBytes': [0, 0, 0]}))
        changes = [lambda e: e['sampledMemory'].update(residentSampleCount=34),
                   lambda e: e['warmupSampledMemory'].update(failedPhysicalFootprintSampleCount=1),
                   lambda e: e['sampledMemory'].update(timerTickCount=0),
                   lambda e: e['settledAfterCycles'].pop(), lambda e: e['settledAfterWarmups'].pop(),
                   lambda e: e.update(afterMeasuredCycles=memory(1, 1)),
                   lambda e: e.update(finalAfterCleanup=memory(True, 1)),
                   lambda e: e.update(residentGrowthFromWarmupBytes=True)]
        for mutate in changes:
            with self.subTest(mutate=mutate): self.reject(lambda r: mutate(r['resourceEvidence']))

    def test_inventory_missing_extra_duplicate_or_wrong_hash(self):
        self.reject(lambda r: r['fileSHA256'].pop('freehand/annotation-pencil-result.png'))
        self.reject(lambda r: r['fileSHA256'].update({'freehand/undeclared.png': '0'*64}))
        self.reject(lambda r: r['freehand']['files'].append('annotation-pencil-result.png'))
        self.reject(lambda r: r['textLine']['files'].append('../outside.png'))
        self.reject(lambda r: r['fileSHA256'].update({'freehand/annotation-freehand-preview.json': '0'*64}))

    def test_missing_file_rejected(self):
        (self.root/'freehand'/'annotation-freehand-preview.json').unlink()
        with self.assertRaises(FileNotFoundError): self.check()

    def test_oversized_file_rejected_before_reading(self):
        path = self.root/'freehand'/'annotation-freehand-edge-bottom-left-result.png'
        with path.open('r+b') as stream:
            stream.truncate(CHECK.MAX_FILE_BYTES + 1)
        with self.assertRaisesRegex(ValueError, 'exceeds bound'): self.check()

    def test_child_report_must_match_combined_even_with_rehashed_file(self):
        forged = copy.deepcopy(self.freehand)
        forged['pencil']['nativeControlsReachable'] = False
        self.replace_file('freehand', CHECK.REPORTS['freehand'], json.dumps(forged).encode())
        with self.assertRaisesRegex(ValueError, 'child report differs'): self.check()

    def test_child_numeric_boolean_impostor_is_not_equal(self):
        forged = copy.deepcopy(self.freehand)
        forged['pencil']['nativeControlsReachable'] = 1
        self.replace_file('freehand', CHECK.REPORTS['freehand'], json.dumps(forged).encode())
        with self.assertRaisesRegex(ValueError, 'child report differs'): self.check()

    def test_symlink_file_and_directory_rejected(self):
        name = CHECK.REPORTS['freehand']
        original = (self.root/'freehand'/name).read_bytes()
        target = self.root/'external.json'; target.write_bytes(original)
        (self.root/'freehand'/name).unlink(); (self.root/'freehand'/name).symlink_to(target)
        with self.assertRaisesRegex(ValueError, 'unsafe evidence file'): self.check()
        (self.root/'freehand'/name).unlink(); (self.root/'freehand'/name).write_bytes(original)
        (self.root/'freehand').rename(self.root/'moved')
        (self.root/'freehand').symlink_to(self.root/'moved', target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'unsafe evidence directory'): self.check()

    def test_rehashed_corrupt_png_rejected(self):
        data = bytearray(self.pngs[(180, 120)])
        data[-5] ^= 1
        self.replace_file('freehand', 'annotation-freehand-edge-bottom-left-result.png', bytes(data))
        with self.assertRaisesRegex(ValueError, 'PNG'): self.check()

    def test_valid_but_wrong_export_dimensions_rejected(self):
        self.replace_file('freehand', 'annotation-freehand-edge-bottom-left-result.png', self.pngs[(680, 360)])
        with self.assertRaisesRegex(ValueError, 'export dimensions'): self.check()

    def test_valid_but_tiny_ui_snapshot_rejected(self):
        self.replace_file('callouts', 'ui-callout-bottom-left.png', png(1, 1))
        with self.assertRaisesRegex(ValueError, 'native UI snapshot'): self.check()

    def test_png_dimensions_crc_filters_and_trailing_bytes(self):
        real = type(self).cached_dimensions.__wrapped__
        for color in (0, 2, 4, 6):
            for mode in range(5):
                with self.subTest(color=color, mode=mode): self.assertEqual(real(png(3, 2, color=color, mode=mode)), (3, 2))
        original = png(3, 2)
        malformed = [original + b'trailing', original[:-1], png(3, 2, mode=5),
                     b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 4000, 2000, 8, 6, 0, 0, 0)) + original[33:],
                     original[:33] + chunk(b'acTL', struct.pack('>II', 2, 0)) + original[33:],
                     original[:33] + chunk(b'ABCD', b'') + original[33:],
                     original[:33] + chunk(b'PLTE', b'xx') + original[33:]]
        for data in malformed:
            with self.subTest(length=len(data)):
                with self.assertRaises(ValueError): real(data)

    def test_png_inflate_bomb_rejected(self):
        real = type(self).cached_dimensions.__wrapped__
        data = (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 6, 0, 0, 0))
                + chunk(b'IDAT', zlib.compress(b'\0' * 1_000_000)) + chunk(b'IEND', b''))
        with self.assertRaisesRegex(ValueError, 'inflated length'): real(data)

    def test_duplicate_json_keys_and_nonfinite_rejected(self):
        for value in (b'{"status":"passed","status":"failed"}', b'{"value":NaN}', b'{"value":Infinity}'):
            with self.assertRaises(ValueError): CHECK.load_json(value)


if __name__ == '__main__':
    unittest.main()
