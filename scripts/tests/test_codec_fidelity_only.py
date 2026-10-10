import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from test_check_codec_staging_comparison import m, report, preflight

HERE=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('defaults',HERE/'check-codec-staging-defaults.py')
defaults=importlib.util.module_from_spec(spec);spec.loader.exec_module(defaults)

def sha(data):return hashlib.sha256(data).hexdigest()

def base(arm,mode,pid,width=768,height=576):
    r=report(arm)
    for key in ['warmups','cycles']:r.pop(key)
    r.update(comparisonMode=mode,processIdentifier=pid,sourceWidth=width,sourceHeight=height,
             profile='staging-2048x1536' if width==2048 else 'installed-768x576')
    return r

def helper(r,digest='d'*64):
    return {'outcome':'succeeded','terminationStatus':0,'childExitConfirmed':True,'temporaryDirectoryRemoved':True,
        'childProcessIdentifier':r['processIdentifier']+1000,'helperExecutablePath':r['helperVerifiedPath'],
        'pngStagingMode':r['pngStagingMode'],'sourceSHA256':digest}

def store(root,name,r):
    d=root/name;d.mkdir(exist_ok=True)
    (d/'codec-staging.json').write_text(json.dumps(r))
    (d/'launch.json.launcher.json').write_text(json.dumps({'status':'exited','launcherExitCode':0,'ownedExitConfirmed':True,
        'launchedIdentityMatches':True,'processIdentifier':r['processIdentifier'],'launchedAppPath':r['bundlePath'],
        'launchedExecutablePath':r['bundlePath']+'/Contents/MacOS/PicShot'}))

def small_evidence(root):
    preflight(root,report('control'),'fidelity-only');pixels=bytes(768*576*4)
    for ordinal,arm in enumerate(['control','candidate']):
        r=base(arm,'evidence',10+ordinal);r.update(status='preserved',sourceSHA256=sha(pixels),entries=[])
        directory=root/f'evidence-small-{arm}';directory.mkdir();(directory/'source.rgba').write_bytes(pixels)
        validation=base(arm,'validate',20+ordinal);validation.update(status='validated',producerPID=r['processIdentifier'],independentValidationProcess=True,helperLaunches=0,entries=[])
        for fmt in ['webp','avif']:
            stage=b'actual stage '+fmt.encode();final=b'actual final '+fmt.encode()
            (directory/f'actual-staged-{fmt}.png').write_bytes(stage);(directory/f'actual-final.{fmt}').write_bytes(final)
            (directory/f'actual-preview-{fmt}.rgba').write_bytes(pixels)
            r['entries'].append({'format':fmt,'stagedSHA256':sha(stage),'stagedBytes':len(stage),'finalSHA256':sha(final),
                'finalBytes':len(final),'previewSHA256':sha(pixels),'previewBytes':len(pixels),'previewWidth':768,'previewHeight':576,
                'helper':helper(r,sha(stage))})
            validation['entries'].append({'format':fmt,'allPixelsAndAlphaCompared':True,'previewCompared':True,'stagedCompared':True,
                'previewWidth':768,'previewHeight':576,'decodedBytes':len(pixels),'previewValidatedBytes':len(pixels),
                'finalSHA256':sha(final),'stagedSHA256':sha(stage)})
        store(root,f'evidence-small-{arm}',r);store(root,f'validate-small-{arm}',validation)

