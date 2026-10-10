#!/usr/bin/env python3
"""Predeclared bounded comparison. Missing observations never become zero."""
import argparse
import json
import math
from pathlib import Path
import statistics

MIB = 1024 * 1024
MARGIN = 2 * MIB
PROTOCOL = 'codec-staging-comparison-v1'
CRITERIA = {
    'endpoint': 'last settled cycle minus backingBaselineAfterWarmup; never substitute half-second tail',
    'controlMinimumVolatileGrowthBytes': 16 * MIB,
    'minimumVolatileReductionBytes': 16.2 * MIB,
    'maximumCandidateVolatileGrowthBytes': 4.05 * MIB,
    'maximumCandidateLastThreeSignedVolatileGrowthBytes': 1.0125 * MIB,
    'minimumRSSReductionBytes': 12 * MIB,
    'independentMemoryRegressionMarginBytes': MARGIN,
    'quantiles': 'warm p50 is median; p95 is nearest-rank ceil(0.95*n), therefore max for 12 samples',
    'coldDefinition': 'first export/native draw of a fresh app process; no claim of cold OS/filesystem caches or WindowServer presentation',
    'latencyMaximumIncrease': 'max(control * 0.10, 0.050 seconds), independently for cold first, warm p50 and warm p95',
    'interpretation': '2 MiB is a conservative acceptance margin, not established native noise or a causal regression threshold. Both AB/BA pairs must pass; missing evidence, nonreproducing control or disagreeing/order-sensitive failures are inconclusive. Consistent excess rejects this candidate claim, not a global cause.',
}

class EvidenceError(ValueError):
    pass

def need(condition, message):
    if not condition:
        raise EvidenceError(message)

def integer(n, minimum=0):
    return isinstance(n, int) and not isinstance(n, bool) and n >= minimum

def positive(n):
    return isinstance(n, (int, float)) and not isinstance(n, bool) and math.isfinite(n) and n > 0

def shape(r):
    expected = 12 if r['profile'] == 'installed-768x576' else 3
    need(r['warmupCycles'] == 2 and r['measuredCycles'] == expected and integer(r['warmupCycles']) and integer(r['measuredCycles']), 'fixed profile counts differ')
    for label, count, warm in [('warmups', 2, True), ('cycles', expected, False)]:
        need(isinstance(r[label], list) and len(r[label]) == count, 'fixed array length differs')
        need(all(integer(c['index'], 1) and c['index'] == i and c['isWarmup'] is warm for i, c in enumerate(r[label], 1)), 'cycle indices/warmup flags differ')

def load(path):
    need(path.is_file() and path.stat().st_size <= 4 * MIB, f'missing/oversized report: {path}')
    return json.loads(path.read_text())

def identity(root):
    expected=load(root/'identity.json')
    for key in ['mainExecutableSHA256', 'helperExecutableSHA256', 'infoPlistSHA256']:
        value=expected[key]
        need(isinstance(value,str) and len(value)==64 and all(c in '0123456789abcdef' for c in value), f'invalid preflight {key}')
    source=expected['sourceCommit']
    need(isinstance(source,str) and len(source)==40 and all(c in '0123456789abcdef' for c in source), 'invalid preflight source commit')
    bundle=expected['bundlePath']
    need(isinstance(bundle,str) and bundle.startswith('/') and bundle.endswith('.app') and
         expected['mainExecutablePath']==bundle+'/Contents/MacOS/PicShot' and
         expected['helperExecutablePath']==bundle+'/Contents/Helpers/PicShotCodecHelper', 'invalid preflight executable paths')
    return expected

def identity_recheck(root, phase):
    expected=identity(root)
    for position in ['before', 'after']:
        report=load(root/f'identity-{phase}-{position}.json')
        need(report['phase']==phase and report['position']==position and report['outsideMeasuredParents'] is True and
             report['matchesPreflight'] is True and report['identity']==expected, f'{phase}: executable identity recheck failed')
    return expected

