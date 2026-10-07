#!/usr/bin/env python3
"""Validate the opt-in wait/latch comparison; never emit a production-fix verdict."""
import importlib.util
import json
from pathlib import Path
import statistics
import sys

SPEC = importlib.util.spec_from_file_location('large_check', Path(__file__).with_name('check-image-decode-large-report.py'))
LARGE = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(LARGE)


def report(root, profile, mode):
    return LARGE.read(root / f'{profile}-{mode}' / f'image-decode-large-{mode}.json')


def median(values):
    assert values
    return statistics.median(values)


def process_times(processes, strategy):
    values = []
    for p in processes:
        t = p['parentTimingUptimes']; child = p['childTimingTrace']
        end = t['terminationLatchValidated'] if strategy == 'termination-latch' else t['waitUntilExitCompleted']
        start = t['terminationLatchWaitStarted'] if strategy == 'termination-latch' else t['waitUntilExitStarted']
        item = {'signatureSeconds': p['signatureSeconds'], 'exitConfirmationWaitSeconds': end-start,
                'responsePreparedToExitConfirmedSeconds': p['boundaryUptimes']['childExitConfirmed']-p['terminal']['responsePreparedUptimeSeconds'],
                'terminalSendSeconds': child['terminalWriteCompletedUptimeSeconds']-child['terminalWriteStartedUptimeSeconds']}
        if strategy == 'termination-latch':
            observation = p['terminationLatch']
            item['runReturnedToCallbackSeconds'] = observation['callbackEnteredUptimeSeconds']-child['runReturnedUptimeSeconds']
            item['callbackPublishedToValidationSeconds'] = t['terminationLatchValidated']-observation['callbackPublishedUptimeSeconds']
        assert all(v >= 0 for v in item.values())
        values.append(item)
    return {k: median([v[k] for v in values]) for k in values[0]}


def validate_probe(root, source, architecture, mode, prepared, child_pids):
    r = LARGE.read(root / mode / f'image-decode-large-{mode}.json')
    assert r['protocol'] == 'image-decode-large-parent-v2' and r['status'] == 'observed'
    assert r['sourceCommit'] == source and r['architecture'] == architecture and r['mode'] == mode and r['profile'] == '5k'
    assert r['timingInstrumentationVersion'] == 3 and r['exitObservationStrategy'] == 'termination-latch'
    assert r['sourceWidth'] == 5120 and r['sourceHeight'] == 2880 and r['previewWidth'] == 1024 and r['previewHeight'] == 576
    assert r['maximumPreviewBytes'] == 4194304 and r['maximumEncodedBytes'] == 8388608 and r['rasterBytes'] == 2359296
    assert r['parentLossVerified'] is False and r['oneShotProbe'] is True
    assert r['warmupCycles'] == r['measuredCycles'] == r['completedParentDraws'] == 0
    assert r['armDeadlineSeconds'] == 20 and r['requiredOuterDeadlineSeconds'] == 30 and 0 <= r['elapsedSeconds'] <= 20
    assert r['inputPreparationProcessIdentifier'] == prepared['processIdentifier'] and r['processIdentifier'] != prepared['processIdentifier']
    assert r['pngSHA256'] == prepared['pngSHA256'] and r['rawSHA256'] == prepared['rawSHA256']
    assert r['probeDecodedRGBAMatchesReference'] is True and r['sharedLeaseReacquired'] is True and r['ownedJobsRemaining'] == 0
    assert r['helperInvocations'] == 1 and r['parentMemoryWatchdogBytes'] == 536870912 and r['childMemoryWatchdogBytes'] == 268435456
    for name in ['beforeProbe', 'afterProbe']:
        LARGE.memory(r[name]); assert r[name]['standard']['bytes']['resident_size'] <= 536870912 and r[name]['standard']['bytes']['phys_footprint'] <= 536870912
    deadline = mode == 'timeout-after-decode'
    LARGE.process(r['probe'], '5k', prepared['rawSHA256'], child_pids, allow_cancel=True, timing_enabled=True,
                  exit_strategy='termination-latch', allow_deadline=deadline)
    assert r['probe']['outcome'] == ('deadline-after-decode' if deadline else 'cancelled-after-decode')
    assert r['probe']['sawPostDecodeReady'] and not r['probe']['outputExistedBeforeCleanup']
    assert r['probe']['terminationStatus'] == 1 and r['probe']['terminationReason'] == 'exit'
    return {'mode': mode, 'outcome': r['probe']['outcome'], 'elapsedSeconds': r['elapsedSeconds'],
            'exitConfirmed': True, 'EOFConfirmed': True, 'ownedCleanupConfirmed': True, 'sharedLeaseReacquired': True}


