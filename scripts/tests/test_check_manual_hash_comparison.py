"""Synthetic schema/control-flow tests, never native memory observations."""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import uuid

HERE=Path(__file__).resolve().parent

def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result

CHECK=load('hash_comparison_check',HERE.parent/'check-manual-hash-comparison.py')
FIX=load('resource_fixture_data',HERE/'test_check_scroll_manual_resource_report.py')


def enrich(value):
    if isinstance(value,dict):
        if 'backingAccounting' in value:
            for flavor in value['backingAccounting'].values():
                flavor['bytes'].update(compressed=0,reusable=0)
                flavor['ledgerBytes'].update({key:0 for key in CHECK.LEDGERS})
        for item in value.values(): enrich(item)
    elif isinstance(value,list):
        for item in value: enrich(item)


class ComparisonTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.app=self.root/'PicShot.app'
        (self.app/'Contents/MacOS').mkdir(parents=True)
        self.executable=b'Synthetic unit test executable, never native evidence'
        (self.app/'Contents/MacOS/PicShot').write_bytes(self.executable)
        (self.app/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(PicShotSourceCommit=FIX.COMMIT,
            CFBundleShortVersionString='0.14.0',CFBundleVersion='140',CFBundleExecutable='PicShot')))

    def fixture(self,strategy='full-frame',pid=123,commit=FIX.COMMIT):
        resource=FIX.report(self.app,self.executable);resource['processIdentifier']=pid;resource['sourceCommit']=commit
        info=plistlib.loads((self.app/'Contents/Info.plist').read_bytes());info['PicShotSourceCommit']=commit
        (self.app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        functional=FIX.functional();functional.update(manualHashStrategy=strategy,processIdentifier=pid,sourceCommit=commit)
        functional['largeFrameProviders']=[dict(width=w,height=h,axis=axis,exactOutputDigest=True,
            closeReleasesControllerAndSpool=True,outputDigestSHA256=hashlib.sha256(axis.encode()).hexdigest())
            for w,h,axis in [(3840,2160,'horizontal'),(5120,2880,'vertical')]]
        functional['nativeAppearanceSnapshots']=dict(exactReferencePixels=True,acceptedFrames=3,outputWidth=640,outputHeight=920)
        digest=hashlib.sha256(json.dumps(functional,sort_keys=True).encode()).hexdigest()
        resource['functionalReportSHA256']=digest
        context=dict(strategy=strategy,diagnosticOnly=True,productionDefaultStrategy=CHECK.production_default_for_commit(commit),processStartMemoryCaptured=False,
            measurementStartScope='Synthetic smoke entry; not process birth',runIdentifier=str(uuid.uuid4()),
            operatingSystem='Synthetic test OS',smokeEntryBeforeFunctional=FIX.mem(-2),afterFunctionalBeforeResource=FIX.mem(-1),cycles=[])
        for row in resource['warmups']+resource['cycles']:
            context['cycles'].append(dict(index=row['index'],phase=row['phase'],profile=row['profile'],strategy=strategy,
                peakNormalizationBufferBytes=row['width']*row['height']*4 if strategy in CHECK.WORKSPACE_STRATEGIES else 0,
                normalizationSamples=40,normalizationReleases=[dict(stage=x,normalizationBufferBytes=0) for x in CHECK.RELEASES],
                normalizationBufferBytesAfterClose=0))
        resource['diagnosticHashComparison']=context;enrich(resource)
        entry={k:copy.deepcopy(v) for k,v in context.items() if k not in ('afterFunctionalBeforeResource','cycles')}
        launch=copy.deepcopy(functional);launch.update(resourceEvidence=copy.deepcopy(resource),bundlePath=str(self.app),arguments=['PicShot'])
        lifecycle=dict(schemaVersion=1,status='exited',launcherExitCode=0,callbackReceived=True,ownedExitConfirmed=True,
            createsNewApplicationInstance=True,processStartMemoryCaptured=False,timeoutSeconds=600,elapsedSeconds=100.0,
            selectedAppPath=str(self.app),launchedAppPath=str(self.app),processIdentifier=pid)
        return [resource,functional,launch,lifecycle,entry],dict(app=self.app,commit=commit,strategy=strategy,functional_sha=digest,launcher_exit_code=0)

    def check(self,args,kwargs): return CHECK.validate_cell(*args,**kwargs)

    def test_all_three_full_workload_cells_compare(self):
        cells=[self.check(*self.fixture(s,100+i))for i,s in enumerate(CHECK.SUITES['context-reuse'])]
        result=CHECK.compare_cells(cells,FIX.COMMIT)
        self.assertEqual(result['status'],'observed');self.assertFalse(result['installerAcceptance'])
        self.assertFalse(result['cells'][0]['processStartMemoryCaptured'])

    def test_new_source_requires_vimage_default_even_for_explicit_legacy_control(self):
        args,kwargs=self.fixture('full-frame')
        self.assertEqual(self.check(args,kwargs)['productionDefaultStrategy'],'vimage-full-frame')
        args[0]['diagnosticHashComparison']['productionDefaultStrategy']='full-frame'
        with self.assertRaisesRegex(ValueError,'production default/scope changed'):self.check(args,kwargs)

    def test_historical_defaults_are_exact_source_scoped_and_not_relabelled(self):
        for commit in CHECK.HISTORICAL_PRODUCTION_DEFAULTS:
            suite='context-reuse' if commit.startswith('8cb0c700') else 'direct-conversion'
            cells=[self.check(*self.fixture(s,100+i,commit)) for i,s in enumerate(CHECK.SUITES[suite])]
            self.assertEqual(CHECK.compare_cells(cells,commit,suite)['productionDefaultStrategy'],'full-frame')
            args,kwargs=self.fixture('full-frame',commit=commit)
            args[0]['diagnosticHashComparison']['productionDefaultStrategy']='vimage-full-frame'
            with self.assertRaisesRegex(ValueError,'production default/scope changed'):self.check(args,kwargs)
        self.assertEqual(CHECK.production_default_for_commit('f'*40),'vimage-full-frame')

    def test_new_matrix_rejects_missing_or_old_production_default_label(self):
        original=[self.check(*self.fixture(s,100+i))for i,s in enumerate(CHECK.SUITES['direct-conversion'])]
        for value in [None,'full-frame']:
            cells=copy.deepcopy(original)
            if value is None: del cells[1]['productionDefaultStrategy']
            else: cells[1]['productionDefaultStrategy']=value
            self.assertEqual(CHECK.compare_cells(cells,FIX.COMMIT,'direct-conversion')['status'],'incomplete')

    def test_strategy_mismatch_and_missing_extension_fail(self):
        args,kwargs=self.fixture();args[0]['diagnosticHashComparison']['strategy']='pooled-full-frame'
        with self.assertRaises(ValueError):self.check(args,kwargs)
        args,kwargs=self.fixture();del args[0]['diagnosticHashComparison']
        with self.assertRaises(ValueError):self.check(args,kwargs)

    def test_true_process_start_claim_fails(self):
        args,kwargs=self.fixture();args[0]['diagnosticHashComparison']['processStartMemoryCaptured']=True
        with self.assertRaises(ValueError):self.check(args,kwargs)

    def test_failed_partial_or_reduced_resource_never_passes(self):
        for edit in [lambda r:r.update(status='failed'),lambda r:r['cycles'].pop(),lambda r:r.update(measuredCycles=13)]:
            args,kwargs=self.fixture();edit(args[0])
            with self.assertRaises((ValueError,KeyError)):self.check(args,kwargs)

    def test_workspace_ownership_and_releases_are_required(self):
        for edit in [lambda c:c.update(peakNormalizationBufferBytes=0),lambda c:c['normalizationReleases'].pop(),
                     lambda c:c['normalizationReleases'][0].update(normalizationBufferBytes=1),lambda c:c.update(normalizationBufferBytesAfterClose=1)]:
            args,kwargs=self.fixture('reusable-full-frame');edit(args[0]['diagnosticHashComparison']['cycles'][0])
            with self.assertRaises(ValueError):self.check(args,kwargs)

    def test_launch_exit_identity_and_lifecycle_bound_are_required(self):
        for field,value in [('ownedExitConfirmed',False),('processIdentifier',999),('createsNewApplicationInstance',False),('timeoutSeconds',900)]:
            args,kwargs=self.fixture();args[3][field]=value
            with self.assertRaises(ValueError):self.check(args,kwargs)
        args,kwargs=self.fixture();kwargs['launcher_exit_code']=1
        with self.assertRaises(ValueError):self.check(args,kwargs)

    def test_entry_boundary_and_large_digest_tampering_fail(self):
        args,kwargs=self.fixture();args[4]['smokeEntryBeforeFunctional']['residentBytes']+=1
        with self.assertRaises(ValueError):self.check(args,kwargs)
        args,kwargs=self.fixture();args[1]['largeFrameProviders'][0]['outputDigestSHA256']='invalid'
        with self.assertRaises(ValueError):self.check(args,kwargs)

    def test_matrix_requires_equal_runtime_counts_digests_and_distinct_processes(self):
        original=[self.check(*self.fixture(s,100+i))for i,s in enumerate(CHECK.SUITES['context-reuse'])]
        changes={'processIdentifier':100,'architecture':'x86_64','operatingSystem':'different','executableSHA256':'f'*64,
                 'captureCounts':[],'sourceByteDigests':[],'largeOutputDigests':[]}
        for field,value in changes.items():
            cells=copy.deepcopy(original);cells[1][field]=value
            with self.subTest(field=field):self.assertEqual(CHECK.compare_cells(cells,FIX.COMMIT)['status'],'incomplete')

    def test_one_failed_cell_preserves_other_observations_but_cannot_complete_matrix(self):
        cells=[self.check(*self.fixture(s,100+i))for i,s in enumerate(CHECK.SUITES['context-reuse'])]
        cells[0]=dict(strategy=CHECK.STRATEGIES[0],status='failed',error='240 second timeout')
        result=CHECK.compare_cells(cells,FIX.COMMIT)
        self.assertEqual(result['status'],'incomplete');self.assertEqual(result['cells'][1]['status'],'observed')

    def test_direct_conversion_requires_exact_pair_and_records_selected_suite(self):
        cells=[self.check(*self.fixture(s,100+i))for i,s in enumerate(CHECK.SUITES['direct-conversion'])]
        result=CHECK.compare_cells(cells,FIX.COMMIT,'direct-conversion')
        self.assertEqual(result['status'],'observed')
        self.assertEqual(result['selectedStrategies'],['full-frame','vimage-full-frame'])
        self.assertEqual(result['suite'],'direct-conversion')
        self.assertIn('fixed full-frame, vimage-full-frame;',result['ordering'])
        self.assertNotIn('pooled-full-frame',result['ordering'])
        for wrong in [cells[::-1],cells[:1],cells+[self.check(*self.fixture('pooled-full-frame',777))],
                      [cells[0],self.check(*self.fixture('reusable-full-frame',888))]]:
            with self.assertRaises(ValueError):CHECK.compare_cells(wrong,FIX.COMMIT,'direct-conversion')
        with self.assertRaises(ValueError):CHECK.compare_cells(cells,FIX.COMMIT)
        with self.assertRaises(ValueError):CHECK.compare_cells(cells,FIX.COMMIT,'unknown')

    def test_vimage_workspace_cannot_be_zero_or_exceed_nominal_bound(self):
        for peak in [0,3840*2160*4+1]:
            args,kwargs=self.fixture('vimage-full-frame')
            args[0]['diagnosticHashComparison']['cycles'][0]['peakNormalizationBufferBytes']=peak
            with self.assertRaises(ValueError):self.check(args,kwargs)

    def test_native_timeout_reason_precedes_success_schema_and_retains_partial_counts(self):
        for measured,reason in [(4,'First source not accepted'),(2,'Moved source not accepted'),(3,'Stable source 4 not accepted')]:
            args,kwargs=self.fixture();resource=args[0]
            resource.update(status='failed',observationsComplete=False,error=reason,elapsedSeconds=240.03)
            resource['cycles']=resource['cycles'][:measured]
            del resource['completedMeasuredCycles'];del resource['finalAfterCleanup']
            kwargs['app']=self.root/'absent-app'
            with self.assertRaises(CHECK.IncompleteResource) as raised:self.check(args,kwargs)
            self.assertIn(reason,str(raised.exception));self.assertNotIn('unexpected object keys',str(raised.exception))
            p=raised.exception.partial
            self.assertEqual(p['status'],'failed');self.assertTrue(p['unvalidated']);self.assertTrue(p['deadlineReached'])
            self.assertEqual(p['recordedCompletedWarmupCycles'],8);self.assertEqual(p['recordedCompletedMeasuredCycles'],measured)

    def test_cli_native_failure_is_never_promoted_or_hidden_by_absent_other_files(self):
        directory=self.root/'failed';directory.mkdir()
        (directory/'scroll-manual-resource.json').write_text(json.dumps(dict(status='failed',error='Resource fixture deadline exceeded',
            elapsedSeconds=240.04,overallDeadlineSeconds=240,warmups=[{}]*8,cycles=[{}]*2)))
        command=['python3',str(HERE.parent/'check-manual-hash-comparison.py'),'cell',str(directory),str(self.root/'missing-app'),FIX.COMMIT,'full-frame','--launcher-exit-code','0']
        result=subprocess.run(command,capture_output=True,text=True)
        self.assertEqual(result.returncode,1,result.stderr)
        report=json.loads(result.stdout)
        self.assertEqual(report['resourceStatus'],'failed');self.assertFalse(report['observationsComplete'])
        self.assertEqual(report['nativeFailureReason'],'Resource fixture deadline exceeded')
        self.assertEqual(report['partialEvidence']['recordedCompletedMeasuredCycles'],2)
        self.assertIn('Partial evidence is not accepted',report['error'])

    def test_direct_cli_rejects_unselected_third_cell(self):
        directory=self.root/'matrix';directory.mkdir()
        for i,strategy in enumerate(CHECK.SUITES['context-reuse']):
            cell=directory/strategy;cell.mkdir()
            (cell/'checked-cell.json').write_text(json.dumps(self.check(*self.fixture(strategy,100+i))))
        result=subprocess.run(['python3',str(HERE.parent/'check-manual-hash-comparison.py'),'matrix',str(directory),FIX.COMMIT,'--suite','direct-conversion'],capture_output=True,text=True)
        self.assertEqual(result.returncode,1,result.stderr)
        self.assertIn('unselected candidate cells present',json.loads(result.stdout)['error'])

    def test_shell_direct_conversion_runs_only_two_cells_after_confirmed_peer_failure(self):
        self.mock_shell(exit_confirmed=True,suite='direct-conversion')

    def test_shell_unknown_suite_fails_before_launch(self):
        evidence=self.root/'never-created'
        result=subprocess.run(['bash',str(HERE.parent/'manual-hash-comparison.sh'),str(self.app),str(evidence),FIX.COMMIT,'typo'],capture_output=True,text=True)
        self.assertEqual(result.returncode,64);self.assertFalse(evidence.exists())
        self.assertIn('Unknown manual-hash suite',result.stderr)

    def test_shell_continues_after_confirmed_failure_and_retains_incomplete_matrix(self):
        self.mock_shell(exit_confirmed=True)

    def test_shell_blocks_peers_if_owned_exit_is_not_confirmed(self):
        self.mock_shell(exit_confirmed=False)

    def mock_shell(self, exit_confirmed, suite=None):
        selected=CHECK.SUITES[suite or 'context-reuse']
        # Mock only the orchestration layer: no real app/codesign/Swift is run.
        repo=self.root/'mock-repo';(repo/'scripts').mkdir(parents=True)
        shutil.copyfile(HERE.parent/'manual-hash-comparison.sh',repo/'scripts/manual-hash-comparison.sh')
        fakebin=repo/'bin';fakebin.mkdir()
        (fakebin/'codesign').write_text('#!/bin/sh\nexit 0\n');(fakebin/'codesign').chmod(0o755)
        (fakebin/'swift').write_text('''#!/usr/bin/env python3
import json,os,pathlib,sys
strategy=os.environ['PICSHOT_MANUAL_HASH_STRATEGY']
root=pathlib.Path(sys.argv[-1]).parent
(root/'launch.json.launcher.json').write_text(json.dumps({'ownedExitConfirmed':os.environ['MOCK_EXIT_CONFIRMED']=='1'}))
with (root.parent/'calls.txt').open('a') as f:f.write(strategy+'\\n')
sys.exit(1 if strategy=='full-frame' else 0)
''');(fakebin/'swift').chmod(0o755)
        (repo/'scripts/check-manual-hash-comparison.py').write_text('''import json,pathlib,sys
if sys.argv[1]=='cell':
 strategy=sys.argv[5];failed=strategy=='full-frame'
 print(json.dumps({'strategy':strategy,'status':'failed' if failed else 'observed'}));sys.exit(int(failed))
root=pathlib.Path(sys.argv[2]);cells=[json.loads(p.read_text())for p in root.glob('*/checked-cell.json')]
print(json.dumps({'status':'incomplete','cells':cells}));sys.exit(1)
''')
        evidence=repo/'evidence';env=dict(os.environ,PATH=str(fakebin)+os.pathsep+os.environ['PATH'],MOCK_EXIT_CONFIRMED='1' if exit_confirmed else '0')
        command=['bash',str(repo/'scripts/manual-hash-comparison.sh'),str(self.app),str(evidence),FIX.COMMIT]
        if suite is not None: command.append(suite)
        result=subprocess.run(command,env=env,capture_output=True,text=True)
        self.assertEqual(result.returncode,1,result.stderr)
        self.assertEqual((evidence/'calls.txt').read_text().splitlines(),list(selected) if exit_confirmed else ['full-frame'])
        comparison=json.loads((evidence/'comparison.json').read_text())
        self.assertEqual(comparison['status'],'incomplete');self.assertEqual(len(comparison['cells']),len(selected))
        if not exit_confirmed:
            self.assertEqual(sum(c['status']=='blocked' for c in comparison['cells']),len(selected)-1)


if __name__=='__main__':unittest.main()
