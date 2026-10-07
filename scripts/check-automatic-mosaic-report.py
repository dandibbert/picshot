#!/usr/bin/env python3
"""Independently validate installed native mosaic evidence, including exported PNG pixels.

Only the standard library is used. Memory measurements are observational, not a
plateau/zero-leak claim. Unit-test reports are schema fixtures, never native proof.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import zlib

WIDTH, HEIGHT = 720, 480
# Top-left raster coordinates; fixed authored workload, not report-defined masks.
REGIONS = [(31, 37, 144, 48), (287, 123, 144, 48), (497, 301, 144, 48)]
NEAR_NONMATCH = (59, 329, 144, 48)
EXPORTS = {
    'redact': ('automatic-mosaic-redact.png', REGIONS),
    'redact-excluded': ('automatic-mosaic-redact-excluded.png', REGIONS[:2]),
    'blur': ('automatic-mosaic-blur.png', REGIONS),
    'pixelate': ('automatic-mosaic-pixelate.png', REGIONS),
}
CHECKS = {
    'native-seed-drag', 'selected-seed-find', 'review-before-apply',
    'native-candidate-exclude-include', 'excluded-candidate-preserved',
    'near-nonmatch-excluded', 'apply-one-undo-step', 'undo-redo',
    'sync-add-on', 'sync-add-off', 'sync-delete-on', 'sync-delete-off',
    'crop-invalidates-review', 'edit-invalidates-review',
    'cancel-discards-preview', 'close-discards-preview',
    'stale-completion-ignored', 'native-edge-controls', 'light-dark-native-png',
    'review-blocks-output', 'apply-cancel-restores-output',
    'focused-candidate-visible',
}


def need(condition, detail):
    if not condition:
        raise ValueError(detail)


def integer(value, *, minimum=0):
    need(type(value) is int and value >= minimum, f'invalid integer: {value!r}')
    return value


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_bytes(directory, name):
    need(isinstance(name, str) and Path(name).name == name and name not in ('', '.', '..'), 'unsafe evidence path')
    path = directory / name
    need(path.resolve().parent == directory.resolve(), 'evidence escaped directory')
    need(path.stat().st_size <= 64 * 1024 * 1024, 'evidence file too large')
    return path.read_bytes()


def png_rgba(data):
    """Decode non-interlaced 8-bit native PNGs; validate all chunk CRCs/filters.

    Native CGContext fixtures emit RGB/RGBA8. Gray/gray-alpha8 are accepted for
    equivalent PNG encoders. Palettes, 16-bit data, and interlace fail explicitly.
    """
    need(data[:8] == b'\x89PNG\r\n\x1a\n', 'invalid PNG signature')
    offset, compressed, header, ended = 8, bytearray(), None, False
    while offset < len(data):
        need(offset + 12 <= len(data), 'truncated PNG chunk')
        size = struct.unpack_from('>I', data, offset)[0]
        kind, start = data[offset+4:offset+8], offset + 8
        need(start + size + 4 <= len(data), 'truncated PNG data')
        payload = data[start:start+size]
        crc = struct.unpack_from('>I', data, start+size)[0]
        need(zlib.crc32(kind + payload) & 0xffffffff == crc, 'PNG CRC mismatch')
        if kind == b'IHDR':
            need(header is None and size == 13 and offset == 8, 'invalid PNG header')
            header = struct.unpack('>IIBBBBB', payload)
        elif kind == b'IDAT':
            compressed.extend(payload)
        elif kind == b'IEND':
            need(size == 0 and start + 4 == len(data), 'invalid PNG end')
            ended = True
            break
        offset = start + size + 4
    need(header is not None and ended, 'incomplete PNG')
    width, height, depth, color, compression, filtering, interlace = header
    need(0 < width <= 16384 and 0 < height <= 16384 and width*height <= 20_000_000, 'PNG dimensions exceeded')
    need(depth == 8 and color in (0, 2, 4, 6) and compression == filtering == interlace == 0, 'unsupported PNG format')
    channels = {0: 1, 2: 3, 4: 2, 6: 4}[color]
    stride = width * channels
    expected = (stride + 1) * height
    inflater = zlib.decompressobj()
    raw = inflater.decompress(bytes(compressed), expected + 1)
    need(len(raw) == expected and inflater.eof and not inflater.unconsumed_tail and not inflater.unused_data, 'invalid PNG inflated length')
    pixels, previous = bytearray(), bytearray(stride)
    for y in range(height):
        index = y * (stride + 1)
        mode = raw[index]
        need(mode <= 4, 'invalid PNG row filter')
        row = bytearray(raw[index+1:index+1+stride])
        for x in range(stride):
            a, b, c = (row[x-channels] if x >= channels else 0), previous[x], (previous[x-channels] if x >= channels else 0)
            if mode == 1: add = a
            elif mode == 2: add = b
            elif mode == 3: add = (a+b)//2
            elif mode == 4:
                p = a+b-c
                distances = (abs(p-a), abs(p-b), abs(p-c))
                add = (a, b, c)[distances.index(min(distances))]
            else: add = 0
            row[x] = (row[x] + add) & 255
        for x in range(width):
            value = row[x*channels:(x+1)*channels]
            if color == 6: pixels.extend(value)
            elif color == 2: pixels.extend(value + b'\xff')
            elif color == 4: pixels.extend(bytes([value[0]]) * 3 + value[1:2])
            else: pixels.extend(value * 3 + b'\xff')
        previous = row
    return width, height, bytes(pixels)


def contains(rect, x, y):
    left, top, width, height = rect
    return left <= x < left+width and top <= y < top+height


def validate_pixels(source, output, regions, *, opaque):
    need(len(source) == len(output) == WIDTH*HEIGHT*4, 'wrong pixel extent')
    inside, outside, changed = 0, 0, 0
    for y in range(HEIGHT):
        for x in range(WIDTH):
            offset = (y*WIDTH+x)*4
            before, after = source[offset:offset+4], output[offset:offset+4]
            if any(contains(rect, x, y) for rect in regions):
                inside += 1
                changed += before != after
                if opaque:
                    need(after == b'\x00\x00\x00\xff', f'nonopaque redaction at {x},{y}')
            else:
                outside += 1
                need(before == after, f'exterior pixel changed at {x},{y}')
    need(inside > 0 and outside > 0 and changed > 0, 'empty/unchanged output')
    return inside, outside, changed


def validate_resources(e, *, full):
    if not full:
        need(e['status'] == 'not-run', 'early resource status')
        need(e['warmupCycles'] == e['completedMeasuredCycles'] == e['actualMatcherCalls'] == 0, 'early resources ran')
        return
    need(e['status'] == 'passed' and e['observationsComplete'] is True, 'resource observations incomplete')
    need(e['warmupCycles'] == 2 and e['measuredCycles'] == e['completedMeasuredCycles'] == 12, 'resource cycle count')
    need(e['actualMatcherCalls'] == 14 and e['appliedCycles'] == 14, 'resource path did not match/apply')
    need(e['sameAuthoredRasterEachCycle'] is True and e['fixedInputRasterCountAtBaselineAndEveryCycleEnd'] == 1, 'unequal raster endpoints')
    need(e['liveEditorsAtBaselineAndEveryCycleEnd'] == e['activeJobsAtBaselineAndEveryCycleEnd'] == e['snapshotsInsideMeasuredLoop'] == 0, 'unequal live endpoints')
    need(e['sampleIntervalSeconds'] == 0.05 and e['settlingDelaySeconds'] == 0.15, 'memory timing changed')
    need(e['measuredElapsedSeconds'] > 0 and e['processIdentifier'] > 0, 'missing process/duration')
    need(e['warmupReleaseProbes'] == 2 and e['measuredReleaseProbes'] == 12, 'weak probe count')
    release = e['releaseEvidence']
    need(release['probeCount'] == 14 and e['retainedObjects'] == 0, 'retained measured objects')
    for key in ('retainedControllers', 'retainedCanvases', 'retainedContentViews', 'retainedReviewSurfaces'):
        need(release[key] == 0, 'unreleased ' + key)
    need(e['memoryIsObservational'] is True and e['stabilityAssessed'] is False and e['memoryPressureOrSystemSettingsChanged'] is False, 'overclaimed/perturbed memory')
    need(e['lateIntervalCycles'] == 1, 'wrong late interval')
    points = [e['beforeWarmup'], e['baselineAfterWarmup'], *e['settledAfterCycles'], e['afterMeasuredCycles'], e['finalAfterCleanup']]
    need(len(e['settledAfterCycles']) == 12 and e['settledAfterCycles'][-1] == e['afterMeasuredCycles'], 'missing memory boundaries')
    for point in points:
        integer(point['residentBytes'], minimum=1)
        integer(point['physicalFootprintBytes'], minimum=1)
    for key in ('warmupSampledMemory', 'sampledMemory'):
        s = e[key]
        integer(s['timerTickCount'], minimum=1); integer(s['boundarySampleCount'], minimum=1)
        total = s['timerTickCount'] + s['boundarySampleCount']
        need(s['residentSampleCount'] == s['physicalFootprintSampleCount'] == total, 'missing samples')
        need(s['failedResidentSampleCount'] == s['failedPhysicalFootprintSampleCount'] == 0, 'failed samples')
        for field in ('peakResidentBytes', 'peakPhysicalFootprintBytes'): integer(s[field], minimum=1)
    for field, label, peak in [('residentBytes', 'resident', 'peakResidentBytes'), ('physicalFootprintBytes', 'physicalFootprint', 'peakPhysicalFootprintBytes')]:
        ends = [point[field] for point in e['settledAfterCycles']]
        need(e[label+'GrowthFromWarmupBytes'] == ends[-1]-e['baselineAfterWarmup'][field], 'incorrect warmup delta')
        need(e[label+'LastIntervalGrowthBytes'] == ends[-1]-ends[-2], 'incorrect last delta')
        need(e[label+'LateThreeIntervalGrowthBytes'] == [ends[i]-ends[i-1] for i in range(9, 12)], 'incorrect late increments')
        need(e[label+'CleanupDeltaBytes'] == e['finalAfterCleanup'][field]-ends[-1], 'incorrect cleanup delta')


def validate_large(r, *, full):
    if not full:
        need(r['status'] == 'not-run' and r['completedSearches'] == 0, 'early large timings ran')
        return
    need(r['status'] == 'passed' and r['completedSearches'] == 2 and r['buildMode'] == 'release', 'large release run missing')
    need(r['productionDeadlineSeconds'] == 8 and r['resourceCycleMeasurementIncluded'] is False, 'large timing changed budget/scope')
    need(len(r['runs']) == 2, 'large run count')
    for run, (profile, width, height) in zip(r['runs'], [('4k', 3840, 2160), ('5k', 5120, 2880)]):
        expected = [[1919, 1081, 144, 48], [width-159, height-71, 144, 48]]
        need(run['profile'] == profile and run['status'] == 'passed' and run['outcome'] == 'completed', 'large search did not complete')
        need(run['actualProductionMatcherRan'] is True and run['architecture'] in ('arm64', 'x86_64'), 'large actual native matcher missing')
        need((run['sourceWidth'], run['sourceHeight'], run['sourceBytes'], run['templateBytes']) == (width, height, width*height*4, 144*48*4), 'large source extent')
        need(run['seed'] == [31, 47, 144, 48] and run['expectedTargets'] == expected and run['nearNonmatch'] == [113, 157, 144, 48], 'large authored geometry')
        need(run['constructionSeconds'] > 0 and 0 < run['conversionAndSearchSeconds'] < run['productionDeadlineSeconds'] == 8, 'large matcher deadline exceeded')
        need(run['sourceByteIdentityVerified'] is True and run['sourceSHA256Before'] == run['sourceSHA256After'] and len(run['sourceSHA256Before']) == 64, 'large source changed')
        need(run['truncated'] is False and run['examinedOrigins'] > 1_000_000, 'large search incomplete')
        need([candidate['rect'] for candidate in run['candidates']] == expected, 'large match returned wrong geometry')
        need(all(0 < candidate['confidence'] <= 1 for candidate in run['candidates']), 'large match confidence')
        need(run['algorithmOwnedScratchBudgetBytes'] == 96*1024*1024 and run['scratchBudgetExcludes'], 'large scratch memory scope')


def validate(r, *, expected_commit, expected_version, expected_build, installed_app, evidence_directory, full):
    need(r['status'] == 'passed' and r['schemaVersion'] == 1, 'report not passed')
    need(r['sourceCommit'] == expected_commit and r['version'] == expected_version and r['buildVersion'] == expected_build, 'bundle identity mismatch')
    need(Path(r['bundlePath']).resolve() == installed_app.resolve(), 'installed bundle mismatch')
    need(r['includeResourceCycles'] is full, 'resource scope mismatch')
    need(0 < r['elapsedSeconds'] < r['overallDeadlineSeconds'] == 240, 'fixture deadline')
    need(r['actualProductionMatcherRan'] is True and r['actualFunctionalMatcherCalls'] >= 4, 'production matcher absent')
    need(r['sourceByteIdentityVerified'] is True and r['sourceRGBAHashBefore'] == r['sourceRGBAHashAfter'], 'source changed')
    need(r['sourceWidth'] == WIDTH and r['sourceHeight'] == HEIGHT, 'authored dimensions changed')
    need(r['authoredRepeatRects'] == [list(rect) for rect in REGIONS] and r['authoredNearNonmatchRect'] == list(NEAR_NONMATCH), 'authored region geometry changed')
    for key in ('screenCaptureStarted', 'permissionRequests', 'networkUsed', 'globalInputPosted',
                'generalPasteboardReadOrWritten', 'standardUserDefaultsChanged', 'physicalRetinaVerified',
                'externalApplicationVerified', 'arbitraryImageAccuracyVerified', 'zeroLeakClaim'):
        need(r[key] is False, 'unsupported side effect/claim: ' + key)
    need(set(r['controls']['checks']) == CHECKS, 'missing/unknown native control checks')
    need(r['controls']['status'] == 'passed' and r['controls']['productionActionsUsed'] is True, 'native controls not verified')
    need(r['controls']['staleRaceUsesRealMatcherResult'] is True, 'stale gate used a placeholder result')
    need(r['controls']['staleCallbacksRejected'] >= 1, 'stale callback not witnessed')
    need(r['controls']['staleRaceBoundary'] == 'actual matcher completed; result delivery held until after invalidation' and
         r['controls']['activeScanCancellationVerifiedHere'] is False, 'stale-delivery test overclaimed scan interruption')
    need(r['controls']['finalActiveJobs'] == 0, 'functional job remains')
    validate_resources(r['resourceEvidence'], full=full)
    validate_large(r['largeImageTimings'], full=full)
    need(r['actualResourceMatcherCalls'] == (14 if full else 0), 'resource match total')
    expected_files = {'automatic-mosaic-input.png', 'automatic-mosaic-review-light.png', 'automatic-mosaic-review-dark.png',
                      'automatic-mosaic-edge.png', *(value[0] for value in EXPORTS.values())}
    need(set(r['evidenceFiles']) == expected_files and len(r['evidenceFiles']) == len(expected_files), 'evidence file set mismatch')
    need(set(r['fileSHA256']) == expected_files, 'missing file hashes')
    decoded = {}
    for name in sorted(expected_files):
        data = file_bytes(evidence_directory, name)
        need(digest(data) == r['fileSHA256'][name], 'evidence file digest mismatch: ' + name)
        decoded[name] = png_rgba(data)
    width, height, source = decoded['automatic-mosaic-input.png']
    need((width, height) == (WIDTH, HEIGHT), 'source PNG dimensions')
    need(len(r['exports']) == len(EXPORTS), 'export count')
    need({entry['mode'] for entry in r['exports']} == set(EXPORTS), 'export mode set')
    for entry in r['exports']:
        name, regions = EXPORTS[entry['mode']]
        need(entry['file'] == name and entry['appliedRects'] == [list(rect) for rect in regions], 'export selection mismatch')
        need(entry['nativeApply'] is True and entry['flattenedRasterOnly'] is True, 'export bypassed apply/flatten')
        opaque = entry['mode'].startswith('redact')
        need(entry['securityClaim'] is opaque, 'cosmetic security claim')
        w, h, output = decoded[name]
        need((w, h) == (WIDTH, HEIGHT), 'export dimensions changed')
        inside, outside, changed = validate_pixels(source, output, regions, opaque=opaque)
        need(entry['matchedPixelsChecked'] == inside and entry['exteriorPixelsChecked'] == outside, 'pixel counts mismatch')
        need(entry['exteriorMismatches'] == 0 and entry['changedMatchedPixels'] == changed, 'pixel claims mismatch')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', type=Path)
    parser.add_argument('app', type=Path)
    parser.add_argument('source')
    parser.add_argument('version')
    parser.add_argument('build')
    parser.add_argument('--full', action='store_true')
    args = parser.parse_args()
    validate(json.loads(args.report.read_text()), expected_commit=args.source, expected_version=args.version,
             expected_build=args.build, installed_app=args.app, evidence_directory=args.report.parent, full=args.full)
    print('Installed automatic mosaic native evidence passed; memory remains observational')


if __name__ == '__main__':
    main()
