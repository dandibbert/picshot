import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


spec = importlib.util.spec_from_file_location('native_shards', Path(__file__).parents[1] / 'native-test-shards.py')
shards = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shards)


class NativeShardCoverageTests(unittest.TestCase):
    def setUp(self):
        self.inventory = sorted(f'PicShotTests.Group{i}Tests/testCase{n}' for i in range(12) for n in range(3))
        self.source = 'a' * 40

    def plan(self, selection='', process_count=2):
        return shards.make_plan(self.inventory, selection, self.source, process_count=process_count)

    def save_plan(self, directory, process_count=2):
        (directory / 'native-test-discovery.log').write_text('\n'.join(self.inventory) + '\n')
        path = directory / 'plan.json'
        plan = self.plan(process_count=process_count)
        path.write_text(json.dumps(plan))
        return path, plan

    @staticmethod
    def events(name, state='passed'):
        cls, method = name.split('/')
        return f"Test Case '-[{cls} {method}]' started.\nTest Case '-[{cls} {method}]' {state} (0.001 seconds).\n"

    def test_discovery_refuses_empty_duplicate_and_unknown_library_formats(self):
        for value in ['', self.inventory[0] + '\n' + self.inventory[0],
                      self.inventory[0] + '\nNewSwiftTestingCase(parameter:)', 'warning: unexpected']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                shards.discover(value)

    def test_plan_is_complete_disjoint_class_preserving_and_stable(self):
        plan = self.plan()
        self.assertEqual(plan, self.plan())
        observed = [n for s in plan['shards'] for n in s['tests']]
        self.assertEqual(sorted(observed), self.inventory)
        self.assertEqual(len(observed), len(set(observed)))
        self.assertFalse(plan['sameProcessAsUnshardedSuite'])
        classes = [{n.split('/')[0] for n in s['tests']} for s in plan['shards']]
        self.assertFalse(classes[0] & classes[1])

    def test_four_process_plan_exactly_subdivides_each_old_bucket_by_class(self):
        old = self.plan()
        plan = self.plan(process_count=4)
        self.assertEqual(plan, self.plan(process_count=4))
        self.assertEqual(plan['processCount'], 4)
        self.assertEqual(plan['timeoutSecondsPerProcess'], 420)
        self.assertFalse(plan['sameProcessAsUnshardedSuite'])
        observed = [n for s in plan['shards'] for n in s['tests']]
        self.assertEqual(sorted(observed), self.inventory)
        self.assertEqual(len(observed), len(set(observed)))
        self.assertEqual([s['index'] for s in plan['shards']], [0, 1, 2, 3])
        owners = {}
        for shard in plan['shards']:
            self.assertTrue(shard['tests'])
            self.assertEqual([n for n in self.inventory if shards.re.fullmatch(shard['filter'], n)],
                             shard['tests'])
            for name in shard['tests']:
                cls = name.split('/')[0]
                self.assertEqual(owners.setdefault(cls, shard['index']), shard['index'])
                self.assertEqual(hashlib.sha256(cls.encode()).digest()[0] % 4, shard['index'])
        for index in range(2):
            self.assertEqual(sorted(plan['shards'][index]['tests'] + plan['shards'][index + 2]['tests']),
                             old['shards'][index]['tests'])

    def test_process_count_requires_supported_integer_and_nonempty_processes(self):
        for count in [None, False, True, 0, 1, 3, 5, -2, 2.0, 4.0, '2', '4']:
            with self.subTest(count=count), self.assertRaisesRegex(ValueError, 'process counts'):
                self.plan(process_count=count)
        with self.assertRaisesRegex(ValueError, 'must contain tests'):
            shards.make_plan(self.inventory[:1], '', self.source, process_count=4)

    def test_discovery_accepts_known_planning_metadata_only(self):
        raw = '[0/1] Planning build\n' + '\n'.join(self.inventory)
        self.assertEqual(shards.discover(raw), self.inventory)
        with self.assertRaises(ValueError):
            shards.discover(raw + '\n[1/1] Unexpected output')

    def test_method_selection_does_not_run_other_methods(self):
        for count in (2, 4):
            with self.subTest(process_count=count):
                plan = self.plan('testCase1$', process_count=count)
                self.assertEqual(len(plan['selectedTests']), 12)
                for s in plan['shards']:
                    matches = [n for n in self.inventory if shards.re.fullmatch(s['filter'], n)]
                    self.assertEqual(matches, s['tests'])
                    self.assertTrue(all(n.endswith('/testCase1') for n in matches))

    def test_similar_class_names_cannot_expand_regex_scope(self):
        names = ['PicShotTests.FooTests/testA', 'PicShotTests.FooTestsExtra/testA', 'PicShotTests.FooTests/testAB']
        pattern = shards.command_pattern(names[:1])
        self.assertEqual([n for n in names if shards.re.fullmatch(pattern, n)], names[:1])

    def test_unknown_empty_selection_and_invalid_source_fail(self):
        for selection, source in [('never-present', self.source), ('', 'main')]:
            with self.assertRaises(ValueError):
                shards.make_plan(self.inventory, selection, source)

    def test_started_and_one_completion_required(self):
        name = self.inventory[0]
        good = self.events(name)
        self.assertEqual(shards.case_results(good, [name]), ([name], []))
        for bad in [good + good, good.splitlines()[0], good.splitlines()[1], good.replace('passed', 'failed')]:
            with self.subTest(log=bad), self.assertRaises(ValueError):
                shards.case_results(bad, [name])

    def test_omitted_extra_or_unapproved_skipped_cases_fail(self):
        name, extra = self.inventory[:2]
        for log, expected in [(self.events(name), [name, extra]),
                              (self.events(name) + self.events(extra), [name]),
                              (self.events(name, 'skipped'), [name])]:
            with self.assertRaises(ValueError):
                shards.case_results(log, expected)

    def test_only_named_optional_model_skips_are_accepted(self):
        names = sorted(shards.ALLOWED_SKIPS)
        log = ''.join(self.events(n, 'skipped') for n in names)
        self.assertEqual(shards.case_results(log, names), ([], names))

    def test_report_plan_detects_omitted_case_changed_filter_and_deadline(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'plan.json'
            (Path(tmp) / 'native-test-discovery.log').write_text('\n'.join(self.inventory) + '\n')
            original = self.plan()
            mutations = []
            changed = copy.deepcopy(original); changed['shards'][0]['tests'].pop(); mutations.append(changed)
            changed = copy.deepcopy(original); changed['shards'][0]['filter'] = '.*'; mutations.append(changed)
            changed = copy.deepcopy(original); changed['timeoutSecondsPerProcess'] = 500; mutations.append(changed)
            for value in mutations:
                p.write_text(json.dumps(value))
                with self.assertRaises(ValueError):
                    shards.checked_plan(p)

    def test_checked_plans_bind_exact_source_and_original_native_discovery_bytes(self):
        for count in (2, 4):
            with self.subTest(process_count=count), tempfile.TemporaryDirectory() as tmp:
                directory = Path(tmp)
                path, original = self.save_plan(directory, count)
                self.assertEqual(shards.checked_plan(path, self.source), original)
                changed = copy.deepcopy(original)
                changed['sourceCommit'] = 'b' * 40
                path.write_text(json.dumps(changed))
                with self.assertRaisesRegex(ValueError, 'expected source SHA'):
                    shards.checked_plan(path, self.source)
                path.write_text(json.dumps(original))
                raw_path = directory / 'native-test-discovery.log'
                raw = '[0/1] Planning build\n' + raw_path.read_text()
                raw_path.write_text(raw)
                # The IDs are unchanged, but the original native bytes must still match.
                self.assertEqual(shards.discover(raw), self.inventory)
                with self.assertRaisesRegex(ValueError, 'deterministic complete inventory'):
                    shards.checked_plan(path, self.source)
                rebound = shards.make_plan(self.inventory, '', self.source,
                                           hashlib.sha256(raw.encode()).hexdigest(), count)
                path.write_text(json.dumps(rebound))
                self.assertEqual(shards.checked_plan(path, self.source), rebound)

    def test_checked_plan_rejects_missing_invalid_or_tampered_process_count(self):
        for count in (2, 4):
            with tempfile.TemporaryDirectory() as tmp:
                path, original = self.save_plan(Path(tmp), count)
                for replacement in (0, 1, 3, 8, True, float(count), str(count), 6 - count):
                    with self.subTest(process_count=count, replacement=replacement):
                        changed = copy.deepcopy(original)
                        changed['processCount'] = replacement
                        path.write_text(json.dumps(changed))
                        with self.assertRaises(ValueError):
                            shards.checked_plan(path)
                del original['processCount']
                path.write_text(json.dumps(original))
                with self.assertRaises(KeyError):
                    shards.checked_plan(path)

    def test_plan_cli_preserves_default_and_builds_four_verified_processes(self):
        for count, arguments in ((2, []), (4, ['--process-count', '4'])):
            with self.subTest(process_count=count), tempfile.TemporaryDirectory() as tmp:
                directory = Path(tmp)
                discovery = directory / 'native-test-discovery.log'
                discovery.write_text('\n'.join(self.inventory) + '\n')
                path = directory / 'plan.json'
                argv = ['native-test-shards.py', 'plan', '--inventory', str(discovery),
                        '--source', self.source, '--output', str(path), *arguments]
                with mock.patch.object(shards.sys, 'argv', argv), mock.patch.object(shards.sys, 'stdout'):
                    shards.main()
                self.assertEqual(shards.checked_plan(path, self.source), self.plan(process_count=count))

    def test_run_dispatches_every_verified_process_with_unchanged_cap_and_exact_filter(self):
        for count in (2, 4):
            with self.subTest(process_count=count), tempfile.TemporaryDirectory() as tmp:
                directory = Path(tmp)
                path, plan = self.save_plan(directory, count)
                for index in range(count):
                    argv = ['native-test-shards.py', 'run', '--plan', str(path),
                            '--expected-source', self.source, '--index', str(index), '--directory', str(directory)]
                    with mock.patch.object(shards.sys, 'argv', argv), mock.patch.object(shards.os, 'execv') as execute:
                        shards.main()
                    command = execute.call_args.args[1]
                    self.assertEqual(command[2:4], ['--timeout-seconds', '420'])
                    self.assertEqual(command[command.index('--') + 1:], shards.expected_command(plan['shards'][index]))
                argv[argv.index('--index') + 1] = str(count)
                with mock.patch.object(shards.sys, 'argv', argv), mock.patch.object(shards.sys, 'stderr'), \
                     mock.patch.object(shards.os, 'execv') as execute:
                    with self.assertRaises((ValueError, SystemExit)):
                        shards.main()
                    execute.assert_not_called()

    def test_self_consistent_smaller_plan_cannot_omit_native_discovered_cases(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / 'native-test-discovery.log').write_text('\n'.join(self.inventory) + '\n')
            p = directory / 'plan.json'
            p.write_text(json.dumps(shards.make_plan(self.inventory[3:], '', self.source)))
            with self.assertRaises(ValueError):
                shards.checked_plan(p)

    def write_native_result(self, directory, shard):
        log = ''.join(self.events(n) for n in shard['tests'])
        log_path, report_path = shards.paths(directory, shard['index'])
        log_path.write_text(log)
        report = {'status': 'exited', 'termination_reason': 'exited', 'child_returncode': 0,
                  'exit_code': 0, 'timeout_seconds': 420, 'log_truncated': False,
                  'command': shards.expected_command(shard), 'log_bytes': len(log.encode()), 'duration_seconds': 2.0}
        report_path.write_text(json.dumps(report))
        return log_path, report_path, report

    def test_successful_aggregate_names_scope_and_every_test(self):
        for count, word in ((2, 'two'), (4, 'four')):
            with self.subTest(process_count=count), tempfile.TemporaryDirectory() as tmp:
                plan = self.plan(process_count=count)
                directory = Path(tmp)
                for s in plan['shards']:
                    self.write_native_result(directory, s)
                result = shards.aggregate(plan, directory)
                self.assertEqual(result['passedCount'], 36)
                self.assertEqual(result['selectedCount'], 36)
                self.assertEqual(result['skippedCount'], 0)
                self.assertEqual(result['processCount'], count)
                self.assertIn(f'{word} disjoint native processes', result['scope'])
                self.assertEqual(result['timeoutSecondsPerProcess'], 420)
                self.assertEqual([s['index'] for s in result['shards']], list(range(count)))
                self.assertFalse(result['sameProcessAsUnshardedSuite'])

    def test_four_process_aggregate_rejects_exact_missing_case_with_valid_wrapper(self):
        plan = self.plan(process_count=4)
        for index in range(4):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as tmp:
                directory = Path(tmp)
                missing = plan['shards'][index]['tests'][0]
                for shard in plan['shards']:
                    log_path, report_path, report = self.write_native_result(directory, shard)
                    if shard['index'] == index:
                        log = log_path.read_text().replace(self.events(missing), '')
                        log_path.write_text(log)
                        report['log_bytes'] = len(log.encode())
                        report_path.write_text(json.dumps(report))
                with self.assertRaises(ValueError) as failure:
                    shards.aggregate(plan, directory)
                self.assertEqual(str(failure.exception), f"Native results differ: missing=['{missing}'], extra=[]")

    def test_aggregate_rejects_timeout_truncation_wrong_command_and_changed_bytes(self):
        plan = self.plan()
        mutations = [{'status': 'timeout'}, {'exit_code': 124}, {'timeout_seconds': 421},
                     {'log_truncated': True}, {'command': ['swift', 'test']}, {'log_bytes': 1}]
        for mutation in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as tmp:
                directory = Path(tmp)
                for s in plan['shards']:
                    _, path, report = self.write_native_result(directory, s)
                    if s['index'] == 0:
                        report.update(mutation); path.write_text(json.dumps(report))
                with self.assertRaises(ValueError):
                    shards.aggregate(plan, directory)

    def test_missing_native_process_report_never_becomes_success(self):
        for count in (2, 4):
            for missing in range(count):
                with self.subTest(process_count=count, missing=missing), tempfile.TemporaryDirectory() as tmp:
                    directory = Path(tmp); plan = self.plan(process_count=count)
                    for shard in plan['shards']:
                        if shard['index'] != missing:
                            self.write_native_result(directory, shard)
                    with self.assertRaisesRegex(ValueError, f'shard-{missing}-runner.json'):
                        shards.aggregate(plan, directory)


class NativeWorkflowRoutingTests(unittest.TestCase):
    """Execute the checked-in shell steps with a recording CLI, without macOS."""

    def setUp(self):
        workflow = (Path(__file__).parents[2] / '.github/workflows/macos.yml').read_text()
        self.build = re.split(r'\n  [A-Za-z_][\w-]*:\n', workflow.split('\n  build:\n', 1)[1])[0]

    @staticmethod
    def scalar(value, arch):
        if value.strip("'").isdigit():
            return int(value.strip("'"))
        match = re.fullmatch(r"\$\{\{ matrix\.arch == '(\w+)' && '?(\d+)'? \|\| '?(\d+)'? \}\}", value)
        if match is None:
            raise ValueError(f'Unknown workflow scalar: {value}')
        return int(match[2] if arch == match[1] else match[3])

    def environment(self, arch):
        block = self.build.split('    env:\n', 1)[1].split('    steps:\n', 1)[0]
        return {name: str(self.scalar(value, arch))
                for name, value in re.findall(r'^      (\w+): (.+)$', block, re.M)}

    def step(self, name):
        match = re.search(r'^      - name: ' + re.escape(name) + r'\n(.*?)(?=^      -|\Z)',
                          self.build, re.M | re.S)
        self.assertIsNotNone(match, name)
        return match[1]

    def execute(self, name, arch, failed_index=''):
        block = self.step(name).split('        run: |\n', 1)[1]
        script = '\n'.join(line[10:] for line in block.splitlines() if line.strip())
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'dist').mkdir()
            executable = root / 'python3'
            executable.write_text(f'#!{sys.executable}\n' +
                "import json, os, sys\n"
                "args = sys.argv[1:]\n"
                "with open(os.environ['CALLS_PATH'], 'a') as log: log.write(json.dumps(args) + '\\n')\n"
                "if len(args) > 1 and args[1] == 'run' and args[args.index('--index') + 1] == os.environ['FAIL_INDEX']: sys.exit(124)\n")
            executable.chmod(0o755)
            calls = root / 'calls.jsonl'
            environment = {**os.environ, **self.environment(arch), 'GITHUB_SHA': 'a' * 40,
                           'PATH': str(root) + os.pathsep + os.environ['PATH'],
                           'CALLS_PATH': str(calls), 'FAIL_INDEX': failed_index}
            result = subprocess.run(['bash', '-e', '-c', script], cwd=root, env=environment,
                                    capture_output=True, text=True, timeout=10)
            return result, [json.loads(line) for line in calls.read_text().splitlines()]

    def test_planning_routes_full_and_focused_counts_independently(self):
        for arch, focused in [('arm64', 2), ('x86_64', 4)]:
            with self.subTest(arch=arch):
                result, calls = self.execute('Plan exhaustive and focused native test processes', arch)
                self.assertEqual(result.returncode, 0, result.stderr)
                plans = [args for args in calls if len(args) > 1 and args[1] == 'plan']
                self.assertEqual(len(plans), 2)
                self.assertEqual([int(args[args.index('--process-count') + 1]) for args in plans], [4, focused])
                self.assertNotIn('--selection-regex', plans[0])
                self.assertIn('--selection-regex', plans[1])
                self.assertTrue(all(args[args.index('--source') + 1] == 'a' * 40 for args in plans))

    def test_every_process_runs_and_failure_remains_failure_after_aggregation(self):
        for arch, focused in [('arm64', 2), ('x86_64', 4)]:
            for name, count in [('Test native modules', 4),
                    ('Check annotation, GIF, recording durability and inference boundaries', focused)]:
                for failed_index in ('', '0'):
                    with self.subTest(arch=arch, stage=name, failed=failed_index):
                        result, calls = self.execute(name, arch, failed_index)
                        runs = [args for args in calls if args[1] == 'run']
                        self.assertEqual([int(args[args.index('--index') + 1]) for args in runs], list(range(count)))
                        self.assertEqual(calls[-1][1], 'check')
                        self.assertTrue(all(args[args.index('--expected-source') + 1] == 'a' * 40 for args in calls))
                        self.assertEqual(result.returncode == 0, not failed_index)

    def test_only_arm_full_stage_receives_four_process_cleanup_allowance(self):
        full = re.search(r'^        timeout-minutes: (.+)$', self.step('Test native modules'), re.M)[1]
        focused = re.search(r'^        timeout-minutes: (.+)$', self.step(
            'Check annotation, GIF, recording durability and inference boundaries'), re.M)[1]
        self.assertEqual([self.scalar(full, arch) for arch in ['arm64', 'x86_64']], [30, 16])
        self.assertEqual([self.scalar(focused, arch) for arch in ['arm64', 'x86_64']], [16, 16])
        self.assertGreater(60 * self.scalar(full, 'arm64'), 4 * (shards.PROCESS_SECONDS + 5.5) + 60)
        self.assertEqual(re.search(r'^    timeout-minutes: (\d+)$', self.build, re.M)[1], '160')


if __name__ == '__main__':
    unittest.main()
