#!/usr/bin/env python3
"""Validate the explicit four-cell diagnostic, preserving all raw measurements."""
import json
import math
from pathlib import Path
import statistics
import sys


def read(path, limit=2_097_152):
    assert path.stat().st_size <= limit
    return json.loads(path.read_text())


def memory(sample):
    assert sample['standard']['kernelReturn'] == sample['purgeable']['kernelReturn'] == 0
    assert sample['standard']['bytes']['resident_size'] > 0
    assert sample['standard']['bytes']['phys_footprint'] > 0
    for key in ('purgeable_volatile_resident', 'purgeable_volatile_virtual', 'purgeable_volatile_pmap'):
        assert key in sample['purgeable']['bytes']


def process(m, expected, child_pids, expected_raw_sha):
    assert m['outcome'] == expected
    assert m['childLaunched'] and m['exitConfirmed'] and m['cleanupConfirmed'] and m['admissionReleased']
    assert m['childPID'] not in child_pids
    child_pids.add(m['childPID'])
    assert m['stdoutBytes'] <= 131072 and m['stderrBytes'] <= 8192 and not m['stderrTruncated']
    assert len(m['phases']) <= 12
    assert not Path(m['jobDirectory']).exists()
    assert m['terminationReason'] == 'exit'
    assert m['launchThroughExitSeconds'] < 9
    t = m['terminal']
    assert t['schema'] == 'image-decode-helper-v1' and t['childPID'] == m['childPID']
    assert t['peaks']['residentSamples'] > 0 and t['peaks']['footprintSamples'] > 0
    assert 0 < t['peaks']['residentBytes'] <= 268435456
    assert 0 < t['peaks']['footprintBytes'] <= 268435456
    phases = []
    for pair in m['phases']:
        e = pair['child']; phases.append(e['phase'])
        assert e['childPID'] == m['childPID']
        memory(pair['parentAtReceipt'])
        if 'memory' in e: memory(e['memory'])
        assert math.isfinite(pair['receiptSkewSeconds']) and pair['receiptSkewSeconds'] >= 0
    for key in ('beforePNGRead', 'imageCreated', 'rasterDrawn', 'afterContextRelease'):
        assert phases.count(key) == 1
    if expected == 'decoded':
        assert m['terminationStatus'] == 0 and t['kind'] == 'result'
        assert t['rawBytes'] == 1769472 and m['outputExistedBeforeCleanup']
        assert not m['sawPostDecodeReady'] and not m['cancelRequested']
        assert phases.count('outputClosed') == phases.count('afterDecodePool') == 1
    else:
        assert m['terminationStatus'] == 1 and t['kind'] == 'error'
        assert m['sawPostDecodeReady'] and not m['outputExistedBeforeCleanup']
        assert phases.count('heldAfterDecode') == 1
        ready = next(p['child'] for p in m['phases'] if p['child']['phase'] == 'heldAfterDecode')
        assert ready['rawBytes'] == 1769472 and ready['rawSHA256'] == expected_raw_sha
        if expected == 'cancelled-after-decode':
            assert m['cancelRequested'] and m['cancelWriteReturn'] == len(b'cancel\n')
            assert t['error'] == 'cancelled'
        else: assert t['error'] in ('deadline', 'cancelled')


