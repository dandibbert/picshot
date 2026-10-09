import copy
import importlib.util
import json
import os
import plistlib
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location('native_owned_xctest',
    Path(__file__).parents[1] / 'native-owned-xctest.py')
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)


def identity(pid=123):
    return dict(pid=pid, parentPID=os.getpid(), groupID=pid, uid=os.getuid(),
                birthSeconds=1234, birthMicroseconds=123, executable='/test/xctest')


def linux_identity(pid):
    raw = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
    return dict(pid=pid, parentPID=int(raw[1]), groupID=int(raw[2]),
        uid=Path(f'/proc/{pid}').stat().st_uid, birthSeconds=int(raw[19]), birthMicroseconds=0,
        executable=os.readlink(f'/proc/{pid}/exe'))


class OwnedXCTestTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)

    def native_fixture(self):
        source = self.path / 'product'
        developer = self.path / 'Xcode.app/Contents/Developer'
        platform = developer / 'Platforms/MacOSX.platform'
        agent = platform / 'Developer/Library/Xcode/Agents/xctest'
        agent.parent.mkdir(parents=True)
        agent.write_bytes(bytes.fromhex('cffaedfe') + b'fixture Mach-O')
        bin_path = source / '.build/arm64-apple-macosx/debug'
        bundle = bin_path / 'PicShotPackageTests.xctest'
        (bundle / 'Contents/MacOS').mkdir(parents=True)
        (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'PicShotPackageTests'}))
        (bundle / 'Contents/MacOS/PicShotPackageTests').write_bytes(b'compiled fixture')
        answers = {
            ('git', 'rev-parse', 'HEAD'): M.SOURCE,
            ('git', 'rev-parse', 'HEAD^{tree}'): M.TREE,
            ('git', 'status', '--porcelain', '--untracked-files=no'): '',
            ('git', 'status', '--porcelain', '--untracked-files=all', '--', 'Package.swift', 'Package.resolved', 'Sources', 'Tests'): '',
            ('/usr/bin/xcode-select', '-p'): str(developer),
            ('/usr/bin/xcrun', '--sdk', 'macosx', '--find', 'xctest'): str(agent),
            ('/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-platform-path'): str(platform),
            ('/usr/bin/xcrun', 'swift', 'build', '--show-bin-path'): str(bin_path),
            ('/usr/bin/xcodebuild', '-version'): 'Xcode 16.4 fixture',
            ('/usr/bin/xcrun', 'swift', '--version'): 'Swift 6.1 fixture',
            ('/usr/bin/xcrun', 'swift', 'package', '--version'): 'SwiftPM fixture',
        }
        args = SimpleNamespace(source_root=source, bundle=bundle, output_mode='baseline')
        return args, answers

    def test_source_tool_bundle_bytes_and_budget_are_bound_before_launch(self):
        args, answers = self.native_fixture()
        def query(argv, cwd=None, timeout=20):
            self.assertGreater(timeout, 0)
            self.assertLessEqual(timeout, 20)
            return answers[tuple(argv)]
        with mock.patch.object(M.sys, 'platform', 'darwin'), mock.patch.dict(M.os.environ, {}, clear=True), \
                mock.patch.object(M, 'bounded_read', side_effect=query):
            result, env = M.launch_inputs(args)
            self.assertEqual(result['sourceCommit'], M.SOURCE)
            self.assertEqual(result['bundleExecutable'], M.file_identity(args.bundle / 'Contents/MacOS/PicShotPackageTests'))
            self.assertEqual(result['limits']['nativeSeconds'], 420)
            self.assertEqual(result['limits']['samplerSeconds'], 40)
            self.assertEqual(env['SWIFT_TESTING_ENABLED'], '0')
            answers[('git', 'rev-parse', 'HEAD')] = '0' * 40
            with self.assertRaisesRegex(ValueError, 'immutable145'):
                M.launch_inputs(args)
            answers[('git', 'rev-parse', 'HEAD')] = M.SOURCE
            key = ('git', 'status', '--porcelain', '--untracked-files=all', '--', 'Package.swift', 'Package.resolved', 'Sources', 'Tests')
            answers[key] = '?? Sources/Injected.swift'
            with self.assertRaisesRegex(ValueError, 'untracked'):
                M.launch_inputs(args)
            answers[key] = ''
            with mock.patch.object(M, 'SETUP_SECONDS', 0):
                with self.assertRaisesRegex(ValueError, 'setup deadline'):
                    M.launch_inputs(args)
            (args.bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'Other'}))
            with self.assertRaisesRegex(ValueError, 'bundle executable'):
                M.launch_inputs(args)

    def child(self, changed=None):
        process = SimpleNamespace(pid=123, wait=mock.Mock(return_value=0))
        watch = mock.Mock()
        watch.leader_exited.return_value = False
        identify = mock.Mock(return_value=identity())
        with mock.patch.object(M.D.BOUNDED, 'ProcessGroup', return_value=watch):
            child = M.OwnedChild(process, '/test/xctest', identify)
        if changed:
            identify.return_value = {**identity(), **changed}
        return child, watch, identify

    def test_command_uses_one_exact_comma_argument_and_preserves_raw_order(self):
        ids = ['Mod.ZTests/testZ', 'Mod.ATests/testA']
        self.assertEqual(M.command('/xctest', '/a.xctest', ids),
                         ['/xctest', '-XCTest', ','.join(ids), '/a.xctest'])
        for bad in ([], ['Mod.T/testA'] * 2, ['Mod.T/testA,Mod.T/testB'], ['^Mod.*']):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                M.command('/xctest', '/a.xctest', bad)

    def test_ordered_selection_preserves_inventory_order_without_neighbours(self):
        (self.path / 'native-test-discovery.log').write_text('Mod.Z/testZ\nMod.Z/testOther\nMod.A/testA\n')
        self.assertEqual(M.ordered_selection(self.path / 'plan.json', ['Mod.A/testA', 'Mod.Z/testZ']),
                         ['Mod.Z/testZ', 'Mod.A/testA'])
        with self.assertRaises(ValueError):
            M.ordered_selection(self.path / 'plan.json', ['Mod.Missing/testA'])

    def test_runtime_environment_preserves_inheritance_and_only_control_buffering(self):
        inherited = {'DYLD_FRAMEWORK_PATH': '/existing', 'DYLD_LIBRARY_PATH': '/lib',
                     'NSUnbufferedIO': 'NO', 'UNCHANGED': 'value'}
        baseline = M.test_environment(inherited, Path('/Platform'), 'baseline')
        self.assertEqual(baseline['DYLD_FRAMEWORK_PATH'],
                         '/existing:/Platform/Developer/Library/Frameworks:/Platform/Developer/Library/PrivateFrameworks')
        self.assertEqual(baseline['DYLD_LIBRARY_PATH'], '/lib:/Platform/Developer/usr/lib')
        self.assertEqual(baseline['NO_COLOR'], '1')
        self.assertEqual(baseline['SWIFT_TESTING_ENABLED'], '0')
        self.assertEqual(baseline['NSUnbufferedIO'], 'NO')
        self.assertEqual(M.test_environment(inherited, Path('/Platform'), 'unbuffered'),
                         {**baseline, 'NSUnbufferedIO': 'YES'})
        self.assertEqual(inherited['DYLD_FRAMEWORK_PATH'], '/existing')

    def test_direct_identity_binding_and_no_observation_after_reap(self):
        child, watch, identify = self.child()
        self.assertEqual(child.validate(), identity())
        with mock.patch.object(M.os, 'kill') as kill:
            child.send(signal.SIGTERM)
            kill.assert_called_once_with(123, signal.SIGTERM)
        watch.leader_exited.return_value = True
        self.assertEqual(child.reap(), 0)
        self.assertTrue(child.record['cleanupConfirmed'])
        with mock.patch.object(M.os, 'kill') as kill:
            with self.assertRaises(ValueError):
                child.send(signal.SIGTERM)
            kill.assert_not_called()
        child.process.wait.assert_called_once_with(timeout=1)

    def test_all_identity_changes_refuse_signal_after_binding(self):
        for field in identity():
            value = '/other' if field == 'executable' else identity()[field] + 1
            with self.subTest(field=field):
                child, _, _ = self.child({field: value})
                with mock.patch.object(M.os, 'kill') as kill:
                    with self.assertRaisesRegex(ValueError, 'identity changed'):
                        child.send(signal.SIGKILL)
                    kill.assert_not_called()

    def test_initial_identity_failure_cleanup_only_uses_unreaped_child(self):
        process = SimpleNamespace(pid=123, wait=mock.Mock(return_value=-15))
        watch = mock.Mock()
        watch.leader_exited.return_value = False
        with mock.patch.object(M.D.BOUNDED, 'ProcessGroup', return_value=watch):
            child = M.OwnedChild(process, '/test/xctest', mock.Mock(side_effect=OSError('injected')))
        self.assertIsNone(child.identity)
        with mock.patch.object(M.os, 'kill') as kill:
            child.send(signal.SIGTERM)
            kill.assert_called_once_with(123, signal.SIGTERM)
        self.assertEqual(child.record['signals'][0]['basis'], 'unreaped-Popen-child-binding-failed')
        watch.leader_exited.return_value = True
        child.reap()
        self.assertEqual(child.record['bindingError'], 'injected')

    def test_signal_esrch_requires_unreaped_exit_confirmation(self):
        child, watch, _ = self.child()
        watch.leader_exited.side_effect = [False, False, True]
        with mock.patch.object(M.os, 'kill', side_effect=ProcessLookupError):
            self.assertFalse(child.send(signal.SIGTERM))
        child, watch, _ = self.child()
        with mock.patch.object(M.os, 'kill', side_effect=ProcessLookupError):
            with self.assertRaisesRegex(ValueError, 'exit evidence'):
                child.send(signal.SIGTERM)

    def test_sample_hash_failure_happens_before_any_spawn(self):
        child, _, _ = self.child()
        with mock.patch.object(M, 'file_identity', side_effect=OSError('hash failure')):
            with mock.patch.object(M.subprocess, 'Popen') as spawn:
                with self.assertRaisesRegex(OSError, 'hash failure'):
                    M.start_sample(self.path, 180, child, child.identify)
                spawn.assert_not_called()

    def test_failed_sampler_retirement_preserves_handle_and_prevents_root_release(self):
        sampler = SimpleNamespace(exited=lambda: False, reaped=False)
        root = SimpleNamespace(validate=mock.Mock(return_value=identity()), identity=identity(), reaped=False, exited=lambda: False)
        record = dict(slotSeconds=180, startedMonotonic=time.monotonic())
        with mock.patch.object(M, 'stop_child', side_effect=OSError('cannot retire')):
            with self.assertRaisesRegex(ValueError, 'retain root PID'):
                M.finish_sample(sampler, record, root, self.path)
        self.assertEqual(record['status'], 'incomplete')
        self.assertIn('cannot retire', record['error'])
        root.validate.assert_not_called()
        self.assertTrue((self.path / 'sample-180.json').is_file())

    def test_raw_sample_binds_pid_path_and_real_thread_graph(self):
        sample = self.path / 'sample.txt'
        good = 'Process: xctest [123]\nPath: /test/xctest\nCall graph:\n    172 Thread_11070\n    + 172 start (in dyld)\n'
        sample.write_text(good)
        self.assertEqual(M.sample_contents(sample, identity())['sampleBytes'], len(good))
        for bad in (good.replace('[123]', '[124]'), good.replace('/test/xctest', '/other/xctest'),
                    good.replace('Thread_11070', 'no_stack')):
            sample.write_text(bad)
            with self.assertRaises(ValueError):
                M.sample_contents(sample, identity())

    def capture_fixture(self):
        slot, target = 180, identity()
        sampler_identity = {**identity(456), 'executable': '/usr/bin/sample'}
        capture = dict(slotSeconds=slot, status='captured', completion='exited', returnCode=0,
            target=target, targetIdentityAfter=target, targetUnreapedAtCompletion=True, targetExitObservedAtCompletion=False,
            process=dict(pid=456, ownerPID=os.getpid(), identity=sampler_identity,
                cleanupConfirmed=True, returnCode=0, bindingError=None, signals=[], reapedAtMonotonic=2))
        request = dict(slotSeconds=slot, target=target, command=['/usr/bin/sample', '123', '2', '10',
            '-mayDie', '-file', str(self.path / 'sample-180.txt')])
        M.save(self.path / 'sample-180.request.json', request)
        capture.update(request=request, requestSHA256=M.file_identity(self.path / 'sample-180.request.json')['sha256'])
        (self.path / 'sample-180.txt').write_text('Process: xctest [123]\nPath: /test/xctest\nCall graph:\n    2 Thread_456\n')
        capture.update(M.sample_contents(self.path / 'sample-180.txt', target))
        M.save(self.path / 'sample-180.json', capture)
        return capture

    def test_capture_replay_binds_request_sidecar_root_and_sampler_retirement(self):
        good = self.capture_fixture()
        M.validate_capture(self.path, good, dict(identity=identity(), reapedAtMonotonic=3))
        mutations = (
            lambda c: c.update(returnCode=1),
            lambda c: c.update(targetIdentityAfter={**identity(), 'birthSeconds': 9}),
            lambda c: c['process'].update(returnCode=1),
            lambda c: c['process'].update(cleanupConfirmed=False),
            lambda c: c['process'].update(cleanupConfirmed='false'),
            lambda c: c['process']['identity'].update(parentPID=999),
            lambda c: c['process'].update(signals=[dict(signal=15)]),
            lambda c: c.update(requestSHA256='0' * 64),
            lambda c: c.update(sampleSHA256='0' * 64),
        )
        for mutate in mutations:
            bad = copy.deepcopy(good); mutate(bad)
            M.save(self.path / 'sample-180.json', bad)
            with self.assertRaises(ValueError):
                M.validate_capture(self.path, bad, dict(identity=identity(), reapedAtMonotonic=3))
        M.save(self.path / 'sample-180.json', good)
        sample = self.path / 'sample-180.txt'
        data = sample.read_bytes()
        sample.write_bytes(data.replace(b'\n', b'\r\n'))
        with self.assertRaises(ValueError):
            M.validate_capture(self.path, good, dict(identity=identity(), reapedAtMonotonic=3))
        sample.write_bytes(data)
        (self.path / 'sample-180.request.json').unlink()
        with self.assertRaises(ValueError):
            M.validate_capture(self.path, good, dict(identity=identity(), reapedAtMonotonic=3))

    @unittest.skipUnless(sys.platform == 'linux', 'Portable live ownership backend uses Linux /proc')
    def test_root_deadline_terminates_before_sampler_cleanup_and_reaps_after_sampler(self):
        def sample(directory, slot, root, identify):
            process = subprocess.Popen([str(Path(sys.executable).resolve()), '-c',
                'import time; time.sleep(10)'], start_new_session=True,
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            child = M.OwnedChild(process, str(Path(sys.executable).resolve()), linux_identity)
            record = dict(slotSeconds=slot, target=root.identity, startedMonotonic=time.monotonic(),
                          status='running', process=child.record)
            return child, record
        with mock.patch.object(M, 'start_sample', side_effect=sample):
            report = M.run_owned([str(Path(sys.executable).resolve()), '-c', 'import time; time.sleep(10)'],
                dict(os.environ), str(self.path), self.path / 'run', linux_identity, timeout=.15, slots=(.05,))
        self.assertEqual(report['status'], 'timeout')
        self.assertTrue(report['cleanupConfirmed'])
        self.assertLess(report['terminationStartedAtSeconds'], .3)
        capture = report['captures'][0]
        self.assertLess(report['root']['signals'][0]['atMonotonic'], capture['process']['signals'][0]['atMonotonic'])
        self.assertGreater(report['root']['reapedAtMonotonic'], capture['process']['reapedAtMonotonic'])
        self.assertEqual(capture['status'], 'incomplete')

    @unittest.skipUnless(sys.platform == 'linux', 'Portable live ownership backend uses Linux /proc')
    def test_normal_root_exit_waits_for_bounded_symbolization_without_releasing_pid(self):
        def sample(directory, slot, root, identify):
            (directory / f'sample-{slot}.txt').write_text(
                f"Process: xctest [{root.process.pid}]\nPath: {root.identity['executable']}\nCall graph:\n    2 Thread_456\n")
            process = subprocess.Popen([str(Path(sys.executable).resolve()), '-c',
                'import time; time.sleep(.3)'], start_new_session=True,
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            child = M.OwnedChild(process, str(Path(sys.executable).resolve()), linux_identity)
            return child, dict(slotSeconds=slot, target=root.identity, startedMonotonic=time.monotonic(),
                               status='running', process=child.record)
        with mock.patch.object(M, 'start_sample', side_effect=sample):
            report = M.run_owned([str(Path(sys.executable).resolve()), '-c', 'import time; time.sleep(.1)'],
                dict(os.environ), str(self.path), self.path / 'run', linux_identity, timeout=1, slots=(.025,))
        self.assertEqual(report['status'], 'exited')
        capture = report['captures'][0]
        self.assertEqual(capture['status'], 'captured')
        self.assertTrue(capture['targetExitObservedAtCompletion'])
        self.assertTrue(capture['targetUnreapedAtCompletion'])
        self.assertIsNone(capture['targetIdentityAfter'])
        self.assertEqual(capture['process']['signals'], [])
        self.assertGreater(report['durationSeconds'], report['workloadEndSeconds'] + .1)
        self.assertGreater(report['root']['reapedAtMonotonic'], capture['process']['reapedAtMonotonic'])

    @unittest.skipUnless(sys.platform == 'linux', 'Portable live ownership backend uses Linux /proc')
    def test_exit_first_observed_after_deadline_is_timeout(self):
        original = M.drain
        def delayed(selector, log, report, timeout):
            time.sleep(.1)
            original(selector, log, report, 0)
        with mock.patch.object(M, 'drain', side_effect=delayed):
            report = self.run_fixture('import time; time.sleep(.03)', timeout=.05)
        self.assertEqual(report['status'], 'timeout')
        self.assertEqual(report['rootReturnCode'], 0)
        self.assertTrue(report['cleanupConfirmed'])

    def test_sampler_exit_first_observed_after_allowance_is_incomplete(self):
        sampler = SimpleNamespace(exited=lambda: True, reaped=True, reap=lambda: 0)
        root = SimpleNamespace(validate=lambda: identity(), identity=identity(), reaped=False, exited=lambda: False)
        record = dict(slotSeconds=180, startedMonotonic=time.monotonic() - 41)
        M.finish_sample(sampler, record, root, self.path)
        self.assertEqual(record['status'], 'incomplete')
        self.assertEqual(record['completion'], 'timeout')

    def test_positive_identity_mismatch_then_exit_is_never_erased(self):
        sampler = SimpleNamespace(exited=lambda: True, reaped=True, reap=lambda: 0)
        root = SimpleNamespace(validate=mock.Mock(side_effect=M.IdentityMismatch('known differing birth')),
            identity=identity(), reaped=False, exited=mock.Mock(side_effect=[False, True]))
        record = dict(slotSeconds=180, startedMonotonic=time.monotonic())
        M.finish_sample(sampler, record, root, self.path)
        self.assertEqual(record['status'], 'incomplete')
        self.assertEqual(record['error'], 'known differing birth')
        self.assertFalse(record['targetExitObservedAtCompletion'])
        root.exited.assert_called_once()

    @unittest.skipUnless(sys.platform == 'linux', 'Portable live ownership backend uses Linux /proc')
    def test_emergency_cleanup_retires_owned_sampler_before_root_after_identity_fault(self):
        def sample(directory, slot, root, identify):
            process = subprocess.Popen([str(Path(sys.executable).resolve()), '-c',
                'import time; time.sleep(10)'], start_new_session=True,
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            child = M.OwnedChild(process, str(Path(sys.executable).resolve()), linux_identity)
            child.identify = lambda pid: {**child.identity, 'birthSeconds': child.identity['birthSeconds'] + 1}
            return child, dict(slotSeconds=slot, target=root.identity, startedMonotonic=time.monotonic(),
                               status='running', process=child.record)
        with mock.patch.object(M, 'start_sample', side_effect=sample):
            report = M.run_owned([str(Path(sys.executable).resolve()), '-c', 'import time; time.sleep(10)'],
                dict(os.environ), str(self.path), self.path / 'run', linux_identity, timeout=.15, slots=(.025,))
        self.assertEqual(report['status'], 'error')
        self.assertTrue(report['cleanupConfirmed'])
        self.assertTrue(report['errors'])
        capture = report['captures'][0]
        self.assertIn('emergencyCleanup', capture['process'])
        self.assertEqual(capture['process']['signals'][0]['basis'], 'unreaped-Popen-child-emergency')
        self.assertGreater(report['root']['reapedAtMonotonic'], capture['process']['reapedAtMonotonic'])

    def good_report(self):
        return dict(status='exited', rootReturnCode=0, cleanupConfirmed=True, outputEOF=True,
                    errors=[], logTruncated=False, captures=[], dueCaptureSlots=[])

    def test_case_gate_exact_methods_rejects_neighbors_duplicates_and_incomplete_samples(self):
        names = ['Mod.T/testA']
        log = "Test Case '-[Mod.T testA]' started.\nTest Case '-[Mod.T testA]' passed (0.1 seconds).\n"
        self.assertEqual(M.assess(self.good_report(), log, names)['status'], 'passed')
        for bad in (log + log, log.replace('passed', 'failed'), log + log.replace('testA', 'testB')):
            with self.assertRaises(ValueError):
                M.assess(self.good_report(), bad, names)
        for updates in ({'dueCaptureSlots': [180]}, {'captures': [dict(slotSeconds=180, status='incomplete')], 'dueCaptureSlots': [180]},
                        {'outputEOF': False}, {'logTruncated': True}, {'errors': ['fault']}, {'cleanupConfirmed': False}):
            with self.assertRaises(ValueError):
                M.assess({**self.good_report(), **updates}, log, names)

    def test_allowed_skip_is_preserved_and_unapproved_skip_rejected(self):
        name = sorted(M.N.ALLOWED_SKIPS)[0]
        cls, method = name.split('/')
        log = f"Test Case '-[{cls} {method}]' started.\nTest Case '-[{cls} {method}]' skipped (0.1 seconds).\n"
        self.assertEqual(M.assess(self.good_report(), log, [name])['skippedIDs'], [name])
        with self.assertRaises(ValueError):
            M.assess(self.good_report(), log.replace(method, 'testUnknown'), [cls + '/testUnknown'])

    def test_result_replay_accepts_both_modes_and_rejects_log_argv_identity_mutations(self):
        names = ['Mod.T/testA']
        log = "Test Case '-[Mod.T testA]' started.\nTest Case '-[Mod.T testA]' passed (0.1 seconds).\n"
        (self.path / 'xctest.log').write_text(log)
        inputs = dict(sourceCommit=M.SOURCE, sourceTree=M.TREE, xctestPath='/test/xctest', bundlePath='/b.xctest',
            limits=dict(setupSeconds=60, nativeSeconds=420, samplerSeconds=40, sampleCollectionSeconds=2, sampleIntervalMilliseconds=10))
        root = dict(identity=identity(), pid=123, ownerPID=os.getpid(), bindingError=None,
                    cleanupConfirmed=True, returnCode=0)
        process = {**self.good_report(), 'root': root, 'command': M.command('/test/xctest', '/b.xctest', names),
                   'timeoutSeconds': 420, 'samplerTimeoutSeconds': 40, 'expectedCaptureSlots': [180, 360],
                   'logIdentity': M.file_identity(self.path / 'xctest.log')}
        result = dict(phase='run', outputMode='baseline', inputs=inputs, schemaVersion=1, scope=M.SCOPE,
            diagnosticOnly=True, installerAcceptance=False, fullInventorySHA256=M.INVENTORY_SHA,
            group3IDsSHA256=M.IDS_SHA, historicalSwiftPMFilter='fixture', historicalSwiftPMFilterSHA256=M.sha(b'fixture'),
            process=process, cases=M.assess(process, log, names), orderedSelectedIDs=names,
            orderedSelectedIDsSHA256=M.ids_digest(names), commaSelectorSHA256=M.sha(','.join(names).encode()))
        def write():
            M.save(self.path / 'process.json', result['process'])
            M.save(self.path / 'result.json', result)
        with mock.patch.object(M, 'FILTER_SHA', M.sha(b'fixture')):
            for mode in ('baseline', 'unbuffered'):
                result['outputMode'] = mode; write()
                self.assertEqual(M.verify_result(self.path, inputs, names, 'run', mode), result)
            result['outputMode'] = 'baseline'; write()
            good = copy.deepcopy(result)
            mutations = (
                lambda r: r['process']['command'].__setitem__(2, 'Mod.T/testOther'),
                lambda r: r['process'].update(timeoutSeconds=421),
                lambda r: r['process']['root'].update(cleanupConfirmed=False),
                lambda r: r['process']['root'].update(cleanupConfirmed='false'),
                lambda r: r['process'].update(cleanupConfirmed='false'),
                lambda r: r['process']['root']['identity'].update(parentPID=999),
                lambda r: r.update(commaSelectorSHA256='0' * 64),
                lambda r: r.update(installerAcceptance=True),
            )
            for mutation in mutations:
                result = copy.deepcopy(good); mutation(result); write()
                with self.assertRaises(ValueError):
                    M.verify_result(self.path, inputs, names, 'run')
            result = copy.deepcopy(good); write()
            (self.path / 'xctest.log').write_text(log + 'tampered')
            with self.assertRaisesRegex(ValueError, 'log identity'):
                M.verify_result(self.path, inputs, names, 'run')

    def run_fixture(self, code, timeout=1, **kwargs):
        return M.run_owned([str(Path(sys.executable).resolve()), '-c', code], dict(os.environ),
            str(self.path), self.path / 'run', linux_identity, timeout=timeout, slots=(), **kwargs)

    @unittest.skipUnless(sys.platform == 'linux', 'Portable live ownership backend uses Linux /proc')
    def test_live_normal_exit_keeps_identity_and_drains_output(self):
        report = self.run_fixture("import time; print('owned output', flush=True); time.sleep(.1)")
        self.assertEqual(report['status'], 'exited')
        self.assertEqual(report['rootReturnCode'], 0)
        self.assertTrue(report['cleanupConfirmed'])
        self.assertTrue(report['outputEOF'])
        self.assertEqual((self.path / 'run/xctest.log').read_text(), 'owned output\n')
        self.assertEqual(report['root']['signals'], [])

    @unittest.skipUnless(sys.platform == 'linux', 'Portable live ownership backend uses Linux /proc')
    def test_live_timeout_escalates_only_owned_root_and_preserves_deadline(self):
        report = self.run_fixture('import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(10)', timeout=.2)
        self.assertEqual(report['status'], 'timeout')
        self.assertEqual(report['rootReturnCode'], -signal.SIGKILL)
        self.assertTrue(report['cleanupConfirmed'])
        self.assertEqual([x['signal'] for x in report['root']['signals']], [signal.SIGTERM, signal.SIGKILL])
        self.assertEqual(report['timeoutSeconds'], .2)
        self.assertLess(report['durationSeconds'], 2)

    @unittest.skipUnless(sys.platform == 'linux', 'Portable live ownership backend uses Linux /proc')
    def test_live_cancellation_cleans_owned_child_and_preserves_evidence(self):
        report = self.run_fixture('import os,signal,time; time.sleep(.1); os.kill(os.getppid(),signal.SIGTERM); time.sleep(10)')
        self.assertEqual(report['status'], 'cancelled')
        self.assertEqual(report['cancellationSignal'], signal.SIGTERM)
        self.assertTrue(report['cleanupConfirmed'])

    @unittest.skipUnless(sys.platform == 'linux', 'Portable live ownership backend uses Linux /proc')
    def test_live_output_over_cap_drains_and_retains_bounded_prefix(self):
        with mock.patch.object(M.N, 'MAX_LOG_BYTES', 1024):
            report = self.run_fixture("import os,time; os.write(1,b'x'*10000); time.sleep(.1)")
        self.assertEqual(report['outputBytes'], 10000)
        self.assertEqual(report['logBytes'], 1024)
        self.assertTrue(report['logTruncated'])
        self.assertTrue(report['outputEOF'])
        self.assertTrue(report['cleanupConfirmed'])

    @unittest.skipUnless(sys.platform == 'linux', 'Portable live ownership backend uses Linux /proc')
    def test_live_initial_identity_error_still_retires_only_direct_child(self):
        report = M.run_owned([str(Path(sys.executable).resolve()), '-c', 'import time; time.sleep(10)'],
            dict(os.environ), str(self.path), self.path / 'run',
            mock.Mock(side_effect=OSError('identity unavailable')), timeout=1, slots=())
        self.assertEqual(report['status'], 'error')
        self.assertTrue(report['cleanupConfirmed'])
        self.assertEqual(report['root']['bindingError'], 'identity unavailable')
        self.assertEqual(report['root']['signals'][0]['basis'], 'unreaped-Popen-child-binding-failed')

    @unittest.skipUnless(sys.platform == 'linux', 'Portable live ownership backend uses Linux /proc')
    def test_live_sample_start_failure_still_retires_root(self):
        with mock.patch.object(M, 'start_sample', side_effect=OSError('sample launch failure')):
            report = M.run_owned([str(Path(sys.executable).resolve()), '-c', 'import time; time.sleep(10)'],
                dict(os.environ), str(self.path), self.path / 'run', linux_identity, timeout=1, slots=(.05,))
        self.assertEqual(report['status'], 'error')
        self.assertTrue(report['cleanupConfirmed'])
        self.assertIn('sample launch failure', report['errors'])


if __name__ == '__main__':
    unittest.main()
