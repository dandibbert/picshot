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
        self.assertIn('launch_product certify product-certify certify/component.json',source[:first])
        self.assertIn('--timeout-seconds 620 --grace-seconds 5',source)
        self.assertIn('--timeout-seconds 300 --grace-seconds 5',source)
        self.assertIn('codesign --verify --deep --strict',source)
        self.assertIn('! -e "$root" && ! -L "$root"',source)

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


if __name__=='__main__':unittest.main()
