"""Portable negative checks for the production helper packaging contract."""
import importlib.util
import json
from pathlib import Path
import plistlib
import re
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('text_script_package', ROOT / 'scripts/verify-text-script-package.py')
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)


class TextScriptPackageTests(unittest.TestCase):
    def test_sandbox_requires_one_boolean_true(self):
        self.assertEqual(VERIFY.require_sandbox({VERIFY.ENTITLEMENT: True}), {VERIFY.ENTITLEMENT: True})
        for value in (None, {}, {VERIFY.ENTITLEMENT: 1}, {VERIFY.ENTITLEMENT: 'true'},
                      {VERIFY.ENTITLEMENT: False}, {VERIFY.ENTITLEMENT: True, 'com.apple.security.network.client': True}):
            with self.subTest(value=value), self.assertRaises(RuntimeError):
                VERIFY.require_sandbox(value)

    def test_checked_in_plist_and_entitlements(self):
        VERIFY.require_sandbox(plistlib.loads((ROOT / 'scripts/text-script-helper.entitlements').read_bytes()))
        expected = VERIFY.require_helper_plist(plistlib.loads((ROOT / 'scripts/text-script-helper-Info.plist').read_bytes()))
        VERIFY.require_exact_plist(dict(reversed(list(expected.items()))), expected)
        for value in ({**expected, 'CFBundleIdentifier': 'local.picshot.app'},
                      {**expected, 'CFBundleExecutable': 'PicShotTextScriptGate'}):
            with self.assertRaises(RuntimeError):
                VERIFY.require_helper_plist(value)
        for value in ({**expected, 'InjectedKey': True}, {**expected, 'CFBundleVersion': 1}):
            with self.assertRaises(RuntimeError):
                VERIFY.require_exact_plist(value, expected)
        with self.assertRaises(RuntimeError):
            VERIFY.require_exact_plist({'key': 1}, {'key': True})

    def test_signing_identity_requires_cdhash_team_and_exact_identifier(self):
        valid = 'Identifier=com.picshot.TextScriptHelper\nCDHash=' + 'ab' * 20 + '\nTeamIdentifier=not set\nSignature=adhoc\n'
        self.assertIsNone(VERIFY.signing_fields(valid, VERIFY.IDENTIFIER)['TeamIdentifier'])
        for value in (valid.replace('Signature=adhoc\n', ''), valid.replace('TeamIdentifier=not set\n', ''),
                      valid.replace('com.picshot.TextScriptHelper', 'local.picshot.app'),
                      valid.replace('ab' * 20, 'invalid'), valid + 'Identifier=other\n'):
            with self.subTest(value=value), self.assertRaises(RuntimeError):
                VERIFY.signing_fields(value, VERIFY.IDENTIFIER)

    def test_team_mismatch_and_signed_versus_adhoc_fail(self):
        for app, helper in (('TEAM123', 'TEAM456'), (None, 'TEAM123'), ('TEAM123', None)):
            with self.assertRaises(RuntimeError):
                VERIFY.require_same_team({'TeamIdentifier': app}, {'TeamIdentifier': helper})
        for team in (None, 'TEAM123'):
            VERIFY.require_same_team({'TeamIdentifier': team}, {'TeamIdentifier': team})

    def test_helper_paths_reject_links_nonexecutables_and_gate_payloads(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary).resolve() / 'PicShot.app'
            helper = app / VERIFY.HELPER_PATH
            helper.parent.mkdir(parents=True)
            helper.write_bytes(b'fixture')
            with self.assertRaises(RuntimeError):
                VERIFY.check_regular_helper(app)
            helper.chmod(0o755)
            self.assertEqual(VERIFY.check_regular_helper(app), helper)
            original = helper.with_name('original')
            helper.rename(original)
            helper.symlink_to(original.name)
            with self.assertRaises(RuntimeError):
                VERIFY.check_regular_helper(app)
            helper.unlink()
            original.rename(helper)
            duplicate = helper.with_name('hardlink')
            duplicate.hardlink_to(helper)
            with self.assertRaises(RuntimeError):
                VERIFY.check_regular_helper(app)
            duplicate.unlink()
            for name in VERIFY.FORBIDDEN:
                fixture = helper.with_name(name)
                fixture.write_text('must not ship')
                with self.assertRaises(RuntimeError):
                    VERIFY.check_regular_helper(app)
                fixture.unlink()

    def test_production_manifest_registers_existing_fourteen_methods_without_gate(self):
        manifest = (ROOT / 'Package.swift').read_text()
        self.assertNotIn('TEXT_SCRIPT_GATE', manifest)
        for name in VERIFY.FORBIDDEN:
            self.assertNotIn('"' + name + '"', manifest)
        for name in VERIFY.MODULES:
            self.assertIn('name: "' + name + '"', manifest)
        self.assertIn('"__TEXT", "-Xlinker", "__info_plist"', manifest)
        helper = re.search(r'\.executableTarget\(name: "PicShotTextScriptHelper", dependencies: \[([^\]]+)\]', manifest)
        self.assertEqual(helper.group(1), '"PicShotTextScriptCore"')
        app = re.search(r'\.executableTarget\(name: "PicShot", dependencies: \[([^\]]+)\]', manifest)
        for name in ('PicShotTextScriptCore', 'PicShotTextScriptProcess'):
            self.assertIn('"' + name + '"', app.group(1))
        methods = []
        for name in ('PicShotTextScriptCoreTests', 'PicShotTextScriptHelperTests'):
            self.assertIn('.testTarget(name: "' + name + '"', manifest)
            for source in (ROOT / 'Tests' / name).glob('*.swift'):
                methods.extend(re.findall(r'\bfunc (test\w+)\(', source.read_text()))
        self.assertEqual(len(methods), 14)

    def test_no_recursive_signing_after_sandbox_helper(self):
        script = (ROOT / 'scripts/package.sh').read_text()
        helper_sign = script.index('codesign --force --sign - --identifier com.picshot.TextScriptHelper')
        self.assertLess(script.index('codesign --force --deep --sign - --identifier local.picshot.app'), helper_sign)
        remaining_signs = [line for line in script[helper_sign:].splitlines() if line.startswith('codesign ') and '--sign ' in line]
        self.assertEqual(len(remaining_signs), 2)
        self.assertTrue(all('--deep' not in line for line in remaining_signs))
        proof = script.index('python3 scripts/verify-text-script-package.py')
        self.assertGreater(proof, script.index('python3 scripts/FormulaRender-verify-packaged-runtime.py'))
        self.assertLess(proof, script.index('PICSHOT_PACKAGE_APP_ONLY'))
        self.assertIn('--verify-relocation', script[proof:].splitlines()[0])
        self.assertLess(proof, script.index('ditto -c -k'))

    def test_source_proof_rejects_uncommitted_app_integration(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = list(VERIFY.PACKAGE_SOURCES + VERIFY.INTEGRATION_SOURCES)
            paths.extend('Sources/' + name + '/Fixture.swift' for name in VERIFY.MODULES)
            paths.extend('Tests/' + name + '/Fixture.swift' for name in
                         ('PicShotTextScriptCoreTests', 'PicShotTextScriptHelperTests'))
            committed = {}
            for name in paths:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('original ' + name)
                committed[name] = path.read_bytes()
            source = 'a' * 40

            def git(command, **kwargs):
                if command == ['git', 'rev-parse', 'HEAD']:
                    return SimpleNamespace(stdout=(source + '\n').encode())
                self.assertEqual(command[:2], ['git', 'show'])
                return SimpleNamespace(stdout=committed[command[2].split(':', 1)[1]])

            with patch.object(VERIFY, 'run', side_effect=git):
                entries = VERIFY.source_inventory(root, source)
                self.assertEqual({entry['path'] for entry in entries}, set(paths))
                app_main = root / 'Sources/PicShot/AppMain.swift'
                app_main.write_text('changed integration after commit')
                with self.assertRaisesRegex(RuntimeError, 'Source differs from exact commit'):
                    VERIFY.source_inventory(root, source)
                app_main.write_bytes(committed['Sources/PicShot/AppMain.swift'])
                (root / 'Sources/PicShot/TextScriptUIPreviewFixture.swift').unlink()
                with self.assertRaisesRegex(RuntimeError, 'Invalid source path'):
                    VERIFY.source_inventory(root, source)


if __name__ == '__main__':
    unittest.main()
