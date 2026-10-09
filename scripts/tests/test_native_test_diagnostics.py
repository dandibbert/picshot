import ctypes
import errno
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
            os.getpid(): self.identity(os.getpid(), os.getppid(), os.getpgrp(), '/usr/bin/python3'),
            100: self.identity(100, 99, 99, '/usr/bin/python3'),
            200: self.identity(200, 100, 200, '/Applications/Xcode.app/Contents/Developer/usr/bin/swift-test'),
            201: self.identity(201, 200, 200, '/Applications/Xcode.app/Contents/Developer/usr/bin/xctest'),
        }

    def binding_fixture(self):
        initial = self.identity(100, os.getpid(), os.getpgrp(), '/opt/python/bin/python3')
        current = dict(initial)
        executable = '/opt/python/Resources/Python.app/Contents/MacOS/Python'
        identify = mock.Mock(side_effect=lambda _: current.copy())
        process = SimpleNamespace(pid=100, poll=mock.Mock(return_value=None))
        binding = D.WrapperBinding(process, identify, executable)
        command = ['swift', 'test', '--skip-build']
        report = {'status': 'running', 'pid': 200, 'command': command, 'timeout_seconds': 420}
        return binding, current, executable, process, command, report

    def test_wrapper_startup_exec_is_allowed_until_verified_handshake_then_fully_pinned(self):
        binding, current, executable, process, command, report = self.binding_fixture()
        initial = current.copy()
        self.assertIsNone(binding.observe(None, command, 420))
        current['executable'] = executable
        self.assertIsNone(binding.observe({**report, 'status': 'starting', 'pid': None}, command, 420))
        self.assertIsNone(binding.stable)
        stable = binding.observe(report, command, 420)
        self.assertEqual(stable, current)
        self.assertEqual(binding.record['initialIdentity'], initial)
        self.assertEqual(binding.record['stableIdentity'], current)
        self.assertEqual(binding.record['status'], 'bound')
        self.assertEqual(binding.record['initialToStableDifferences'], {
            'executable': {'expected': initial['executable'], 'current': executable}})

    def test_wrong_ready_executable_retains_exact_difference_and_never_binds(self):
        binding, current, executable, process, command, report = self.binding_fixture()
        current['executable'] = '/tmp/unexpected-python'
        with self.assertRaisesRegex(ValueError, 'exact known interpreter'):
            binding.observe(report, command, 420)
        self.assertIsNone(binding.stable)
        self.assertEqual(binding.record['status'], 'blocked')
        self.assertEqual(binding.record['executableDifferences']['executable'],
                         {'expected': executable, 'current': current['executable']})

    def test_wrapper_lifetime_continuity_rejects_pid_uid_parent_group_and_birth_changes(self):
        for field in D.WrapperBinding.ANCHOR_FIELDS:
            with self.subTest(field=field):
                binding, current, executable, process, command, report = self.binding_fixture()
                current['executable'] = executable
                original = current[field]
                current[field] += 1
                with self.assertRaisesRegex(ValueError, 'lifetime identity changed'):
                    binding.observe(report, command, 420)
                self.assertEqual(binding.record['anchorDifferences'][field],
                                 {'expected': original, 'current': original + 1})
                self.assertIsNone(binding.stable)

    def test_post_handshake_executable_change_is_sticky_and_retains_both_snapshots(self):
        binding, current, executable, process, command, report = self.binding_fixture()
        current['executable'] = executable
        stable = binding.observe(report, command, 420).copy()
        current['executable'] = '/tmp/replacement'
        with self.assertRaisesRegex(ValueError, 'Stable wrapper identity changed'):
            binding.observe(report, command, 420)
        current['executable'] = executable
        with self.assertRaisesRegex(ValueError, 'already blocked'):
            binding.observe(report, command, 420)
        self.assertEqual(binding.record['firstError'], 'Stable wrapper identity changed')
        self.assertEqual(binding.record['stableIdentity'], stable)
        self.assertEqual(binding.record['stableDifferences']['executable']['current'], '/tmp/replacement')

    def test_unowned_initial_identity_is_archived_and_blocks_binding(self):
        initial = self.identity(100, os.getpid() + 1, 99, '/opt/launcher')
        process = SimpleNamespace(pid=100, poll=lambda: None)
        binding = D.WrapperBinding(process, lambda _: initial.copy(), '/opt/interpreter')
        self.assertEqual(binding.record['initialIdentity'], initial)
        self.assertEqual(binding.record['initialOwnershipDifferences']['parentPID']['expected'], os.getpid())
        self.assertEqual(binding.record['status'], 'blocked')

    def test_initial_identity_read_failure_is_archived_without_losing_owned_process(self):
        process = SimpleNamespace(pid=100, poll=lambda: None)
        binding = D.WrapperBinding(process, mock.Mock(side_effect=OSError('injected identity failure')), '/opt/interpreter')
        self.assertIs(binding.process, process)
        self.assertIsNone(binding.record['initialIdentity'])
        self.assertIn('injected identity failure', binding.record['initialIdentityError'])
        self.assertEqual(binding.record['status'], 'blocked')

    def test_wrong_handshake_missing_envelope_and_early_exit_cannot_bind(self):
        changes = ({'command': ['other']}, {'timeout_seconds': 421}, {'status': 'exited'},
                   {'pid': True}, {'status': 'unexpected'})
        for change in changes:
            with self.subTest(change=change):
                binding, current, executable, process, command, report = self.binding_fixture()
                current['executable'] = executable
                with self.assertRaises(ValueError):
                    binding.observe({**report, **change}, command, 420)
                self.assertIsNone(binding.stable)
        binding, current, executable, process, command, report = self.binding_fixture()
        self.assertIsNone(binding.observe(None, command, 420))
        process.poll.return_value = 0
        with self.assertRaisesRegex(ValueError, 'exited during readiness'):
            binding.observe(report, command, 420)
        self.assertIsNone(binding.stable)

    def test_ownership_uses_settled_wrapper_and_preserves_binding_failure(self):
        binding, current, executable, process, command, report = self.binding_fixture()
        ownership = D.Ownership(None, binding=binding)
        report_path = self.root / 'runner.json'
        ownership.observe(process, report_path, command, binding.identify)
        self.assertIsNone(ownership.wrapper)
        self.assertFalse(ownership.record['uncertainCensus'])
        current['executable'] = executable
        report_path.write_text(json.dumps(report))
        snapshot = self.snapshot()
        snapshot['wrapper'] = current.copy()
        with mock.patch.object(D, 'owned_target', return_value=snapshot) as census:
            ownership.observe(process, report_path, command, binding.identify)
        self.assertEqual(census.call_args.kwargs['expected_wrapper'], current)
        current['executable'] = '/tmp/changed-after-ready'
        ownership.observe(process, report_path, command, binding.identify)
        self.assertTrue(ownership.record['uncertainCensus'])
        self.assertEqual(binding.record['status'], 'blocked')

    def test_settled_binding_selects_descendant_that_the_startup_executable_pin_rejects(self):
        binding, current, executable, process, command, report = self.binding_fixture()
        launch = current.copy()
        current['executable'] = executable
        stable = binding.observe(report, command, 420)
        self.identities[100] = current.copy()
        self.identities[201]['groupID'] = 201
        with self.assertRaises(D.SelectionError) as rejected:
            D.owned_target(100, 200, self.identities.__getitem__, self.children, expected_wrapper=launch)
        self.assertEqual(rejected.exception.census['expectedWrapper'], launch)
        self.assertEqual(rejected.exception.census['wrapperDifferences'], {
            'executable': {'expected': launch['executable'], 'current': executable}})
        selected = D.owned_target(100, 200, self.identities.__getitem__, self.children, expected_wrapper=stable)
        self.assertEqual(selected['target']['pid'], 201)
        self.assertTrue(selected['complete'])

    def test_completed_between_outer_loop_and_observe_does_not_query_reaped_pid_or_invent_cleanup(self):
        binding, current, executable, process, command, report = self.binding_fixture()
        current['executable'] = executable
        binding.observe(report, command, 420)
        ownership = D.Ownership(binding.stable, binding=binding)
        ownership.accept(self.snapshot())
        report_path = self.root / 'completed-runner.json'
        report_path.write_text(json.dumps(report))
        self.assertIsNone(process.poll())  # The observer's outer loop saw it live.
        process.poll.return_value = 0
        binding.identify.reset_mock()
        ownership.observe(process, report_path, command, binding.identify)
        binding.identify.assert_not_called()
        self.assertEqual(binding.record['status'], 'completed')
        self.assertFalse(ownership.record['uncertainCensus'])
        self.assertEqual(ownership.targets, [self.identities[201]])
        self.assertNotIn('cleanupConfirmed', binding.record)

    def test_verified_terminal_envelope_avoids_live_binding_during_wrapper_finish(self):
        binding, current, executable, process, command, report = self.binding_fixture()
        current['executable'] = executable
        binding.observe(report, command, 420)
        binding.identify.reset_mock()
        self.assertIsNone(binding.observe({**report, 'status': 'timeout'}, command, 420))
        binding.identify.assert_not_called()
        self.assertEqual(binding.record['status'], 'finishing')
        self.assertIsNone(binding.record['wrapperReturnCode'])
        self.assertNotIn('cleanupConfirmed', binding.record)

    def test_pid_disappearing_during_live_read_requires_owned_popen_completion(self):
        for completed in (True, False):
            with self.subTest(completed=completed):
                binding, current, executable, process, command, report = self.binding_fixture()
                current['executable'] = executable
                binding.observe(report, command, 420)
                process.poll.side_effect = [None, 0 if completed else None]
                binding.identify.side_effect = ProcessLookupError(errno.ESRCH, 'exited during read')
                if completed:
                    self.assertIsNone(binding.observe(report, command, 420))
                    self.assertEqual(binding.record['status'], 'completed')
                else:
                    with self.assertRaises(ProcessLookupError):
                        binding.observe(report, command, 420)
                    self.assertEqual(binding.record['status'], 'blocked')

    def test_verified_terminating_envelope_keeps_live_identity_checks_and_separate_cleanup(self):
        for reason in ('exited', 'timeout', 'cancelled'):
            with self.subTest(reason=reason):
                binding, current, executable, process, command, report = self.binding_fixture()
                current['executable'] = executable
                binding.observe(report, command, 420)
                binding.identify.reset_mock()
                stopping = {**report, 'status': 'terminating', 'termination_reason': reason}
                self.assertIsNone(binding.observe(stopping, command, 420))
                binding.identify.assert_called_once_with(process.pid)
                self.assertEqual(binding.record['status'], 'finishing')
                self.assertNotIn('cleanupConfirmed', binding.record)
                current['executable'] = '/tmp/replaced-while-terminating'
                with self.assertRaisesRegex(ValueError, 'Stable wrapper identity changed'):
                    binding.observe(stopping, command, 420)

    def test_executable_read_failure_only_resolves_when_owned_popen_confirms_completion(self):
        for completed in (True, False):
            with self.subTest(completed=completed):
                binding, current, executable, process, command, report = self.binding_fixture()
                current['executable'] = executable
                binding.observe(report, command, 420)
                process.poll.side_effect = [None, 0 if completed else None]
                binding.identify.side_effect = ValueError('Cannot read executable identity (errno 3); retirement unproven')
                if completed:
                    self.assertIsNone(binding.observe(report, command, 420))
                    self.assertEqual(binding.record['status'], 'completed')
                    self.assertEqual(binding.record['identityReadAtCompletionErrorType'], 'ValueError')
                    self.assertNotIn('cleanupConfirmed', binding.record)
                else:
                    with self.assertRaisesRegex(ValueError, 'retirement unproven'):
                        binding.observe(report, command, 420)
                    self.assertEqual(binding.record['status'], 'blocked')

    def test_terminating_before_binding_or_with_unverified_reason_cannot_be_accepted(self):
        binding, current, executable, process, command, report = self.binding_fixture()
        current['executable'] = executable
        with self.assertRaisesRegex(ValueError, 'Invalid terminating'):
            binding.observe({**report, 'status': 'terminating', 'termination_reason': 'timeout'}, command, 420)
        binding, current, executable, process, command, report = self.binding_fixture()
        current['executable'] = executable
        binding.observe(report, command, 420)
        with self.assertRaisesRegex(ValueError, 'Invalid terminating'):
            binding.observe({**report, 'status': 'terminating', 'termination_reason': 'unknown'}, command, 420)

    @staticmethod
    def identity(pid, parent, group, executable):
        return {'pid': pid, 'parentPID': parent, 'groupID': group, 'uid': os.getuid(),
                'birthSeconds': 100000, 'birthMicroseconds': 12, 'executable': executable}

    def snapshot(self):
        return D.owned_target(100, 200, lambda pid: self.identities[pid].copy(), self.children)

    def children(self, pid):
        return [child for child, value in self.identities.items() if value['parentPID'] == pid]

    def test_public_darwin_identity_layout_has_birth_time_and_no_argument_or_environment_fields(self):
        self.assertEqual(ctypes.sizeof(D.BSDInfo), 136)
        self.assertEqual(D.BSDInfo.start_seconds.offset, 120)
        self.assertEqual(D.BSDInfo.start_microseconds.offset, 128)

    def test_executable_path_esrch_is_unknown_until_process_lookup_confirms_exit(self):
        reader = object.__new__(D.ProcessIdentity)
        def info(pid, _flavor, _argument, pointer, _size):
            pointer._obj.pid = pid
            pointer._obj.start_seconds = 100000
            pointer._obj.start_microseconds = 12
            return ctypes.sizeof(D.BSDInfo)
        def missing(*_):
            ctypes.set_errno(errno.ESRCH)
            return 0
        reader.library = SimpleNamespace(proc_pidinfo=info, proc_pidpath=missing)
        with mock.patch.object(D.os, 'kill') as kill:
            result = D.retire_targets([self.identities[201]], reader)
        self.assertFalse(result['confirmed'])
        self.assertEqual(result['targets'][0]['state'], 'unknown')
        self.assertIn('retirement unproven', result['targets'][0]['error'])
        kill.assert_not_called()
        reader.library.proc_pidinfo = missing
        with self.assertRaises(D.PIDInfoAbsent) as absent:
            reader(201)
        self.assertEqual(absent.exception.filename,201)
        self.assertEqual(D.target_state(self.identities[201], reader)['state'], 'retired')

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
        mutations = [(200, 'parentPID', 999), (201, 'uid', os.getuid() + 1),
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
        with self.assertRaisesRegex(ValueError, 'exactly one'):
            D.owned_target(100, 200, self.identities.__getitem__, self.children)
        del self.identities[202]
        count = 0
        def changed(pid):
            nonlocal count
            value = self.identities[pid].copy()
            if pid == 201:
                count += 1
                if count > 1:
                    value['birthMicroseconds'] += 1
            return value
        with self.assertRaisesRegex(ValueError, 'identity changed'):
            D.owned_target(100, 200, changed, self.children)

    def test_swiftpm_xctest_in_new_group_is_selected_by_parent_chain(self):
        self.identities[201]['groupID'] = 201
        value = self.snapshot()
        self.assertEqual(value['target']['pid'], 201)
        self.assertNotEqual(value['target']['groupID'], value['leader']['groupID'])
        self.assertTrue(value['complete'])
        self.assertEqual(value['candidatePIDs'], [201])

    def test_both_exact_xctest_paths_are_recognized_under_the_owned_swiftpm_xcode(self):
        developer = '/Applications/Xcode.app/Contents/Developer'
        self.identities[200]['executable'] = developer + '/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-package'
        self.identities[201]['groupID'] = 201
        for relative in D.XCTEST_RELATIVE_EXECUTABLES:
            with self.subTest(relative=relative):
                self.identities[201]['executable'] = developer + '/' + relative
                census = self.snapshot()
                self.assertEqual(census['xcodeDeveloperDirectory'], developer)
                self.assertEqual(census['candidatePIDs'], [201])
                ownership = D.Ownership(self.identities[100])
                ownership.accept(census)
                self.assertEqual(ownership.targets, [self.identities[201]])

    def test_wrong_xcode_platform_basename_and_noncanonical_paths_are_ineligible(self):
        developer = '/Applications/Xcode.app/Contents/Developer'
        agent = developer + '/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/xctest'
        wrong = [agent.replace('Xcode.app', 'OtherXcode.app'),
                 agent.replace('MacOSX.platform', 'iPhoneOS.platform'), '/tmp/xctest',
                 agent + '-helper', agent.replace('/Agents/', '/Agents/../Agents/'),
                 developer + '/usr/bin/not-xctest']
        for executable in wrong:
            with self.subTest(executable=executable):
                self.identities[201]['executable'] = executable
                with self.assertRaises(D.SelectionError) as rejected:
                    self.snapshot()
                self.assertTrue(rejected.exception.census['complete'])
                self.assertEqual(rejected.exception.census['candidatePIDs'], [])
                ownership = D.Ownership(self.identities[100])
                ownership.accept(rejected.exception.census)
                self.assertEqual(ownership.targets, [])

    def test_unresolved_startup_swift_root_has_no_target_without_fabricating_incomplete_census(self):
        self.identities[200]['executable'] = '/usr/bin/swift'
        with self.assertRaises(D.SelectionError) as rejected:
            self.snapshot()
        self.assertTrue(rejected.exception.census['complete'])
        self.assertIsNone(rejected.exception.census['xcodeDeveloperDirectory'])
        self.assertEqual(rejected.exception.census['candidatePIDs'], [])
        ownership = D.Ownership(self.identities[100])
        ownership.accept(rejected.exception.census)
        self.assertFalse(ownership.record['uncertainCensus'])
        self.assertEqual(ownership.targets, [])

    def test_two_allowed_xctest_executables_are_ambiguous_and_both_remain_owned_for_cleanup(self):
        developer = '/Applications/Xcode.app/Contents/Developer'
        self.identities[202] = self.identity(202, 200, 202, developer + '/' + D.XCTEST_RELATIVE_EXECUTABLES[1])
        with self.assertRaises(D.SelectionError) as rejected:
            self.snapshot()
        self.assertEqual(rejected.exception.census['candidatePIDs'], [201, 202])
        ownership = D.Ownership(self.identities[100])
        ownership.accept(rejected.exception.census)
        self.assertTrue(ownership.record['uncertainCensus'])
        self.assertEqual([target['pid'] for target in ownership.targets], [201, 202])

    def test_selected_developer_root_requires_an_actual_known_swift_tool_location(self):
        developer = '/Applications/Xcode_16.4.app/Contents/Developer'
        for name in ('swift', 'swift-frontend', 'swift-package', 'swift-test'):
            value = {'executable': developer + '/Toolchains/XcodeDefault.xctoolchain/usr/bin/' + name}
            self.assertEqual(D.xcode_developer_directory(value), developer)
        for executable in ('/tmp/swift-package', developer + '/usr/bin/unrelated',
                           developer + '/Toolchains/Unknown.xctoolchain/usr/bin/swift-package'):
            self.assertIsNone(D.xcode_developer_directory({'executable': executable}))

    def test_nested_child_groups_are_followed_but_unrelated_same_named_process_is_not(self):
        self.identities[202] = self.identity(202, 200, 202, '/usr/bin/helper')
        self.identities[201].update(parentPID=202, groupID=201)
        self.identities[999] = self.identity(999, 1, 999, self.identities[201]['executable'])
        self.assertEqual([member['pid'] for member in self.snapshot()['members']], [200, 202, 201])

    def test_failed_selection_keeps_census_and_never_confirms_empty_cleanup(self):
        del self.identities[201]
        with self.assertRaises(D.SelectionError) as raised:
            self.snapshot()
        census = raised.exception.census
        self.assertEqual(census['candidatePIDs'], [])
        self.assertEqual(census['members'], [self.identities[200]])
        self.assertTrue(census['anchorValidated'])
        with mock.patch.object(D.os, 'kill') as kill:
            result = D.retire_targets([], self.identities.__getitem__)
        self.assertFalse(result['confirmed'])
        kill.assert_not_called()

    def disappearing_child(self, second_read, reenumeration=None):
        missing=mock.Mock(side_effect=[D.PIDInfoAbsent(202),second_read])
        def identify(pid):
            return missing() if pid==202 else self.identities[pid].copy()
        lists=mock.Mock(side_effect=[[202,201], [201] if reenumeration is None else reenumeration])
        def children(pid):
            return lists() if pid==200 else []
        return mock.Mock(side_effect=identify),mock.Mock(side_effect=children),missing

    def test_twice_absent_enumerated_child_is_recorded_but_never_owned_or_signalled(self):
        identify,children,missing=self.disappearing_child(D.PIDInfoAbsent(202))
        with mock.patch.object(D.os,'kill') as signal_pid:
            census=D.owned_target(100,200,identify,children)
            ownership=D.Ownership(self.identities[100]);ownership.accept(census)
        signal_pid.assert_not_called()
        self.assertEqual(missing.call_count,2)
        self.assertTrue(census['complete'])
        self.assertFalse(census['atomicSnapshot'])
        self.assertEqual([member['pid'] for member in census['members']],[200,201])
        self.assertEqual(census['candidatePIDs'],[201])
        row=census['vanishedChildObservations'][0]
        self.assertEqual(row['pid'],202)
        self.assertTrue(row['confirmedAbsent'])
        self.assertEqual(row['parent'],row['parentAfter'])
        self.assertEqual(row['parentChildPIDsAfter'],[201])
        self.assertEqual(row['firstAbsence']['origin'],'proc_pidinfo')
        self.assertEqual(row['secondAbsence']['origin'],'proc_pidinfo')
        self.assertGreaterEqual(row['secondAbsence']['elapsedSecondsSinceCensusStart'],
                                row['firstAbsence']['elapsedSecondsSinceCensusStart'])
        self.assertEqual(ownership.targets,[self.identities[201]])
        self.assertFalse(ownership.record['uncertainCensus'])
        self.assertIn('not global descendant cleanup',census['scope'])
        ownership.accept(self.snapshot())
        self.assertEqual(ownership.record['vanishedChildEvidence']['first'],row)

    def test_only_second_typed_pid_info_absence_can_resolve_the_edge(self):
        live=self.identity(202,200,202,'/usr/bin/helper')
        for second in (live,dict(live,uid=os.getuid()+1),dict(live,birthSeconds=99999),
                       OSError(errno.EACCES,'denied'),OSError(errno.ESRCH,'unspecified source'),
                       ValueError('Cannot read executable identity (errno 3)'),D.PIDInfoAbsent(999)):
            with self.subTest(second=second):
                identify,children,_=self.disappearing_child(second)
                with self.assertRaises(D.SelectionError) as rejected:
                    D.owned_target(100,200,identify,children)
                census=rejected.exception.census
                self.assertFalse(census['complete'])
                self.assertFalse(census['vanishedChildObservations'][0]['confirmedAbsent'])
                ownership=D.Ownership(self.identities[100]);ownership.accept(census)
                ownership.accept(self.snapshot())
                self.assertTrue(ownership.record['uncertainCensus'])
                self.assertEqual(ownership.targets,[self.identities[201]])
                self.assertEqual(children.call_count,1)

    def test_first_path_or_untyped_absence_remains_an_unknown_child(self):
        for first in (ValueError('Cannot read executable identity (errno 3)'),
                      OSError(errno.ESRCH,'unproven origin'),D.PIDInfoAbsent(999)):
            with self.subTest(first=first):
                identify,children,missing=self.disappearing_child(D.PIDInfoAbsent(202))
                missing.side_effect=[first]
                with self.assertRaises(D.SelectionError) as rejected:
                    D.owned_target(100,200,identify,children)
                self.assertFalse(rejected.exception.census['complete'])
                self.assertEqual(missing.call_count,1)

    def test_parent_identity_change_or_child_reappearance_keeps_uncertainty(self):
        for field in ('pid','parentPID','groupID','uid','birthSeconds','birthMicroseconds','executable'):
            with self.subTest(field=field):
                identify,children,_=self.disappearing_child(D.PIDInfoAbsent(202))
                original=identify.side_effect;count=0
                def changed(pid):
                    nonlocal count
                    value=original(pid)
                    if pid==200:
                        count+=1
                        if count==2:value[field]=value[field]+1 if type(value[field]) is int else value[field]+'.changed'
                    return value
                identify.side_effect=changed
                with self.assertRaisesRegex(D.SelectionError,'Parent identity changed'):
                    D.owned_target(100,200,identify,children)
        for current in ([202,201],[201,201],[0],[True],list(range(1000,1065))):
            with self.subTest(children=current):
                identify,children,_=self.disappearing_child(D.PIDInfoAbsent(202),current)
                with self.assertRaises(D.SelectionError) as rejected:
                    D.owned_target(100,200,identify,children)
                self.assertFalse(rejected.exception.census['complete'])
                self.assertFalse(rejected.exception.census['vanishedChildObservations'][0]['confirmedAbsent'])

    def test_new_children_seen_during_absence_recheck_are_traversed_and_remain_ambiguous(self):
        for executable in ('/usr/bin/helper',self.identities[201]['executable']):
            with self.subTest(executable=executable):
                self.identities[203]=self.identity(203,200,203,executable)
                identify,children,_=self.disappearing_child(D.PIDInfoAbsent(202),[201,203])
                if executable=='/usr/bin/helper':
                    census=D.owned_target(100,200,identify,children)
                    self.assertEqual([m['pid'] for m in census['members']],[200,201,203])
                    self.assertEqual(census['candidatePIDs'],[201])
                else:
                    with self.assertRaises(D.SelectionError) as rejected:
                        D.owned_target(100,200,identify,children)
                    self.assertEqual(rejected.exception.census['candidatePIDs'],[201,203])

    def test_final_identity_recheck_absence_and_birth_change_are_never_reconciled(self):
        for pid,at in ((100,2),(200,3),(201,2)):
            for failure in ('absent','birth-changed'):
                with self.subTest(pid=pid,failure=failure):
                    identify,children,_=self.disappearing_child(D.PIDInfoAbsent(202))
                    original=identify.side_effect;count=0
                    def changed(current_pid):
                        nonlocal count
                        value=original(current_pid)
                        if current_pid==pid:
                            count+=1
                            if count==at:
                                if failure=='absent':raise D.PIDInfoAbsent(pid)
                                value['birthMicroseconds']+=1
                        return value
                    identify.side_effect=changed
                    with self.assertRaises(D.SelectionError) as rejected:
                        D.owned_target(100,200,identify,children)
                    census=rejected.exception.census
                    self.assertFalse(census['complete'])
                    self.assertTrue(census['vanishedChildObservations'][0]['confirmedAbsent'])
                    ownership=D.Ownership(self.identities[100]);ownership.accept(census)
                    self.assertTrue(ownership.record['uncertainCensus'])

    def test_vanished_children_consume_the_existing_member_bound(self):
        def identify(pid):
            if pid in (202,203):raise D.PIDInfoAbsent(pid)
            return self.identities[pid].copy()
        lists=iter([[202,203,201],[203,201],[201]])
        children=lambda pid: next(lists) if pid==200 else []
        with mock.patch.object(D,'MAX_DIAGNOSTIC_MEMBERS',3), \
             self.assertRaisesRegex(D.SelectionError,'member bound') as rejected:
            D.owned_target(100,200,identify,children)
        self.assertEqual(len(rejected.exception.census['vanishedChildObservations']),2)
        self.assertFalse(rejected.exception.census['complete'])

    def test_vanished_evidence_first_latest_copies_and_counts_are_bounded(self):
        record={}
        observations=[dict(pid=i,confirmedAbsent=i!=2,parent=dict(pid=200)) for i in range(4)]
        for observation in observations:
            D.remember_vanished_children(record,{'vanishedChildObservations':[observation]})
        observations[0]['parent']['pid']=999
        evidence=record['vanishedChildEvidence']
        self.assertEqual((evidence['totalCount'],evidence['confirmedAbsentCount'],evidence['unresolvedCount']),(4,3,1))
        self.assertEqual((evidence['retainedCount'],evidence['omittedCount']),(2,2))
        self.assertEqual(evidence['first']['pid'],0)
        self.assertEqual(evidence['first']['parent']['pid'],200)
        self.assertEqual(evidence['latest']['pid'],3)

    def startup_child_fixture(self, transitions=None):
        root='/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/'
        self.identities[200]['executable']=root+'swift-package'
        initial=self.identity(202,200,200,root+'swift-package')
        settled=dict(initial,groupID=202,executable=root+'swift-driver')
        sequence=iter([initial]+(transitions if transitions is not None else [settled]*4))
        child_reads=[];traversal_reads=[]
        def identify(pid):
            if pid==202:
                value=next(sequence,settled)
                child_reads.append(value)
                if isinstance(value,Exception):raise value
                return value.copy()
            return self.identities[pid].copy()
        def children(pid):
            if pid==202:traversal_reads.append(len(child_reads))
            return [202,201] if pid==200 else []
        return initial,settled,identify,children,child_reads,traversal_reads

    def test_provisional_fork_child_stabilizes_before_traversal_and_target_selection(self):
        initial,settled,identify,children,reads,traversals=self.startup_child_fixture()
        census=D.owned_target(100,200,identify,children,expected_wrapper=self.identities[100])
        row=census['initialChildObservations'][0]
        self.assertEqual(row['before'],initial)
        self.assertEqual(row['after'],settled)
        self.assertEqual(row['status'],'stabilized')
        self.assertEqual(set(row['differences']),{'groupID','executable'})
        self.assertFalse(row['acceptedAsOwnedTarget'])
        self.assertEqual(row['identityReads'],3)
        self.assertEqual(len(row['observations']),3)
        self.assertEqual(traversals,[4])
        self.assertEqual(census['candidatePIDs'],[201])
        self.assertEqual(row['totalCensusBudgetSeconds'],0.2)

    def test_provisional_child_lifetime_path_and_group_changes_remain_failures(self):
        initial,settled,*_=self.startup_child_fixture()
        changes={'pid':999,'parentPID':999,'uid':os.getuid()+1,'birthSeconds':99999,
                 'birthMicroseconds':999,'groupID':999,'executable':'/tmp/swift-driver'}
        for field,value in changes.items():
            with self.subTest(field=field):
                _,_,identify,children,_,traversals=self.startup_child_fixture([dict(settled,**{field:value})])
                with self.assertRaises(D.SelectionError) as rejected:
                    D.owned_target(100,200,identify,children,expected_wrapper=self.identities[100])
                census=rejected.exception.census;row=census['initialChildObservations'][0]
                self.assertFalse(census['complete'])
                self.assertEqual(row['status'],'unresolved')
                self.assertEqual(row['after'][field],value)
                self.assertIn(field,row['differences'])
                self.assertEqual(traversals,[])
        for error in (D.PIDInfoAbsent(202),OSError(errno.EACCES,'denied'),
                      ValueError('Cannot read executable identity (errno 3)')):
            with self.subTest(error=error):
                _,_,identify,children,_,traversals=self.startup_child_fixture([error])
                with self.assertRaises(D.SelectionError) as rejected:
                    D.owned_target(100,200,identify,children,expected_wrapper=self.identities[100])
                row=rejected.exception.census['initialChildObservations'][0]
                self.assertEqual(row['status'],'unresolved')
                self.assertIsNone(row['observations'][-1]['identity'])
                self.assertIn('error',row['observations'][-1])
                self.assertEqual(traversals,[])

    def test_provisional_child_group_cannot_return_to_inherited_group_or_exhaust_bounds(self):
        initial,settled,*_=self.startup_child_fixture()
        for transitions in ([settled,dict(settled,groupID=200)], [initial]*D.INITIAL_CHILD_READS,
                            [settled,dict(settled,executable=settled['executable'].replace('swift-driver','swift-frontend'))]*3):
            _,_,identify,children,_,traversals=self.startup_child_fixture(transitions)
            with self.assertRaises(D.SelectionError) as rejected:
                D.owned_target(100,200,identify,children,expected_wrapper=self.identities[100])
            self.assertFalse(rejected.exception.census['complete'])
            self.assertEqual(traversals,[])
        _,_,identify,children,reads,traversals=self.startup_child_fixture([initial]*6)
        clock=[0.0]
        with mock.patch.object(D.time,'monotonic',side_effect=lambda:clock[0]), \
             mock.patch.object(D.time,'sleep',side_effect=lambda _:clock.__setitem__(0,0.3)):
            with self.assertRaisesRegex(D.SelectionError,'deadline exhausted'):
                D.owned_target(100,200,identify,children,expected_wrapper=self.identities[100])
        self.assertEqual(len(reads),2)
        self.assertEqual(traversals,[])

    def test_known_leader_or_target_never_uses_provisional_child_rebinding(self):
        _,_,identify,children,_,_=self.startup_child_fixture()
        with self.assertRaisesRegex(D.SelectionError,'identity changed') as rejected:
            D.owned_target(100,200,identify,children,expected_wrapper=self.identities[100],
                           expected_leader=self.identities[200])
        self.assertEqual(rejected.exception.census['initialChildObservations'],[])
        failure=rejected.exception.census['identityRecheckFailure']
        self.assertEqual(failure['before']['pid'],202)
        self.assertEqual(set(failure['differences']),{'groupID','executable'})
        count=[0]
        def changed_target(pid):
            value=self.identities[pid].copy()
            if pid==201:
                count[0]+=1
                if count[0]>1:value['executable']='/tmp/replacement'
            return value
        with self.assertRaises(D.SelectionError) as rejected:
            D.owned_target(100,200,changed_target,self.children,expected_wrapper=self.identities[100])
        self.assertEqual(rejected.exception.census['initialChildObservations'],[])
        self.assertEqual(rejected.exception.census['identityRecheckFailure']['after']['executable'],'/tmp/replacement')

    def test_unbound_wrapper_and_unapproved_xcode_executables_cannot_admit_a_child(self):
        _,_,identify,children,_,_=self.startup_child_fixture()
        with self.assertRaises(D.SelectionError) as rejected:
            D.owned_target(100,200,identify,children)
        self.assertEqual(rejected.exception.census['initialChildObservations'],[])
        initial,settled,*_=self.startup_child_fixture()
        for path in (settled['executable'].replace('Xcode.app','OtherXcode.app'),
                     settled['executable'].replace('swift-driver','clang')):
            _,_,identify,children,_,traversals=self.startup_child_fixture([dict(settled,executable=path)])
            with self.assertRaisesRegex(D.SelectionError,'allowlist'):
                D.owned_target(100,200,identify,children,expected_wrapper=self.identities[100])
            self.assertEqual(traversals,[])

    def test_stabilized_child_does_not_hide_new_or_newly_execed_ambiguous_xctest(self):
        self.identities[203]=self.identity(203,200,203,self.identities[201]['executable'])
        _,_,identify,children,_,_=self.startup_child_fixture()
        calls=[0]
        def added(pid):
            if pid==200:
                calls[0]+=1
                if calls[0]>1:return [202,201,203]
            return children(pid)
        with self.assertRaises(D.SelectionError) as rejected:
            D.owned_target(100,200,identify,added,expected_wrapper=self.identities[100])
        self.assertTrue(rejected.exception.census['complete'])
        self.assertEqual(rejected.exception.census['candidatePIDs'],[201,203])
        del self.identities[203]
        initial,settled,*_=self.startup_child_fixture()
        xctest=dict(settled,executable=self.identities[201]['executable'])
        _,_,identify,children,_,_=self.startup_child_fixture([xctest]*4)
        with self.assertRaises(D.SelectionError) as rejected:
            D.owned_target(100,200,identify,children,expected_wrapper=self.identities[100])
        census=rejected.exception.census
        self.assertTrue(census['complete'])
        self.assertEqual(census['candidatePIDs'],[202,201])
        self.assertFalse(census['initialChildObservations'][0]['acceptedAsOwnedTarget'])

    def test_stabilized_child_requires_unchanged_anchors_edge_and_final_identity(self):
        for changed_pid in (100,200):
            _,_,identify,children,_,traversals=self.startup_child_fixture()
            original=identify;counts={}
            def changed(pid):
                value=original(pid);counts[pid]=counts.get(pid,0)+1
                if pid==changed_pid and counts[pid]==2:value['birthMicroseconds']+=1
                return value
            with self.assertRaisesRegex(D.SelectionError,'wrapper or leader'):
                D.owned_target(100,200,changed,children,expected_wrapper=self.identities[100])
            self.assertEqual(traversals,[])
        _,settled,identify,children,_,traversals=self.startup_child_fixture()
        enum_count=[0]
        def detached(pid):
            if pid==200:
                enum_count[0]+=1
                if enum_count[0]>1:return [201]
            return children(pid)
        with self.assertRaisesRegex(D.SelectionError,'parent edge'):
            D.owned_target(100,200,identify,detached,expected_wrapper=self.identities[100])
        self.assertEqual(traversals,[])
        _,_,identify,children,_,_=self.startup_child_fixture([settled,settled,settled,dict(settled,birthMicroseconds=999)])
        with self.assertRaisesRegex(D.SelectionError,'identity changed') as rejected:
            D.owned_target(100,200,identify,children,expected_wrapper=self.identities[100])
        self.assertEqual(rejected.exception.census['identityRecheckFailure']['after']['birthMicroseconds'],999)

    def test_147_adjacent_snapshots_replay_with_bound_parent_and_no_accepted_candidate(self):
        # These are adjacent archived observations, NOT the missing failed147 recheck value.
        root='/Applications/Xcode_16.4.app/Contents/Developer/'
        wrapper=dict(pid=3091,parentPID=2514,groupID=2514,uid=501,birthSeconds=1791544534,
            birthMicroseconds=588834,executable='/opt/homebrew/Cellar/python@3.14/3.14.7/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python')
        leader=dict(pid=3092,parentPID=3091,groupID=3092,uid=501,birthSeconds=1791544534,
            birthMicroseconds=694226,executable=root+'Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-package')
        before=dict(pid=3101,parentPID=3092,groupID=3092,uid=501,birthSeconds=1791544535,
            birthMicroseconds=353542,executable=leader['executable'])
        after=dict(before,groupID=3101,executable=root+'Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-driver')
        target=dict(pid=3124,parentPID=3092,groupID=3124,uid=501,birthSeconds=1791544536,
            birthMicroseconds=534983,executable=root+'Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/xctest')
        phase=[0];reads=[0]
        def identify(pid):
            if pid==3101:
                reads[0]+=1
                return (before if reads[0]==1 else after).copy()
            return {3091:wrapper,3092:leader,3124:target}[pid].copy()
        identify.children=lambda pid:([3101] if phase[0]==0 else [3124]) if pid==3092 else []
        report=self.root/'147-running.json';command=['swift','test','--skip-build']
        report.write_text(json.dumps(dict(status='running',pid=3092,timeout_seconds=420,command=command)))
        native=SimpleNamespace(pid=3091,poll=lambda:None)
        ownership=D.Ownership(wrapper.copy())
        with mock.patch.object(D.os,'getuid',return_value=501):
            ownership.observe(native,report,command,identify)
            self.assertIsNone(ownership.leader)
            self.assertEqual(ownership.targets,[])
            self.assertFalse(ownership.record['uncertainCensus'])
            self.assertEqual(ownership.record['initialChildEvidence']['first']['before'],before)
            self.assertEqual(ownership.record['initialChildEvidence']['first']['after'],after)
            phase[0]=1
            ownership.observe(native,report,command,identify)
        self.assertEqual(ownership.leader,leader)
        self.assertEqual(ownership.targets,[target])
        self.assertFalse(ownership.record['uncertainCensus'])

    def test_wrong_wrapper_or_leader_birth_rejects_before_traversal(self):
        for keyword, pid in (('expected_wrapper', 100), ('expected_leader', 200)):
            expected = {**self.identities[pid], 'birthMicroseconds': 11}
            children = mock.Mock(side_effect=self.children)
            with self.assertRaises(D.SelectionError) as raised:
                D.owned_target(100, 200, self.identities.__getitem__, children, **{keyword: expected})
            self.assertFalse(raised.exception.census['anchorValidated'])
            children.assert_not_called()

    def test_reparenting_during_census_or_beyond_depth_and_member_caps_rejects(self):
        calls = 0
        def changed(pid):
            nonlocal calls
            value = self.identities[pid].copy()
            if pid == 201:
                calls += 1
                if calls > 1:
                    value['parentPID'] = 1
            return value
        with self.assertRaisesRegex(D.SelectionError, 'identity changed'):
            D.owned_target(100, 200, changed, self.children)
        with mock.patch.object(D, 'MAX_DIAGNOSTIC_DEPTH', 0), self.assertRaisesRegex(D.SelectionError, 'depth bound'):
            self.snapshot()
        with mock.patch.object(D, 'MAX_DIAGNOSTIC_MEMBERS', 1), self.assertRaisesRegex(D.SelectionError, 'member bound'):
            self.snapshot()

    def test_owned_reparented_target_retirement_uses_pid_and_rechecks_before_signal(self):
        target = {**self.identities[201], 'groupID': 201}
        current = {**target, 'parentPID': 1, 'groupID': 301}
        reads = []
        alive = True
        def identify(pid):
            reads.append(pid)
            if not alive:
                raise ProcessLookupError(errno.ESRCH, 'exited')
            return current.copy()
        def kill(pid, signum):
            nonlocal alive
            self.assertEqual(reads[-1], 201)
            self.assertEqual((pid, signum), (201, signal.SIGTERM))
            alive = False
        with mock.patch.object(D.os, 'kill', side_effect=kill) as signal_pid, \
             mock.patch.object(D.os, 'killpg') as signal_group:
            result = D.retire_targets([target], identify)
        self.assertTrue(result['confirmed'])
        self.assertEqual(result['targets'][0]['signals'], [signal.SIGTERM])
        signal_pid.assert_called_once()
        signal_group.assert_not_called()

    def test_pid_reuse_or_changed_uid_executable_never_receives_a_signal(self):
        target = self.identities[201]
        for key, replacement, confirmed in (('birthMicroseconds', 13, True),
                ('uid', os.getuid() + 1, False), ('executable', '/tmp/replacement', False)):
            with self.subTest(key=key), mock.patch.object(D.os, 'kill') as kill:
                result = D.retire_targets([target], lambda _: {**target, key: replacement})
                self.assertEqual(result['confirmed'], confirmed)
                kill.assert_not_called()

    def test_inaccessible_target_remains_unknown_and_blocks_cleanup(self):
        with mock.patch.object(D.os, 'kill') as kill:
            result = D.retire_targets([self.identities[201]],
                mock.Mock(side_effect=PermissionError(errno.EPERM, 'no identity access')))
        self.assertFalse(result['confirmed'])
        self.assertEqual(result['targets'][0]['state'], 'unknown')
        kill.assert_not_called()

    def test_live_target_at_cleanup_deadline_retains_identity_and_bounded_failure(self):
        with mock.patch.object(D.os, 'kill') as kill:
            started = time.monotonic()
            result = D.retire_targets([self.identities[201]], self.identities.__getitem__, budget_seconds=0.02)
        self.assertLess(time.monotonic() - started, 0.2)
        self.assertFalse(result['confirmed'])
        self.assertEqual(result['targets'][0]['state'], 'live')
        self.assertEqual(result['targets'][0]['identity'], self.identities[201])
        self.assertEqual(kill.call_args.args, (201, signal.SIGTERM))

    def test_kill_escalation_rechecks_birth_and_does_not_signal_reused_pid(self):
        target = self.identities[201]
        now = 0
        signalled = False
        def clock():
            nonlocal now
            now += 0.1
            return now
        def identify(_):
            return {**target, 'birthMicroseconds': 13} if signalled else target.copy()
        def kill(*_):
            nonlocal signalled
            signalled = True
        with mock.patch.object(D.time, 'monotonic', side_effect=clock), \
             mock.patch.object(D.time, 'sleep'), mock.patch.object(D.os, 'kill', side_effect=kill) as send:
            result = D.retire_targets([target], identify)
        self.assertTrue(result['confirmed'])
        send.assert_called_once_with(201, signal.SIGTERM)

    def test_still_owned_target_escalation_is_rechecked_and_bounded(self):
        now = 0
        reads = []
        alive = True
        def clock():
            nonlocal now
            now += 0.04
            return now
        def identify(pid):
            reads.append(pid)
            if not alive:
                raise ProcessLookupError(errno.ESRCH, 'exited')
            return self.identities[pid].copy()
        def kill(pid, signum):
            nonlocal alive
            self.assertEqual(reads[-1], pid)
            reads.clear()
            if signum == signal.SIGKILL:
                alive = False
        with mock.patch.object(D.time, 'monotonic', side_effect=clock), \
             mock.patch.object(D.time, 'sleep'), mock.patch.object(D.os, 'kill', side_effect=kill) as send:
            result = D.retire_targets([self.identities[201]], identify)
        self.assertTrue(result['confirmed'])
        self.assertEqual(send.call_args_list, [mock.call(201, signal.SIGTERM), mock.call(201, signal.SIGKILL)])
        self.assertLess(result['durationSeconds'], 2)

    def test_ownership_keeps_partial_census_uncertainty_after_later_success(self):
        ownership = D.Ownership(self.identities[100])
        census = {'complete': False, 'anchorValidated': True,
                  'members': [self.identities[200]], 'error': 'Identity access failed'}
        ownership.accept(census)
        ownership.accept(self.snapshot())
        self.assertTrue(ownership.record['uncertainCensus'])
        self.assertEqual(ownership.record['firstFailedCensus'], census)
        self.assertEqual(ownership.targets, [self.identities[201]])
        self.assertEqual(ownership.record['successfulCensuses'], 1)

    def test_startup_pending_and_empty_complete_census_do_not_invent_a_target(self):
        ownership = D.Ownership(self.identities[100])
        ownership.accept({'pending': 'Awaiting original bounded runner envelope', 'complete': False})
        del self.identities[201]
        with self.assertRaises(D.SelectionError) as raised:
            self.snapshot()
        ownership.accept(raised.exception.census)
        self.assertEqual(ownership.targets, [])
        self.assertEqual(ownership.record['successfulCensuses'], 0)
        self.assertFalse(ownership.record['uncertainCensus'])

    def test_observe_pins_launch_identity_and_reuses_leader_after_selection(self):
        self.args.directory.mkdir()
        report = self.args.directory / 'shard-3-runner.json'
        command = D.NATIVE.expected_command(self.plan['shards'][3])
        report.write_text(json.dumps({'status': 'running', 'timeout_seconds': 420, 'command': command, 'pid': 200}))
        ownership = D.Ownership(self.identities[100])
        native = SimpleNamespace(pid=100, poll=lambda: None)
        identify = mock.Mock(side_effect=lambda pid: self.identities[pid].copy())
        identify.children = self.children
        ownership.observe(native, report, command, identify)
        self.assertEqual(ownership.leader, self.identities[200])
        self.assertEqual(ownership.targets, [self.identities[201]])
        self.identities[200]['birthMicroseconds'] += 1
        ownership.observe(native, report, command, identify)
        self.assertTrue(ownership.record['uncertainCensus'])
        self.assertIn('leader identity changed', ownership.record['lastCensus']['error'])

    def test_unknown_census_blocks_cleanup_even_when_known_target_and_wrappers_retired(self):
        command = [sys.executable, '-c', 'import time; time.sleep(0.08); raise SystemExit(124)']
        ownership = D.Ownership(self.identities[100])
        ownership.accept(self.snapshot())
        ownership.accept({'complete': False, 'error': 'Unknown descendant identity'})
        ownership.observe = mock.Mock()
        with mock.patch.object(D, 'ProcessIdentity', return_value=self.identities.__getitem__), \
             mock.patch.object(D, 'native_command', return_value=command), \
             mock.patch.object(D, 'Ownership', return_value=ownership), \
             mock.patch.object(D, 'cleanup_evidence', return_value=(True, {'status': 'timeout'})), \
             mock.patch.object(D, 'retire_targets', return_value={'confirmed': True, 'targets': []}):
            self.assertEqual(D.run(self.args), 124)
        summary = json.loads((self.args.diagnostics / 'diagnostics.json').read_text())
        self.assertTrue(summary['nativeCleanupConfirmed'])
        self.assertTrue(summary['nativeXCTestCleanupConfirmed'])
        self.assertFalse(summary['cleanupConfirmed'])
        self.assertEqual(summary['nativeExitCode'], 124)

    def test_native_success_without_any_owned_xctest_evidence_is_diagnostic_failure(self):
        command = [sys.executable, '-c', 'pass']
        with mock.patch.object(D, 'ProcessIdentity', return_value=lambda _: {'executable': sys.executable}), \
             mock.patch.object(D, 'native_command', return_value=command), \
             mock.patch.object(D, 'cleanup_evidence', return_value=(True, {'status': 'exited'})):
            self.assertEqual(D.run(self.args), 125)
        summary = json.loads((self.args.diagnostics / 'diagnostics.json').read_text())
        self.assertFalse(summary['nativeXCTestCleanupConfirmed'])
        self.assertFalse(summary['cleanupConfirmed'])
        self.assertEqual(summary['observationStatus'], 'incomplete')

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

    def test_sampler_final_census_is_archived_before_exec_including_rejected_edges(self):
        request=self.root/'last-census.request.json';output=self.root/'last-census.txt'
        original=self.snapshot();request.write_text(json.dumps(original))
        late=dict(pid=202,confirmedAbsent=True,phase='initial-enumerated-child-identity')
        current=dict(original,vanishedChildObservations=[late])
        def inspect_before_exec(*_):
            saved=json.loads(output.with_suffix('.identity.json').read_text())
            self.assertEqual(saved['status'],'validated')
            self.assertEqual(saved['census']['vanishedChildObservations'],[late])
            self.assertEqual(saved['phase'],'sampler-pre-exec-census')
        with mock.patch.object(D,'ProcessIdentity'),mock.patch.object(D,'owned_target',return_value=current), \
             mock.patch.object(D.resource,'setrlimit'),mock.patch.object(D.os,'execv',side_effect=inspect_before_exec) as execute:
            D.sample_exec(request,output)
        execute.assert_called_once()
        failed=dict(current,complete=False,error='second read denied')
        failed_output=self.root/'rejected-census.txt'
        with mock.patch.object(D,'ProcessIdentity'), \
             mock.patch.object(D,'owned_target',side_effect=D.SelectionError('second read denied',failed)), \
             mock.patch.object(D.os,'execv') as execute:
            with self.assertRaises(D.SelectionError):
                D.sample_exec(request,failed_output)
        execute.assert_not_called()
        saved=json.loads(failed_output.with_suffix('.identity.json').read_text())
        self.assertEqual(saved['status'],'rejected')
        self.assertEqual(saved['error'],'second read denied')
        self.assertEqual(saved['census'],failed)

    def test_sampler_cannot_exec_if_final_census_save_fails_or_exceeds_cap(self):
        request=self.root/'save-failure.request.json';output=self.root/'save-failure.txt'
        original=self.snapshot();request.write_text(json.dumps(original))
        with mock.patch.object(D,'ProcessIdentity'),mock.patch.object(D,'owned_target',return_value=original), \
             mock.patch.object(D,'save',side_effect=OSError('metadata write denied')), \
             mock.patch.object(D.os,'execv') as execute:
            with self.assertRaisesRegex(OSError,'metadata write denied'):
                D.sample_exec(request,output)
        execute.assert_not_called()
        with mock.patch.object(D,'ProcessIdentity'), \
             mock.patch.object(D,'owned_target',return_value=dict(original,padding='x'*(D.METADATA_CAP+1))), \
             mock.patch.object(D.os,'execv') as execute:
            with self.assertRaisesRegex(ValueError,'metadata exceeded'):
                D.sample_exec(request,output)
        execute.assert_not_called()
        self.assertFalse(output.with_suffix('.identity.json').exists())

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
        self.assertEqual(argv[argv.index('--timeout-seconds') + 1], '20')
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
        with mock.patch.object(D, 'ProcessIdentity', return_value=lambda _: {'executable': sys.executable}), \
             mock.patch.object(D, 'native_command', return_value=command), \
             mock.patch.object(D, 'CAPTURE_AT', (0,)), \
             mock.patch.object(D, 'start_capture', side_effect=ValueError('no unique owned XCTest')):
            started = time.monotonic()
            self.assertEqual(D.run(self.args), 124)
        self.assertLess(time.monotonic() - started, 2)
        summary = json.loads((self.args.diagnostics / 'diagnostics.json').read_text())
        self.assertEqual(summary['nativeExitCode'], 124)
        self.assertEqual(summary['captures'][0]['error'], 'no unique owned XCTest')
        self.assertIn('initialIdentity', summary['wrapperBinding'])
        self.assertEqual(summary['wrapperBinding']['status'], 'blocked')
        self.assertIn('initialIdentityError', summary['wrapperBinding'])
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
                    'exit_code': 0, 'child_returncode': 0, 'timeout_seconds': 20}))
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
        with mock.patch.object(D, 'ProcessIdentity', return_value=lambda _: {'executable': sys.executable}), \
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
