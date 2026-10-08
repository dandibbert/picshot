"""Portable source scope only, never a native runtime or memory verdict."""
import hashlib
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


def read(name):
    return (ROOT / name).read_text()


class RendererStorageSourceBindingTests(unittest.TestCase):
    def test_exact_existing_drawing_hooks_preserve_prior_diagnostics(self):
        source = read('Sources/PicShot/EditableDrawingPairDiagnostic.swift')
        for hook in [
            '        try RendererStoragePairDiagnostic.begin(includeResources: includeResources, observer: observer)\n',
            '        try RendererStoragePairDiagnostic.process?.checkpoint(drawingCheckpoint: checkpoints[checkpoints.count - 1])\n',
            '        try RendererStoragePairDiagnostic.process?.write(native: native, nativeData: nativeData, drawingData: data, directory: directory)\n',
        ]:
            self.assertEqual(source.count(hook), 1)
            source = source.replace(hook, '', 1)
        self.assertEqual(hashlib.sha256(source.encode()).hexdigest(), '13a81503fe0f8fbe366b6961de4fce4ac81be2228ae22ee7ab8104f2b82ea5ab')
        source = read('Sources/PicShot/DrawingRasterOutputGuardEvidence.swift')
        hook = '        try RendererStorageOutputGuardEvidence.writeIfRequested(evidenceDirectory: evidenceDirectory)\n'
        self.assertEqual(source.count(hook), 1)
        self.assertEqual(hashlib.sha256(source.replace(hook, '', 1).encode()).hexdigest(),
                         'f347e1dbfd628655e57bc2781183ab1f3cbfb4fd154fc0112b04771a9c84399b')

    def test_original_launcher_and_pair_runner_are_byte_identical(self):
        for path, expected in {
            'scripts/launch-editable-drawing-pair.swift': '033787cfa085c96db354d7645c6443c392150620862a1a7e87da43f0319dda75',
            'scripts/editable-drawing-pair-diagnostic.sh': 'ab92d46636429bc6933079a2ac6db8d8a2033225cbee6c986f6660aea6ae6de6',
            'Sources/PicShot/EffectOutputFailureNativeFixture.swift': '24ce9bf612aef873351f4abc3702dd4f78f9f61b12d67b83b5e6caf33b076cb7',
            'scripts/check-effect-output-failure-report.py': '7fe28f27f4ea208d19b12d74d4f754f9f739c25a42279887092f864547430ba3',
            'scripts/effect-output-failure-smoke.sh': 'e225338ba906ff2cf0abb05511153d09f65aa2cd512a8795fb51350baaf4dcc4',
        }.items():
            with self.subTest(path=path):
                self.assertEqual(hashlib.sha256((ROOT / path).read_bytes()).hexdigest(), expected)
        launcher = read('scripts/launch-smoke-app.swift')
        self.assertEqual(launcher.count('"PICSHOT_RENDERER_STORAGE_STRATEGY", '), 1)
        self.assertEqual(hashlib.sha256(launcher.replace('"PICSHOT_RENDERER_STORAGE_STRATEGY", ', '', 1).encode()).hexdigest(),
                         '61bec476b22f3d6403b57e402fac8cf6326c9ce9204427edbdec89d5df058eae')

    def test_each_finite_kind_has_exactly_four_processes_and_original_bounds(self):
        runner = read('scripts/renderer-storage-pair-diagnostic.sh')
        self.assertEqual(re.findall(r'^launch (\S+) (\S+) (\S+)$', runner, re.M), [
            ('baseline-certification', '"$baseline"', 'certify'), ('candidate-certification', '"$candidate"', 'certify'),
            ('baseline', '"$baseline"', 'resources'), ('candidate', '"$candidate"', 'resources')])
        self.assertLess(runner.index('--stage certification'), runner.index('launch baseline "$baseline" resources'))
        self.assertLess(runner.index('launch candidate "$candidate" resources'), runner.index('--stage pair'))
        for selection in ['renderer-final-storage) baseline=native; candidate=owned-srgb8',
                          'renderer-autorelease-scope) baseline=native; candidate=native-pooled',
                          'renderer-final-storage-scoped) baseline=native-pooled; candidate=owned-pooled']:
            self.assertIn(selection, runner)
        self.assertIn('kind="${4:-renderer-final-storage}"', runner)
        self.assertEqual(runner.count('--comparison-kind "$kind"'), 3)
        self.assertIn('--timeout-seconds 620 --grace-seconds 5 --max-log-bytes 2097152', runner)
        self.assertIn('! -e "$root"', runner)
        self.assertIn('deadlineSeconds = 300.0', read('Sources/PicShot/EditableAnnotationNativeFixture.swift'))
        launcher = read('scripts/launch-renderer-storage-pair.swift')
        self.assertEqual(re.findall(r'let timeout: TimeInterval = ([^\n]+)', launcher), ['600'])
        self.assertIn('configuration.environment["PICSHOT_DRAWING_RASTER_STRATEGY"] = "owned-srgb8"', launcher)
        self.assertIn('configuration.environment["PICSHOT_RENDERER_STORAGE_STRATEGY"] = strategy', launcher)
        self.assertIn('configuration.environment["PICSHOT_EDITABLE_HASH_DIAGNOSTIC"] = mode == "certify" ? "certify" : "vimage"', launcher)
        self.assertIn('configuration.createsNewApplicationInstance = true', launcher)
        self.assertIn('configuration.arguments = []', launcher)
        self.assertIn('"ownedExitConfirmed": launched?.isTerminated == true', launcher)
        self.assertNotIn('ProcessInfo.processInfo.environment', launcher)
        self.assertEqual(set(re.findall(r'PICSHOT_[A-Z_]+', launcher)), {'PICSHOT_SMOKE_TEST', 'PICSHOT_SMOKE_REPORT',
            'PICSHOT_EDITABLE_ANNOTATIONS_ONLY', 'PICSHOT_EDITABLE_HASH_DIAGNOSTIC',
            'PICSHOT_DRAWING_RASTER_STRATEGY', 'PICSHOT_RENDERER_STORAGE_STRATEGY', 'PICSHOT_RENDERER_COMPARISON_KIND', 'PICSHOT_EDITABLE_ANNOTATION_RESOURCES'})

    def test_helpers_retain_only_bounded_scalar_metadata_at_existing_checkpoints(self):
        pair = read('Sources/PicShot/RendererStoragePairDiagnostic.swift')
        guard = read('Sources/PicShot/RendererStorageOutputGuardEvidence.swift')
        for fragment in ['checkpoints.count < 256', 'data.count <= 256 * 1_024',
                         '"additionalRasterObservations": 0', '"maximumCheckpoints": 256',
                         '"observationBoundary": "after-existing-drawing-checkpoint"',
                         'JSONEncoder().encode(RendererStorageConfiguration.process.tracker.snapshot())',
                         'SHA256.hash(data: nativeData)', 'SHA256.hash(data: drawingData)',
                         '"sourceCommit", "executableSHA256", "executableBytes", "architecture", "processIdentifier"',
                         '"rendererAutoreleaseScope": strategy.autoreleaseScope',
                         '"comparisonKind": comparisonKind', 'contracts[kind]?.contains(selected) == true']:
            self.assertIn(fragment, pair)
        for fragment in ['let snapshot = configuration.tracker.snapshot()', 'JSONEncoder().encode(snapshot)',
                         '"status": "observed"', '"executableSHA256": try O.fileDigest(executable)',
                         'RendererStorageStrategy.productionDefault.rawValue', 'data.count <= 16 * 1_024',
                         '"rendererAutoreleaseScope": selected.autoreleaseScope']:
            self.assertIn(fragment, guard)
        for source in (pair, guard):
            for forbidden in ['CGImage', 'CGContext', 'NSImage', 'NSBitmapImageRep', 'dataProvider',
                              'UnsafeMutable', 'O.memory(', 'Task.sleep', 'RunLoop', 'malloc_zone_pressure_relief',
                              'vm_purgable_control', 'CGRequestScreenCaptureAccess', 'NSPasteboard']:
                self.assertNotIn(forbidden, source)

    def test_explicit_finite_checker_contract_preserves_original_defaults(self):
        source = read('scripts/check-editable-drawing-pair.py')
        for kind in ('drawing-input', 'renderer-final-storage', 'renderer-autorelease-scope', 'renderer-final-storage-scoped'):
            self.assertIn(repr(kind), source)
        self.assertIn("comparison_kind='drawing-input'", source)
        self.assertIn("STRATEGIES = ('reference', 'owned-srgb8')", source)
        renderer = read('scripts/check-renderer-storage-pair.py')
        self.assertIn('comparison_kind=KIND', renderer)
        self.assertIn('comparison_kind=comparison_kind', renderer)
        for forbidden in [r'\bC\.STRATEGIES\s*=', r'\bC\.CELLS\s*=', r'\bC\.validate_launch\s*=', r'\bC\.drawing_strategy\s*=']:
            self.assertNotRegex(renderer, forbidden)


if __name__ == '__main__':
    unittest.main()
