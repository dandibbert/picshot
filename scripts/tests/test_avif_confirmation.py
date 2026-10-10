import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

# Reuse unchanged thirteen-test fixture constructors, not a second checker model.
from test_check_codec_staging_comparison import m, report, preflight

HERE=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('avif_guard',HERE/'check-avif-confirmation-source.py')
guard=importlib.util.module_from_spec(spec);spec.loader.exec_module(guard)


def prepare(root):
    source=preflight(root,report('candidate'),'avif-confirmation')['sourceCommit']
    proof={'status':'verified','baseCommit':guard.BASE,'baseTree':guard.TREE,'headCommit':source,
        'nativeSourceBytesUnchanged':True,'protectedFileCount':1,'protectedFiles':[{'path':'Sources/test.swift','sha256':'a'*64}]}
    for position in ['before','after']:(root/f'source-guard-{position}.json').write_text(json.dumps(proof))
    for arm in ['candidate','control']:
        r=report(arm);r.update(format='avif',profile='staging-768x576',measuredCycles=3)
        r['cycles']=r['cycles'][:3]
        r['diagnosticEntryBacking']['standard']['observedAtUptimeSeconds']=100 if arm=='candidate' else 200
        r['backingHalfSecondAfterFinalCycle']['standard']['observedAtUptimeSeconds']=110 if arm=='candidate' else 210
        directory=root/('avif-confirmation-'+arm);directory.mkdir()
        (directory/'codec-staging.json').write_text(json.dumps(r))
        life={'status':'exited','launcherExitCode':0,'ownedExitConfirmed':True,'launchedIdentityMatches':True,
            'processIdentifier':r['processIdentifier'],'launchedAppPath':r['bundlePath'],
            'launchedExecutablePath':r['bundlePath']+'/Contents/MacOS/PicShot'}
        (directory/'launch.json.launcher.json').write_text(json.dumps(life))


class AVIFConfirmationTests(unittest.TestCase):
    def test_phase_invokes_exactly_candidate_then_control(self):
        script=(HERE/'codec-staging-comparison.sh').read_text()
        case=script.split('case "$phase" in\n',1)[1].split('\nesac',1)[0]
        observed=subprocess.check_output(['bash','-c','phase=avif-confirmation\nrun() { printf "%s\\n" "$*"; }\ncase "$phase" in\n'+case+'\nesac'],text=True)
        self.assertEqual(observed.splitlines(),[
            'avif-confirmation-candidate export-only candidate staging-768x576 avif',
            'avif-confirmation-control export-only control staging-768x576 avif'])

    def test_passing_confirmation_never_promotes_or_erases_prior_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary).resolve();prepare(root)
            result=m.run(root,'avif-confirmation')
            self.assertTrue(result['confirmationPair']['passes'])
            self.assertFalse(result['priorFailedPair']['passes'])
            self.assertEqual(result['priorFailedPair']['failedIndependentGates'],['latency.warmP95'])
            self.assertAlmostEqual(result['priorFailedPair']['candidateWarmP95Seconds'],.669911083333318)
            self.assertEqual(result['overallAVIFVerdict'],'inconclusive-order-sensitive')
            self.assertTrue(result['avifQualificationHold']);self.assertFalse(result['promotionReady'])
            self.assertFalse((root/'product-summary.json').exists())
            self.assertEqual(result['predeclaredCriteria'],m.CRITERIA)

    def test_repeat_failure_retains_fixed_threshold_and_nonzero_exit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary).resolve();prepare(root)
            path=root/'avif-confirmation-candidate/codec-staging.json';r=json.loads(path.read_text())
            r['cycles'][-1]['exportSeconds']=.4;path.write_text(json.dumps(r))
            result=m.run(root,'avif-confirmation')
            self.assertIn('latency.warmP95',result['confirmationPair']['failedIndependentGates'])
            self.assertEqual(result['overallAVIFVerdict'],'reject-consistent-gate-excess')
            self.assertFalse(result['promotionReady'])
            cli=subprocess.run([sys.executable,str(HERE/'check-codec-staging-comparison.py'),str(root),'--phase','avif-confirmation'],capture_output=True,text=True)
            self.assertEqual(cli.returncode,3,cli.stdout+cli.stderr)

    def test_order_profile_counts_identity_and_source_proof_fail_closed(self):
        for mutation in ['order','profile','count','identity','guard','extra']:
            with self.subTest(mutation=mutation),tempfile.TemporaryDirectory() as temporary:
                root=Path(temporary).resolve();prepare(root)
                path=root/'avif-confirmation-candidate/codec-staging.json';r=json.loads(path.read_text())
                if mutation=='order':r['backingHalfSecondAfterFinalCycle']['standard']['observedAtUptimeSeconds']=201
                if mutation=='profile':r['profile']='staging-2048x1536'
                if mutation=='count':r['cycles'].pop()
                if mutation=='identity':r['helperVerifiedSHA256']='0'*64
                if mutation=='guard':(root/'source-guard-before.json').unlink()
                if mutation=='extra':
                    (root/'unapproved').mkdir();(root/'unapproved/codec-staging.json').write_text(json.dumps(r))
                path.write_text(json.dumps(r))
                with self.assertRaises(m.EvidenceError):m.run(root,'avif-confirmation')

    def test_source_guard_rejects_native_byte_changes_and_added_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary).resolve()
            for directory in ['Sources','Tests','scripts']:(root/directory).mkdir()
            for name in ['Sources/native.swift','Tests/native.swift','Package.swift','scripts/package.sh']:(root/name).write_text('fixed bytes\n')
            subprocess.run(['git','init','-q',str(root)],check=True)
            subprocess.run(['git','-C',str(root),'add','.'],check=True)
            subprocess.run(['git','-C',str(root),'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','fixture'],check=True)
            base=subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip()
            tree=subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD^{tree}'],text=True).strip()
            with patch.object(guard,'BASE',base),patch.object(guard,'TREE',tree):
                self.assertTrue(guard.verify(root)['nativeSourceBytesUnchanged'])
                (root/'Sources/native.swift').write_text('changed native bytes\n')
                with self.assertRaises(ValueError):guard.verify(root)
                (root/'Sources/native.swift').write_text('fixed bytes\n');(root/'Sources/extra.swift').write_text('extra\n')
                with self.assertRaises(ValueError):guard.verify(root)

    def test_workflow_has_no_native_test_rebuild_and_keeps_full_matrix_separate(self):
        workflow=(HERE.parent/'.github/workflows/macos.yml').read_text()
        job=workflow.split('\n  codec-avif-confirmation:\n',1)[1]
        self.assertIn('PICSHOT_PACKAGE_APP_ONLY=1',job)
        self.assertIn('--phase avif-confirmation',job)
        self.assertNotIn('swift test',job);self.assertNotIn('--build-tests',job)
        self.assertNotIn('--phase product',job);self.assertNotIn('--phase export',job)
        self.assertEqual(job.count('--phase avif-confirmation'),1)
        self.assertIn('--timeout-seconds 1300',job)
        self.assertIn('check-avif-confirmation-source.py',job)

if __name__=='__main__':unittest.main()
