"""Portable source contracts only; these checks never attest native execution.

The two whole-source fingerprints were taken from the audited preserving-decode
119 integration. Remove only the literal, counted pair hooks before comparing.
No external baseline checkout, Git history, macOS SDK or generated run is needed.
"""
import hashlib
import importlib.util
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
NATIVE = 'Sources/PicShot/EditableAnnotationNativeFixture.swift'
OBSERVATION = 'Sources/PicShot/EditableAnnotationFixtureObservation.swift'
PAIR = 'Sources/PicShot/EditableDrawingPairDiagnostic.swift'
LAUNCHER = 'scripts/launch-editable-drawing-pair.swift'
RUNNER = 'scripts/editable-drawing-pair-diagnostic.sh'


def read(path):
    return (ROOT / path).read_text(encoding='utf-8')


def checker(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / 'scripts' / name)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


N = checker('check-editable-annotation-report.py')
O = checker('check-editable-observation-comparison.py')


class DrawingPairSourceBinding(unittest.TestCase):
    def assert_source_hash(self, source, expected):
        self.assertEqual(hashlib.sha256(source.encode('utf-8')).hexdigest(), expected)

    def remove_exact_hook(self, source, hook, replacement=''):
        self.assertEqual(source.count(hook), 1, 'Missing, duplicated or edited opt-in hook: ' + hook)
        return source.replace(hook, replacement, 1)

    def test_full_native_workload_is_preserved_after_only_four_declared_hooks(self):
        source = read(NATIVE)
        hooks = [
            ('        try EditableDrawingPairDiagnostic.begin(includeResources: includeResources)\n', ''),
            ('        defer { O.diagnostic = nil; EditableDrawingPairDiagnostic.process = nil }\n',
             '        defer { O.diagnostic = nil }\n'),
            ('        try EditableDrawingPairDiagnostic.process?.documents(original: originalDocument, applied: appliedDocument)\n', ''),
            ('        try EditableDrawingPairDiagnostic.process?.write(native: report, nativeData: data, directory: directory)\n', ''),
        ]
        for hook, replacement in hooks:
            source = self.remove_exact_hook(source, hook, replacement)
        self.assertNotIn('EditableDrawingPairDiagnostic', source)
        self.assert_source_hash(source, '3566e3fa1aad8b74347689fc17bf20b02876071c874ec259f5ca714cc1f27ccb')

    def test_full_original_observer_is_preserved_after_only_one_checkpoint_hook(self):
        source = self.remove_exact_hook(read(OBSERVATION),
            '        try EditableDrawingPairDiagnostic.process?.checkpoint(workload: workload, label: label)\n')
        self.assertNotIn('EditableDrawingPairDiagnostic', source)
        self.assert_source_hash(source, 'df169ca8ff20adae8c83d17c8c6faf07a7df4483353dc294dafd1d172ab74c0c')

    def test_existing_validators_public_routes_storage_and_component_work_are_unchanged(self):
        # Intended drawing-raster call sites and CI orchestration are not frozen
        # here. This harness must not weaken the existing acceptance validators,
        # replace storage formats, change public smoke routing or alter a prior
        # component experiment to manufacture a paired result.
        expected = {
            'scripts/check-editable-annotation-report.py': '589a9e152cad435894cd3da61602cc905bf9804a32f535637459094f89e72f01',
            'scripts/check-editable-observation-comparison.py': '6fe6ad86b2518de2ba8772b430ac86ae753cfb3391f6553a438cc2edbecac191',
            'scripts/editable-annotation-smoke.sh': 'f0a4be3748f98e5dae3bcd7d0f8da56689cddc8d4a557b888b5aa43c287dcc52',
            'Sources/PicShot/EditableComponentFixture.swift': 'f056d20286b952fd468206b63675579e7042849ed49fd60765930b938d981499',
            'Sources/PicShot/SourceFormatOwnedCopy.swift': 'af07f2432ff48bd772d0e7975324b539d1721033dc17e011478c4a8bc640c62f',
            'Sources/PicShot/EditableAnnotationDocument.swift': '8fc061da6911e5fe6d44adc9cca160dc852c2ee6091fb3e7b6ea751abde210d6',
            'Sources/PicShot/HistoryStore.swift': '80f39fcc9d13e7c957865552501051e6e949000fa7ad75445cdf80ed0ba96402',
            'Sources/PicShot/PinSessionStore.swift': 'a8e36d9c472dc57611d749d8fff58c338617e3fc13fca8d6ab52e904504659be',
            'Sources/PicShot/ImageBackingMemoryReading.swift': '69e01b4cf7e5a36b726bc4534955cb8422c225e8231f512f8688398a58db5569',
        }
        for path, digest in expected.items():
            with self.subTest(path=path):
                self.assert_source_hash(read(path), digest)
        # Other independent diagnostic routes can add their own observations.
        # Keep the complete existing editable route byte-for-byte unchanged.
        self.assertIn('''            if ProcessInfo.processInfo.environment["PICSHOT_EDITABLE_ANNOTATIONS_ONLY"] == "1" {
                var payload = try await EditableAnnotationNativeFixture.verify(evidenceDirectory: directory,
                    includeResources: ProcessInfo.processInfo.environment["PICSHOT_EDITABLE_ANNOTATION_RESOURCES"] == "1")
                payload["arguments"] = CommandLine.arguments
                try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
                try? FileManager.default.removeItem(at: history.directory)
                NSApp.terminate(nil); return
            }''', read('Sources/PicShot/SmokeVerification.swift'))

    def test_all_fifteen_native_assertions_and_full_resource_work_remain(self):
        source = read(NATIVE)
        block = source[source.index('    private static let assertions = ['):source.index('\n\n    static func verify(')]
        assertions = re.findall(r'"([A-Za-z]+)"', block)
        self.assertEqual(len(assertions), 15)
        self.assertEqual(set(assertions), N.ASSERTIONS)
        for required in [
            'warmups = 2, measured = 8, deadlineSeconds = 300.0',
            '[("small", 640, 360), ("4k", 3840, 2160)]',
            'for cycle in 0..<(warmups + measured)',
            'try await functional(directory: directory, width: 3840, height: 2160,',
            'try await release(lifetime, deadline: deadline); try await settle(deadline)',
            '"sourceWidth": 3840, "sourceHeight": 2160, "fixedInputRastersAtEndpoints": 0',
            '"realHistoryPNGMetadataRoundTripsPerCycle": true, "nativeActionsInEveryCycle": true',
            '"minimumOriginalPlusBaseBytesWhileLoaded"] = 3840 * 2160 * 8',
            '"memoryStabilityAssessed": false, "zeroLeakClaim": false',
        ]:
            self.assertIn(required, source)

    def test_existing_hash_contract_requires_35_certifications_and_205_measured_hashes(self):
        self.assertEqual(len(O.LABELS), 17)
        self.assertEqual(len(O.SMALL_LABELS), 18)
        self.assertEqual(O.workload_names(False), ['functional-small', 'functional-4k'])
        self.assertEqual(O.workload_names(True), ['functional-small', 'functional-4k'] +
                         [f'warmup-{i}' for i in range(1, 3)] + [f'measured-{i}' for i in range(1, 9)])
        self.assertEqual(sum(len(O.SMALL_LABELS if w == 'functional-small' else O.LABELS)
                             for w in O.workload_names(False)), 35)
        self.assertEqual(sum(len(O.SMALL_LABELS if w == 'functional-small' else O.LABELS)
                             for w in O.workload_names(True)), 205)
        source = read(OBSERVATION)
        for required in ['try require(mode != .certify || !includeResources,',
                         'memcmp(reference.baseAddress!, candidate.baseAddress!, reference.count) == 0',
                         'item["everyRGBAByteEqual"] = equal',
                         'try O.require(equal && referenceHash == candidateHash,',
                         '"conversionCount": hashes.count * (mode == .certify ? 2 : 1)']:
            self.assertIn(required, source)

    def test_exact_four_fresh_launches_gate_both_complete_resource_arms_on_certification(self):
        source = read(RUNNER)
        launches = re.findall(r'^launch (\S+) (\S+) (\S+)$', source, re.M)
        self.assertEqual(launches, [
            ('baseline-certification', 'reference', 'certify'),
            ('candidate-certification', 'owned-srgb8', 'certify'),
            ('baseline', 'reference', 'resources'),
            ('candidate', 'owned-srgb8', 'resources'),
        ])
        self.assertIn('set -euo pipefail', source)
        self.assertIn('! -e "$root"', source)
        self.assertIn('"$expected" =~ ^[0-9a-f]{40}$', source)
        self.assertIn('mkdir "$root/$cell"', source)
        self.assertIn('--cell "$root/$cell" --strategy "$strategy" --mode "$mode" --launcher-status "$status"', source)
        cert = source.index('--stage certification')
        self.assertLess(source.index('launch candidate-certification owned-srgb8 certify'), cert)
        self.assertLess(cert, source.index('launch baseline reference resources'))
        self.assertLess(source.index('launch candidate owned-srgb8 resources'), source.index('--stage pair'))
        self.assertEqual(source.count('codesign --verify --deep --strict "$app"'), 3)

    def test_native_300_launcher_600_and_wrapper_620_bounds_are_not_relaxed(self):
        self.assertIn('deadlineSeconds = 300.0', read(NATIVE))
        self.assertEqual(re.findall(r'let timeout: TimeInterval = ([^\n]+)', read(LAUNCHER)), ['600'])
        runner = read(RUNNER)
        self.assertIn('--timeout-seconds 620 --grace-seconds 5 --max-log-bytes 2097152', runner)
        self.assertNotRegex(read(LAUNCHER) + runner, r'\b(?:900|1200|1800)\b')

    def test_launcher_uses_identical_vimage_observation_in_both_measured_arms(self):
        source = read(LAUNCHER)
        self.assertIn('["reference", "owned-srgb8"].contains(strategy)', source)
        self.assertIn('["certify", "resources"].contains(mode)', source)
        self.assertIn('configuration.environment["PICSHOT_EDITABLE_HASH_DIAGNOSTIC"] = mode == "certify" ? "certify" : "vimage"', source)
        self.assertIn('configuration.environment["PICSHOT_DRAWING_RASTER_STRATEGY"] = strategy', source)
        self.assertIn('if mode == "resources" { configuration.environment["PICSHOT_EDITABLE_ANNOTATION_RESOURCES"] = "1" }', source)
        self.assertEqual(set(re.findall(r'PICSHOT_[A-Z_]+', source)), {
            'PICSHOT_SMOKE_TEST', 'PICSHOT_SMOKE_REPORT', 'PICSHOT_EDITABLE_ANNOTATIONS_ONLY',
            'PICSHOT_EDITABLE_HASH_DIAGNOSTIC', 'PICSHOT_DRAWING_RASTER_STRATEGY',
            'PICSHOT_EDITABLE_ANNOTATION_RESOURCES',
        })
        self.assertNotIn('ProcessInfo.processInfo.environment', source)
        self.assertNotIn('cgcontext', source)
        self.assertNotIn('#if', source)

    def test_launcher_records_owned_identity_fresh_instance_and_confirmed_exit(self):
        source = read(LAUNCHER)
        for required in [
            'configuration.createsNewApplicationInstance = true', 'configuration.arguments = []',
            'configuration.addsToRecentItems = false', 'NSWorkspace.shared.openApplication(',
            'launchedProcessIdentifier = app.map { Int($0.processIdentifier) }',
            'launchedExecutablePath = app?.executableURL?.resolvingSymlinksInPath().path',
            '"ownedExitConfirmed": launched?.isTerminated == true',
            '"processStartMemoryCaptured": false', '"launchBeganUptimeSeconds": launchBeganUptime',
            '"finishUptimeSeconds": ProcessInfo.processInfo.systemUptime',
            'if launched.isTerminated { finish(0, "exited") }',
            'finish(1, "timed-out")',
        ]:
            self.assertIn(required, source)
        self.assertNotRegex(source, r'\b(?:killall|pkill|task_for_pid)\b')

    def test_pair_selection_is_opt_in_immutable_and_uses_the_process_configuration(self):
        source = read(PAIR)
        self.assertIn('private let strategy: String, resources: Bool, observer: String', source)
        self.assertEqual(source.count('ProcessInfo.processInfo.environment'), 1)
        guard = source.index('guard environment["PICSHOT_DRAWING_RASTER_STRATEGY"] != nil else { return }')
        selection = source.index('let selected = try DrawingRasterConfiguration.process.selectedStrategy().rawValue')
        self.assertLess(guard, selection)
        self.assertIn('environment["PICSHOT_SMOKE_TEST"] == "1"', source)
        self.assertIn('environment["PICSHOT_EDITABLE_ANNOTATIONS_ONLY"] == "1"', source)
        self.assertIn('observer == "vimage" || (observer == "certify" && !includeResources)', source)
        self.assertIn('strategy: selected, resources: includeResources, observer: observer', source)
        self.assertNotRegex(source, r'(?:UserDefaults|\.standard\b|\bsetenv\s*\(|\bputenv\s*\()')
        self.assertNotIn('public ', source)

    def test_document_hook_records_the_actual_original_and_applied_native_bytes(self):
        source = read(NATIVE)
        original = source.index('let originalDocument = try EditableAnnotationDocumentCodec.encode(editor.editablePayload().document)')
        applied = source.index('let appliedDocument = try EditableAnnotationDocumentCodec.encode(applied.editablePayload().document)')
        capture = source.index('try EditableDrawingPairDiagnostic.process?.documents(original: originalDocument, applied: appliedDocument)')
        self.assertLess(original, applied)
        self.assertLess(applied, capture)
        self.assertIn('"documentSHA256": digest(originalDocument)', source)
        self.assertIn('"appliedDocumentSHA256": digest(appliedDocument)', source)
        pair = read(PAIR)
        documents = pair[pair.index('    func documents('):pair.index('    func write(')]
        self.assertIn('documentRows.count < 12 && original.count <= 131_072 && applied.count <= 131_072', documents)
        self.assertIn('"originalBase64": original.base64EncodedString()', documents)
        self.assertIn('"appliedBase64": applied.base64EncodedString()', documents)
        self.assertNotRegex(documents, r'JSON(?:Encoder|Decoder|Serialization)|UUID\(|Date\(|replacingOccurrences')

    def test_session_date_bounds_are_captured_without_rewriting_document_dates(self):
        source = read(PAIR)
        self.assertIn('private let beganReferenceDateSeconds = Date().timeIntervalSinceReferenceDate', source)
        self.assertIn('"sessionDateBounds": ["beganReferenceDateSeconds": beganReferenceDateSeconds,', source)
        self.assertIn('"finishedReferenceDateSeconds": Date().timeIntervalSinceReferenceDate]', source)
        for forbidden in ['capturedAt', 'frozenTimestamp', 'captureTimestampKnown', 'timestampIsCaptureDate']:
            self.assertNotIn(forbidden, source)

    def test_sidecar_is_bounded_metadata_and_bound_to_final_native_report_bytes(self):
        source = read(PAIR)
        for required in [
            'checkpoints.count < 256', '"maximumCheckpoints": 256',
            '"maximumDocuments": 12, "maximumDocumentBytes": 131_072',
            'data.count <= 2 * 1_024 * 1_024',
            'guard native["status"] as? String != "running" else { return }',
            '"nativeReportSHA256": SHA256.hash(data: nativeData)',
            '["sourceCommit", "executableSHA256", "architecture", "processIdentifier"]',
            'directory.appendingPathComponent("editable-drawing-pair.json")',
            '"productDefaultsChanged": false, "privateFrameworkReleaseClaim": false',
        ]:
            self.assertIn(required, source)
        for forbidden in ['CGImage', 'CGContext', 'NSImage', 'NSBitmapImageRep', 'dataProvider',
                          'UnsafeMutable', 'weak var', 'ManualScrollVImageObservation', 'SourceFormatOwnedCopy.copy']:
            self.assertNotIn(forbidden, source)
        native = read(NATIVE)
        final = native.index('report["finalMemory"] = try O.memory()')
        passed = native.index('report["status"] = "passed"', final)
        self.assertLess(passed, native.index('try write(report, directory: evidenceDirectory); return report', passed))
        native_write = native.index('try data.write(to: directory.appendingPathComponent("editable-annotation-native.json")')
        self.assertLess(native_write, native.index('try EditableDrawingPairDiagnostic.process?.write(', native_write))

    def test_pair_records_full_actual_task_accounting_and_scalar_drawing_snapshots(self):
        source = read(PAIR)
        self.assertIn('JSONEncoder().encode(DrawingRasterConfiguration.process.tracker.snapshot())', source)
        self.assertIn('"memory": try O.memory(), "drawing": tracker', source)
        observation = read(OBSERVATION)
        self.assertIn('"backingAccounting": try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))', observation)
        self.assertEqual(set(re.findall(r'"([a-z_]+)"', re.search(r'static let required = \[(.*?)\]', observation).group(1))), N.MEMORY)
        self.assertEqual(len(N.MEMORY), 8)
        for required in ['"sampleIntervalSeconds": Self.interval', 'static let interval: TimeInterval = 0.05',
                         '"continuousSampleArraysRetained": false', '"pairedTaskInfoCallsAreAtomic": false',
                         '"missingFieldsBecomeZero": false']:
            self.assertIn(required, observation)

    def test_all_four_native_snapshot_file_pixel_geometry_and_hit_checks_remain(self):
        self.assertEqual(set(N.VISUAL_NAMES), {
            'editable-reopened-light.png', 'editable-reopened-dark.png',
            'editable-hidden-pin.png', 'editable-restored-pin.png',
        })
        self.assertEqual(len(N.VISUAL_CONTROLS), 6)
        source = read(NATIVE)
        for required in [
            'root.cacheDisplay(in: root.bounds, to: bitmap)',
            'let hit = try O.required(root.hitTest(',
            'hit === canvas || hit.isDescendant(of: canvas)',
            'control.isEnabled && !control.isHiddenOrHasHiddenAncestor',
            '"sha256": try O.fileDigest(url), "rgbaSHA256": rgbaHash',
            '"cropViewportInBase": rectangle(crop)', '"nativeHitVerified": true',
            '"imageNativeHitVerified": true, "whileSnapshotLiveMemory": whileLive',
            'width <= 1280 && height <= 900', 'bytes <= 8 * 1_024 * 1_024',
        ]:
            self.assertIn(required, source)

    def test_harness_requests_no_pressure_purge_tcc_capture_or_clipboard_actions(self):
        source = '\n'.join(read(path) for path in [PAIR, NATIVE, OBSERVATION, LAUNCHER, RUNNER])
        for forbidden in [r'\bmalloc_zone_pressure_relief\s*\(', r'\bvm_purgable_control\s*\(',
                          r'\bmemory_pressure\b', r'(?m)^\s*(?:sudo\s+)?purge(?:\s|$)',
                          r'\bCGRequestScreenCaptureAccess\s*\(', r'\bCGPreflightScreenCaptureAccess\s*\(',
                          r'\bCGWindowListCreateImage\s*\(', r'\bCGDisplayCreateImage\s*\(',
                          r'\bSCStream\s*\(', r'\bNSPasteboard\.general\b', r'\bpbcopy\b',
                          r'\btccutil\b', r'\bCGEventPost\s*\(']:
            with self.subTest(forbidden=forbidden):
                self.assertNotRegex(source, forbidden)
        for field in N.FLAGS_FALSE:
            self.assertIn('"' + field + '": false', read(NATIVE))


if __name__ == '__main__':
    unittest.main()
