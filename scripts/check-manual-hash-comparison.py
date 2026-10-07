#!/usr/bin/env python3
"""Validate full-workload manual hash candidates; incomplete cells never pass."""
import argparse
import copy
import importlib.util
import json
from pathlib import Path
import plistlib
import sys
import uuid

SPEC = importlib.util.spec_from_file_location('manual_resource_check', Path(__file__).with_name('check-scroll-manual-resource-report.py'))
BASE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BASE)
STRATEGIES = ('full-frame', 'pooled-full-frame', 'reusable-full-frame')
RELEASES = ('first-pause', 'second-pause', 'recoverable-seam', 'accepted-3-pause', 'accepted-4-pause', 'cancel', 'reset')
CONTEXT_FIELDS = {'strategy', 'diagnosticOnly', 'productionDefaultStrategy', 'processStartMemoryCaptured',
                  'measurementStartScope', 'runIdentifier', 'operatingSystem', 'smokeEntryBeforeFunctional',
                  'afterFunctionalBeforeResource', 'cycles'}
METRICS = ('purgeable_volatile_resident', 'purgeable_volatile_virtual', 'purgeable_volatile_pmap', 'compressed', 'reusable')
LEDGERS = ('ledger_purgeable_nonvolatile', 'ledger_purgeable_novolatile_compressed',
           'ledger_purgeable_volatile', 'ledger_purgeable_volatile_compressed')


def points(point):
    BASE.memory(point)
    p = point['backingAccounting']['purgeable']
    result = {key: point[key] for key in ('residentBytes', 'physicalFootprintBytes')}
    for key in METRICS:
        result[key] = BASE.integer(p['bytes'][key], 0, 2**64-1)
    for key in LEDGERS:
        result[key] = BASE.integer(p['ledgerBytes'][key], -2**63, 2**63-1)
    return result


def delta(a, b):
    return {key: b[key]-a[key] for key in a}


