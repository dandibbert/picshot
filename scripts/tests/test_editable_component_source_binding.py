"""Portable source integrity checks; never native execution evidence."""
import hashlib
import re
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class FixtureSourceBinding(unittest.TestCase):
    def test_verbatim_fixture_generation_matches_audited_owner(self):
        source = (ROOT / 'Sources/PicShot/EditableComponentFixture.swift').read_text()
        start = source.index('    private static var decoration:')
        end = source.index('\n}\n', start)
        block = source[start:end] + '\n'
        self.assertEqual(hashlib.sha256(block.encode()).hexdigest(),
                         'fa69a1f70ee2397b7aaf6de4c6810c1401ffec5a5cf63987403496bdc8ac42b3')

    def test_candidate_keeps_all_three_independent_build113_pixel_hashes(self):
        source = (ROOT / 'Sources/PicShot/EditableComponentFixture.swift').read_text()
        start = source.index('    static let expectedHashes = [')
        end = source.index('    enum Mode:', start)
        self.assertEqual(dict(re.findall(r'"(original|base|current)": "([a-f0-9]{64})"', source[start:end])), {
            'original': 'c7819513b71c4ad1675665feece59747ff9a518db5766c5a8de973f65fdf19c6',
            'base': 'b41f79800dd04476e3381aa6fa9da0a2e4f61034729dce3551909a383be83fc9',
            'current': 'b8362e485bb0bfc04471d4a9de1eaf01be470fb66f419193fa41966cdcaaaff5',
        })

    def test_no_direct_or_reference_helper_weak_corefoundation_probes(self):
        source = (ROOT / 'Sources/PicShot/EditableComponentFixture.swift').read_text()
        self.assertNotIn('lifetime.image(', source)
        self.assertNotIn('O.referencePixels(', source)
        self.assertNotIn('weak var image', source)
        self.assertIn('coreFoundationWeakProbesUsed": false', source)

    def test_component_launcher_has_fixed_timeout_and_exact_environment_scope(self):
        source = (ROOT / 'scripts/launch-editable-component.swift').read_text()
        self.assertEqual(re.findall(r'let timeout: TimeInterval = ([^\n]+)', source), ['600'])
        expected = {'PICSHOT_SMOKE_TEST', 'PICSHOT_SMOKE_REPORT',
                    'PICSHOT_EDITABLE_COMPONENT_MODE', 'PICSHOT_EDITABLE_COMPONENT_INPUT',
                    'PICSHOT_EDITABLE_COMPONENT_CERTIFICATE', 'PICSHOT_EDITABLE_COMPONENT_WRITES'}
        self.assertEqual(set(re.findall(r'PICSHOT_[A-Z_]+', source)), expected)
        forwarded = re.search(r'for key in \[(.*?)\] \{', source).group(1)
        self.assertEqual(set(re.findall(r'"(PICSHOT_[A-Z_]+)"', forwarded)), expected -
                         {'PICSHOT_SMOKE_TEST', 'PICSHOT_SMOKE_REPORT'})
        self.assertEqual(source.count('ProcessInfo.processInfo.environment'), 1)
        self.assertNotIn('#if', source)
        self.assertNotIn('900', source)

    def test_effect_only_route_retains_priority_and_component_follows_immediately(self):
        source = (ROOT / 'Sources/PicShot/SmokeVerification.swift').read_text()
        effect = source.index('if ProcessInfo.processInfo.environment["PICSHOT_EFFECT_OUTPUT_FAILURE_ONLY"]')
        component = source.index('if ProcessInfo.processInfo.environment.keys.contains(where:')
        recording = source.index('if ProcessInfo.processInfo.environment["PICSHOT_RECORDING_COMPOSITION_ONLY"]')
        self.assertLess(effect, component)
        self.assertLess(component, recording)
        between = source[source.index('NSApp.terminate(nil); return', effect):component]
        self.assertNotIn('if ', between)
        self.assertEqual(source.count('EditableComponentFixture.runIfRequested'), 1)

    def test_component_cleanup_is_installed_before_throwing_request_parser(self):
        source = (ROOT / 'Sources/PicShot/SmokeVerification.swift').read_text()
        start = source.index('if ProcessInfo.processInfo.environment.keys.contains(where:')
        end = source.index('            // Explicit diagnostic route:', start)
        route = source[start:end]
        self.assertIn('$0.hasPrefix("PICSHOT_EDITABLE_COMPONENT_")', route)
        cleanup = 'defer { try? FileManager.default.removeItem(at: history.directory) }'
        invocation = 'guard let payload = try await EditableComponentFixture.runIfRequested'
        self.assertLess(route.index(cleanup), route.index(invocation))
        self.assertIn('throw PicShotError.message("Component diagnostic request disappeared")', route)
        self.assertEqual(route.count('FileManager.default.removeItem(at: history.directory)'), 2)
        self.assertLess(route.rindex('FileManager.default.removeItem'), route.index('NSApp.terminate(nil)'))
        # No selection means this local cleanup scope is never entered; unrelated
        # smoke paths retain their established behavior.
        self.assertTrue(route.startswith('if ProcessInfo.processInfo.environment.keys.contains(where:'))

    def test_existing_consumer_and_decode_work_is_byte_identical(self):
        source = (ROOT / 'Sources/PicShot/EditableComponentFixture.swift').read_text()
        # Baseline 430960b: candidate insertion must not alter the comparison
        # cells, original ImageIO options, provider ownership or editable work.
        blocks = [
            ('simpleCycle', '    // This candidate owns', '67a56eff55e290b421070d0c826664d495811ad0c70f6582721be4c84af110d0'),
            ('editableCycle', '    private static func verifyWrites(', 'b6d47f3f1b7e1a81ab9bb1d4b223712e809a3f67810211f4b8d79eceb0a9c768'),
            ('decode', '    private static func owned(', 'f1730a192db2694e67ccff9482de4f9d198db7f7cdf2b2606e782a0a445c36af'),
            ('owned', '    final class OwnedBytes', '69c3c595c19507ee019e2209bac459962642f5a85a0fb234d39f39b0c67d890d'),
        ]
        for name, end_marker, expected in blocks:
            with self.subTest(function=name):
                start = source.index('    private static func ' + name + '(')
                end = source.index(end_marker, start)
                self.assertEqual(hashlib.sha256(source[start:end].encode()).hexdigest(), expected)

    def test_owned_candidate_converts_without_context_snapshot_or_preview(self):
        source = (ROOT / 'Sources/PicShot/EditableComponentFixture.swift').read_text()
        start = source.index('    private static func ownedDecodeCycle(')
        end = source.index('    private static func editableCycle(', start)
        candidate = source[start:end]
        self.assertIn('import Accelerate', source)
        self.assertEqual(candidate.count('try decode(asset.png, asset: asset)'), 1)
        self.assertEqual(candidate.count('vImageBuffer_InitWithCGImage(&buffer, &format, nil, decoded, flags)'), 1)
        self.assertEqual(candidate.count('vImage_Flags(kvImageNoAllocate)'), 1)
        for text in ['OwnedBytes(count: asset.byteCount, data: nil',
                     'vImage_Buffer(data: bytes.pointer, height: vImagePixelCount(asset.height)',
                     'width: vImagePixelCount(asset.width), rowBytes: asset.width * 4',
                     'error == kvImageNoError && buffer.data == bytes.pointer',
                     'buffer.rowBytes == asset.width * 4',
                     'CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue',
                     'CGColorSpace(name: CGColorSpace.sRGB)',
                     'try destinations[asset.role]!.compare(image, asset: asset, label: asset.role)',
                     'owner.callback(count)', 'Unmanaged<OwnedBytes>.fromOpaque(info).takeRetainedValue()']:
            self.assertIn(text, candidate)
        for forbidden in ['CGContext(', 'context.draw(', 'makeImage(', 'canonicalPixels(',
                          'owned(asset', 'asset.raw.withUnsafeBytes', 'ImageOutputDecorationRenderer',
                          'MultiWindowCompositeRenderer', 'vImageScale', 'CGImageSourceCreateThumbnail',
                          '.cropping(', 'lifetime.image(']:
            self.assertNotIn(forbidden, candidate)
        pool = candidate.index('let result: (CGImage, [String: Any]) = try autoreleasepool {')
        returned = candidate.index('return (image, [', pool)
        released = candidate.index('record["afterDecodedInputReleaseMemory"]', returned)
        ready = candidate.index('let afterCreation = try O.memory()', released)
        draw = candidate.index('try destinations[asset.role]!.compare(', ready)
        self.assertLess(pool, returned)
        self.assertLess(returned, released)
        self.assertLess(released, ready)
        self.assertLess(ready, draw)
        self.assertIn('withExtendedLifetime(decoded) { try O.memory() }', candidate)
        self.assertIn('"imageCreationCount": 6', candidate)
        self.assertIn('"pngDecodeCount": 3, "ownedNormalizationCount": 3', candidate)
        self.assertIn('"decodedInputReferencesReleasedBeforeValidation": true', candidate)

    def test_runner_requires_all_six_consumers_in_fresh_processes(self):
        runner = (ROOT / 'scripts/editable-components-diagnostic.sh').read_text()
        consumers = re.search(r'for mode in (.*?); do launch "\$mode"; done', runner).group(1).split()
        self.assertEqual(consumers, ['raw-draw', 'png-write', 'png-decode-draw',
                                    'png-decode-owned-draw', 'png-decode-preserved-draw', 'editable-render-pin'])
        self.assertEqual(re.findall(r'^launch ([-a-z]+)$', runner, re.M), ['prepare', 'certify', 'verify-writes'])
        self.assertEqual(len(consumers) + 3, 9)
        self.assertIn('--timeout-seconds 620 --grace-seconds 5', runner)
        source = (ROOT / 'Sources/PicShot/EditableComponentFixture.swift').read_text()
        self.assertIn('deadlineSeconds = 300.0', source)
        self.assertIn('sourceWidth = 3840, sourceHeight = 2160, warmups = 2, measured = 8', source)
        self.assertIn('} else if mode == .pngDecodeOwnedDraw {', source)
        self.assertIn('try ownedDecodeCycle(input, destinations: destinations, trackers: trackers, deadline: deadline)', source)

    def test_preserving_candidate_keeps_existing_canonical_cell_byte_identical(self):
        source = (ROOT / 'Sources/PicShot/EditableComponentFixture.swift').read_text()
        start = source.index('    private static func ownedDecodeCycle(')
        end = source.index('    private static func editableCycle(', start)
        self.assertEqual(hashlib.sha256(source[start:end].encode()).hexdigest(),
                         '8575366ea40a5211446f5c57db39fdacba3c15e8ac949df724dab50b1aed1926')

    def test_preserving_helper_uses_source_format_bounded_owned_storage_without_drawing(self):
        source = (ROOT / 'Sources/PicShot/SourceFormatOwnedCopy.swift').read_text()
        for required in ['kvImageNoAllocate', 'calloc(1, count)', 'free(pointer)',
                         'Unmanaged.passUnretained(color)', 'bitmapInfo: source.bitmapInfo',
                         'bitsPerComponent: UInt32(source.bitsPerComponent)',
                         'bitsPerPixel: UInt32(source.bitsPerPixel)',
                         'version: 0, decode: nil, renderingIntent: source.renderingIntent',
                         'rowBytes: source.bytesPerRow', 'buffer.data == bytes.pointer',
                         'shouldInterpolate: source.shouldInterpolate', 'intent: source.renderingIntent',
                         'image.decode != nil', 'multipliedReportingOverflow',
                         'case unchanged(image: CGImage, reason: UnsupportedReason)',
                         'owner.callback(count)', 'Unmanaged<Bytes>.fromOpaque(info).takeRetainedValue()']:
            self.assertIn(required, source)
        for forbidden in ['CGContext(', '.draw(', 'makeImage(', 'CGImageSourceCreateThumbnail',
                          'CGColorSpace(name:', 'dataProvider?.data', 'CFDataGetBytePtr', 'weak var']:
            self.assertNotIn(forbidden, source)
        copy_start = source.index('    static func copy(')
        fallback = source.index('if let reason = unsupported(source)', copy_start)
        admission = source.index('let byteCount = try checkedStorage(', copy_start)
        allocation = source.index('let bytes = try Bytes(', copy_start)
        self.assertLess(fallback, admission)
        self.assertLess(admission, allocation)
        self.assertLess(source.index('try tracker?.reserve(count)'), source.index('calloc(1, count)'))
        calls = []
        for path in (ROOT / 'Sources').rglob('*.swift'):
            if 'SourceFormatOwnedCopy.copy(' in path.read_text():
                calls.append(path.name)
        self.assertEqual(calls, ['EditableComponentFixture.swift'])

    def test_raw_preservation_oracle_is_outside_measured_cycles(self):
        source = (ROOT / 'Sources/PicShot/EditableComponentFixture.swift').read_text()
        start = source.index('    private static func preservedDecodeCycle(')
        end = source.index('    private static func certifyPreservingCopies(', start)
        cycle = source[start:end]
        for forbidden in ['dataProvider', 'comparePreservedSamples(', 'CFDataGetBytePtr',
                          'rawSampleValidation": raw', 'afterRawValidationMemory']:
            self.assertNotIn(forbidden, cycle)
        for required in ['"rawSampleValidationInMeasuredProcess": false',
                         '"rawSampleValidationSource": "fresh-certification-process"',
                         '"rawSampleCertificateSHA256": input.certificateHash!',
                         'SourceFormatOwnedCopy.copy(decoded',
                         'guard case .owned(let image, let ownedBytes) = outcome',
                         '"imageCreationCount": 6', '"pngDecodeCount": 3, "ownedPreservingCopyCount": 3',
                         '"preservedCopyFallbackCount": 0', '"preservedCopyFailureCount": 0']:
            self.assertIn(required, cycle)
        self.assertLess(cycle.index('record["afterDecodedInputReleaseMemory"]'),
                        cycle.index('try destinations[asset.role]!.compare('))
        certificate = source[end:source.index('    // Verbatim fixture generators', end)]
        self.assertIn('let raw = try comparePreservedSamples(decoded, image)', certificate)
        self.assertIn('source.dataProvider?.data', certificate)
        self.assertIn('owned.dataProvider?.data', certificate)
        self.assertIn('memcmp(original.advanced(by: offset)', certificate)
        self.assertIn('state.releaseCallbacks == 1 && state.deallocations == 1', certificate)
        self.assertIn('report["preservingValidations"] = try certifyPreservingCopies(bundle!)', source)

    def test_opt_in_route_leaves_existing_editable_path_intact(self):
        source = (ROOT / 'Sources/PicShot/SmokeVerification.swift').read_text()
        self.assertLess(source.index('EditableComponentFixture.runIfRequested'),
                        source.index('EditableAnnotationNativeFixture.verify'))
        self.assertEqual(source.count('EditableAnnotationNativeFixture.verify'), 1)
        self.assertIn('includeResources: ProcessInfo.processInfo.environment["PICSHOT_EDITABLE_ANNOTATION_RESOURCES"] == "1"', source)


if __name__ == '__main__':
    unittest.main()
