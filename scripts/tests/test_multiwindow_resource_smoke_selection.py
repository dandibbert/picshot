"""Portable selector/evidence tests; no native rendering or installed app is simulated as evidence."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
SMOKE = (SCRIPTS / 'multiwindow-resource-smoke.sh').read_text()
CHECK = SMOKE.split("<<'PY'\n")[2].split('\nPY\n', 1)[0]
LAUNCH = SMOKE[SMOKE.index('(\n  export PICSHOT_MULTIWINDOW_RESOURCES_ONLY=1'):SMOKE.index(') > "$root/launcher.log"')] + ')\n'
fixture_namespace = {'__name__': 'explicitly_synthetic_selection_fixture', '__file__': str(Path(__file__).with_name('test_check_multiwindow_memory_comparison.py'))}
fixture_path = Path(fixture_namespace['__file__'])
exec(compile(fixture_path.read_text(), str(fixture_path), 'exec'), fixture_namespace)
SOURCE = fixture_namespace['SOURCE']


class ResourceSmokeSelectionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='picshot-synthetic-selection-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def check(self, mode='normalizedCandidate', selection='productionDefault', change=None, optimized=True):
        files = fixture_namespace['cell'](0, 'synthetic-selection', mode, False, False)
        raw = files['multi-window-resource.json']
        raw.update(compositionModeSource=selection,
                   diagnosticCompositionOverride=mode if selection == 'diagnosticOverride' else None)
        if change:
            change(raw)
        for name, data in files.items():
            (self.root / name).write_text(json.dumps(data))
        command = [sys.executable] + (['-O'] if optimized else [])
        command += ['-c', CHECK, str(self.root), raw['bundlePath'], SOURCE, '0', mode, selection]
        process = subprocess.run(command, capture_output=True, text=True, timeout=10)
        checked = json.loads((self.root / 'checked-resource.json').read_text())
        return process.returncode, checked

    def test_absent_selector_is_recorded_as_actual_production_default(self):
        for optimized in (False, True):
            code, result = self.check(optimized=optimized)
            self.assertEqual(code, 0, result)
            self.assertEqual(result['compositionMode'], 'normalizedCandidate')
            self.assertEqual(result['productionCompositionMode'], 'normalizedCandidate')
            self.assertEqual(result['compositionModeSource'], 'productionDefault')
            self.assertIsNone(result['diagnosticCompositionOverride'])

    def test_explicit_baseline_and_candidate_remain_overrides(self):
        for mode in ('coreGraphicsBaseline', 'normalizedCandidate'):
            code, result = self.check(mode, 'diagnosticOverride')
            self.assertEqual(code, 0, result)
            self.assertEqual(result['diagnosticCompositionOverride'], mode)
            self.assertEqual(result['compositionModeSource'], 'diagnosticOverride')

    def test_explicit_same_mode_cannot_masquerade_as_default(self):
        code, result = self.check(change=lambda raw: raw.update(diagnosticCompositionOverride='normalizedCandidate'))
        self.assertEqual(code, 1)
        self.assertEqual(result['status'], 'failed')

    def test_wrong_mode_cannot_pass_default_path(self):
        code, _ = self.check(change=lambda raw: raw.update(compositionMode='coreGraphicsBaseline'))
        self.assertEqual(code, 1)

    def test_default_path_rejects_diagnostic_tail_or_trace(self):
        for flag in ('diagnosticTailStripFirst', 'diagnosticBoundariesEnabled'):
            code, _ = self.check(change=lambda raw: raw.update({flag: True}))
            self.assertEqual(code, 1)

    def test_explicit_path_rejects_absent_override(self):
        code, _ = self.check(selection='diagnosticOverride', change=lambda raw: raw.update(diagnosticCompositionOverride=None))
        self.assertEqual(code, 1)

    def test_explicit_path_rejects_wrong_override(self):
        code, _ = self.check(selection='diagnosticOverride', change=lambda raw: raw.update(diagnosticCompositionOverride='coreGraphicsBaseline'))
        self.assertEqual(code, 1)

    def test_missing_selector_source_is_not_accepted_as_absence(self):
        code, _ = self.check(change=lambda raw: raw.pop('compositionModeSource'))
        self.assertEqual(code, 1)

    def test_optimized_python_still_enforces_sampling_evidence(self):
        code, _ = self.check(change=lambda raw: raw['transientSampler']['total'].update(timerSampleCount=0))
        self.assertEqual(code, 1)

    def launch_environment(self, selection, mode):
        bin_path = self.root / 'bin'
        bin_path.mkdir(exist_ok=True)
        stub = bin_path / 'swift'
        # Observe the actual shell launch branch, without running any native app.
        stub.write_text('#!' + sys.executable + '\nimport json,os,pathlib\n'
            'keys=["PICSHOT_MULTIWINDOW_COMPOSITION","PICSHOT_MULTIWINDOW_DIAGNOSTIC_TAIL_FIRST","PICSHOT_MULTIWINDOW_DIAGNOSTIC_BOUNDARIES"]\n'
            'pathlib.Path(os.environ["SELECTION_ENV_REPORT"]).write_text(json.dumps({k:os.environ[k] for k in keys if k in os.environ}))\n')
        stub.chmod(0o700)
        env = dict(os.environ, PATH=str(bin_path) + os.pathsep + os.environ['PATH'],
            selection=selection, mode=mode, app='/explicitly-synthetic/PicShot.app', root=str(self.root),
            SELECTION_ENV_REPORT=str(self.root / 'launch-environment.json'), PICSHOT_MULTIWINDOW_COMPOSITION='inherited-stale-mode',
            PICSHOT_MULTIWINDOW_DIAGNOSTIC_TAIL_FIRST='1', PICSHOT_MULTIWINDOW_DIAGNOSTIC_BOUNDARIES='1')
        process = subprocess.run(['bash', '-euc', LAUNCH], env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(process.returncode, 0, process.stderr)
        return json.loads((self.root / 'launch-environment.json').read_text())

    def test_default_launch_unsets_all_inherited_diagnostic_selectors(self):
        self.assertEqual(self.launch_environment('productionDefault', 'normalizedCandidate'), {})

    def test_explicit_launch_sets_renderer_and_preserves_comparison_flags(self):
        values = self.launch_environment('diagnosticOverride', 'coreGraphicsBaseline')
        self.assertEqual(values, {'PICSHOT_MULTIWINDOW_COMPOSITION': 'coreGraphicsBaseline',
            'PICSHOT_MULTIWINDOW_DIAGNOSTIC_TAIL_FIRST': '1', 'PICSHOT_MULTIWINDOW_DIAGNOSTIC_BOUNDARIES': '1'})


if __name__ == '__main__':
    unittest.main()
