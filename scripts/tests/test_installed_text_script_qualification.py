"""Portable receipt/archive mutation tests, never native acceptance evidence."""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('text_qualification', ROOT/'scripts/check-experimental-scroll-interactions.py')
C = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(C)
SOURCE = dict(sourceCommit='a'*40, build='256', version='0.22.0', architecture='arm64',
              executableSHA256='b'*64, plistSHA256='c'*64, buildInfoSHA256='d'*64)


def prepare():
    proof = dict(schemaVersion=1, sourceCommit=SOURCE['sourceCommit'], version=SOURCE['version'],
        build=SOURCE['build'], architectures=['arm64'], executableSHA256=SOURCE['executableSHA256'],
        appInfoPlistSHA256=SOURCE['plistSHA256'], buildInfoSHA256=SOURCE['buildInfoSHA256'],
        appSignatureVerified=True, sameTeamIdentifierVerified=True, relocationVerified=True,
        helperEntitlementsVerifiedAfterOuterSigning=True, helperSignedInfoPlistVerifiedAfterOuterSigning=True,
        installedRuntimeAcceptanceVerified=False,
        helper=dict(path='Contents/Helpers/PicShotTextScriptHelper', identifier='com.picshot.TextScriptHelper',
            entitlements={'com.apple.security.app-sandbox':True}, strictSignatureVerified=True,
            sha256='e'*64, cdHash='f'*40))
    C.save(Path('dist/text-script-package-proof.json'), proof)
    formats = dict(status='passed', exactInstalledBinaryIdentity=True, formats={})
    for extension in ('zip', 'dmg'):
        root = Path('dist/evidence')/extension/'text-script'
        root.mkdir(parents=True)
        app = str((Path('dist/installer-smoke.synthetic')/extension/'PicShot.app').resolve())
        formats['formats'][extension] = dict(bundlePath=app, buildVersion=SOURCE['build'],
            **{key: value for key, value in SOURCE.items() if key != 'build'})
        hashes = {}
        for name in C.TEXT_SCRIPT_EVIDENCE_FILES:
            path = root/('package-proof.json' if name == 'package-proof' else name)
            path.write_bytes(Path('dist/text-script-package-proof.json').read_bytes() if name == 'package-proof'
                             else ('portable fixture only: '+name).encode())
            hashes[name] = C.sha(path)
        receipt = dict(schemaVersion=1, status='passed', installerAcceptance=False,
            realScreenCaptureAcceptance=False, original227MemoryAcceptance=False, hardMemoryCapClaimed=False,
            exactGeneratedTextOutputVerified=True, onceOnlyCaptureOCRTransformVerified=True,
            checkedCopyRetryAndCloseVerified=True, sourceAndFinalPackageBound=True,
            scope='Installed saved editor and region/OCR/script/Copy owner; generated acquisition, actual Apple Vision and signed production helper, checked private clipboard',
            sourceIdentity=dict(appPath=app, helperSHA256='e'*64, helperCDHash='f'*40,
                **{key: SOURCE[key] for key in ('sourceCommit','build','version','architecture','executableSHA256')}),
            evidenceSHA256=hashes)
        C.save(root/'text-script-receipt.json', receipt)
        for stem, timeout, command in (
            ('proof',180,['python3','scripts/verify-text-script-package.py','--app',app,'--source',SOURCE['sourceCommit'],
                '--report',str((root/'package-proof.json').resolve()),'--verify-relocation']),
            ('launch',270,['swift','scripts/launch-smoke-app.swift',app,str((root/'text-script-installed.json').resolve())]),
            ('check',120,['python3','scripts/check-text-script-demo.py','--report',str((root/'text-script-installed.json').resolve()),
                '--source',SOURCE['sourceCommit'],'--package-proof',str((root/'package-proof.json').resolve()),'--source-root',str(Path.cwd())])):
            C.save(root/(stem+'-report.json'),dict(schema_version=1,status='exited',child_returncode=0,exit_code=0,
                cancel_signal=None,sigterm_sent=False,sigkill_sent=False,descendant_cleanup=False,
                termination_reason='exited',log_truncated=False,timeout_seconds=timeout,grace_seconds=10,
                duration_seconds=20,max_log_bytes=1048576,command=command,log_bytes=0,output_bytes=0))
            (root/(stem+'.log')).write_bytes(b'')
    C.save(Path('dist/evidence/installed-format-identity.json'),formats)
    C.save(C.ROOT/'source-identity.json',SOURCE)
    return formats


class InstalledTextScriptQualificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.previous = Path.cwd()
        os.chdir(self.temporary.name)
        self.formats = prepare()

    def tearDown(self):
        os.chdir(self.previous)
        self.temporary.cleanup()

    def test_both_actual_format_receipts_bind_helper_and_app(self):
        result = C.installed_text_scripts(SOURCE,self.formats)
        self.assertEqual(set(result),{'zip','dmg'})
        self.assertEqual(len(C.TEXT_SCRIPT_EVIDENCE_FILES),26)
        self.assertNotEqual(result['zip']['sourceIdentity']['appPath'],result['dmg']['sourceIdentity']['appPath'])
        for value in result.values():
            self.assertEqual(value['sourceIdentity']['helperSHA256'],'e'*64)
            self.assertEqual(len(value['boundedCommandSHA256']),6)

    def test_every_receipt_identity_and_claim_is_required(self):
        path=Path('dist/evidence/zip/text-script/text-script-receipt.json');original=C.load(path)
        for key in original:
            value=copy.deepcopy(original);del value[key];C.save(path,value)
            with self.subTest(key=key),self.assertRaises(ValueError):C.installed_text_scripts(SOURCE,self.formats)
        C.save(path,original)
        for key in original['sourceIdentity']:
            value=copy.deepcopy(original);value['sourceIdentity'][key]='different';C.save(path,value)
            with self.subTest(identity=key),self.assertRaises(ValueError):C.installed_text_scripts(SOURCE,self.formats)
        C.save(path,original)
        for key in ('installerAcceptance','realScreenCaptureAcceptance','original227MemoryAcceptance','hardMemoryCapClaimed'):
            value=copy.deepcopy(original);value[key]=True;C.save(path,value)
            with self.subTest(claim=key),self.assertRaises(ValueError):C.installed_text_scripts(SOURCE,self.formats)

    def test_missing_reused_or_changed_installer_identity_fails(self):
        for extension in ('zip','dmg'):
            value=copy.deepcopy(self.formats);del value['formats'][extension]
            with self.assertRaises(ValueError):C.installed_text_scripts(SOURCE,value)
            for key in self.formats['formats'][extension]:
                value=copy.deepcopy(self.formats);value['formats'][extension][key]='wrong'
                with self.subTest(key=key),self.assertRaises(ValueError):C.installed_text_scripts(SOURCE,value)

    def test_retained_proof_requires_exact_boolean_only_sandbox(self):
        path=Path('dist/text-script-package-proof.json');original=C.load(path)
        for entitlements in ({'com.apple.security.app-sandbox':1},
                             {'com.apple.security.app-sandbox':'true'},
                             {'com.apple.security.app-sandbox':False},
                             {'com.apple.security.app-sandbox':True,'com.apple.security.network.client':True}):
            value=copy.deepcopy(original);value['helper']['entitlements']=entitlements;C.save(path,value)
            with self.subTest(entitlements=entitlements),self.assertRaisesRegex(ValueError,'sole Boolean sandbox entitlement'):
                C.installed_text_scripts(SOURCE,self.formats)
        C.save(path,original)

    def test_changed_missing_or_symlinked_evidence_fails(self):
        root=Path('dist/evidence/dmg/text-script')
        for name in C.TEXT_SCRIPT_EVIDENCE_FILES:
            path=root/('package-proof.json' if name=='package-proof' else name);original=path.read_bytes()
            path.write_bytes(b'changed')
            with self.subTest(name=name),self.assertRaises(ValueError):C.installed_text_scripts(SOURCE,self.formats)
            path.unlink()
            with self.assertRaises(ValueError):C.installed_text_scripts(SOURCE,self.formats)
            outside=Path('outside');outside.write_bytes(original);path.symlink_to(outside.resolve())
            with self.assertRaises(ValueError):C.installed_text_scripts(SOURCE,self.formats)
            path.unlink();path.write_bytes(original)

    def test_bounded_commands_and_log_bytes_cannot_change(self):
        for stem in ('proof','launch','check'):
            path=Path('dist/evidence/zip/text-script')/(stem+'-report.json');original=C.load(path)
            for key in original:
                value=copy.deepcopy(original);del value[key];C.save(path,value)
                with self.subTest(stem=stem,key=key),self.assertRaises(ValueError):C.installed_text_scripts(SOURCE,self.formats)
            for key,bad in [('timeout_seconds',600),('command',['wrong']),('sigterm_sent',True),
                            ('log_truncated',True),('max_log_bytes',1048577),('output_bytes',1),('cleanup_errors',['pending'])]:
                value=copy.deepcopy(original);value[key]=bad;C.save(path,value)
                with self.subTest(stem=stem,key=key),self.assertRaises(ValueError):C.installed_text_scripts(SOURCE,self.formats)
            C.save(path,original)

    def test_each_archive_stays_separate_and_below_transfer_cap(self):
        C.archive_text_scripts()
        for extension in ('zip','dmg'):
            path=Path('dist/text-script-installed-evidence')/(extension+'.zip')
            self.assertLess(path.stat().st_size,20*1024**2-65536)
            with zipfile.ZipFile(path) as archive:
                self.assertIn('dist/text-script-package-proof.json',archive.namelist())
                self.assertIn('dist/evidence/'+extension+'/text-script/text-script-receipt.json',archive.namelist())
                other='dmg' if extension=='zip' else 'zip'
                self.assertFalse(any('/evidence/'+other+'/' in name for name in archive.namelist()))
        with self.assertRaises(ValueError):C.archive_text_scripts()

    def test_archive_rejects_unbounded_or_nested_input(self):
        root=Path('dist/evidence/zip/text-script');nested=root/'nested';nested.mkdir()
        with self.assertRaises(ValueError):C.archive_text_scripts()
        nested.rmdir()
        with (root/'oversized.png').open('wb') as output:output.truncate(16*1024**2+1)
        with self.assertRaises(ValueError):C.archive_text_scripts()

    def test_inventory_rejects_counts_without_exact_baseline_union(self):
        added=json.loads((ROOT/'scripts/text-script-integration-tests.json').read_text())
        fake=sorted(added+['PicShotTests.UnrelatedTests/test'+str(i) for i in range(2303)])
        with patch.object(C,'read',return_value=json.dumps(added).encode()),self.assertRaisesRegex(ValueError,'Accepted248'):
            C.text_script_additions(fake)
        for bad in (added[:-1],added+[added[0]],list(reversed(added)),
                    sorted(added[:-1]+['PicShotTests.TextScriptSyntheticTests/testForgedMethod'])):
            with patch.object(C,'read',return_value=json.dumps(bad).encode()),self.assertRaises(ValueError):
                C.text_script_additions(fake)


if __name__=='__main__':
    unittest.main()
