#!/usr/bin/env python3
"""Read one bounded, source-bound Save PNG pair. Never qualify memory benefit.

The third native process validates pixels. This portable reader binds those
assertions to actual retained bytes; synthetic reader tests are not native runs.
"""
import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import stat
import statistics
import struct

PROTOCOL = 'save-png-comparison-v1'
MAX_REPORT = 4 * 1024 * 1024
MAX_LOG = 8 * 1024 * 1024
MAX_PNG = 128 * 1024 * 1024
WIDTH, HEIGHT = 3840, 2160
OPTIONS = {'format': 'png', 'quality': .94, 'lossless': False, 'preserveAlpha': True,
           'alphaQuality': 1, 'paper': 0, 'orientation': 0, 'margin': 24, 'pagination': 0}
BACKING_BYTES = {'virtual_size', 'resident_size', 'resident_size_peak', 'device', 'device_peak',
    'internal', 'internal_peak', 'external', 'external_peak', 'reusable', 'reusable_peak',
    'compressed', 'compressed_peak', 'compressed_lifetime', 'phys_footprint'}
VOLATILE_BYTES = {'purgeable_volatile_pmap', 'purgeable_volatile_resident', 'purgeable_volatile_virtual'}
LEDGERS = {'ledger_phys_footprint_peak', 'ledger_purgeable_nonvolatile',
    'ledger_purgeable_novolatile_compressed', 'ledger_purgeable_volatile',
    'ledger_purgeable_volatile_compressed', *{'ledger_tag_' + category + '_' + kind
        for category in ('graphics', 'media') for kind in
        ('footprint', 'footprint_compressed', 'nofootprint', 'nofootprint_compressed')}}
STAGES = ('entryBacking', 'afterSourceCreationBacking', 'afterSourceHashBacking',
          'afterControllerCreationBacking', 'afterPNGPreparationBacking', 'afterSaveBacking',
          'afterCloseBacking', 'settledBacking')
ENDPOINTS = ('diagnosticEntryBacking', 'afterSetupBacking', 'backingBeforeWarmup',
             'backingBaselineAfterWarmup', 'backingFinal', 'backingLate')
OWNERS = {'sourceReleased', 'controllerReleased', 'windowReleased', 'contentReleased'}
MEMORY_METRICS = {
    'rss': ('standard', 'bytes', 'resident_size'),
    'footprint': ('standard', 'bytes', 'phys_footprint'),
    'volatileResident': ('purgeable', 'bytes', 'purgeable_volatile_resident'),
    'volatileVirtual': ('purgeable', 'bytes', 'purgeable_volatile_virtual'),
    'volatilePmap': ('purgeable', 'bytes', 'purgeable_volatile_pmap'),
    'volatileLedger': ('purgeable', 'ledgerBytes', 'ledger_purgeable_volatile'),
    'kernelRSSPeak': ('standard', 'bytes', 'resident_size_peak'),
    'kernelFootprintPeak': ('standard', 'ledgerBytes', 'ledger_phys_footprint_peak')}
IDENTITY_FIELDS = {'schemaVersion', 'sourceCommit', 'bundlePath', 'mainExecutablePath',
    'mainExecutableSHA256', 'infoPlistSHA256', 'bundleFilesSHA256', 'bundleEntryCount', 'version', 'build'}


def need(ok, text):
    if not ok:
        raise ValueError(text)


def keys(value, expected, label, optional=()):
    need(type(value) is dict, label + ': expected object')
    missing, extra = set(expected) - value.keys(), value.keys() - set(expected) - set(optional)
    need(not missing and not extra, f'{label}: missing {sorted(missing)}, unknown {sorted(extra)}')


def integer(value, low=0, high=2**63 - 1):
    need(type(value) is int and low <= value <= high, 'invalid bounded integer')
    return value


def number(value, low=0, high=2**63 - 1):
    need(type(value) in (int, float) and math.isfinite(value) and low <= value <= high,
         'invalid finite number')
    return value


def exact_int(value, expected, label):
    need(integer(value) == expected, label + ': value differs')


def text(value):
    need(type(value) is str and 0 < len(value) <= 8192, 'invalid bounded string')
    return value


def digest(value):
    need(type(value) is str and re.fullmatch('[0-9a-f]{64}', value) is not None, 'invalid SHA256')
    return value


def strict_pairs(pairs):
    result = {}
    for key, value in pairs:
        need(key not in result, 'duplicate JSON key: ' + key)
        result[key] = value
    return result


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False)


def regular(path, maximum=MAX_REPORT, allow_empty=False):
    need(path.absolute() == path.resolve(strict=True), 'linked or noncanonical path: ' + str(path))
    info = path.lstat()
    need(stat.S_ISREG(info.st_mode) and (0 if allow_empty else 1) <= info.st_size <= maximum,
         'missing/nonregular/oversized file: ' + str(path))
    return info


def read_json(path):
    info = regular(path)
    raw = path.read_bytes()
    need(len(raw) == info.st_size, 'file changed while reading')
    value = json.loads(raw, object_pairs_hook=strict_pairs,
        parse_constant=lambda _: (_ for _ in ()).throw(ValueError('nonfinite JSON')))
    canonical(value)  # Also catches finite JSON tokens which overflow a double.
    return value


def sha_file(path, maximum=512 * 1024 * 1024):
    info = regular(path, maximum)
    hasher = hashlib.sha256()
    total = 0
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            total += len(block)
            need(total <= maximum, 'file grew beyond bound')
            hasher.update(block)
    need(total == info.st_size, 'file changed while hashing')
    return hasher.hexdigest()