def cell(root, name):
    r = load(root / name / 'codec-staging.json')
    lifecycle = load(root / name / 'launch.json.launcher.json')
    expected=identity(root)
    for report_key, identity_key in [('bundlePath','bundlePath'),('sourceCommit','sourceCommit'),('helperVerifiedPath','helperExecutablePath'),('helperVerifiedSHA256','helperExecutableSHA256')]:
        need(r[report_key]==expected[identity_key], f'{name}: preflight {identity_key} differs')
    need(lifecycle['launchedExecutablePath']==expected['mainExecutablePath'], f'{name}: launched main executable differs')
    need(r['protocol'] == PROTOCOL and r['status'] in ('observed', 'preserved', 'validated', 'passed'), f'{name}: unsuccessful report')
    need(lifecycle['status'] == 'exited' and lifecycle['launcherExitCode'] == 0 and lifecycle['ownedExitConfirmed'] and lifecycle['launchedIdentityMatches'], f'{name}: app exit/identity not confirmed')
    need(integer(r['processIdentifier'], 1) and integer(lifecycle['processIdentifier'], 1) and lifecycle['processIdentifier'] == r['processIdentifier'], f'{name}: launched PID differs')
    need(lifecycle['launchedAppPath'] == r['bundlePath'], f'{name}: bundle mismatch')
    need(r['helperIdentityCheckedBeforeMeasurement'] and len(r['helperVerifiedSHA256']) == 64, f'{name}: helper not verified')
    expected_mode = 'legacyPreview' if r['arm'] == 'control' else 'verifiedBytesOnly'
    need(r['pngStagingMode'] == expected_mode, f'{name}: declared staging mode differs')
    if 'cycles' in r:
        shape(r)
    for c in r.get('warmups', []) + r.get('cycles', []):
        h = c['helper']
        need(h['outcome'] == 'succeeded' and h['childExitConfirmed'] is True and h['temporaryDirectoryRemoved'] is True and integer(h['terminationStatus']) and h['terminationStatus'] == 0, f'{name}: helper did not succeed/exit/clean')
        need(integer(h['childProcessIdentifier'], 1) and h['helperExecutablePath'] == r['helperVerifiedPath'], f'{name}: helper PID/path missing')
        need(h['pngStagingMode'] == expected_mode and len(h['sourceSHA256']) == 64, f'{name}: actual staging route/bytes differ')
        need(all(integer(h[k], 1) for k in ['parentResidentSampleCount', 'parentPhysicalFootprintSampleCount', 'childReportedResidentSampleCount', 'childReportedPhysicalFootprintSampleCount']), f'{name}: required helper memory unavailable')
        need(integer(c['memory']['timerTickCount'], 1) and integer(c['memory']['backingSampleCount'], 1), f'{name}: sampling missing')
        if r['comparisonMode'] == 'controller':
            need(c['controllerReleased'] and c['helperInactive'] and c['draw']['windowVisible'], f'{name}: native controller not drawn/released')
            need(positive(c['firstNativeDrawUptimeSeconds']) and positive(c['requestUptimeSeconds']) and c['firstNativeDrawUptimeSeconds'] >= c['requestUptimeSeconds'], f'{name}: stale draw')
            need(c['draw']['imageIdentity'] == c['currentImageIdentity'] and bool(c['currentImageIdentity']), f'{name}: wrong draw image')
            for field in ['bounds', 'displayedRect', 'backingRect']:
                rect=c['draw'][field]
                need(len(rect)==4 and all(isinstance(n,(int,float)) and not isinstance(n,bool) and math.isfinite(n) for n in rect) and rect[2]>0 and rect[3]>0, f'{name}: empty/invalid draw rect')
            need(positive(c['draw']['backingScale']), f'{name}: invalid backing scale')
            if c['action'] == 'save':
                need(c['sameByteSave'], f'{name}: save mismatch')
        else:
            need(c['payloadReleased'] and not c['helperActive'] and c['ownedTemporaryFiles'] == 0 and c['fixtureEncodingTasksActive'] == 0 and c['sameByteSave'], f'{name}: pending work/output')
            need(c['sourceSHA256'] and not any(b['name'] == 'afterSourceRasterDigest' for b in c['boundaries']), f'{name}: extra source raster contaminated measured cell')
    if 'cycles' in r:
        child_ids=[c['helper']['childProcessIdentifier'] for c in r['warmups']+r['cycles']]
        need(len(set(child_ids))==len(child_ids), f'{name}: helper launch PID reused')
    return r

