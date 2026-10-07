#!/usr/bin/env python3
"""Bounded v2 large/native-UI evidence validation; no memory-remedy verdict."""
import hashlib
import json
import math
from pathlib import Path
import statistics
import sys


def read(path, maximum=2_097_152):
    assert 0 < path.stat().st_size <= maximum
    return json.loads(path.read_text())


def memory(m):
    assert m['standard']['kernelReturn'] == m['purgeable']['kernelReturn'] == 0
    assert m['standard']['bytes']['resident_size'] > 0 and m['standard']['bytes']['phys_footprint'] > 0
    assert all(k in m['purgeable']['bytes'] for k in ('purgeable_volatile_resident', 'purgeable_volatile_virtual', 'purgeable_volatile_pmap'))


def process(m, profile, reference_sha, pids, allow_cancel=False):
    assert m['diagnosticProfile'] == profile and m['cleanupConfirmed'] and m['admissionReleased']
    assert m['stdoutBytes'] <= 131072 and m['stderrBytes'] <= 8192 and not m['stderrTruncated']
    if m.get('jobDirectory'): assert not Path(m['jobDirectory']).exists()
    if not m['childLaunched']:
        assert allow_cancel and m['outcome'] == 'cancelled'
        return
    assert m['exitConfirmed'] and m['terminationReason'] == 'exit'
    assert m['childPID'] not in pids; pids.add(m['childPID'])
    assert m['launchThroughExitSeconds'] < 9
    assert [p['phase'] for p in m['signaturePhases']] == ['pathAndIdentity', 'appCodeObject', 'appValidity', 'helperCodeObject', 'helperValidity']
    for phase in m['signaturePhases']:
        assert math.isfinite(phase['elapsedSeconds']) and phase['elapsedSeconds'] >= 0
        if phase['phase'] != 'pathAndIdentity': assert phase['securityStatus'] == 0
    terminal = m['terminal']; assert terminal['schema'] == 'image-decode-helper-v2' and terminal['profile'] == profile
    assert terminal['childPID'] == m['childPID']
    assert terminal['helperEntryUptimeSeconds'] <= terminal['responsePreparedUptimeSeconds']
    assert terminal['peaks']['residentBytes'] <= 268435456 and terminal['peaks']['footprintBytes'] <= 268435456
    actual_phases = [p['child']['phase'] for p in m['phases']]
    normal_prefix = ['beforePNGRead', 'imageCreated', 'rasterDrawn', 'afterContextRelease', 'outputClosed', 'afterDecodePool']
    if m['outcome'] == 'decoded': assert actual_phases == normal_prefix + ['complete']
    elif m['outcome'] == 'cancelled-after-decode': assert actual_phases == normal_prefix[:4] + ['heldAfterDecode', 'failed']
    else:
        # Ordinary UI cancellation can arrive during decode or just after a
        # successful child exit. Neither case may publish a stale UI artifact.
        assert allow_cancel and m['outcome'] == 'cancelled' and actual_phases
        if terminal['kind'] == 'result': assert actual_phases == normal_prefix + ['complete']
        else: assert actual_phases[-1] == 'failed' and actual_phases[:-1] == normal_prefix[:len(actual_phases)-1]
    required_boundaries = {'signatureStarted', 'signatureFinished', 'stagingFinished', 'processRunStarted', 'processRunReturned', 'childExitConfirmed', 'cleanupFinished'}
    if m['outcome'] == 'decoded': required_boundaries.add('rawReadFinished')
    assert required_boundaries.issubset(m['parentBoundaries']) and required_boundaries.issubset(m['boundaryUptimes'])
    assert set(m['parentBoundaries']) == set(m['boundaryUptimes'])
    for pair in m['phases']:
        assert pair['child']['childPID'] == m['childPID']
        memory(pair['parentAtReceipt'])
        if 'memory' in pair['child']: memory(pair['child']['memory'])
    for sample in m['parentBoundaries'].values(): memory(sample)
    if m['outcome'] == 'decoded':
        assert terminal['kind'] == 'result' and m['terminationStatus'] == 0
        assert terminal['rawBytes'] == 2359296 and terminal['rawSHA256'] == reference_sha
        assert set(('stagingFinished', 'childExitConfirmed', 'rawReadFinished', 'cleanupFinished')).issubset(m['boundaryUptimes'])
    else:
        assert allow_cancel and m['outcome'] in ('cancelled', 'cancelled-after-decode')
        if terminal['kind'] == 'error': assert terminal['error'] == 'cancelled' and m['terminationStatus'] == 1
        else:
            assert m['outcome'] == 'cancelled' and terminal['kind'] == 'result' and m['terminationStatus'] == 0
            assert terminal['rawSHA256'] == reference_sha and terminal['rawBytes'] == 2359296
        if m['sawPostDecodeReady']:
            ready = next(p['child'] for p in m['phases'] if p['child']['kind'] == 'ready')
            assert ready['rawSHA256'] == reference_sha and not m['outputExistedBeforeCleanup']


