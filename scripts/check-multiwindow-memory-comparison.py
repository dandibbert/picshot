#!/usr/bin/env python3
"""Bind complete diagnostic cells; observations never approve a production fix."""
import json
import math
import pathlib
import re
import sys

PROFILES = (
    ('baseline', 'coreGraphicsBaseline', False, False),
    ('tail-first', 'coreGraphicsBaseline', True, False),
    ('baseline-traced', 'coreGraphicsBaseline', False, True),
    ('tail-first-traced', 'coreGraphicsBaseline', True, True),
    ('candidate', 'normalizedCandidate', False, False),
    ('candidate-traced', 'normalizedCandidate', False, True),
)
COUNTERS = ('resident_size', 'phys_footprint', 'purgeable_volatile_resident',
            'purgeable_volatile_virtual', 'compressed', 'ledger_purgeable_volatile_compressed')
OUTPUT_SHA256 = '5b8033659faae766800872f3684782128355a46fc4603aa5718e3134b2ac941d'
CANDIDATE_IMPLEMENTATION = 'vimage-canonical-cgimage-quartz-strips-v1'
PRODUCTION_DEFAULT = 'normalizedCandidate'


def require(condition, message):
    # Deliberately not assert: PYTHONOPTIMIZE must not bypass an evidence gate.
    if not condition:
        raise ValueError(message)


def integer(value, label, minimum=None):
    require(type(value) is int, label + ' must be an integer')
    require(minimum is None or value >= minimum, label + ' is below its bound')
    return value


def finite(value, label):
    require(type(value) in (int, float) and math.isfinite(value) and value >= 0,
            label + ' must be a finite nonnegative number')
    return value


def counter_values(value, label):
    require(isinstance(value, dict), label + ' must be a counter object')
    return {key: integer(value[key], label + '.' + key,
                        None if key == 'ledger_purgeable_volatile_compressed' else 0) for key in COUNTERS}


def delta(before, after):
    return {key: after[key] - before[key] for key in COUNTERS}


def trace_sequence(candidate, tail_first):
    expected = []
    def emit(phase, cycle, event, window=0, top=-1):
        expected.append((phase, cycle, event, window, top))
    for phase, count in ((1, 4), (2, 12)):
        for cycle in range(1, count + 1):
            for event in ('canvasBeforeAllocation', 'canvasAfterAllocation'):
                emit(phase, cycle, event)
            for window in (202, 101):
                for event in ('decodeBefore', 'decodeImageCreated', 'decodeReturned', 'inputBeforeAppend'):
                    emit(phase, cycle, event, window)
                if candidate:
                    for event in ('normalizationBefore', 'normalizationAfter', 'candidateBlendBefore'):
                        emit(phase, cycle, event, window)
                emit(phase, cycle, 'appendBeforeDraws', window)
                tops = [2048] + list(range(0, 2048, 128)) if tail_first else list(range(0, 2160, 128))
                for top in tops:
                    emit(phase, cycle, 'drawBefore', window, top)
                    emit(phase, cycle, 'drawAfter', window, top)
                emit(phase, cycle, 'appendAfterFlush', window)
                if candidate:
                    emit(phase, cycle, 'candidateBlendAfter', window)
                emit(phase, cycle, 'inputAfterAppendScope', window)
            for event in ('finishBefore', 'finishAfterOwnershipTransfer', 'outputAfterFinishScope',
                          'digestBefore', 'digestAfter', 'cycleAfterRelease'):
                emit(phase, cycle, event)
    for event, window in (('canvasBeforeAllocation', 0), ('canvasAfterAllocation', 0),
                          ('decodeBefore', 202), ('decodeImageCreated', 202), ('decodeReturned', 202),
                          ('cancellationAfterRelease', 0)):
        emit(3, 0, event, window)
    return expected


