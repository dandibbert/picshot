#!/usr/bin/env python3
"""Predeclared bounded comparison. Missing observations never become zero."""
import argparse
import hashlib
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

def specimen(path, expected_hash, expected_bytes, maximum):
    need(isinstance(expected_hash,str) and len(expected_hash)==64 and all(c in '0123456789abcdef' for c in expected_hash), 'invalid specimen digest')
    need(integer(expected_bytes,1) and expected_bytes<=maximum and path.is_file() and not path.is_symlink() and path.stat().st_size==expected_bytes, 'missing/oversized/changed specimen')
    digest=hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda:stream.read(MIB),b''):digest.update(block)
    need(digest.hexdigest()==expected_hash, 'actual specimen bytes differ from validated digest')

def evidence_checks(root, profile, bind_measured=True):
    reports = [cell(root, f'evidence-{profile}-{arm}') for arm in ('control', 'candidate')]
    checks = [cell(root, f'validate-{profile}-{arm}') for arm in ('control', 'candidate')]
    width,height=(2048,1536) if profile=='large' else (768,576)
    for arm,report,check in zip(('control','candidate'),reports,checks):
        need(report['status']=='preserved' and report['comparisonMode']=='evidence' and check['comparisonMode']=='validate' and
             report['arm']==check['arm']==arm and report['sourceWidth']==check['sourceWidth']==width and report['sourceHeight']==check['sourceHeight']==height,
             'wrong producer/validator cell or source dimensions')
        need([e['format'] for e in report['entries']]==['webp','avif'] and [e['format'] for e in check['entries']]==['webp','avif'], 'exactly two format evidence entries required')
        directory=root/f'evidence-{profile}-{arm}'
        specimen(directory/'source.rgba',report['sourceSHA256'],width*height*4,width*height*4)
        for entry,validated in zip(report['entries'],check['entries']):
            fmt=entry['format'];pw,ph=entry['previewWidth'],entry['previewHeight']
            need(integer(pw,1) and integer(ph,1) and any((pw,ph)==(max(1,round(width*min(1,limit/max(width,height)))),max(1,round(height*min(1,limit/max(width,height))))) for limit in (1024,1000)), 'preview geometry exceeds native plans')
            need(validated['previewWidth']==pw and validated['previewHeight']==ph and validated['decodedBytes']==width*height*4 and
                 validated['previewValidatedBytes']==pw*ph*4 and validated['finalSHA256']==entry['finalSHA256'] and validated['stagedSHA256']==entry['stagedSHA256'], 'validator geometry/byte/digest binding differs')
            specimen(directory/f'actual-staged-{fmt}.png',entry['stagedSHA256'],entry['stagedBytes'],80_000_000)
            specimen(directory/f'actual-final.{fmt}',entry['finalSHA256'],entry['finalBytes'],134_217_728)
            need(entry['previewBytes']==pw*ph*4, 'actual preview raster byte count differs')
            specimen(directory/f'actual-preview-{fmt}.rgba',entry['previewSHA256'],entry['previewBytes'],4_194_304)
            helper=entry['helper']
            need(helper['outcome']=='succeeded' and integer(helper['terminationStatus']) and helper['terminationStatus']==0 and helper['childExitConfirmed'] is True and helper['temporaryDirectoryRemoved'] is True and
                 integer(helper['childProcessIdentifier'],1) and helper['helperExecutablePath']==report['helperVerifiedPath'] and
                 helper['pngStagingMode']==report['pngStagingMode'] and helper['sourceSHA256']==entry['stagedSHA256'], 'actual producer helper route/exit/staging identity differs')
        need(check['status'] == 'validated' and check['producerPID'] == report['processIdentifier'], 'validation did not use preserved evidence')
        need(check['independentValidationProcess'] is True and check['helperLaunches']==0 and all(e['allPixelsAndAlphaCompared'] is True and e['previewCompared'] is True and e['stagedCompared'] is True for e in check['entries']), 'pixel validation missing')
    need(reports[0]['sourceSHA256'] == reports[1]['sourceSHA256'], 'evidence source differs')
    for a, b in zip(reports[0]['entries'], reports[1]['entries']):
        need(a['format'] == b['format'] and a['stagedSHA256'] == b['stagedSHA256'] and a['finalSHA256'] == b['finalSHA256'] and a['previewSHA256'] == b['previewSHA256'], 'actual stage/final/preview files differ')
    matched=0
    for directory in root.iterdir():
        if not directory.is_dir() or not (directory / 'codec-staging.json').exists():
            continue
        r = load(directory / 'codec-staging.json')
        if not r.get('cycles') or r['comparisonMode'] not in ('export-only', 'controller', 'combined'):
            continue
        if (r['sourceWidth'] == 2048) != (profile == 'large'):
            continue
        need(bind_measured, 'standalone fidelity must not contain measured cells')
        matched+=1
        reference = reports[0 if r['arm'] == 'control' else 1]
        entry = next(e for e in reference['entries'] if e['format'] == r['format'])
        for c in r['warmups'] + r['cycles']:
            need(c['sourceSHA256'] == reference['sourceSHA256'] and c['helper']['sourceSHA256'] == entry['stagedSHA256'] and c['encodedSHA256'] == entry['finalSHA256'], 'measured bytes not bound to independently validated actual files')
    need(not bind_measured or matched>0, 'full fidelity requires actual same-run measured cells')
    return {'profile': profile, 'status': 'passed', 'actualStagedFinalPreviewBytesMatch': True,
        'sameRunMeasuredCellBinding':bind_measured and matched>0, 'measuredCellCount':matched, 'allMeasuredDigestsBound':bind_measured and matched>0}