def validate(root, source, architecture, headless_only=False):
    summaries = []; parent_pids = set(); child_pids = set(); inputs = {}
    for profile, width, height in [('4k', 3840, 2160), ('5k', 5120, 2880)]:
        prepared = read(root/f'prepared-{profile}/image-decode-large-inputs.json')
        assert prepared['protocol'] == 'image-decode-large-input-v2' and prepared['status'] == 'prepared'
        assert prepared['profile'] == profile and prepared['sourceCommit'] == source and prepared['architecture'] == architecture
        assert (prepared['sourceWidth'], prepared['sourceHeight']) == (width, height)
        assert (prepared['previewWidth'], prepared['previewHeight'], prepared['rawBytes']) == (1024, 576, 2359296)
        assert 0 < prepared['pngBytes'] <= 8388608
        assert prepared['processIdentifier'] not in parent_pids; parent_pids.add(prepared['processIdentifier']); inputs[profile] = prepared
        for name, key in [('input.png', 'pngSHA256'), ('reference.rgba', 'rawSHA256')]:
            path = root/f'prepared-{profile}'/name
            assert path.stat().st_size == (prepared['pngBytes'] if name == 'input.png' else 2359296)
            assert path.stat().st_size <= 8388608 and hashlib.sha256(path.read_bytes()).hexdigest() == prepared[key]
        for mode in ['production-control', 'isolated-decode']:
            r = read(root/f'{profile}-{mode}'/f'image-decode-large-{mode}.json')
            base(r, source, architecture, profile, prepared, parent_pids)
            assert r['mode'] == mode
            assert r['warmupCycles'] == 2 and r['measuredCycles'] == 12 and len(r['warmups']) == 2 and len(r['cycles']) == 12
            assert r['completedDraws'] == r['completedExactPixelChecks'] == 14
            assert r['armDeadlineSeconds'] == 180 and r['requiredOuterDeadlineSeconds'] == 200 and r['elapsedSeconds'] <= 180
            for group, warm in [('warmups', True), ('cycles', False)]:
                for index, c in enumerate(r[group], 1):
                    assert c['index'] == index and c['isWarmup'] == warm
                    for key in ('before', 'beforeImageCreation', 'afterPool', 'settled'): memory(c[key])
                    d = c['draw']; memory(d['beforeDraw']); memory(d['afterDraw'])
                    assert d['maximumDifference'] == 0 and d['validatedBytes'] == 2359296 and d['pixelsSHA256'] == prepared['rawSHA256']
                    assert 0 < c['timeToValidatedPixelsSeconds'] <= c['fullLifecycleSeconds'] <= c['observedCycleSeconds']
                    if mode == 'isolated-decode': process(c['process'], profile, prepared['rawSHA256'], child_pids)
                    else: assert 'process' not in c
            assert r['helperInvocations'] == (14 if mode == 'isolated-decode' else 0)
            b, end = r['baselineAfterWarmup'], r['cycles'][-1]['settled']; memory(b); memory(end)
            summary = {'profile': profile, 'mode': mode, 'medianFullLifecycleSeconds': statistics.median(c['fullLifecycleSeconds'] for c in r['cycles']),
                'parentRSSDeltaBytes': end['standard']['bytes']['resident_size']-b['standard']['bytes']['resident_size'],
                'parentFootprintDeltaBytes': end['standard']['bytes']['phys_footprint']-b['standard']['bytes']['phys_footprint'],
                'parentVolatileResidentDeltaBytes': end['purgeable']['bytes']['purgeable_volatile_resident']-b['purgeable']['bytes']['purgeable_volatile_resident']}
            summaries.append(summary)
    if not headless_only:
        for mode in ['native-ui-control', 'native-ui-isolated']:
            r = read(root/f'5k-{mode}'/f'image-decode-large-{mode}.json'); prepared = inputs['5k']
            base(r, source, architecture, '5k', prepared, parent_pids)
            assert r['mode'] == mode
            assert r['warmupCycles'] == 2 and r['measuredCycles'] == 4 and len(r['warmups']) == 2 and len(r['cycles']) == 4
            assert r['completedSuccessfulNativeDraws'] == r['exactSuccessfulPreviewValidations'] == 6 and r['actualNativeDrawCount'] >= 6
            assert r['armDeadlineSeconds'] == 120 and r['requiredOuterDeadlineSeconds'] == 140 and r['elapsedSeconds'] <= 120
            assert r['controllersReleased'] and r['activeExportControllers'] == 0
            assert r['debounceBurst']['startedWorkers'] == 1 and r['debounceBurst']['latestResultDrawn']
            assert len(r['workers']) == 10 and len(r['faultScenarios']) == 3
            workers = {w['index']: w for w in r['workers']}
            assert set(workers) == set(range(1, 11))
            assert r['mainQueue']['samples'] > 0 and r['mainQueue']['outstandingCallbacks'] == 0
            assert len(r['mainQueue']['histogramTenMillisecondBins']) == 64
            assert r['responsivenessFlagTriggered'] == (r['mainQueue']['maximumDelaySeconds'] > 0.1)
            for expected_worker, c in enumerate(r['warmups']+r['cycles'], 1):
                assert c['workerIndex'] == expected_worker
                assert c['exactPreviewPixels'] and c['rawSHA256'] == prepared['rawSHA256']
                assert c['workerIndex'] in workers and workers[c['workerIndex']]['scenario'] == 'normal' and workers[c['workerIndex']]['outcome'] == 'completed'
                d = c['nativeDraw']; assert d['windowVisible'] and d['backingScale'] > 0 and d['displayedRect'][2] > 0 and d['displayedRect'][3] > 0
                assert 0 < c['requestToNativeDrawSeconds'] < 120
                assert d['uptimeSeconds'] >= workers[c['workerIndex']]['finishedUptimeSeconds']
                memory(c['before']); memory(c['settled'])
            for f in r['faultScenarios']:
                assert f['staleResultSuppressed'] and f['windowClosed'] and isinstance(f['cancellationRaceExercised'], bool)
                assert f['cancellationHandledToWorkerFinishedSeconds'] >= 0
            assert {f['scenario'] for f in r['faultScenarios']} == {'cancelActive', 'closeDecoded', 'lateResult'}
            assert r['allRequestedCancellationRacesObserved'] == all(f['cancellationRaceExercised'] and f.get('cancelOverlappedSignatureValidation', True) for f in r['faultScenarios'])
            for f in r['faultScenarios']:
                assert f['workerIndex'] in workers and workers[f['workerIndex']]['scenario'] == f['scenario']
                worker = workers[f['workerIndex']]
                if worker['outcome'] == 'completed':
                    assert mode == 'native-ui-isolated' and f['scenario'] == 'cancelActive' and not f['cancellationRaceExercised']
                else:
                    assert worker['outcome'] in ('cancelled', 'completed-after-cancel')
            assert sum(w['scenario'] == 'normal' for w in r['workers']) == 6
            assert sum(w['scenario'] == 'burst' for w in r['workers']) == 1

            for w in r['workers']:
                assert w['finishedUptimeSeconds'] >= w['startedUptimeSeconds']
                if mode == 'native-ui-isolated':
                    assert 'process' in w
                    process(w['process'], '5k', prepared['rawSHA256'], child_pids, allow_cancel=True)
                else: assert 'process' not in w
                if w['outcome'] in ('completed', 'completed-after-cancel'): assert w['pixelsSHA256'] == prepared['rawSHA256']
            assert r['helperInvocations'] == sum(w.get('process', {}).get('childLaunched', False) for w in r['workers'])
            assert r['highDPIBackingObserved'] == (r['backingScaleFactor'] >= 2)
            summaries.append({'profile': '5k', 'mode': mode, 'medianRequestToNativeDrawSeconds': statistics.median(c['requestToNativeDrawSeconds'] for c in r['cycles']),
                'maximumMainQueueDelaySeconds': r['mainQueue']['maximumDelaySeconds'], 'responsivenessFlagTriggered': r['responsivenessFlagTriggered'],
                'highDPIBackingObserved': r['highDPIBackingObserved'],
                'allRequestedCancellationRacesObserved': r['allRequestedCancellationRacesObserved']})
    assert not parent_pids.intersection(child_pids)
    coverage = None if headless_only else {
        'allCancellationRacesObserved': all(c['allRequestedCancellationRacesObserved'] for c in summaries if c['mode'].startswith('native-ui')),
        'highDPIBackingObservedInBothUIArms': all(c['highDPIBackingObserved'] for c in summaries if c['mode'].startswith('native-ui')),
        'responsivenessFlagTriggered': any(c['responsivenessFlagTriggered'] for c in summaries if c['mode'].startswith('native-ui')),
    }
    return {'status': 'observed', 'sourceCommit': source, 'architecture': architecture, 'headlessOnly': headless_only,
        'cells': summaries, 'coverage': coverage, 'parentLossVerified': False, 'interpretation': 'Exact bounded previews and native diagnostic UI observations only; no production remedy verdict'}