def validate(root, source, architecture):
    prepared = read(root/'prepared/image-draw-inputs.json')
    assert prepared['status'] == 'prepared' and prepared['sourceCommit'] == source and prepared['architecture'] == architecture
    parent_pids = {prepared['processIdentifier']}; child_pids = set(); arms = []
    modes = ('production-control', 'isolated-decode', 'cancel-after-decode', 'timeout-after-decode')
    for mode in modes:
        r = read(root/mode/f'image-decode-helper-{mode}.json')
        assert r['status'] == 'observed' and r['protocol'] == 'image-decode-helper-parent-v1' and r['mode'] == mode
        assert r['sourceCommit'] == source and r['architecture'] == architecture
        assert r['processIdentifier'] not in parent_pids; parent_pids.add(r['processIdentifier'])
        assert r['inputPreparationProcessIdentifier'] == prepared['processIdentifier']
        assert r['sourceWidth'] == 768 and r['sourceHeight'] == 576 and r['rasterBytes'] == 1769472 and r['pixelTolerance'] == 0
        assert r['immutablePNGSHA256'] == prepared['pngSHA256'] and r['immutableRawSHA256'] == prepared['rawSHA256']
        assert not r['captureStarted'] and not r['networkAttempted'] and r['allocatorReliefCalls'] == 0
        assert r['immutableInputsUnchanged'] and r['ownedJobDirectoriesRemaining'] == 0 and r['retainedCycleImages'] == 0
        assert r['childWorkDeadlineSeconds'] == 5 and r['childHardDeadlineSeconds'] == 6 and r['childExitDeadlineSeconds'] == 9
        assert r['armDeadlineSeconds'] == 180 and r['requiredOuterDeadlineSeconds'] == 200 and r['elapsedSeconds'] <= 180
        for key in ('beforeDestinationPreparation', 'afterDestinationPreparation', 'halfSecondAfterFinalCycleDestinationLive', 'afterDestinationOwnerDropped', 'halfSecondAfterDestinationOwnerDropped'): memory(r[key])
        measured = mode in modes[:2]
        assert r['oneShotProbe'] != measured
        if measured:
            assert r['warmupCycles'] == 2 and r['measuredCycles'] == 12
            assert len(r['warmups']) == 2 and len(r['cycles']) == 12
            assert r['completedDraws'] == r['completedFullPixelValidations'] == 14
            assert r['destinationLifetime']['allocations'] == 1
            memory(r['baselineAfterWarmup'])
            for group, warm in [('warmups', True), ('cycles', False)]:
                for index, c in enumerate(r[group], 1):
                    assert c['index'] == index and c['isWarmup'] == warm
                    for key in ('before', 'beforeParentDraw', 'afterPool', 'settled'): memory(c[key])
                    w = c['draw']; memory(w['beforeDrawImageLive']); memory(w['afterDrawAndReadbackImageLive'])
                    assert w['actualDrawCount'] == 1 and w['validatedRGBABytes'] == 1769472 and w['maximumAbsoluteChannelDifference'] == 0
                    assert w['pixelsSHA256'] == prepared['rawSHA256']
                    assert 0 < c['timeToValidatedPixelsSeconds'] <= c['fullLifecycleSeconds'] <= c['observedCycleSeconds']
                    if mode == 'isolated-decode':
                        process(c['process'], 'decoded', child_pids, prepared['rawSHA256'])
                        assert c['process']['terminal']['rawSHA256'] == prepared['rawSHA256']
                        assert c['rawProviderLifetime']['allocations'] == index + (0 if warm else 2)
                    else: assert 'process' not in c and 'rawProviderLifetime' not in c
            if mode == 'isolated-decode':
                p = r['rawProviderLifetime']; assert p['allocations'] == 14 and p['callbackSizesMatch']
                assert 0 <= p['releaseCallbacks'] <= 14 and 0 <= p['deallocations'] <= 14
                assert p['activeBytes'] == (14-p['deallocations'])*1769472
            base, end = r['baselineAfterWarmup'], r['cycles'][-1]['settled']
            arms.append({'mode': mode, 'medianFullLifecycleSeconds': statistics.median(c['fullLifecycleSeconds'] for c in r['cycles']),
                'medianTimeToValidatedPixelsSeconds': statistics.median(c['timeToValidatedPixelsSeconds'] for c in r['cycles']),
                'parentRSSDeltaBytes': end['standard']['bytes']['resident_size']-base['standard']['bytes']['resident_size'],
                'parentFootprintDeltaBytes': end['standard']['bytes']['phys_footprint']-base['standard']['bytes']['phys_footprint'],
                'parentVolatileResidentDeltaBytes': end['purgeable']['bytes']['purgeable_volatile_resident']-base['purgeable']['bytes']['purgeable_volatile_resident'],
                'parentPeaks': r['parentSampledMemory']})
            if mode == 'isolated-decode':
                child_max = {k: max(c['process']['terminal']['peaks'][k] for c in r['warmups']+r['cycles']) for k in ('residentBytes', 'footprintBytes')}
                pairs = [p for c in r['warmups']+r['cycles'] for p in c['process']['phases'] if p['childObservedRunning'] and 'memory' in p['child']]
                arms[-1]['maxIndividualChildPeaks'] = child_max
                arms[-1]['sampledIndependentPeakEnvelope'] = {k: r['parentSampledMemory'][k]+child_max[k] for k in child_max}
                arms[-1]['envelopeScope'] = 'Sum of separately sampled process maxima; not simultaneous, not a hard upper bound, and may double-count shared physical pages'
                if pairs:
                    arms[-1]['maximumReceiptPairRSSSumBytes'] = max(p['parentAtReceipt']['standard']['bytes']['resident_size']+p['child']['memory']['standard']['bytes']['resident_size'] for p in pairs)
                    arms[-1]['maximumReceiptPairFootprintSumBytes'] = max(p['parentAtReceipt']['standard']['bytes']['phys_footprint']+p['child']['memory']['standard']['bytes']['phys_footprint'] for p in pairs)
                    arms[-1]['receiptPairMaximumSkewSeconds'] = max(p['receiptSkewSeconds'] for p in pairs)
                    arms[-1]['receiptPairScope'] = 'Child event sample paired with later parent receipt while child was observed live; non-atomic and not a lifetime peak'
        else:
            assert r['warmupCycles'] == r['measuredCycles'] == r['completedDraws'] == 0
            assert r['completedFullPixelValidations'] == 0 and not r['cycles'] and not r['warmups']
            assert r['probeDecodedRGBAMatchesReference']
            process(r['probe'], 'cancelled-after-decode' if mode == modes[2] else 'deadline-after-decode', child_pids, prepared['rawSHA256'])
        assert r['helperInvocations'] == (0 if mode == modes[0] else 14 if mode == modes[1] else 1)
        assert r['maximumObservedChildConcurrency'] == (0 if mode == modes[0] else 1)
    assert len(parent_pids) == 5 and len(child_pids) == 16 and not parent_pids.intersection(child_pids)
    return {'status': 'observed', 'sourceCommit': source, 'architecture': architecture, 'arms': arms,
        'interpretation': 'Sequential signed-child decode plus actual parent drawing; process-specific accounting and full lifecycle costs only, no production remedy verdict'}


if __name__ == '__main__':
    if len(sys.argv) != 4: raise SystemExit('Usage: check-image-decode-helper-report.py ROOT SOURCE ARCHITECTURE')
    root = Path(sys.argv[1]); result = validate(root, sys.argv[2], sys.argv[3])
    (root/'comparison.json').write_text(json.dumps(result, indent=2, sort_keys=True)+'\n')
    print(json.dumps(result, indent=2, sort_keys=True))
