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
        payload=json.loads((ROOT/'scripts/save-payload-native-tests.json').read_text())
        scroll=list(C.SCROLL_CHAIN_ADDITIONS)
        preserved_payload=set(payload['focused'])-set(payload['added'])
        fake=sorted(added+list(C.SCROLL_RECOVERY_ADDITIONS)+scroll+payload['focused']+
                    ['PicShotTests.UnrelatedTests/test'+str(i) for i in range(2303-len(preserved_payload))])
        self.assertEqual(len(fake),C.CURRENT_NATIVE_INVENTORY[0])
        self.assertEqual(fake,sorted(set(fake)))
        self.assertEqual(len(set(fake)-set(added)-set(C.SCROLL_RECOVERY_ADDITIONS)-set(scroll)-set(payload['added'])),2303)
        with patch.object(C,'read',side_effect=lambda path: (ROOT/path).read_bytes()),self.assertRaisesRegex(ValueError,'Accepted248'):
            C.text_script_additions(fake)
        for method in scroll:
            renamed_class='PicShotTests.UnrecordedScrollChainTests/'+method.split('/')[1]
            for label,changed in (
                    ('missing',[name for name in fake if name != method]),
                    ('renamed',sorted(name+'Renamed' if name == method else name for name in fake)),
                    ('new class',sorted(renamed_class if name == method else name for name in fake))):
                with self.subTest(method=method,mutation=label),self.assertRaisesRegex(ValueError,'Existing-image chain additions are missing or renamed'):
                    C.text_script_additions(changed)
        for cls in sorted({name.split('/')[0] for name in scroll}):
            changed=sorted(fake+[cls+'/testUnrecordedMethod'])
            with self.subTest(unrecorded_class=cls),self.assertRaisesRegex(ValueError,'Existing-image chain class has an unrecorded method'):
                C.text_script_additions(changed)
        recovery=C.SCROLL_RECOVERY_ADDITIONS[0]
        for changed in ([name for name in fake if name != recovery],
                        sorted(name+'Renamed' if name == recovery else name for name in fake)):
            with patch.object(C,'read',side_effect=lambda path: (ROOT/path).read_bytes()),self.assertRaisesRegex(ValueError,'Explicit264'):
                C.text_script_additions(changed)
        for bad in (added[:-1],added+[added[0]],list(reversed(added)),
                    sorted(added[:-1]+['PicShotTests.TextScriptSyntheticTests/testForgedMethod'])):
            with patch.object(C,'read',side_effect=lambda path: json.dumps(bad).encode() if path.name=='text-script-integration-tests.json' else (ROOT/path).read_bytes()),self.assertRaises(ValueError):
                C.text_script_additions(fake)

    def test_inventory_rejects_count_and_class_preserving_baseline_rename(self):
        # Reuse the portable source census; native discovery remains a separate CI gate.
        spec=importlib.util.spec_from_file_location('native_inventory_fixture',ROOT/'scripts/tests/test_native_test_shards.py')
        native=importlib.util.module_from_spec(spec);spec.loader.exec_module(native)
        inventory=native.NativeWorkflowRoutingTests().current_source_inventory()
        added=json.loads((ROOT/'scripts/text-script-integration-tests.json').read_text())
        excluded=set(added)|set(C.SCROLL_RECOVERY_ADDITIONS)|set(C.SCROLL_CHAIN_ADDITIONS)
        baseline=next(name for name in inventory if name not in excluded and name.split('/')[0] not in C.SAVE_PAYLOAD_CLASSES)
        changed=sorted(name+'Renamed' if name == baseline else name for name in inventory)
        self.assertEqual(len(changed),len(inventory))
        self.assertEqual(len(set(changed)),len(inventory))
        self.assertEqual({name.split('/')[0] for name in changed},{name.split('/')[0] for name in inventory})
        with patch.object(C,'read',side_effect=lambda path: (ROOT/path).read_bytes()):
            self.assertEqual(C.text_script_additions(inventory),set(added))
            with self.assertRaisesRegex(ValueError,'Accepted248 native IDs changed'):
                C.text_script_additions(changed)


if __name__=='__main__':
    unittest.main()