def bundle_manifest(app):
    need(app.absolute() == app.resolve(strict=True) and app.is_dir() and app.suffix == '.app',
         'bundle must be a canonical existing app directory')
    rows = []
    for path in sorted(app.rglob('*'), key=lambda path: path.relative_to(app).as_posix()):
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            target = os.readlink(path)
            need(not os.path.isabs(target) and path.resolve(strict=True).is_relative_to(app),
                 'bundle symlink escapes app')
            kind, payload = 'symlink', target
        elif stat.S_ISDIR(info.st_mode):
            kind, payload = 'directory', ''
        else:
            need(stat.S_ISREG(info.st_mode), 'unsupported bundle entry')
            kind, payload = 'file', sha_file(path)
        rows.append([path.relative_to(app).as_posix(), kind, payload, stat.S_IMODE(info.st_mode)])
    need(0 < len(rows) <= 100000, 'bundle entry bound exceeded')
    return rows


def bundle_identity(app, source):
    need(type(source) is str and re.fullmatch('[0-9a-f]{40}', source) is not None, 'invalid requested source')
    manifest = bundle_manifest(app)
    executable, plist = app / 'Contents/MacOS/PicShot', app / 'Contents/Info.plist'
    regular(plist)
    info = plistlib.loads(plist.read_bytes())
    regular(executable, 512 * 1024 * 1024)
    with executable.open('rb') as handle:
        header = handle.read(8)
    need(header == bytes.fromhex('cffaedfe0c000001'), 'expected thin arm64 Mach-O executable')
    need(info['PicShotSourceCommit'] == source and info['CFBundleExecutable'] == 'PicShot',
         'bundle source/executable differs')
    return {'schemaVersion': 1, 'sourceCommit': source, 'bundlePath': str(app),
        'mainExecutablePath': str(executable), 'mainExecutableSHA256': sha_file(executable),
        'infoPlistSHA256': sha_file(plist),
        'bundleFilesSHA256': hashlib.sha256(canonical(manifest).encode()).hexdigest(),
        'bundleEntryCount': len(manifest), 'version': text(info['CFBundleShortVersionString']),
        'build': text(info['CFBundleVersion'])}, manifest


def validate_identity(root, app, source):
    expected, manifest = bundle_identity(app, source)
    for phase in ('before', 'after'):
        found = read_json(root / f'identity-{phase}.json')
        keys(found, IDENTITY_FIELDS, 'identity ' + phase)
        need(canonical(found) == canonical(expected), 'actual source/bundle/executable identity differs: ' + phase)
        stored = read_json(root / f'bundle-manifest-{phase}.json')
        need(canonical(stored) == canonical(manifest), 'bundle manifest differs: ' + phase)
        signature = read_json(root / f'signature-{phase}.json')
        keys(signature, {'schemaVersion', 'exitCode'}, 'signature receipt')
        exact_int(signature['schemaVersion'], 1, 'signature schema')
        exact_int(signature['exitCode'], 0, 'signature verification')
    return expected