def check_trace(report, candidate, tail_first):
    trace = report['diagnosticBoundaryTrace']
    require(integer(trace['capacity'], 'trace.capacity') == 2048, 'trace capacity changed')
    require(integer(trace['overflowCount'], 'trace.overflowCount') == 0, 'trace overflowed')
    require(integer(trace['allocatedBytes'], 'trace.allocatedBytes', 1) == report['diagnosticTraceAllocatedBytesBeforeEntry'],
            'trace allocation metadata disagrees')
    expected = trace_sequence(candidate, tail_first)
    rows = trace['observations']
    require(integer(trace['recordCount'], 'trace.recordCount') == len(rows) == len(expected), 'trace length changed')
    previous_time = 0
    for index, (row, expected_row) in enumerate(zip(rows, expected)):
        actual = (row['phase'], row['cycle'], row['event'], row['windowID'], row['stripTop'])
        for key in ('phase', 'cycle', 'windowID', 'stripTop'):
            integer(row[key], f'trace[{index}].{key}')
        require(actual == expected_row, f'trace[{index}] expected {expected_row}, received {actual}')
        for flavor, name in (('standard', 'TASK_VM_INFO'), ('purgeable', 'TASK_VM_INFO_PURGEABLE')):
            value = row[flavor]
            require(value['flavor'] == name, f'trace[{index}] wrong task flavor')
            require(integer(value['kernelReturn'], 'kernelReturn') == 0, 'trace task_info failed')
            require(value['requiredCountersAvailable'] is True and value['missingRequiredFields'] == [], 'trace declares missing counters')
            returned = integer(value['returnedNaturalCount'], 'returnedNaturalCount', 1)
            require(returned <= integer(value['requestedNaturalCount'], 'requestedNaturalCount', 1), 'trace count exceeds requested capacity')
            names = ('resident_size', 'phys_footprint', 'compressed') if flavor == 'standard' else ('purgeable_volatile_resident', 'purgeable_volatile_virtual')
            for key in names:
                integer(value['bytes'][key], f'trace[{index}].{flavor}.{key}', 0)
            if flavor == 'purgeable':
                integer(value['ledgerBytes']['ledger_purgeable_volatile_compressed'], 'trace compressed ledger')
            stamp = finite(value['observedAtUptimeSeconds'], 'trace timestamp')
            require(stamp >= previous_time, 'trace task timestamps moved backward')
            previous_time = stamp


def ownership(value, cancelled=False):
    expected = dict(inputObjectsCreated=1 if cancelled else 2, decoderObjectsCreated=1 if cancelled else 2,
        outputObjectsCreated=0 if cancelled else 1, maximumConcurrentInputObjects=1,
        liveInputObjects=0, liveDecoderObjects=0, liveOutputObjects=0)
    for key, wanted in expected.items():
        require(integer(value[key], 'ownership.' + key) == wanted, 'ownership mismatch: ' + key)