def value(reading, metric):
    scope, kind, key = {
        'rss': ('standard', 'bytes', 'resident_size'),
        'footprint': ('standard', 'bytes', 'phys_footprint'),
        'volatile': ('purgeable', 'bytes', 'purgeable_volatile_resident'),
        'volatileLedger': ('purgeable', 'ledgerBytes', 'ledger_purgeable_volatile'),
        'kernelRSSPeak': ('standard', 'bytes', 'resident_size_peak'),
        'kernelFootprintPeak': ('standard', 'ledgerBytes', 'ledger_phys_footprint_peak'),
    }[metric]
    need(reading[scope]['kernelReturn'] == 0, f'{metric}: Mach query failed')
    n = reading[scope][kind].get(key)
    need(isinstance(n, int) and not isinstance(n, bool), f'{metric}: required observation unavailable')
    return n

def settled(r, c):
    if r['comparisonMode'] == 'controller':
        return c['backingSettled']
    return next(b['backing'] for b in c['boundaries'] if b['name'] == 'afterMainQueueDrainAndSettling')

def summarize(r):
    shape(r)
    baseline, cold = r['backingBaselineAfterWarmup'], r['backingBeforeWarmup']
    ends = [settled(r, c) for c in r['cycles']]
    output = {'metrics': {}, 'sourceSHA256': r['cycles'][0]['sourceSHA256']}
    for metric in ['rss', 'footprint', 'volatile', 'volatileLedger']:
        b = value(baseline, metric); values = [value(e, metric) for e in ends]
        previous = [b] + values[:-1]
        intervals = [x - y for x, y in zip(values, previous)]
        output['metrics'][metric] = dict(cold=value(cold, metric), entry=value(r['diagnosticEntryBacking'], metric),
            baseline=b, final=values[-1], coldToWarm=b-value(cold, metric), growth=values[-1]-b,
            intervals=intervals, lastThreeSignedSum=sum(intervals[-3:]),
            halfSecond=value(r['backingHalfSecondAfterFinalCycle'], metric))
    peaks = r['wholeRunSampledMemory']
    output['sampledPeaks'] = {metric: peaks[key] for metric, key in [
        ('rss', 'peakResidentBytes'), ('footprint', 'peakPhysicalFootprintBytes'),
        ('volatile', 'peakVolatileResidentBytes'), ('volatileLedger', 'peakVolatileLedgerBytes')]}
    need(all(integer(n) for n in output['sampledPeaks'].values()), 'required sampled peak missing/noninteger')
    output['kernelPeaks'] = {key: value(r['backingHalfSecondAfterFinalCycle'], key) for key in ['kernelRSSPeak', 'kernelFootprintPeak']}
    latency_key = 'requestToNativeDrawSeconds' if r['comparisonMode'] == 'controller' else 'exportSeconds'
    times = [c[latency_key] for c in r['cycles']]
    need(all(positive(n) for n in times) and positive(r['warmups'][0][latency_key]), 'latency missing/nonfinite/nonpositive')
    output['latency'] = {'metric': latency_key, 'coldFirst': r['warmups'][0][latency_key],
        'warmP50': statistics.median(times), 'warmP95': sorted(times)[math.ceil(.95*len(times))-1], 'warmValues': times}
    return output

