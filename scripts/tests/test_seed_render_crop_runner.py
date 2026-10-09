"""Portable bounded dispatch tests. Stubs never launch or certify native work."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
RUNNER = SCRIPTS/'seed-render-crop-substage-diagnostic.sh'
LAUNCHER = SCRIPTS/'launch-seed-render-crop-substage.swift'


class SubstageRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve(strict=True)
        self.bin = self.root/'bin'; self.bin.mkdir()
        self.log = self.root/'commands.jsonl'
        stub = ('#!'+sys.executable+'\n'
            'import json, os, sys\nfrom pathlib import Path\n'
            'with open(os.environ["COMMAND_LOG"], "a") as f: f.write(json.dumps(sys.argv)+"\\n")\n'
            'if Path(sys.argv[0]).name == "codesign": sys.exit(int(os.environ.get("FAIL_CODESIGN", "0")))\n'
            'if "scripts/run-bounded-command.py" in sys.argv: sys.exit(int(os.environ.get("FAIL_LAUNCHER", "0")))\n'
            'if "--launcher-status" in sys.argv:\n'
            '    status=int(sys.argv[sys.argv.index("--launcher-status")+1])\n'
            '    if status: sys.exit(8)\n'
            'if "--mode" in sys.argv and sys.argv[sys.argv.index("--mode")+1] == os.environ.get("FAIL_MODE"): sys.exit(7)\n'
            'if "--root" in sys.argv and os.environ.get("FAIL_ROOT") == "1": sys.exit(6)\n')
        for name in ('python3', 'codesign'):
            path = self.bin/name; path.write_text(stub); path.chmod(0o755)
        self.environment = dict(os.environ, PATH=str(self.bin)+os.pathsep+os.environ['PATH'], COMMAND_LOG=str(self.log))
        self.app = self.root/'PicShot.app'; self.app.mkdir()
        self.source = 'a'*40

    def run_script(self, *, app=None, root=None, source=None, extra=()):
        return subprocess.run(['bash', str(RUNNER), str(app or self.app), str(root or self.root/'evidence'),
            source or self.source, *extra], env=self.environment, capture_output=True, text=True, timeout=10)

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_exact_two_processes_gate_resources_on_certification_then_attribute(self):
        result = self.run_script(); self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.commands()
        launches = [c for c in commands if 'scripts/run-bounded-command.py' in c]
        checks = [c for c in commands if 'scripts/check-seed-render-crop-substage.py' in c]
        self.assertEqual(len(launches), 2); self.assertEqual(len(checks), 3)
        for (name, mode), launch, check in zip((('certification', 'certify'), ('resources', 'resources')), launches, checks):
            directory = self.root/'evidence'/name
            self.assertEqual(launch[2:8], ['--timeout-seconds','620','--grace-seconds','5','--max-log-bytes','2097152'])
            self.assertEqual(launch[launch.index('--')+1:], ['swift','scripts/launch-seed-render-crop-substage.swift',
                str(self.app), str(directory/'launch.json'), mode])
            self.assertEqual(check[check.index('--cell')+1], str(directory))
            self.assertEqual(check[check.index('--mode')+1], mode)
            self.assertEqual(check[check.index('--launcher-status')+1], '0')
            self.assertLess(commands.index(launch), commands.index(check))
        self.assertLess(commands.index(checks[0]), commands.index(launches[1]))
        self.assertLess(commands.index(checks[1]), commands.index(checks[2]))
        self.assertIn('--root', checks[2])
        self.assertEqual(len([c for c in commands if Path(c[0]).name == 'codesign']), 4)

    def test_failed_launcher_and_certification_prevent_resources(self):
        for variable, value, expected in [('FAIL_LAUNCHER','124',8), ('FAIL_MODE','certify',7)]:
            with self.subTest(variable=variable):
                self.environment[variable]=value
                result=self.run_script(root=self.root/variable)
                self.assertEqual(result.returncode, expected)
                launches=[c for c in self.commands() if 'scripts/run-bounded-command.py' in c]
                self.assertEqual(len(launches), 1)
                self.assertFalse((self.root/variable/'resources').exists())
                self.assertFalse(any('--root' in c for c in self.commands()))
                del self.environment[variable]; self.log.unlink()

    def test_resource_or_final_failure_is_not_accepted(self):
        for variable, value, expected in [('FAIL_MODE','resources',7), ('FAIL_ROOT','1',6)]:
            self.environment[variable]=value
            result=self.run_script(root=self.root/variable)
            self.assertEqual(result.returncode, expected)
            self.assertEqual(len([c for c in self.commands() if 'scripts/run-bounded-command.py' in c]),2)
            del self.environment[variable]; self.log.unlink()

    def test_reject_invalid_existing_root_and_failed_signature(self):
        for index, arguments in enumerate((dict(extra=('extra',)), dict(source='bad'), dict(app='relative/app'), dict(root='relative/evidence'))):
            result=self.run_script(**arguments)
            self.assertEqual(result.returncode,64); self.assertEqual(self.commands(),[])
        existing=self.root/'evidence'; existing.mkdir()
        self.assertEqual(self.run_script().returncode,64)
        self.assertEqual(self.commands(),[])
        self.environment['FAIL_CODESIGN']='1'
        self.assertEqual(self.run_script(root=self.root/'unsigned').returncode,1)
        self.assertFalse((self.root/'unsigned').exists())

    def test_shell_canonicalizes_temp_alias_before_path_bound_invocations(self):
        alias=self.root/'alias'; alias.symlink_to(self.root, target_is_directory=True)
        result=self.run_script(app=alias/'PicShot.app',root=alias/'evidence')
        self.assertEqual(result.returncode,0,result.stderr)
        for command in self.commands():
            if 'scripts/run-bounded-command.py' in command or 'scripts/check-seed-render-crop-substage.py' in command:
                self.assertNotIn(str(alias), ' '.join(command))

    def test_launcher_has_fixed_finite_environment_fresh_identity_and_original_bounds(self):
        source=LAUNCHER.read_text()
        self.assertIn('guard CommandLine.arguments.count == 4 else',source)
        self.assertIn('["certify", "resources"].contains(mode)',source)
        self.assertEqual(set(re.findall(r'PICSHOT_[A-Z_]+',source)), {
            'PICSHOT_SMOKE_TEST','PICSHOT_SMOKE_REPORT','PICSHOT_EDITABLE_ANNOTATIONS_ONLY',
            'PICSHOT_EDITABLE_HASH_DIAGNOSTIC','PICSHOT_DRAWING_RASTER_STRATEGY','PICSHOT_EFFECT_CONTEXT_POLICY',
            'PICSHOT_SUBSTAGE_PROBE','PICSHOT_EDITABLE_ANNOTATION_RESOURCES'})
        for key,value in [('PICSHOT_DRAWING_RASTER_STRATEGY','owned-srgb8'),('PICSHOT_EFFECT_CONTEXT_POLICY','reference'),('PICSHOT_SUBSTAGE_PROBE','seed-render-crop')]:
            self.assertIn('configuration.environment["'+key+'"] = "'+value+'"',source)
        for snippet in ['configuration.createsNewApplicationInstance = true','configuration.arguments = []',
            'configuration.addsToRecentItems = false','NSWorkspace.shared.openApplication(',
            'launchedProcessIdentifier = app.map { Int($0.processIdentifier) }',
            'launchedExecutablePath = app?.executableURL?.resolvingSymlinksInPath().path',
            '"ownedExitConfirmed": launched?.isTerminated == true','"processStartMemoryCaptured": false',
            '"launchBeganUptimeSeconds": launchBeganUptime','"finishUptimeSeconds": ProcessInfo.processInfo.systemUptime',
            'if launched.isTerminated { finish(0, "exited") }','finish(1, "timed-out")']:
            self.assertIn(snippet,source)
        self.assertEqual(re.findall(r'let timeout: TimeInterval = ([^\n]+)',source),['600'])
        self.assertIn('deadlineSeconds = 300.0',(SCRIPTS.parent/'Sources/PicShot/EditableAnnotationNativeFixture.swift').read_text())
        self.assertNotIn('ProcessInfo.processInfo.environment',source)
        self.assertNotIn('#if',source)
        self.assertNotRegex(source,r'\b(?:killall|pkill|task_for_pid)\b')


if __name__ == '__main__': unittest.main()
