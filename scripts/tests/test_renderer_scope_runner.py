"""Portable shell dispatch tests. Stub tools do not launch or certify native work."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
RUNNER = SCRIPTS / 'renderer-storage-pair-diagnostic.sh'
KINDS = {
    'renderer-final-storage': ('native', 'owned-srgb8'),
    'renderer-autorelease-scope': ('native', 'native-pooled'),
    'renderer-final-storage-scoped': ('native-pooled', 'owned-pooled'),
}


class RendererScopeRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.bin = self.root / 'bin'; self.bin.mkdir()
        self.log = self.root / 'commands.jsonl'
        stub = ('#!' + sys.executable + '\n'
            'import json, os, sys\n'
            'with open(os.environ["COMMAND_LOG"], "a") as stream:\n'
            '    stream.write(json.dumps(sys.argv) + "\\n")\n'
            'if os.environ.get("FAIL_CERTIFICATION") == "1" and "--stage" in sys.argv:\n'
            '    if sys.argv[sys.argv.index("--stage") + 1] == "certification":\n'
            '        sys.exit(7)\n')
        for name in ('codesign', 'python3'):
            path = self.bin / name; path.write_text(stub); path.chmod(0o755)
        self.environment = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'], COMMAND_LOG=str(self.log))

    def run_runner(self, kind=None, evidence='evidence'):
        return subprocess.run(['bash', str(RUNNER), str(self.root / 'PicShot.app'), str(self.root / evidence), 'a' * 40,
            *([kind] if kind is not None else [])], text=True, capture_output=True, timeout=10, env=self.environment)

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_old_default_and_every_kind_dispatch_exactly_four_cells(self):
        for index, kind in enumerate((None, *KINDS)):
            if self.log.exists():
                self.log.unlink()
            completed = self.run_runner(kind, 'evidence-' + str(index))
            self.assertEqual(completed.returncode, 0, completed.stderr)
            selected = kind or 'renderer-final-storage'
            commands = self.commands()
            launches = [c for c in commands if 'scripts/run-bounded-command.py' in c]
            self.assertEqual(len(launches), 4)
            baseline, candidate = KINDS[selected]
            self.assertEqual([c[-3:] for c in launches], [[baseline, 'certify', selected],
                [candidate, 'certify', selected], [baseline, 'resources', selected], [candidate, 'resources', selected]])
            for command in launches:
                self.assertEqual(command[2:8], ['--timeout-seconds', '620', '--grace-seconds', '5', '--max-log-bytes', '2097152'])
                self.assertEqual(command[command.index('--') + 1:command.index('--') + 3],
                                 ['swift', 'scripts/launch-renderer-storage-pair.swift'])
            checks = [c for c in commands if 'scripts/check-renderer-storage-pair.py' in c]
            self.assertEqual(len(checks), 6)
            self.assertTrue(all(c[c.index('--comparison-kind') + 1] == selected for c in checks))
            stages = [c[c.index('--stage') + 1] for c in checks if '--stage' in c]
            self.assertEqual(stages, ['certification', 'pair'])
            certificate_index = next(i for i, c in enumerate(commands) if '--stage' in c and 'certification' in c)
            measured_index = next(i for i, c in enumerate(commands) if c[-2:] == ['resources', selected])
            self.assertLess(certificate_index, measured_index)

    def test_unknown_kind_and_reused_directory_fail_before_launch(self):
        completed = self.run_runner('forged')
        self.assertEqual(completed.returncode, 64)
        self.assertFalse(self.log.exists())
        self.assertFalse((self.root / 'evidence').exists())
        (self.root / 'evidence').mkdir()
        completed = self.run_runner()
        self.assertEqual(completed.returncode, 64)
        self.assertFalse(self.log.exists())

    def test_failed_certification_never_enters_measured_pair(self):
        self.environment['FAIL_CERTIFICATION'] = '1'
        completed = self.run_runner('renderer-final-storage-scoped')
        self.assertEqual(completed.returncode, 7)
        launches = [c for c in self.commands() if 'scripts/run-bounded-command.py' in c]
        self.assertEqual(len(launches), 2)
        self.assertTrue(all(c[-2] == 'certify' for c in launches))


if __name__ == '__main__':
    unittest.main()
