"""Synthetic checker inputs only; these tests are never installed native evidence."""
import copy
import hashlib
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
import zlib

SPEC = importlib.util.spec_from_file_location('mosaic_check', Path(__file__).resolve().parents[1] / 'check-automatic-mosaic-report.py')
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


def png(width, height, pixels, filter_mode=0):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind+data) & 0xffffffff)
    rows = bytearray()
    for y in range(height):
        row = pixels[y*width*4:(y+1)*width*4]
        rows.append(filter_mode)
        rows.extend(row if not filter_mode else bytes((v-(row[i-4] if i >= 4 else 0)) & 255 for i, v in enumerate(row)))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')


def memory(resident, footprint):
    return dict(residentBytes=resident, physicalFootprintBytes=footprint)


def resource_report():
    ends = [memory(1_000_000+i*100, 900_000+i*70) for i in range(12)]
    stats = dict(timerTickCount=2, boundarySampleCount=14, residentSampleCount=16, physicalFootprintSampleCount=16,
                 failedResidentSampleCount=0, failedPhysicalFootprintSampleCount=0,
                 peakResidentBytes=2_000_000, peakPhysicalFootprintBytes=1_800_000)
    r = dict(status='passed', observationsComplete=True, warmupCycles=2, measuredCycles=12, completedMeasuredCycles=12,
             actualMatcherCalls=14, appliedCycles=14, sameAuthoredRasterEachCycle=True,
             fixedInputRasterCountAtBaselineAndEveryCycleEnd=1, liveEditorsAtBaselineAndEveryCycleEnd=0,
             activeJobsAtBaselineAndEveryCycleEnd=0, snapshotsInsideMeasuredLoop=0, sampleIntervalSeconds=0.05,
             settlingDelaySeconds=0.15, measuredElapsedSeconds=5, processIdentifier=123,
             warmupReleaseProbes=2, measuredReleaseProbes=12, retainedObjects=0,
             releaseEvidence=dict(probeCount=14, retainedControllers=0, retainedCanvases=0, retainedContentViews=0, retainedReviewSurfaces=0),
             memoryIsObservational=True, stabilityAssessed=False, memoryPressureOrSystemSettingsChanged=False, lateIntervalCycles=1,
             beforeWarmup=memory(800_000, 700_000), baselineAfterWarmup=memory(1_000_000, 900_000),
             settledAfterCycles=ends, afterMeasuredCycles=ends[-1], finalAfterCleanup=memory(1_000_900, 900_700),
             warmupSampledMemory=stats, sampledMemory=stats)
    for field, label in [('residentBytes', 'resident'), ('physicalFootprintBytes', 'physicalFootprint')]:
        values = [end[field] for end in ends]
        r[label+'GrowthFromWarmupBytes'] = values[-1]-r['baselineAfterWarmup'][field]
        r[label+'LastIntervalGrowthBytes'] = values[-1]-values[-2]
        r[label+'LateThreeIntervalGrowthBytes'] = [values[i]-values[i-1] for i in range(9, 12)]
        r[label+'CleanupDeltaBytes'] = r['finalAfterCleanup'][field]-values[-1]
    return r


def large_report():
    runs = []
    for profile, width, height in [('4k', 3840, 2160), ('5k', 5120, 2880)]:
        targets = [[1919, 1081, 144, 48], [width-159, height-71, 144, 48]]
        runs.append(dict(profile=profile, status='passed', outcome='completed', actualProductionMatcherRan=True,
                         architecture='arm64', sourceWidth=width, sourceHeight=height, sourceBytes=width*height*4,
                         templateBytes=144*48*4, seed=[31, 47, 144, 48], expectedTargets=targets, nearNonmatch=[113, 157, 144, 48],
                         constructionSeconds=0.2, conversionAndSearchSeconds=2.0, productionDeadlineSeconds=8,
                         sourceByteIdentityVerified=True, sourceSHA256Before='d'*64, sourceSHA256After='d'*64,
                         examinedOrigins=2_000_000, truncated=False, candidates=[dict(rect=target, confidence=0.99) for target in targets],
                         algorithmOwnedScratchBudgetBytes=96*1024*1024, scratchBudgetExcludes='Original source and native internals'))
    return dict(status='passed', completedSearches=2, buildMode='release', productionDeadlineSeconds=8,
                resourceCycleMeasurementIncluded=False, runs=runs)


class MosaicReportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = bytes([85, 120, 155, 255]) * (CHECK.WIDTH * CHECK.HEIGHT)
        cls.blobs = {'automatic-mosaic-input.png': png(CHECK.WIDTH, CHECK.HEIGHT, cls.source)}
        cls.exports = []
        for mode, (name, regions) in CHECK.EXPORTS.items():
            pixels = bytearray(cls.source)
            for left, top, width, height in regions:
                for y in range(top, top+height):
                    for x in range(left, left+width):
                        pixels[(y*CHECK.WIDTH+x)*4:(y*CHECK.WIDTH+x)*4+4] = b'\0\0\0\xff' if mode.startswith('redact') else b'\x70\x80\x90\xff'
            cls.blobs[name] = png(CHECK.WIDTH, CHECK.HEIGHT, pixels)
            inside = sum(rect[2]*rect[3] for rect in regions)
            cls.exports.append(dict(mode=mode, file=name, appliedRects=[list(rect) for rect in regions],
                                    nativeApply=True, flattenedRasterOnly=True, securityClaim=mode.startswith('redact'),
                                    matchedPixelsChecked=inside, exteriorPixelsChecked=CHECK.WIDTH*CHECK.HEIGHT-inside,
                                    exteriorMismatches=0, changedMatchedPixels=inside))
        for name in ('automatic-mosaic-review-light.png', 'automatic-mosaic-review-dark.png', 'automatic-mosaic-edge.png'):
            cls.blobs[name] = png(2, 2, b'\xff\0\0\xff' * 4)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mosaic-checker-unit-only-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name, blob in self.blobs.items():
            (self.root/name).write_bytes(blob)
        self.report = dict(status='passed', schemaVersion=1, sourceCommit='a'*40, version='0.12.0', buildVersion='12',
                           bundlePath=str(self.root/'PicShot.app'), includeResourceCycles=True, elapsedSeconds=20, overallDeadlineSeconds=240,
                           actualProductionMatcherRan=True, actualFunctionalMatcherCalls=4, actualResourceMatcherCalls=14, sourceByteIdentityVerified=True,
                           sourceRGBAHashBefore='b'*64, sourceRGBAHashAfter='b'*64, sourceWidth=720, sourceHeight=480,
                           authoredRepeatRects=[list(rect) for rect in CHECK.REGIONS], authoredNearNonmatchRect=list(CHECK.NEAR_NONMATCH),
                           controls=dict(status='passed', checks=sorted(CHECK.CHECKS), productionActionsUsed=True,
                                         staleRaceUsesRealMatcherResult=True, staleCallbacksRejected=1, finalActiveJobs=0,
                                         staleRaceBoundary='actual matcher completed; result delivery held until after invalidation',
                                         activeScanCancellationVerifiedHere=False),
                           resourceEvidence=resource_report(), largeImageTimings=large_report(), evidenceFiles=sorted(self.blobs),
                           fileSHA256={name: hashlib.sha256(blob).hexdigest() for name, blob in self.blobs.items()},
                           exports=copy.deepcopy(self.exports))
        for key in ('screenCaptureStarted', 'permissionRequests', 'networkUsed', 'globalInputPosted', 'generalPasteboardReadOrWritten',
                    'standardUserDefaultsChanged', 'physicalRetinaVerified', 'externalApplicationVerified', 'arbitraryImageAccuracyVerified', 'zeroLeakClaim'):
            self.report[key] = False

    def check(self, report=None, full=True):
        CHECK.validate(report or self.report, expected_commit='a'*40, expected_version='0.12.0', expected_build='12',
                       installed_app=self.root/'PicShot.app', evidence_directory=self.root, full=full)

    def reject(self, mutate):
        candidate = copy.deepcopy(self.report)
        mutate(candidate)
        with self.assertRaises((ValueError, KeyError, TypeError)):
            self.check(candidate)

    def test_full_checker_fixture(self):
        self.check()

    def test_early_resources_are_explicitly_not_run(self):
        self.report['includeResourceCycles'] = False
        self.report['resourceEvidence'] = dict(status='not-run', warmupCycles=0, completedMeasuredCycles=0, actualMatcherCalls=0)
        self.report['actualResourceMatcherCalls'] = 0
        self.report['largeImageTimings'] = dict(status='not-run', completedSearches=0)
        self.check(full=False)
        with self.assertRaises(ValueError): self.check(full=True)

    def test_reject_report_tampering(self):
        changes = [
            lambda r: r.update(sourceCommit='c'*40),
            lambda r: r.update(sourceRGBAHashAfter='c'*64),
            lambda r: r.update(actualProductionMatcherRan=False),
            lambda r: r.update(permissionRequests=True),
            lambda r: r['controls'].update(staleRaceUsesRealMatcherResult=False),
            lambda r: r['controls'].update(staleCallbacksRejected=0),
            lambda r: r['controls']['checks'].remove('sync-add-off'),
            lambda r: r['resourceEvidence'].update(fixedInputRasterCountAtBaselineAndEveryCycleEnd=0),
            lambda r: r['resourceEvidence'].update(completedMeasuredCycles=11),
            lambda r: r['resourceEvidence'].update(residentLateThreeIntervalGrowthBytes=[0, 0, 0]),
            lambda r: r['resourceEvidence']['sampledMemory'].update(residentSampleCount=15),
            lambda r: r['resourceEvidence']['releaseEvidence'].update(retainedReviewSurfaces=1),
            lambda r: r['exports'][2].update(securityClaim=True),
            lambda r: r['exports'][0]['appliedRects'].append(list(CHECK.NEAR_NONMATCH)),
            lambda r: r['exports'][0].update(matchedPixelsChecked=1),
            lambda r: r['largeImageTimings'].update(buildMode='debug'),
            lambda r: r['largeImageTimings']['runs'][1].update(conversionAndSearchSeconds=8.1),
            lambda r: r['largeImageTimings']['runs'][0].update(outcome='budget-exceeded'),
            lambda r: r['largeImageTimings']['runs'][1]['candidates'].pop(),
        ]
        for mutate in changes:
            with self.subTest(mutation=mutate): self.reject(mutate)

    def replace_output(self, mode, pixels):
        name = CHECK.EXPORTS[mode][0]
        blob = png(CHECK.WIDTH, CHECK.HEIGHT, pixels)
        (self.root/name).write_bytes(blob)
        self.report['fileSHA256'][name] = hashlib.sha256(blob).hexdigest()

    def test_reject_exterior_pixel_change_even_with_updated_hash(self):
        _, _, pixels = CHECK.png_rgba(self.blobs['automatic-mosaic-redact.png'])
        pixels = bytearray(pixels); pixels[0] ^= 1
        self.replace_output('redact', pixels)
        with self.assertRaisesRegex(ValueError, 'exterior pixel'): self.check()

    def test_reject_translucent_redaction_even_with_updated_hash(self):
        _, _, pixels = CHECK.png_rgba(self.blobs['automatic-mosaic-redact.png'])
        pixels = bytearray(pixels); pixels[(37*CHECK.WIDTH+31)*4+3] = 254
        self.replace_output('redact', pixels)
        with self.assertRaisesRegex(ValueError, 'nonopaque redaction'): self.check()

    def test_reject_unapplied_cosmetic_output(self):
        self.replace_output('blur', self.source)
        with self.assertRaisesRegex(ValueError, 'unchanged output'): self.check()

    def test_reject_file_digest_change(self):
        path = self.root/'automatic-mosaic-input.png'
        path.write_bytes(path.read_bytes() + b'not-native')
        with self.assertRaisesRegex(ValueError, 'digest mismatch'): self.check()

    def test_png_decoder_checks_crc_truncation_filters(self):
        pixels = bytes(range(16))
        self.assertEqual(CHECK.png_rgba(png(2, 2, pixels, filter_mode=1)), (2, 2, pixels))
        good = png(2, 2, pixels)
        corrupt = bytearray(good); corrupt[30] ^= 1
        for blob in (bytes(corrupt), good[:-1], good+b'x'):
            with self.subTest(blob=blob):
                with self.assertRaises(ValueError): CHECK.png_rgba(blob)

    def test_evidence_symlink_escape_rejected(self):
        with tempfile.TemporaryDirectory() as outside:
            target = Path(outside)/'image.png'; target.write_bytes(self.blobs['automatic-mosaic-input.png'])
            path = self.root/'automatic-mosaic-input.png'; path.unlink(); path.symlink_to(target)
            with self.assertRaisesRegex(ValueError, 'escaped directory'): self.check()


if __name__ == '__main__':
    unittest.main()