def validate_launch(root, name, report, identity):
    directory = root / name
    mode = 'validate' if name == 'validation' else 'measure'
    limit, outer = (240, 300) if mode == 'validate' else (360, 420)
    launcher = read_json(directory / 'smoke.json.launcher.json')
    required = {'schemaVersion', 'status', 'launcherExitCode', 'selectedAppPath',
        'createsNewApplicationInstance', 'timeoutSeconds', 'elapsedSeconds', 'callbackReceived',
        'ownedExitConfirmed', 'processStartMemoryCaptured', 'scope', 'launchBeganUptimeSeconds',
        'finishUptimeSeconds', 'launchedIdentityMatches', 'expectedExecutablePath', 'processIdentifier',
        'launchedAppPath', 'launchedExecutablePath', 'savePNGComparisonDiagnosticOnly',
        'savePNGComparisonMode', 'arguments'}
    flags = {'earlyWitnessOnly', 'liveScrollDiagnosticOnly', 'captureChainDiagnosticOnly', 'textScriptDiagnosticOnly'}
    keys(launcher, required, 'owned launcher', flags)
    exact_int(launcher['schemaVersion'], 1, 'launcher schema')
    exact_int(launcher['launcherExitCode'], 0, 'launcher exit')
    need(launcher['status'] == 'exited' and launcher['savePNGComparisonMode'] == mode,
         'owned launcher mode/status differs')
    for flag in ('createsNewApplicationInstance', 'callbackReceived', 'ownedExitConfirmed',
                 'launchedIdentityMatches', 'savePNGComparisonDiagnosticOnly'):
        need(launcher[flag] is True, 'owned launcher assertion missing: ' + flag)
    need(launcher['processStartMemoryCaptured'] is False and launcher['arguments'] == [],
         'unexpected application arguments/start-memory claim')
    for flag in flags & launcher.keys():
        need(launcher[flag] is False, 'unrelated diagnostic contamination')
    for key in ('selectedAppPath', 'launchedAppPath'):
        need(launcher[key] == identity['bundlePath'], 'owned bundle path differs')
    for key in ('expectedExecutablePath', 'launchedExecutablePath'):
        need(launcher[key] == identity['mainExecutablePath'], 'owned executable path differs')
    need(integer(launcher['processIdentifier'], 1, 2**31-1) == report['processIdentifier'], 'owned PID differs')
    need(number(launcher['timeoutSeconds']) == limit, 'owned deadline changed')
    start = number(launcher['launchBeganUptimeSeconds'])
    end = number(launcher['finishUptimeSeconds'], start, start + limit)
    elapsed = number(launcher['elapsedSeconds'], 0, limit)
    need(elapsed > 0 and end > start and abs((end-start) - elapsed) <= 1,
         'owned launcher elapsed/uptime interval differs')
    text(launcher['scope'])
    exit_path = directory / 'launcher-exit-code.txt'
    regular(exit_path, 32)
    need(exit_path.read_text().strip() == '0', 'invoked launcher did not succeed')
    wrapper = read_json(directory / 'command.json')
    keys(wrapper, {'schema_version', 'status', 'command', 'started_at', 'timeout_seconds',
        'grace_seconds', 'max_log_bytes', 'pid', 'child_returncode', 'exit_code', 'cancel_signal',
        'sigterm_sent', 'sigkill_sent', 'descendant_cleanup', 'output_bytes', 'log_bytes',
        'log_truncated', 'termination_reason', 'duration_seconds', 'group_observation'}, 'bounded command')
    for key, value in [('schema_version', 1), ('child_returncode', 0), ('exit_code', 0), ('max_log_bytes', MAX_LOG)]:
        exact_int(wrapper[key], value, 'wrapper ' + key)
    need(wrapper['status'] == wrapper['termination_reason'] == 'exited' and wrapper['cancel_signal'] is None,
         'bounded command did not exit normally')
    for flag in ('sigterm_sent', 'sigkill_sent', 'descendant_cleanup'):
        need(wrapper[flag] is False, 'bounded command required cleanup')
    need(number(wrapper['timeout_seconds']) == outer and number(wrapper['grace_seconds']) == 5,
         'bounded command deadline changed')
    integer(wrapper['pid'], 1, 2**31-1)
    output = integer(wrapper['output_bytes'])
    logged = integer(wrapper['log_bytes'], 0, MAX_LOG)
    need(logged == min(output, MAX_LOG) and wrapper['log_truncated'] is (output > logged),
         'bounded log accounting differs')
    need(regular(directory / 'launcher.log', MAX_LOG, True).st_size == logged, 'launcher log size differs')
    duration = number(wrapper['duration_seconds'], elapsed - .1, outer)
    group = wrapper['group_observation']
    keys(group, {'backend', 'timeout_seconds', 'count', 'failures', 'total_seconds', 'max_seconds', 'atomic_snapshot'},
         'group observation')
    need(group['backend'] == 'darwin-ps-pgrp' and number(group['timeout_seconds']) == .5
         and group['atomic_snapshot'] is False, 'group observer changed')
    count = integer(group['count'], 1, 1000000)
    exact_int(group['failures'], 0, 'group observer failures')
    total = number(group['total_seconds'], 0, duration + .001)
    maximum = number(group['max_seconds'], 0, total)
    need(maximum > 0 and total <= count * maximum + 1e-9, 'group observation duration/count differs')
    command = wrapper['command']
    need(type(command) is list and len(command) == 11 and command[:2] == ['env', '-i']
         and command[-4:] == ['swift', 'scripts/launch-smoke-app.swift', identity['bundlePath'], str(directory / 'smoke.json')],
         'bounded launcher command changed')
    environment = {}
    for item in command[2:-4]:
        need(type(item) is str and '=' in item, 'invalid launcher environment')
        key, value = item.split('=', 1)
        need(key not in environment and value, 'duplicate/empty launcher environment')
        environment[key] = value
    selector = 'PICSHOT_SAVE_PNG_COMPARISON_'
    keys(environment, {'HOME', 'PATH', 'TMPDIR', selector + 'MODE',
                      selector + ('INPUT_DIRECTORY' if mode == 'validate' else 'ARM')}, 'exclusive launcher environment')
    need(environment[selector + 'MODE'] == mode and environment[selector + ('INPUT_DIRECTORY' if mode == 'validate' else 'ARM')]
         == (str(root) if mode == 'validate' else name), 'launcher selector changed')
    need(environment['HOME'].startswith('/') and environment['TMPDIR'].startswith('/'), 'launcher paths not absolute')
    timestamp = datetime.datetime.fromisoformat(text(wrapper['started_at']))
    need(timestamp.tzinfo is not None and timestamp.utcoffset() == datetime.timedelta(0), 'wrapper time is not UTC')
    return {'processIdentifier': report['processIdentifier'], 'start': start, 'finish': end,
            'wrapperStartedEpochSeconds': timestamp.timestamp(), 'wrapperDurationSeconds': duration,
            'environment': {key: environment[key] for key in ('HOME', 'PATH', 'TMPDIR')}}


def validate_options(value):
    keys(value, OPTIONS, 'PNG options')
    for field, expected in OPTIONS.items():
        if type(expected) is bool:
            need(value[field] is expected, 'PNG option differs: ' + field)
        elif type(expected) is str:
            need(value[field] == expected, 'PNG option differs: ' + field)
        else:
            need(number(value[field]) == expected, 'PNG option differs: ' + field)
            if field in ('paper', 'orientation', 'pagination'):
                integer(value[field])


def validate_backing(value, began, finished):
    keys(value, {'standard', 'purgeable'}, 'backing memory')
    times = []
    for part, flavor in [('standard', 'TASK_VM_INFO'), ('purgeable', 'TASK_VM_INFO_PURGEABLE')]:
        row = value[part]
        keys(row, {'flavor', 'kernelReturn', 'requestedNaturalCount', 'returnedNaturalCount',
            'observedAtUptimeSeconds', 'pageSizeBytes', 'regionCount', 'bytes', 'ledgerBytes'}, 'Mach reading')
        need(row['flavor'] == flavor, 'wrong Mach flavor')
        exact_int(row['kernelReturn'], 0, 'Mach query')
        requested = integer(row['requestedNaturalCount'], 1, 4096)
        integer(row['returnedNaturalCount'], 1, requested)
        times.append(number(row['observedAtUptimeSeconds'], began, finished))
        integer(row['pageSizeBytes'], 1, 65536)
        integer(row['regionCount'], 0, 2**31-1)
        keys(row['bytes'], BACKING_BYTES | (VOLATILE_BYTES if part == 'purgeable' else set()), 'Mach bytes')
        keys(row['ledgerBytes'], LEDGERS, 'Mach ledgers')
        for count in row['bytes'].values():
            integer(count, 0, 2**64-1)
        for count in row['ledgerBytes'].values():
            integer(count, -2**63, 2**63-1)
        need(row['bytes']['resident_size'] > 0 and row['bytes']['phys_footprint'] > 0,
             'RSS/footprint unavailable')
        need(row['bytes']['resident_size_peak'] >= row['bytes']['resident_size'], 'kernel RSS peak below observation')
    need(times[0] <= times[1], 'Mach flavor chronology differs')
    return times[0], times[1]


