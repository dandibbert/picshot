#!/usr/bin/env python3
"""Candidate renderer ownership after the unchanged 24-case/432-attempt guard."""
import hashlib
import json
from pathlib import Path
import sys
import importlib.util


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


D = module('renderer_guard_drawing', 'check-drawing-raster-guard.py')
R = module('renderer_guard_pair', 'check-renderer-storage-pair.py')
N = R.N
FILENAME = 'renderer-storage-output-guard.json'
KEYS = D.SIDECAR_KEYS | {'comparisonKind', 'executableSHA256', 'executableBytes', 'drawingReportSHA256', 'drawingStrategy'}


def check_directory(directory, app, source):
    directory, app = Path(directory), Path(app)
    # Keep every original native and drawing assertion, including the exact
    # matrix, no failed output publication, successful retry and owned exit.
    drawing_result = D.check_directory(directory, app, source)
    native_path = directory / 'effect-output-failure.json'
    native_bytes = D.read_bytes(native_path, D.NATIVE.MAX_REPORT_BYTES)
    native = D.parse_json(native_bytes)
    drawing_bytes = D.read_bytes(directory / 'drawing-raster-output-guard.json', D.MAX_SIDECAR_BYTES)
    report = D.parse_json(D.read_bytes(directory / FILENAME, D.MAX_SIDECAR_BYTES))
    N.keys(report, KEYS)
    C = R.C
    C.equal_int(report['schemaVersion'], 1, 'renderer guard schema')
    N.need(report['status'] == 'observed' and report['diagnosticOnly'] is True, 'renderer guard is not raw evidence')
    N.need(report['comparisonKind'] == R.KIND and report['observationBoundary'] == 'after-effect-output-failure-fixture-return',
           'renderer guard observation differs')
    for key in ('sourceCommit', 'version', 'buildVersion'):
        N.need(type(report[key]) is str and report[key] == native[key], 'renderer guard identity differs: ' + key)
    for key in ('bundlePath', 'executablePath'):
        D.NATIVE.same_path(report[key], native[key], key)
    C.equal_int(report['processIdentifier'], native['processIdentifier'], 'renderer guard PID')
    D.NATIVE.same_path(report['nativeReportPath'], native_path, 'renderer native report')
    C.equal_int(report['nativeReportBytes'], len(native_bytes), 'renderer native byte count')
    N.need(report['nativeReportSHA256'] == drawing_result['nativeReportSHA256'] == hashlib.sha256(native_bytes).hexdigest(),
           'renderer guard native byte binding differs')
    N.need(report['drawingReportSHA256'] == hashlib.sha256(drawing_bytes).hexdigest(), 'renderer guard drawing byte binding differs')
    executable = D.read_bytes(app / 'Contents/MacOS/PicShot', 512 * 1024 * 1024)
    C.equal_int(report['executableBytes'], len(executable), 'renderer guard executable byte count')
    N.need(report['executableSHA256'] == hashlib.sha256(executable).hexdigest(), 'renderer guard executable SHA differs')
    N.need(report['requestedStrategy'] == report['selectedStrategy'] == 'owned-srgb8'
           and report['drawingStrategy'] == 'owned-srgb8' and report['productionDefaultStrategy'] == 'native',
           'renderer guard strategy/default differs')
    tracker = R.snapshot(report['tracker'], 'owned-srgb8', released=True, allow_failures=True)
    for field in ('eligibleCount', 'seedCount', 'drawCount', 'publishCount', 'failureCount', 'allocations', 'releaseCallbacks'):
        N.need(tracker[field] > 0, 'renderer guard path not exercised: ' + field)
    # Failed pre-provider destinations must be freed but have no callback.
    # A provider created before image-publication failure can have a callback.
    # Do not equate callbacks with all allocations or successful publications.
    N.need(tracker['allocations'] - tracker['releaseCallbacks'] <= tracker['failureCount'],
           'renderer guard allocations missing callbacks without failures')
    N.need(tracker['eligibleCount'] - tracker['allocations'] <= tracker['failureCount'],
           'renderer guard eligible work omitted without failures')
    return {**drawing_result, 'comparisonKind': R.KIND,
        'drawingStrategy': 'owned-srgb8', 'productionDefaultStrategy': 'native',
        'executableSHA256': report['executableSHA256'], 'executableBytes': report['executableBytes'],
        'drawingReportSHA256': report['drawingReportSHA256'], 'drawingTracker': drawing_result['tracker'],
        'tracker': tracker, 'nativeExecutionAttestedByChecker': False,
        'privateFrameworkReleaseClaim': False, 'productMemoryRemedyClaim': False}


if __name__ == '__main__':
    N.need(len(sys.argv) == 4, 'EVIDENCE_DIRECTORY APP SOURCE')
    print(json.dumps(check_directory(*sys.argv[1:]), sort_keys=True, allow_nan=False))
