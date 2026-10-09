"""Source129 delta contracts only: not native runtime or memory qualification."""
import hashlib
from pathlib import Path
import re
import unittest

from seed_render_crop_source_contract import DRAWING, HOOKS, NATIVE, SOURCE129_SHA256, without_substage_hooks

ROOT = Path(__file__).resolve().parents[2]
PROBE = 'Sources/PicShot/SeedRenderCropSubstageProbe.swift'


def read(path):
    return (ROOT / path).read_text()


class SeedRenderCropSourceBindingTests(unittest.TestCase):
    def test_exact_counted_hooks_recover_source129_byte_for_byte(self):
        for path, expected in SOURCE129_SHA256.items():
            with self.subTest(path=path):
                source = without_substage_hooks(path, read(path))
                self.assertEqual(hashlib.sha256(source.encode()).hexdigest(), expected)
        self.assertEqual(len(HOOKS[NATIVE]), 2)
        self.assertEqual(len(HOOKS[DRAWING]), 3)

    def test_missing_duplicated_or_mutated_hooks_cannot_normalize(self):
        for path, hooks in HOOKS.items():
            original = read(path)
            for hook in hooks:
                for forged in [original.replace(hook, '', 1), original + hook,
                               original.replace(hook, hook.replace('try ', 'try? ', 1), 1)]:
                    with self.assertRaises(AssertionError):
                        without_substage_hooks(path, forged)

    def test_native_hooks_are_exactly_after_existing_actions_before_lifetime_or_crop(self):
        source = read(NATIVE)
        self.assertIn('        try click("editor.applyCrop", editor: seed)\n' + HOOKS[NATIVE][0]
                      + '        let full = try O.required(ImageEditorRenderer.render(', source)
        self.assertIn('"Full effect render failed")\n' + HOOKS[NATIVE][1]
                      + '        lifetime.image(full, role: "current")\n'
                      + '        let expectedCrop = try O.required(ImageEditorRenderer.crop(', source)
        self.assertEqual(source.count('SeedRenderCropSubstageProbe'), 2)
        self.assertLess(source.index(HOOKS[NATIVE][1]), source.index('label: "reference-crop"'))
        self.assertIn('warmups = 2, measured = 8, deadlineSeconds = 300.0', source)
        self.assertIn('[("small", 640, 360), ("4k", 3840, 2160)]', source)

    def test_existing_drawing_metadata_and_final_bytes_are_reused_without_sampling(self):
        source = read(DRAWING)
        self.assertLess(source.index(HOOKS[DRAWING][0]), source.index('guard environment["PICSHOT_DRAWING_RASTER_STRATEGY"]'))
        self.assertIn('        try EffectContextPairDiagnostic.process?.checkpoint(drawingCheckpoint: checkpoints[checkpoints.count - 1])\n'
                      + HOOKS[DRAWING][1], source)
        self.assertIn('        try EffectContextPairDiagnostic.process?.write(native: native, nativeData: nativeData, drawingData: data, directory: directory)\n'
                      + HOOKS[DRAWING][2], source)
        probe = read(PROBE)
        metadata = probe[probe.index('    func observeDrawingCheckpoint('):probe.index('    private func requireNext(')]
        for forbidden in ['O.memory(', 'EffectContextConfiguration', 'tracker.snapshot(', 'metadata["memory"]', 'metadata["drawing"]']:
            self.assertNotIn(forbidden, metadata)
        self.assertIn('metadata["workload"]', metadata)
        self.assertIn('metadata["label"]', metadata)

    def test_finite_selection_adds_no_policy_or_early_context_constructor(self):
        source = read(PROBE)
        before_checkpoint = source[:source.index('    func checkpoint(')]
        self.assertNotIn('EffectContextConfiguration.process', before_checkpoint)
        self.assertNotRegex(before_checkpoint, r'\bEffectContextConfiguration\s*\(')
        self.assertIn('EffectContextConfiguration.selection(environment: environment) == .reference', before_checkpoint)
        self.assertIn('static let flag = "PICSHOT_SUBSTAGE_PROBE"', source)
        self.assertIn('static let kind = "seed-render-crop"', source)
        for prefix in ['PICSHOT_DRAWING_RASTER', 'PICSHOT_RENDERER_STORAGE', 'PICSHOT_EFFECT_CONTEXT']:
            self.assertFalse('PICSHOT_SUBSTAGE_PROBE'.startswith(prefix))
        for requirement in ['environment["PICSHOT_SMOKE_TEST"] == "1"',
                'environment["PICSHOT_EDITABLE_ANNOTATIONS_ONLY"] == "1"',
                'environment["PICSHOT_DRAWING_RASTER_STRATEGY"] == "owned-srgb8"',
                'environment["PICSHOT_RENDERER_STORAGE_STRATEGY"] == nil',
                'environment["PICSHOT_RENDERER_COMPARISON_KIND"] == nil',
                'environment["PICSHOT_EFFECT_CONTEXT_POLICY"] == "reference"',
                'observer == (includeResources ? "vimage" : "certify")',
                '"contextInitializationBoundary": "after-first-drawing-memory-before-native-entry"']:
            self.assertIn(requirement, source)
        self.assertEqual(source.count('ProcessInfo.processInfo.environment'), 1)
        drawing = read(DRAWING)
        self.assertLess(drawing.index('"memory": try O.memory()'),
                        drawing.index('try EffectContextPairDiagnostic.process?.checkpoint('))

    def test_probe_has_one_logical_sampler_and_only_json_scalar_retention(self):
        source = read(PROBE)
        code = re.sub(r'//[^\n]*', '', source)
        self.assertEqual(len(re.findall(r'\bO\.memory\s*\(', code)), 1)
        self.assertLess(code.index('try requireNext(boundary)', code.index('    func checkpoint(')), code.index('let memory = try O.memory()'))
        for forbidden in [r'\b(?:CGImage|CGContext|NSImage|NSBitmapImageRep|CIImage|CIContext)\b',
                r'\bdataProvider\b', r'\bUnsafeMutable\w*', r'\bautoreleasepool\s*[({]',
                r'\bclearCaches\s*\(', r'\bManualScrollVImageObservation\b',
                r'\bSourceFormatOwnedCopy\.copy\b', r'\bTask\.sleep\b', r'\bRunLoop\b',
                r'\bmalloc_zone_pressure_relief\b', r'\bvm_purgable_control\b',
                r'\bUserDefaults\b', r'\b(?:setenv|putenv)\s*\(', r'@escaping']:
            self.assertNotRegex(code, forbidden)
        for required in ['private var checkpoints: [[String: Any]] = []',
                'checkpoints.count < selection.maximumCheckpoints', 'metadataCheckpointCount < 256',
                'checkpoints.count == selection.maximumCheckpoints',
                '"additionalMemoryObservations": checkpoints.count', '"checkpointsPerWorkflow": 2',
                '"additionalRasterObservations": 0', '"memory": memory',
                '"existingMaterializedCropBoundary": "reference-crop.before"',
                '"existingMaterializedCropBoundaryHasFullBackingFields": false',
                '"existingMaterializedCropBoundaryCounterCount": 8',
                'JSONSerialization.isValidJSONObject(memory)', 'bytes.count <= 16 * 1_024',
                'data.count <= Self.maximumBytes', 'static let maximumBytes = 256 * 1_024']:
            self.assertIn(required, source)
        native_tests = read('Tests/PicShotTests/SeedRenderCropSubstageProbeTests.swift')
        self.assertEqual(len(re.findall(r'    func test\w+\(', native_tests)), 8)

    def test_serialization_follows_final_native_and_drawing_endpoints_and_binds_raw_bytes(self):
        source = read(PROBE)
        write = source[source.index('    func write('):]
        self.assertLess(write.index('guard native["status"] as? String != "running"'), write.index('let report = try report('))
        for required in ['SHA256.hash(data: nativeData)', 'SHA256.hash(data: drawingData)',
                '"sourceCommit", "executableSHA256", "executableBytes", "architecture", "processIdentifier"',
                '"productDefaultsChanged": false', '"privateFrameworkReleaseClaim": false',
                'static let filename = "seed-render-crop-substage.json"']:
            self.assertIn(required, source)


if __name__ == '__main__':
    unittest.main()
