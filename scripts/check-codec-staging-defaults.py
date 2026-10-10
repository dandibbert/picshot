#!/usr/bin/env python3
"""Verify actual production routes in the existing ordinary installed reports."""
import argparse
import json
from pathlib import Path

MODES=('verifiedBytesOnly','legacyPreview')

def require(condition,message):
    if not condition:raise ValueError(message)

def load(path):
    require(path.is_file() and path.stat().st_size<=4*1024*1024,'missing/oversized ordinary attribution report')
    return json.loads(path.read_text())

def check(root,source,expected):
    require(len(source)==40 and all(c in '0123456789abcdef' for c in source),'exact expected source required')
    require(set(expected)=={'webp','avif'} and all(v in MODES for v in expected.values()),'explicit per-format production routes required')
    prepared=load(root/'prepared/launch.json')
    require(prepared['status']=='prepared' and prepared['sourceCommit']==source and prepared['profile']=='installed-768x576','ordinary preparation source/profile differs')
    require([e['format'] for e in prepared['inputs']]==['webp','avif'],'ordinary prepared formats differ')
    pids=[prepared['processIdentifier']];observed=[];bundle=None
    def helper(h,fmt,path):
        require(h['outcome']=='succeeded' and h['childExitConfirmed'] is True and h['temporaryDirectoryRemoved'] is True and
                type(h['terminationStatus']) is int and h['terminationStatus']==0 and type(h['childProcessIdentifier']) is int and h['childProcessIdentifier']>0,
                'actual production helper launch/exit/cleanup missing')
        require(h['pngStagingMode']==expected[fmt],f'{fmt}: installed production pngStagingMode differs from declared scope')
        require(h['helperExecutablePath']==path,'actual production helper path differs')
        require(h.get('sourceSHA256') is None,'ordinary production must leave diagnostic staged-PNG identity collection off')
        observed.append({'format':fmt,'pngStagingMode':h['pngStagingMode'],'helperPID':h['childProcessIdentifier']})
    for fmt in ['webp','avif']:
        for mode in ['export-only','decode-only','combined']:
            r=load(root/fmt/mode/'launch.json')
            require(r['status']=='observed' and r['sourceCommit']==source and r['format']==fmt and r['mode']==mode and r['profile']=='installed-768x576','ordinary cell identity differs')
            require('arm' not in r and 'comparisonMode' not in r and 'pngStagingMode' not in r,'diagnostic-selected cell cannot prove the production default')
            require(r['sourceWidth']==768 and r['sourceHeight']==576 and r['warmupCycles']==2 and r['measuredCycles']==12 and len(r['warmups'])==2 and len(r['cycles'])==12,'ordinary cell workload differs')
            require(r['temporaryDirectoryRemoved'] is True and r['fixtureEncodingTasksActive']==0 and r['activeControllersAfterAllCycles']==0 and r['queuedOrRunningJobsAfterAllCycles']==0,'ordinary cell cleanup incomplete')
            bundle=r['bundlePath'] if bundle is None else bundle
            require(r['bundlePath']==bundle and bundle.endswith('.app'),'ordinary installed bundle path differs')
            pids.append(r['processIdentifier'])
            if mode!='decode-only':
                for c in r['warmups']+r['cycles']:helper(c['helper'],fmt,bundle+'/Contents/Helpers/PicShotCodecHelper')
    for e in prepared['inputs']:helper(e['helper'],e['format'],bundle+'/Contents/Helpers/PicShotCodecHelper')
    require(all(type(pid) is int and pid>0 for pid in pids) and len(set(pids))==7,'ordinary cells must be seven distinct processes')
    require(len(observed)==58,'expected ordinary image staging jobs missing')
    return {'status':'verified','sourceCommit':source,'bundlePath':bundle,'expectedProductionRoutes':expected,'observedJobs':observed,
        'actualProductionRouteVerified':True,'diagnosticStagedPNGIdentityCollection':False,'memoryQualification':False,'promotionReady':False,
        'scope':'Actual per-job pngStagingMode from unmodified ordinary installed codec-attribution paths. The ordinary reports contain no diagnostic arm selection and every helper has staged-PNG source identity collection off. This check does not select a diagnostic arm or grant memory/fidelity/installer acceptance.'}

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('root',type=Path);parser.add_argument('--source',required=True)
    parser.add_argument('--webp',choices=MODES,required=True);parser.add_argument('--avif',choices=MODES,required=True);parser.add_argument('--report',type=Path,required=True);args=parser.parse_args()
    try:result=check(args.root,args.source,{'webp':args.webp,'avif':args.avif})
    except (ValueError,KeyError,TypeError) as error:result={'status':'failed','error':str(error),'promotionReady':False}
    args.report.parent.mkdir(parents=True,exist_ok=True);args.report.write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k!='observedJobs'}));raise SystemExit(0 if result['status']=='verified' else 1)
