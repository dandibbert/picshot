#!/usr/bin/env python3
"""Bind observed drawing counters to the unchanged installed output guard.

Synthetic tests exercise this acceptance contract, not native runtime success.
This does not measure RSS, footprint, native caches, or GPU storage.
"""
import hashlib
import importlib.util
import json
import math
import os
import pathlib
import plistlib
import re
import stat
import sys

_SPEC = importlib.util.spec_from_file_location(
    'native_effect_output_guard', pathlib.Path(__file__).with_name('check-effect-output-failure-report.py'))
NATIVE = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(NATIVE)
need = NATIVE.need

MAX_SIDECAR_BYTES = 16 * 1024
MAX_PLIST_BYTES = 64 * 1024
MAX_INTEGER = (1 << 63) - 1
SIDECAR_KEYS = {
    'schemaVersion', 'status', 'diagnosticOnly', 'observationBoundary', 'sourceCommit',
    'version', 'buildVersion', 'bundlePath', 'executablePath', 'processIdentifier',
    'nativeReportPath', 'nativeReportBytes', 'nativeReportSHA256', 'requestedStrategy',
    'selectedStrategy', 'productionDefaultStrategy', 'tracker',
}
COUNTERS = {
    'referenceCount', 'eligibleCount', 'ownedCount', 'seededContextCount',
    'presentationReuseCount', 'presentationFallbackCount', 'failureCount',
    'allocations', 'deallocations', 'releaseCallbacks', 'allocatedBytes',
    'deallocatedBytes', 'callbackBytes', 'activeBytes', 'peakActiveBytes', 'seededContextBytes',
}
UNSUPPORTED_REASONS = {
    'imageMask', 'decodeArray', 'colorSpace', 'floatingPoint', 'componentDepth',
    'channelLayout', 'byteOrder', 'bitmapFlags',
}


def integer(value, label, minimum=0, maximum=MAX_INTEGER):
    need(type(value) is int and minimum <= value <= maximum, 'Invalid ' + label)
    return value


def read_bytes(path, maximum):
    """Bound a stable regular file; reject symlinks, hard links, and special files."""
    path = pathlib.Path(path)
    before = path.lstat()
    need(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and 0 < before.st_size <= maximum,
         'Missing, linked, nonregular or oversized file: ' + str(path))
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as stream:
        opened = os.fstat(stream.fileno())
        need((opened.st_dev, opened.st_ino) == (before.st_dev, before.st_ino)
             and stat.S_ISREG(opened.st_mode) and opened.st_nlink == 1
             and 0 < opened.st_size <= maximum, 'File changed before reading')
        data = stream.read(maximum + 1)
        after = os.fstat(stream.fileno())
    need((opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns, opened.st_nlink)
         == (after.st_size, after.st_mtime_ns, after.st_ctime_ns, after.st_nlink)
         and len(data) == opened.st_size and 0 < len(data) <= maximum, 'File changed while reading')
    return data


def finite_float(value):
    number = float(value)
    need(math.isfinite(number), 'Nonfinite JSON number')
    return number


def parse_json(data):
    result = json.loads(data.decode('utf-8'), object_pairs_hook=NATIVE.unique_object,
                        parse_constant=NATIVE.reject_constant, parse_float=finite_float)
    need(type(result) is dict, 'Report must be an object')
    return result


