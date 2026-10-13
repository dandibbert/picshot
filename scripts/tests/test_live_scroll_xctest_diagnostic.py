"""Portable contracts for one exact185 diagnostic; never native pass evidence."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import stat
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('live_scroll_owned_diagnostic', ROOT/'scripts/diagnose-live-scroll-xctest.py')
M = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(M)


def filesystem_rows(scopes):
    paths=[]
    for scope in scopes:
        p=ROOT/scope
        paths.extend([p] if p.is_file() else [f for f in p.rglob('*') if f.is_file()])
    rows=[]
    for p in sorted(paths):
        raw=p.read_bytes()
        rows.append(dict(path=str(p.relative_to(ROOT)),mode='100755' if stat.S_IMODE(p.stat().st_mode)&0o111 else '100644',
            sha=hashlib.sha1(b'blob '+str(len(raw)).encode()+b'\0'+raw).hexdigest()))
    return sorted(rows,key=lambda row:row["path"])


def native_ids():
    names=[]
    for path in (ROOT/'Tests').rglob('*.swift'):
        text=path.read_text()
        if text.startswith('#if PICSHOT_CALLOUT_RETIREMENT_DIAGNOSTICS\n'):continue
        methods=re.findall(r'\bfunc\s+(test\w+)\s*\(',text)
        if not methods:continue
        classes=re.findall(r'\bclass\s+(\w+)\s*:\s*\w*TestCase\b',text)
        if len(classes)!=1:raise ValueError(str(path))
        names.extend(path.relative_to(ROOT/'Tests').parts[0]+'.'+classes[0]+'/'+method for method in methods)
    return sorted(names)


class ExactLiveScrollDiagnosticTests(unittest.TestCase):
    def test_product_and_only_approved_corrected_test_bytes_are_frozen(self):
        products=filesystem_rows(['Package.swift','Sources']);tests=filesystem_rows(['Tests'])
        self.assertEqual((len(products),M.tree_digest(products)),(336,M.PRODUCT_SHA256))
        self.assertEqual((len(tests),M.tree_digest(tests)),(290,M.TESTS_SHA256))
        self.assertEqual({p:next(r['sha'] for r in tests if r['path']==p) for p in M.CORRECTED_TESTS},M.CORRECTED_TESTS)
        for name,digest in M.HELPERS.items():
            self.assertEqual(M.O.file_identity(ROOT/'scripts'/name)['sha256'],digest)

    def test_input_tree_guard_rejects_one_changed_product_or_unapproved_test(self):
        rows={'Sources':filesystem_rows(['Package.swift','Sources']),'Tests':filesystem_rows(['Tests'])}
        def query(argv,cwd):
            return '\n'.join(r['mode']+' blob '+r['sha']+'\t'+r['path'] for r in rows[argv[-1]])
        good=M.frozen_inputs(ROOT,query)
        self.assertEqual(good['productSHA256'],M.PRODUCT_SHA256)
        for scope in rows:
            original=rows[scope][0]['sha'];rows[scope][0]['sha']='a'*40
            with self.subTest(scope=scope),self.assertRaises(ValueError):M.frozen_inputs(ROOT,query)
            rows[scope][0]['sha']=original
        for raw in ['', '120000 blob '+'a'*40+'\tSources/file.swift',
                    '100644 blob '+'a'*40+'\t../outside.swift']:
            with self.assertRaises(ValueError):M.tree_rows(raw)

    def test_full2436_and_exact185_source_inventory_and_raw_order(self):
        names=native_ids()
        self.assertEqual((len(names),M.O.ids_digest(names)),(2436,M.FULL_IDS_SHA256))
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'native-test-discovery.log';p.write_text('\n'.join(reversed(names))+'\n')
            selected,raw=M.selection(ROOT,p)
            self.assertEqual(len(selected),185)
            self.assertEqual(M.O.ids_digest(sorted(selected)),M.SELECTED_IDS_SHA256)
            self.assertEqual(selected,[name for name in reversed(names) if '.LiveScroll' in name])
            self.assertEqual(raw,p.read_text())
            for changed in [names[:-1],sorted(names+['PicShotTests.LiveScrollNewTests/testUnknown']),
                            [name+'Renamed' if i==10 else name for i,name in enumerate(names)]]:
                p.write_text('\n'.join(changed)+'\n')
                with self.assertRaises(ValueError):M.selection(ROOT,p)

    def test_selection_never_widens_to_classes_or_other_methods(self):
        names=['PicShotTests.LiveScrollA/testA','PicShotTests.LiveScrollB/testB']
        self.assertEqual(M.O.command('/platform/xctest','/build/tests.xctest',names),
            ['/platform/xctest','-XCTest',','.join(names),'/build/tests.xctest'])
        for bad in [[],names+names,[names[0]+'|.*']]:
            with self.assertRaises(ValueError):M.O.command('/xctest','/bundle',bad)

    def test_unbuffered_bootstrap_preserves_the_existing_runtime_environment(self):
        old={'PATH':'/bin','CUSTOM':'kept','NSUnbufferedIO':'NO'}
        env=M.O.test_environment(old,Path('/platform'),'unbuffered')
        self.assertEqual(env['NSUnbufferedIO'],'YES');self.assertEqual(env['CUSTOM'],'kept')
        self.assertEqual(env['SWIFT_TESTING_ENABLED'],'0');self.assertEqual(old['NSUnbufferedIO'],'NO')

    def test_native_boundaries_distinguish_assertion_failure_and_missing_terminal(self):
        names=['P.A/testA','P.B/testB','P.C/testC','P.D/testD']
        log="Test Case '-[P.A testA]' started.\nTest Case '-[P.A testA]' passed (0.001 seconds).\n"
        log+="Test Case '-[P.B testB]' started.\nTest Case '-[P.B testB]' failed (0.001 seconds).\n"
        log+="Test Case '-[P.C testC]' started.\n"
        phases=M.method_phases(log,names)
        self.assertEqual(phases['passedIDs'],names[:1]);self.assertEqual(phases['failedIDs'],names[1:2])
        self.assertEqual(phases['startedWithoutTerminalIDs'],names[2:3]);self.assertEqual(phases['notStartedIDs'],names[3:])
        self.assertIs(phases['lastPrintedMethodIsNotCausalAttribution'],True)
        for bad in [log+log,log.replace("P.C testC","P.C testUnexpected"),log.replace('failed','skipped')]:
            with self.assertRaises(ValueError):M.method_phases(bad,names)

    def process_fixture(self,directory):
        names=['P.A/testA'];identity=dict(xctestPath='/platform/xctest',bundlePath='/build/tests.xctest',orderedSelectedIDs=names)
        target=dict(pid=100,groupID=100,parentPID=99,executable='/platform/xctest')
        root=dict(identity=target,pid=100,ownerPID=99,bindingError=None,cleanupConfirmed=True,returnCode=-15,
            retirementEvidence='unreaped-exit-observation-then-Popen-wait')
        process=dict(schemaVersion=1,diagnosticOnly=True,installerAcceptance=False,cancellationSignal=None,
            command=M.O.command(identity['xctestPath'],identity['bundlePath'],names),timeoutSeconds=420,
            samplerTimeoutSeconds=40,expectedCaptureSlots=[180,360],cleanupConfirmed=True,outputEOF=True,
            errors=[],logTruncated=False,status='timeout',root=root,rootReturnCode=-15,workloadEndSeconds=420.01,
            terminationStartedAtSeconds=420.01,dueCaptureSlots=[180,360],
            captures=[dict(slotSeconds=slot,startedAtSeconds=slot+.01) for slot in (180,360)])
        (directory/'xctest.log').write_text("Test Case '-[P.A testA]' started.\n")
        process['logIdentity']=M.O.file_identity(directory/'xctest.log')
        evidence=directory.with_name(directory.name+'-inputs');evidence.mkdir()
        source=dict(sourceCommit='a'*40,sourceTree='b'*40,trackedStatus='',buildInputStatus='',packageResolved=dict(status='absent'))
        identity.update(sourceCommit='a'*40,sourceTree='b'*40,sourceInputEvidence=source,frozenInputs={'fixture':True})
        (evidence/'native-test-discovery.log').write_text('P.A/testA\n')
        identity['rawDiscovery']=M.O.file_identity(evidence/'native-test-discovery.log')
        for name,value in [('launch-inputs.json',identity),('source-inputs.json',source),('frozen-inputs.json',identity['frozenInputs'])]:
            M.save(evidence/name,value)
        for name in ('tracked-status.txt','build-input-status.txt'):(evidence/name).write_text('')
        M.save(directory/'process.json',process)
        return identity,process

    def test_timeout_requires_both_owned_samples420s_and_confirmed_retirement(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory=Path(tmp)/'owned';directory.mkdir();identity,process=self.process_fixture(directory)
            with mock.patch.object(M.O,'validate_capture') as sample,mock.patch.object(M.O,'verify_bundle_inputs'):
                self.assertEqual(M.validate_process(directory,process,identity),process['root']['identity'])
                self.assertEqual(sample.call_count,2)
                for key,value in [('timeoutSeconds',421),('samplerTimeoutSeconds',41),('cleanupConfirmed',False),
                        ('outputEOF',False),('logTruncated',True),('captures',[]),('terminationStartedAtSeconds',419),
                        ('rootReturnCode',0),('errors',['owned cleanup failed']),('cancellationSignal',15),('diagnosticOnly',False)]:
                    changed={**process,key:value};M.save(directory/'process.json',changed)
                    with self.subTest(field=key),self.assertRaises(ValueError):M.validate_process(directory,changed,identity)
                changed=copy.deepcopy(process);changed['root']['identity']['parentPID']=123
                M.save(directory/'process.json',changed)
                with self.assertRaises(ValueError):M.validate_process(directory,changed,identity)

    def test_archived_input_reports_discovery_and_native_log_cannot_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory=Path(tmp)/'owned';directory.mkdir();identity,process=self.process_fixture(directory)
            evidence=directory.with_name('owned-inputs')
            with mock.patch.object(M.O,'validate_capture'),mock.patch.object(M.O,'verify_bundle_inputs'):
                for name in ('launch-inputs.json','source-inputs.json','frozen-inputs.json',
                             'native-test-discovery.log','tracked-status.txt','build-input-status.txt'):
                    path=evidence/name;original=path.read_bytes()
                    path.write_bytes(b'{}' if name.endswith('.json') else b'changed')
                    with self.subTest(path=name),self.assertRaises(ValueError):M.validate_process(directory,process,identity)
                    path.write_bytes(original)
                (directory/'xctest.log').write_text('changed')
                with self.assertRaisesRegex(ValueError,'raw log changed'):M.validate_process(directory,process,identity)

    def test_workflow_reuses_live_preview_without_package_or_ordinary_group(self):
        workflow=(ROOT/'.github/workflows/macos.yml').read_text()
        preview=workflow.split('  live-scroll-preview:\n',1)[1].split('\n  runner-check:\n',1)[0]
        marker="contains(github.event.head_commit.message || '', '[live-scroll-xctest-diagnostic]')"
        self.assertIn('timeout-minutes: 40',preview)
        for name in ['Build separate owned native scrolling target','Package exact signed preview application',
                     'Demonstrate actual native scrolling and growing preview']:
            step=preview.split('    - name: '+name+'\n',1)[1].split('    - name:',1)[0]
            self.assertIn('if: ${{ !'+marker+' }}',step)
        normal=preview.split('    - name: Test live scrolling matcher storage stream and geometry\n',1)[1].split('    - name:',1)[0]
        self.assertIn('!'+marker,normal);self.assertIn('--timeout-seconds 420',normal)
        owned=preview.split('    - name: Diagnose exact185 with unbuffered boundaries and owned stacks\n',1)[1].split('    - name:',1)[0]
        self.assertIn('timeout-minutes: 9',owned);self.assertIn('--timeout-seconds 510 --grace-seconds 10',owned)
        self.assertEqual(preview.count('-- python3 scripts/diagnose-live-scroll-xctest.py'),1)
        self.assertIn('dist/live-scroll-xctest/',preview.split('    - name: Preserve focused usability evidence\n',1)[1])
        self.assertIn('if: always()',preview.split('    - name: Preserve focused usability evidence\n',1)[1])
        self.assertIn('!'+marker,workflow.split('  build:\n',1)[1].splitlines()[0])
        self.assertNotIn('  live-scroll-xctest-diagnostic:\n',workflow)


if __name__=='__main__':unittest.main()