def compare(control, candidate, benefit):
    shape(control); shape(candidate)
    if benefit:
        need(control['comparisonMode'] == 'export-only' and control['format'] == 'webp' and control['profile'] == 'installed-768x576', 'benefit must use small WebP export-only')
    for key in ['sourceCommit', 'bundlePath', 'helperVerifiedPath', 'helperVerifiedSHA256', 'profile', 'format', 'comparisonMode', 'sourceWidth', 'sourceHeight', 'warmupCycles', 'measuredCycles']:
        need(control[key] == candidate[key], f'matched pair differs: {key}')
    need(control['arm'] == 'control' and candidate['arm'] == 'candidate' and control['processIdentifier'] != candidate['processIdentifier'], 'fresh matched arms required')
    for a, b in zip(control['warmups'] + control['cycles'], candidate['warmups'] + candidate['cycles']):
        need(a['sourceSHA256'] == b['sourceSHA256'] and a['encodedSHA256'] == b['encodedSHA256'] and a['helper']['sourceSHA256'] == b['helper']['sourceSHA256'], 'matched source/staged/final bytes differ')
    a, b = summarize(control), summarize(candidate)
    failures = []
    def gate(name, ok):
        if not ok:
            failures.append(name)
    for metric in a['metrics']:
        for field in ['entry', 'cold', 'coldToWarm', 'growth', 'lastThreeSignedSum']:
            gate(f'{metric}.{field}', b['metrics'][metric][field] <= a['metrics'][metric][field] + MARGIN)
        gate(f'{metric}.sampledPeak', b['sampledPeaks'][metric] <= a['sampledPeaks'][metric] + MARGIN)
        gate(f'{metric}.sampledPeakAboveCold', b['sampledPeaks'][metric]-b['metrics'][metric]['cold'] <= a['sampledPeaks'][metric]-a['metrics'][metric]['cold']+MARGIN)
    for metric in a['kernelPeaks']:
        gate(metric, b['kernelPeaks'][metric] <= a['kernelPeaks'][metric] + MARGIN)
    for key in ['coldFirst', 'warmP50', 'warmP95']:
        gate(f'latency.{key}', b['latency'][key] <= a['latency'][key] + max(.1*a['latency'][key], .05))
    reproduces = not benefit or a['metrics']['volatile']['growth'] >= CRITERIA['controlMinimumVolatileGrowthBytes']
    if benefit:
        gate('volatile.reduction', a['metrics']['volatile']['growth']-b['metrics']['volatile']['growth'] >= CRITERIA['minimumVolatileReductionBytes'])
        gate('volatile.remaining', b['metrics']['volatile']['growth'] <= CRITERIA['maximumCandidateVolatileGrowthBytes'])
        gate('volatile.lastThreeSignedSumBenefit', b['metrics']['volatile']['lastThreeSignedSum'] <= CRITERIA['maximumCandidateLastThreeSignedVolatileGrowthBytes'])
        gate('rss.reduction', a['metrics']['rss']['growth']-b['metrics']['rss']['growth'] >= CRITERIA['minimumRSSReductionBytes'])
    return {'control': a, 'candidate': b, 'controlReproduces': reproduces, 'failedIndependentGates': failures,
        'passes': reproduces and not failures}

def paired_result(pairs):
    if all(p['passes'] for p in pairs):
        return 'passes-predeclared-gates'
    if not all(p['controlReproduces'] for p in pairs):
        return 'inconclusive-control-did-not-reproduce'
    if len(pairs) > 1 and set.intersection(*(set(p['failedIndependentGates']) for p in pairs)):
        return 'reject-consistent-gate-excess'
    return 'inconclusive-noise-or-order-sensitive'

def evidence_checks(root, profile):
    reports = [cell(root, f'evidence-{profile}-{arm}') for arm in ('control', 'candidate')]
    checks = [cell(root, f'validate-{profile}-{arm}') for arm in ('control', 'candidate')]
    for report, check in zip(reports, checks):
        need(check['status'] == 'validated' and check['producerPID'] == report['processIdentifier'], 'validation did not use preserved evidence')
        need(all(e['allPixelsAndAlphaCompared'] and e['previewCompared'] and e['stagedCompared'] for e in check['entries']), 'pixel validation missing')
    need(reports[0]['sourceSHA256'] == reports[1]['sourceSHA256'], 'evidence source differs')
    for a, b in zip(reports[0]['entries'], reports[1]['entries']):
        need(a['format'] == b['format'] and a['stagedSHA256'] == b['stagedSHA256'] and a['finalSHA256'] == b['finalSHA256'] and a['previewSHA256'] == b['previewSHA256'], 'actual stage/final/preview files differ')
    for directory in root.iterdir():
        if not directory.is_dir() or not (directory / 'codec-staging.json').exists():
            continue
        r = load(directory / 'codec-staging.json')
        if not r.get('cycles') or r['comparisonMode'] not in ('export-only', 'controller', 'combined'):
            continue
        if (r['sourceWidth'] == 2048) != (profile == 'large'):
            continue
        specimen = reports[0 if r['arm'] == 'control' else 1]
        entry = next(e for e in specimen['entries'] if e['format'] == r['format'])
        for c in r['warmups'] + r['cycles']:
            need(c['sourceSHA256'] == specimen['sourceSHA256'] and c['helper']['sourceSHA256'] == entry['stagedSHA256'] and c['encodedSHA256'] == entry['finalSHA256'], 'measured bytes not bound to independently validated actual files')
    return {'profile': profile, 'status': 'passed', 'actualStagedFinalPreviewBytesMatch': True, 'allMeasuredDigestsBound': True}