class FidelityOnlyTests(unittest.TestCase):
    def test_real_specimens_are_checked_without_false_measured_binding(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp).resolve();small_evidence(root)
            result=m.evidence_checks(root,'small',bind_measured=False)
            self.assertTrue(result['actualStagedFinalPreviewBytesMatch'])
            self.assertFalse(result['sameRunMeasuredCellBinding']);self.assertFalse(result['allMeasuredDigestsBound'])
            self.assertEqual(result['measuredCellCount'],0)
            with self.assertRaises(m.EvidenceError):m.evidence_checks(root,'small')
            (root/'evidence-small-candidate/actual-final.avif').write_bytes(b'changed')
            with self.assertRaises(m.EvidenceError):m.evidence_checks(root,'small',bind_measured=False)

    def test_missing_format_or_validator_pixel_binding_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp).resolve();small_evidence(root)
            path=root/'validate-small-candidate/codec-staging.json';original=json.loads(path.read_text())
            for change in ['empty','hash','pixels','geometry']:
                r=copy.deepcopy(original)
                if change=='empty':r['entries']=[]
                if change=='hash':r['entries'][0]['stagedSHA256']='0'*64
                if change=='pixels':r['entries'][0]['allPixelsAndAlphaCompared']=False
                if change=='geometry':r['entries'][0]['previewWidth']=1024
                path.write_text(json.dumps(r))
                with self.subTest(change=change),self.assertRaises(m.EvidenceError):m.evidence_checks(root,'small',bind_measured=False)

    def test_standalone_summary_cannot_promote_or_inherit_historical_summaries(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp).resolve();preflight(root,report('control'),'fidelity-only');pid=100
            for mode in ['evidence','validate']:
                for profile in ['small','large']:
                    for arm in ['control','candidate']:
                        pid+=1;r=base(arm,mode,pid);r['status']='preserved' if mode=='evidence' else 'validated';store(root,f'{mode}-{profile}-{arm}',r)
            for arm in ['control','candidate']:
                pid+=1;r=base(arm,'interruptions',pid);r.update(status='passed',closeDuringHelper={'progressTriggeredClose':True,'lateResultSuppressed':True,'controllerReleased':True,'helper':helper(r)},formats=[
                    {'format':f,'inFlightFormatQualityChange':True,'realPixelsAndAlphaVerified':True,'sameByteSave':True,'childExitConfirmed':True,'temporaryDirectoryRemoved':True} for f in ['WebP','AVIF']]);store(root,'interruptions-'+arm,r)
            with patch.object(m,'evidence_checks',return_value={'status':'passed','sameRunMeasuredCellBinding':False,'measuredCellCount':0}) as checks:
                result=m.run(root,'fidelity-only');self.assertFalse(result['promotionReady']);self.assertFalse(result['historicalMemoryQualification']);self.assertFalse(result['sameRunMeasuredCellBinding'])
                self.assertTrue(all(call.kwargs=={'bind_measured':False} for call in checks.call_args_list))
                (root/'product-summary.json').write_text('{}')
                with self.assertRaises(m.EvidenceError):m.run(root,'fidelity-only')

    def test_phase_reuses_exact_ten_fidelity_cells_and_no_measurements(self):
        script=(HERE/'codec-staging-comparison.sh').read_text();case=script.split('case "$phase" in\n',1)[1].split('\nesac',1)[0]
        output=subprocess.check_output(['bash','-c','phase=fidelity-only\nroot=/fixture\nrun() { printf "%s\\n" "$*"; }\ncase "$phase" in\n'+case+'\nesac'],text=True).splitlines()
        self.assertEqual(len(output),10)
        self.assertTrue(all(line.split()[1] in ['evidence','validate','interruptions'] for line in output))
        self.assertEqual(sum(' validate ' in line for line in output),4)
        self.assertEqual(sum(' evidence ' in line for line in output),4)
        self.assertEqual(sum(' interruptions ' in line for line in output),2)

    def test_ordinary_installed_default_route_cannot_be_a_diagnostic_override(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp).resolve();prepared={'status':'prepared','sourceCommit':'a'*40,'profile':'installed-768x576','processIdentifier':1,'inputs':[]}
            pid=1
            for fmt,route in [('webp','verifiedBytesOnly'),('avif','legacyPreview')]:
                original=report('candidate');original['pngStagingMode']=route;h=helper(original);h.pop('sourceSHA256')
                prepared['inputs'].append({'format':fmt,'helper':h})
                for mode in ['export-only','decode-only','combined']:
                    pid+=1;r={'status':'observed','sourceCommit':'a'*40,'format':fmt,'mode':mode,'profile':'installed-768x576','sourceWidth':768,'sourceHeight':576,
                        'warmupCycles':2,'measuredCycles':12,'warmups':[{'helper':h}]*2,'cycles':[{'helper':h}]*12,'temporaryDirectoryRemoved':True,
                        'fixtureEncodingTasksActive':0,'activeControllersAfterAllCycles':0,'queuedOrRunningJobsAfterAllCycles':0,
                        'bundlePath':original['bundlePath'],'processIdentifier':pid}
                    d=root/fmt/mode;d.mkdir(parents=True);(d/'launch.json').write_text(json.dumps(r))
            (root/'prepared').mkdir();(root/'prepared/launch.json').write_text(json.dumps(prepared))
            expected={'webp':'verifiedBytesOnly','avif':'legacyPreview'}
            result=defaults.check(root,'a'*40,expected);self.assertEqual(len(result['observedJobs']),58);self.assertFalse(result['promotionReady'])
            with self.assertRaises(ValueError):defaults.check(root,'a'*40,{'webp':'verifiedBytesOnly','avif':'verifiedBytesOnly'})
            p=root/'avif/export-only/launch.json';r=json.loads(p.read_text());original=copy.deepcopy(r)
            r['cycles'][0]['helper']['sourceSHA256']='f'*64;p.write_text(json.dumps(r))
            with self.assertRaises(ValueError):defaults.check(root,'a'*40,expected)
            original['arm']='candidate';p.write_text(json.dumps(original))
            with self.assertRaises(ValueError):defaults.check(root,'a'*40,expected)

    def test_installed_proposal_keeps_new_media_out_of_existing_QA_artifact(self):
        proposal=(HERE/'codec-fidelity-installed-steps.yml').read_text();wrapper=(HERE/'codec-fidelity-installed.sh').read_text()
        self.assertIn('PicShot-0.19.1-macos-',proposal);self.assertIn('dist/codec-fidelity-standalone',proposal)
        self.assertNotIn('dist/evidence/codec-fidelity',proposal)
        self.assertIn('dist/codec-fidelity-metadata/outer.log',proposal)
        self.assertNotIn('dist/codec-fidelity-only.log',proposal)
        self.assertIn('ARM 318, Intel 346',proposal)
        self.assertIn('--timeout-seconds 6240',proposal)
        self.assertIn('--phase fidelity-only',wrapper)
        self.assertIn('"$root" != "$PWD/dist/evidence/"*',wrapper)
        self.assertNotIn('PICSHOT_PACKAGE_APP_ONLY',wrapper)

if __name__=='__main__':unittest.main()