def validate_cell(resource, functional, launch, lifecycle, entry, *, app, commit, strategy, functional_sha, launcher_exit_code):
    BASE.need(strategy in STRATEGIES, 'unknown strategy')
    BASE.need(launcher_exit_code == 0, 'launcher did not complete successfully')
    app = Path(app).resolve(strict=True)
    info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    BASE.need(type(resource) is dict and 'diagnosticHashComparison' in resource, 'diagnostic resource extension missing')
    context = resource['diagnosticHashComparison']
    BASE.keys(context, CONTEXT_FIELDS)
    BASE.need(context['strategy'] == functional.get('manualHashStrategy') == strategy, 'actual strategy differs between reports')
    BASE.need(context['diagnosticOnly'] is True and context['productionDefaultStrategy'] == 'full-frame', 'production default/scope changed')
    BASE.need(context['processStartMemoryCaptured'] is False and 'not process birth' in context['measurementStartScope'], 'startup memory mislabeled')
    BASE.string(context['operatingSystem']); uuid.UUID(context['runIdentifier'])
    BASE.need(type(entry) is dict and entry == {k:v for k,v in context.items() if k not in ('afterFunctionalBeforeResource','cycles')}, 'saved smoke-entry boundary differs')
    original = copy.deepcopy(resource); del original['diagnosticHashComparison']
    # Every original assertion, bound, arithmetic check, image identity and
    # actual installed executable check remains in the unchanged strict checker.
    BASE.validate(original, expected_commit=commit, expected_version=info['CFBundleShortVersionString'],
                  expected_build=info['CFBundleVersion'], installed_app=app,
                  functional_report=functional, functional_report_sha256=functional_sha)
    BASE.need(launch.get('resourceEvidence') == resource, 'launch/resource payload differs')
    BASE.need({k:v for k,v in launch.items() if k not in ('resourceEvidence','bundlePath','arguments')} == functional,
              'launch/functional payload differs')
    BASE.need(Path(launch['bundlePath']).resolve(strict=True) == app and len(launch['arguments']) == 1, 'wrong launched bundle/arguments')
    BASE.need(lifecycle.get('schemaVersion') == 1 and lifecycle.get('status') == 'exited'
              and lifecycle.get('launcherExitCode') == 0 and lifecycle.get('callbackReceived') is True
              and lifecycle.get('ownedExitConfirmed') is True and lifecycle.get('createsNewApplicationInstance') is True,
              'fresh owned process exit not verified')
    BASE.need(lifecycle.get('processStartMemoryCaptured') is False and lifecycle.get('timeoutSeconds') == 600, 'launcher scope/deadline differs')
    BASE.number(lifecycle['elapsedSeconds'], 0, 606)
    BASE.need(Path(lifecycle['selectedAppPath']).resolve(strict=True) == app and Path(lifecycle['launchedAppPath']).resolve(strict=True) == app, 'launcher selected another app')
    pid = BASE.integer(resource['processIdentifier'], 1)
    BASE.need(lifecycle.get('processIdentifier') == functional.get('processIdentifier') == pid, 'process identity differs')
    endpoint_names = ('smokeEntryBeforeFunctional','afterFunctionalBeforeResource','beforeWarmup','baselineAfterWarmup','finalAfterCleanup')
    endpoints = {name: points(context[name] if name in context else resource[name]) for name in endpoint_names}
    times = [context[name]['backingAccounting']['standard']['observedAtUptimeSeconds'] for name in endpoint_names[:2]]
    times += [resource['beforeWarmup']['backingAccounting']['standard']['observedAtUptimeSeconds']]
    BASE.need(times == sorted(times), 'smoke/functional/resource boundary order differs')
    diagnostics = BASE.array(context['cycles'], 24)
    rows = resource['warmups'] + resource['cycles']
    for diagnostic, row in zip(diagnostics, rows):
        BASE.keys(diagnostic, {'index','phase','profile','strategy','peakNormalizationBufferBytes','normalizationSamples',
                               'normalizationReleases','normalizationBufferBytesAfterClose'})
        BASE.need(all(diagnostic[k] == row[k] for k in ('index','phase','profile')) and diagnostic['strategy'] == strategy, 'normalization cycle identity differs')
        expected = row['width'] * row['height'] * 4 if strategy == 'reusable-full-frame' else 0
        BASE.need(BASE.integer(diagnostic['peakNormalizationBufferBytes']) == expected, 'normalization peak differs from bounded workspace')
        BASE.integer(diagnostic['normalizationSamples'], 1)
        releases = BASE.array(diagnostic['normalizationReleases'], len(RELEASES))
        BASE.need([item.get('stage') for item in releases] == list(RELEASES), 'drained normalization evidence incomplete')
        for release in releases:
            BASE.keys(release, {'stage','normalizationBufferBytes'})
            BASE.need(BASE.integer(release['normalizationBufferBytes']) == 0, 'normalization workspace survived drain')
        BASE.need(BASE.integer(diagnostic['normalizationBufferBytesAfterClose']) == 0, 'normalization workspace survived close')
    large = BASE.array(functional.get('largeFrameProviders'), 2)
    BASE.need({(r['width'],r['height'],r['axis']) for r in large} == {(3840,2160,'horizontal'),(5120,2880,'vertical')}, 'functional large profiles incomplete')
    digests = []
    for row in large:
        BASE.need(row['exactOutputDigest'] is True and row['closeReleasesControllerAndSpool'] is True, 'exact large output/cleanup failed')
        BASE.sha(row['outputDigestSHA256'])
        digests.append([row['width'],row['height'],row['axis'],row['outputDigestSHA256']])
    appearance = functional.get('nativeAppearanceSnapshots', {})
    BASE.need(appearance.get('exactReferencePixels') is True and appearance.get('acceptedFrames') == 3
              and appearance.get('outputWidth') == 640 and appearance.get('outputHeight') == 920, 'native readable output proof missing')
    return {'status':'observed','strategy':strategy,'diagnosticOnly':True,'observationsComplete':True,
            'sourceCommit':commit,'executableSHA256':resource['executableSHA256'],'processIdentifier':pid,
            'runIdentifier':context['runIdentifier'],'ownedExitConfirmed':True,'architecture':resource['architecture'],
            'buildMode':resource['buildMode'],'operatingSystem':context['operatingSystem'],
            'processStartMemoryCaptured':False,'measurementStartScope':context['measurementStartScope'],
            'elapsedSeconds':resource['elapsedSeconds'],'endpoints':endpoints,
            'stageDeltas':{f'{a}To{b}':delta(endpoints[a],endpoints[b]) for a,b in zip(endpoint_names,endpoint_names[1:])},
            'warmupToFinalDelta':delta(endpoints['baselineAfterWarmup'],endpoints['finalAfterCleanup']),
            'warmupSampledMemory':resource['warmupSampledMemory'],'sampledMemory':resource['sampledMemory'],
            'captureCounts':[[r['phase'],r['index'],r['profile'],r['captures'],r['sampledFrames']] for r in rows],
            'sourceByteDigests':[[r['phase'],r['index'],r['profile'],[[x['bytes'],x['sha256']] for x in r['sourceBytesBefore']]] for r in rows],
            'largeOutputDigests':digests,'zeroLeakClaim':False}


