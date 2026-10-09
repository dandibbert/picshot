"""Exact source-scope tests; no native execution or memory verdict."""
import hashlib
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
import re
import unittest
from product_launcher_source_contract import without_product_launcher_hooks
from product_retirement_source_contract import without_product_retirement_waits, without_provider_test_observer

ROOT=Path(__file__).resolve().parents[2]


class ProductSourceBindingTests(unittest.TestCase):
    def test_provider_observer_is_inert_for_process_and_preserves_original_drawing_implementation(self):
        source=(ROOT/'Sources/PicShot/DrawingRaster.swift').read_text()
        environment=source[source.index('    init(environment:'):source.index('    static let process =')]
        self.assertEqual(environment.count('providerObserverForTesting = nil'),1)
        self.assertIn('static let process = DrawingRasterConfiguration(environment: ProcessInfo.processInfo.environment)',source)
        callback=source.index('            configuration.providerObserverForTesting?(provider)')
        self.assertLess(source.index('guard let provider = CGDataProvider('),callback)
        self.assertLess(callback,source.index('let image = CGImage(',callback))
        stripped=without_provider_test_observer(self,source)
        self.assertEqual(hashlib.sha256(stripped.encode()).hexdigest(),
            'ab3166f71cd826b10e137bf2c4f2171dd3b8fbf8e4da3a279337a866199c2363')

    def test_general_launcher_preserves_prior_body_after_four_literal_insertions(self):
        source=(ROOT/'scripts/launch-smoke-app.swift').read_text()
        stripped=without_product_launcher_hooks(self,source)
        self.assertEqual(hashlib.sha256(stripped.encode()).hexdigest(),'a46ab938b151e73ebadd99f2800f31e32ec147a707f9a19815555a7a2f2d8d19')

    def test_dedicated_launcher_has_only_finite_drawing_and_product_variables(self):
        source=(ROOT/'scripts/launch-editable-product.swift').read_text()
        self.assertEqual(set(re.findall(r'PICSHOT_[A-Z_]+',source)),{'PICSHOT_SMOKE_TEST','PICSHOT_SMOKE_REPORT',
            'PICSHOT_EDITABLE_PRODUCT_MODE','PICSHOT_EDITABLE_PRODUCT_INPUT','PICSHOT_EDITABLE_PRODUCT_CERTIFICATE','PICSHOT_DRAWING_RASTER_STRATEGY'})
        self.assertIn('configuration.createsNewApplicationInstance = true',source)
        self.assertIn('configuration.arguments = []',source)
        self.assertIn('ownedExitConfirmed',source)
        self.assertEqual(re.findall(r'let timeout: TimeInterval = ([^\n]+)',source),['600'])

    def test_runner_measures_both_cells_before_either_decoder_and_keeps_deadlines(self):
        source=(ROOT/'scripts/editable-product-resource.sh').read_text()
        self.assertEqual(source.count('for cell in baseline candidate; do'),2)
        first=source.index('for cell in baseline candidate; do')
        second=source.index('for cell in baseline candidate; do',first+1)
        self.assertIn('launch_product measure',source[first:second])
        self.assertNotIn('pixel-report.json',source[first:second])
        self.assertIn('drawing=reference',source[first:second])
        self.assertIn('drawing=owned-srgb8',source[first:second])
        self.assertIn('launch_product certify product-certify certify/component.json reference',source[:first])
        self.assertIn('--timeout-seconds 620 --grace-seconds 5',source)
        self.assertIn('--timeout-seconds 300 --grace-seconds 5',source)
        self.assertIn('codesign --verify --deep --strict',source)
        self.assertIn('! -e "$root" && ! -L "$root"',source)

    def test_installed_default_runner_certifies_reference_then_launches_one_unselected_app(self):
        source=(ROOT/'scripts/editable-product-installed-default.sh').read_text()
        body=source[source.index('launch_product() {'):source.index('\nlaunch_component prepare')]
        self.assertIn('unset PICSHOT_DRAWING_RASTER_STRATEGY',body)
        self.assertEqual(body.count('export PICSHOT_DRAWING_RASTER_STRATEGY'),1)
        self.assertIn('if [[ "$mode" == certify ]]; then export PICSHOT_DRAWING_RASTER_STRATEGY=reference; fi',body)
        self.assertNotIn('owned-srgb8',body)
        calls=re.findall(r'^launch_product ([^\n]+)$',source,re.M)
        self.assertEqual(calls,['certify product-certify certify/component.json',
            'installed-default installed-default product-certify/product-certificate.json'])
        measured=source.index('launch_product installed-default')
        preflight=source.index('--stage preflight --cell installed-default',measured)
        decoder=source.index('-- "$root/verification/pixel-verifier"',preflight)
        complete=source.index('--stage complete',decoder)
        self.assertLess(measured,preflight);self.assertLess(preflight,decoder);self.assertLess(decoder,complete)
        self.assertEqual(source.count('scripts/check-editable-product-resource.py --validation-mode installed-default'),3)
        self.assertIn('--timeout-seconds 620 --grace-seconds 5',source)
        self.assertIn('--timeout-seconds 300 --grace-seconds 5',source)
        self.assertIn('codesign --verify --deep --strict',source)
        self.assertIn('! -e "$root" && ! -L "$root"',source)

    def test_absent_drawing_override_reports_actual_compiled_default(self):
        source=(ROOT/'Sources/PicShot/EditableProductResourceFixture.swift').read_text()
        self.assertEqual(source.count('environment["PICSHOT_DRAWING_RASTER_STRATEGY"] ?? DrawingRasterStrategy.productionDefault.rawValue'),2)
        self.assertNotIn('environment["PICSHOT_DRAWING_RASTER_STRATEGY"] ?? "reference"',source)
        self.assertIn('case certify, measure, installedDefault = "installed-default"',source)
        self.assertIn('DrawingRasterStrategy.productionDefault == .ownedSRGB8 && drawing == .ownedSRGB8',source)
        self.assertIn('"fixtureMutatedProductionDefaults": false',source)
        self.assertNotIn('"productionDefaultsChanged"',source)
        self.assertIn('certificate["drawingOverridePresent"] as? Bool == true',source)

    def test_measurement_has_no_reference_pixel_oracle(self):
        source=(ROOT/'Sources/PicShot/EditableProductResourceFixture.swift').read_text()
        measured=source[source.index('    private static func measure('):source.index('    private static func certify(')]
        for forbidden in ('CGContext(', 'ImageEditorRenderer.render(', 'ImageOutputDecorationRenderer.project(',
                          'CGDataProviderCopyData', 'canonicalPixels(', 'O.digest(', 'Data(contentsOf:', 'dataProvider?.data'):
            self.assertNotIn(forbidden,measured)
        self.assertIn('CGImage.read(url: input.directory.appendingPathComponent("original.png"))',measured)
        self.assertIn('CGImage.read(url: input.directory.appendingPathComponent("base.png"))',measured)
        self.assertIn('static let deadlineSeconds = 300.0, copyBufferBytes = 65_536',source)
        self.assertIn('static let warmups = 2, measured = 8, width = 3840, height = 2160',source)
        # Strip only the exact bounded-retirement substitutions. The historical
        # actual workload, snapshots, outputs and copy accounting stay frozen.
        core=source[source.index('    private static func measure('):source.index('    private static func loadInput(')]
        core=without_product_retirement_waits(self,core)
        self.assertEqual(hashlib.sha256(core.encode()).hexdigest(),
            '8c27512aff4ee6ab7772ff5bfd16c1456a671f23e9ef5cd94b7553470e4d2844')


