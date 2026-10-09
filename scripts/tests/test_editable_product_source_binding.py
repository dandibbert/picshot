"""Exact source-scope tests; no native execution or memory verdict."""
import hashlib
from pathlib import Path
import re
import unittest
from product_launcher_source_contract import without_product_launcher_hooks

ROOT=Path(__file__).resolve().parents[2]


class ProductSourceBindingTests(unittest.TestCase):
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
        # Source133's entire actual workload, snapshots, copy accounting and
        # retirement implementation remain unchanged for default validation.
        core=source[source.index('    private static func measure('):source.index('    private static func loadInput(')]
        self.assertEqual(hashlib.sha256(core.encode()).hexdigest(),
            '8c27512aff4ee6ab7772ff5bfd16c1456a671f23e9ef5cd94b7553470e4d2844')


if __name__=='__main__':unittest.main()