def compare_cells(cells, commit):
    BASE.need(len(cells) == 3 and [c.get('strategy') for c in cells] == list(STRATEGIES), 'three ordered candidate cells required')
    issues = [f"{c['strategy']}: {c.get('error',c.get('status'))}" for c in cells if c.get('status') != 'observed']
    result = {'schemaVersion':1,'sourceCommit':commit,'diagnosticOnly':True,'installerAcceptance':False,
              'productionDefaultStrategy':'full-frame','cells':cells,'zeroLeakClaim':False,
              'ordering':'fixed full-frame, pooled-full-frame, reusable-full-frame; timing/order may confound comparisons',
              'scope':'Same executable and full E2E work counts; actual backing accounting does not establish reclaimability or unlimited-run stability'}
    if not issues:
        for field in ('sourceCommit','executableSHA256','architecture','operatingSystem','buildMode','captureCounts','sourceByteDigests','largeOutputDigests'):
            if any(c[field] != cells[0][field] for c in cells[1:]): issues.append('paired equality failed: '+field)
        if cells[0]['sourceCommit'] != commit: issues.append('matrix source identity differs')
        if len({c['processIdentifier'] for c in cells}) != 3: issues.append('distinct process IDs not established')
        if len({c['runIdentifier'] for c in cells}) != 3: issues.append('distinct invocation IDs not established')
    result.update(status='incomplete' if issues else 'observed', observationsComplete=not issues, issues=issues,
                  matchingWorkloadAndRuntime=not issues)
    return result


def cell_from_files(directory, app, commit, strategy, launcher_exit_code):
    functional, digest = BASE.read_json_with_sha(directory/'scroll-manual-continuous.json')
    return validate_cell(BASE.read_json(directory/'scroll-manual-resource.json'),functional,
                         BASE.read_json(directory/'launch.json'),BASE.read_json(directory/'launch.json.launcher.json'),
                         BASE.read_json(directory/'manual-hash-entry.json'),app=app,commit=commit,strategy=strategy,
                         functional_sha=digest,launcher_exit_code=launcher_exit_code)


def main():
    parser=argparse.ArgumentParser(description=__doc__); sub=parser.add_subparsers(dest='command',required=True)
    cell=sub.add_parser('cell');cell.add_argument('directory',type=Path);cell.add_argument('app',type=Path);cell.add_argument('commit')
    cell.add_argument('strategy',choices=STRATEGIES);cell.add_argument('--launcher-exit-code',type=int,required=True)
    matrix=sub.add_parser('matrix');matrix.add_argument('directory',type=Path);matrix.add_argument('commit')
    args=parser.parse_args()
    try:
        if args.command=='cell':
            result=cell_from_files(args.directory,args.app,args.commit,args.strategy,args.launcher_exit_code)
        else:
            cells=[]
            for strategy in STRATEGIES:
                try: cells.append(BASE.read_json(args.directory/strategy/'checked-cell.json'))
                except (ValueError,OSError,KeyError,TypeError) as error:
                    cells.append({'strategy':strategy,'status':'missing','error':str(error)})
            result=compare_cells(cells,args.commit)
    except (ValueError,OSError,KeyError,TypeError,OverflowError,RecursionError) as error:
        result={'status':'failed','observationsComplete':False,'error':str(error),'diagnosticOnly':True}
        if args.command=='cell':
            result.update(strategy=args.strategy,launcherExitCode=args.launcher_exit_code)
            try:
                partial=BASE.read_json(args.directory/'scroll-manual-resource.json')
                result['partialEvidence']={'unvalidated':True,'status':partial.get('status'),'error':partial.get('error'),
                    'elapsedSeconds':partial.get('elapsedSeconds'),'warmupRows':len(partial.get('warmups',[])),
                    'measuredRows':len(partial.get('cycles',[]))}
            except (ValueError,OSError,KeyError,TypeError): pass
    print(json.dumps(result,indent=2,sort_keys=True))
    return 0 if result['status']=='observed' else 1


if __name__=='__main__': sys.exit(main())