# Immutable bounded context from build 182; this one confirmation never erases it.
AVIF_PRIOR_FAILURE = {
    'sourceCommit': 'c625e309d39326541db1c4c4756e16fcd7e1eb6b',
    'workflowBuild': 182, 'order': ['control', 'candidate'],
    'productReportSHA256': 'b84cef481dbd6472faf31bb2482b3246d186ec4dac708447a8658d4887e2bb81',
    'terminalReceiptSHA256': 'f65e4b3b6387bc74085801e65e2afcb2c1cfcec0a95afdafa32961a37095b33f',
    'failedIndependentGates': ['latency.warmP95'],
    'controlWarmP95Seconds': 0.5350528750000194,
    'candidateWarmP95Seconds': 0.669911083333318,
    'fixedLimitSeconds': 0.5885581625000214,
    'passes': False,
}

def avif_confirmation(root):
    before,after=[load(root/('source-guard-'+position+'.json')) for position in ['before','after']]
    expected=identity(root)
    need(before==after and before['status']=='verified' and before['nativeSourceBytesUnchanged'] is True and
         before['baseCommit']==AVIF_PRIOR_FAILURE['sourceCommit'] and before['baseTree']=='009df062cd6439f967f1ce33ac6eef7dfd014f05' and
         before['headCommit']==expected['sourceCommit'] and integer(before['protectedFileCount'],1) and
         len(before['protectedFiles'])==before['protectedFileCount'], 'pinned native source guard differs or is missing')
    names=['avif-confirmation-candidate','avif-confirmation-control']
    need(sorted(p.parent.name for p in root.glob('*/codec-staging.json'))==sorted(names), 'confirmation must contain only the two intended AVIF cells')
    candidate,control=[cell(root,name) for name in names]
    for r in [candidate,control]:
        need(r['comparisonMode']=='export-only' and r['format']=='avif' and r['profile']=='staging-768x576' and
             r['sourceWidth']==768 and r['sourceHeight']==576 and r['warmupCycles']==2 and r['measuredCycles']==3,
             'confirmation profile/format/counts differ from approved AVIF pair')
    candidate_end=candidate['backingHalfSecondAfterFinalCycle']['standard']['observedAtUptimeSeconds']
    control_start=control['diagnosticEntryBacking']['standard']['observedAtUptimeSeconds']
    need(positive(candidate_end) and positive(control_start) and candidate_end<control_start, 'confirmation is not candidate then control')
    pair=compare(control,candidate,False)
    repeated=set(pair['failedIndependentGates']) & set(AVIF_PRIOR_FAILURE['failedIndependentGates'])
    return {'confirmationPair':pair,'observedOrder':['candidate','control'],'priorFailedPair':AVIF_PRIOR_FAILURE,
        'binaryProvenance':'Same-product-source rebuild; only these two new cells share the recorded new binary. No cross-build executable equality is claimed.',
        'pinnedNativeSource':{'baseCommit':before['baseCommit'],'baseTree':before['baseTree'],'protectedFileCount':before['protectedFileCount']},
        'verdict':'passes-predeclared-gates' if pair['passes'] else 'confirmation-pair-failed-independent-gates',
        'overallAVIFVerdict':'reject-consistent-gate-excess' if repeated else 'inconclusive-order-sensitive',
        'avifQualificationHold':True,'promotionReady':False,
        'scope':'Only one reversed AVIF 768x576 2+3 confirmation. A passing pair does not replace the failed original pair or establish AVIF acceptance. Full fidelity and installed acceptance remain unrun here.',
        'requiredProductScope':'Retain the legacy AVIF staging path before qualifying a WebP-only candidate; no production mutation is performed by this diagnostic.'}

