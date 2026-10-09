#!/usr/bin/env python3
"""Build/run a bounded separate native reader, then join its installed evidence.

Requires macOS and this checkout's existing pinned .build/native-codecs/install;
does not download, install, dispatch CI, modify the application, or add a runtime
dependency. Invoke after the installed application has retained all witnesses.
"""
import argparse
import importlib.util
import os
from pathlib import Path
import platform
import signal
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def run(command, timeout, log):
    with log.open("wb") as output:
        child = subprocess.Popen([str(x) for x in command], stdout=output, stderr=subprocess.STDOUT,
                                 start_new_session=True)
        try:
            status = child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait(timeout=5)
            raise RuntimeError(f"Native verification command exceeded {timeout}s: {command[0]}")
    if status:
        detail = log.read_bytes()[:65536].decode("utf-8", "replace")
        raise RuntimeError(f"Native verification command failed ({status}): {detail}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence_directory", type=Path)
    parser.add_argument("source_commit")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.exit(1, "Native verification requires macOS; no native evidence was produced\n")
    architecture = platform.machine()
    if architecture not in ("arm64", "x86_64"):
        parser.exit(1, "Unsupported native verification architecture\n")
    prefix = ROOT / ".build/native-codecs/install"
    libraries = [prefix / "lib" / name for name in
                 ("libwebpdemux.a", "libwebp.a", "libsharpyuv.a", "libavif.a", "libaom.a")]
    if not all(x.is_file() for x in libraries):
        parser.exit(1, "Existing pinned native codec build is required; this command will not fetch/install it\n")
    bridge = ROOT / "Sources/CPicShotCodecs"
    try:
        sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], timeout=10, text=True).strip()
        with tempfile.TemporaryDirectory(prefix="PicShot-Input-Export-Validator-") as temporary:
            temporary = Path(temporary)
            obj, binary, log = temporary / "codecs.o", temporary / "validator", temporary / "command.log"
            run(["xcrun", "clang", "-std=c11", "-O2", "-arch", architecture, "-mmacosx-version-min=14.0",
                 "-isysroot", sdk, "-I" + str(prefix / "include"), "-I" + str(bridge / "include"),
                 "-c", bridge / "CPicShotCodecs.c", "-o", obj], 60, log)
            run(["xcrun", "swiftc", "-O", "-parse-as-library", "-target", architecture + "-apple-macosx14.0",
                 "-sdk", sdk, "-import-objc-header", bridge / "include/CPicShotCodecs.h",
                 ROOT / "Sources/PicShot/RecordingInputExportOracle.swift",
                 ROOT / "scripts/RecordingInputExportValidator.swift", obj, *libraries, "-lc++", "-o", binary], 120, log)
            run([binary, args.evidence_directory.resolve(), args.source_commit], 90, log)
        spec = importlib.util.spec_from_file_location("recording_input_export_gate", ROOT / "scripts/check-recording-input-exports.py")
        gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gate)
        import json
        print(json.dumps(gate.validate(args.evidence_directory, args.source_commit), sort_keys=True))
    except (RuntimeError, OSError, subprocess.SubprocessError, ValueError) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    main()
