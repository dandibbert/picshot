import copy
import importlib.util
import hashlib
import plistlib
import json
from pathlib import Path
import tempfile
import subprocess
import sys
import unittest

spec = importlib.util.spec_from_file_location('staging', Path(__file__).resolve().parents[1] / 'check-codec-staging-comparison.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
MiB = 1024 * 1024

def reading(rss, footprint, volatile):
    return {'standard': {'kernelReturn': 0, 'bytes': {'resident_size': int(rss*MiB), 'phys_footprint': int(footprint*MiB), 'resident_size_peak': int((rss+5)*MiB)},
        'ledgerBytes': {'ledger_phys_footprint_peak': int((footprint+5)*MiB)}},
        'purgeable': {'kernelReturn': 0, 'bytes': {'purgeable_volatile_resident': int(volatile*MiB)}, 'ledgerBytes': {'ledger_purgeable_volatile': int(volatile*MiB)}}}

def report(arm):
    control = arm == 'control'; growth = 20.25 if control else 0
    r = {'protocol': m.PROTOCOL, 'status': 'observed', 'arm': arm, 'sourceCommit': 'a'*40, 'bundlePath': '/tmp/PicShot.app',
        'helperVerifiedPath': '/tmp/PicShot.app/Contents/Helpers/PicShotCodecHelper', 'helperVerifiedSHA256': 'b'*64,
        'helperIdentityCheckedBeforeMeasurement': True, 'profile': 'installed-768x576', 'format': 'webp',
        'comparisonMode': 'export-only', 'sourceWidth': 768, 'sourceHeight': 576, 'warmupCycles': 2, 'measuredCycles': 12,
        'processIdentifier': 100 if control else 200, 'pngStagingMode': 'legacyPreview' if control else 'verifiedBytesOnly',
        'diagnosticEntryBacking': reading(45, 25, 0), 'backingBeforeWarmup': reading(50, 30, 0),
        'backingBaselineAfterWarmup': reading(60, 35, 3), 'backingHalfSecondAfterFinalCycle': reading(60+growth, 35, 3+growth),
        'wholeRunSampledMemory': {'peakResidentBytes': int((70+growth)*MiB), 'peakPhysicalFootprintBytes': 45*MiB,
            'peakVolatileResidentBytes': int((4+growth)*MiB), 'peakVolatileLedgerBytes': int((4+growth)*MiB)}}
    def cycle(i):
        return {'sourceSHA256': 'c'*64, 'encodedSHA256': 'd'*64, 'exportSeconds': .2,
            'helper': {'sourceSHA256': 'e'*64, 'pngStagingMode': r['pngStagingMode'], 'helperExecutablePath': r['helperVerifiedPath'],
                'childProcessIdentifier': 1000+i, 'outcome': 'succeeded', 'childExitConfirmed': True, 'temporaryDirectoryRemoved': True,
                'terminationStatus': 0, 'parentResidentSampleCount': 1, 'parentPhysicalFootprintSampleCount': 1,
                'childReportedResidentSampleCount': 1, 'childReportedPhysicalFootprintSampleCount': 1},
            'memory': {'timerTickCount': 1, 'backingSampleCount': 1}, 'payloadReleased': True, 'helperActive': False,
            'ownedTemporaryFiles': 0, 'fixtureEncodingTasksActive': 0, 'sameByteSave': True,
            'boundaries': [{'name': 'afterMainQueueDrainAndSettling', 'backing': reading(60+growth*i/12,35,3+growth*i/12)}]}
    r['warmups'] = [cycle(0),cycle(0)]; r['cycles'] = [cycle(i) for i in range(1,13)]
    for i,c in enumerate(r['warmups'],1):c.update(index=i,isWarmup=True);c['helper']['childProcessIdentifier']=900+i
    for i,c in enumerate(r['cycles'],1):c.update(index=i,isWarmup=False)
    return r

def preflight(root, report, phase='export'):
    identity={'schemaVersion':1,'bundlePath':report['bundlePath'],'sourceCommit':report['sourceCommit'],
        'mainExecutablePath':report['bundlePath']+'/Contents/MacOS/PicShot','mainExecutableSHA256':'f'*64,
        'helperExecutablePath':report['helperVerifiedPath'],'helperExecutableSHA256':report['helperVerifiedSHA256'],'infoPlistSHA256':'a'*64}
    (root/'identity.json').write_text(json.dumps(identity))
    for position in ['before','after']:
        (root/f'identity-{phase}-{position}.json').write_text(json.dumps({'phase':phase,'position':position,
            'outsideMeasuredParents':True,'matchesPreflight':True,'identity':identity}))
    return identity

class ComparisonTests(unittest.TestCase):
    def test_both_orders_required_and_no_compensation(self):
        a,b=report('control'),report('candidate')
        good=m.compare(a,b,True);self.assertTrue(good['passes'])
        b['cycles'][-1]['exportSeconds']=.3
        bad=m.compare(a,b,True);self.assertIn('latency.warmP95',bad['failedIndependentGates'])
        self.assertEqual(m.paired_result([good,bad]),'inconclusive-noise-or-order-sensitive')
        self.assertEqual(m.paired_result([bad,bad]),'reject-consistent-gate-excess')
        self.assertEqual(m.paired_result([good,good]),'passes-predeclared-gates')

    def test_nonreproducing_control_inconclusive(self):
        a,b=report('control'),report('candidate')
        for c in a['cycles']:c['boundaries'][0]['backing']=reading(60,35,3)
        result=m.compare(a,b,True)
        self.assertFalse(result['controlReproduces'])
        self.assertEqual(m.paired_result([result,result]),'inconclusive-control-did-not-reproduce')

    def test_tail_cannot_substitute_for_settled(self):
        a,b=report('control'),report('candidate')
        b['cycles'][-1]['boundaries'][0]['backing']=reading(65,35,8)
        result=m.compare(a,b,True)
        self.assertIn('volatile.remaining',result['failedIndependentGates'])
        self.assertEqual(result['candidate']['metrics']['volatile']['halfSecond'],3*MiB)
        self.assertEqual(result['candidate']['metrics']['volatile']['growth'],5*MiB)

    def test_missing_peak_never_zero_and_bytes_must_match(self):
        a,b=report('control'),report('candidate')
        del b['backingHalfSecondAfterFinalCycle']['standard']['bytes']['resident_size_peak']
        with self.assertRaises(m.EvidenceError):m.compare(a,b,True)
        b=report('candidate');b['cycles'][0]['helper']['sourceSHA256']='f'*64
        with self.assertRaises(m.EvidenceError):m.compare(a,b,True)

    def test_cold_peak_footprint_each_independent(self):
        a,b=report('control'),report('candidate')
        b['diagnosticEntryBacking']=reading(48,25,0)
        b['wholeRunSampledMemory']['peakPhysicalFootprintBytes']=48*MiB
        result=m.compare(a,b,True)
        self.assertIn('rss.entry',result['failedIndependentGates'])
        self.assertIn('footprint.sampledPeak',result['failedIndependentGates'])

    def test_signed_late_sum_and_nearest_rank(self):
        b=report('candidate')
        b['cycles'][-3]['boundaries'][0]['backing']=reading(60,35,4)
        b['cycles'][-2]['boundaries'][0]['backing']=reading(60,35,2)
        b['cycles'][-1]['boundaries'][0]['backing']=reading(60,35,3)
        b['cycles'][-1]['exportSeconds']=.23
        result=m.summarize(b)
        self.assertEqual(result['metrics']['volatile']['intervals'][-3:],[MiB,-2*MiB,MiB])
        self.assertEqual(result['metrics']['volatile']['lastThreeSignedSum'],0)
        self.assertEqual(result['latency']['warmP95'],.23)

    def test_actual_route_pid_exit_and_no_extra_source_draw(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp).resolve(strict=True);d=root/'cell';d.mkdir();r=report('candidate');preflight(root,r)
            life={'status':'exited','launcherExitCode':0,'ownedExitConfirmed':True,'launchedIdentityMatches':True,
                'processIdentifier':r['processIdentifier'],'launchedAppPath':r['bundlePath'],'launchedExecutablePath':r['bundlePath']+'/Contents/MacOS/PicShot'}
            (d/'codec-staging.json').write_text(json.dumps(r));(d/'launch.json.launcher.json').write_text(json.dumps(life))
            self.assertEqual(m.cell(root,'cell')['arm'],'candidate')
            r['cycles'][0]['helper']['pngStagingMode']='legacyPreview'
            (d/'codec-staging.json').write_text(json.dumps(r))
            with self.assertRaises(m.EvidenceError):m.cell(root,'cell')
            r=report('candidate');r['cycles'][0]['boundaries'].append({'name':'afterSourceRasterDigest'})
            (d/'codec-staging.json').write_text(json.dumps(r))
            with self.assertRaises(m.EvidenceError):m.cell(root,'cell')
            life['ownedExitConfirmed']=False;(d/'launch.json.launcher.json').write_text(json.dumps(life))
            with self.assertRaises(m.EvidenceError):m.cell(root,'cell')

    def test_truncation_flags_and_boolean_samples_rejected(self):
        for bad in ['truncated', 'index', 'warmFlag', 'peak', 'coldLatency']:
            a,b=report('control'),report('candidate')
            if bad=='truncated':a['cycles']=a['cycles'][:10];b['cycles']=b['cycles'][:10]
            if bad=='index':b['cycles'][-1]['index']=11
            if bad=='warmFlag':b['cycles'][0]['isWarmup']=True
            if bad=='peak':b['wholeRunSampledMemory']['peakResidentBytes']=True
            if bad=='coldLatency':b['warmups'][0]['exportSeconds']=float('nan')
            with self.subTest(bad=bad),self.assertRaises(m.EvidenceError):m.compare(a,b,True)

    def test_export_cli_does_not_green_a_rejected_benefit(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp).resolve(strict=True);preflight(root,report('control'))
            for i,name in enumerate(['export-ab-control','export-ab-candidate','export-ba-candidate','export-ba-control']):
                arm=name.rsplit('-',1)[-1];r=report(arm);r['processIdentifier']=100+i
                if arm=='candidate':
                    for c in r['cycles']:c['exportSeconds']=.4
                d=root/name;d.mkdir();(d/'codec-staging.json').write_text(json.dumps(r))
                (d/'launch.json.launcher.json').write_text(json.dumps({'status':'exited','launcherExitCode':0,'ownedExitConfirmed':True,
                    'launchedIdentityMatches':True,'processIdentifier':r['processIdentifier'],'launchedAppPath':r['bundlePath'],'launchedExecutablePath':r['bundlePath']+'/Contents/MacOS/PicShot'}))
            result=subprocess.run([sys.executable,str(Path(m.__file__)),str(root),'--phase','export'],capture_output=True,text=True)
            self.assertEqual(result.returncode,3,result.stdout+result.stderr)
            summary=json.loads((root/'export-summary.json').read_text())
            self.assertEqual(summary['verdict'],'reject-consistent-gate-excess')
            self.assertFalse(summary['promotionReady'])

    def test_binary_identity_requires_unchanged_final_recheck(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp).resolve(strict=True);expected=preflight(root,report('control'),'summary')
            self.assertEqual(m.identity_recheck(root,'summary'),expected)
            path=root/'identity-summary-after.json';changed=json.loads(path.read_text())
            changed['identity']['mainExecutableSHA256']='0'*64;path.write_text(json.dumps(changed))
            with self.assertRaises(m.EvidenceError):m.identity_recheck(root,'summary')
            changed['identity']=expected;changed['matchesPreflight']=False;path.write_text(json.dumps(changed))
            with self.assertRaises(m.EvidenceError):m.identity_recheck(root,'summary')
            path.unlink()
            with self.assertRaises(m.EvidenceError):m.identity_recheck(root,'summary')

    def test_cell_rejects_preflight_source_helper_or_main_path_mismatch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp).resolve(strict=True);d=root/'cell';d.mkdir();original=report('candidate');preflight(root,original)
            life={'status':'exited','launcherExitCode':0,'ownedExitConfirmed':True,'launchedIdentityMatches':True,
                'processIdentifier':original['processIdentifier'],'launchedAppPath':original['bundlePath'],
                'launchedExecutablePath':original['bundlePath']+'/Contents/MacOS/PicShot'}
            for key in ['sourceCommit','helperVerifiedSHA256','mainPath']:
                r=copy.deepcopy(original);l=copy.deepcopy(life)
                if key=='mainPath':l['launchedExecutablePath']='/tmp/other/PicShot'
                else:r[key]='0'*len(r[key])
                (d/'codec-staging.json').write_text(json.dumps(r));(d/'launch.json.launcher.json').write_text(json.dumps(l))
                with self.subTest(key=key),self.assertRaises(m.EvidenceError):m.cell(root,'cell')

    def test_shell_identity_capture_hashes_files_and_rejects_replacement(self):
        script=(Path(m.__file__).parent/'codec-staging-comparison.sh').read_text()
        body=script.split("<<'PYIDENTITY'\n",1)[1].split('\nPYIDENTITY',1)[0]
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp).resolve(strict=True);app=root/'PicShot.app';evidence=root/'evidence';evidence.mkdir()
            main=app/'Contents/MacOS/PicShot';helper=app/'Contents/Helpers/PicShotCodecHelper'
            main.parent.mkdir(parents=True);helper.parent.mkdir(parents=True)
            main.write_bytes(b'original-main');helper.write_bytes(b'original-helper')
            (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'PicShot','PicShotSourceCommit':'a'*40}))
            def capture(phase,position,bundle=app):return subprocess.run([sys.executable,'-c',body,str(bundle),str(evidence),phase,position],capture_output=True,text=True)
            alias=root/'Aliased.app';alias.symlink_to(app,target_is_directory=True)
            rejected=capture('export','before',alias)
            self.assertNotEqual(rejected.returncode,0)
            self.assertIn('requires the canonical bundle path',rejected.stderr)
            self.assertFalse((evidence/'identity.json').exists())
            first=capture('export','before');self.assertEqual(first.returncode,0,first.stderr)
            identity=json.loads((evidence/'identity.json').read_text())
            self.assertEqual(identity['mainExecutableSHA256'],hashlib.sha256(b'original-main').hexdigest())
            self.assertEqual(identity['helperExecutableSHA256'],hashlib.sha256(b'original-helper').hexdigest())
            self.assertEqual(capture('export','after').returncode,0)
            main.write_bytes(b'replaced-main')
            changed=capture('summary','after');self.assertNotEqual(changed.returncode,0)
            self.assertFalse(json.loads((evidence/'identity-summary-after.json').read_text())['matchesPreflight'])

    def test_combined_cannot_qualify_benefit(self):
        a,b=report('control'),report('candidate');a['comparisonMode']=b['comparisonMode']='combined'
        with self.assertRaises(m.EvidenceError):m.compare(a,b,True)

if __name__=='__main__':unittest.main()