def validate_samples(value):
    counts = {'residentSampleCount', 'physicalFootprintSampleCount', 'failedResidentSampleCount',
        'failedPhysicalFootprintSampleCount', 'timerTickCount', 'boundarySampleCount', 'backingSampleCount'}
    peaks = {'peakResidentBytes', 'peakPhysicalFootprintBytes', 'peakVolatileResidentBytes', 'peakVolatileLedgerBytes'}
    keys(value, counts | peaks, 'sampled memory')
    for field in counts:
        integer(value[field])
    for field in peaks:
        integer(value[field], -2**63 if field == 'peakVolatileLedgerBytes' else 0)
    need(value['failedResidentSampleCount'] == value['failedPhysicalFootprintSampleCount'] == 0,
         'failed memory samples')
    need(value['timerTickCount'] > 0 and value['boundarySampleCount'] > 0,
         'timer/boundary sampling missing')
    need(value['residentSampleCount'] == value['physicalFootprintSampleCount'] == value['backingSampleCount']
         == value['timerTickCount'] + value['boundarySampleCount'], 'missing or unaccounted sampled observations')
    need(value['peakResidentBytes'] > 0 and value['peakPhysicalFootprintBytes'] > 0, 'sampled RSS/footprint missing')


COMMON_FIELDS = {'schemaVersion', 'protocol', 'sourceCommit', 'bundlePath', 'processIdentifier',
    'operatingSystem', 'sourceWidth', 'sourceHeight', 'options', 'mode', 'status', 'scope',
    'beganUptimeSeconds', 'finishedUptimeSeconds', 'elapsedSeconds', 'productionDefaultPNGPreparationMode',
    'productDefaultsChanged', 'productConfigurationScope', 'exportLimits', 'executablePath', 'architecture', 'defaultsEvidenceScope'}
MEASURE_FIELDS = COMMON_FIELDS | set(ENDPOINTS) | {'arm', 'pngPreparationMode', 'warmupCycles',
    'measuredCycles', 'maximumOutputs', 'cooperativeDeadlineSeconds', 'nativeDrainDeadlineSeconds',
    'outerDeadlineRequiredSeconds', 'productSaveTimeoutSeconds', 'sampleIntervalSeconds', 'sourceScope',
    'memoryScope', 'peakScope', 'ownershipScope', 'bookkeepingScope', 'afterPreparationScope', 'entryScope',
    'interpretation', 'independentDecodes', 'extraReferenceRasterDraws', 'captureStarted', 'networkAttempted',
    'userPreferencesRead', 'generalPasteboardReadOrWritten', 'warmups', 'cycles', 'observationFailures',
    'setupSeconds', 'outputsDirectory', 'completedCycles', 'lateDelaySeconds', 'wholeRunSampledMemory',
    'activeJobsAfterAllCycles', 'activeControllersAfterAllCycles', 'queuedOrRunningJobsAfterAllCycles',
    'retainedInputBytesAfterAllCycles', 'outputsPreserved', 'fixtureJobsDrained', 'isolatedDefaultsRemoved'}
CYCLE_FIELDS = set(STAGES) | {'schemaVersion', 'protocol', 'arm', 'ordinal', 'index', 'isWarmup',
    'status', 'options', 'outputFilename', 'workloadCompleted', 'independentDecodes', 'extraReferenceRasterDraws',
    'queueCounts', 'sourceCreateSeconds', 'sourceSHA256', 'sourceHashSeconds', 'controllerCreationSeconds',
    'nativeWindowVisibleAtAdmission', 'reservedInputBytes', 'activeJobsAtAdmission', 'retainedInputBytesAtAdmission',
    'terminalState', 'nativeWindowVisibleAtCompletion', 'jobDrainedAtCompletion', 'activeJobsAtCompletion',
    'encodedBytes', 'publishedFilenameMatches', 'clipboardNotRequested', 'closedThroughNativeButton',
    'saveCallbackCount', 'preparationCallbackCount', 'saveLatencySeconds', 'requestToPreparedSeconds',
    'drain', 'ownershipDrained', 'sampledMemory', 'stagingEntries', 'stagingCleanupConfirmed',
    'elapsedSeconds', 'observationFailures'}
EXPORT_LIMITS = {'maximumSourcePixels': 100000000, 'maximumEncodedBytes': MAX_PNG,
    'maximumPages': 200, 'previewDimension': 1024, 'maximumPreviewBytes': 4194304}