def run(root, phase):
    expected_identity=identity_recheck(root,phase)
    result = {'protocol': PROTOCOL, 'phase': phase, 'predeclaredCriteria': CRITERIA,
        'signedExecutableIdentity': expected_identity, 'binaryIdentityRecheckedOutsideMeasuredParents': True}
    if phase == 'avif-confirmation':
        result.update(avif_confirmation(root))
    elif phase == 'export':
        pairs = [compare(cell(root, f'export-{repeat}-control'), cell(root, f'export-{repeat}-candidate'), True) for repeat in ['ab', 'ba']]
        result.update(pairs=pairs, verdict=paired_result(pairs), promotionReady=False)
    elif phase == 'product':
        pairs = [compare(cell(root, f'controller-{repeat}-control'), cell(root, f'controller-{repeat}-candidate'), False) for repeat in ['ab', 'ba']]
        result['controllerPairs'] = pairs
        result['controllerVerdict'] = paired_result(pairs)
        result['boundedChecks'] = {name: compare(cell(root, name+'-control'), cell(root, name+'-candidate'), False) for name in ['large-export', 'large-controller', 'avif-export', 'combined']}
        result['combinedScope'] = 'Corroboration only; parent independent ImageIO decode/full raster remains. Cannot qualify export-only benefit.'
        result['verdict'] = 'passes-predeclared-gates' if all(p['passes'] for p in pairs) and all(v['passes'] for k, v in result['boundedChecks'].items() if k != 'combined') else 'inconclusive-or-reject-review-independent-gates'
    elif phase in ('fidelity','fidelity-only'):
        standalone=phase=='fidelity-only'
        if standalone:
            expected={f'{mode}-{profile}-{arm}' for mode in ('evidence','validate') for profile in ('small','large') for arm in ('control','candidate')} | {'interruptions-control','interruptions-candidate'}
            need({p.parent.name for p in root.glob('*/codec-staging.json')}==expected, 'standalone fidelity needs exactly ten producer/validator/interruption cells')
            need(not any((root/(name+'-summary.json')).exists() for name in ('export','product','summary')), 'standalone fidelity cannot inherit or fabricate measured summaries')
        result['evidence'] = [evidence_checks(root, p,bind_measured=not standalone) for p in ('small', 'large')]
        for arm in ('control', 'candidate'):
            r = cell(root, 'interruptions-'+arm)
            need(r['status'] == 'passed' and r['comparisonMode']=='interruptions' and r['arm']==arm and r['closeDuringHelper']['progressTriggeredClose'] is True and r['closeDuringHelper']['lateResultSuppressed'] is True and r['closeDuringHelper']['controllerReleased'] is True, 'interruption checks incomplete')
            h=r['closeDuringHelper']['helper']
            need(h['childExitConfirmed'] is True and h['temporaryDirectoryRemoved'] is True and integer(h['childProcessIdentifier'],1) and h['helperExecutablePath']==r['helperVerifiedPath'] and h['pngStagingMode']==r['pngStagingMode'], 'close helper identity/route/cleanup missing')
            need(len(r['formats']) == 2 and {f['format'].lower() for f in r['formats']}=={'webp','avif'} and all(f['inFlightFormatQualityChange'] is True and f['realPixelsAndAlphaVerified'] is True and f['sameByteSave'] is True and f['childExitConfirmed'] is True and f['temporaryDirectoryRemoved'] is True for f in r['formats']), 'WebP/AVIF UI fidelity incomplete')
        result['verdict'] = 'passed'
        if standalone:
            result.update(promotionReady=False,sameRunMeasuredCellBinding=False,historicalMemoryQualification=False,
                scope='Standalone actual-file/independent-pixel/native-UI fidelity only. No same-run measured-cell binding, historical memory qualification, installed default-route acceptance or promotion is inferred.')
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
    parser.add_argument('root', type=Path); parser.add_argument('--phase', choices=['export', 'product', 'fidelity', 'summary', 'avif-confirmation', 'fidelity-only'], required=True)
    args = parser.parse_args()
    try:
        output = run(args.root, args.phase)
    except (EvidenceError, KeyError, StopIteration, TypeError) as e:
        output = {'phase': args.phase, 'verdict': 'inconclusive-invalid-or-missing-evidence', 'error': str(e), 'promotionReady': False}
        if args.phase=='fidelity-only':
            output.update(sameRunMeasuredCellBinding=False,historicalMemoryQualification=False)
        if args.phase=='avif-confirmation':
            output.update(avifQualificationHold=True, overallAVIFVerdict='inconclusive-incomplete-confirmation', priorFailedPair=AVIF_PRIOR_FAILURE)
    destination = args.root / (args.phase + '-summary.json')
    destination.write_text(json.dumps(output, indent=2, sort_keys=True)+'\n')
    print(json.dumps({'report': str(destination), 'verdict': output['verdict']}))
    raise SystemExit(2 if 'error' in output else 0 if output['verdict'] in ('passes-predeclared-gates', 'passed', 'bounded-candidate-gates-pass') else 3)
