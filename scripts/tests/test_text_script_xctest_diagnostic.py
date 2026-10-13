"""Portable selection/identity/diagnostic-bound tests; never native evidence."""
import copy
from contextlib import nullcontext
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('editor_crash_diagnostic', ROOT/'scripts/diagnose-text-script-xctest.py')
D = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(D)


class TextScriptXCTestDiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.binding = dict(startUTC='2026-10-13T00:00:00+00:00',endUTC='2026-10-13T00:00:02+00:00',
            ownedIdentity=dict(pid=321,parentPID=123,groupID=321,uid=501,
                executable='/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/xctest',
                birthSeconds=1791849600,birthMicroseconds=100000))
        # Compute rather than assume the Unix date constant in portable fixtures.
        self.binding['ownedIdentity']['birthSeconds']=int(D.C.timestamp(self.binding['startUTC']).timestamp())
        self.body=dict(pid=321,parentPid=123,procName='xctest',procPath=self.binding['ownedIdentity']['executable'],
            procLaunch='2026-10-13T00:00:00.1000+00:00',captureTime='2026-10-13T00:00:01+00:00',
            exception=dict(type='EXC_BAD_ACCESS',signal='SIGSEGV'),termination=dict(namespace='SIGNAL',code=11),
            faultingThread=0,threads=[dict(frames=[dict(imageIndex=0,symbol='owned_symbol',imageOffset=1)],
                threadState=dict(registers='do not retain'))],usedImages=[dict(name='AppKit',uuid='synthetic',arch='arm64',
                path='/private/path',base=123)],asi='Do not retain application text',userID=501)

    def marker(self, phase, pid=321):
        return f'PICSHOT_TEXT_SCRIPT_LIFECYCLE phase={phase} pid={pid} running=0 active=0 policy=2 visible=-1'

    def test_crash_requires_exact_owned_pid_path_parent_and_birth(self):
        self.assertTrue(D.match_crash(self.body,self.binding))
        for key,value in [('pid',True),('pid',322),('parentPid',124),('procName','PicShotPackageTests'),
                          ('procPath','/foreign/xctest'),('procPath','/Applications/*/xctest'),
                          ('procLaunch','2026-10-13T00:00:00.2000+00:00'),
                          ('captureTime','2026-10-13T00:00:18+00:00')]:
            with self.subTest(key=key),self.assertRaises(ValueError):D.match_crash(dict(self.body,**{key:value}),self.binding)
        for key in ('procLaunch','captureTime'):
            value=copy.deepcopy(self.body);value[key]='2026-10-13T00:00:00'
            with self.assertRaises(ValueError):D.match_crash(value,self.binding)
        for parent in (None, True, 124):
            value=copy.deepcopy(self.body)
            if parent is None:del value['parentPid']
            else:value['parentPid']=parent
            with self.assertRaisesRegex(ValueError,'crash parent'):D.match_crash(value,self.binding)

    def test_extraction_keeps_only_os_cause_faulting_symbols_and_image_identity(self):
        value=D.crash_details(self.body)
        text=json.dumps(value)
        self.assertIn('EXC_BAD_ACCESS',text);self.assertIn('owned_symbol',text)
        for forbidden in ('Do not retain','threadState','registers','/private/path','userID','"base"'):
            self.assertNotIn(forbidden,text)
        self.body['threads'][0]['frames']*=100
        self.assertEqual(len(D.crash_details(self.body)['crashedThread']['frames']),32)

    def test_stale_reports_cannot_exhaust_owned_window_candidate_budget(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary).resolve()
            stamp=D.C.timestamp(self.binding['startUTC']).timestamp()
            for index in range(40):
                path=root/f'xctest-old-{index:02}.ips';path.write_bytes(b'old report must not be read')
                os.utime(path,(stamp-60,stamp-60))
            current=root/'xctest-current.ips'
            current.write_bytes((json.dumps({'bug_type':'309'})+'\n'+json.dumps(self.body)).encode())
            os.utime(current,(stamp+2,stamp+2))
            entries=list(os.scandir(root))
            entries.sort(key=lambda entry:entry.name=='xctest-current.ips')
            with patch.object(D.C,'open_directory',side_effect=lambda _:os.open(root,os.O_RDONLY|os.O_DIRECTORY)),\
                 patch.object(D.os,'scandir',side_effect=lambda _:nullcontext(entries)),\
                 patch.object(D.C,'read_at',wraps=D.C.read_at) as reads:
                result=D.collect_crash(self.binding)
                self.assertEqual(result['status'],'observed')
                self.assertEqual(reads.call_count,1)

    def test_phase_prefix_has_fixed_order_exact_pid_and_no_extra_content(self):
        lines=[self.marker(p) for p in D.PHASES]
        self.assertEqual(len(D.phase_markers('\n'.join(lines),321)),26)
        self.assertEqual(len(D.phase_markers('\n'.join(lines[:6]),321)),6)
        for invalid in ([self.marker(D.PHASES[0],322)],lines[:2]+[lines[0]],
                        [lines[0]+' content=private'],[self.marker('unknown')]):
            with self.assertRaises(ValueError):D.phase_markers('\n'.join(invalid),321)

    def test_selection_uses_exact_seventy_source_ids_and_current_discovery(self):
        names=json.loads((ROOT/'scripts/text-script-integration-tests.json').read_text())
        self.assertEqual(len(names),70)
        self.assertEqual(D.O.ids_digest(names),D.IDS_SHA256)
        self.assertEqual(D.C.sha((ROOT/'scripts/text-script-integration-tests.json').read_bytes()),D.SOURCE_IDS_SHA256)
        argv=D.O.command('/verified/xctest','/verified/PicShotPackageTests.xctest',names)
        self.assertEqual(argv[1],'-XCTest');self.assertEqual(argv[2].split(','),names)
        self.assertIn(D.METHOD,names)
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary).resolve();inventory=root/'inventory.log'
            inventory.write_text('\n'.join(names)+'\n')
            with self.assertRaisesRegex(ValueError,'Actual discovery'):
                D.selection(ROOT,inventory)

    def test_untracked_compilable_inputs_are_not_bound_to_a_clean_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary).resolve()
            def query(command,*args,**kwargs):
                if command==['git','rev-parse','HEAD']:return 'a'*40
                if command==['git','rev-parse','HEAD^{tree}']:return 'b'*40
                if '--untracked-files=all' in command:return '?? Sources/PicShot/Unexpected.swift\n'
                return ''
            with patch.object(D.O,'bounded_read',side_effect=query),self.assertRaisesRegex(ValueError,'build input'):
                D.source_guard(root,'a'*40)

    def test_owned_receipt_rejects_wrong_pid_path_cleanup_or_deadline(self):
        target=self.binding['ownedIdentity']
        process=dict(root=dict(pid=321,ownerPID=123,identity=target,bindingError=None,cleanupConfirmed=True,returnCode=-11),
            rootReturnCode=-11,timeoutSeconds=420,expectedCaptureSlots=[],captures=[],cleanupConfirmed=True,
            outputEOF=True,logTruncated=False,errors=[])
        identity=dict(xctestPath=target['executable'])
        self.assertEqual(D.verify_owned(process,identity),target)
        for key,value in [('timeoutSeconds',421),('cleanupConfirmed',False),('outputEOF',False),
                          ('logTruncated',True),('errors',['failure']),('expectedCaptureSlots',[180])]:
            with self.subTest(key=key),self.assertRaises(ValueError):D.verify_owned(dict(process,**{key:value}),identity)
        changed=copy.deepcopy(process);changed['root']['identity']['executable']='/wrong/xctest'
        with self.assertRaises(ValueError):D.verify_owned(changed,identity)

    def test_group_is_never_run_after_failed_single_method(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary).resolve();output=root/'evidence'
            (root/'inventory').write_text('mocked discovery input')
            args=['diagnostic','--source','a'*40,'--source-root',str(root),'--inventory',str(root/'inventory'),
                  '--directory',str(output)]
            names=[D.METHOD,'PicShotTests.TextScriptOtherTests/testOther']
            identity=dict(sourceCommit='a'*40)
            with patch.object(D.sys,'platform','darwin'),patch.object(D.sys,'argv',args),\
                 patch.object(D,'selection',return_value=(names,{})),\
                 patch.object(D,'launch_inputs',return_value=(identity,{})),\
                 patch.object(D,'source_guard',return_value='b'*40),\
                 patch.object(D,'run_phase',return_value=dict(status='failed')) as run:
                self.assertEqual(D.main(),1)
                self.assertEqual(run.call_count,1)
                self.assertEqual(run.call_args.args[:2],('single',[D.METHOD]))
            value=json.loads((output/'diagnostic.json').read_text())
            self.assertEqual(value['groupStatus'],'not-run')
            self.assertFalse(value['installerAcceptance']);self.assertTrue(value['diagnosticOnly'])

    def test_successful_single_runs_group_once_with_identical_bundle_inputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary).resolve();output=root/'evidence'
            (root/'inventory').write_text('mocked discovery input')
            args=['diagnostic','--source','a'*40,'--source-root',str(root),'--inventory',str(root/'inventory'),
                  '--directory',str(output)]
            names=[D.METHOD,'PicShotTests.TextScriptOtherTests/testOther'];identity=dict(sourceCommit='a'*40)
            with patch.object(D.sys,'platform','darwin'),patch.object(D.sys,'argv',args),\
                 patch.object(D,'selection',return_value=(names,{})),\
                 patch.object(D,'launch_inputs',return_value=(identity,{})),\
                 patch.object(D,'source_guard',return_value='b'*40),\
                 patch.object(D,'run_phase',side_effect=[dict(status='passed'),dict(status='failed')]) as run:
                self.assertEqual(D.main(),1)
                self.assertEqual(run.call_count,2)
                self.assertEqual(run.call_args_list[1].args[:2],('original70',names))
                self.assertIs(run.call_args_list[0].args[4],run.call_args_list[1].args[4])

    def test_diagnostic_workflow_keeps_original_caps_and_always_preserves_logs(self):
        workflow=(ROOT/'.github/workflows/macos.yml').read_text()
        job=workflow.split('  text-script-xctest-diagnostic:\n',1)[1].split('  text-script-runtime:\n',1)[0]
        for timeout in (840,540,60,1020):self.assertIn('--timeout-seconds '+str(timeout),job)
        self.assertIn('swift build --build-tests',job)
        self.assertNotIn('scripts/package.sh',job)
        self.assertNotIn('run-live-scroll-resource',job)
        self.assertEqual(job.count('if: always()'),2)
        self.assertIn("root.mkdir(parents=True,exist_ok=True)",job)
        self.assertIn("status=root/'archive-status.json'",job)
        self.assertIn("'dist/text-script-xctest-evidence.zip'",job)

    def test_archive_preserves_early_failure_logs_and_exact_plist_prefix(self):
        workflow=(ROOT/'.github/workflows/macos.yml').read_text()
        job=workflow.split('    - name: Bound editor diagnostic evidence without raw crash reports\n',1)[1]
        code=job.split("        python3 - <<'PY'\n",1)[1].split('\n        PY\n',1)[0]
        code='\n'.join(line[8:] for line in code.splitlines())
        previous=Path.cwd()
        with tempfile.TemporaryDirectory() as temporary:
            try:
                os.chdir(Path(temporary).resolve())
                exec(compile(code,'diagnostic-archive','exec'),{})
                archive=Path('dist/text-script-xctest-evidence.zip')
                with zipfile.ZipFile(archive) as bundle:
                    self.assertIn('dist/text-script-xctest/archive-status.json',bundle.namelist())
                archive.unlink()
                status=Path('dist/text-script-xctest/archive-status.json');status.unlink()
                root=Path('dist/text-script-xctest');(root/'build.log').write_text('bounded compiler failure')
                inputs=root/'owned/inputs';inputs.mkdir(parents=True)
                (inputs/'bundle-Info.plist.prefix').write_bytes(b'bounded invalid plist')
                exec(compile(code,'diagnostic-archive','exec'),{})
                with zipfile.ZipFile(archive) as bundle:
                    self.assertIn('dist/text-script-xctest/build.log',bundle.namelist())
                    self.assertIn('dist/text-script-xctest/owned/inputs/bundle-Info.plist.prefix',bundle.namelist())
                archive.unlink();status.unlink()
                (inputs/'unexpected.prefix').write_bytes(b'not allowed')
                with self.assertRaises(SystemExit):exec(compile(code,'diagnostic-archive','exec'),{})
            finally:
                os.chdir(previous)


if __name__=='__main__':
    unittest.main()