def common(report, identity, lifecycle, mode):
    exact_int(report['schemaVersion'], 1, 'native schema')
    need(report['protocol'] == PROTOCOL and report['mode'] == mode, 'native protocol/mode differs')
    for field in ('sourceCommit', 'bundlePath'):
        need(report[field] == identity[field], 'native identity differs: ' + field)
    need(report['architecture'] == 'arm64' and report['executablePath'] == identity['mainExecutablePath'],
         'native architecture/executable path differs')
    need(report['defaultsEvidenceScope'] == 'source-review-invariant-not-runtime-default-observation',
         'production default evidence scope differs')
    integer(report['processIdentifier'], 1, 2**31-1)
    exact_int(report['sourceWidth'], WIDTH, 'source width')
    exact_int(report['sourceHeight'], HEIGHT, 'source height')
    validate_options(report['options'])
    text(report['operatingSystem']); text(report['scope']); text(report['productConfigurationScope'])
    need(report['productionDefaultPNGPreparationMode'] == 'legacyPreview' and report['productDefaultsChanged'] is False,
         'production default changed')
    keys(report['exportLimits'], EXPORT_LIMITS, 'export limits')
    for field, expected in EXPORT_LIMITS.items():
        exact_int(report['exportLimits'][field], expected, 'export limit ' + field)
    began = number(report['beganUptimeSeconds'], lifecycle['start'], lifecycle['finish'])
    ended = number(report['finishedUptimeSeconds'], began, lifecycle['finish'])
    elapsed = number(report['elapsedSeconds'], 0, 300)
    need(0 < elapsed and abs(ended-began-elapsed) <= .1, 'native duration differs from native bounds')
    return began, ended


def validate_envelope(directory, native):
    smoke = read_json(directory / 'smoke.json')
    keys(smoke, set(native) | {'historyDirectoryRemoved', 'arguments'}, 'smoke envelope')
    need(smoke['historyDirectoryRemoved'] is True, 'history cleanup unconfirmed')
    need(smoke['arguments'] == [native['bundlePath'] + '/Contents/MacOS/PicShot'], 'smoke process argv differs')
    need(canonical({key: value for key, value in smoke.items() if key in native}) == canonical(native),
         'smoke/native report mismatch')


def validate_measurement(root, arm, report, identity, lifecycle):
    keys(report, MEASURE_FIELDS, arm + ' measurement', {'error', 'cleanupError'})
    began, ended = common(report, identity, lifecycle, 'measure')
    need(report['arm'] == arm and report['pngPreparationMode'] ==
         ('legacyPreview' if arm == 'control' else 'encodedPayload'), 'actual preparation arm differs')
    need(report['status'] == 'observed' and report['observationFailures'] == []
         and 'error' not in report and 'cleanupError' not in report, 'measurement reports failures')
    for field, value in [('warmupCycles', 2), ('measuredCycles', 8), ('maximumOutputs', 10),
        ('completedCycles', 10), ('independentDecodes', 0), ('extraReferenceRasterDraws', 0),
        ('activeJobsAfterAllCycles', 0), ('activeControllersAfterAllCycles', 0),
        ('queuedOrRunningJobsAfterAllCycles', 0), ('retainedInputBytesAfterAllCycles', 0)]:
        exact_int(report[field], value, field)
    for field, value in [('cooperativeDeadlineSeconds', 300), ('nativeDrainDeadlineSeconds', 4),
        ('outerDeadlineRequiredSeconds', 420), ('productSaveTimeoutSeconds', 300),
        ('sampleIntervalSeconds', .05), ('lateDelaySeconds', .5)]:
        need(number(report[field]) == value, 'fixed timing differs: ' + field)
    for flag in ('captureStarted', 'networkAttempted', 'userPreferencesRead', 'generalPasteboardReadOrWritten'):
        need(report[flag] is False, 'unexpected work: ' + flag)
    for flag in ('fixtureJobsDrained', 'isolatedDefaultsRemoved'):
        need(report[flag] is True, 'native cleanup failed: ' + flag)
    for field in ('sourceScope', 'memoryScope', 'peakScope', 'ownershipScope', 'bookkeepingScope',
                  'afterPreparationScope', 'entryScope', 'interpretation'):
        text(report[field])
    number(report['setupSeconds'], 0, report['elapsedSeconds'])
    need(report['outputsDirectory'] == 'outputs' and report['outputsPreserved'] ==
         [f'cycle-{ordinal:02d}.png' for ordinal in range(1, 11)], 'preserved output list differs')
    need(type(report['warmups']) is list and len(report['warmups']) == 2
         and type(report['cycles']) is list and len(report['cycles']) == 8, 'fixed cycle count differs')
    timings = {name: validate_backing(report[name], began, ended) for name in ENDPOINTS}
    validate_samples(report['wholeRunSampledMemory'])
    chronology = [timings[name] for name in ENDPOINTS[:3]]
    for ordinal, cycle in enumerate(report['warmups'] + report['cycles'], 1):
        keys(cycle, CYCLE_FIELDS, arm + ' cycle ' + str(ordinal))
        exact_int(cycle['schemaVersion'], 1, 'cycle schema')
        need(cycle['protocol'] == PROTOCOL and cycle['arm'] == arm and cycle['status'] == 'observed'
             and cycle['observationFailures'] == [], 'cycle protocol/arm/status differs')
        exact_int(cycle['ordinal'], ordinal, 'cycle ordinal')
        exact_int(cycle['index'], ordinal if ordinal <= 2 else ordinal - 2, 'cycle index')
        need(cycle['isWarmup'] is (ordinal <= 2), 'warmup flag differs')
        validate_options(cycle['options']); digest(cycle['sourceSHA256'])
        need(cycle['outputFilename'] == f'outputs/cycle-{ordinal:02d}.png', 'output filename differs')
        integer(cycle['encodedBytes'], 1, MAX_PNG)
        for flag in ('workloadCompleted', 'nativeWindowVisibleAtAdmission', 'nativeWindowVisibleAtCompletion',
            'jobDrainedAtCompletion', 'publishedFilenameMatches', 'clipboardNotRequested',
            'closedThroughNativeButton', 'ownershipDrained', 'stagingCleanupConfirmed'):
            need(cycle[flag] is True, 'native Save observation failed: ' + flag)
        need(cycle['terminalState'] == 'completed' and cycle['stagingEntries'] == [], 'completion/staging differs')
        for field, value in [('reservedInputBytes', WIDTH*HEIGHT*4), ('retainedInputBytesAtAdmission', WIDTH*HEIGHT*4),
            ('activeJobsAtAdmission', 1), ('activeJobsAtCompletion', 0), ('saveCallbackCount', 1),
            ('preparationCallbackCount', 1), ('independentDecodes', 0), ('extraReferenceRasterDraws', 0)]:
            exact_int(cycle[field], value, field)
        for field in ('sourceCreateSeconds', 'sourceHashSeconds', 'controllerCreationSeconds', 'saveLatencySeconds',
                      'requestToPreparedSeconds', 'elapsedSeconds'):
            need(number(cycle[field], 0, report['elapsedSeconds']) > 0, 'missing cycle latency: ' + field)
        need(cycle['requestToPreparedSeconds'] <= cycle['saveLatencySeconds'] <= cycle['elapsedSeconds'],
             'preparation/save latency chronology differs')
        keys(cycle['queueCounts'], STAGES, 'queue counts')
        for count in cycle['queueCounts'].values():
            integer(count, 0, 1)
        for field in ('entryBacking', 'afterSourceCreationBacking', 'afterSourceHashBacking', 'settledBacking'):
            exact_int(cycle['queueCounts'][field], 0, 'idle shared queue')
        drain = cycle['drain']
        keys(drain, {'initial', 'final', 'elapsedSeconds', 'maximumSeconds', 'activeJobs', 'activeControllers',
            'retainedInputBytes', 'queueCount'}, 'native owner drain')
        for name in ('initial', 'final'):
            keys(drain[name], OWNERS, 'weak owners')
            need(all(type(value) is bool for value in drain[name].values()), 'invalid weak-owner fact')
        need(all(drain['final'].values()), 'native owner survived drain')
        need(number(drain['maximumSeconds']) == 4, 'native drain limit changed')
        number(drain['elapsedSeconds'], 0, cycle['elapsedSeconds'])
        for field in ('activeJobs', 'activeControllers', 'retainedInputBytes', 'queueCount'):
            exact_int(drain[field], 0, 'drained ' + field)
        if ordinal == 3:
            chronology.append(timings['backingBaselineAfterWarmup'])
        chronology.extend(validate_backing(cycle[stage], began, ended) for stage in STAGES)
        validate_samples(cycle['sampledMemory'])
        stored = read_json(root / arm / f'save-png-cycle-{ordinal:02d}.json')
        need(canonical(stored) == canonical(cycle), 'durable cycle receipt differs from native manifest')
    chronology += [timings['backingFinal'], timings['backingLate']]
    need(all(first[1] <= second[0] for first, second in zip(chronology, chronology[1:])),
         'cold/warm/cycle/late memory boundaries reordered')
    need(timings['backingLate'][0] - timings['backingFinal'][1] >= .5, 'late observation delay omitted')
    validate_envelope(root / arm, report)
    return summarize(report)


