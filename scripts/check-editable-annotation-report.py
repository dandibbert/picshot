#!/usr/bin/env python3
"""Validate source-bound installed editable-layer evidence; never infer stability.
Synthetic checker tests are schema tests, not evidence of native execution.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import plistlib
import re
import stat
import struct

MAX_BYTES = 2 * 1024 * 1024
MEMORY = {'resident_size', 'phys_footprint', 'compressed', 'purgeable_volatile_resident',
          'purgeable_volatile_virtual', 'purgeable_volatile_pmap',
          'ledger_purgeable_volatile', 'ledger_purgeable_volatile_compressed'}
ROLES = {'original', 'base', 'current', 'canonical', 'editor', 'canvas', 'content', 'window', 'pin', 'store'}
ASSERTIONS = {'nativeHistorySave', 'historyReopen', 'restoredSelectTool', 'nativeEditUndo',
              'cancelKeptSavedContent', 'durableFailureKeptDraft', 'durableRetry', 'pinSpaceReopen',
              'pinApply', 'cropFullStackPixels', 'uncropUndo', 'hiddenGeometry', 'hiddenExportAnnotated',
              'originalExportSeparate', 'legacyRaster'}
FLAGS_TRUE = {'syntheticSource', 'nativeEditorPinControls', 'realPNGAndMetadataReads'}
FLAGS_FALSE = {'screenCaptureStarted', 'permissionRequests', 'globalInputPosted', 'networkUsed',
               'generalPasteboardUsed', 'standardDefaultsWritten', 'memoryPressureOrPurgeRequested',
               'physicalMultiDisplayVerified', 'appMainHistoryGridDoubleClickExercised',
               'memoryStabilityAssessed', 'zeroLeakClaim'}
CASE_FIELDS = {'width', 'height', 'fullBasePixels', 'viewportPixels', 'outputWidth', 'outputHeight',
               'layerCount', 'originalAndBaseAreDistinct', 'sourcePixelsSHA256', 'basePixelsSHA256',
               'expectedOutputPixelsSHA256', 'persistedOutputPixelsSHA256', 'reopenedOutputPixelsSHA256',
               'hiddenPixelsSHA256', 'ordinaryExportPixelsSHA256', 'originalExportPixelsSHA256',
               'originalPNGSHA256', 'basePNGSHA256', 'documentSHA256', 'assertions',
               'ownershipAfterRelease', 'windowContentGraphsAfterRelease', 'ownedOpenDescriptorsAfter',
               'appliedDocumentSHA256', 'appliedLayerCount', 'appliedExpectedOutputPixelsSHA256',
               'appliedPersistedOutputPixelsSHA256', 'appliedReopenedOutputPixelsSHA256'}
CYCLE_FIELDS = {'index', 'phase', 'beforeMemory', 'afterMemory', 'temporaryDirectoryRemoved',
                'activeExportControllersAfter', 'projectionReservedBytesAfter',
                'canonicalNormalizationBytesPerFullBase', 'minimumOriginalPlusBaseBytesWhileLoaded'}
ROOT_FIELDS = {'processIdentifier', 'schemaVersion', 'status', 'sourceCommit', 'version', 'buildVersion', 'bundlePath', 'architecture',
               'executableSHA256', 'executableBytes', 'deadlineSeconds', 'resourcesRequested', 'entryMemory',
               'functionalCases', 'resources', 'flags', 'historyReopenEntryPoint', 'memoryScope', 'sampledMemory',
               'finalMemory', 'ownedTemporaryDirectoryRemoved', 'ownedOpenDescriptorsAfterCleanup', 'elapsedSeconds'}


def need(condition, message):
    if not condition:
        raise ValueError(message)


def keys(value, expected):
    need(type(value) is dict and set(value) == set(expected), 'unexpected object keys')


def integer(value, low=0, high=2**63 - 1):
    need(type(value) is int and low <= value <= high, 'invalid bounded integer')
    return value


def number(value, low=0, high=2**63 - 1):
    need(type(value) in (int, float) and math.isfinite(value) and low <= value <= high, 'invalid finite number')
    return value


def sha(value):
    need(type(value) is str and re.fullmatch(r'[0-9a-f]{64}', value) is not None, 'invalid SHA256')


def string(value):
    need(type(value) is str and 0 < len(value) <= 8192, 'invalid string')


def counters(value):
    keys(value, MEMORY)
    for key, entry in value.items():
        integer(entry, -(2**63 - 1) if key.startswith('ledger_') else 0)
    need(value['resident_size'] > 0 and value['phys_footprint'] > 0, 'missing resident/footprint observation')


def observation(value):
    keys(value, {'uptimeSeconds', 'counters', 'backingAccounting'})
    number(value['uptimeSeconds'])
    counters(value['counters'])
    raw = value['backingAccounting']
    keys(raw, {'standard', 'purgeable'})
    fields = {'flavor', 'kernelReturn', 'requestedNaturalCount', 'returnedNaturalCount',
              'observedAtUptimeSeconds', 'pageSizeBytes', 'regionCount', 'bytes', 'ledgerBytes'}
    for label, flavor in [('standard', 'TASK_VM_INFO'), ('purgeable', 'TASK_VM_INFO_PURGEABLE')]:
        item = raw[label]
        keys(item, fields)
        need(item['flavor'] == flavor, 'wrong task-info flavor')
        need(integer(item['kernelReturn']) == 0, 'task-info query failed')
        requested = integer(item['requestedNaturalCount'], 1, 4096)
        integer(item['returnedNaturalCount'], 1, requested)
        number(item['observedAtUptimeSeconds'], 0, value['uptimeSeconds'] + 0.1)
        integer(item['pageSizeBytes'], 1, 65536)
        integer(item['regionCount'], 0, 2**31 - 1)
        need(type(item['bytes']) is dict and len(item['bytes']) <= 64, 'invalid task byte fields')
        need(type(item['ledgerBytes']) is dict and len(item['ledgerBytes']) <= 64, 'invalid task ledger fields')
        for name, count in item['bytes'].items():
            string(name); integer(count)
        for name, count in item['ledgerBytes'].items():
            string(name); integer(count, -(2**63 - 1))
    for field, count in value['counters'].items():
        source = raw['purgeable']['ledgerBytes'] if field.startswith('ledger_') else (
            raw['purgeable']['bytes'] if field.startswith('purgeable_') else raw['standard']['bytes'])
        need(field in source and source[field] == count, 'flattened memory differs from actual returned accounting')


def ownership(value):
    keys(value, ROLES)
    for role, entry in value.items():
        keys(entry, {'created', 'alive', 'peakConcurrent', 'peakKnownBytes'})
        created = integer(entry['created'], 1, 4096)
        alive = integer(entry['alive'], 0, created)
        peak = integer(entry['peakConcurrent'], 1, created)
        need(alive <= peak, 'live object count exceeds peak')
        integer(entry['peakKnownBytes'])
        if role != 'window':
            need(alive == 0, 'owned source/view/controller survived release')
    for role, expected in {'editor': 5, 'canvas': 5, 'content': 5, 'window': 7, 'pin': 2, 'store': 4}.items():
        need(value[role]['created'] == expected, 'native lifecycle workload changed: ' + role)
    need(value['canonical']['created'] >= 8 and value['canonical']['peakConcurrent'] == 1, 'canonical normalization lifecycle incomplete')
    # AppKit can keep detached closed NSWindow shells; their image graphs must be zero.
    for role in ('original', 'base', 'current', 'canonical'):
        need(value[role]['peakKnownBytes'] > 0, 'raster/canonical ownership byte cost omitted')


def case(value, width, height, cycle=False):
    keys(value, CASE_FIELDS | (CYCLE_FIELDS if cycle else {'profile', 'afterReleaseMemory'}))
    for field, expected in [('width', width), ('height', height), ('fullBasePixels', width * height),
                            ('viewportPixels', (width // 640 * 400) * (width // 640 * 260)),
                            ('outputWidth', width // 640 * 400 + 14), ('outputHeight', width // 640 * 260 + 14),
                            ('layerCount', 7), ('appliedLayerCount', 8), ('windowContentGraphsAfterRelease', 0), ('ownedOpenDescriptorsAfter', 0)]:
        need(integer(value[field]) == expected, 'incorrect dimensions/count/cleanup: ' + field)
    need(value['originalAndBaseAreDistinct'] is True, 'distinct original/base case missing')
    keys(value['assertions'], ASSERTIONS)
    need(all(flag is True for flag in value['assertions'].values()), 'native functional assertion failed')
    for field in CASE_FIELDS:
        if field.endswith('SHA256'):
            sha(value[field])
    expected = value['expectedOutputPixelsSHA256']
    need(all(value[field] == expected for field in ['persistedOutputPixelsSHA256', 'reopenedOutputPixelsSHA256',
                                                  'ordinaryExportPixelsSHA256']), 'saved/restored/current export pixel mismatch')
    applied = value['appliedExpectedOutputPixelsSHA256']
    need(applied != expected and value['appliedDocumentSHA256'] != value['documentSHA256'], 'Apply did not change pixels and metadata')
    need(value['appliedPersistedOutputPixelsSHA256'] == applied and value['appliedReopenedOutputPixelsSHA256'] == applied, 'Apply current/reopened pixels differ')
    need(value['hiddenPixelsSHA256'] != expected, 'hidden preview was not a different display')
    need(value['sourcePixelsSHA256'] == value['originalExportPixelsSHA256'], 'original export changed')
    need(value['sourcePixelsSHA256'] != value['basePixelsSHA256'], 'distinct base pixels missing')
    ownership(value['ownershipAfterRelease'])
    for role in ('original', 'base', 'canonical'):
        need(value['ownershipAfterRelease'][role]['peakKnownBytes'] >= width * height * 4, 'full-base memory cost omitted')
    if not cycle:
        observation(value['afterReleaseMemory'])
    else:
        integer(value['index'], 1, 8)
        need(value['phase'] in ('warmup', 'measured'), 'invalid cycle phase')
        observation(value['beforeMemory']); observation(value['afterMemory'])
        need(value['afterMemory']['uptimeSeconds'] >= value['beforeMemory']['uptimeSeconds'], 'cycle time moved backwards')
        need(value['temporaryDirectoryRemoved'] is True, 'cycle temporary directory retained')
        for field in ('activeExportControllersAfter', 'projectionReservedBytesAfter'):
            need(integer(value[field]) == 0, 'output resources survived cycle')
        need(integer(value['canonicalNormalizationBytesPerFullBase']) == width * height * 4, 'canonical cost omitted')
        need(integer(value['minimumOriginalPlusBaseBytesWhileLoaded']) == width * height * 8, 'original/base cost omitted')


def delta(before, after):
    return {key: after['counters'][key] - before['counters'][key] for key in MEMORY}


def resources(value):
    fields = {'status', 'warmupCycles', 'measuredCycles', 'completedWarmupCycles', 'completedMeasuredCycles',
              'sourceWidth', 'sourceHeight', 'fixedInputRastersAtEndpoints', 'originalAndBaseDistinct', 'fullBaseCostsIncluded',
              'realHistoryPNGMetadataRoundTripsPerCycle', 'nativeActionsInEveryCycle', 'beforeWarmup', 'afterWarmupBaseline',
              'warmups', 'cycles', 'afterMeasuredCycles', 'afterWarmupToMeasuredDeltaBytes', 'lateMeasuredIncrements',
              'memoryStabilityAssessed', 'zeroLeakClaim', 'workload'}
    keys(value, fields)
    need(value['status'] == 'observed', 'resource observations incomplete')
    for field, expected in [('warmupCycles', 2), ('measuredCycles', 8), ('completedWarmupCycles', 2),
                            ('completedMeasuredCycles', 8), ('sourceWidth', 3840), ('sourceHeight', 2160),
                            ('fixedInputRastersAtEndpoints', 0)]:
        need(integer(value[field]) == expected, 'incomplete resource workload')
    for field in ('originalAndBaseDistinct', 'fullBaseCostsIncluded', 'realHistoryPNGMetadataRoundTripsPerCycle', 'nativeActionsInEveryCycle'):
        need(value[field] is True, 'resource scope omitted')
    need(value['memoryStabilityAssessed'] is False and value['zeroLeakClaim'] is False, 'unsupported stability claim')
    string(value['workload'])
    for field in ('beforeWarmup', 'afterWarmupBaseline', 'afterMeasuredCycles'):
        observation(value[field])
    for field, count, phase in [('warmups', 2, 'warmup'), ('cycles', 8, 'measured')]:
        need(type(value[field]) is list and len(value[field]) == count, 'missing resource cycles')
        for index, entry in enumerate(value[field], 1):
            case(entry, 3840, 2160, cycle=True)
            need(entry['index'] == index and entry['phase'] == phase, 'cycle sequence changed')
    need(len({c['expectedOutputPixelsSHA256'] for c in value['warmups'] + value['cycles']}) == 1, 'repeated workload changed pixels')
    for item in [value['afterWarmupToMeasuredDeltaBytes']] + value['lateMeasuredIncrements']:
        keys(item, MEMORY)
        for count in item.values():
            integer(count, -(2**63 - 1))
    need(value['afterWarmupToMeasuredDeltaBytes'] == delta(value['afterWarmupBaseline'], value['afterMeasuredCycles']), 'memory growth arithmetic changed')
    endpoints = [entry['afterMemory'] for entry in value['cycles']]
    need(value['lateMeasuredIncrements'] == [delta(endpoints[i], endpoints[i + 1]) for i in range(4, 7)], 'late positive/negative increments omitted or changed')


def statistics(value):
    keys(value, {'sampleCount', 'timerSampleCount', 'sampledPeakBytes', 'sampledMinimumBytes', 'lastBytes', 'missingFieldCounts'})
    count = integer(value['sampleCount'], 1, 100000)
    integer(value['timerSampleCount'], 0, count)
    need(value['missingFieldCounts'] == {}, 'missing transient memory fields')
    for field in ('sampledPeakBytes', 'sampledMinimumBytes', 'lastBytes'):
        counters(value[field])
    for key in MEMORY:
        need(value['sampledMinimumBytes'][key] <= value['lastBytes'][key] <= value['sampledPeakBytes'][key], 'invalid memory sample range')


def samples(value, include_resources):
    keys(value, {'scope', 'sampleIntervalSeconds', 'maximumPhaseAggregates', 'continuousSampleArraysRetained',
                 'pairedTaskInfoCallsAreAtomic', 'missingFieldsBecomeZero', 'total', 'phases'})
    string(value['scope'])
    need(number(value['sampleIntervalSeconds']) == 0.05 and integer(value['maximumPhaseAggregates']) == 128, 'sample interval or phase bound changed')
    for field in ('continuousSampleArraysRetained', 'pairedTaskInfoCallsAreAtomic', 'missingFieldsBecomeZero'):
        need(value[field] is False, 'misleading sampler semantics')
    statistics(value['total'])
    need(value['total']['timerSampleCount'] > 0, 'transient sampler never ticked')
    phases = value['phases']
    expected = {'entry', 'functional-small', 'functional-4k', 'final-cleanup'}
    if include_resources:
        expected |= {'resource-before-input'} | {f'warmup-{n}' for n in range(1, 3)} | {f'measured-{n}' for n in range(1, 9)}
    keys(phases, expected)
    for item in phases.values():
        statistics(item)
    for field in ('sampleCount', 'timerSampleCount'):
        need(value['total'][field] == sum(p[field] for p in phases.values()), 'sample counts do not reconcile')
    for key in MEMORY:
        need(value['total']['sampledPeakBytes'][key] == max(p['sampledPeakBytes'][key] for p in phases.values()), 'peak aggregation mismatch')
        need(value['total']['sampledMinimumBytes'][key] == min(p['sampledMinimumBytes'][key] for p in phases.values()), 'minimum aggregation mismatch')


def validate(report, identity, include_resources, process_id=None):
    keys(report, ROOT_FIELDS)
    pid = integer(report['processIdentifier'], 1, 2**31 - 1)
    if process_id is not None:
        need(pid == process_id, 'report process does not match the owned installed launch')
    need(integer(report['schemaVersion']) == 1 and report['status'] == 'passed', 'native acceptance did not pass')
    need(type(report['sourceCommit']) is str and re.fullmatch(r'[0-9a-f]{40}', report['sourceCommit']) is not None, 'invalid source commit')
    for field in ('sourceCommit', 'version', 'buildVersion', 'bundlePath', 'executableSHA256', 'executableBytes', 'architecture'):
        need(report[field] == identity[field], 'installed executable identity mismatch: ' + field)
    for field in ('version', 'buildVersion', 'bundlePath'):
        string(report[field])
    integer(report['executableBytes'], 1); sha(report['executableSHA256'])
    need(report['architecture'] in ('arm64', 'x86_64'), 'unsupported architecture')
    need(number(report['deadlineSeconds']) == 300 and number(report['elapsedSeconds'], 0, 300) > 0, 'deadline was omitted or exceeded')
    need(report['resourcesRequested'] is include_resources, 'resource mode does not match requested gate')
    keys(report['flags'], FLAGS_TRUE | FLAGS_FALSE)
    need(all(report['flags'][f] is True for f in FLAGS_TRUE), 'expected native scope missing')
    need(all(report['flags'][f] is False for f in FLAGS_FALSE), 'unsafe or unsupported claim')
    need(report['historyReopenEntryPoint'] == 'HistoryStore.editablePayload + ImageEditorController.restoreEditablePayload', 'history route scope changed')
    string(report['memoryScope'])
    observation(report['entryMemory']); observation(report['finalMemory'])
    need(type(report['functionalCases']) is list and len(report['functionalCases']) == 2, 'small/4K functional cases incomplete')
    for item, profile, width, height in zip(report['functionalCases'], ['small', '4k'], [640, 3840], [360, 2160]):
        case(item, width, height); need(item['profile'] == profile, 'functional profile mismatch')
    if include_resources:
        resources(report['resources'])
    else:
        need(report['resources'] is None, 'unexpected resource report')
    samples(report['sampledMemory'], include_resources)
    need(report['ownedTemporaryDirectoryRemoved'] is True, 'temporary directory survived')
    need(integer(report['ownedOpenDescriptorsAfterCleanup']) == 0, 'linked/unlinked owned descriptor survived')
    return {'status': 'passed', 'resourceObservationsComplete': include_resources, 'nativeExecutionAttestedByChecker': False,
            'memoryStabilityAssessed': False, 'zeroLeakClaim': False, 'sourceCommit': report['sourceCommit']}


def strict_pairs(pairs):
    result = {}
    for key, value in pairs:
        need(key not in result, 'duplicate JSON key'); result[key] = value
    return result


def read_report(path):
    info = path.lstat()
    need(stat.S_ISREG(info.st_mode) and 0 < info.st_size <= MAX_BYTES, 'report is not a bounded regular file')
    return json.loads(path.read_text(), object_pairs_hook=strict_pairs,
                      parse_constant=lambda _: (_ for _ in ()).throw(ValueError('nonfinite JSON')))


def bundle_identity(app, source):
    app = app.resolve(strict=True)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    executable = app / 'Contents/MacOS/PicShot'
    need(executable.is_file() and not executable.is_symlink(), 'bundle executable is missing or linked')
    need(info['PicShotSourceCommit'] == source, 'bundle source is not requested source')
    need(0 < executable.stat().st_size <= 512 * 1024 * 1024, 'executable size outside bound')
    with executable.open('rb') as handle:
        header = handle.read(8)
    need(len(header) == 8 and header[:4] == bytes.fromhex('cffaedfe'), 'expected a thin 64-bit Mach-O executable')
    architecture = {0x0100000c: 'arm64', 0x01000007: 'x86_64'}.get(struct.unpack('<I', header[4:8])[0])
    need(architecture is not None, 'unsupported executable architecture')
    return {'architecture': architecture, 'sourceCommit': source, 'version': info['CFBundleShortVersionString'], 'buildVersion': info['CFBundleVersion'],
            'bundlePath': str(app), 'executableSHA256': hashlib.sha256(executable.read_bytes()).hexdigest(),
            'executableBytes': executable.stat().st_size}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('report', type=Path); parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--source', required=True); parser.add_argument('--resources', action='store_true')
    parser.add_argument('--output', type=Path); parser.add_argument('--process-id', type=int)
    args = parser.parse_args()
    result = validate(read_report(args.report), bundle_identity(args.app, args.source), args.resources, args.process_id)
    result['reportSHA256'] = hashlib.sha256(args.report.read_bytes()).hexdigest()
    text = json.dumps(result, indent=2) + '\n'
    if args.output:
        args.output.write_text(text)
    print(text, end='')


if __name__ == '__main__':
    main()