def validate(root, source, architecture):
    arms = {strategy: root / strategy for strategy in ['wait-until-exit', 'termination-latch']}
    summaries = {strategy: LARGE.validate(path, source, architecture, timing_enabled=True, exit_strategy=strategy)
                 for strategy, path in arms.items()}
    for profile in ['4k', '5k']:
        inputs = [LARGE.read(path / f'prepared-{profile}' / 'image-decode-large-inputs.json') for path in arms.values()]
        for key in ['sourceWidth', 'sourceHeight', 'previewWidth', 'previewHeight', 'rawSHA256', 'pngSHA256']:
            assert inputs[0][key] == inputs[1][key]
    pairs = []
    for profile, mode in [('4k', 'isolated-decode'), ('5k', 'isolated-decode'), ('5k', 'native-ui-isolated')]:
        pair = {'profile': profile, 'mode': mode, 'arms': {}}
        for strategy, path in arms.items():
            r = report(path, profile, mode); ui = mode.startswith('native-ui')
            cycles = r['cycles']
            processes = ([w['process'] for w in r['workers'] if w['index'] in [c['workerIndex'] for c in cycles]] if ui else [c['process'] for c in cycles])
            item = {'measuredSamples': len(cycles), 'medianLatencySeconds': median([c['requestToNativeDrawSeconds' if ui else 'fullLifecycleSeconds'] for c in cycles]),
                    'latencyScope': 'request-to-native-draw' if ui else 'full-lifecycle', 'medianProcessTiming': process_times(processes, strategy),
                    'parentPeaks': r['parentPeaks']}
            if ui: item.update(maximumMainQueueDelaySeconds=r['mainQueue']['maximumDelaySeconds'], backingScaleFactor=r['backingScaleFactor'])
            pair['arms'][strategy] = item
        pairs.append(pair)
    candidate = arms['termination-latch']
    prepared = LARGE.read(candidate / 'prepared-5k' / 'image-decode-large-inputs.json')
    child_pids = {p['childPID'] for profile in ['4k', '5k'] for c in (lambda r:r['warmups']+r['cycles'])(report(candidate, profile, 'isolated-decode')) for p in [c['process']]}
    child_pids.update(w['process']['childPID'] for w in report(candidate, '5k', 'native-ui-isolated')['workers'] if w['process']['childLaunched'])
    probes = [validate_probe(root / 'probes', source, architecture, mode, prepared, child_pids) for mode in ['cancel-after-decode', 'timeout-after-decode']]
    return {'protocol': 'image-decode-exit-comparison-v1', 'status': 'observed', 'sourceCommit': source, 'architecture': architecture,
            'arms': summaries, 'comparisons': pairs, 'probes': probes, 'parentLossVerified': False,
            'interpretation': 'Opt-in sequential wait/callback observations only; no decoder/default/signature change or production-remedy verdict'}


if __name__ == '__main__':
    if len(sys.argv) != 4: raise SystemExit('Usage: check-image-decode-exit-report.py ROOT SOURCE ARCH')
    root = Path(sys.argv[1]); result = validate(root, sys.argv[2], sys.argv[3])
    output = json.dumps(result, indent=2, sort_keys=True)+'\n'
    assert len(output.encode()) <= 262144
    (root/'exit-comparison.json').write_text(output)
    print(output)
