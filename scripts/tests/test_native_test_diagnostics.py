import ctypes
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location('native_diagnostics',
    Path(__file__).parents[1] / 'native-test-diagnostics.py')
D = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(D)


class NativeDiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = 'a' * 40
        self.inventory = sorted(f'PicShotTests.Group{i}Tests/testCase{j}' for i in range(12) for j in range(2))
        discovery = self.root / 'native-test-discovery.log'
        discovery.write_text('\n'.join(self.inventory) + '\n')
        self.plan = D.NATIVE.make_plan(self.inventory, '', self.source, process_count=4)
        self.plan_path = self.root / 'plan.json'
        self.plan_path.write_text(json.dumps(self.plan))
        self.args = SimpleNamespace(plan=self.plan_path, expected_source=self.source, index=3,
            directory=self.root / 'native', diagnostics=self.root / 'diagnostics', output_mode='baseline')
        self.identities = {
            100: self.identity(100, 99, 99, '/usr/bin/python3'),
            200: self.identity(200, 100, 200, '/Applications/Xcode.app/Contents/Developer/usr/bin/swift-test'),
            201: self.identity(201, 200, 200, '/Applications/Xcode.app/Contents/Developer/usr/bin/xctest'),
        }

    @staticmethod
    def identity(pid, parent, group, executable):
        return {'pid': pid, 'parentPID': parent, 'groupID': group, 'uid': os.getuid(),
                'birthSeconds': 100000, 'birthMicroseconds': 12, 'executable': executable}

    def snapshot(self):
        with mock.patch.object(D.BOUNDED, 'darwin_group_snapshot', return_value={200: 'S', 201: 'S'}):
            return D.owned_target(100, 200, lambda pid: self.identities[pid].copy())

    def test_public_darwin_identity_layout_has_birth_time_and_no_argument_or_environment_fields(self):
        self.assertEqual(ctypes.sizeof(D.BSDInfo), 136)
        self.assertEqual(D.BSDInfo.start_seconds.offset, 120)
        self.assertEqual(D.BSDInfo.start_microseconds.offset, 128)

    def test_baseline_keeps_environment_exact_and_unbuffered_is_separate(self):
        for inherited in ({'A': 'b'}, {'NSUnbufferedIO': 'NO', 'A': 'b'}):
            self.assertEqual(D.environment('baseline', inherited), inherited)
            self.assertIsNot(D.environment('baseline', inherited), inherited)
            self.assertEqual(D.environment('unbuffered', inherited), {**inherited, 'NSUnbufferedIO': 'YES'})
        with self.assertRaises(ValueError):
            D.environment('unknown', {})
        self.assertFalse(D.buffering_setting('unbuffered', {'NSUnbufferedIO': 'YES'})['changesInheritedValue'])
        self.assertTrue(D.buffering_setting('unbuffered', {})['changesInheritedValue'])
        self.assertEqual(D.buffering_setting('baseline', {'NSUnbufferedIO': 'unexpected-private-value'}),
            {'inheritedPresent': True, 'inheritedSetting': 'other-present',
             'effectiveSetting': 'other-present', 'changesInheritedValue': False})

    def test_only_unique_owned_xcode_xctest_is_selected(self):
        value = self.snapshot()
        self.assertEqual(value['target'], self.identities[201])
        self.assertEqual(value['leader']['parentPID'], 100)
        self.assertFalse(value['atomicSnapshot'])
        mutations = [(200, 'parentPID', 999), (201, 'groupID', 999), (201, 'uid', os.getuid() + 1),
                     (201, 'executable', '/tmp/xctest'), (201, 'executable', '/usr/bin/another-process')]
        for pid, key, replacement in mutations:
            with self.subTest(pid=pid, key=key):
                old = self.identities[pid][key]
                self.identities[pid][key] = replacement
                with self.assertRaises(ValueError):
                    self.snapshot()
                self.identities[pid][key] = old

    def test_ambiguous_or_changed_process_identity_prevents_sampling(self):
        self.identities[202] = self.identity(202, 200, 200, self.identities[201]['executable'])
        with mock.patch.object(D.BOUNDED, 'darwin_group_snapshot', return_value={200: 'S', 201: 'S', 202: 'S'}):
            with self.assertRaisesRegex(ValueError, 'exactly one'):
                D.owned_target(100, 200, self.identities.__getitem__)
        count = 0
        def changed(pid):
            nonlocal count
            value = self.identities[pid].copy()
            if pid == 201:
                count += 1
                if count > 1:
                    value['birthMicroseconds'] += 1
            return value
        with mock.patch.object(D.BOUNDED, 'darwin_group_snapshot', return_value={200: 'S', 201: 'S'}):
            with self.assertRaisesRegex(ValueError, 'identity changed'):
                D.owned_target(100, 200, changed)

    def test_sampler_rechecks_identity_and_bounds_its_own_file_before_exec(self):
        request = self.root / 'sample.request.json'
        value = self.snapshot()
        request.write_text(json.dumps(value))
        output = self.root / 'sample.txt'
        with mock.patch.object(D, 'ProcessIdentity'), mock.patch.object(D, 'owned_target', return_value=value), \
             mock.patch.object(D.resource, 'setrlimit') as limit, mock.patch.object(D.os, 'execv') as execute:
            D.sample_exec(request, output)
        self.assertIn(mock.call(D.resource.RLIMIT_FSIZE, (2 * 1024 * 1024, 2 * 1024 * 1024)), limit.call_args_list)
        self.assertEqual(execute.call_args.args, ('/usr/bin/sample',
            ['/usr/bin/sample', '201', '2', '10', '-mayDie', '-file', str(output)]))
        changed = json.loads(json.dumps(value))
        changed['target']['birthMicroseconds'] += 1
        with mock.patch.object(D, 'ProcessIdentity'), mock.patch.object(D, 'owned_target', return_value=changed), \
             mock.patch.object(D.os, 'execv') as execute:
            with self.assertRaisesRegex(ValueError, 'target changed'):
                D.sample_exec(request, output)
            execute.assert_not_called()

    def test_capture_uses_original_native_command_and_independent_short_wrapper(self):
        self.args.directory.mkdir()
        self.args.diagnostics.mkdir()
        report = self.args.directory / 'shard-3-runner.json'
        report.write_text(json.dumps({'status': 'running', 'timeout_seconds': 420,
            'command': D.NATIVE.expected_command(self.plan['shards'][3]), 'pid': 200}))
        child = SimpleNamespace(pid=100, poll=lambda: None)
        with mock.patch.object(D, 'owned_target', return_value=self.snapshot()), \
             mock.patch.object(D.subprocess, 'Popen') as launch:
            D.start_capture(self.args, child, report, 180, lambda _: None)
        argv = launch.call_args.args[0]
        self.assertEqual(argv[argv.index('--timeout-seconds') + 1], '8')
        self.assertEqual(argv[argv.index('--grace-seconds') + 1], '0.5')
        self.assertEqual(argv[argv.index('--max-log-bytes') + 1], str(256 * 1024))
        self.assertNotIn('shell', launch.call_args.kwargs)
        self.assertEqual(D.native_command(self.args)[2:], ['run', '--plan', str(self.plan_path),
            '--expected-source', self.source, '--index', '3', '--directory', str(self.args.directory)])

    def capture_fixture(self):
        self.args.directory.mkdir()
        self.args.diagnostics.mkdir()
        report = self.args.directory / 'shard-3-runner.json'
        report.write_text(json.dumps({'status': 'running', 'timeout_seconds': 420,
            'command': D.NATIVE.expected_command(self.plan['shards'][3]), 'pid': 200}))
        return report, SimpleNamespace(pid=100, poll=lambda: None), self.snapshot()

    def test_request_hash_read_failure_prevents_sampler_launch(self):
        report, child, request = self.capture_fixture()
        with mock.patch.object(D, 'owned_target', return_value=request), \
             mock.patch.object(Path, 'read_bytes', side_effect=OSError('injected request hash read failure')), \
             mock.patch.object(D.subprocess, 'Popen') as launch:
            with self.assertRaisesRegex(OSError, 'injected request hash'):
                D.start_capture(self.args, child, report, 180, lambda _: None)
        launch.assert_not_called()

    def test_sampler_handle_returns_without_any_post_launch_metadata_read(self):
        report, child, request = self.capture_fixture()
        sampler = SimpleNamespace(pid=202)
        launched = False
        reads = []
        original = Path.read_bytes
        def read(path):
            if launched:
                raise OSError('metadata read attempted after sampler launch')
            reads.append(path)
            return original(path)
        def launch(*args, **kwargs):
            nonlocal launched
            launched = True
            return sampler
        with mock.patch.object(D, 'owned_target', return_value=request), \
             mock.patch.object(Path, 'read_bytes', new=read), \
             mock.patch.object(D.subprocess, 'Popen', side_effect=launch):
            owned, record = D.start_capture(self.args, child, report, 180, lambda _: None)
        self.assertIs(owned, sampler)
        self.assertEqual(reads, [self.args.diagnostics / 'sample-180.request.json'])
        self.assertEqual(record['requestSHA256'], D.hashlib.sha256(original(reads[0])).hexdigest())
        self.assertIn('selectionSeconds', record)

    def test_suite_preserves_all_four_processes_in_order_after_native_timeout(self):
        self.args.output = self.root / 'aggregate.json'
        self.observation_summaries()
        for failures in ([0, 0, 0, 0], [124, 0, 0, 0]):
            for path in (self.args.output, self.root / 'aggregate-diagnostic-status.json'):
                if path.exists():
                    path.unlink()
            with mock.patch.object(D, 'observe_process', side_effect=[{'returncode': c, 'cancelled': False,
                 'cleanupWaitExpired': False} for c in failures]) as run, \
                 mock.patch.object(D.NATIVE, 'aggregate', return_value={'status': 'passed'}) as aggregate:
                self.assertEqual(D.suite(self.args), int(any(failures)))
            commands = [call.args[0] for call in run.call_args_list]
            self.assertEqual([command[command.index('--index') + 1] for command in commands], ['0', '1', '2', '3'])
            self.assertTrue(all(command[command.index('--output-mode') + 1] == 'baseline' for command in commands))
            self.assertTrue(all(command[command.index('--plan') + 1] == str(self.plan_path) for command in commands))
            aggregate.assert_called_once_with(self.plan, self.args.directory)
            status = json.loads((self.root / 'aggregate-diagnostic-status.json').read_text())
            self.assertTrue(status['cleanupConfirmed'])
            self.assertEqual(status['completedIndices'], [0, 1, 2, 3])

    def observation_summaries(self, unconfirmed=None):
        for index in range(4):
            root = self.args.diagnostics / f'shard-{index}'
            root.mkdir(parents=True, exist_ok=True)
            (root / 'diagnostics.json').write_text(json.dumps({'sourceCommit': self.source, 'index': index,
                'selectedTests': self.plan['shards'][index]['tests'], 'outputMode': 'baseline',
                'cleanupConfirmed': index != unconfirmed, 'nativeEnvelope': {'status': 'timeout'},
                'observationStatus': 'complete'}))

    def test_suite_rejects_focused_selection_and_missing_results(self):
        self.args.output = self.root / 'aggregate.json'
        focused = D.NATIVE.make_plan(self.inventory, 'testCase0$', self.source, process_count=4)
        self.plan_path.write_text(json.dumps(focused))
        with mock.patch.object(D, 'observe_process') as execute, self.assertRaisesRegex(ValueError, 'complete four-process'):
            D.suite(self.args)
        execute.assert_not_called()
        self.plan_path.write_text(json.dumps(self.plan))
        self.observation_summaries()
        with mock.patch.object(D, 'observe_process', return_value={'returncode': 124,
             'cancelled': False, 'cleanupWaitExpired': False}) as execute:
            with self.assertRaisesRegex(ValueError, 'regular input'):
                D.suite(self.args)
        self.assertEqual(execute.call_count, 4)
        self.assertFalse(self.args.output.exists())

    def test_uncertain_cleanup_blocks_every_later_process_and_control(self):
        self.args.output = self.root / 'aggregate.json'
        self.observation_summaries(unconfirmed=0)
        with mock.patch.object(D, 'observe_process', return_value={'returncode': 125,
             'cancelled': False, 'cleanupWaitExpired': False}) as execute:
            with self.assertRaisesRegex(ValueError, 'uncertain cleanup'):
                D.suite(self.args)
        self.assertEqual(execute.call_count, 1)
        status = json.loads((self.root / 'aggregate-diagnostic-status.json').read_text())
        self.assertEqual(status['status'], 'blocked-uncertain-cleanup')
        self.assertFalse(status['cleanupConfirmed'])

    def test_cleanup_wait_expiry_retains_owned_observer_identity_and_blocks_next_process(self):
        self.args.output = self.root / 'aggregate.json'
        outcome = {'returncode': None, 'cancelled': True, 'cleanupWaitExpired': True,
                   'observerPID': 100, 'observerIdentity': self.identities[100]}
        with mock.patch.object(D, 'observe_process', return_value=outcome) as execute:
            with self.assertRaisesRegex(ValueError, 'cleanup was not confirmed'):
                D.suite(self.args)
        self.assertEqual(execute.call_count, 1)
        status = json.loads((self.root / 'aggregate-diagnostic-status.json').read_text())
        self.assertEqual(status['observer']['observerIdentity'], self.identities[100])
        self.assertFalse(status['cleanupConfirmed'])

    def test_missing_stack_capture_is_separate_from_native_success_and_fails_diagnosis(self):
        self.args.output = self.root / 'aggregate.json'
        self.observation_summaries()
        path = self.args.diagnostics / 'shard-3/diagnostics.json'
        value = json.loads(path.read_text())
        value['observationStatus'] = 'incomplete'
        path.write_text(json.dumps(value))
        with mock.patch.object(D, 'observe_process', return_value={'returncode': 0,
             'cancelled': False, 'cleanupWaitExpired': False}), \
             mock.patch.object(D.NATIVE, 'aggregate', return_value={'status': 'passed'}):
            self.assertEqual(D.suite(self.args), 1)
        status = json.loads((self.root / 'aggregate-diagnostic-status.json').read_text())
        self.assertEqual(status['status'], 'observation-incomplete')
        self.assertEqual(status['nativeOutcome'], 'passed')
        self.assertTrue(status['cleanupConfirmed'])
        self.assertFalse(status['observationComplete'])

    def test_fragmented_progress_tracks_complete_events_and_labels_arrival_time(self):
        path = self.root / 'native.log'
        progress = D.Progress(path)
        line = "Test Case '-[PicShotTests.FooTests testOne]' started.\n"
        path.write_text(line[:20])
        self.assertIsNone(progress.read(1)['latestCompleteEvent'])
        with path.open('a') as stream:
            stream.write(line[20:])
        value = progress.read(2)
        self.assertEqual(value['latestCompleteEvent'], {'id': 'PicShotTests.FooTests/testOne',
            'event': 'started', 'observedAtSeconds': 2})
        self.assertEqual(value['readLogBytes'], len(line))
        self.assertIn('not native event execution time', value['scope'])
        self.assertEqual(progress.read(9)['latestCompleteEvent']['observedAtSeconds'], 2)

    def test_diagnostic_capture_failure_cannot_hide_native_failure_or_change_plan(self):
        before = self.plan_path.read_bytes()
        command = [sys.executable, '-c', 'import time; time.sleep(0.08); raise SystemExit(124)']
        with mock.patch.object(D, 'ProcessIdentity', return_value=lambda _: {}), \
             mock.patch.object(D, 'native_command', return_value=command), \
             mock.patch.object(D, 'CAPTURE_AT', (0,)), \
             mock.patch.object(D, 'start_capture', side_effect=ValueError('no unique owned XCTest')):
            started = time.monotonic()
            self.assertEqual(D.run(self.args), 124)
        self.assertLess(time.monotonic() - started, 2)
        summary = json.loads((self.args.diagnostics / 'diagnostics.json').read_text())
        self.assertEqual(summary['nativeExitCode'], 124)
        self.assertEqual(summary['captures'][0]['error'], 'no unique owned XCTest')
        self.assertEqual(summary['selectedTests'], self.plan['shards'][3]['tests'])
        self.assertEqual(self.plan_path.read_bytes(), before)
        self.assertLess(max(D.CAPTURE_AT) + D.SAMPLE_TIMEOUT + D.SAMPLE_GRACE + 2, 420)

    def test_completed_sampler_without_stacks_or_with_reused_pid_is_incomplete(self):
        target = self.identities[201]
        for create_file, changed in [(False, False), (True, True), (True, False)]:
            with self.subTest(create_file=create_file, changed=changed):
                prefix = self.root / f'sample-{create_file}-{changed}'
                if create_file:
                    prefix.with_suffix('.txt').write_text('sampled thread stacks')
                prefix.with_suffix('.runner.json').write_text(json.dumps({'status': 'exited',
                    'exit_code': 0, 'child_returncode': 0, 'timeout_seconds': 8}))
                active = {'prefix': str(prefix), 'target': target,
                          'samplerStartedMonotonic': time.monotonic()}
                after = {**target, 'birthMicroseconds': 13} if changed else target
                D.finish_capture(active, SimpleNamespace(returncode=0), lambda _: after)
                self.assertEqual(active['status'], 'captured' if create_file and not changed else 'incomplete')

    def bounded(self, prefix, code, timeout='4'):
        return [sys.executable, str(Path(D.__file__).with_name('run-bounded-command.py')),
            '--timeout-seconds', timeout, '--grace-seconds', '0.1',
            '--log', str(prefix.with_suffix('.log')), '--report', str(prefix.with_suffix('.json')),
            '--', sys.executable, '-c', code]

    def test_external_cancel_reaches_unchanged_native_wrapper_and_its_child(self):
        prefix = self.root / 'cancel'
        command = self.bounded(prefix, 'import time; time.sleep(60)')
        timer = threading.Timer(0.2, lambda: os.kill(os.getpid(), signal.SIGTERM))
        with mock.patch.object(D, 'ProcessIdentity', return_value=lambda _: {}), \
             mock.patch.object(D, 'native_command', return_value=command):
            started = time.monotonic()
            timer.start()
            try:
                self.assertEqual(D.run(self.args), 143)
            finally:
                timer.cancel()
                timer.join()
        self.assertLess(time.monotonic() - started, 2)
        report = json.loads(prefix.with_suffix('.json').read_text())
        self.assertEqual(report['status'], 'cancelled')
        self.assertEqual(report['exit_code'], 143)
        self.assertEqual(report['child_returncode'], -signal.SIGTERM)
        self.assertTrue(report['sigterm_sent'])

    def test_native_deadline_remains_independent_and_cleans_active_sampler(self):
        native_prefix = self.root / 'native-deadline'
        native_command = self.bounded(native_prefix, 'import time; time.sleep(60)', timeout='0.2')
        sample_prefix = self.root / 'sample-cleanup'
        sampler_command = self.bounded(sample_prefix, 'import time; time.sleep(60)')
        def capture(*_):
            child = subprocess.Popen(sampler_command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return child, {'prefix': str(sample_prefix), 'target': self.identities[201],
                           'samplerStartedMonotonic': time.monotonic()}
        with mock.patch.object(D, 'ProcessIdentity', return_value=self.identities.__getitem__), \
             mock.patch.object(D, 'native_command', return_value=native_command), \
             mock.patch.object(D, 'CAPTURE_AT', (0,)), mock.patch.object(D, 'start_capture', side_effect=capture):
            started = time.monotonic()
            self.assertEqual(D.run(self.args), 124)
        self.assertLess(time.monotonic() - started, 2)
        native = json.loads(native_prefix.with_suffix('.json').read_text())
        sample = json.loads(sample_prefix.with_suffix('.json').read_text())
        self.assertEqual(native['status'], 'timeout')
        self.assertEqual(native['exit_code'], 124)
        self.assertLess(native['duration_seconds'], 0.8)
        self.assertEqual(sample['status'], 'cancelled')
        self.assertEqual(sample['child_returncode'], -signal.SIGTERM)

    def test_native_cleanup_wait_expiry_preserves_live_identity(self):
        child = SimpleNamespace(pid=100, returncode=None, poll=lambda: None,
            terminate=mock.Mock(), wait=mock.Mock(side_effect=subprocess.TimeoutExpired('native', 7)))
        original = D.save
        writes = 0
        def disk_failure(path, value):
            nonlocal writes
            writes += 1
            if writes == 2:
                raise OSError('synthetic observer write failure')
            return original(path, value)
        with mock.patch.object(D, 'ProcessIdentity', return_value=self.identities.__getitem__), \
             mock.patch.object(D.subprocess, 'Popen', return_value=child), mock.patch.object(D, 'save', side_effect=disk_failure):
            with self.assertRaises(OSError):
                D.run(self.args)
        summary = json.loads((self.args.diagnostics / 'diagnostics.json').read_text())
        self.assertFalse(summary['cleanupConfirmed'])
        self.assertEqual(summary['unconfirmedOwnedProcesses'][0]['identity'], self.identities[100])
        child.terminate.assert_called_once()
        child.wait.assert_called_once_with(timeout=7)

    def test_sampler_cleanup_wait_expiry_preserves_native_failure_and_live_identity(self):
        self.identities[202] = self.identity(202, os.getpid(), os.getpgrp(), '/usr/bin/python3')
        sampler = SimpleNamespace(pid=202, returncode=None, poll=lambda: None,
            terminate=mock.Mock(), wait=mock.Mock(side_effect=subprocess.TimeoutExpired('sampler', 2)))
        active = {'prefix': str(self.root / 'stuck-sample'), 'target': self.identities[201],
                  'samplerStartedMonotonic': time.monotonic(), 'slotSeconds': 0}
        command = [sys.executable, '-c', 'import time; time.sleep(0.08); raise SystemExit(124)']
        with mock.patch.object(D, 'ProcessIdentity', return_value=self.identities.__getitem__), \
             mock.patch.object(D, 'native_command', return_value=command), mock.patch.object(D, 'CAPTURE_AT', (0,)), \
             mock.patch.object(D, 'start_capture', return_value=(sampler, active)):
            self.assertEqual(D.run(self.args), 124)
        summary = json.loads((self.args.diagnostics / 'diagnostics.json').read_text())
        self.assertFalse(summary['cleanupConfirmed'])
        self.assertEqual(summary['unconfirmedOwnedProcesses'][0]['identity'], self.identities[202])
        self.assertEqual(summary['observationStatus'], 'incomplete')
        sampler.terminate.assert_called_once()

    def test_suite_cancellation_is_forwarded_to_its_owned_observer(self):
        timer = threading.Timer(0.15, lambda: os.kill(os.getpid(), signal.SIGTERM))
        timer.start()
        try:
            result = D.observe_process([sys.executable, '-c', 'import time; time.sleep(60)'])
        finally:
            timer.cancel()
            timer.join()
        self.assertTrue(result['cancelled'])
        self.assertFalse(result['cleanupWaitExpired'])
        self.assertEqual(result['returncode'], -signal.SIGTERM)

    @unittest.skipUnless(sys.platform == 'darwin', 'requires the actual Darwin libproc ABI')
    def test_native_darwin_process_identity_matches_owned_observer(self):
        value = D.ProcessIdentity()(os.getpid())
        self.assertEqual(value['pid'], os.getpid())
        self.assertEqual(value['parentPID'], os.getppid())
        self.assertEqual(value['groupID'], os.getpgrp())
        self.assertEqual(value['uid'], os.getuid())
        self.assertTrue(Path(value['executable']).is_file())


if __name__ == '__main__':
    unittest.main()