def base(r, source, architecture, profile, prepared, pids):
    assert r['protocol'] == 'image-decode-large-parent-v2' and r['status'] == 'observed'
    assert r['sourceCommit'] == source and r['architecture'] == architecture and r['profile'] == profile
    assert r['processIdentifier'] not in pids; pids.add(r['processIdentifier'])
    assert r['inputPreparationProcessIdentifier'] == prepared['processIdentifier']
    assert r['pngSHA256'] == prepared['pngSHA256'] and r['rawSHA256'] == prepared['rawSHA256']
    assert (r['sourceWidth'], r['sourceHeight']) == (prepared['sourceWidth'], prepared['sourceHeight'])
    assert (r['previewWidth'], r['previewHeight'], r['rasterBytes']) == (1024, 576, 2359296)
    assert r['maximumPreviewBytes'] == 4194304 and r['maximumPreviewDimension'] == 1024 and r['pixelTolerance'] == 0
    assert not r['parentLossVerified'] and not r['screenCaptureAttempted'] and not r['networkAttempted'] and r['allocatorReliefCalls'] == 0
    assert r['ownedJobsRemaining'] == 0
    for key in ('providerLifetime', 'destinationLifetime'):
        if key in r:
            owned = r[key]
            assert owned['callbackSizesMatch'] and 0 <= owned['deallocations'] <= owned['allocations']
            assert 0 <= owned['releaseCallbacks'] <= owned['allocations']
            assert owned['activeBytes'] == (owned['allocations']-owned['deallocations'])*2359296
    assert r['parentPeaks']['residentBytes'] <= 536870912 and r['parentPeaks']['footprintBytes'] <= 536870912


if __name__ == '__main__':
    if len(sys.argv) not in (4, 5): raise SystemExit('Usage: check-image-decode-large-report.py ROOT SOURCE ARCH [--headless-only]')
    headless = len(sys.argv) == 5
    if headless and sys.argv[4] != '--headless-only': raise SystemExit('Unknown mode')
    root = Path(sys.argv[1]); result = validate(root, sys.argv[2], sys.argv[3], headless)
    (root/('headless-comparison.json' if headless else 'comparison.json')).write_text(json.dumps(result, indent=2, sort_keys=True)+'\n')
    print(json.dumps(result, indent=2, sort_keys=True))