def run(root, phase):
    expected_identity=identity_recheck(root,phase)
    result = {'protocol': PROTOCOL, 'phase': phase, 'predeclaredCriteria': CRITERIA,
        'signedExecutableIdentity': expected_identity, 'binaryIdentityRecheckedOutsideMeasuredParents': True}
    if phase == 'export':
        pairs = [compare(cell(root, f'export-{repeat}-control'), cell(root, f'export-{repeat}-candidate'), True) for repeat in ['ab', 'ba']]
        result.update(pairs=pairs, verdict=paired_result(pairs), promotionReady=False)
    elif phase == 'product':
        pairs = [compare(cell(root, f'controller-{repeat}-control'), cell(root, f'controller-{repeat}-candidate'), False) for repeat in ['ab', 'ba']]
        result['controllerPairs'] = pairs
        result['controllerVerdict'] = paired_result(pairs)
        result['boundedChecks'] = {name: compare(cell(root, name+'-control'), cell(root, name+'-candidate'), False) for name in ['large-export', 'large-controller', 'avif-export', 'combined']}
        result['combinedScope'] = 'Corroboration only; parent independent ImageIO decode/full raster remains. Cannot qualify export-only benefit.'
        result['verdict'] = 'passes-predeclared-gates' if all(p['passes'] for p in pairs) and all(v['passes'] for k, v in result['boundedChecks'].items() if k != 'combined') else 'inconclusive-or-reject-review-independent-gates'
    elif phase == 'fidelity':
        result['evidence'] = [evidence_checks(root, p) for p in ('small', 'large')]
        for arm in ('control', 'candidate'):
            r = cell(root, 'interruptions-'+arm)
            need(r['status'] == 'passed' and r['closeDuringHelper']['lateResultSuppressed'] and r['closeDuringHelper']['controllerReleased'], 'interruption checks incomplete')
            need(len(r['formats']) == 2 and all(f['inFlightFormatQualityChange'] and f['realPixelsAndAlphaVerified'] and f['sameByteSave'] for f in r['formats']), 'WebP/AVIF UI fidelity incomplete')
        result['verdict'] = 'passed'
    else:
        summaries = {p: load(root / (p+'-summary.json')) for p in ['export', 'product', 'fidelity']}
        result['phases'] = {p: r['verdict'] for p, r in summaries.items()}
        result['promotionReady'] = all(r['verdict'] in ['passes-predeclared-gates', 'passed'] for r in summaries.values())
        result['verdict'] = 'bounded-candidate-gates-pass' if result['promotionReady'] else 'not-promotable'
    # Fresh process evidence includes all cells, even validation and preparation.
    pids = [load(p)['processIdentifier'] for p in root.glob('*/codec-staging.json')]
    need(len(set(pids)) == len(pids), 'cell PID reuse requires launch/start identity review')
    return result

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('root', type=Path); parser.add_argument('--phase', choices=['export', 'product', 'fidelity', 'summary'], required=True)
    args = parser.parse_args()
    try:
        output = run(args.root, args.phase)
    except (EvidenceError, KeyError, StopIteration, TypeError) as e:
        output = {'phase': args.phase, 'verdict': 'inconclusive-invalid-or-missing-evidence', 'error': str(e), 'promotionReady': False}
    destination = args.root / (args.phase + '-summary.json')
    destination.write_text(json.dumps(output, indent=2, sort_keys=True)+'\n')
    print(json.dumps({'report': str(destination), 'verdict': output['verdict']}))
    raise SystemExit(2 if 'error' in output else 0 if output['verdict'] in ('passes-predeclared-gates', 'passed', 'bounded-candidate-gates-pass') else 3)