VALIDATION_FIELDS = COMMON_FIELDS | {'measurementProcess', 'independentValidationProcess',
    'cooperativeDeadlineSeconds', 'producerPIDs', 'producerStatuses', 'sourceSHA256',
    'canonicalSourceSHA256', 'validatedOutputs', 'entries'}
VALIDATION_ENTRY_FIELDS = {'arm', 'ordinal', 'filename', 'encodedBytes', 'encodedSHA256', 'width', 'height',
    'canonicalRGBABytes', 'canonicalRGBASHA256', 'allSourcePixelsAndAlphaExactlyEqual',
    'exactPNGBytesEqualAcrossArms', 'optionsVerified', 'pngMetadataVerified'}


def validate_outputs(root, reports, identity, lifecycles):
    """Always called independently of memory validation, including failed samples."""
    report = reports['validation']
    keys(report, VALIDATION_FIELDS, 'independent validation', {'error'})
    common(report, identity, lifecycles['validation'], 'validate')
    need(report['status'] == 'validated' and report['measurementProcess'] is False
         and report['independentValidationProcess'] is True, 'independent output validation failed/missing')
    need(number(report['cooperativeDeadlineSeconds']) == 180, 'validator cooperative deadline changed')
    exact_int(report['validatedOutputs'], 20, 'validated output count')
    need(type(report['entries']) is list and len(report['entries']) == 20, 'twenty output validations required')
    need(type(report['producerPIDs']) is list and len(report['producerPIDs']) == 2, 'producer PID list differs')
    ids = [integer(pid, 1, 2**31-1) for pid in report['producerPIDs']]
    need(ids == [reports[name]['processIdentifier'] for name in ('control', 'candidate')]
         and len(set(ids + [report['processIdentifier']])) == 3, 'producer/validation process identity differs')
    need(report['producerStatuses'] == [reports[name]['status'] for name in ('control', 'candidate')]
         and all(status in ('observed', 'failed') for status in report['producerStatuses']), 'producer statuses differ')
    source_hash = digest(report['sourceSHA256'])
    rgba_hash = digest(report['canonicalSourceSHA256'])
    checked = []
    for arm in ('control', 'candidate'):
        producer = reports[arm]
        common(producer, identity, lifecycles[arm], 'measure')
        need(producer['arm'] == arm, 'producer arm differs')
        exact_int(producer['completedCycles'], 10, 'completed producer output count')
        need(type(producer['warmups']) is list and len(producer['warmups']) == 2
             and type(producer['cycles']) is list and len(producer['cycles']) == 8, 'producer cycle arrays incomplete')
        outputs = root / arm / 'outputs'
        need(outputs.resolve(strict=True) == outputs and outputs.is_dir(), 'output directory linked/missing')
        need(sorted(path.name for path in outputs.iterdir()) == [f'cycle-{n:02d}.png' for n in range(1, 11)],
             'extra/missing output or staging entry')
        receipts = sorted(path.name for path in (root / arm).glob('save-png-cycle-*.json'))
        need(receipts == [f'save-png-cycle-{n:02d}.json' for n in range(1, 11)], 'extra/missing durable cycle receipt')
    for index, entry in enumerate(report['entries']):
        ordinal, arm = index // 2 + 1, ('control', 'candidate')[index % 2]
        keys(entry, VALIDATION_ENTRY_FIELDS, 'validated PNG entry')
        exact_int(entry['ordinal'], ordinal, 'validated ordinal')
        need(entry['arm'] == arm and entry['filename'] == f'outputs/cycle-{ordinal:02d}.png',
             'validated entry order/path/arm differs')
        exact_int(entry['width'], WIDTH, 'PNG width'); exact_int(entry['height'], HEIGHT, 'PNG height')
        exact_int(entry['canonicalRGBABytes'], WIDTH*HEIGHT*4, 'full RGBA byte count')
        need(digest(entry['canonicalRGBASHA256']) == rgba_hash, 'canonical RGBA source differs')
        for flag in ('allSourcePixelsAndAlphaExactlyEqual', 'exactPNGBytesEqualAcrossArms', 'optionsVerified', 'pngMetadataVerified'):
            need(entry[flag] is True, 'native output check missing/failed: ' + flag)
        receipt = read_json(root / arm / f'save-png-cycle-{ordinal:02d}.json')
        native_cycle = (reports[arm]['warmups'] + reports[arm]['cycles'])[ordinal-1]
        need(canonical(receipt) == canonical(native_cycle), 'retained cycle receipt differs from producer report')
        need(receipt['protocol'] == PROTOCOL and receipt['arm'] == arm
             and receipt['workloadCompleted'] is True and receipt['outputFilename'] == entry['filename'],
             'retained output lacks completed actual Save receipt')
        exact_int(receipt['ordinal'], ordinal, 'receipt ordinal'); validate_options(receipt['options'])
        need(digest(receipt['sourceSHA256']) == source_hash, 'actual measured source differs from independent source')
        size = integer(entry['encodedBytes'], 1, MAX_PNG)
        exact_int(receipt['encodedBytes'], size, 'actual Save byte count')
        output = root / arm / entry['filename']
        need(regular(output, MAX_PNG).st_size == size and sha_file(output, MAX_PNG) == digest(entry['encodedSHA256']),
             'retained PNG bytes differ from independent validator')
        with output.open('rb') as handle:
            header = handle.read(33)
        need(len(header) == 33 and header[:16] == b'\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR'
             and struct.unpack('>II', header[16:24]) == (WIDTH, HEIGHT), 'retained PNG header/dimensions differ')
        if arm == 'candidate':
            previous = report['entries'][index-1]
            need(entry['encodedSHA256'] == previous['encodedSHA256'] and size == previous['encodedBytes'],
                 'corresponding exact PNG bytes differ across arms')
        checked.append({'arm': arm, 'ordinal': ordinal, 'encodedBytes': size, 'encodedSHA256': entry['encodedSHA256'],
                        'canonicalRGBASHA256': rgba_hash})
    validate_envelope(root / 'validation', report)
    return {'status': 'validated', 'validatedOutputCount': len(checked), 'entries': checked,
        'measurementFailuresDoNotSuppressOutputValidation': True,
        'pixelValidationScope': 'Separate native validator full RGBA and options checks bound to every actual retained PNG SHA256; portable reader does not perform native execution attestation.'}


