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

    def test_opt_in_route_leaves_existing_editable_path_intact(self):
        source = (ROOT / 'Sources/PicShot/SmokeVerification.swift').read_text()
        self.assertLess(source.index('EditableComponentFixture.runIfRequested'),
                        source.index('EditableAnnotationNativeFixture.verify'))
        self.assertEqual(source.count('EditableAnnotationNativeFixture.verify'), 1)
        self.assertIn('includeResources: ProcessInfo.processInfo.environment["PICSHOT_EDITABLE_ANNOTATION_RESOURCES"] == "1"', source)


if __name__ == '__main__':
    unittest.main()
