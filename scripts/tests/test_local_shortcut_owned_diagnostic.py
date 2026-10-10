import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location('shortcut_diagnostic',
    Path(__file__).parents[1] / 'local-shortcut-owned-diagnostic.py')
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)


class ShortcutOwnedDiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name).resolve()
        self.source = self.path / 'product'
        self.developer = self.path / 'Xcode.app/Contents/Developer'
        self.platform = self.developer / 'Platforms/MacOSX.platform'
        self.agent = self.platform / 'Developer/Library/Xcode/Agents/xctest'
        self.agent.parent.mkdir(parents=True)
        self.agent.write_bytes(bytes.fromhex('cffaedfe') + b'fixture Mach-O')
        self.bin_path = self.source / '.build/arm64-apple-macosx/debug'
        self.bundle = self.bin_path / 'PicShotPackageTests.xctest'
        self.binary = self.bundle / 'Contents/MacOS/PicShotPackageTests'
        self.binary.parent.mkdir(parents=True)
        self.binary.write_bytes(b'compiled fixture, never executed')
        self.commit, self.tree = 'a' * 40, 'b' * 40
        inventory = [M.METHOD]
        classes = [f'Fixture.Class{i}' for i in range(231)]
        for method in range(9):
            for cls in classes:
                if len(inventory) < 2047:
                    inventory.append(f'{cls}/test{method}')
        inventory.sort()
        bucket = lambda name: M.O.hashlib.sha256(name.split('/')[0].encode()).digest()[0] % 2
        self.assertEqual(bucket(M.METHOD), 0)
        group0 = sorted([M.METHOD] + [n for n in inventory if n != M.METHOD and bucket(n) == 0][:74])
        selected = sorted(group0 + [n for n in inventory if bucket(n) == 1][:27])
        raw = ('\n'.join(inventory) + '\n').encode()
        self.plan = M.N.make_plan(inventory, M.N.command_pattern(selected), self.commit, M.O.sha(raw))
        self.plan_path = self.path / 'plan.json'
        self.plan_path.write_text(json.dumps(self.plan))
        (self.path / 'native-test-discovery.log').write_bytes(raw)
        self.inventory_sha = M.O.ids_digest(inventory)
        for key, value in (('INVENTORY_SHA256', self.inventory_sha), ('GROUP0_SHA256', M.O.ids_digest(group0))):
            patcher = mock.patch.object(M, key, value)
            patcher.start(); self.addCleanup(patcher.stop)
        self.answers = {
            ('git', 'rev-parse', 'HEAD'): self.commit,
            ('git', 'rev-parse', 'HEAD^{tree}'): self.tree,
            ('git', 'status', '--porcelain', '--untracked-files=no'): '',
            ('git', 'status', '--porcelain', '--untracked-files=all', '--',
             'Package.swift', 'Package.resolved', 'Sources', 'Tests'): '',
            ('/usr/bin/xcode-select', '-p'): str(self.developer),
            ('/usr/bin/xcrun', '--sdk', 'macosx', '--find', 'xctest'): str(self.agent),
            ('/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-platform-path'): str(self.platform),
            ('/usr/bin/xcrun', 'swift', 'build', '--show-bin-path'): str(self.bin_path),
            ('/usr/bin/xcodebuild', '-version'): 'Xcode fixture',
            ('/usr/bin/xcrun', 'swift', '--version'): 'Swift fixture',
            ('/usr/bin/xcrun', 'swift', 'package', '--version'): 'SwiftPM fixture',
        }
        self.sequence = 0

    def args(self, mode='single', **updates):
        self.sequence += 1
        values = dict(selection=mode, single_pass=None, source_root=self.source, bundle=self.bundle,
            plan=self.plan_path, directory=self.path / f'run-{self.sequence}', expected_source=self.commit,
            expected_tree=self.tree, expected_plan_sha256=M.O.file_identity(self.plan_path)['sha256'],
            expected_inventory_sha256=self.inventory_sha,
            expected_bundle_sha256=M.O.file_identity(self.binary)['sha256'])
        values.update(updates)
        return SimpleNamespace(**values)

    def query(self, argv, cwd=None, timeout=20, strip=True):
        self.assertGreater(timeout, 0)
        self.assertLessEqual(timeout, 20)
        value = self.answers[tuple(argv)]
        return value.strip() if strip else value

    def launch(self, args):
        with mock.patch.object(M.sys, 'platform', 'darwin'), \
                mock.patch.dict(M.os.environ, {}, clear=True), mock.patch.object(M.O, 'bounded_read', side_effect=self.query):
            return M.launch_inputs(args)

    def report(self, args, identity, timeout=False):
        args.directory.mkdir()
        target = dict(pid=123, parentPID=os.getpid(), groupID=123, uid=os.getuid(),
            birthSeconds=1234, birthMicroseconds=123, executable=str(self.agent))
        root = dict(pid=123, ownerPID=os.getpid(), identity=target, signals=[], bindingError=None,
            cleanupConfirmed=True, returnCode=-15 if timeout else 0, reapedAtMonotonic=500,
            retirementEvidence='unreaped-exit-observation-then-Popen-wait')
        names = identity['planEvidence']['selectedIDs']
        lines = []
        for name in names:
            cls, method = name.split('/')
            lines.append(f"Test Case '-[{cls} {method}]' started.\n")
            if timeout:
                break
            lines.append(f"Test Case '-[{cls} {method}]' passed (0.1 seconds).\n")
        (args.directory / 'xctest.log').write_text(''.join(lines))
        report = dict(schemaVersion=1, scope=M.O.SCOPE, diagnosticOnly=True, installerAcceptance=False,
            command=M.O.command(str(self.agent), str(self.bundle), names), timeoutSeconds=420,
            samplerTimeoutSeconds=40, expectedCaptureSlots=[180, 360], dueCaptureSlots=[180, 360] if timeout else [],
            status='timeout' if timeout else 'exited', root=root, rootReturnCode=root['returnCode'],
            cleanupConfirmed=True, outputEOF=True, errors=[], logTruncated=False, cancellationSignal=None,
            workloadEndSeconds=420.08 if timeout else 1, terminationStartedAtSeconds=420.08, captures=[],
            logIdentity=M.O.file_identity(args.directory / 'xctest.log'))
        if timeout:
            for index, slot in enumerate(M.SLOTS):
                sampler = {**target, 'pid': 456 + index, 'groupID': 456 + index, 'executable': '/usr/bin/sample'}
                capture = dict(slotSeconds=slot, startedAtSeconds=slot + .01, status='captured',
                    completion='exited', returnCode=0, target=target, targetIdentityAfter=target,
                    targetUnreapedAtCompletion=True, targetExitObservedAtCompletion=False,
                    process=dict(pid=sampler['pid'], ownerPID=os.getpid(), identity=sampler,
                        cleanupConfirmed=True, returnCode=0, bindingError=None, signals=[], reapedAtMonotonic=slot + 3))
                request = dict(slotSeconds=slot, target=target, command=['/usr/bin/sample', '123', '2', '10',
                    '-mayDie', '-file', str(args.directory / f'sample-{slot}.txt')])
                request_path = args.directory / f'sample-{slot}.request.json'
                M.save(request_path, request)
                capture.update(request=request, requestSHA256=M.O.file_identity(request_path)['sha256'])
                sample = args.directory / f'sample-{slot}.txt'
                sample.write_text(f'Process: xctest [123]\nPath: {self.agent}\nCall graph:\n    2 Thread_456\n')
                capture.update(M.O.sample_contents(sample, target))
                M.save(args.directory / f'sample-{slot}.json', capture)
                report['captures'].append(capture)
        M.save(args.directory / 'process.json', report)
        return report

    def receipt(self, args, identity, report):
        cases = M.validate_process(args.directory, report, identity)
        M.save(args.directory / 'result.json', dict(schemaVersion=1, scope=M.SCOPE,
            diagnosticOnly=True, installerAcceptance=False, evidenceStatus='verified',
            inputs=identity, process=report, cases=cases))

    def test_current_source_plan_bundle_identity_and_baseline_environment(self):
        historical = (M.O.SOURCE, M.O.TREE, M.O.INVENTORY_SHA, M.O.IDS_SHA, M.O.FILTER_SHA)
        args = self.args()
        identity, env = self.launch(args)
        self.assertEqual(identity['sourceCommit'], self.commit)
        self.assertEqual(identity['planEvidence']['selectedIDs'], [M.METHOD])
        self.assertEqual(identity['limits']['nativeSeconds'], 420)
        self.assertEqual(identity['limits']['samplerSeconds'], 40)
        self.assertEqual(env['SWIFT_TESTING_ENABLED'], '0')
        self.assertNotIn('NSUnbufferedIO', env)
        self.assertEqual(historical, (M.O.SOURCE, M.O.TREE, M.O.INVENTORY_SHA, M.O.IDS_SHA, M.O.FILTER_SHA))
        self.assertFalse(args.directory.exists())
        self.assertEqual(M.validate_process(args.directory, self.report(args, identity), identity)['status'], 'passed')

    def test_explicit_identity_mismatches_reject_before_workload(self):
        for key, value in (('expected_source', 'c' * 40), ('expected_tree', 'c' * 40),
                ('expected_plan_sha256', '0' * 64), ('expected_inventory_sha256', '0' * 64),
                ('expected_bundle_sha256', '0' * 64), ('expected_tree', 'HEAD')):
            args = self.args(**{key: value})
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.launch(args)
            self.assertFalse(args.directory.exists())

    def test_source_dirty_untracked_or_bad_generated_lock_reject(self):
        key = ('git', 'status', '--porcelain', '--untracked-files=no')
        self.answers[key] = ' M Tests/Changed.swift\n'
        with self.assertRaisesRegex(ValueError, 'Tracked source'):
            self.launch(self.args())
        self.answers[key] = ''
        key = ('git', 'status', '--porcelain', '--untracked-files=all', '--',
               'Package.swift', 'Package.resolved', 'Sources', 'Tests')
        self.answers[key] = '?? Sources/Injected.swift\n'
        with self.assertRaisesRegex(ValueError, 'build inputs'):
            self.launch(self.args())
        self.answers[key] = '?? Package.resolved\n'
        (self.source / 'Package.resolved').write_text('{}')
        with self.assertRaises(ValueError):
            self.launch(self.args())

    def test_selected_xcode_platform_agent_and_canonical_bundle_are_checked(self):
        other = self.path / 'other'; other.mkdir()
        key = ('/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-platform-path')
        self.answers[key] = str(other)
        with self.assertRaisesRegex(ValueError, 'selected macOS platform'):
            self.launch(self.args())
        self.answers[key] = str(self.platform)
        self.agent.write_bytes(b'not Mach-O')
        with self.assertRaisesRegex(ValueError, 'Mach-O'):
            self.launch(self.args())
        self.agent.write_bytes(bytes.fromhex('cffaedfe'))
        with self.assertRaisesRegex(ValueError, 'compiled XCTest bundle'):
            self.launch(self.args(bundle=other))

    def test_discovery_omission_and_group0_substitution_reject(self):
        discovery = self.path / 'native-test-discovery.log'
        discovery.write_text(discovery.read_text().replace(M.METHOD + '\n', ''))
        with self.assertRaisesRegex(ValueError, 'native discovery'):
            self.launch(self.args())
        bad = copy.deepcopy(self.plan)
        bad['shards'][0]['tests'] = bad['shards'][0]['tests'][:-1]
        with self.assertRaisesRegex(ValueError, 'exact 195'):
            M.selection_ids(bad, 'group0')

    def test_timeout_keeps_both_raw_samples_and_valid_owned_cleanup(self):
        args = self.args()
        identity, _ = self.launch(args)
        report = self.report(args, identity, timeout=True)
        self.assertEqual(M.validate_process(args.directory, report, identity)['status'], 'incomplete')
        sample = args.directory / 'sample-180.txt'
        sample.write_text(sample.read_text().replace('[123]', '[999]'))
        with self.assertRaisesRegex(ValueError, 'PID differs'):
            M.validate_process(args.directory, report, identity)

    def test_bad_cleanup_missing_sample_changed_argv_or_cap_reject(self):
        args = self.args()
        identity, _ = self.launch(args)
        good = self.report(args, identity, timeout=True)
        for change in (lambda p: p.update(cleanupConfirmed=False), lambda p: p.update(captures=[]),
                lambda p: p.update(timeoutSeconds=421), lambda p: p['command'].__setitem__(2, 'Other.T/testX'),
                lambda p: p['root'].update(emergencyCleanup={'reason': 'fixture'}),
                lambda p: p.update(outputEOF=False)):
            bad = copy.deepcopy(good); change(bad)
            M.save(args.directory / 'process.json', bad)
            with self.assertRaises(ValueError):
                M.validate_process(args.directory, bad, identity)

    def test_group0_requires_replayed_single_success_and_identical_bundle(self):
        single = self.args()
        identity, _ = self.launch(single)
        report = self.report(single, identity)
        self.receipt(single, identity, report)
        group = self.args('group0', single_pass=single.directory)
        group_identity, _ = self.launch(group)
        self.assertEqual(len(group_identity['planEvidence']['selectedIDs']), 75)
        self.assertEqual(M.verify_single_pass(single.directory, group_identity)['directory'], str(single.directory))
        for key, value in (('sourceTree', 'c' * 40), ('bundleManifestSHA256', '0' * 64),
                ('runtimeEnvironment', {'NSUnbufferedIO': 'YES'})):
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'same source'):
                M.verify_single_pass(single.directory, {**group_identity, key: value})
        (single.directory / 'xctest.log').write_text('tampered')
        with self.assertRaisesRegex(ValueError, 'Raw XCTest log'):
            M.verify_single_pass(single.directory, group_identity)

    def test_timed_out_single_cannot_authorize_group0(self):
        single = self.args()
        identity, _ = self.launch(single)
        report = self.report(single, identity, timeout=True)
        self.receipt(single, identity, report)
        group_identity, _ = self.launch(self.args('group0', single_pass=single.directory))
        with self.assertRaisesRegex(ValueError, 'did not pass'):
            M.verify_single_pass(single.directory, group_identity)

    def test_native_handoff_uses_owned_identity_exact_selection_and_unchanged_cap(self):
        args = self.args()
        captured = []
        def runner(argv, env, cwd, directory, identify, timeout, slots):
            captured.append((argv, cwd, identify, timeout, slots))
            identity = json.loads(directory.with_name(directory.name + '-inputs').joinpath('launch-inputs.json').read_text())
            return self.report(args, identity)
        with mock.patch.object(M.sys, 'platform', 'darwin'), mock.patch.dict(M.os.environ, {}, clear=True), \
                mock.patch.object(M.O, 'bounded_read', side_effect=self.query), \
                mock.patch.object(M.D, 'ProcessIdentity', return_value='owned identity fixture'), \
                mock.patch.object(M.O, 'run_owned', side_effect=runner):
            self.assertEqual(M.run(args), 0)
        self.assertEqual(captured, [(M.O.command(str(self.agent), str(self.bundle), [M.METHOD]),
            str(self.source), 'owned identity fixture', 420, (180, 360))])
        result = json.loads((args.directory / 'result.json').read_text())
        self.assertTrue(result['diagnosticOnly'])
        self.assertFalse(result['installerAcceptance'])
        with mock.patch.object(M, 'launch_inputs') as launch:
            with self.assertRaisesRegex(ValueError, 'requires --single-pass'):
                M.run(self.args('group0'))
            launch.assert_not_called()


if __name__ == '__main__':
    unittest.main()
