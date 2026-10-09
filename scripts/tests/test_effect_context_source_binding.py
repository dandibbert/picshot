"""Portable source boundaries only; these tests make no native memory verdict."""
import hashlib
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
KIND = 'effect-context-memory-target'
PAIR = 'Sources/PicShot/EffectContextPairDiagnostic.swift'
GUARD = 'Sources/PicShot/EffectContextOutputGuardEvidence.swift'
LAUNCHER = 'scripts/launch-effect-context-pair.swift'
GUARD_LAUNCHER = 'scripts/launch-effect-context-guard.swift'
RUNNER = 'scripts/effect-context-pair-diagnostic.sh'
HOOKS = [
    '        try EffectContextPairDiagnostic.begin(includeResources: includeResources, observer: observer)\n',
    '        try EffectContextPairDiagnostic.process?.checkpoint(drawingCheckpoint: checkpoints[checkpoints.count - 1])\n',
    '        try EffectContextPairDiagnostic.process?.write(native: native, nativeData: nativeData, drawingData: data, directory: directory)\n',
]


def read(name):
    return (ROOT / name).read_text()


class EffectContextSourceBindingTests(unittest.TestCase):
    def test_only_three_drawing_hooks_at_existing_boundaries(self):
        source = read('Sources/PicShot/EditableDrawingPairDiagnostic.swift')
        for hook in HOOKS:
            self.assertEqual(source.count(hook), 1)
        self.assertLess(source.index(HOOKS[0]), source.index('try process?.checkpoint(workload: "entry"'))
        self.assertLess(source.index('checkpoints.append('), source.index(HOOKS[1]))
        self.assertLess(source.index('try data.write(to:'), source.index(HOOKS[2]))
        for hook in HOOKS:
            source = source.replace(hook, '', 1)
        self.assertEqual(hashlib.sha256(source.encode()).hexdigest(),
            'b3a96cefa73d88870313d40dc37cab1f1fdfaa36da98410f07c832e25f94ebd8')

    def test_existing_launchers_diagnostics_and_native_fixtures_are_unchanged(self):
        expected_hashes = {
            'scripts/launch-editable-drawing-pair.swift': '033787cfa085c96db354d7645c6443c392150620862a1a7e87da43f0319dda75',
            'scripts/editable-drawing-pair-diagnostic.sh': 'ab92d46636429bc6933079a2ac6db8d8a2033225cbee6c986f6660aea6ae6de6',
            'scripts/launch-renderer-storage-pair.swift': 'b8bb59762c366dd0f0877dd065513f4cc62da039f6b0d0e881e89b1f97d71c4a',
            'scripts/renderer-storage-pair-diagnostic.sh': '07c6dd1ae7d26fef0db1aad3c89b19d0d0b2e1174f3b086364f0ca70b29814fa',
            'scripts/launch-smoke-app.swift': 'a46ab938b151e73ebadd99f2800f31e32ec147a707f9a19815555a7a2f2d8d19',
            'Sources/PicShot/EditableAnnotationNativeFixture.swift': '4b328adbce635a7f9801b347294146814986e56a94ea12c28c00cd513e1489c3',
            'Sources/PicShot/EffectOutputFailureNativeFixture.swift': '24ce9bf612aef873351f4abc3702dd4f78f9f61b12d67b83b5e6caf33b076cb7',
            'scripts/check-effect-output-failure-report.py': '7fe28f27f4ea208d19b12d74d4f754f9f739c25a42279887092f864547430ba3',
            'scripts/effect-output-failure-smoke.sh': 'e225338ba906ff2cf0abb05511153d09f65aa2cd512a8795fb51350baaf4dcc4',
            'Sources/PicShot/RendererStoragePairDiagnostic.swift': '6b19aad0297c7e13eae58351277fc5e156b8b5481ab327fc29a5f209cc7bd767',
            'Sources/PicShot/RendererStorageOutputGuardEvidence.swift': '69d7d3c39ff4db9d3a07cdeb7b1549f095cab11a9d44138a77546ea41a67a5f3',
        }
        for path, expected in expected_hashes.items():
            with self.subTest(path=path):
                self.assertEqual(hashlib.sha256((ROOT / path).read_bytes()).hexdigest(), expected)

    def test_pair_launcher_fixes_drawing_renderer_and_observation_and_has_closed_policy(self):
        source = read(LAUNCHER)
        self.assertIn('"' + KIND + '"', source)
        self.assertIn('["reference", "memory32"].contains(policy)', source)
        self.assertIn('["certify", "resources"].contains(mode)', source)
        self.assertIn('configuration.environment["PICSHOT_DRAWING_RASTER_STRATEGY"] = "owned-srgb8"', source)
        self.assertIn('configuration.environment["PICSHOT_EFFECT_CONTEXT_POLICY"] = policy', source)
        self.assertIn('guard comparisonKind == "effect-context-memory-target"', source)
        self.assertIn('configuration.environment["PICSHOT_EDITABLE_HASH_DIAGNOSTIC"] = mode == "certify" ? "certify" : "vimage"', source)
        self.assertIn('if mode == "resources" { configuration.environment["PICSHOT_EDITABLE_ANNOTATION_RESOURCES"] = "1" }', source)
        self.assertEqual(set(re.findall(r'PICSHOT_[A-Z_]+', source)), {
            'PICSHOT_SMOKE_TEST', 'PICSHOT_SMOKE_REPORT', 'PICSHOT_EDITABLE_ANNOTATIONS_ONLY',
            'PICSHOT_EDITABLE_HASH_DIAGNOSTIC', 'PICSHOT_DRAWING_RASTER_STRATEGY',
            'PICSHOT_EFFECT_CONTEXT_POLICY',
            'PICSHOT_EDITABLE_ANNOTATION_RESOURCES',
        })
        self.assertNotIn('ProcessInfo.processInfo.environment', source)
        self.assertNotIn('#if', source)

    def test_guard_launcher_limits_environment_to_unchanged_failure_route(self):
        source = read(GUARD_LAUNCHER)
        self.assertIn('guard CommandLine.arguments.count == 4 else', source)
        self.assertIn('["reference", "memory32"].contains(policy)', source)
        self.assertIn('configuration.environment["PICSHOT_DRAWING_RASTER_STRATEGY"] = "owned-srgb8"', source)
        self.assertIn('configuration.environment["PICSHOT_EFFECT_CONTEXT_POLICY"] = policy', source)
        self.assertIn('configuration.environment["PICSHOT_EFFECT_OUTPUT_FAILURE_ONLY"] = "1"', source)
        self.assertEqual(set(re.findall(r'PICSHOT_[A-Z_]+', source)), {
            'PICSHOT_SMOKE_TEST', 'PICSHOT_SMOKE_REPORT', 'PICSHOT_EFFECT_OUTPUT_FAILURE_ONLY',
            'PICSHOT_DRAWING_RASTER_STRATEGY', 'PICSHOT_EFFECT_CONTEXT_POLICY',
        })
        self.assertNotIn('ProcessInfo.processInfo.environment', source)
        self.assertNotIn('#if', source)

    def test_original_bounds_owned_fresh_process_and_exit_are_preserved(self):
        self.assertIn('deadlineSeconds = 300.0', read('Sources/PicShot/EditableAnnotationNativeFixture.swift'))
        self.assertIn('--timeout-seconds 620 --grace-seconds 5 --max-log-bytes 2097152', read(RUNNER))
        self.assertIn('--timeout-seconds 620 --grace-seconds 5 --max-log-bytes 2097152', read('scripts/effect-context-output-guard.sh'))
        required = [
            'configuration.createsNewApplicationInstance = true', 'configuration.arguments = []',
            'configuration.addsToRecentItems = false', 'NSWorkspace.shared.openApplication(',
            'launchedProcessIdentifier = app.map { Int($0.processIdentifier) }',
            'launchedExecutablePath = app?.executableURL?.resolvingSymlinksInPath().path',
            '"ownedExitConfirmed": launched?.isTerminated == true', '"processStartMemoryCaptured": false',
            '"launchBeganUptimeSeconds": launchBeganUptime',
            '"finishUptimeSeconds": ProcessInfo.processInfo.systemUptime',
            'if launched.isTerminated { finish(0, "exited") }', 'finish(1, "timed-out")',
            '"rendererStorageStrategy": "native"', '"rendererAutoreleaseScope": "caller"',
        ]
        for path in (LAUNCHER, GUARD_LAUNCHER):
            with self.subTest(path=path):
                source = read(path)
                self.assertEqual(re.findall(r'let timeout: TimeInterval = ([^\n]+)', source), ['600'])
                for fragment in required:
                    self.assertIn(fragment, source)
                self.assertNotRegex(source, r'\b(?:killall|pkill|task_for_pid)\b')

    def test_scalar_sidecars_add_no_rasters_memory_samples_pools_or_cache_mutations(self):
        for path in (PAIR, GUARD):
            with self.subTest(path=path):
                source = read(path)
                for forbidden in [r'\b(?:CGImage|CGContext|NSImage|NSBitmapImageRep|CIImage|CIContext)\b',
                        r'\bdataProvider\b', r'\bUnsafeMutable\w*', r'\bO\.memory\s*\(',
                        r'\bautoreleasepool\s*[({]', r'\bclearCaches\s*\(',
                        r'\bManualScrollVImageObservation\b', r'\bSourceFormatOwnedCopy\.copy\b',
                        r'\bTask\.sleep\b', r'\bRunLoop\b', r'\bmalloc_zone_pressure_relief\b',
                        r'\bvm_purgable_control\b', r'\bCGRequestScreenCaptureAccess\b',
                        r'\bNSPasteboard\b', r'\bUserDefaults\b', r'\b(?:setenv|putenv)\s*\(']:
                    self.assertNotRegex(source, forbidden)
                self.assertIn('SHA256.hash(data: nativeData)', source)
                self.assertIn('SHA256.hash(data: drawingData)', source)
                self.assertNotIn('public ', source)

    def test_pair_sidecar_reuses_existing_checkpoint_names_and_final_report_identity(self):
        source = read(PAIR)
        for fragment in ['checkpoints.count < 256', 'data.count <= 256 * 1_024',
                '"maximumCheckpoints": 256', '"additionalRasterObservations": 0',
                '"additionalMemoryObservations": 0',
                '"observationBoundary": "after-existing-drawing-checkpoint"',
                '"contextOwnershipScope": "one-immutable-process-context"',
                '"contextInitializationBoundary": "after-first-drawing-memory-before-native-entry"',
                'drawingCheckpoint["workload"]', 'drawingCheckpoint["label"]',
                'EffectContextConfiguration.process.tracker.snapshot()',
                'RendererStorageConfiguration.process.tracker.snapshot()',
                'guard native["status"] as? String != "running" else { return }',
                '"sourceCommit", "executableSHA256", "executableBytes", "architecture", "processIdentifier"',
                '"productDefaultsChanged": false', '"privateFrameworkReleaseClaim": false',
                'directory.appendingPathComponent("effect-context-pair.json")',
                'observer == "vimage" || (observer == "certify" && !includeResources)']:
            self.assertIn(fragment, source)
        begin = source[source.index('    static func begin('):source.index('    static func scalar<')]
        self.assertEqual(begin.count('ProcessInfo.processInfo.environment'), 1)
        self.assertRegex(source, r'guard environment\["PICSHOT_EFFECT_CONTEXT_POLICY"\] != nil else \{ return \}')

    def test_selection_uses_immutable_process_configuration_and_fixed_other_axes(self):
        source = read(PAIR)
        selected = source[source.index('    static func selectedPolicy('):source.index('    static func begin(')]
        self.assertEqual(selected.count('ProcessInfo.processInfo.environment'), 1)
        for fragment in ['let selected = try EffectContextConfiguration.selection(environment: environment)',
                'environment["PICSHOT_SMOKE_TEST"] == "1"',
                'environment["PICSHOT_EFFECT_CONTEXT_POLICY"] == selected.rawValue',
                'environment["PICSHOT_DRAWING_RASTER_STRATEGY"] == "owned-srgb8"',
                'environment["PICSHOT_RENDERER_STORAGE_STRATEGY"] == nil',
                'DrawingRasterConfiguration.process.selectedStrategy() == .ownedSRGB8',
                'RendererStorageConfiguration.process.selectedStrategy() == .native']:
            self.assertIn(fragment, selected)
        self.assertIn('private let policy: EffectContextPolicy, resources: Bool, observer: String', source)
        self.assertIn('static let comparisonKind = "effect-context-memory-target"', source)
        self.assertNotIn('PICSHOT_EFFECT_CONTEXT_COMPARISON_KIND', source)

    def test_context_initialization_follows_first_existing_drawing_memory_and_is_rechecked_at_write(self):
        source = read(PAIR)
        checkpoint_start = source.index('    func checkpoint(')
        before_checkpoint = source[:checkpoint_start]
        self.assertNotIn('EffectContextConfiguration.process', before_checkpoint)
        self.assertNotRegex(before_checkpoint, r'\bEffectContextConfiguration\s*\(')
        checkpoint = source[checkpoint_start:source.index('    func write(')]
        self.assertIn('EffectContextConfiguration.process.tracker.snapshot()', checkpoint)
        self.assertEqual(source.index('EffectContextConfiguration.process'),
                         source.index('EffectContextConfiguration.process.tracker.snapshot()', checkpoint_start))

        drawing = read('Sources/PicShot/EditableDrawingPairDiagnostic.swift')
        self.assertLess(drawing.index(HOOKS[0]), drawing.index('try process?.checkpoint(workload: "entry", label: "native-entry")'))
        drawing_checkpoint = drawing[drawing.index('    func checkpoint('):drawing.index('    func documents(')]
        memory_append = 'checkpoints.append(["workload": workload, "label": label, "memory": try O.memory(), "drawing": tracker])'
        self.assertIn(memory_append, drawing_checkpoint)
        self.assertLess(drawing_checkpoint.index(memory_append), drawing_checkpoint.index(HOOKS[1]))

        native = read('Sources/PicShot/EditableAnnotationNativeFixture.swift')
        self.assertLess(native.index('try EditableDrawingPairDiagnostic.begin(includeResources: includeResources)'),
                        native.index('"entryMemory": try O.memory()'))
        write = source[source.index('    func write('):]
        running_guard = 'guard native["status"] as? String != "running" else { return }'
        actual_selection = 'let actualPolicy = try EffectContextConfiguration.process.selectedPolicy()'
        self.assertLess(write.index(running_guard), write.index(actual_selection))
        self.assertLess(write.index(actual_selection), write.index('var report:'))
        self.assertIn('try O.require(actualPolicy == policy, "Effect context process selection changed")', write)
        self.assertIn('"effectContextPolicy": actualPolicy.rawValue', write)

    def test_guard_binds_raw_bounded_reports_and_actual_configuration(self):
        source = read(GUARD)
        for fragment in ['guard let requested = environment["PICSHOT_EFFECT_CONTEXT_POLICY"] else { return }',
                'let selected = try EffectContextPairDiagnostic.selectedPolicy()',
                'environment["PICSHOT_EFFECT_OUTPUT_FAILURE_ONLY"] == "1"',
                'EffectContextConfiguration.process.tracker.snapshot()',
                'RendererStorageConfiguration.process.tracker.snapshot()',
                'RendererStorageConfiguration.process.selectedStrategy()',
                'DrawingRasterConfiguration.process.selectedStrategy()',
                '"status": "observed", "diagnosticOnly": true',
                '"observationBoundary": "after-effect-output-failure-fixture-return"',
                '"scalarAdditionalRasterObservations": 0', '"additionalMemoryObservations": 0',
                '"contextOwnershipScope": "one-immutable-process-context"',
                'EffectContextPolicy.productionDefault.rawValue',
                'RendererStorageStrategy.productionDefault.rawValue',
                '"executableSHA256": try O.fileDigest(executable)',
                'values.isRegularFile == true && values.isSymbolicLink == false',
                'maximum: 128 * 1_024', 'maximum: 16 * 1_024',
                'read(upToCount: maximum + 1)', 'data.count == values.fileSize',
                'data.count <= 16 * 1_024',
                'static let filename = "effect-context-output-guard.json"']:
            self.assertIn(fragment, source)

    def test_guard_positive_control_follows_and_binds_original_snapshots(self):
        source = read(GUARD)
        effect = 'let effect = EffectContextConfiguration.process.tracker.snapshot()'
        renderer = 'let renderer = RendererStorageConfiguration.process.tracker.snapshot()'
        control = 'let positiveControl = try EffectContextGuardControl.verify()'
        binding = 'try O.require(positiveControl.processBefore == effect, "Effect guard/control boundary changed")'
        for fragment in (effect, renderer, control, binding):
            self.assertEqual(source.count(fragment), 1)
        self.assertLess(source.index(effect), source.index(control))
        self.assertLess(source.index(renderer), source.index(control))
        self.assertLess(source.index(control), source.index(binding))
        self.assertLess(source.index(binding), source.index('let payload:'))
        self.assertIn('"effectContext": try EffectContextPairDiagnostic.scalar(effect)', source)
        self.assertIn('"rendererStorage": try EffectContextPairDiagnostic.scalar(renderer)', source)
        self.assertIn('"positiveControl": try EffectContextPairDiagnostic.scalar(positiveControl)', source)
        self.assertNotIn('"additionalRasterObservations"', source)
        pair = read(PAIR)
        self.assertNotIn('EffectContextGuardControl', pair)
        self.assertNotIn('positiveControl', pair)
        self.assertIn('"additionalRasterObservations": 0', pair)


if __name__ == '__main__':
    unittest.main()
