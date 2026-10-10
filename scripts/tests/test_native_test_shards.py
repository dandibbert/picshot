import ast
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

    def current_source_inventory(self):
        # Portable drift sentinel for this repository's one-XCTestCase-per-file
        # layout. Actual swift test list and checked_plan remain mandatory in CI.
        root = Path(__file__).parents[2] / 'Tests'
        inventory = []
        for path in sorted(root.rglob('*.swift')):
            source = path.read_text()
            if source.startswith('#if PICSHOT_CALLOUT_RETIREMENT_DIAGNOSTICS\n'):
                self.assertTrue(source.rstrip().endswith('#endif'))
                continue  # Existing opt-in diagnostic is not a production test.
            methods = re.findall(r'\bfunc\s+(test\w+)\s*\(', source)
            if not methods:
                continue
            classes = re.findall(r'\bclass\s+(\w+)\s*:\s*\w*TestCase\b', source)
            self.assertEqual(len(classes), 1, str(path))
            module = path.relative_to(root).parts[0]
            inventory.extend(f'{module}.{classes[0]}/{method}' for method in methods)
        return shards.discover('\n'.join(inventory))

    def execute_pin_inventory_guard(self, plan):
        step = self.step('Reproduce the exact pin Apply regression before broader native gates')
        python = step.split("          python3 - <<'PYTHON'\n", 1)[1].split('          PYTHON\n', 1)[0]
        tree = ast.parse('\n'.join(line[10:] for line in python.splitlines()))
        identities = [node for node in tree.body if isinstance(node, ast.Assign)
                      and any(isinstance(target, ast.Name) and target.id in ('method', 'class_ids')
                              for target in node.targets)]
        body = next(node.body for node in tree.body if isinstance(node, ast.Try))
        start = next(index for index, node in enumerate(body) if isinstance(node, ast.Assign)
                     and any(isinstance(target, ast.Name) and target.id == 'inventory'
                             for target in node.targets))
        stop = next(index for index, node in enumerate(body) if isinstance(node, ast.For))
        guard = ast.Module(body=identities + body[start:stop], type_ignores=[])
        context = dict(native=shards, hashlib=hashlib, plan=plan, Path=Path,
                       plan_path=Path('unused-plan.json'), record={},
                       digest=lambda path: 'portable-test-placeholder')
        exec(compile(guard, '<production pin inventory guard>', 'exec'), context)
        return context['record']

    def test_pin_preflight_accepts_current_inventory_and_reports_current_counts(self):
        inventory = self.current_source_inventory()
        plan = shards.make_plan(inventory, '', 'a' * 40, process_count=4)
        record = self.execute_pin_inventory_guard(plan)
        self.assertEqual((record['discoveredCount'], record['discoveredClassCount']), (1998, 225))
        annotation = json.loads((Path(__file__).parents[1] / 'annotation-preferences-native-additions.json').read_text())
        self.assertEqual(len(annotation), 44)
        self.assertEqual(annotation, sorted(set(annotation)))
        self.assertTrue(set(annotation).issubset(inventory))
        current_inventory, current_plan = inventory, plan
        inventory = [name for name in current_inventory if name not in annotation]
        self.assertEqual(len(inventory), 1954)
        self.assertEqual(len({name.split('/')[0] for name in inventory}), 220)
        plan = shards.make_plan(inventory, '', 'a' * 40, process_count=4)
        self.assertEqual(current_inventory, sorted(inventory + annotation))
        self.assertEqual([len(shard['tests']) for shard in current_plan['shards']], [546, 440, 512, 500])
        for old_shard, current_shard in zip(plan['shards'], current_plan['shards']):
            self.assertEqual([name for name in current_shard['tests'] if name not in annotation], old_shard['tests'])
        staging = json.loads((Path(__file__).parents[1] / 'codec-staging-native-additions.json').read_text())
        self.assertEqual(len(staging), 9)
        self.assertEqual(staging, sorted(set(staging)))
        staging_classes = {'PicShotTests.CodecStagingComparisonTests': 3,
                           'PicShotTests.ImageExportPNGStagingTests': 6}
        for cls, count in staging_classes.items():
            expected = [name for name in staging if name.split('/')[0] == cls]
            self.assertEqual(len(expected), count)
            self.assertEqual([name for name in inventory if name.split('/')[0] == cls], expected)
        before_staging = [name for name in inventory if name not in staging]
        self.assertEqual(len(before_staging), 1945)
        self.assertEqual(len({name.split('/')[0] for name in before_staging}), 218)
        self.assertEqual(hashlib.sha256(('\n'.join(before_staging) + '\n').encode()).hexdigest(),
                         '11d1789bc19d0ad0f0b5b2e482e21c4aca16a5f08cef246b4706cdc584f21772')
        self.assertTrue(set(before_staging).isdisjoint(staging))
        self.assertEqual(inventory, sorted(before_staging + staging))
        old_plan = shards.make_plan(before_staging, '', 'a' * 40, process_count=4)
        self.assertEqual([len(shard['tests']) for shard in old_plan['shards']], [529, 432, 490, 494])
        self.assertEqual([len(shard['tests']) for shard in plan['shards']], [529, 432, 493, 500])
        for old_shard, shard in zip(old_plan['shards'], plan['shards']):
            self.assertEqual([name for name in shard['tests'] if name not in staging], old_shard['tests'])
        additions = json.loads((Path(__file__).parents[1] / 'recording-controls-native-additions.json').read_text())
        self.assertEqual(len(additions), 61)
        self.assertEqual(additions, sorted(set(additions)))
        self.assertTrue(set(additions).issubset(inventory))
        settings = json.loads((Path(__file__).parents[1] / 'settings-native-additions.json').read_text())
        self.assertEqual(len(settings), 48)
        self.assertEqual(settings, sorted(set(settings)))
        self.assertTrue(set(settings).issubset(inventory))
        accepted = [name for name in before_staging if name not in settings]
        self.assertEqual(len(accepted), 1897)
        self.assertEqual(hashlib.sha256(('\n'.join(accepted) + '\n').encode()).hexdigest(),
                         '57360d46e241f23de466cb09e0e8cdcd55197fbd3ad93be82f229b0557546075')
        original = [name for name in accepted if name not in additions]
        self.assertEqual(len(original), 1836)
        self.assertEqual(hashlib.sha256(('\n'.join(original) + '\n').encode()).hexdigest(),
                         '1b5d454926a5ad3d3408ad8827e5fcec619755d284d208d9c13b0e144627cf9b')
        selection = re.search(r"--selection-regex '([^']+)'", self.step(
            'Plan exhaustive and focused native test processes'))[1]
        for count in [2, 4]:
            current_focused = shards.make_plan(current_inventory, selection, 'a' * 40, process_count=count)
            self.assertEqual(len(current_focused['selectedTests']), 1466)
            self.assertTrue(set(annotation).issubset(current_focused['selectedTests']))
        for count, sizes in [(2, [774, 648]), (4, [432, 294, 342, 354])]:
            with self.subTest(process_count=count):
                focused = shards.make_plan(inventory, selection, 'a' * 40, process_count=count)
                old_focused = shards.make_plan(before_staging, selection, 'a' * 40, process_count=count)
                self.assertEqual(len(old_focused['selectedTests']), 1413)
                self.assertEqual(len(focused['selectedTests']), 1422)
                self.assertEqual(focused['selectedTests'], sorted(old_focused['selectedTests'] + staging))
                self.assertTrue(set(additions + settings + staging).issubset(focused['selectedTests']))
                self.assertEqual([len(shard['tests']) for shard in focused['shards']], sizes)
                for old_shard, shard in zip(old_focused['shards'], focused['shards']):
                    self.assertEqual([name for name in shard['tests'] if name not in staging], old_shard['tests'])

    def test_pin_preflight_rejects_stale_missing_extra_and_renamed_inventory(self):
        inventory = self.current_source_inventory()
        alternatives = [
            [name for name in inventory if name.split('/')[0] not in
             {'PicShotTests.CodecStagingComparisonTests', 'PicShotTests.ImageExportPNGStagingTests'}],
            [name for name in inventory if not name.startswith('PicShotTests.RecordingInput')],
            inventory[:-1],
            sorted(inventory + ['PicShotTests.RecordingInputEffectsTests/testUnexpected']),
            sorted(inventory[:-1] + [inventory[-1] + 'Renamed']),
        ]
        for changed in alternatives:
            with self.subTest(count=len(changed)), self.assertRaisesRegex(ValueError, 'Complete native inventory'):
                self.execute_pin_inventory_guard(shards.make_plan(changed, '', 'a' * 40, process_count=4))

    def test_pin_preflight_rejects_selection_process_deadline_and_grouping_changes(self):
        plan = shards.make_plan(self.current_source_inventory(), '', 'a' * 40, process_count=4)
        mutations = [dict(selectedTests=plan['selectedTests'][:-1]), dict(selectionRegex='RecordingInput'),
                     dict(processCount=2), dict(timeoutSecondsPerProcess=421),
                     dict(shards=list(reversed(plan['shards'])))]
        for mutation in mutations:
            with self.subTest(field=next(iter(mutation))), self.assertRaisesRegex(ValueError, 'Complete native inventory'):
                self.execute_pin_inventory_guard({**plan, **mutation})

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
        # Retain the historical regression ID while fixing Intel's old shortage.
        full = re.search(r'^        timeout-minutes: (.+)$', self.step('Test native modules'), re.M)[1]
        focused = re.search(r'^        timeout-minutes: (.+)$', self.step(
            'Check annotation, GIF, recording durability and inference boundaries'), re.M)[1]
        self.assertEqual([self.scalar(full, arch) for arch in ['arm64', 'x86_64']], [30, 30])
        self.assertEqual([self.scalar(focused, arch) for arch in ['arm64', 'x86_64']], [16, 30])
        budgets = self.checked_serial_budgets()
        # Retain early witness22m plus standalone installed fidelity120m.
        self.assertEqual([budgets[arch]['jobMinutes'] for arch in ['arm64', 'x86_64']], [176 + 22 + 120, 204 + 22 + 120])
        self.assertEqual([budgets[arch]['regressionMinutes'] for arch in ['arm64', 'x86_64']], [16, 16])
        self.assertEqual(budgets['arm64']['regressionRequiredSeconds'], 920)
        self.assertEqual(budgets['arm64']['focusedRequiredSeconds'], 920)
        self.assertEqual(budgets['x86_64']['focusedRequiredSeconds'], 1780)
        self.assertEqual(budgets['x86_64']['fullRequiredSeconds'], 1780)

    def checked_serial_budgets(self):
        # These are enclosing-stage allowances, not new command deadlines.
        # Ten seconds reserves the existing cleanup timers and observation/tick
        # overhead; sixty seconds covers serial startup, plan checks and aggregation.
        cleanup_seconds, stage_overhead_seconds = 10, 60
        if shards.PROCESS_SECONDS != 420:
            raise ValueError('Native process deadline changed')
        focused_name = 'Check annotation, GIF, recording durability and inference boundaries'
        focused = re.search(r'^        timeout-minutes: (.+)$', self.step(focused_name), re.M)[1]
        full = re.search(r'^        timeout-minutes: (.+)$', self.step('Test native modules'), re.M)[1]
        regression = re.search(r'^        timeout-minutes: (.+)$', self.step(
            'Reproduce the exact pin Apply regression before broader native gates'), re.M)[1]
        job = re.search(r'^    timeout-minutes: (.+)$', self.build, re.M)[1]
        discovery = self.step('Plan exhaustive and focused native test processes')
        discovery_minutes = re.search(r'^        timeout-minutes: (.+)$', discovery, re.M)[1]
        discovery_seconds = int(re.search(r'run-bounded-command\.py --timeout-seconds (\d+)', discovery)[1])
        fidelity_steps = [
            'Verify installed production staging routes and portable fidelity contract',
            'Verify actual staged final and preview pixels from installed ZIP',
            'Preserve standalone fidelity reports and actual default-route evidence',
            'Preserve small fidelity specimens separately',
            'Preserve large control fidelity specimens separately',
            'Preserve large candidate fidelity specimens separately',
            'Preserve ordinary default-route and outer-command evidence separately']
        fidelity_minutes = [int(re.search(r'^        timeout-minutes: (\d+)$', self.step(name), re.M)[1])
                            for name in fidelity_steps]
        if fidelity_minutes != [3, 106, 2, 2, 2, 2, 2]:
            raise ValueError('Installed fidelity stage or upload allowance changed')
        if '--timeout-seconds 6240' not in self.step(fidelity_steps[1]):
            raise ValueError('Installed fidelity wrapper deadline changed')
        added_fidelity_allowance = sum(fidelity_minutes) + 1
        budgets = {}
        for arch in ['arm64', 'x86_64']:
            env = self.environment(arch)
            focused_count, full_count = int(env['FOCUSED_TEST_PROCESS_COUNT']), int(env['NATIVE_TEST_PROCESS_COUNT'])
            focused_minutes, full_minutes, job_minutes = (self.scalar(value, arch) for value in [focused, full, job])
            regression_minutes = self.scalar(regression, arch)
            regression_required = 2 * (shards.PROCESS_SECONDS + cleanup_seconds) + stage_overhead_seconds
            focused_required = focused_count * (shards.PROCESS_SECONDS + cleanup_seconds) + stage_overhead_seconds
            full_required = full_count * (shards.PROCESS_SECONDS + cleanup_seconds) + stage_overhead_seconds
            if 60 * focused_minutes < focused_required:
                raise ValueError(f'{arch} focused serial process envelope exceeds its stage')
            if 60 * full_minutes < full_required:
                raise ValueError(f'{arch} full serial process envelope exceeds its stage')
            if 60 * regression_minutes < regression_required:
                raise ValueError(f'{arch} pin regression process envelope exceeds its stage')
            # Retain all original work plus Intel's two native-stage increases
            # and the separate method-then-class pin regression stage.
            previous_full = 30 if arch == 'arm64' else 16
            required_job = (160 + max(0, focused_minutes - 16)
                            + max(0, full_minutes - previous_full) + regression_minutes + 22 + added_fidelity_allowance)
            if job_minutes < required_job:
                raise ValueError(f'{arch} job does not preserve the prior allowance plus native stage increases')
            # Discovery is outside both execution stages. Its 2-minute stage
            # retains 60s command + 10s cleanup allowance + 50s planning overhead.
            if discovery_seconds != 60 or 60 * self.scalar(discovery_minutes, arch) < discovery_seconds + cleanup_seconds + 50:
                raise ValueError(f'{arch} discovery/planning stage is under-budgeted or changed')
            budgets[arch] = dict(focusedRequiredSeconds=focused_required, fullRequiredSeconds=full_required,
                                 focusedMinutes=focused_minutes, fullMinutes=full_minutes, jobMinutes=job_minutes,
                                 regressionMinutes=regression_minutes, regressionRequiredSeconds=regression_required)
        return budgets

    def replace_stage_budget(self, name, minutes):
        stage = self.step(name)
        revised, count = re.subn(r'^        timeout-minutes: .+$', f'        timeout-minutes: {minutes}', stage, count=1, flags=re.M)
        self.assertEqual(count, 1)
        changed = self.build.replace(stage, revised, 1)
        self.assertNotEqual(changed, self.build)
        return changed

    def test_each_intel_stage_rejects_the_old_budget_and_insufficient_cleanup_margin(self):
        for name in ['Check annotation, GIF, recording durability and inference boundaries', 'Test native modules']:
            for minutes in [16, 28, 29]:
                arm_minutes = 30 if name == 'Test native modules' else 16
                value = f"${{{{ matrix.arch == 'x86_64' && {minutes} || {arm_minutes} }}}}"
                with self.subTest(stage=name, minutes=minutes), mock.patch.object(self, 'build', self.replace_stage_budget(name, value)):
                    with self.assertRaisesRegex(ValueError, 'serial process envelope'):
                        self.checked_serial_budgets()

    def test_stage_budget_tracks_process_count_and_rejects_native_deadline_changes(self):
        enlarged = self.build.replace("NATIVE_TEST_PROCESS_COUNT: '4'", "NATIVE_TEST_PROCESS_COUNT: '8'")
        self.assertNotEqual(enlarged, self.build)
        with mock.patch.object(self, 'build', enlarged), self.assertRaisesRegex(ValueError, 'full serial process envelope'):
            self.checked_serial_budgets()
        with mock.patch.object(shards, 'PROCESS_SECONDS', 421), self.assertRaisesRegex(ValueError, 'deadline changed'):
            self.checked_serial_budgets()

    def test_intel_job_preserves_allowance_for_both_stage_increases(self):
        for arch, values in [('x86_64', [160, 174, 187, 188, 203, 226, 345]), ('arm64', [160, 175, 198, 317])]:
            for minutes in values:
                intel, arm = (minutes, 318) if arch == 'x86_64' else (346, minutes)
                changed, count = re.subn(r'^    timeout-minutes: .+$',
                    f"    timeout-minutes: ${{{{ matrix.arch == 'x86_64' && {intel} || {arm} }}}}",
                    self.build, count=1, flags=re.M)
                self.assertEqual(count, 1)
                self.assertNotEqual(changed, self.build)
                with self.subTest(arch=arch, minutes=minutes), mock.patch.object(self, 'build', changed):
                    with self.assertRaisesRegex(ValueError, 'job does not preserve'):
                        self.checked_serial_budgets()

    def test_pin_regression_stage_preserves_both_process_cleanup_allowances(self):
        changed = self.replace_stage_budget(
            'Reproduce the exact pin Apply regression before broader native gates', 15)
        with mock.patch.object(self, 'build', changed), self.assertRaisesRegex(ValueError, 'pin regression process envelope'):
            self.checked_serial_budgets()

    def test_discovery_budget_is_separate_from_serial_execution(self):
        changed = self.replace_stage_budget('Plan exhaustive and focused native test processes', 1)
        with mock.patch.object(self, 'build', changed), self.assertRaisesRegex(ValueError, 'discovery/planning'):
            self.checked_serial_budgets()

    def test_unchanged_runner_cleanup_timers_fit_the_reserved_stage_allowance(self):
        source = ast.parse((Path(__file__).parents[1] / 'run-bounded-command.py').read_text())
        grace = [ast.literal_eval(keyword.value) for node in ast.walk(source)
                 if isinstance(node, ast.Call) and node.args and isinstance(node.args[0], ast.Constant)
                 and node.args[0].value == '--grace-seconds' for keyword in node.keywords if keyword.arg == 'default']
        waits = [ast.literal_eval(keyword.value) for node in ast.walk(source)
                 if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == 'wait'
                 and isinstance(node.func.value, ast.Name) and node.func.value.id == 'process'
                 for keyword in node.keywords if keyword.arg == 'timeout']
        kill_settle = [ast.literal_eval(node.comparators[0]) for node in ast.walk(source)
                       if isinstance(node, ast.Compare) and isinstance(node.left, ast.BinOp)
                       and isinstance(node.left.right, ast.Name) and node.left.right.id == 'kill_at']
        observations = [ast.literal_eval(node.value) for node in source.body
                        if isinstance(node, ast.Assign) and any(isinstance(target, ast.Name)
                        and target.id == 'GROUP_OBSERVATION_SECONDS' for target in node.targets)]
        self.assertEqual(grace, [5.0])
        self.assertEqual(waits, [1, 1])
        self.assertEqual(kill_settle, [0.5])
        self.assertEqual(observations, [0.5])
        # 7.5s explicit cleanup timers + 2.5s allowance for observation/ticks.
        # This is budget accounting, not a claim of a hard I/O/scheduler bound.
        self.assertEqual(grace[0] + sum(waits) + kill_settle[0] + 2.5, 10)


if __name__ == '__main__':
    unittest.main()