def validate(sidecar, native, native_bytes, native_path):
    need(type(sidecar) is dict and set(sidecar) == SIDECAR_KEYS, 'Sidecar schema mismatch')
    NATIVE.count(sidecar, 'schemaVersion', 1)
    need(sidecar['status'] == 'observed' and sidecar['diagnosticOnly'] is True, 'Not raw diagnostic evidence')
    need(sidecar['observationBoundary'] == 'after-effect-output-failure-fixture-return', 'Wrong observation boundary')
    for key in ('sourceCommit', 'version', 'buildVersion'):
        need(type(sidecar[key]) is str and sidecar[key] == native[key], 'Native identity mismatch: ' + key)
    for key in ('bundlePath', 'executablePath'):
        NATIVE.same_path(sidecar[key], native[key], key)
    NATIVE.count(sidecar, 'processIdentifier', native['processIdentifier'])
    NATIVE.same_path(sidecar['nativeReportPath'], native_path, 'native report')
    NATIVE.count(sidecar, 'nativeReportBytes', len(native_bytes))
    digest = sidecar['nativeReportSHA256']
    need(type(digest) is str and re.fullmatch(r'[0-9a-f]{64}', digest) is not None
         and digest == hashlib.sha256(native_bytes).hexdigest(), 'Native report SHA256 mismatch')
    for key in ('requestedStrategy', 'selectedStrategy'):
        need(sidecar[key] == 'owned-srgb8', 'Candidate strategy missing: ' + key)
    need(sidecar['productionDefaultStrategy'] == 'owned-srgb8', 'Production default must be owned-srgb8')

    tracker = sidecar['tracker']
    need(type(tracker) is dict and set(tracker) == COUNTERS | {'unsupportedCounts', 'callbackSizesMatch'},
         'Tracker schema mismatch')
    for key in COUNTERS:
        integer(tracker[key], key)
    unsupported = tracker['unsupportedCounts']
    need(type(unsupported) is dict and set(unsupported) <= UNSUPPORTED_REASONS, 'Invalid unsupported reasons')
    for key, value in unsupported.items():
        integer(value, 'unsupported ' + key, minimum=1)
    integer(sum(unsupported.values()) + tracker['eligibleCount'], 'total attempted rasters', minimum=1)
    for key in ('referenceCount', 'presentationFallbackCount', 'failureCount', 'activeBytes'):
        NATIVE.count(tracker, key, 0)
    need(tracker['callbackSizesMatch'] is True, 'Provider callback size mismatch')
    integer(tracker['seededContextCount'], 'seededContextCount', minimum=1)
    need(tracker['eligibleCount'] == tracker['ownedCount'] + tracker['seededContextCount'],
         'Eligible drawing work does not balance')
    need(tracker['allocations'] == tracker['deallocations'] == tracker['releaseCallbacks'] == tracker['ownedCount'],
         'Owned provider allocation/release counts do not balance')
    need(tracker['allocatedBytes'] == tracker['deallocatedBytes'] == tracker['callbackBytes'],
         'Owned provider allocation/release bytes do not balance')
    need(tracker['allocatedBytes'] - tracker['deallocatedBytes'] == tracker['activeBytes'],
         'Active owned bytes do not balance')
    for key in ('allocatedBytes', 'deallocatedBytes', 'callbackBytes', 'peakActiveBytes', 'seededContextBytes'):
        need(tracker[key] % 4 == 0, 'Invalid sRGB8 byte alignment: ' + key)
    need(4 * tracker['seededContextCount'] <= tracker['seededContextBytes']
         <= 400_000_000 * tracker['seededContextCount'], 'Seeded bytes do not cover admitted seeded work')
    owned = tracker['ownedCount']
    if owned:
        need(4 * owned <= tracker['allocatedBytes'] <= 400_000_000 * owned,
             'Allocated bytes do not cover admitted owned work')
        need(0 < tracker['peakActiveBytes'] <= min(tracker['allocatedBytes'], 800_000_000)
             and tracker['peakActiveBytes'] * owned >= tracker['allocatedBytes'], 'Invalid peak owned bytes')
    else:
        NATIVE.count(tracker, 'allocatedBytes', 0)
        NATIVE.count(tracker, 'peakActiveBytes', 0)
    return sidecar


def check(native_path, sidecar_path, app, source, launcher_path):
    native_bytes = read_bytes(native_path, NATIVE.MAX_REPORT_BYTES)
    native = parse_json(native_bytes)
    launcher = parse_json(read_bytes(launcher_path, NATIVE.MAX_LAUNCHER_BYTES))
    info = plistlib.loads(read_bytes(pathlib.Path(app) / 'Contents/Info.plist', MAX_PLIST_BYTES))
    # Reuse every assertion in the unchanged native guard, including the exact
    # 24-case / 432-attempt / 24-controller-release matrix and owned launcher exit.
    NATIVE.validate(native, info, app, source, launcher)
    sidecar = validate(parse_json(read_bytes(sidecar_path, MAX_SIDECAR_BYTES)), native, native_bytes, native_path)
    return {
        'status': 'passed', 'diagnosticOnly': True, 'sourceCommit': source,
        'processIdentifier': native['processIdentifier'], 'caseCount': native['caseCount'],
        'rejectedOutputAttempts': sum(case['failedRenderRequests'] for case in native['cases']),
        'controllerReleaseCount': native['controllerReleaseCount'],
        'nativeReportSHA256': sidecar['nativeReportSHA256'],
        'selectedStrategy': sidecar['selectedStrategy'],
        'productionDefaultStrategy': sidecar['productionDefaultStrategy'],
        'tracker': sidecar['tracker'],
    }


def check_directory(directory, app, source):
    directory = pathlib.Path(directory)
    return check(directory / 'effect-output-failure.json', directory / 'drawing-raster-output-guard.json',
                 app, source, directory / 'launch.json.launcher.json')


if __name__ == '__main__':
    need(len(sys.argv) == 4, 'EVIDENCE_DIRECTORY APP SOURCE')
    print(json.dumps(check_directory(*sys.argv[1:]), sort_keys=True, allow_nan=False))
