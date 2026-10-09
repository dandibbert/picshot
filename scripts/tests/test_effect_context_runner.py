"""Portable shell dispatch tests; stubs do not launch or certify native work."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
RUNNER = SCRIPTS / 'effect-context-pair-diagnostic.sh'
GUARD_RUNNER = SCRIPTS / 'effect-context-output-guard.sh'
KIND = 'effect-context-memory-target'


class EffectContextRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        # Resolve before any identity or CLI path is constructed (notably /var
        # versus /private/var on macOS).
        self.root = Path(self.temp.name).resolve(strict=True)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.log = self.root / 'commands.jsonl'
        stub = ('#!' + sys.executable + '\n'
            'import json, os, sys\n'
            'from pathlib import Path\n'
            'with open(os.environ["COMMAND_LOG"], "a") as stream:\n'
            '    stream.write(json.dumps(sys.argv) + "\\n")\n'
            'if Path(sys.argv[0]).name == "codesign":\n'
            '    sys.exit(int(os.environ.get("FAIL_CODESIGN", "0")))\n'
            'if "scripts/run-bounded-command.py" in sys.argv:\n'
            '    sys.exit(int(os.environ.get("FAIL_LAUNCHER", "0")))\n'
            'if "--launcher-status" in sys.argv:\n'
            '    status = int(sys.argv[sys.argv.index("--launcher-status") + 1])\n'
            '    if status: sys.exit(8)\n'
            'if "--stage" in sys.argv:\n'
            '    stage = sys.argv[sys.argv.index("--stage") + 1]\n'
            '    if stage == os.environ.get("FAIL_STAGE"): sys.exit(7)\n'
            'if "scripts/check-effect-context-guard.py" in sys.argv:\n'
            '    if "--policy" in sys.argv:\n'
            '        policy = sys.argv[sys.argv.index("--policy") + 1]\n'
            '        if policy == os.environ.get("FAIL_GUARD_POLICY"): sys.exit(6)\n'
            '    if "--pair" in sys.argv and os.environ.get("FAIL_GUARD_PAIR") == "1": sys.exit(5)\n')
        for name in ('codesign', 'python3'):
            path = self.bin / name
            path.write_text(stub)
            path.chmod(0o755)
        self.environment = dict(os.environ,
            PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
            COMMAND_LOG=str(self.log))
        self.app = self.root / 'PicShot.app'
        self.app.mkdir()
        self.source = 'a' * 40

    def run_runner(self, kind=None, evidence='evidence', app=None, source=None, extra=()):
        return subprocess.run(['bash', str(RUNNER), str(app or self.app),
            str(self.root / evidence), self.source if source is None else source,
            *([kind] if kind is not None else []), *extra],
            text=True, capture_output=True, timeout=10, env=self.environment)

    def run_guard(self, evidence='guard', app=None, source=None, extra=()):
        return subprocess.run(['bash', str(GUARD_RUNNER), str(app or self.app),
            str(self.root / evidence), self.source if source is None else source, *extra],
            text=True, capture_output=True, timeout=10, env=self.environment)

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def launches(self):
        return [c for c in self.commands() if 'scripts/run-bounded-command.py' in c]

    def test_default_and_explicit_kind_have_exact_four_processes_and_certification_gate(self):
        cells = [('baseline-certification', 'reference', 'certify'),
                 ('candidate-certification', 'memory32', 'certify'),
                 ('baseline', 'reference', 'resources'),
                 ('candidate', 'memory32', 'resources')]
        for index, kind in enumerate((None, KIND)):
            with self.subTest(kind=kind):
                if self.log.exists():
                    self.log.unlink()
                evidence = 'evidence-' + str(index)
                completed = self.run_runner(kind, evidence)
                self.assertEqual(completed.returncode, 0, completed.stderr)
                commands = self.commands()
                launches = self.launches()
                self.assertEqual(len(launches), 4)
                for command, (cell, policy, mode) in zip(launches, cells):
                    directory = self.root / evidence / cell
                    self.assertEqual(command[2:8], ['--timeout-seconds', '620',
                        '--grace-seconds', '5', '--max-log-bytes', '2097152'])
                    self.assertEqual(command[command.index('--log') + 1], str(directory / 'launcher.log'))
                    self.assertEqual(command[command.index('--report') + 1], str(directory / 'bounded-launch.json'))
                    self.assertEqual(command[command.index('--') + 1:], [
                        'swift', 'scripts/launch-effect-context-pair.swift', str(self.app),
                        str(directory / 'launch.json'), policy, mode, KIND])
                checks = [c for c in commands if 'scripts/check-effect-context-pair.py' in c]
                self.assertEqual(len(checks), 6)
                for command in checks:
                    self.assertEqual(command[command.index('--comparison-kind') + 1], KIND)
                    self.assertEqual(command[command.index('--app') + 1], str(self.app))
                    self.assertEqual(command[command.index('--expected-source') + 1], self.source)
                cell_checks = [c for c in checks if '--cell' in c]
                self.assertEqual(len(cell_checks), 4)
                for command, (cell, policy, mode) in zip(cell_checks, cells):
                    self.assertEqual(command[command.index('--cell') + 1], str(self.root / evidence / cell))
                    self.assertEqual(command[command.index('--policy') + 1], policy)
                    self.assertEqual(command[command.index('--mode') + 1], mode)
                    self.assertEqual(command[command.index('--launcher-status') + 1], '0')
                stage_checks = [c for c in checks if '--stage' in c]
                self.assertEqual([c[c.index('--stage') + 1] for c in stage_checks], ['certification', 'pair'])
                self.assertLess(commands.index(launches[1]), commands.index(stage_checks[0]))
                self.assertLess(commands.index(stage_checks[0]), commands.index(launches[2]))
                self.assertLess(commands.index(launches[3]), commands.index(stage_checks[1]))
                signatures = [c for c in commands if Path(c[0]).name == 'codesign']
                self.assertEqual(len(signatures), 6)
                self.assertTrue(all(c[1:] == ['--verify', '--deep', '--strict', str(self.app)] for c in signatures))

    def test_invalid_kind_source_app_and_extra_operands_fail_before_mutation(self):
        for index, arguments in enumerate((
                {'kind': 'renderer-final-storage'}, {'kind': 'forged'},
                {'source': 'a' * 39}, {'source': 'A' * 40},
                {'app': 'relative/PicShot.app'},
                {'kind': KIND, 'extra': ('unexpected',)})):
            with self.subTest(arguments=arguments):
                evidence = 'invalid-' + str(index)
                completed = self.run_runner(evidence=evidence, **arguments)
                self.assertEqual(completed.returncode, 64, completed.stderr)
                self.assertEqual(self.commands(), [])
                self.assertFalse((self.root / evidence).exists())

    def test_reused_directory_fails_before_launch_and_preserves_contents(self):
        evidence = self.root / 'evidence'
        evidence.mkdir()
        sentinel = evidence / 'keep.txt'
        sentinel.write_text('existing evidence')
        completed = self.run_runner()
        self.assertEqual(completed.returncode, 64, completed.stderr)
        self.assertEqual(self.commands(), [])
        self.assertEqual(sentinel.read_text(), 'existing evidence')

    def test_failed_certification_never_enters_measured_pair(self):
        self.environment['FAIL_STAGE'] = 'certification'
        completed = self.run_runner()
        self.assertEqual(completed.returncode, 7, completed.stderr)
        self.assertEqual([c[-3:] for c in self.launches()], [
            ['reference', 'certify', KIND], ['memory32', 'certify', KIND]])
        self.assertFalse((self.root / 'evidence/baseline').exists())
        self.assertFalse((self.root / 'evidence/candidate').exists())

    def test_launcher_failure_is_preserved_for_checker_and_stops_the_matrix(self):
        self.environment['FAIL_LAUNCHER'] = '124'
        completed = self.run_runner()
        self.assertEqual(completed.returncode, 8, completed.stderr)
        self.assertEqual(len(self.launches()), 1)
        checks = [c for c in self.commands() if '--launcher-status' in c]
        self.assertEqual(len(checks), 1)
        self.assertEqual(checks[0][checks[0].index('--launcher-status') + 1], '124')
        self.assertFalse(any('--stage' in c for c in self.commands()))

    def test_signature_failure_does_not_create_evidence_or_launch(self):
        self.environment['FAIL_CODESIGN'] = '9'
        completed = self.run_runner()
        self.assertEqual(completed.returncode, 9, completed.stderr)
        self.assertEqual(self.launches(), [])
        self.assertFalse((self.root / 'evidence').exists())

    def test_pair_check_failure_is_not_reported_as_success(self):
        self.environment['FAIL_STAGE'] = 'pair'
        completed = self.run_runner()
        self.assertEqual(completed.returncode, 7, completed.stderr)
        self.assertEqual(len(self.launches()), 4)

    def test_guard_runs_two_independent_cells_then_checks_the_pair(self):
        completed = self.run_guard()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        commands = self.commands()
        launches = self.launches()
        self.assertEqual(len(launches), 2)
        for command, policy in zip(launches, ('reference', 'memory32')):
            directory = self.root / 'guard' / policy
            self.assertEqual(command[2:8], ['--timeout-seconds', '620',
                '--grace-seconds', '5', '--max-log-bytes', '2097152'])
            self.assertEqual(command[command.index('--log') + 1], str(directory / 'launcher.log'))
            self.assertEqual(command[command.index('--report') + 1], str(directory / 'bounded-launch.json'))
            self.assertEqual(command[command.index('--') + 1:], [
                'swift', 'scripts/launch-effect-context-guard.swift', str(self.app),
                str(directory / 'launch.json'), policy])
        checks = [c for c in commands if 'scripts/check-effect-context-guard.py' in c]
        self.assertEqual([c[2:] for c in checks], [
            [str(self.root / 'guard/reference'), str(self.app), self.source, '--policy', 'reference'],
            [str(self.root / 'guard/memory32'), str(self.app), self.source, '--policy', 'memory32'],
            [str(self.root / 'guard'), str(self.app), self.source, '--pair']])
        self.assertLess(commands.index(launches[0]), commands.index(checks[0]))
        self.assertLess(commands.index(checks[0]), commands.index(launches[1]))
        self.assertLess(commands.index(launches[1]), commands.index(checks[1]))
        self.assertLess(commands.index(checks[1]), commands.index(checks[2]))
        signatures = [c for c in commands if Path(c[0]).name == 'codesign']
        self.assertEqual(len(signatures), 4)
        self.assertTrue(all(c[1:] == ['--verify', '--deep', '--strict', str(self.app)] for c in signatures))

    def test_guard_rejects_invalid_arguments_and_existing_evidence(self):
        for index, arguments in enumerate(({'extra': ('memory32',)},
                {'source': 'invalid'}, {'app': 'relative/PicShot.app'})):
            with self.subTest(arguments=arguments):
                evidence = 'guard-invalid-' + str(index)
                completed = self.run_guard(evidence=evidence, **arguments)
                self.assertEqual(completed.returncode, 64, completed.stderr)
                self.assertEqual(self.commands(), [])
                self.assertFalse((self.root / evidence).exists())
        (self.root / 'guard').mkdir()
        completed = self.run_guard()
        self.assertEqual(completed.returncode, 64, completed.stderr)
        self.assertEqual(self.commands(), [])

    def test_guard_launcher_failure_stops_without_cell_or_pair_acceptance(self):
        self.environment['FAIL_LAUNCHER'] = '124'
        completed = self.run_guard()
        self.assertEqual(completed.returncode, 124, completed.stderr)
        self.assertEqual(len(self.launches()), 1)
        self.assertFalse(any('scripts/check-effect-context-guard.py' in c for c in self.commands()))
        self.assertFalse((self.root / 'guard/memory32').exists())

    def test_guard_failed_reference_check_prevents_candidate(self):
        self.environment['FAIL_GUARD_POLICY'] = 'reference'
        completed = self.run_guard()
        self.assertEqual(completed.returncode, 6, completed.stderr)
        self.assertEqual(len(self.launches()), 1)
        self.assertFalse(any('--pair' in c for c in self.commands()))
        self.assertFalse((self.root / 'guard/memory32').exists())

    def test_guard_failed_candidate_check_prevents_pair_acceptance(self):
        self.environment['FAIL_GUARD_POLICY'] = 'memory32'
        completed = self.run_guard()
        self.assertEqual(completed.returncode, 6, completed.stderr)
        self.assertEqual(len(self.launches()), 2)
        self.assertFalse(any('--pair' in c for c in self.commands()))

    def test_guard_pair_failure_propagates(self):
        self.environment['FAIL_GUARD_PAIR'] = '1'
        completed = self.run_guard()
        self.assertEqual(completed.returncode, 5, completed.stderr)
        self.assertEqual(len(self.launches()), 2)


if __name__ == '__main__':
    unittest.main()
