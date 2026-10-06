"""Portable policy tests. These do not download/build or establish a macOS pass."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "build-native-codecs.py"
spec = importlib.util.spec_from_file_location("build_native_codecs", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class NativeBuildPolicyTests(unittest.TestCase):
    def test_exact_approved_pins(self):
        self.assertEqual(module.PINS["libwebp"][1], "4fa21912338357f89e4fd51cf2368325b59e9bd9")
        self.assertEqual(module.PINS["libavif"][1], "c5240fc79fe5c2407e10afd35f5505ef6333ea49")
        self.assertEqual(module.PINS["libaom"], ("3.15.0", "de4c1d1edc49723a78954d30a83690aa1937422f", "https://aomedia.googlesource.com/aom"))

    def test_host_and_architecture_fail_closed(self):
        module.validate_host("arm64", "Darwin", "arm64")
        module.validate_host("x86_64", "Darwin", "x86_64")
        for arch, system, host in (("arm64","Linux","arm64"),("arm64","Darwin","x86_64"),("x86_64","Darwin","arm64"),("universal","Darwin","universal")):
            with self.assertRaises(RuntimeError): module.validate_host(arch,system,host)

    def test_pin_mismatch_rejected(self):
        pin=module.PINS["libaom"][1]
        module.validate_pin(pin,pin+"\n")
        with self.assertRaises(RuntimeError): module.validate_pin(pin,"0"*40)
        with self.assertRaises(RuntimeError): module.validate_pin("main","main")

    def test_full_nested_legal_files_and_inline_notices_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);source=root/"source";output=root/"licenses"
            (source/"third_party/component").mkdir(parents=True)
            original="Full LICENSE\n"+"Do not truncate this legal text.\n"*1000
            (source/"LICENSE").write_text(original)
            (source/"third_party/component/LICENSE.txt").write_text("component license\n")
            (source/"file.c").write_text("/* Copyright Someone.\nRedistribution conditions. */\nint x;\n")
            records=module.inventory_licenses(source,output)
            self.assertEqual((output/"LICENSE").read_text(),original)
            self.assertEqual((output/"third_party/component/LICENSE.txt").read_text(),"component license\n")
            self.assertIn("Redistribution conditions.",(output/"SOURCE_FILE_NOTICES.txt").read_text())
            self.assertEqual({r["path"] for r in records},{"LICENSE","third_party/component/LICENSE.txt","SOURCE_FILE_NOTICES.txt"})
            self.assertTrue(all(len(r["sha256_local"])==64 for r in records))

    def test_missing_notices_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/"source").mkdir()
            with self.assertRaises(RuntimeError):module.inventory_licenses(root/"source",root/"notices")

    def test_aom_unknown_and_overridden_options_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            source=Path(directory)
            (source/"CMakeLists.txt").write_text('set_aom_config_var(CONFIG_LIBYUV 1 "library")\nset_aom_option_var(ENABLE_APPS "apps" ON)\n')
            flags=["-DCONFIG_LIBYUV=0","-DENABLE_APPS=OFF"]
            module.verify_aom_option_definitions(source,flags)
            with self.assertRaises(RuntimeError):module.verify_aom_option_definitions(source,["-DCONFIG_UNKNOWN=0"])
            module.verify_aom_cache("CONFIG_LIBYUV:STRING=0\nENABLE_APPS:BOOL=OFF\n",flags)
            with self.assertRaises(RuntimeError):module.verify_aom_cache("CONFIG_LIBYUV:STRING=1\nENABLE_APPS:BOOL=OFF\n",flags)
            with self.assertRaises(RuntimeError):module.verify_aom_cache("",flags)

    def test_no_unapproved_codec_archive(self):
        self.assertEqual(set(module.LIBRARIES),{"libwebp.a","libsharpyuv.a","libwebpdemux.a","libavif.a","libaom.a"})
        text=SCRIPT.read_text()
        self.assertIn('"-DAVIF_CODEC_AOM=SYSTEM"',text)
        self.assertNotIn('"-DAVIF_CODEC_AOM=LOCAL"',text)
        self.assertIn('(deny network*)',text)
        self.assertIn('"-DFETCHCONTENT_FULLY_DISCONNECTED=ON"',text)


if __name__=="__main__": unittest.main()