def flattened(value):
    return {metric: value[flavor][kind][field] for metric, (flavor, kind, field) in MEMORY_METRICS.items()}


def differences(first, second):
    """Signed candidate-minus-control or after-minus-before; never clamp."""
    if type(first) is dict:
        need(type(second) is dict and first.keys() == second.keys(), 'metric shape differs')
        return {key: differences(first[key], second[key]) for key in first}
    if type(first) is list:
        need(type(second) is list and len(first) == len(second), 'metric array differs')
        return [differences(a, b) for a, b in zip(first, second)]
    return number(second, -2**64, 2**64) - number(first, -2**64, 2**64)


def summarize(report):
    values = {name: flattened(report[name]) for name in ENDPOINTS}
    cycles = report['warmups'] + report['cycles']
    settled = [flattened(cycle['settledBacking']) for cycle in cycles]
    measured = settled[2:]
    previous = [values['backingBaselineAfterWarmup']] + measured[:-1]
    latency_fields = ('sourceCreateSeconds', 'sourceHashSeconds', 'controllerCreationSeconds',
                      'requestToPreparedSeconds', 'saveLatencySeconds', 'elapsedSeconds')
    latency = {}
    for field in latency_fields:
        all_values = [cycle[field] for cycle in cycles]
        latency[field] = {'coldFirst': all_values[0], 'warmups': all_values[:2], 'measured': all_values[2:],
                         'warmP50': statistics.median(all_values[2:]), 'warmP95': max(all_values[2:])}
    peaks = ('peakResidentBytes', 'peakPhysicalFootprintBytes', 'peakVolatileResidentBytes', 'peakVolatileLedgerBytes')
    return {'absoluteEndpointsBytes': values,
        'absoluteEveryCycleBoundaryBytes': [{stage: flattened(cycle[stage]) for stage in STAGES} for cycle in cycles],
        'sampledPeaksBytes': {field: report['wholeRunSampledMemory'][field] for field in peaks},
        'everyCycleSampledPeaksBytes': [{field: cycle['sampledMemory'][field] for field in peaks} for cycle in cycles],
        'coldToWarmBytes': differences(values['backingBeforeWarmup'], values['backingBaselineAfterWarmup']),
        'measuredGrowthBytes': differences(values['backingBaselineAfterWarmup'], measured[-1]),
        'everyMeasuredIncrementBytes': [differences(a, b) for a, b in zip(previous, measured)],
        'lateMeasuredIncrementBytes': [differences(a, b) for a, b in zip(previous, measured)][-3:],
        'finalToLateBytes': differences(values['backingFinal'], values['backingLate']),
        'entryToLateBytes': differences(values['diagnosticEntryBacking'], values['backingLate']),
        'latencySeconds': latency, 'nativeElapsedSeconds': report['elapsedSeconds'], 'setupSeconds': report['setupSeconds']}


