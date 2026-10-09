import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location('observer_self_test', Path(__file__).parents[1]/'native-observer-self-test.py')
S = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(S)


class ObserverSelfTestContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.output = self.root/'evidence'
        self.output.mkdir()
        self.wrapper = self.identity(100, 90, 90, '/usr/bin/python3')
        self.leader = self.identity(200, 100, 200, '/usr/bin/swift-test')
        self.target = self.identity(300, 200, 300, '/Applications/Xcode.app/Contents/Developer/usr/bin/xctest')
        self.snapshot = dict(complete=True, anchorValidated=True, wrapper=self.wrapper,
            leader=self.leader, target=self.target, members=[self.leader, self.target], candidatePIDs=[300])
        self.identify = mock.Mock(side_effect=lambda pid: {100:self.wrapper, 200:self.leader, 300:self.target}[pid])
        self.harness = S.Harness(self.output, 'a'*40, self.identify)

    @staticmethod
    def identity(pid, parent, group, executable):
        return dict(pid=pid, parentPID=parent, groupID=group, uid=os.getuid(), birthSeconds=1000,
                    birthMicroseconds=15, executable=executable)

    def retirement(self, confirmed=True):
        return dict(confirmed=confirmed, targets=[dict(identity=self.target, signals=[],
                    state='retired' if confirmed else 'unknown')])

    def mark_success(self):
        self.harness.targets=[self.target]
        self.harness.report.update(ancestryVerified=True, separateXCTestProcessGroupObserved=True,
            stackIdentityVerified=True, wrongBirthRejected=True, wrongIdentitySignalRejected=True,
            normalExitVerified=True, cancellationVerified=True, timeoutRetirementVerified=True)
        self.harness.package=self.root/'package'
        self.harness.package.mkdir()

    def test_fixture_is_archived_exactly_and_only_as_separate_test_package(self):
        package, archive = self.root/'package', self.root/'archive'
        records=S.fixture(package,archive)
        self.assertEqual(set(records),{'Package.swift','Tests/ObserverSelfTestTests/ObserverOwnershipTests.swift'})
        for name in records:
            self.assertEqual((package/name).read_bytes(),(archive/name).read_bytes())
        self.assertIn('Thread.sleep(forTimeInterval: 0.01)', S.TEST)
        self.assertIn('addingTimeInterval(60)', S.TEST)
        self.assertNotIn('PicShotTests', S.PACKAGE)

    def test_actual_separate_process_group_and_ancestry_are_required(self):
        self.assertEqual(S.require_snapshot(self.snapshot,self.wrapper,self.leader),self.target)
        changed=copy.deepcopy(self.snapshot)
        changed['target']['groupID']=200
        with self.assertRaisesRegex(ValueError,'separate XCTest'):
            S.require_snapshot(changed,self.wrapper,self.leader)
        changed=copy.deepcopy(self.snapshot)
        changed['target']['parentPID']=999
        with self.assertRaisesRegex(ValueError,'parent edge'):
            S.require_snapshot(changed,self.wrapper,self.leader)

    def test_incomplete_census_can_never_establish_readiness(self):
        for field in ('complete','anchorValidated'):
            changed=dict(self.snapshot,**{field:False})
            with self.assertRaises(ValueError):
                S.require_snapshot(changed,self.wrapper,self.leader)

    def test_complete_startup_without_candidate_is_pending(self):
        self.harness.remember_census(dict(complete=True,anchorValidated=True,members=[self.leader],candidatePIDs=[]))
        self.assertFalse(self.harness.census_uncertain)
        self.assertEqual(self.harness.targets,[])

    def test_unknown_census_is_sticky_after_later_success(self):
        self.harness.remember_census(dict(complete=False,anchorValidated=True,members=[],candidatePIDs=[]))
        self.harness.remember_census(self.snapshot)
        self.assertTrue(self.harness.census_uncertain)
        self.assertEqual(self.harness.targets,[self.target])

    def test_ambiguous_verified_candidates_are_retained_but_not_success(self):
        other=self.identity(301,200,301,self.target['executable'])
        self.harness.remember_census(dict(self.snapshot,members=[self.leader,self.target,other],candidatePIDs=[300,301]))
        self.assertEqual(self.harness.targets,[self.target,other])
        self.assertTrue(self.harness.census_uncertain)

    def test_startup_does_not_pin_a_pre_exec_swift_leader(self):
        prefix=self.output/'native'
        prefix.with_suffix('.runner.json').write_text(json.dumps(dict(status='running',pid=200)))
        ready=self.output/'fixture.ready'; ready.write_text('ready')
        native=mock.Mock(pid=100); native.poll.return_value=None
        with mock.patch.object(S.D,'owned_target',return_value=self.snapshot) as owned:
            found=self.harness.target(native,prefix,ready)
        self.assertEqual(found,self.snapshot)
        self.assertIsNone(owned.call_args.kwargs['expected_leader'])
        self.assertEqual(owned.call_args.kwargs['expected_wrapper'],self.wrapper)

    def test_complete_zero_candidate_startup_and_exec_transition_are_pending(self):
        prefix=self.output/'native'
        prefix.with_suffix('.runner.json').write_text(json.dumps(dict(status='running',pid=200)))
        ready=self.output/'normal-gate.ready'; ready.write_text('ready')
        native=mock.Mock(pid=100); native.poll.return_value=None
        old_leader=dict(self.leader,executable='/usr/bin/swift')
        pending=dict(complete=True,anchorValidated=True,wrapper=self.wrapper,leader=old_leader,
                     members=[old_leader],candidatePIDs=[])
        with mock.patch.object(S.D,'owned_target',side_effect=[S.D.SelectionError('no target yet',pending),self.snapshot]) as owned:
            result=self.harness.target(native,prefix,ready)
        self.assertEqual(result['leader']['executable'],'/usr/bin/swift-test')
        self.assertFalse(self.harness.census_uncertain)
        self.assertEqual(len(owned.call_args_list),2)
        self.assertTrue(all(call.kwargs['expected_leader'] is None for call in owned.call_args_list))
        attempts=json.loads(prefix.with_suffix('.discovery-attempts.json').read_text())
        self.assertEqual(attempts[0]['census']['candidatePIDs'],[])

    def test_partial_census_history_remains_distinct_from_startup(self):
        prefix=self.output/'native'
        prefix.with_suffix('.runner.json').write_text(json.dumps(dict(status='running',pid=200)))
        ready=self.output/'normal-gate.ready'; ready.write_text('ready')
        native=mock.Mock(pid=100); native.poll.return_value=None
        partial=dict(complete=False,anchorValidated=True,members=[self.leader],candidatePIDs=[])
        with mock.patch.object(S.D,'owned_target',side_effect=[S.D.SelectionError('child enumeration denied',partial),self.snapshot]):
            self.harness.target(native,prefix,ready)
        self.assertTrue(self.harness.census_uncertain)
        attempts=json.loads(prefix.with_suffix('.discovery-attempts.json').read_text())
        self.assertEqual(attempts[0]['error'],'child enumeration denied')

    def test_gate_ready_suffix_matches_archived_swift_fixture(self):
        gate=self.root/'normal-gate'
        self.assertEqual(gate.with_suffix('.ready').name,'normal-gate.ready')
        self.assertIn('gate.appendingPathExtension("ready")', S.TEST)

    def test_swiftpm_debug_symlink_alias_is_not_a_duplicate_executable(self):
        package=self.root/'package'
        actual=package/'.build/arm64-apple-macosx/debug/Fixture.xctest/Contents/MacOS/Fixture'
        actual.parent.mkdir(parents=True); actual.write_bytes(b'fixture')
        alias=package/'.build/debug'
        alias.symlink_to(package/'.build/arm64-apple-macosx/debug',target_is_directory=True)
        aliased=alias/'Fixture.xctest/Contents/MacOS/Fixture'
        with mock.patch.object(Path,'glob',return_value=iter([actual,aliased])):
            self.assertEqual(S.fixture_executable(package),actual.resolve())

    def test_only_generated_cancel_timeout_fixtures_ignore_their_own_sigterm(self):
        self.assertIn('import Darwin', S.TEST)
        self.assertIn('environment["PICSHOT_OBSERVER_SELF_TEST_SURVIVE_TERM"] == "1"', S.TEST)
        self.assertIn('Darwin.signal(SIGTERM, SIG_IGN)', S.TEST)
        self.assertNotIn('SIGKILL', S.TEST)
        for name, expected in [('normal','0'),('cancellation','1'),('timeout','1')]:
            harness=S.Harness(self.output, 'a'*40, self.identify)
            harness.package=self.root/'package'
            with mock.patch.object(harness,'launch',side_effect=ValueError('stop after preparing owned fixture environment')) as launch:
                with self.assertRaisesRegex(ValueError,'stop after'):
                    harness.scenario(name)
            self.assertEqual(launch.call_args.args[3]['PICSHOT_OBSERVER_SELF_TEST_SURVIVE_TERM'],expected)
            self.assertEqual(harness.report['scenarios'][0]['fixtureSignalPolicy'],
                'unchanged' if name=='normal' else 'ignore-own-SIGTERM')

    def test_wrapper_deadline_remains_self_test_specific(self):
        command=S.wrapper_command(['swift','test','--skip-build'],12,self.output/'command')
        self.assertEqual(command[command.index('--timeout-seconds')+1],'12')
        self.assertEqual(command[-3:],['swift','test','--skip-build'])
        self.assertEqual(self.harness.report['originalNativeProcessSeconds'],420)
        self.assertEqual(S.SELF_TEST_SECONDS,300)

    def test_wrong_birth_is_rejected_without_a_sample_or_identity_change(self):
        prefix=self.output/'wrong'
        proc=mock.Mock()
        with mock.patch.object(self.harness,'launch',return_value=proc), \
             mock.patch.object(self.harness,'wait',return_value=1), \
             mock.patch.object(S,'final_envelope',return_value={'status':'exited'}):
            result=self.harness.sample(self.snapshot,prefix,wrong_birth=True)
        request=json.loads(prefix.with_suffix('.request.json').read_text())
        self.assertNotEqual(request['target']['birthSeconds'],self.target['birthSeconds'])
        self.assertTrue(result['rejected'])
        self.assertFalse(prefix.with_suffix('.txt').exists())

    def test_wrong_birth_success_is_a_self_test_failure(self):
        with mock.patch.object(self.harness,'launch',return_value=mock.Mock()), \
             mock.patch.object(self.harness,'wait',return_value=0), \
             mock.patch.object(S,'final_envelope',return_value={'status':'exited'}):
            with self.assertRaisesRegex(ValueError,'Wrong birth'):
                self.harness.sample(self.snapshot,self.output/'wrong',wrong_birth=True)

    def test_stack_requires_fixture_frame_and_matching_identity(self):
        prefix=self.output/'stack'
        prefix.with_suffix('.txt').write_text('UnrelatedStackFrame')
        with mock.patch.object(self.harness,'launch',return_value=mock.Mock()), \
             mock.patch.object(self.harness,'wait',return_value=0), \
             mock.patch.object(S,'final_envelope',return_value={'status':'exited'}):
            with self.assertRaisesRegex(ValueError,'generated XCTest'):
                self.harness.sample(self.snapshot,prefix)
            prefix.with_suffix('.txt').write_text('ObserverOwnershipTests.testWaitForGate')
            self.assertTrue(self.harness.sample(self.snapshot,prefix)['captured'])

    def test_success_requires_actual_retirement_and_removes_only_owned_package(self):
        self.mark_success()
        with mock.patch.object(S.D,'retire_targets',return_value=self.retirement()):
            self.harness.finish()
        self.assertEqual(self.harness.report['status'],'passed')
        self.assertTrue(self.harness.report['temporaryPackageRemoved'])
        self.assertFalse(self.harness.package.exists())

    def test_unknown_retirement_preserves_temporary_package_and_failure(self):
        self.mark_success()
        with mock.patch.object(S.D,'retire_targets',return_value=self.retirement(False)):
            self.harness.finish()
        self.assertEqual(self.harness.report['status'],'failed')
        self.assertTrue(self.harness.package.is_dir())
        self.assertFalse(self.harness.report['cleanupConfirmed'])

    def test_uncertain_census_cannot_be_erased_by_retired_known_targets(self):
        self.mark_success(); self.harness.census_uncertain=True
        with mock.patch.object(S.D,'retire_targets',return_value=self.retirement()):
            self.harness.finish()
        self.assertEqual(self.harness.report['status'],'failed')
        self.assertTrue(self.harness.report['allOwnedTargetsRetired'])
        self.assertFalse(self.harness.report['cleanupConfirmed'])
        self.assertTrue(self.harness.package.exists())

    def test_live_wrapper_blocks_target_signals_and_keeps_failure(self):
        self.mark_success()
        wrapper=mock.Mock(pid=900); wrapper.poll.return_value=None
        wrapper.wait.side_effect=subprocess.TimeoutExpired('wrapper',10)
        self.harness.processes=[wrapper]
        with mock.patch.object(S.D,'retire_targets') as retirement:
            self.harness.finish()
        retirement.assert_not_called()
        self.assertEqual(self.harness.report['status'],'failed')
        self.assertEqual(self.harness.report['unconfirmedWrappers'][0]['wrapperPID'],900)

    def test_cancellation_cannot_be_reported_as_success(self):
        self.mark_success(); self.harness.cancelled=[15]
        with mock.patch.object(S.D,'retire_targets',return_value=self.retirement()):
            self.harness.finish()
        self.assertEqual(self.harness.report['status'],'failed')
        with self.assertRaisesRegex(ValueError,'cancelled'):
            self.harness.checkpoint()

    def test_temporary_removal_failure_is_preserved_in_report(self):
        self.mark_success()
        with mock.patch.object(S.D,'retire_targets',return_value=self.retirement()), \
             mock.patch.object(S.shutil,'rmtree',side_effect=OSError('removal refused')):
            self.harness.finish()
        self.assertEqual(self.harness.report['status'],'failed')
        self.assertEqual(self.harness.report['temporaryPackageCleanupError'],'removal refused')
        self.assertTrue((self.output/'self-test-report.json').is_file())

    def test_wrapper_error_cannot_be_promoted_to_cleanup_confirmation(self):
        with mock.patch.object(S.D,'cleanup_evidence',return_value=(False,{'status':'wrapper_error'})):
            with self.assertRaisesRegex(ValueError,'unproven'):
                S.final_envelope(self.output/'native',125,20)


if __name__ == '__main__':
    unittest.main()
