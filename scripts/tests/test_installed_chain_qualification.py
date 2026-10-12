"""Portable final-receipt/archive contracts; synthetic bytes are never native proof."""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('installed_chain_contract', ROOT/'scripts/check-experimental-scroll-interactions.py')
C = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(C)
SOURCE = dict(sourceCommit='a'*40, build='246', version='0.22.0', architecture='arm64',
              executableSHA256='b'*64, plistSHA256='c'*64, buildInfoSHA256='d'*64)


def prepare():
    formats = dict(status='passed', exactInstalledBinaryIdentity=True, formats={})
    for extension in ('zip', 'dmg'):
        root = Path('dist/evidence')/extension/'capture-chain'
        root.mkdir(parents=True)
        app = str(Path('dist/installer-smoke.synthetic')/extension/'PicShot.app')
        app = str(Path(app).resolve())
        installed = dict(bundlePath=app, buildVersion=SOURCE['build'],
                         **{key: value for key, value in SOURCE.items() if key != 'build'})
        formats['formats'][extension] = installed
        hashes = {}
        for name in C.CHAIN_EVIDENCE_FILES:
            data = ('portable schema input only: '+name).encode()
            (root/name).write_bytes(data)
            hashes[name] = hashlib.sha256(data).hexdigest()
        receipt = dict(schemaVersion=1, status='passed', installerAcceptance=False,
            realScreenCaptureAcceptance=False, memoryQualification=False, exactDecodedOutputPixels=True,
            savedReceiptPhysicalBytesVerified=True, unchangedMetadataOnlyCatalogVerified=True,
            nativeOwnedActionRoute='PortableSettingsUIPreviewFixture.click: owned NSButton.mouseDown with queued mouseUp; NSTableView: owned-nextEvent-sendEvent',
            scope='Installed native controls and output recipients with injected acquisition; bounded ownership observations only',
            sourceIdentity=dict(SOURCE, bundlePath=app, executablePath=app+'/Contents/MacOS/PicShot'), evidenceSHA256=hashes)
        C.save(root/'capture-chain-receipt.json', receipt)
        for stem, timeout, command in (
            ('launch', 270, ['swift', 'scripts/launch-smoke-app.swift', app, str((root/'demo.json').resolve())]),
            ('check', 120, ['python3', 'scripts/check-capture-chain-demo.py', '--report',
                            str((root/'demo.json').resolve()), '--source', SOURCE['sourceCommit']])):
            C.save(root/(stem+'-report.json'), dict(schema_version=1, status='exited', child_returncode=0,
                exit_code=0, cancel_signal=None, sigterm_sent=False, sigkill_sent=False, descendant_cleanup=False,
                termination_reason='exited', log_truncated=False, timeout_seconds=timeout, grace_seconds=10,
                duration_seconds=20, max_log_bytes=1048576, command=command, log_bytes=0, output_bytes=0))
            (root/(stem+'.log')).write_bytes(b'')
    C.save(Path('dist/evidence/installed-format-identity.json'), formats)
    C.save(C.ROOT/'source-identity.json', SOURCE)
    return formats


class InstalledChainTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.previous = Path.cwd()
        os.chdir(self.temp.name)
        self.formats = prepare()

    def tearDown(self):
        os.chdir(self.previous)
        self.temp.cleanup()

    def test_both_retained_receipts_bind_distinct_actual_formats(self):
        result = C.installed_capture_chains(SOURCE, self.formats)
        self.assertEqual(set(result), {'zip', 'dmg'})
        self.assertNotEqual(result['zip']['sourceIdentity']['bundlePath'], result['dmg']['sourceIdentity']['bundlePath'])
        for row in result.values():
            self.assertEqual(set(row['evidenceSHA256']), C.CHAIN_EVIDENCE_FILES)
            self.assertEqual(len(row['evidenceSHA256']), 27)
            self.assertEqual(row['sourceIdentity']['sourceCommit'], SOURCE['sourceCommit'])
            self.assertEqual(set(row['boundedCommandSHA256']), {'launch-report.json', 'launch.log', 'check-report.json', 'check.log'})

    def test_every_receipt_and_source_identity_field_is_required(self):
        for extension in ('zip', 'dmg'):
            path = Path('dist/evidence')/extension/'capture-chain/capture-chain-receipt.json'
            original = C.load(path)
            for parent in ((), ('sourceIdentity',)):
                row = original['sourceIdentity'] if parent else original
                for key in row:
                    value = copy.deepcopy(original)
                    del (value['sourceIdentity'] if parent else value)[key]
                    C.save(path, value)
                    with self.subTest(format=extension, parent=parent, key=key), self.assertRaises(ValueError):
                        C.installed_capture_chains(SOURCE, self.formats)
                    C.save(path, original)

    def test_changed_format_source_hash_and_prohibited_acceptance_fail(self):
        for extension in ('zip', 'dmg'):
            for key in ('sourceCommit', 'buildVersion', 'version', 'architecture', 'executableSHA256', 'plistSHA256', 'buildInfoSHA256', 'bundlePath'):
                formats = copy.deepcopy(self.formats); formats['formats'][extension][key] = 'wrong'
                with self.subTest(format=extension, key=key), self.assertRaises(ValueError):
                    C.installed_capture_chains(SOURCE, formats)
            path = Path('dist/evidence')/extension/'capture-chain/capture-chain-receipt.json'; original=C.load(path)
            for key in ('installerAcceptance', 'realScreenCaptureAcceptance', 'memoryQualification', 'exactDecodedOutputPixels'):
                value=copy.deepcopy(original); value[key]=not value[key];C.save(path,value)
                with self.subTest(format=extension, claim=key), self.assertRaises(ValueError):
                    C.installed_capture_chains(SOURCE,self.formats)
            C.save(path, original)
        for extension in ('zip', 'dmg'):
            formats=copy.deepcopy(self.formats);del formats['formats'][extension]
            with self.assertRaises(ValueError): C.installed_capture_chains(SOURCE,formats)

    def test_evidence_cannot_change_disappear_escape_or_be_symlinked(self):
        root=Path('dist/evidence/zip/capture-chain');path=root/'chain-pin-reloaded.png'; original=path.read_bytes()
        path.write_bytes(b'changed')
        with self.assertRaises(ValueError):C.installed_capture_chains(SOURCE,self.formats)
        path.unlink()
        with self.assertRaises(ValueError):C.installed_capture_chains(SOURCE,self.formats)
        outside=Path('outside');outside.write_bytes(original);path.symlink_to(outside.resolve())
        with self.assertRaises(ValueError):C.installed_capture_chains(SOURCE,self.formats)
        path.unlink();path.write_bytes(original)
        receipt_path=root/'capture-chain-receipt.json';receipt=C.load(receipt_path)
        receipt['evidenceSHA256']['../outside']=receipt['evidenceSHA256'].pop('chain-pin-reloaded.png')
        C.save(receipt_path,receipt)
        with self.assertRaises(ValueError):C.installed_capture_chains(SOURCE,self.formats)

    def test_every_bounded_runner_field_is_required(self):
        for stem in ('launch','check'):
            path=Path('dist/evidence/dmg/capture-chain')/(stem+'-report.json');original=C.load(path)
            for key in original:
                changed=copy.deepcopy(original);del changed[key];C.save(path,changed)
                with self.subTest(stem=stem,key=key),self.assertRaises(ValueError):
                    C.installed_capture_chains(SOURCE,self.formats)
            C.save(path,original)

    def test_timeouts_cleanup_command_source_and_log_changes_fail(self):
        path=Path('dist/evidence/zip/capture-chain/check-report.json');original=C.load(path)
        for key,bad in [('timeout_seconds',121),('grace_seconds',11),('sigterm_sent',True),
                        ('cleanup_errors',['unfinished']),('log_truncated',True),('max_log_bytes',1048577),
                        ('command',['python3','wrong.py']),('log_bytes',True),('output_bytes',1)]:
            changed=copy.deepcopy(original);changed[key]=bad;C.save(path,changed)
            with self.subTest(key=key),self.assertRaises(ValueError):C.installed_capture_chains(SOURCE,self.formats)
        C.save(path,original)
        (path.parent/'check.log').write_bytes(b'unbound log')
        with self.assertRaises(ValueError):C.installed_capture_chains(SOURCE,self.formats)

    def test_installed_chain_launch_stays_within_original300_second_ceiling(self):
        path=Path('dist/evidence/zip/capture-chain/launch-report.json');original=C.load(path)
        self.assertEqual(original['timeout_seconds'],270)
        self.assertEqual(original['grace_seconds'],10)
        self.assertLess(original['timeout_seconds']+original['grace_seconds'],300)
        for timeout in (240,269,271,300,600,660):
            changed=copy.deepcopy(original);changed['timeout_seconds']=timeout;C.save(path,changed)
            with self.subTest(timeout=timeout),self.assertRaises(ValueError):
                C.installed_capture_chains(SOURCE,self.formats)
        C.save(path,original)
        smoke=(ROOT/'scripts/smoke.sh').read_text()
        chain=smoke.split('  # Check this exact installed format',1)[1].split('\ndone\n',1)[0]
        self.assertIn('--timeout-seconds 270 --grace-seconds 10',chain)
        self.assertNotIn('--timeout-seconds 660',chain)
        workflow=(ROOT/'.github/workflows/macos.yml').read_text()
        contracts=workflow.split('      - name: Check experimental scrolling interaction evidence contract',1)[1].split('      - name:',1)[0]
        self.assertIn('python3 -m unittest discover -s scripts/tests -p test_capture_chain_launcher_timeout.py',contracts)
        self.assertIn('python3 -O -m unittest discover -s scripts/tests -p test_capture_chain_launcher_timeout.py',contracts)

    def test_archives_are_separate_bounded_and_include_original_identities(self):
        C.archive_capture_chains()
        for extension in ('zip','dmg'):
            archive=Path('dist/capture-chain-installed-evidence')/(extension+'.zip')
            self.assertLess(archive.stat().st_size,20*1024**2-65536)
            with zipfile.ZipFile(archive) as bundle:
                self.assertIn(f'dist/evidence/{extension}/capture-chain/capture-chain-receipt.json',bundle.namelist())
                self.assertIn('dist/evidence/installed-format-identity.json',bundle.namelist())
                self.assertIn(str(C.ROOT/'source-identity.json'),bundle.namelist())
                other='dmg' if extension=='zip' else 'zip'
                self.assertFalse(any(f'/evidence/{other}/' in name for name in bundle.namelist()))
        with self.assertRaises(ValueError):C.archive_capture_chains()

    def test_archive_rejects_nested_symlinked_and_oversized_evidence(self):
        root=Path('dist/evidence/zip/capture-chain')
        nested=root/'nested';nested.mkdir()
        with self.assertRaises(ValueError):C.archive_capture_chains()
        nested.rmdir();nested.symlink_to('demo.json')
        with self.assertRaises(ValueError):C.archive_capture_chains()
        nested.unlink();large=root/'large.png'
        with large.open('wb') as output:output.truncate(16*1024**2+1)
        with self.assertRaises(ValueError):C.archive_capture_chains()

    def test_original_failed227_memory_scope_and_every_ordinary_gate_stay_required(self):
        self.assertEqual(C.PRIOR_FAILURE,dict(runID='38130153505',build=227,warmRSSBytes=10780672,
            warmLimitBytes=9830400,lateThreeRSSBytes=5177344,lateLimitBytes=4915200,preserved=True))
        for key in ('installerAcceptance','fullMemoryQualification','testingPackageEligible','partialMemoryQualification',
                    'stableInstallerReplacement','disputedResourceCellRerun','scrollingResourceClassifierRun','realScreenCaptureAcceptance'):
            self.assertIs(C.FLAGS[key],False)
        self.assertEqual(set(C.REQUIRED_GATES), {f'current_gate_{n:02d}' for n in range(1,26)} |
                         {'experimental_scroll_contract','experimental_scroll_prepare','experimental_scroll_demo','experimental_scroll_receipt'})
        steps={name:dict(outcome='success',conclusion='success') for name in C.REQUIRED_GATES}
        steps.update({name:dict(outcome='skipped',conclusion='skipped') for name in
            ('live_scroll_resource','scroll_testing_classification','scroll_testing_contract')})
        C.validate_outcomes(steps)
        steps['live_scroll_resource']=dict(outcome='success',conclusion='success')
        with self.assertRaises(ValueError):C.validate_outcomes(steps)

    def test_existing_installed_loop_checks_both_bundles_before_cleanup_and_final_requires_receipts(self):
        smoke=(ROOT/'scripts/smoke.sh').read_text()
        block=smoke.split('for format in zip dmg;do',1)[1].split('\ndone\n',1)[0]
        self.assertIn('chain_evidence="$PWD/dist/evidence/$format/capture-chain"',block)
        self.assertIn('PICSHOT_CAPTURE_CHAIN_DEMO_ONLY=1 python3 scripts/run-bounded-command.py',block)
        self.assertIn('-- swift scripts/launch-smoke-app.swift "$app" "$chain_evidence/demo.json"',block)
        self.assertIn('-- python3 scripts/check-capture-chain-demo.py',block)
        self.assertNotIn('export PICSHOT_CAPTURE_CHAIN_DEMO_ONLY',smoke)
        self.assertIn('editable-product-installed-default.sh',smoke.split('\ndone\n')[-1])
        checker=(ROOT/'scripts/check-experimental-scroll-interactions.py').read_text().split('def final():',1)[1].split('\ndef archive():',1)[0]
        self.assertIn('chain_receipts = installed_capture_chains(source, formats)',checker)
        self.assertIn('currentSourceInstalledChainFormats=chain_receipts',checker)
        self.assertIn('resourceFailurePreserved=PRIOR_FAILURE',checker)
        workflow=(ROOT/'.github/workflows/macos.yml').read_text()
        for extension in ('zip','dmg'):
            self.assertIn('path: dist/capture-chain-installed-evidence/'+extension+'.zip',workflow)


if __name__=='__main__':unittest.main()
