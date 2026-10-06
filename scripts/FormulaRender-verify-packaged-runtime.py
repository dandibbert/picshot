#!/usr/bin/env python3
"""Run a relocated packaged helper with its original SwiftPM build bundle hidden.

macOS only. Run after packaging, with no concurrent builds/tests in the same
build directory. The exact source bundle is renamed temporarily and restored in
a finally block. No signature, app content or runtime asset is changed.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--build-bundle", required=True, type=Path,
                        help="Exact $bin/PicShot_PicShotFormulaRenderHelper.bundle used to build the helper")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This check requires the built macOS helper")
    app = args.app.resolve(strict=True)
    source = args.build_bundle.resolve(strict=True)
    name = "PicShot_PicShotFormulaRenderHelper.bundle"
    if app.suffix != ".app" or source.name != name or not source.is_dir():
        parser.error("Expected a packaged .app and its exact SwiftPM build resource bundle")
    packaged = app / "Contents/Resources" / name
    helper = app / "Contents/Helpers/PicShotFormulaRenderHelper"
    if not packaged.is_dir() or not helper.is_file() or source == packaged.resolve():
        parser.error("Installed helper/resources must exist and differ from the original build bundle")
    hidden = source.with_name(source.name + ".FormulaRender-hidden-" + uuid.uuid4().hex)
    renamed = False

    def interrupted(signum, frame):
        raise RuntimeError(f"Interrupted by signal {signum}; restoring build resources")

    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, interrupted)
    try:
        # A fresh unrelated location ensures neither working-directory nor argv
        # behavior can accidentally find the original app/resource directory.
        with tempfile.TemporaryDirectory(prefix="FormulaRender-packaged-") as temp:
            temp = Path(temp).resolve()
            relocated = temp / "Relocated.app"
            shutil.copytree(app, relocated, symlinks=True)
            request = temp / "input.json"
            output = temp / "output.json"
            request.write_text(json.dumps({"latex": r"\frac{1}{x^2-1}", "fontSize": 24,
                                           "scale": 2, "transparent": False}), encoding="utf-8")
            source.rename(hidden)
            renamed = True
            if source.exists():
                raise RuntimeError("Original build bundle is still accessible")
            process = subprocess.run(
                [str(relocated / "Contents/Helpers/PicShotFormulaRenderHelper"),
                 "--input", str(request), "--output", str(output)],
                cwd="/", env={"HOME": str(temp), "TMPDIR": str(temp), "LANG": "en_US.UTF-8"},
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                timeout=15, check=False)
            if process.returncode != 0:
                raise RuntimeError(f"Relocated helper failed ({process.returncode}): " +
                                   process.stderr[:2048].decode("utf-8", errors="replace"))
            if not output.is_file() or output.stat().st_size > 24 * 1024 * 1024:
                raise RuntimeError("Missing or oversized helper output")
            result = json.loads(output.read_text(encoding="utf-8"))
            assert "<mfrac>" in result["mathML"] and "<path " in result["svg"]
            assert base64.b64decode(result["png"]).startswith(b"\x89PNG\r\n\x1a\n")
            assert base64.b64decode(result["pdf"]).startswith(b"%PDF-")
            assert 0 < result["width"] <= 4096 and 0 < result["height"] <= 4096
            assert result["width"] * result["height"] <= 4194304
            # Removing installed resources must fail; even the hidden build copy
            # cannot supply a fallback. This also catches accidental code search.
            shutil.rmtree(relocated / "Contents/Resources" / name)
            output.unlink()
            missing = subprocess.run(
                [str(relocated / "Contents/Helpers/PicShotFormulaRenderHelper"),
                 "--input", str(request), "--output", str(output)], cwd="/",
                env={"HOME": str(temp), "TMPDIR": str(temp), "LANG": "en_US.UTF-8"},
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                timeout=15, check=False)
            if missing.returncode == 0 or output.exists():
                raise RuntimeError("Helper unexpectedly rendered without installed resources")
            print("PASS: relocated packaged renderer works without build resources; missing installed resources fail closed")
    finally:
        if renamed:
            if source.exists():
                raise RuntimeError(f"Refusing to overwrite a concurrently created build bundle; restore {hidden} manually")
            hidden.rename(source)


if __name__ == "__main__":
    main()