class InstalledExtractionDirectoryTests(unittest.TestCase):
    """Exercise the real shell preflight/cleanup, stopping before app extraction."""
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="picshot-preview-path-")
        self.root = Path(self.temporary.name).resolve()
        self.repo = self.root / "physical-repository"
        (self.repo / "scripts").mkdir(parents=True)
        self.scripts = ('ui-preview', 'codec-attribution', 'image-backing-attribution',
                        'recording-recovery-smoke', 'gif-attribution', 'smoke')
        for script in self.scripts:
            shutil.copyfile(ROOT / f'scripts/{script}.sh', self.repo / f'scripts/{script}.sh')
        self.tools = self.root / "tools"
        self.tools.mkdir()
        stub = self.tools / "ditto"
        stub.write_text("""#!/bin/sh
printf '%s\\n' "$@" > "$PICSHOT_TEST_DITTO_ARGUMENTS"
exit 97
""")
        stub.chmod(0o755)
        self.arguments = self.root / "ditto-arguments"
        self.environment = dict(os.environ, PATH=str(self.tools) + os.pathsep + os.environ['PATH'],
                                PICSHOT_TEST_DITTO_ARGUMENTS=str(self.arguments))

    def tearDown(self):
        self.temporary.cleanup()

    def run_preflight(self, script, root=None):
        self.arguments.unlink(missing_ok=True)
        return subprocess.run(['bash', str((root or self.repo) / f'scripts/{script}.sh')],
            cwd=self.root, env=self.environment, capture_output=True, text=True, timeout=10)

    def extraction_root(self, script):
        arguments = self.arguments.read_text().splitlines()
        self.assertEqual(arguments[:3], ['-x', '-k', 'dist/PicShot-0.16.0-macos-' + os.uname().machine + '.zip'])
        destination = Path(arguments[3])
        return destination.parent if script == 'smoke' else destination

    def test_installed_extraction_uses_fresh_owned_workspace_and_cleans_on_failure(self):
        for script in self.scripts:
            with self.subTest(script=script):
                destinations = []
                for _ in range(2):
                    result = self.run_preflight(script)
                    self.assertEqual(result.returncode, 97, result.stderr)
                    destination = self.extraction_root(script)
                    self.assertEqual(destination.parent, self.repo / 'dist')
                    prefix = 'installer-smoke' if script == 'smoke' else script
                    self.assertTrue(destination.name.startswith(prefix + '.'))
                    self.assertFalse(destination.exists(), 'Owned extraction directory survived failing extraction')
                    destinations.append(destination)
                self.assertNotEqual(destinations[0], destinations[1])

    def test_linked_repository_invocation_uses_physical_workspace_path(self):
        alias = self.root / 'repository-alias'
        alias.symlink_to(self.repo, target_is_directory=True)
        for script in self.scripts:
            with self.subTest(script=script):
                result = self.run_preflight(script, alias)
                self.assertEqual(result.returncode, 97, result.stderr)
                destination = self.extraction_root(script)
                self.assertEqual(destination.parent, self.repo / 'dist')
                self.assertNotIn(str(alias), str(destination))
                self.assertFalse(destination.exists())

    def test_redirected_dist_refuses_extraction_without_touching_other_directory(self):
        outside = self.root / 'other-owned-directory'
        outside.mkdir()
        marker = outside / 'keep.txt'
        marker.write_text('preserve')
        (self.repo / 'dist').symlink_to(outside, target_is_directory=True)
        for script in self.scripts:
            with self.subTest(script=script):
                result = self.run_preflight(script)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotEqual(result.returncode, 97)
                self.assertFalse(self.arguments.exists(), 'Extraction invoked through redirected dist')
                self.assertEqual(marker.read_text(), 'preserve')
                self.assertEqual(list(outside.iterdir()), [marker])

    def test_every_installer_extractor_is_covered(self):
        extractors = {p.stem for p in (ROOT / 'scripts').glob('*.sh')
                      if 'ditto -x -k ' in p.read_text()}
        self.assertEqual(extractors, set(self.scripts))


if __name__=='__main__':unittest.main()