def validate(root, source):
    require(re.fullmatch(r'[0-9a-f]{40}', source) is not None, 'invalid source commit')
    root = pathlib.Path(root)
    outcomes = json.loads((root / 'cell-outcomes.json').read_text())
    require(isinstance(outcomes, list) and len(outcomes) == len(PROFILES), 'six cell outcomes are required')
    for outcome, profile in zip(outcomes, PROFILES):
        require(outcome['profile'] == profile[0], 'cell outcome order or identity changed')
        require(outcome['status'] == 'exited' and integer(outcome['exitCode'], 'cell exitCode') == 0,
                profile[0] + ': cell failed or was skipped')
        require(outcome.get('reason') is None, profile[0] + ': unexpected outcome reason')
    cells, identities, inputs, outputs, pids, architectures, systems = [], set(), set(), set(), set(), set(), set()
    for name, mode, tail_first, traced in PROFILES:
        directory = root / name
        read = lambda filename: json.loads((directory / filename).read_text())
        report, checked = read('multi-window-resource.json'), read('checked-resource.json')
        provenance, launch, launcher = read('provenance.json'), read('launch.json'), read('launch.json.launcher.json')
        require(checked['status'] == report['status'] == launch['status'] == 'observed', name + ': incomplete report')
        require(checked['observationsComplete'] is report['observationsComplete'] is True, name + ': incomplete observations')
        require(provenance['sourceCommit'] == launch['sourceCommit'] == checked['sourceCommit'] == source, name + ': wrong source')
        pid = integer(report['pid'], 'pid', 1)
        require(pid == integer(launch['pid'], 'launch.pid', 1) == integer(launcher['processIdentifier'], 'launcher.pid', 1), name + ': PID mismatch')
        require(launcher['status'] == 'exited' and integer(launcher['launcherExitCode'], 'launcherExitCode') == 0,
                name + ': unsuccessful launcher exit')
        require(launcher['ownedExitConfirmed'] is launcher['createsNewApplicationInstance'] is launcher['callbackReceived'] is True,
                name + ': unconfirmed fresh lifecycle')
        require(checked['ownedExitConfirmed'] is True, name + ': checked lifecycle mismatch')
        bundle = pathlib.Path(provenance['bundlePath']).resolve()
        for value in (report['bundlePath'], launch['bundlePath'], launcher['selectedAppPath'], launcher['launchedAppPath']):
            require(pathlib.Path(value).resolve() == bundle, name + ': bundle path mismatch')
        executable = bundle / 'Contents/MacOS/PicShot'
        require(pathlib.Path(report['executablePath']).resolve() == executable, name + ': executable mismatch')
        require(len(launch['arguments']) == 1 and pathlib.Path(launch['arguments'][0]).resolve() == executable, name + ': unexpected process operands')
        require(report['compositionMode'] == checked['compositionMode'] == mode and report['productionCompositionMode'] == checked['productionCompositionMode'] == PRODUCTION_DEFAULT, name + ': wrong mode')
        require(report['compositionModeSource'] == checked['compositionModeSource'] == 'diagnosticOverride',
                name + ': comparison cell must explicitly select its renderer')
        require(report['diagnosticCompositionOverride'] == checked['diagnosticCompositionOverride'] == mode,
                name + ': missing or mismatched diagnostic renderer override')
        require(report['candidateImplementation'] == CANDIDATE_IMPLEMENTATION, name + ': wrong candidate implementation')
        require(report['diagnosticTailStripFirst'] is tail_first and report['diagnosticBoundariesEnabled'] is traced, name + ': wrong control flags')
        workload = dict(warmupCycles=4, measuredCycles=12, windowsPerCycle=2,
            completedWarmupCycles=4, completedMeasuredCycles=12, remainingWarmupCycles=0, remainingMeasuredCycles=0,
            sourceWidth=3840, sourceHeight=2160, outputWidth=4480, outputHeight=2520,
            maximumConcurrentCycleTasks=1, cooperativeDeadlineSeconds=180, perCompositionDeadlineSeconds=20,
            normalizationRasterBytes=3840*2160*4 if mode == 'normalizedCandidate' else 0)
        for key, wanted in workload.items():
            require(integer(report[key], name + '.' + key) == wanted, name + ': workload changed: ' + key)
        for key in ('screenCaptureStarted', 'permissionRequested', 'systemScreenshotCommandInvoked', 'userAssetsRead',
                    'globalInputPosted', 'memoryPressureOrPurgeRequested', 'zeroLeakClaim', 'plateauAssessed', 'memoryStabilityAssessed'):
            require(report[key] is False, name + ': forbidden scope/verdict: ' + key)
        require(checked['memoryStabilityAssessed'] is False, name + ': checked stability claim')
        require(report['temporaryDirectoryRemoved'] is True and integer(report['ownedOpenFileDescriptorsAfterCleanup'], 'cleanup FD') == 0, name + ': incomplete cleanup')
        require(report['cancellation']['status'] == 'passed', name + ': cancellation failed')
        ownership(report['cancellation']['ownership'], cancelled=True)
        require(integer(report['cancellation']['ownedOpenFileDescriptors'], 'cancellation FD') == 0, name + ': cancellation FD retained')
        elapsed = finite(report['elapsedSeconds'], 'elapsedSeconds')
        require(0 < elapsed <= 180 and checked['elapsedSeconds'] == elapsed, name + ': invalid elapsed time')
        require(integer(checked['measuredCycles'], 'checked.measuredCycles') == 12, name + ': checked count mismatch')
        digest = provenance['executableSHA256']
        require(isinstance(digest, str) and re.fullmatch(r'[0-9a-f]{64}', digest) is not None, name + ': invalid executable digest')
        identities.add((source, provenance['version'], provenance['buildVersion'], digest, integer(provenance['executableBytes'], 'executableBytes', 1)))
        pids.add(pid); architectures.add(report['compiledArchitecture']); systems.add(report['osVersion'])
        require(report['compiledArchitecture'] in ('arm64', 'x86_64'), name + ': unknown architecture')
        entries = report['preparedInputs']
        require(len(entries) == 2 and [entry['filename'] for entry in entries] == ['front.png', 'back.png'], name + ': wrong input identities')
        for entry in entries:
            require(integer(entry['bytes'], 'PNG size', 1) <= 80*1024*1024, name + ': PNG exceeds bound')
            for key in ('pngSHA256', 'generatedRGBA_SHA256'):
                require(re.fullmatch(r'[0-9a-f]{64}', entry[key]) is not None, name + ': invalid input digest')
        inputs.add(tuple((entry['filename'], entry['bytes'], entry['pngSHA256'], entry['generatedRGBA_SHA256']) for entry in entries))
        require(report['expectedOutputSHA256'] == OUTPUT_SHA256, name + ': procedural output identity changed')
        outputs.add(report['expectedOutputSHA256'])
        for category, phase, count in (('warmups', 'warmup', 4), ('cycles', 'measured', 12)):
            require(len(report[category]) == count, name + ': incomplete cycles')
            for index, cycle in enumerate(report[category], 1):
                require(cycle['phase'] == phase and integer(cycle['index'], 'cycle.index') == index, name + ': unordered cycles')
                require(cycle['rgbaSHA256'] == OUTPUT_SHA256 and integer(cycle['exactOutputPixels'], 'output pixels') == 4480*2520, name + ': output mismatch')
                require(integer(cycle['ownedOpenFileDescriptorsAfter'], 'cycle FD') == 0, name + ': cycle FD retained')
                ownership(cycle['ownership'])
                raster = cycle['ownedRasterProbe']
                for key in ('currentRasterBytes', 'canvasBytes', 'normalizationBytes', 'admittedSourceBytes'):
                    require(integer(raster[key], 'raster.' + key) == 0, name + ': explicit raster retained')
                require(0 < integer(raster['peakRasterBytes'], 'raster peak') <= 192_000_000, name + ': raster budget exceeded')
                require(integer(raster['normalizationCount'], 'normalizationCount') == (2 if mode == 'normalizedCandidate' else 0), name + ': wrong conversion count')
                require(integer(raster['canonicalImagesCreated'], 'canonicalImagesCreated') == (2 if mode == 'normalizedCandidate' else 0), name + ': wrong canonical image count')
                require(integer(raster['liveCanonicalImages'], 'liveCanonicalImages') == 0, name + ': canonical image retained')
                for boundary in ('before', 'afterCompositionBeforeDigest', 'afterDigestBeforeOutputRelease', 'afterRelease'):
                    counter_values(cycle[boundary]['counters'], name + '.' + boundary)
        boundary = {key: counter_values(report[key]['counters'], name + '.' + key) for key in
                    ('fixtureEntryBeforeInputPreparation', 'afterInputPreparationPreWarmup', 'afterWarmupBaseline', 'finalAfterCleanup')}
        measured = delta(boundary['afterWarmupBaseline'], boundary['finalAfterCleanup'])
        require(checked['afterWarmupToCleanupDeltaBytes'] == measured, name + ': stale measured delta')
        total = report['transientSampler']['total']
        require(integer(total['timerSampleCount'], 'timerSampleCount', 1) <= integer(total['sampleCount'], 'sampleCount', 1), name + ': invalid sampler count')
        require(total['missingFieldCounts'] == {}, name + ': missing sampled memory fields')
        peaks = counter_values(total['sampledPeakBytes'], name + '.sampledPeakBytes')
        require(checked['sampledPeakBytes'] == peaks, name + ': stale sampled peaks')
        increments = [dict(fromMeasuredCycle=index, toMeasuredCycle=index+1,
            counterDeltaBytes=delta(report['cycles'][index-1]['afterRelease']['counters'], report['cycles'][index]['afterRelease']['counters']))
            for index in range(1,12)]
        require(report['measuredBoundaryIncrements'] == increments, name + ': stale measured increments')
        require(report['lateMeasuredIncrements'] == checked['lateMeasuredIncrements'] == increments[-4:], name + ': stale late increments')
        if traced:
            integer(report['diagnosticTraceAllocatedBytesBeforeEntry'], 'trace storage', 1)
            check_trace(report, mode == 'normalizedCandidate', tail_first)
        else:
            require(integer(report['diagnosticTraceAllocatedBytesBeforeEntry'], 'trace storage') == 0 and 'diagnosticBoundaryTrace' not in report, name + ': unexpected trace')
        cells.append(dict(profile=name, pid=pid, mode=mode, tailStripFirst=tail_first, boundaries=traced,
            elapsedSeconds=elapsed, inputPreparation=boundary['afterInputPreparationPreWarmup'],
            fixtureEntry=boundary['fixtureEntryBeforeInputPreparation'], afterWarmup=boundary['afterWarmupBaseline'],
            final=boundary['finalAfterCleanup'], measuredDelta=measured,
            lateMeasuredIncrements=increments[-4:], sampledPeaks=peaks))
    require(len(identities) == len(inputs) == len(outputs) == len(architectures) == len(systems) == 1, 'cells do not share binary/input/system identity')
    require(len(pids) == len(PROFILES), 'Every cell requires a distinct, confirmed-exited process')
    return dict(status='observed', observationsComplete=True, sourceCommit=source, productionDefault=PRODUCTION_DEFAULT,
                candidateImplementation=CANDIDATE_IMPLEMENTATION,
                memoryStabilityAssessed=False, productionPromotionApproved=False, cells=cells)


if __name__ == '__main__':
    require(len(sys.argv) == 3, 'ROOT SOURCE')
    try:
        result = validate(sys.argv[1], sys.argv[2])
    except Exception as error:
        result = dict(status='failed', observationsComplete=False, sourceCommit=sys.argv[2],
            memoryStabilityAssessed=False, productionPromotionApproved=False,
            error=f'{type(error).__name__}: {error}')
    (pathlib.Path(sys.argv[1]) / 'comparison.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    sys.exit(0 if result['status'] == 'observed' else 1)