def run(root, app, source):
    result = {'schemaVersion': 1, 'protocol': PROTOCOL, 'status': 'incomplete', 'evidenceComplete': False,
        'benefitVerdict': 'single-pair-diagnostic-requires-review', 'promotionReady': False,
        'memoryStabilityAssessed': False, 'statisticalSignificanceAssessed': False,
        'general227RemedyClaim': False, 'nativeExecutionAttestedByChecker': False,
        'newNumericMemoryQualificationThresholds': False, 'errors': [], 'nativeReports': {}, 'measurements': {},
        'retainedOutputValidation': {'status': 'incomplete'},
        'interpretation': 'One ordered control/candidate pair of two warmups and eight measured Save PNG jobs. Absolute cold, warm, every-cycle, late, final, sampled and cumulative kernel peak observations plus signed differences are diagnostic only. No statistical, stability, ownership-attribution or general 227 remedy verdict. Missing observations never become zero; full raw native accounting remains included.',
        'latencySummaryDefinition': 'Cold first is first Save in a fresh app process, not cold OS caches. Warm p50 is median of eight measured saves; nearest-rank p95 is their maximum. No latency benefit qualification threshold.'}
    def check(label, action):
        try:
            return action()
        except (ValueError, KeyError, TypeError, OSError, IndexError, struct.error, OverflowError) as error:
            result['errors'].append({'check': label, 'error': str(error)[:4096]})
            return None
    root, app = Path(root).absolute(), Path(app).absolute()
    check('root', lambda: need(root.resolve(strict=True) == root and root.is_dir(), 'evidence root linked/missing'))
    check('cell-directories', lambda: need({p.name for p in root.iterdir() if p.is_dir()} - {'parts'}
          == {'control', 'candidate', 'validation'}, 'missing/extra process cell directory'))
    identity = check('identity', lambda: validate_identity(root, app, source))
    # Actual bundle identity can still bind outputs if a before/after/signature receipt failed.
    actual = identity or check('actual-bundle', lambda: bundle_identity(app, source)[0])
    if actual:
        result['actualBundleIdentity'] = actual
    reports, lifecycles = result['nativeReports'], {}
    for name in ('control', 'candidate', 'validation'):
        filename = 'save-png-validation.json' if name == 'validation' else 'save-png-comparison.json'
        native = check(name + '.report', lambda n=name, f=filename: read_json(root / n / f))
        if native is not None:
            reports[name] = native
            if actual:
                lifecycle = check(name + '.launch', lambda n=name, r=native: validate_launch(root, n, r, actual))
                if lifecycle:
                    lifecycles[name] = lifecycle
    if len(lifecycles) == 3:
        def order():
            ordered = [lifecycles[name] for name in ('control', 'candidate', 'validation')]
            need(len({row['processIdentifier'] for row in ordered}) == 3, 'fresh process PID reuse')
            need(all(a['finish'] <= b['start'] for a, b in zip(ordered, ordered[1:])),
                 'owned producer exit/validation order overlaps or differs')
            need(all(row['environment'] == ordered[0]['environment'] for row in ordered), 'cell base environment differs')
            need(all(reports[name]['operatingSystem'] == reports['control']['operatingSystem'] for name in reports),
                 'paired operating systems differ')
        check('fresh-process-order', order)
    result['lifecycles'] = lifecycles
    for arm in ('control', 'candidate'):
        if arm in reports and arm in lifecycles and actual:
            summary = check(arm + '.measurement', lambda a=arm: validate_measurement(root, a, reports[a], actual, lifecycles[a]))
            if summary:
                result['measurements'][arm] = summary
    # This must run after measurement failure as well as success.
    if len(reports) == 3 and len(lifecycles) == 3 and actual:
        validated = check('retained-outputs', lambda: validate_outputs(root, reports, actual, lifecycles))
        if validated:
            result['retainedOutputValidation'] = validated
    if len(result['measurements']) == 2:
        result['candidateMinusControl'] = differences(result['measurements']['control'], result['measurements']['candidate'])
    result['evidenceComplete'] = not result['errors'] and len(result['measurements']) == 2 and result['retainedOutputValidation']['status'] == 'validated'
    result['status'] = 'evidence-complete-review-required' if result['evidenceComplete'] else 'incomplete-or-invalid-evidence'
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--source', required=True, help='Expected full 40-hex Git source commit')
    parser.add_argument('--bundle', required=True, type=Path)
    parser.add_argument('--report', type=Path, help='Defaults to ROOT/save-png-summary.json')
    args = parser.parse_args()
    report = run(args.root, args.bundle, args.source)
    output = args.report or args.root / 'save-png-summary.json'
    output.write_text(json.dumps(report, indent=2, sort_keys=True, allow_nan=False) + '\n')
    print(json.dumps({'report': str(output), 'status': report['status'], 'evidenceComplete': report['evidenceComplete'],
                      'benefitVerdict': report['benefitVerdict'], 'errors': report['errors']}))
    return 0 if report['evidenceComplete'] else 2


if __name__ == '__main__':
    raise SystemExit(main())
