#!/usr/bin/env python3
"""Strict source/bundle-bound validation of opt-in continuous-scroll resource evidence.

Requires a release installed bundle and its separate owned-event functional report.
Validates assertions, identities, bounded counts and exact memory arithmetic; JSON
cannot independently attest native execution or prove a memory plateau/zero leaks.
Hostile-schema tests fabricate data and are never native resource evidence.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import plistlib
import re
import stat

MAX_REPORT_BYTES = 2 * 1024 * 1024
PROFILES = [('4k-vertical', 3840, 2160, 'vertical'), ('4k-horizontal', 3840, 2160, 'horizontal'),
            ('5k-vertical', 5120, 2880, 'vertical'), ('5k-horizontal', 5120, 2880, 'horizontal')]
MEMORY_FIELDS = [('residentBytes', 'resident', 'peakResidentBytes'),
                 ('physicalFootprintBytes', 'physicalFootprint', 'peakPhysicalFootprintBytes')]
LIMITS = dict(framePixels=24_000_000, outputPixels=60_000_000, outputDimension=32768,
              acceptedSources=100, temporaryDiskBytes=512*1024*1024, fixtureViewportRasters=1,
              pendingCaptureRasters=1, captureRunners=1, queuedCaptureRequests=0, overviewPixels=800*800,
              previewTilePixels=1048576, previewSourceSamplePixels=4194304, previewCachedTiles=1,
              previewActiveJobs=1, previewPendingJobs=1)
FALSE_FIELDS = {'nativeControlEventsInResourceLoop', 'stabilityAssessed', 'zeroLeakClaim',
                'screenCaptureStarted', 'permissionRequests', 'globalInputPosted', 'networkUsed',
                'generalPasteboardUsed', 'standardDefaultsWritten', 'memoryPressureOrSystemSettingsChanged',
                'allocatorPurgeAttempted', 'physicalDisplayOrExternalApplicationVerified'}
TRUE_CYCLE_FIELDS = {'acceptedSourcesImmutable', 'stationarySuppressed', 'uncertainSeamRejected',
                    'pauseDrained', 'pauseStoppedSampling', 'sameSizeMovePreservedSources', 'retryKeptAnchor',
                    'cancelOverlappedProvider', 'cancelDrained', 'resetRemovedSpool', 'closedObjectsReleased'}
RESET_FIELDS = {'fixtureViewportRasters', 'pendingCaptureRasters', 'captureRunners', 'providerCalls',
                'acceptedSources', 'acceptedGrayPixels', 'overviewPixels', 'temporaryDiskBytes',
                'previewActiveJobs', 'previewPendingJobs', 'previewCachedTiles', 'previewSourceReferences'}
CLOSED_FIELDS = {'controllers', 'previews', 'drivers', 'controls', 'coordinators', 'providerCalls', 'spoolDirectories'}
PREVIEW_FIELDS = {'outputWidth', 'outputHeight', 'zoom', 'displayScale', 'visibleRect', 'latestOutputRanges',
                  'tileWidth', 'tileHeight', 'activeJobs', 'pendingJobs', 'cachedTiles', 'sourceReferences', 'resolutionLabel'}
STATS_FIELDS = {'residentSampleCount', 'physicalFootprintSampleCount', 'failedResidentSampleCount',
                'failedPhysicalFootprintSampleCount', 'timerTickCount', 'boundarySampleCount',
                'peakResidentBytes', 'peakPhysicalFootprintBytes'}


def need(condition, message):
    if not condition:
        raise ValueError(message)


def integer(value, minimum=0, maximum=2**63-1):
    need(type(value) is int and minimum <= value <= maximum, 'invalid bounded integer')
    return value


def number(value, minimum=0, maximum=2**63-1):
    need(type(value) in (int, float) and math.isfinite(value) and minimum <= value <= maximum, 'invalid bounded number')
    return value


def keys(value, expected):
    need(type(value) is dict and set(value) == set(expected), 'unexpected object keys')


def array(value, count):
    need(type(value) is list and len(value) == count, 'unexpected array count')
    return value


def sha(value):
    need(type(value) is str and re.fullmatch('[0-9a-f]{64}', value) is not None, 'invalid SHA256')


def string(value):
    need(type(value) is str and 0 < len(value) <= 4096, 'invalid string')


def strict_pairs(pairs):
    result = {}
    for key, value in pairs:
        need(key not in result, 'duplicate JSON key')
        result[key] = value
    return result


def read_json_with_sha(path):
    path = Path(path)
    info = path.lstat()
    need(stat.S_ISREG(info.st_mode) and 0 < info.st_size <= MAX_REPORT_BYTES, 'report must be a bounded regular file')
    data = path.read_bytes()
    need(0 < len(data) <= MAX_REPORT_BYTES, 'report grew beyond bounded size')
    value = json.loads(data, object_pairs_hook=strict_pairs,
                       parse_constant=lambda value: (_ for _ in ()).throw(ValueError('nonfinite JSON')))
    return value, hashlib.sha256(data).hexdigest()


def read_json(path):
    return read_json_with_sha(path)[0]


def file_sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(65536), b''):
            digest.update(chunk)
    return digest.hexdigest()


def memory(point):
    keys(point, {item[0] for item in MEMORY_FIELDS})
    for value in point.values():
        integer(value, 1)


def sampled(stats):
    keys(stats, STATS_FIELDS)
    for value in stats.values():
        integer(value)
    need(stats['timerTickCount'] > 0 and stats['boundarySampleCount'] > 0, 'timer/boundary samples missing')
    count = stats['timerTickCount'] + stats['boundarySampleCount']
    need(stats['failedResidentSampleCount'] == stats['failedPhysicalFootprintSampleCount'] == 0, 'memory samples failed')
    need(stats['residentSampleCount'] == stats['physicalFootprintSampleCount'] == count, 'sample accounting mismatch')
    integer(stats['peakResidentBytes'], 1)
    integer(stats['peakPhysicalFootprintBytes'], 1)


def zero_state(value, fields):
    keys(value, fields)
    for count in value.values():
        need(integer(count) == 0, 'owned resource survived cleanup')


def source_identities(values):
    array(values, 4)
    names = set()
    for value in values:
        keys(value, {'name', 'bytes', 'sha256'})
        name = value['name']
        need(type(name) is str and 0 < len(name) <= 256 and Path(name).name == name and '\\' not in name
             and name.lower().endswith('.png') and name not in names, 'unsafe/duplicate source name')
        names.add(name)
        integer(value['bytes'], 1, LIMITS['temporaryDiskBytes'])
        sha(value['sha256'])
    need(len({item['sha256'] for item in values}) == 4, 'different accepted viewports have identical stored bytes')
    total = sum(item['bytes'] for item in values)
    need(total <= LIMITS['temporaryDiskBytes'], 'source spool exceeded cap')
    return total


def preview(value, width, height, axis):
    keys(value, PREVIEW_FIELDS)
    step = (height if axis == 'vertical' else width) // 4
    output_width = width + (3*step if axis == 'horizontal' else 0)
    output_height = height + (3*step if axis == 'vertical' else 0)
    need(integer(value['outputWidth'], 1) == output_width and integer(value['outputHeight'], 1) == output_height, 'preview output dimensions differ')
    need(output_width*output_height <= LIMITS['outputPixels'], 'output cap exceeded')
    number(value['zoom'], 1.0000001)
    number(value['displayScale'], 1e-12, 4)
    rect = array(value['visibleRect'], 4)
    for component in rect:
        number(component)
    need(rect[2] > 0 and rect[3] > 0 and rect[0]+rect[2] <= output_width+1e-6
         and rect[1]+rect[3] <= output_height+1e-6, 'preview rectangle outside output')
    tile_width = integer(value['tileWidth'], 1, 1024)
    tile_height = integer(value['tileHeight'], 1, 1024)
    need(tile_width*tile_height <= LIMITS['previewTilePixels'], 'tile exceeds cap')
    for field, expected in [('activeJobs', 0), ('pendingJobs', 0), ('cachedTiles', 1), ('sourceReferences', 4)]:
        need(integer(value[field]) == expected, 'preview did not settle')
    ranges = array(value['latestOutputRanges'], 1)
    last = array(ranges[0], 2)
    need([integer(item) for item in last] == [3*step, 3*step+(height if axis == 'vertical' else width)], 'latest viewport geometry differs')
    string(value['resolutionLabel'])


def cycle(value, profile, index, phase):
    name, width, height, axis = profile
    base = {'index', 'phase', 'profile', 'axis', 'width', 'height', 'framePixels', 'rgbaBytesPerViewport',
            'elapsedSeconds', 'captures', 'sampledFrames', 'acceptedFrames', 'verifiedSpoolBytes',
            'providerPeakActiveCalls', 'lateCaptureIncrements', 'sourceBytesBefore', 'sourceBytesAfter',
            'preview', 'observedPeaks', 'ownershipSamples', 'resetState', 'closedState', 'before',
            'settledAfterClose', 'sampledMemory'}
    keys(value, base | TRUE_CYCLE_FIELDS)
    need(integer(value['index'], 1) == index and value['phase'] == phase and value['profile'] == name and value['axis'] == axis, 'cycle order/profile mismatch')
    for field, expected in [('width', width), ('height', height), ('framePixels', width*height),
                            ('rgbaBytesPerViewport', width*height*4), ('acceptedFrames', 4),
                            ('providerPeakActiveCalls', 1), ('lateCaptureIncrements', 0)]:
        need(integer(value[field]) == expected, 'cycle extent/count mismatch: '+field)
    number(value['elapsedSeconds'], 1e-9, 240)
    need(integer(value['captures'], 13, 80) == integer(value['sampledFrames'], 13, 80), 'capture/sample count mismatch')
    integer(value['ownershipSamples'], 1)
    for field in TRUE_CYCLE_FIELDS:
        need(value[field] is True, 'required resource assertion missing: '+field)
    total = source_identities(value['sourceBytesBefore'])
    source_identities(value['sourceBytesAfter'])
    need(value['sourceBytesBefore'] == value['sourceBytesAfter'], 'accepted sources changed')
    need(integer(value['verifiedSpoolBytes'], 1) == total, 'actual spool/source byte sum mismatch')
    caps = dict(fixtureViewportRasters=1, fixtureViewportPixels=width*height,
                pendingCaptureRasters=1, pendingCapturePixels=width*height, captureRunners=1, providerCalls=1,
                acceptedSources=4, acceptedGrayPixels=width*height, overviewPixels=800*800,
                previewTilePixels=1048576, previewCachedTiles=1, previewActiveJobs=1, previewPendingJobs=1,
                previewSourceReferences=4, temporaryDiskBytes=512*1024*1024)
    peaks = value['observedPeaks']
    keys(peaks, caps)
    for key, cap in caps.items():
        integer(peaks[key], 0, cap)
    for key, expected in [('fixtureViewportRasters', 1), ('fixtureViewportPixels', width*height),
                          ('captureRunners', 1), ('providerCalls', 1), ('acceptedSources', 4),
                          ('acceptedGrayPixels', width*height), ('previewCachedTiles', 1),
                          ('previewSourceReferences', 4), ('temporaryDiskBytes', total)]:
        need(peaks[key] == expected, 'owned peak did not observe required workload: '+key)
    need(peaks['overviewPixels'] > 0 and peaks['previewTilePixels'] > 0, 'preview raster evidence absent')
    keys(value['preview'], {'beginning', 'end'})
    for item in value['preview'].values():
        preview(item, width, height, axis)
        need(item['tileWidth']*item['tileHeight'] <= peaks['previewTilePixels'], 'tile peak below endpoint')
    need(value['preview']['beginning']['visibleRect'] != value['preview']['end']['visibleRect'], 'preview did not navigate')
    zero_state(value['resetState'], RESET_FIELDS)
    zero_state(value['closedState'], CLOSED_FIELDS)
    memory(value['before']); memory(value['settledAfterClose']); sampled(value['sampledMemory'])


def functional(value, commit):
    need(type(value) is dict and value['status'] == 'passed' and value['sourceCommit'] == commit, 'functional evidence identity/failure')
    for field in ('screenCaptureStarted', 'accessibilityRequested', 'permissionRequested'):
        need(value[field] is False, 'functional evidence used forbidden capture/permissions')
    need(integer(value['systemInputEventsPosted']) == 0, 'functional evidence posted system input')
    need(value['acceptedSourcesImmutable'] is True and value['regionMoveNativeEvents'] is True
         and value['lateCaptureClose'] is True and value['colorDigest'] is True, 'functional native/recovery assertions missing')
    axes = array(value['axes'], 2)
    need({item['axis'] for item in axes} == {'vertical', 'horizontal'}, 'functional axes incomplete')
    for item in axes:
        for field in ('stableCapture', 'stationarySuppressed', 'pauseDrains', 'resumeWithoutCountdown',
                      'fixedRegionMovePreservesBytes', 'uncertainSeamRejected', 'retryKeepsAnchor', 'exactPixels', 'closeReleases'):
            need(item[field] is True, 'functional assertion missing')
    writes = array(value['lateWritePauseStopClose'], 3)
    need({item['action'] for item in writes} == {'pause', 'stop', 'close'}, 'write cancellation actions incomplete')
    need(all(item['uncommittedPNGRemoved'] is True and item['lateCommitRejected'] is True for item in writes), 'late source writes survived')


def validate(report, *, expected_commit, expected_version, expected_build, installed_app, functional_report, functional_report_sha256):
    need(type(expected_commit) is str and re.fullmatch('[0-9a-f]{40}', expected_commit) is not None, 'expected full source commit required')
    for value in (expected_version, expected_build):
        string(value)
    fields = {'schemaVersion', 'status', 'sourceCommit', 'version', 'buildVersion', 'bundlePath', 'processIdentifier',
              'architecture', 'buildMode', 'warmupCycles', 'measuredCycles', 'acceptedFramesPerCycle',
              'overallDeadlineSeconds', 'sampleIntervalSeconds', 'settlingDelaySeconds', 'workload',
              'fullOutputRastersInResourceLoop', 'giantMasterPageRasters', 'memoryIsObservational',
              'memoryScope', 'backingCaveat', 'ownershipScope', 'limits', 'executableSHA256', 'functionalReportSHA256', 'beforeWarmup',
              'warmups', 'warmupSampledMemory', 'baselineAfterWarmup', 'cycles', 'sampledMemory', 'finalAfterCleanup',
              'profileMemory', 'completedWarmupCycles', 'completedMeasuredCycles', 'observationsComplete', 'elapsedSeconds'}
    fields |= FALSE_FIELDS
    for _, prefix, _ in MEMORY_FIELDS:
        fields |= {prefix+suffix for suffix in ('GrowthFromWarmupBytes', 'EveryIntervalGrowthBytes',
                                              'LateThreeIntervalGrowthBytes', 'CleanupDeltaBytes')}
    keys(report, fields)
    need(integer(report['schemaVersion']) == 1 and report['status'] == 'passed', 'resource report failed/unsupported')
    need((report['sourceCommit'], report['version'], report['buildVersion']) ==
         (expected_commit, expected_version, expected_build), 'source/version/build mismatch')
    app = Path(installed_app).resolve(strict=True)
    need(Path(report['bundlePath']).resolve(strict=True) == app and app.is_dir(), 'installed bundle mismatch')
    with (app/'Contents/Info.plist').open('rb') as source:
        info = plistlib.load(source)
    need((info.get('PicShotSourceCommit'), info.get('CFBundleShortVersionString'), info.get('CFBundleVersion')) ==
         (expected_commit, expected_version, expected_build), 'actual installed plist identity mismatch')
    executable_name = info.get('CFBundleExecutable')
    need(type(executable_name) is str and Path(executable_name).name == executable_name and executable_name not in ('', '.', '..'), 'unsafe bundle executable')
    executable = app/'Contents/MacOS'/executable_name
    need(executable.resolve(strict=True).is_relative_to(app), 'executable escaped bundle')
    sha(report['executableSHA256'])
    need(report['executableSHA256'] == file_sha(executable), 'installed executable SHA mismatch')
    need(report['architecture'] in ('arm64', 'x86_64') and report['buildMode'] == 'release', 'native release profile required')
    integer(report['processIdentifier'], 1)
    for field, expected in [('warmupCycles', 8), ('measuredCycles', 16), ('acceptedFramesPerCycle', 4),
                            ('completedWarmupCycles', 8), ('completedMeasuredCycles', 16),
                            ('fullOutputRastersInResourceLoop', 0), ('giantMasterPageRasters', 0)]:
        need(integer(report[field]) == expected, 'workload size mismatch')
    need(number(report['overallDeadlineSeconds']) == 240 and 0 < number(report['elapsedSeconds']) < 240, 'resource deadline exceeded')
    need(number(report['sampleIntervalSeconds']) == 0.05 and number(report['settlingDelaySeconds']) == 0.15, 'sampling contract changed')
    for field in FALSE_FIELDS:
        need(report[field] is False, 'unsupported side effect/claim: '+field)
    need(report['memoryIsObservational'] is True and report['observationsComplete'] is True, 'scope or observation incomplete')
    for field in ('memoryScope', 'backingCaveat', 'ownershipScope', 'workload'):
        string(report[field])
    need('ImageIO' in report['backingCaveat'] and 'volatile' in report['backingCaveat'] and 'full-display' in report['backingCaveat'], 'ImageIO/display backing caveat missing')
    keys(report['limits'], LIMITS)
    for key, expected in LIMITS.items():
        need(integer(report['limits'][key]) == expected, 'production resource cap changed')
    for field in ('beforeWarmup', 'baselineAfterWarmup', 'finalAfterCleanup'):
        memory(report[field])
    sampled(report['warmupSampledMemory']); sampled(report['sampledMemory'])
    for phase, count in [('warmups', 8), ('cycles', 16)]:
        for index, value in enumerate(array(report[phase], count), 1):
            cycle(value, PROFILES[(index-1) % 4], index, 'warmup' if phase == 'warmups' else 'measured')
    need(sum(item['elapsedSeconds'] for item in report['warmups']+report['cycles']) <= report['elapsedSeconds'], 'elapsed time arithmetic inconsistent')
    for field, prefix, peak in MEMORY_FIELDS:
        values = [item['settledAfterClose'][field] for item in report['cycles']]
        expected = {prefix+'GrowthFromWarmupBytes': values[-1]-report['baselineAfterWarmup'][field],
                    prefix+'EveryIntervalGrowthBytes': [b-a for a,b in zip(values, values[1:])],
                    prefix+'LateThreeIntervalGrowthBytes': [values[i]-values[i-1] for i in range(13,16)],
                    prefix+'CleanupDeltaBytes': report['finalAfterCleanup'][field]-values[-1]}
        for name, target in expected.items():
            actual = report[name]
            if type(target) is list:
                array(actual, len(target))
                for item in actual:
                    integer(item, -2**63)
            else:
                integer(actual, -2**63)
            need(actual == target, 'incorrect memory arithmetic: '+name)
    for index, value in enumerate(array(report['profileMemory'], 4)):
        keys(value, {'profile', 'cycleIndices', 'settledAfterCycles', 'residentLateThreeIntervalGrowthBytes', 'physicalFootprintLateThreeIntervalGrowthBytes'})
        need(value['profile'] == PROFILES[index][0], 'per-profile order mismatch')
        indices = [index+1+4*repetition for repetition in range(4)]
        need(value['cycleIndices'] == indices, 'per-profile cycle identity mismatch')
        for item in array(value['cycleIndices'], 4):
            integer(item, 1, 16)
        points = array(value['settledAfterCycles'], 4)
        need(points == [report['cycles'][i-1]['settledAfterClose'] for i in indices], 'per-profile endpoints changed')
        for point in points:
            memory(point)
        for field, prefix, _ in MEMORY_FIELDS:
            increments = array(value[prefix+'LateThreeIntervalGrowthBytes'], 3)
            for item in increments:
                integer(item, -2**63)
            need(increments == [b[field]-a[field] for a,b in zip(points,points[1:])], 'per-profile increments incorrect')
    sha(report['functionalReportSHA256']); sha(functional_report_sha256)
    need(report['functionalReportSHA256'] == functional_report_sha256, 'actual functional report SHA mismatch')
    functional(functional_report, expected_commit)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', type=Path)
    parser.add_argument('installed_app', type=Path)
    parser.add_argument('expected_commit')
    parser.add_argument('expected_version')
    parser.add_argument('expected_build')
    parser.add_argument('--functional-report', type=Path, required=True)
    args = parser.parse_args()
    try:
        functional_value, functional_digest = read_json_with_sha(args.functional_report)
        validate(read_json(args.report), expected_commit=args.expected_commit, expected_version=args.expected_version,
                 expected_build=args.expected_build, installed_app=args.installed_app,
                 functional_report=functional_value, functional_report_sha256=functional_digest)
    except (ValueError, KeyError, TypeError, OSError, OverflowError, RecursionError) as error:
        parser.exit(1, 'scroll manual evidence rejected: '+str(error)+'\n')
    print('Continuous manual resource evidence accepted: 8 warmups + 16 measured 4K/5K cycles; observational memory only')


if __name__ == '__main__':
    main()
