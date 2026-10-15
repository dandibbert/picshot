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

    def test_every_scroll_text_bridge_method_requires_a_native_pass_without_skips(self):
        bridge = json.loads((Path(__file__).parents[1] / 'scroll-text-script-additive-tests.json').read_text())
        self.assertEqual(len(bridge), 41)
        log = ''.join(self.events(name) for name in bridge)
        self.assertEqual(shards.case_results(log, bridge), (bridge, []))
        for method in bridge:
            with self.subTest(method=method), self.assertRaisesRegex(ValueError, 'Unapproved native skip'):
                shards.case_results(log.replace(self.events(method), self.events(method, 'skipped')), bridge)

    def test_every_capture_state_method_requires_exact_native_results_without_skips(self):
        added = json.loads((Path(__file__).parents[1] / 'scroll-capture-state-additive-tests.json').read_text())
        self.assertEqual(len(added), 6)
        log = ''.join(self.events(name) for name in added)
        self.assertEqual(shards.case_results(log, added), (added, []))
        for method in added:
            for label, replacement in [('missing', ''), ('renamed', self.events(method + 'Renamed')),
                                       ('duplicate', self.events(method) * 2),
                                       ('extra', self.events(method) + self.events(method + 'Unexpected')),
                                       ('skipped', self.events(method, 'skipped'))]:
                with self.subTest(method=method, mutation=label), self.assertRaises(ValueError):
                    shards.case_results(log.replace(self.events(method), replacement), added)

    def test_every_geometry_method_requires_exact_native_results_without_skips(self):
        added = json.loads((Path(__file__).parents[1] / 'scroll-geometry-additive-tests.json').read_text())
        self.assertEqual(len(added), 13)
        log = ''.join(self.events(name) for name in added)
        self.assertEqual(shards.case_results(log, added), (added, []))
        for method in added:
            for label, replacement in [('missing', ''), ('renamed', self.events(method + 'Renamed')),
                                       ('duplicate', self.events(method) * 2),
                                       ('extra', self.events(method) + self.events(method + 'Unexpected')),
                                       ('skipped', self.events(method, 'skipped'))]:
                with self.subTest(method=method, mutation=label), self.assertRaises(ValueError):
                    shards.case_results(log.replace(self.events(method), replacement), added)

    def test_every_menu_move_method_requires_exact_native_results_without_skips(self):
        added = json.loads((Path(__file__).parents[1] / 'scroll-menu-move-additive-tests.json').read_text())
        self.assertEqual(len(added), 4)
        log = ''.join(self.events(name) for name in added)
        self.assertEqual(shards.case_results(log, added), (added, []))
        for method in added:
            for label, replacement in [('missing', ''), ('renamed', self.events(method + 'Renamed')),
                                       ('duplicate', self.events(method) * 2),
                                       ('unknown', self.events(method) + self.events(method + 'Unexpected')),
                                       ('skipped', self.events(method, 'skipped'))]:
                with self.subTest(method=method, mutation=label), self.assertRaises(ValueError):
                    shards.case_results(log.replace(self.events(method), replacement), added)

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
        for arch, focused in [('arm64', 4), ('x86_64', 4)]:
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
        context = dict(native=shards, hashlib=hashlib, importlib=importlib, json=json, plan=plan, Path=Path,
                       plan_path=Path('unused-plan.json'), record={},
                       digest=lambda path: 'portable-test-placeholder')
        exec(compile(guard, '<production pin inventory guard>', 'exec'), context)
        return context['record']

    def test_pin_preflight_accepts_current_inventory_and_reports_current_counts(self):
        inventory = self.current_source_inventory()
        plan = shards.make_plan(inventory, '', 'a' * 40, process_count=4)
        record = self.execute_pin_inventory_guard(plan)
        spec = importlib.util.spec_from_file_location('qualification', Path(__file__).parents[1] / 'check-experimental-scroll-interactions.py')
        qualification = importlib.util.module_from_spec(spec); spec.loader.exec_module(qualification)
        bridge_added = sorted(qualification.scroll_text_script_additions(inventory))
        capture_added = sorted(qualification.scroll_capture_state_additions(inventory))
        source_recovery_added = sorted(qualification.scroll_source_recovery_additions(inventory))
        geometry_added = sorted(qualification.scroll_geometry_additions(inventory))
        self.assertEqual(len(geometry_added), 13)
        self.assertEqual(len(source_recovery_added), 7)
        self.assertEqual(len(capture_added), 6)
        self.assertEqual((len(inventory), len({name.split('/')[0] for name in inventory}),
            hashlib.sha256(('\n'.join(inventory)+'\n').encode()).hexdigest()), qualification.CURRENT_NATIVE_INVENTORY)
        menu_move_added = sorted(qualification.scroll_menu_move_additions(inventory))
        self.assertEqual(len(menu_move_added), 4)
        self.assertEqual([len(shard['tests']) for shard in plan['shards']], [647, 556, 637, 677])
        menu_move_inventory = inventory
        inventory = [name for name in menu_move_inventory if name not in menu_move_added]
        self.assertEqual(menu_move_inventory, sorted(inventory + menu_move_added))
        self.assertEqual((len(inventory), len({name.split('/')[0] for name in inventory}),
            hashlib.sha256(('\n'.join(inventory)+'\n').encode()).hexdigest()), qualification.PRESERVED291_NATIVE_INVENTORY)
        selection = re.search(r"--selection-regex '([^']+)'", self.step(
            'Plan exhaustive and focused native test processes'))[1]
        for focused in (False, True):
            current_plans = {}
            for count in (2, 4):
                current = shards.make_plan(menu_move_inventory, selection if focused else '', 'a' * 40, process_count=count)
                prior = shards.make_plan(inventory, selection if focused else '', 'a' * 40, process_count=count)
                current_plans[count] = current
                self.assertEqual(current['selectedTests'], sorted(prior['selectedTests'] + menu_move_added))
                self.assertEqual(current['timeoutSecondsPerProcess'], 420)
                self.assertEqual([len(shard['tests']) for shard in current['shards']],
                    {False: {2: [1284, 1233], 4: [647, 556, 637, 677]},
                     True: {2: [1036, 949], 4: [550, 418, 486, 531]}}[focused][count])
                for before, after in zip(prior['shards'], current['shards']):
                    self.assertEqual([name for name in after['tests'] if name not in menu_move_added], before['tests'])
                if focused:
                    qualification.check_focused_inventory(current['selectedTests'])
                    self.assertEqual((len(current['selectedTests']), hashlib.sha256(
                        ('\n'.join(current['selectedTests'])+'\n').encode()).hexdigest()), qualification.CURRENT_FOCUSED_INVENTORY)
                    self.assertEqual((len(prior['selectedTests']), hashlib.sha256(
                        ('\n'.join(prior['selectedTests'])+'\n').encode()).hexdigest()), qualification.PRESERVED291_FOCUSED_INVENTORY)
                    baseline = next(name for name in prior['selectedTests'] if name.startswith('PicShotTests.LiveScrollSessionInteractionTests/'))
                    for method in menu_move_added + [baseline]:
                        for label, changed in (
                                ('missing', [name for name in current['selectedTests'] if name != method]),
                                ('renamed', sorted(name+'Renamed' if name == method else name for name in current['selectedTests'])),
                                ('wrong module', sorted(name.replace('PicShotTests.', 'PicShotCoreTests.', 1) if name == method else name for name in current['selectedTests'])),
                                ('unknown', sorted(current['selectedTests'] + [method+'Unexpected'])),
                                ('duplicate', sorted(current['selectedTests'] + [method]))):
                            with self.subTest(focused_menu_move=method, mutation=label), self.assertRaises(ValueError):
                                qualification.check_focused_inventory(changed)
                    for changed in (prior['selectedTests'], list(reversed(current['selectedTests']))):
                        with self.assertRaises(ValueError):
                            qualification.check_focused_inventory(changed)
            for index in (0, 1):
                self.assertEqual(sorted(current_plans[4]['shards'][index]['tests']
                                        + current_plans[4]['shards'][index + 2]['tests']),
                                 current_plans[2]['shards'][index]['tests'])
        geometry_inventory = inventory
        inventory = [name for name in geometry_inventory if name not in geometry_added]
        self.assertEqual(geometry_inventory, sorted(inventory + geometry_added))
        self.assertEqual((len(inventory), len({name.split('/')[0] for name in inventory}),
            hashlib.sha256(('\n'.join(inventory)+'\n').encode()).hexdigest()), qualification.PRESERVED289_NATIVE_INVENTORY)
        selection = re.search(r"--selection-regex '([^']+)'", self.step(
            'Plan exhaustive and focused native test processes'))[1]
        for focused in (False, True):
            current_plans = {}
            for count in (2, 4):
                current = shards.make_plan(geometry_inventory, selection if focused else '', 'a' * 40, process_count=count)
                prior = shards.make_plan(inventory, selection if focused else '', 'a' * 40, process_count=count)
                current_plans[count] = current
                self.assertEqual(current['selectedTests'], sorted(prior['selectedTests'] + geometry_added))
                self.assertEqual(current['timeoutSecondsPerProcess'], 420)
                self.assertEqual([len(shard['tests']) for shard in current['shards']],
                    {False: {2: [1280, 1233], 4: [647, 556, 633, 677]},
                     True: {2: [1032, 949], 4: [550, 418, 482, 531]}}[focused][count])
                for before, after in zip(prior['shards'], current['shards']):
                    self.assertEqual([name for name in after['tests'] if name not in geometry_added], before['tests'])
                if focused:
                    qualification.check_focused_inventory(sorted(current['selectedTests'] + menu_move_added))
                    self.assertEqual((len(current['selectedTests']), hashlib.sha256(
                        ('\n'.join(current['selectedTests'])+'\n').encode()).hexdigest()), qualification.PRESERVED291_FOCUSED_INVENTORY)
                    self.assertEqual((len(prior['selectedTests']), hashlib.sha256(
                        ('\n'.join(prior['selectedTests'])+'\n').encode()).hexdigest()), qualification.PRESERVED289_FOCUSED_INVENTORY)
                    baselines = [next(name for name in prior['selectedTests'] if name.split('/')[0] == cls)
                                 for cls in sorted({name.split('/')[0] for name in geometry_added})]
                    for method in geometry_added + baselines:
                        wrong_module = ('PicShotTests.' if method.startswith('PicShotCoreTests.') else 'PicShotCoreTests.') + method.split('.', 1)[1]
                        for label, changed in (
                                ('missing', [name for name in current['selectedTests'] if name != method]),
                                ('renamed', sorted(name+'Renamed' if name == method else name for name in current['selectedTests'])),
                                ('wrong module', sorted(wrong_module if name == method else name for name in current['selectedTests'])),
                                ('matched count', sorted([name for name in current['selectedTests'] if name != method] + [method+'Replacement'])),
                                ('extra', sorted(current['selectedTests'] + [method+'Unexpected'])),
                                ('duplicate', sorted(current['selectedTests'] + [method]))):
                            with self.subTest(focused_geometry=method,mutation=label),self.assertRaises(ValueError):
                                qualification.check_focused_inventory(sorted(changed + menu_move_added))
                    for changed in (prior['selectedTests'], list(reversed(current['selectedTests']))):
                        with self.assertRaises(ValueError):
                            qualification.check_focused_inventory(sorted(changed + menu_move_added)
                                if changed == sorted(changed) else changed + menu_move_added)
            for index in (0, 1):
                self.assertEqual(sorted(current_plans[4]['shards'][index]['tests']
                                        + current_plans[4]['shards'][index + 2]['tests']),
                                 current_plans[2]['shards'][index]['tests'])
        source_recovery_inventory = inventory
        inventory = [name for name in source_recovery_inventory if name not in source_recovery_added]
        self.assertEqual(source_recovery_inventory, sorted(inventory + source_recovery_added))
        self.assertEqual((len(inventory), len({name.split('/')[0] for name in inventory}),
            hashlib.sha256(('\n'.join(inventory)+'\n').encode()).hexdigest()), qualification.PRESERVED287_NATIVE_INVENTORY)
        selection = re.search(r"--selection-regex '([^']+)'", self.step(
            'Plan exhaustive and focused native test processes'))[1]
        for focused in (False, True):
            current_plans = {}
            for count in (2, 4):
                current = shards.make_plan(source_recovery_inventory, selection if focused else '', 'a' * 40, process_count=count)
                prior = shards.make_plan(inventory, selection if focused else '', 'a' * 40, process_count=count)
                current_plans[count] = current
                self.assertEqual(current['selectedTests'], sorted(prior['selectedTests'] + source_recovery_added))
                self.assertEqual(current['timeoutSecondsPerProcess'], 420)
                self.assertEqual([len(shard['tests']) for shard in current['shards']],
                    {False: {2: [1274, 1226], 4: [647, 553, 627, 673]},
                     True: {2: [1026, 942], 4: [550, 415, 476, 527]}}[focused][count])
                for before, after in zip(prior['shards'], current['shards']):
                    self.assertEqual([name for name in after['tests'] if name not in source_recovery_added], before['tests'])
                if focused:
                    qualification.check_focused_inventory(sorted(current['selectedTests'] + geometry_added + menu_move_added))
                    self.assertEqual((len(current['selectedTests']), hashlib.sha256(
                        ('\n'.join(current['selectedTests'])+'\n').encode()).hexdigest()), qualification.PRESERVED289_FOCUSED_INVENTORY)
                    self.assertEqual((len(prior['selectedTests']), hashlib.sha256(
                        ('\n'.join(prior['selectedTests'])+'\n').encode()).hexdigest()), qualification.PRESERVED287_FOCUSED_INVENTORY)
                    baseline = next(name for name in prior['selectedTests'] if name.startswith('PicShotTests.LiveScrollFrameSourceTests/'))
                    for method in source_recovery_added + [baseline]:
                        for label, changed in (
                                ('missing', [name for name in current['selectedTests'] if name != method]),
                                ('renamed', sorted(name+'Renamed' if name == method else name for name in current['selectedTests'])),
                                ('wrong module', sorted(name.replace('PicShotTests.', 'PicShotCoreTests.', 1) if name == method else name for name in current['selectedTests'])),
                                ('matched count', sorted([name for name in current['selectedTests'] if name != method] + [method+'Replacement']))):
                            with self.subTest(focused_source_recovery=method,mutation=label),self.assertRaises(ValueError):
                                qualification.check_focused_inventory(sorted(changed + geometry_added + menu_move_added))
            for index in (0, 1):
                self.assertEqual(sorted(current_plans[4]['shards'][index]['tests']
                                        + current_plans[4]['shards'][index + 2]['tests']),
                                 current_plans[2]['shards'][index]['tests'])
        capture_inventory = inventory
        inventory = [name for name in capture_inventory if name not in capture_added]
        self.assertEqual(capture_inventory, sorted(inventory + capture_added))
        selection = re.search(r"--selection-regex '([^']+)'", self.step(
            'Plan exhaustive and focused native test processes'))[1]
        for focused in (False, True):
            current_plans = {}
            for count in (2, 4):
                current = shards.make_plan(capture_inventory, selection if focused else '', 'a' * 40, process_count=count)
                prior = shards.make_plan(inventory, selection if focused else '', 'a' * 40, process_count=count)
                current_plans[count] = current
                self.assertEqual(current['selectedTests'], sorted(prior['selectedTests'] + capture_added))
                self.assertEqual(current['timeoutSecondsPerProcess'], 420)
                self.assertEqual([len(shard['tests']) for shard in current['shards']],
                    {False: {2: [1270, 1223], 4: [647, 550, 623, 673]},
                     True: {2: [1022, 939], 4: [550, 412, 472, 527]}}[focused][count])
                for before, after in zip(prior['shards'], current['shards']):
                    self.assertEqual([name for name in after['tests'] if name not in capture_added], before['tests'])
                if focused:
                    qualification.check_focused_inventory(sorted(current['selectedTests'] + source_recovery_added + geometry_added + menu_move_added))
                    self.assertEqual((len(current['selectedTests']), hashlib.sha256(
                        ('\n'.join(current['selectedTests'])+'\n').encode()).hexdigest()), qualification.PRESERVED287_FOCUSED_INVENTORY)
                    self.assertEqual((len(prior['selectedTests']), hashlib.sha256(
                        ('\n'.join(prior['selectedTests'])+'\n').encode()).hexdigest()), qualification.PRESERVED284_FOCUSED_INVENTORY)
            for index in (0, 1):
                self.assertEqual(sorted(current_plans[4]['shards'][index]['tests']
                                        + current_plans[4]['shards'][index + 2]['tests']),
                                 current_plans[2]['shards'][index]['tests'])
        plan = shards.make_plan(inventory, '', 'a' * 40, process_count=4)
        self.assertEqual(record['additiveScrollTextScriptIDs'], bridge_added)
        self.assertEqual(record['additiveScrollTextScriptMethods'], 41)
        self.assertEqual((record['discoveredCount'], record['discoveredClassCount']), (2517, 276))
        self.assertEqual((len(inventory), len({name.split('/')[0] for name in inventory}),
            hashlib.sha256(('\n'.join(inventory)+'\n').encode()).hexdigest()), qualification.PRESERVED284_NATIVE_INVENTORY)
        self.assertEqual([len(shard['tests']) for shard in plan['shards']], [647, 550, 617, 673])
        bridge_inventory, bridge_plan = inventory, plan
        inventory = [name for name in bridge_inventory if name not in bridge_added]
        self.assertEqual((len(inventory), len({name.split('/')[0] for name in inventory}),
            hashlib.sha256(('\n'.join(inventory)+'\n').encode()).hexdigest()), qualification.PRESERVED279_NATIVE_INVENTORY)
        self.assertEqual(bridge_inventory, sorted(inventory + bridge_added))
        plan = shards.make_plan(inventory, '', 'a' * 40, process_count=4)
        self.assertEqual(bridge_plan['selectedTests'], bridge_inventory)
        self.assertEqual(bridge_plan['timeoutSecondsPerProcess'], 420)
        for before, after in zip(plan['shards'], bridge_plan['shards']):
            self.assertEqual([name for name in after['tests'] if name not in bridge_added], before['tests'])
        selection = re.search(r"--selection-regex '([^']+)'", self.step(
            'Plan exhaustive and focused native test processes'))[1]
        for count in (2, 4):
            full = shards.make_plan(bridge_inventory, selection, 'a' * 40, process_count=count)
            prior = shards.make_plan(inventory, selection, 'a' * 40, process_count=count)
            qualification.check_focused_inventory(sorted(full['selectedTests'] + capture_added + source_recovery_added + geometry_added + menu_move_added))
            self.assertEqual(full['selectedTests'], sorted(prior['selectedTests'] + bridge_added))
            self.assertEqual((len(full['selectedTests']), hashlib.sha256(
                ('\n'.join(full['selectedTests'])+'\n').encode()).hexdigest()), qualification.PRESERVED284_FOCUSED_INVENTORY)
            self.assertEqual((len(prior['selectedTests']), hashlib.sha256(
                ('\n'.join(prior['selectedTests'])+'\n').encode()).hexdigest()), qualification.PRESERVED279_FOCUSED_INVENTORY)
            self.assertEqual(full['timeoutSecondsPerProcess'], 420)
            self.assertEqual([len(shard['tests']) for shard in full['shards']],
                {2: [1016, 939], 4: [550, 412, 466, 527]}[count])
            for before, after in zip(prior['shards'], full['shards']):
                self.assertEqual([name for name in after['tests'] if name not in bridge_added], before['tests'])
        guidance_added = sorted(qualification.scroll_guidance_additions(inventory))
        self.assertEqual(len(guidance_added), 6)
        preserved278 = [name for name in inventory if name not in guidance_added]
        self.assertEqual((len(preserved278), len({name.split('/')[0] for name in preserved278}),
            hashlib.sha256(('\n'.join(preserved278)+'\n').encode()).hexdigest()), qualification.PRESERVED278_NATIVE_INVENTORY)
        prior278_plan = shards.make_plan(preserved278, '', 'a' * 40, process_count=4)
        self.assertEqual(inventory, sorted(preserved278 + guidance_added))
        self.assertEqual([len(shard['tests']) for shard in prior278_plan['shards']], [647, 534, 617, 642])
        self.assertEqual(plan['timeoutSecondsPerProcess'], 420)
        for before, after in zip(prior278_plan['shards'], plan['shards']):
            self.assertEqual([name for name in after['tests'] if name not in guidance_added], before['tests'])
        scroll_added = sorted(qualification.scroll_chain_additions(inventory))
        self.assertFalse(set(guidance_added) & set(scroll_added))
        self.assertEqual(record['additiveExistingImageChainIDs'], scroll_added)
        self.assertEqual(record['additiveExistingImageChainMethods'], len(scroll_added))
        current_inventory, current_plan = inventory, plan
        choice_added = set(qualification.SCROLL_CHAIN_CHOICE_ADDITIONS)
        self.assertEqual(len(choice_added), 4)
        preserved269 = [name for name in preserved278 if name not in choice_added]
        self.assertEqual((len(preserved269), hashlib.sha256(('\n'.join(preserved269)+'\n').encode()).hexdigest()),
            (2436, '38a94e9f556705bb7b34260cca519f70d8058e59ef4f12b0701cf1a65ad79d07'))
        self.assertEqual([len(shard['tests']) for shard in current_plan['shards']], [647, 534, 617, 648])
        self.assertEqual((len(inventory), len({name.split('/')[0] for name in inventory}),
            hashlib.sha256(('\n'.join(inventory)+'\n').encode()).hexdigest()), qualification.PRESERVED279_NATIVE_INVENTORY)
        inventory = [name for name in preserved278 if name not in scroll_added]
        self.assertEqual((len(inventory), len({name.split('/')[0] for name in inventory})), (2407, 267))
        plan = shards.make_plan(inventory, '', 'a' * 40, process_count=4)
        self.assertEqual(current_inventory, sorted(inventory + scroll_added + guidance_added))
        for before, after in zip(plan['shards'], current_plan['shards']):
            self.assertEqual([name for name in after['tests'] if name not in scroll_added and name not in guidance_added], before['tests'])
        selection = re.search(r"--selection-regex '([^']+)'", self.step(
            'Plan exhaustive and focused native test processes'))[1]
        focused_plans = {}
        for count in (2, 4):
            full = shards.make_plan(current_inventory, selection, 'a' * 40, process_count=count)
            focused_plans[count] = full
            qualification.check_focused_inventory(sorted(full['selectedTests'] + bridge_added + capture_added + source_recovery_added + geometry_added + menu_move_added))
            prior278 = shards.make_plan(preserved278, selection, 'a' * 40, process_count=count)
            self.assertEqual(full['selectedTests'], sorted(prior278['selectedTests'] + guidance_added))
            self.assertEqual((len(prior278['selectedTests']), hashlib.sha256(
                ('\n'.join(prior278['selectedTests'])+'\n').encode()).hexdigest()), qualification.PRESERVED278_FOCUSED_INVENTORY)
            self.assertEqual([len(shard['tests']) for shard in prior278['shards']],
                {2: [1016, 892], 4: [550, 396, 466, 496]}[count])
            for before, after in zip(prior278['shards'], full['shards']):
                self.assertEqual([name for name in after['tests'] if name not in guidance_added], before['tests'])
            prior = shards.make_plan(inventory, selection, 'a' * 40, process_count=count)
            self.assertEqual(full['selectedTests'], sorted(prior['selectedTests'] + scroll_added + guidance_added))
            self.assertEqual((len(full['selectedTests']), hashlib.sha256(
                ('\n'.join(full['selectedTests'])+'\n').encode()).hexdigest()), qualification.PRESERVED279_FOCUSED_INVENTORY)
            self.assertEqual(full['timeoutSecondsPerProcess'], 420)
            self.assertEqual([len(shard['tests']) for shard in full['shards']],
                {2: [1016, 898], 4: [550, 396, 466, 502]}[count])
            for before, after in zip(prior['shards'], full['shards']):
                self.assertEqual([name for name in after['tests'] if name not in scroll_added and name not in guidance_added], before['tests'])
        for index in (0, 1):
            self.assertEqual(sorted(focused_plans[4]['shards'][index]['tests']
                                    + focused_plans[4]['shards'][index + 2]['tests']),
                             focused_plans[2]['shards'][index]['tests'])
        self.assertEqual(hashlib.sha256(('\n'.join(inventory) + '\n').encode()).hexdigest(),
                         '5c7d51efe5e1fc16a1d3dd5c5d5fc4ae35948893fc7e5feb92aaf7c83c9f5539')
        payload = json.loads((Path(__file__).parents[1] / 'save-payload-native-tests.json').read_text())
        self.assertEqual(set(payload), {'added', 'focused'})
        payload_added = payload['added']
        self.assertEqual((len(payload_added), len(payload['focused'])), (25, 93))
        self.assertEqual(payload_added, sorted(set(payload_added)))
        self.assertEqual(record['additiveSavePayloadIDs'], payload_added)
        self.assertEqual(record['additiveSavePayloadMethods'], 25)
        self.assertEqual(hashlib.sha256(('\n'.join(payload_added) + '\n').encode()).hexdigest(),
                         'fb6caa647da701ca40cb44139a26229052f2c204f4838cf756a4701b11fd63c1')
        self.assertEqual(hashlib.sha256(('\n'.join(payload['focused']) + '\n').encode()).hexdigest(),
                         'ed9db8041ef5f823b3f2ae655a32192359454e8c2fb7b49aad542c19a8d1b1a8')
        payload_classes = {name.split('/')[0] for name in payload['focused']}
        self.assertEqual(len(payload_classes), 5)
        self.assertEqual(payload['focused'], [name for name in inventory if name.split('/')[0] in payload_classes])
        payload_inventory, payload_plan = inventory, plan
        inventory = [name for name in payload_inventory if name not in payload_added]
        self.assertEqual((len(inventory), len({name.split('/')[0] for name in inventory})), (2382, 267))
        self.assertEqual(hashlib.sha256(('\n'.join(inventory) + '\n').encode()).hexdigest(),
                         'a88b82f2a8e8828ee7e0ce31b52340106f32f37b8e831599d2859281ed876f7c')
        self.assertEqual(payload_inventory, sorted(inventory + payload_added))
        plan = shards.make_plan(inventory, '', 'a' * 40, process_count=4)
        self.assertEqual([len(shard['tests']) for shard in payload_plan['shards']], [640, 520, 608, 639])
        for old_shard, current_shard in zip(plan['shards'], payload_plan['shards']):
            self.assertEqual([name for name in current_shard['tests'] if name not in payload_added], old_shard['tests'])
        selection = re.search(r"--selection-regex '([^']+)'", self.step(
            'Plan exhaustive and focused native test processes'))[1]
        for count, sizes in [(2, [1000, 875]), (4, [543, 382, 457, 493])]:
            current_focused = shards.make_plan(payload_inventory, selection, 'a' * 40, process_count=count)
            prior_focused = shards.make_plan(inventory, selection, 'a' * 40, process_count=count)
            self.assertEqual(current_focused['selectedTests'], sorted(prior_focused['selectedTests'] + payload_added))
            self.assertEqual(len(current_focused['selectedTests']), 1875)
            self.assertEqual([len(shard['tests']) for shard in current_focused['shards']], sizes)
            for old_shard, current_shard in zip(prior_focused['shards'], current_focused['shards']):
                self.assertEqual([name for name in current_shard['tests'] if name not in payload_added], old_shard['tests'])
        spec = importlib.util.spec_from_file_location('qualification', Path(__file__).parents[1] / 'check-experimental-scroll-interactions.py')
        qualification = importlib.util.module_from_spec(spec); spec.loader.exec_module(qualification)
        recovery_added = list(qualification.SCROLL_RECOVERY_ADDITIONS)
        self.assertEqual(len(recovery_added), 7)
        self.assertEqual(recovery_added, sorted(set(recovery_added)))
        self.assertTrue(set(recovery_added).issubset(inventory))
        recovery_inventory, recovery_plan = inventory, plan
        inventory = [name for name in recovery_inventory if name not in recovery_added]
        self.assertEqual((len(inventory), len({name.split('/')[0] for name in inventory})), (2375, 267))
        self.assertEqual(recovery_inventory, sorted(inventory + recovery_added))
        plan = shards.make_plan(inventory, '', 'a' * 40, process_count=4)
        self.assertEqual([len(shard['tests']) for shard in recovery_plan['shards']], [640, 514, 608, 620])
        for old_shard, current_shard in zip(plan['shards'], recovery_plan['shards']):
            self.assertEqual([name for name in current_shard['tests'] if name not in recovery_added], old_shard['tests'])
        selection = re.search(r"--selection-regex '([^']+)'", self.step(
            'Plan exhaustive and focused native test processes'))[1]
        for count in (2, 4):
            current_focused = shards.make_plan(recovery_inventory, selection, 'a' * 40, process_count=count)
            prior_focused = shards.make_plan(inventory, selection, 'a' * 40, process_count=count)
            self.assertEqual(current_focused['selectedTests'], sorted(prior_focused['selectedTests'] + recovery_added))
            self.assertEqual(len(current_focused['selectedTests']), 1850)
            for old_shard, current_shard in zip(prior_focused['shards'], current_focused['shards']):
                self.assertEqual([name for name in current_shard['tests'] if name not in recovery_added], old_shard['tests'])
        self.assertEqual(hashlib.sha256(('\n'.join(inventory) + '\n').encode()).hexdigest(),
                         '0f19081756c225e5b0fede62805ee01693d1409bf6552979ac74db409e3e4aab')
        text_path = Path(__file__).parents[1] / 'text-script-integration-tests.json'
        self.assertEqual(hashlib.sha256(text_path.read_bytes()).hexdigest(),
                         'ff6801d5165ef1e962127123a2c99164782e8b4490bf380c7cbdb52374ffe365')
        text_added = json.loads(text_path.read_text())
        self.assertEqual(text_added, sorted(set(text_added)))
        self.assertEqual(len(text_added), 72)
        self.assertEqual(hashlib.sha256(('\n'.join(text_added) + '\n').encode()).hexdigest(),
                         'fabb6746e6dff19fa4aae030f48b722260a4f648f7223d685ee449120d1b6ebf')
        self.assertEqual(record['additiveTextScriptMethods'], 72)
        self.assertEqual(record['additiveTextScriptIDs'], text_added)
        self.assertEqual([name for name in inventory if '.TextScript' in name], text_added)
        script_inventory, script_plan = inventory, plan
        inventory = [name for name in script_inventory if name not in set(text_added)]
        self.assertEqual((len(inventory), len({name.split('/')[0] for name in inventory})), (2303, 258))
        self.assertEqual(hashlib.sha256(('\n'.join(inventory) + '\n').encode()).hexdigest(),
                         '7366868482823631d5939adc3b411ff4d538c2c59090c2e35ebdea396b9e41ca')
        self.assertEqual(script_inventory, sorted(inventory + text_added))
        plan = shards.make_plan(inventory, '', 'a' * 40, process_count=4)
        self.assertEqual([len(shard['tests']) for shard in script_plan['shards']], [640, 514, 608, 613])
        for old_shard, current_shard in zip(plan['shards'], script_plan['shards']):
            self.assertEqual([name for name in current_shard['tests'] if name not in text_added], old_shard['tests'])
        selection = re.search(r"--selection-regex '([^']+)'", self.step(
            'Plan exhaustive and focused native test processes'))[1]
        for count in (2, 4):
            full_focused = shards.make_plan(script_inventory, selection, 'a' * 40, process_count=count)
            prior_focused = shards.make_plan(inventory, selection, 'a' * 40, process_count=count)
            self.assertEqual(full_focused['selectedTests'], sorted(prior_focused['selectedTests'] + text_added))
            self.assertEqual(len(full_focused['selectedTests']), 1843)
            for old_shard, current_shard in zip(prior_focused['shards'], full_focused['shards']):
                self.assertEqual([name for name in current_shard['tests'] if name not in text_added], old_shard['tests'])
        live = json.loads((Path(__file__).parents[1] / 'live-scroll-additive-tests.json').read_text())
        self.assertEqual(record['additiveLiveScrollIDs'], live)
        self.assertEqual(record['additiveLiveScrollMethods'], len(live))
        self.assertEqual(len(live), 254)
        self.assertEqual(len(set(live) & set(bridge_added)), 29)
        self.assertTrue(set(capture_added).issubset(live))
        self.assertTrue(set(source_recovery_added).issubset(live))
        self.assertTrue(set(geometry_added).issubset(live))
        self.assertTrue(set(menu_move_added).issubset(live))
        live = [name for name in live if name not in scroll_added and name not in guidance_added and name not in bridge_added and name not in capture_added and name not in source_recovery_added and name not in geometry_added and name not in menu_move_added]
        self.assertEqual(len(live), 165)
        self.assertEqual(len(set(live) & set(payload_added)), 2)
        live = [name for name in live if name not in payload_added]
        self.assertEqual(len(live), 163)
        self.assertTrue(set(recovery_added).issubset(live))
        live = [name for name in live if name not in recovery_added]
        self.assertEqual(len(live), 156)
        self.assertEqual(live, sorted(set(live)))
        self.assertEqual([name for name in record['additiveLiveScrollIDs'] if name not in recovery_added and name not in payload_added and name not in scroll_added and name not in guidance_added and name not in bridge_added and name not in capture_added and name not in source_recovery_added and name not in geometry_added and name not in menu_move_added], live)
        self.assertEqual(record['preserved214Methods'], 2047)
        self.assertEqual(hashlib.sha256(('\n'.join(live) + '\n').encode()).hexdigest(),
                         'a9c4eb4840fe1716651b164c9fc4c27c639738360adcb1a1d20030366b682f64')
        self.assertTrue(set(live).issubset(inventory))
        feedback = json.loads((Path(__file__).parents[1] / 'save-feedback-native-tests.json').read_text())
        self.assertEqual(set(feedback), {'baseline241', 'added'})
        self.assertEqual(len(feedback['baseline241']), 9)
        self.assertEqual(len(feedback['added']), 5)
        self.assertEqual(record['additiveSaveFeedbackIDs'], feedback['added'])
        self.assertEqual(feedback['added'], sorted(set(feedback['added'])))
        self.assertEqual(sorted(feedback['baseline241'] + feedback['added']),
                         [name for name in inventory if '.SaveWorkflowUITests/' in name])
        chains = json.loads((Path(__file__).parents[1] / 'capture-chain-native-tests.json').read_text())
        self.assertEqual(record['additiveCaptureChainIDs'], chains['added'])
        chains['added'] = [name for name in chains['added'] if name not in scroll_added]
        self.assertEqual(len(chains['added']), 95)
        self.assertEqual(chains['added'], sorted(set(chains['added'])))
        self.assertEqual(hashlib.sha256(('\n'.join(chains['added'])+'\n').encode()).hexdigest(),
                         '1d0981cda725cf988eadd9252851f4ae56d4c97a8fb6f6989a253598e8b0e57f')
        additions = live + feedback['added'] + chains['added']
        live_inventory, live_plan = inventory, plan
        inventory = [name for name in live_inventory if name not in additions]
        self.assertEqual((len(inventory), len({name.split('/')[0] for name in inventory})), (2047, 232))
        self.assertEqual(hashlib.sha256(('\n'.join(inventory) + '\n').encode()).hexdigest(),
                         '926ac5674df90163b949fe461f0d4589ef72c8fc3215fa00b927564aae57cb44')
        plan = shards.make_plan(inventory, '', 'a' * 40, process_count=4)
        self.assertEqual([len(shard['tests']) for shard in live_plan['shards']], [612, 508, 608, 575])
        for old_shard, current_shard in zip(plan['shards'], live_plan['shards']):
            self.assertEqual([name for name in current_shard['tests'] if name not in additions], old_shard['tests'])
        live_selection = re.search(r"--selection-regex '([^']+)'", self.step(
            'Plan exhaustive and focused native test processes'))[1]
        for count in (2, 4):
            current_focused = shards.make_plan(live_inventory, live_selection, 'a' * 40, process_count=count)
            old_focused = shards.make_plan(inventory, live_selection, 'a' * 40, process_count=count)
            self.assertEqual(current_focused['selectedTests'], sorted(old_focused['selectedTests'] + additions))
            self.assertEqual(len(current_focused['selectedTests']), 1771)
        pins = json.loads((Path(__file__).parents[1] / 'pin-management-native-additions.json').read_text())
        self.assertEqual(len(pins), 49)
        self.assertEqual(pins, sorted(set(pins)))
        self.assertTrue(set(pins).issubset(inventory))
        pin_inventory, pin_plan = inventory, plan
        inventory = [name for name in pin_inventory if name not in pins]
        self.assertEqual(len(inventory), 1998)
        self.assertEqual(len({name.split('/')[0] for name in inventory}), 225)
        self.assertEqual(hashlib.sha256(('\n'.join(inventory) + '\n').encode()).hexdigest(),
                         '41d0a2f62bd2623b25d961212c8b8eeeec9b568719ff95a7bf0d33ab9d3dda20')
        plan = shards.make_plan(inventory, '', 'a' * 40, process_count=4)
        self.assertEqual(pin_inventory, sorted(inventory + pins))
        self.assertEqual([len(shard['tests']) for shard in pin_plan['shards']], [579, 442, 522, 504])
        for old_shard, current_shard in zip(plan['shards'], pin_plan['shards']):
            self.assertEqual([name for name in current_shard['tests'] if name not in pins], old_shard['tests'])
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
            pin_focused = shards.make_plan(pin_inventory, selection, 'a' * 40, process_count=count)
            self.assertEqual(len(pin_focused['selectedTests']), 1515)
            self.assertTrue(set(pins).issubset(pin_focused['selectedTests']))
            current_focused = shards.make_plan(current_inventory, selection, 'a' * 40, process_count=count)
            self.assertEqual([name for name in pin_focused['selectedTests'] if name not in pins], current_focused['selectedTests'])
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
        text_method = 'PicShotTests.TextScriptControllerTests/testNewDraftIsNotAutoSavedByCloseQuitSelectionOrReopen'
        baseline_method = next(name for name in inventory if '.TextScript' not in name)
        self.assertIn(text_method, inventory)
        recovery_method = 'PicShotTests.LiveScrollAssemblerTransactionTests/testMismatchCannotSpendRecoveryAndFailedStationaryRetryIsBoundedBothAxes'
        self.assertIn(recovery_method, inventory)
        payload_method = 'PicShotTests.ImageExportPNGStagingTests/testSavePayloadMatchesOrdinaryReferenceAlphaPixelsAndMetadata'
        self.assertIn(payload_method, inventory)
        alternatives = [
            ('missing payload method', [name for name in inventory if name != payload_method],
             'Save payload methods lost or added outside explicit inventory'),
            ('renamed payload method', sorted(name + 'Renamed' if name == payload_method else name for name in inventory),
             'Save payload methods lost or added outside explicit inventory'),
            ('missing recovery method', [name for name in inventory if name != recovery_method],
             'Complete native inventory is missing a required additive live-scroll method'),
            ('renamed recovery method', sorted(name + 'Renamed' if name == recovery_method else name for name in inventory),
             'Complete native inventory is missing a required additive live-scroll method'),
            ('unrecorded recovery method', sorted(inventory + [recovery_method + 'Unexpected']), 'Preserved291 native IDs changed'),
            ('missing live classes', [name for name in inventory if '.LiveScroll' not in name], 'Complete native inventory'),
            ('missing live fixture', [name for name in inventory if not name.startswith('PicShotTests.LiveScrollResourceFixtureTests/')],
             'Complete native inventory'),
            ('missing codec classes', [name for name in inventory if name.split('/')[0] not in
             {'PicShotTests.CodecStagingComparisonTests', 'PicShotTests.ImageExportPNGStagingTests'}], 'Save payload methods lost or added outside explicit inventory'),
            ('missing recording classes', [name for name in inventory if not name.startswith('PicShotTests.RecordingInput')],
             'Preserved291 native IDs changed'),
            ('missing final method', inventory[:-1], 'Preserved291 native IDs changed'),
            ('extra baseline method', sorted(inventory + ['PicShotTests.RecordingInputEffectsTests/testUnexpected']),
             'Preserved291 native IDs changed'),
            ('renamed final method', sorted(inventory[:-1] + [inventory[-1] + 'Renamed']),
             'Preserved291 native IDs changed'),
            ('missing baseline method', [name for name in inventory if name != baseline_method], 'Preserved291 native IDs changed'),
            ('renamed baseline method', sorted(name + 'Renamed' if name == baseline_method else name for name in inventory),
             'Preserved291 native IDs changed'),
            ('missing script method', [name for name in inventory if name != text_method],
             'Preserved291 native IDs changed'),
            ('renamed script method', sorted(name + 'Renamed' if name == text_method else name for name in inventory),
             'Preserved291 native IDs changed'),
        ]
        spec = importlib.util.spec_from_file_location('qualification', Path(__file__).parents[1] / 'check-experimental-scroll-interactions.py')
        qualification = importlib.util.module_from_spec(spec); spec.loader.exec_module(qualification)
        guidance = qualification.SCROLL_GUIDANCE_ADDITIONS
        alternatives.append(('stale278 inventory', [name for name in inventory if name not in guidance],
                             'Complete native inventory is missing a required additive live-scroll method'))
        for method in guidance:
            self.assertIn(method, inventory)
            alternatives.extend([
                ('missing guidance method', [name for name in inventory if name != method],
                 'Complete native inventory is missing a required additive live-scroll method'),
                ('renamed guidance method', sorted(name + 'Renamed' if name == method else name for name in inventory),
                 'Complete native inventory is missing a required additive live-scroll method'),
                ('wrong guidance module', sorted(name.replace('PicShotTests.', 'PicShotCoreTests.', 1) if name == method else name for name in inventory),
                 'Complete native inventory is missing a required additive live-scroll method'),
                ('unrecorded guidance method', sorted(inventory + [method + 'Unexpected']), 'Preserved291 native IDs changed'),
            ])
        for label, changed, rejection in alternatives:
            with self.subTest(mutation=label), self.assertRaisesRegex(ValueError, re.escape(rejection)):
                self.execute_pin_inventory_guard(shards.make_plan(changed, '', 'a' * 40, process_count=4))

    def test_pin_preflight_rejects_every_missing_extra_renamed_wrong_module_and_duplicate_bridge_id(self):
        inventory = self.current_source_inventory()
        bridge = json.loads((Path(__file__).parents[1] / 'scroll-text-script-additive-tests.json').read_text())
        mutations = [('stale279', [name for name in inventory if name not in bridge])]
        for method in bridge:
            mutations.extend([
                ('missing', [name for name in inventory if name != method]),
                ('renamed', sorted(name + 'Renamed' if name == method else name for name in inventory)),
                ('wrong module', sorted(name.replace('PicShotTests.', 'PicShotCoreTests.', 1) if name == method else name for name in inventory)),
                ('extra', sorted(inventory + [method + 'Unexpected'])),
                ('duplicate', sorted(inventory + [method])),
            ])
        for label, changed in mutations:
            with self.subTest(mutation=label), self.assertRaises(ValueError):
                self.execute_pin_inventory_guard(shards.make_plan(changed, '', 'a' * 40, process_count=4))

    def test_pin_preflight_rejects_every_missing_extra_renamed_wrong_module_and_duplicate_capture_state_id(self):
        inventory = self.current_source_inventory()
        added = json.loads((Path(__file__).parents[1] / 'scroll-capture-state-additive-tests.json').read_text())
        mutations = [('stale284', [name for name in inventory if name not in added])]
        for method in added:
            mutations.extend([
                ('missing', [name for name in inventory if name != method]),
                ('renamed', sorted(name + 'Renamed' if name == method else name for name in inventory)),
                ('wrong module', sorted(name.replace('PicShotTests.', 'PicShotCoreTests.', 1) if name == method else name for name in inventory)),
                ('extra', sorted(inventory + [method + 'Unexpected'])),
                ('duplicate', sorted(inventory + [method])),
            ])
        for label, changed in mutations:
            with self.subTest(mutation=label), self.assertRaises(ValueError):
                self.execute_pin_inventory_guard(shards.make_plan(changed, '', 'a' * 40, process_count=4))

    def test_pin_preflight_rejects_every_missing_renamed_wrong_module_and_matched_count_source_recovery_id(self):
        inventory = self.current_source_inventory()
        added = json.loads((Path(__file__).parents[1] / 'scroll-source-recovery-additive-tests.json').read_text())
        mutations = [('stale287', [name for name in inventory if name not in added])]
        for method in added:
            mutations.extend([
                ('missing', [name for name in inventory if name != method]),
                ('renamed', sorted(name + 'Renamed' if name == method else name for name in inventory)),
                ('wrong module', sorted(name.replace('PicShotTests.', 'PicShotCoreTests.', 1) if name == method else name for name in inventory)),
                ('matched count', sorted([name for name in inventory if name != method] + [method + 'Replacement'])),
                ('extra', sorted(inventory + [method + 'Unexpected'])),
                ('duplicate', sorted(inventory + [method])),
            ])
        for label, changed in mutations:
            with self.subTest(mutation=label), self.assertRaises(ValueError):
                self.execute_pin_inventory_guard(shards.make_plan(changed, '', 'a' * 40, process_count=4))

    def test_pin_preflight_rejects_every_missing_renamed_wrong_module_and_duplicate_geometry_id(self):
        inventory = self.current_source_inventory()
        added = json.loads((Path(__file__).parents[1] / 'scroll-geometry-additive-tests.json').read_text())
        mutations = [('stale289', [name for name in inventory if name not in added])]
        for method in added:
            wrong_module = ('PicShotTests.' if method.startswith('PicShotCoreTests.') else 'PicShotCoreTests.') + method.split('.', 1)[1]
            wrong_class = method.split('/')[0] + 'Unrecorded/' + method.split('/')[1]
            mutations.extend([
                ('missing', [name for name in inventory if name != method]),
                ('renamed', sorted(name + 'Renamed' if name == method else name for name in inventory)),
                ('wrong module', sorted(wrong_module if name == method else name for name in inventory)),
                ('wrong class', sorted(wrong_class if name == method else name for name in inventory)),
                ('matched count', sorted([name for name in inventory if name != method] + [method + 'Replacement'])),
                ('extra', sorted(inventory + [method + 'Unexpected'])),
                ('duplicate', sorted(inventory + [method])),
            ])
        for label, changed in mutations:
            with self.subTest(mutation=label), self.assertRaises(ValueError):
                self.execute_pin_inventory_guard(shards.make_plan(changed, '', 'a' * 40, process_count=4))

    def test_pin_preflight_rejects_every_missing_renamed_wrong_module_and_duplicate_menu_move_id(self):
        inventory = self.current_source_inventory()
        added = json.loads((Path(__file__).parents[1] / 'scroll-menu-move-additive-tests.json').read_text())
        mutations = [('stale291', [name for name in inventory if name not in added])]
        for method in added:
            wrong_module = ('PicShotTests.' if method.startswith('PicShotCoreTests.') else 'PicShotCoreTests.') + method.split('.', 1)[1]
            wrong_class = method.split('/')[0] + 'Unrecorded/' + method.split('/')[1]
            mutations.extend([
                ('missing', [name for name in inventory if name != method]),
                ('renamed', sorted(name + 'Renamed' if name == method else name for name in inventory)),
                ('wrong module', sorted(wrong_module if name == method else name for name in inventory)),
                ('wrong class', sorted(wrong_class if name == method else name for name in inventory)),
                ('matched count', sorted([name for name in inventory if name != method] + [method + 'Replacement'])),
                ('unknown', sorted(inventory + [method + 'Unexpected'])),
                ('duplicate', sorted(inventory + [method])),
            ])
        for label, changed in mutations:
            with self.subTest(mutation=label), self.assertRaises(ValueError):
                self.execute_pin_inventory_guard(shards.make_plan(changed, '', 'a' * 40, process_count=4))

    def test_text_script_cli_matches_exact_original72_and_new27_union(self):
        workflow = (Path(__file__).parents[2] / '.github/workflows/macos.yml').read_text()
        step = workflow.split('    - name: Verify text script catalog editor execution and existing runtime methods\n', 1)[1].split('    - name:', 1)[0]
        self.assertIn('--timeout-seconds 420', step)
        self.assertIn('-- swift test --skip-build --filter TextScript\n', step)
        python = step.split("        python3 - <<'PYTHON'\n", 1)[1].split('        PYTHON\n', 1)[0]
        tree = ast.parse('\n'.join(line[8:] for line in python.splitlines()))
        stop = next(index for index, node in enumerate(tree.body) if isinstance(node, ast.Assign)
                    and any(isinstance(target, ast.Tuple) and any(isinstance(element, ast.Name)
                            and element.id == 'passed' for element in target.elts) for target in node.targets))
        context = {}
        exec(compile(ast.Module(body=tree.body[:stop], type_ignores=[]), '<production text script selection>', 'exec'), context)
        inventory = self.current_source_inventory()
        original = json.loads((Path(__file__).parents[1] / 'text-script-integration-tests.json').read_text())
        bridge = json.loads((Path(__file__).parents[1] / 'scroll-text-script-additive-tests.json').read_text())
        expected = sorted(original + [name for name in bridge if re.search('TextScript', name)])
        self.assertEqual(context['expected'], expected)
        self.assertEqual(expected, [name for name in inventory if re.search('TextScript', name)])
        self.assertEqual(len(expected), 99)
        self.assertEqual(len(set(expected) & set(bridge)), 27)
        self.assertEqual(hashlib.sha256(('\n'.join(expected)+'\n').encode()).hexdigest(),
                         'fba29fbce662138dbe7a9fb9f38fa6148fdcc5b2ebea424213375edf58f12447')
        self.assertIn("native.need(not skipped, 'Text script methods cannot be skipped')", step)

    def test_focused_guidance_inventory_rejects_missing_extra_and_wrong_ids(self):
        spec = importlib.util.spec_from_file_location('qualification', Path(__file__).parents[1] / 'check-experimental-scroll-interactions.py')
        qualification = importlib.util.module_from_spec(spec); spec.loader.exec_module(qualification)
        selection = re.search(r"--selection-regex '([^']+)'", self.step(
            'Plan exhaustive and focused native test processes'))[1]
        inventory = shards.make_plan(self.current_source_inventory(), selection, 'a' * 40,
                                     process_count=4)['selectedTests']
        qualification.check_focused_inventory(inventory)
        guidance = qualification.SCROLL_GUIDANCE_ADDITIONS
        bridge = qualification.scroll_text_script_manifest()
        capture_state = qualification.scroll_capture_state_manifest()
        baseline = next(name for name in inventory if name not in set(guidance) | bridge | capture_state)
        mutations = [
            ('stale284', [name for name in inventory if name not in capture_state]),
            ('stale279', [name for name in inventory if name not in bridge]),
            ('stale278', [name for name in inventory if name not in guidance]),
            ('missing baseline', [name for name in inventory if name != baseline]),
            ('renamed baseline', sorted(name + 'Renamed' if name == baseline else name for name in inventory)),
            ('unsorted', list(reversed(inventory))),
            ('duplicate baseline', sorted(inventory + [baseline])),
        ]
        for method in (*guidance, *sorted(bridge), *sorted(capture_state)):
            mutations.extend([
                ('missing guidance', [name for name in inventory if name != method]),
                ('renamed guidance', sorted(name + 'Renamed' if name == method else name for name in inventory)),
                ('wrong guidance module', sorted(name.replace('PicShotTests.', 'PicShotCoreTests.', 1) if name == method else name for name in inventory)),
                ('extra guidance', sorted(inventory + [method + 'Unexpected'])),
                ('duplicate guidance', sorted(inventory + [method])),
            ])
        for label, changed in mutations:
            with self.subTest(mutation=label), self.assertRaises(ValueError):
                qualification.check_focused_inventory(changed)

    def test_pin_preflight_rejects_selection_process_deadline_and_grouping_changes(self):
        plan = shards.make_plan(self.current_source_inventory(), '', 'a' * 40, process_count=4)
        mutations = [dict(selectedTests=plan['selectedTests'][:-1]), dict(selectionRegex='RecordingInput'),
                     dict(processCount=2), dict(timeoutSecondsPerProcess=421),
                     dict(shards=list(reversed(plan['shards'])))]
        for mutation in mutations:
            with self.subTest(field=next(iter(mutation))), self.assertRaisesRegex(ValueError, 'Complete native inventory'):
                self.execute_pin_inventory_guard({**plan, **mutation})

    def test_every_process_runs_and_failure_remains_failure_after_aggregation(self):
        for arch, focused in [('arm64', 4), ('x86_64', 4)]:
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
        # Retain the historical regression ID; both focused stages now subdivide.
        full = re.search(r'^        timeout-minutes: (.+)$', self.step('Test native modules'), re.M)[1]
        focused = re.search(r'^        timeout-minutes: (.+)$', self.step(
            'Check annotation, GIF, recording durability and inference boundaries'), re.M)[1]
        self.assertEqual([self.scalar(full, arch) for arch in ['arm64', 'x86_64']], [30, 30])
        self.assertEqual([self.scalar(focused, arch) for arch in ['arm64', 'x86_64']], [30, 30])
        budgets = self.checked_serial_budgets()
        # Retain early witness22m plus standalone installed fidelity120m.
        self.assertEqual([budgets[arch]['jobMinutes'] for arch in ['arm64', 'x86_64']], [176 + 14 + 22 + 120, 204 + 22 + 120])
        self.assertEqual([budgets[arch]['regressionMinutes'] for arch in ['arm64', 'x86_64']], [16, 16])
        self.assertEqual(budgets['arm64']['regressionRequiredSeconds'], 920)
        self.assertEqual(budgets['arm64']['focusedRequiredSeconds'], 1780)
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
            for arch in ['arm64', 'x86_64']:
                for minutes in [16, 28, 29]:
                    intel, arm = (minutes, 30) if arch == 'x86_64' else (30, minutes)
                    value = f"${{{{ matrix.arch == 'x86_64' && {intel} || {arm} }}}}"
                    with self.subTest(arch=arch, stage=name, minutes=minutes), mock.patch.object(self, 'build', self.replace_stage_budget(name, value)):
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
        for arch, values in [('x86_64', [160, 174, 187, 188, 203, 226, 345]), ('arm64', [160, 175, 198, 317, 318, 331])]:
            for minutes in values:
                intel, arm = (minutes, 332) if arch == 'x86_64' else (346, minutes)
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
