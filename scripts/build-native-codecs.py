#!/usr/bin/env python3
"""Build PicShot's approved, pinned codecs on a native macOS CI runner.

No package manager, prebuilt codec or network-enabled CMake sub-build is used.
Nothing is downloaded when imported by the portable policy tests.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys

PINS = {
    "libwebp": ("1.6.0", "4fa21912338357f89e4fd51cf2368325b59e9bd9", "https://github.com/webmproject/libwebp.git"),
    "libaom": ("3.15.0", "de4c1d1edc49723a78954d30a83690aa1937422f", "https://aomedia.googlesource.com/aom"),
    "libavif": ("1.4.2", "c5240fc79fe5c2407e10afd35f5505ef6333ea49", "https://github.com/AOMediaCodec/libavif.git"),
}
LIBRARIES = ("libwebp.a", "libsharpyuv.a", "libwebpdemux.a", "libavif.a", "libaom.a")
LEGAL_NAME = re.compile(r"^(?:COPYING|LICENSE|LICENCE|PATENTS|NOTICE|AUTHORS|COPYRIGHT)(?:[._-].*)?$", re.I)
COMMENT = re.compile(r"/\*.*?\*/|(?:(?://[^\n]*\n)+)", re.S)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_host(requested, system=None, machine=None):
    system = system or platform.system()
    machine = machine or platform.machine()
    if system != "Darwin":
        raise RuntimeError("Native codecs must be built on the authorized macOS runner, not this host")
    if requested not in ("arm64", "x86_64") or machine != requested:
        raise RuntimeError(f"Expected native {requested} runner, got {machine}")


def validate_pin(expected, observed):
    if not re.fullmatch(r"[0-9a-f]{40}", expected) or observed.strip() != expected:
        raise RuntimeError(f"Source pin mismatch: expected {expected}, got {observed!r}")


def inventory_licenses(source, destination):
    """Preserve all whole legal files, plus file-specific inline notice blocks.

    The source-wide inventory is intentionally over-inclusive (including notices
    for disabled components); no upstream license text is summarized/replaced.
    """
    destination.mkdir(parents=True, exist_ok=True)
    notices = []
    entries = []
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source)
        if ".git" in relative.parts or not path.is_file() or path.is_symlink():
            continue
        if LEGAL_NAME.match(path.name):
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)
            entries.append({"path": relative.as_posix(), "sha256_local": sha256(target)})
        elif path.suffix.lower() in (".c", ".cc", ".cpp", ".h", ".hpp", ".s", ".asm"):
            content = path.read_text(encoding="utf-8", errors="replace")
            for match in COMMENT.finditer(content):
                block = match.group(0)
                if re.search(r"copyright|redistribution|spdx-license|patent license", block, re.I):
                    notices.append(f"\nFile: {relative.as_posix()}\n{block}\n")
    if not entries:
        raise RuntimeError(f"No licenses found in {source.name}")
    inline = destination / "SOURCE_FILE_NOTICES.txt"
    inline.write_text("File-specific notices reproduced from the pinned source tree.\n" + "".join(notices), encoding="utf-8")
    entries.append({"path": inline.name, "sha256_local": sha256(inline)})
    return entries


def verify_aom_option_definitions(source, flags):
    """Reject unknown option names instead of accepting ignored CMake arguments."""
    files = [source / "CMakeLists.txt", *source.rglob("*.cmake")]
    definitions = "\n".join(path.read_text(encoding="utf-8") for path in files)
    for flag in flags:
        name = flag[2:].split("=", 1)[0]
        if name.startswith(("ENABLE_", "CONFIG_")):
            pattern = r"set_aom_(?:config|option)_var\(\s*" + re.escape(name) + r"\s"
            if not re.search(pattern, definitions):
                raise RuntimeError("Pinned libaom does not define required option " + name)


def verify_aom_cache(cache, flags):
    for flag in flags:
        name, expected = flag[2:].split("=", 1)
        match = re.search(r"^" + re.escape(name) + r":[^=\n]+=(.*)$", cache, re.M)
        if not match:
            raise RuntimeError("Missing configured libaom option " + name)
        accepted = {expected}
        if expected in ("OFF", "0"): accepted = {"OFF", "0", "FALSE"}
        if expected in ("ON", "1"): accepted = {"ON", "1", "TRUE"}
        if match.group(1) not in accepted:
            raise RuntimeError(f"Unexpected libaom option {name}: {match.group(1)}")


class Builder:
    def __init__(self, root, arch, jobs):
        self.root, self.arch, self.jobs = root, arch, jobs
        self.base = root / ".build/native-codecs"
        self.work = self.base / ("work-" + arch)
        self.stage = self.base / ("install-" + arch + ".staging")
        self.logs = self.base / "logs" / arch
        self.commands = []
        self.dependencies = {}
        self.environment = os.environ.copy()
        for key in ("CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS", "CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "LIBRARY_PATH", "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH", "PKG_CONFIG_PATH", "CMAKE_PREFIX_PATH", "SDKROOT"):
            self.environment.pop(key, None)
        self.environment.update(MACOSX_DEPLOYMENT_TARGET="14.0", LC_ALL="C", TZ="UTC", ZERO_AR_DATE="1", GIT_TERMINAL_PROMPT="0", GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null", PKG_CONFIG_LIBDIR=str(self.stage / "lib/pkgconfig"))
        self.number = 0

    def run(self, command, *, timeout=600, offline=True, capture=False):
        command = [str(arg) for arg in command]
        if offline:
            command = ["/usr/bin/sandbox-exec", "-p", "(version 1) (allow default) (deny network*)", *command]
        self.number += 1
        label = f"{self.number:03d}"
        log = self.logs / (label + ".log")
        report = self.logs / (label + ".json")
        self.commands.append({"argv": command, "timeout_seconds": timeout, "log": str(log.relative_to(self.base)), "report": str(report.relative_to(self.base))})
        wrapper = [sys.executable, str(self.root / "scripts/run-bounded-command.py"), "--timeout-seconds", str(timeout), "--max-log-bytes", str(8 * 1024 * 1024), "--log", str(log), "--report", str(report), "--", *command]
        subprocess.run(wrapper, check=True, env=self.environment)
        return log.read_text(encoding="utf-8").strip() if capture else None

    def prepare(self):
        self.logs.mkdir(parents=True, exist_ok=True)
        # No cached build or stale install is accepted as evidence of this run.
        final = self.base / "install"
        if final.exists():
            shutil.rmtree(final)
        for path in (self.work, self.stage):
            if path.exists():
                shutil.rmtree(path)
            path.mkdir(parents=True)
        (self.stage / "lib").mkdir()
        (self.stage / "include").mkdir()
        if not Path("/usr/bin/sandbox-exec").is_file():
            raise RuntimeError("Network-denying build sandbox is unavailable")
        translated = subprocess.run(["/usr/sbin/sysctl", "-in", "sysctl.proc_translated"], capture_output=True, text=True, check=False)
        if translated.stdout.strip() == "1":
            raise RuntimeError("Rosetta is not a native Intel build runner")
        self.cc = self.run(["xcrun", "--find", "clang"], capture=True)
        self.cxx = self.run(["xcrun", "--find", "clang++"], capture=True)
        self.sdk = self.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], capture=True)
        self.sdk_version = self.run(["xcrun", "--sdk", "macosx", "--show-sdk-version"], capture=True)
        self.compiler = self.run([self.cc, "--version"], capture=True)
        self.cmake_version = self.run(["cmake", "--version"], capture=True)

    def fetch(self, name):
        version, pin, url = PINS[name]
        source = self.work / "source" / name
        source.mkdir(parents=True)
        git = ["git", "-c", "core.hooksPath=/dev/null", "-C", str(source)]
        self.run([*git, "init", "--quiet"])
        self.run([*git, "-c", "http.lowSpeedLimit=1024", "-c", "http.lowSpeedTime=30", "fetch", "--depth=1", "--no-tags", url, pin], timeout=300, offline=False)
        observed = self.run([*git, "rev-parse", "FETCH_HEAD^{commit}"], capture=True)
        validate_pin(pin, observed)
        self.run([*git, "checkout", "--detach", "--quiet", pin])
        validate_pin(pin, self.run([*git, "rev-parse", "HEAD"], capture=True))
        self.run([*git, "fsck", "--no-reflogs"], timeout=180)
        archive = self.work / (name + "-source.tar")
        self.run([*git, "archive", "--format=tar", "--output=" + str(archive), pin])
        tree = self.run([*git, "rev-parse", "HEAD^{tree}"], capture=True)
        inventory = inventory_licenses(source, self.stage / "licenses" / name)
        required = ("COPYING", "PATENTS") if name == "libwebp" else ("LICENSE", "PATENTS") if name == "libaom" else ("LICENSE",)
        for filename in required:
            if not (source / filename).is_file():
                raise RuntimeError(f"Missing required {name}/{filename}")
        return source, {"version": version, "commit": pin, "git_tree": tree, "official_repository": url, "source_archive_sha256_local": sha256(archive), "hash_provenance": "Computed locally from git archive of the verified commit; not an upstream-published checksum", "notices": inventory}

    def common_flags(self):
        return ["-G", "Unix Makefiles", "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_SHARED_LIBS=OFF", "-DCMAKE_POSITION_INDEPENDENT_CODE=ON", "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON", f"-DCMAKE_C_COMPILER={self.cc}", f"-DCMAKE_CXX_COMPILER={self.cxx}", f"-DCMAKE_OSX_ARCHITECTURES={self.arch}", "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0", f"-DCMAKE_OSX_SYSROOT={self.sdk}", f"-DCMAKE_INSTALL_PREFIX={self.stage}", "-DCMAKE_INSTALL_LIBDIR=lib", "-DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF", "-DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF", "-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local", "-DFETCHCONTENT_FULLY_DISCONNECTED=ON", "-DFETCHCONTENT_UPDATES_DISCONNECTED=ON", "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"]

    def build(self, name, source, flags, targets):
        build = self.work / "build" / name
        self.run(["cmake", "-S", source, "-B", build, *self.common_flags(), *flags], timeout=300)
        self.run(["cmake", "--build", build, "--parallel", self.jobs, "--target", *targets], timeout=1800)
        proof = self.base / "evidence" / self.arch / name
        proof.mkdir(parents=True, exist_ok=True)
        for filename in ("CMakeCache.txt", "compile_commands.json"):
            shutil.copyfile(build / filename, proof / filename)
        return build

    def copy_archive(self, build, name):
        candidates = list(build.rglob(name))
        if len(candidates) != 1:
            raise RuntimeError(f"Expected one {name}, found {candidates}")
        architecture = self.run(["/usr/bin/lipo", "-archs", candidates[0]], capture=True)
        if architecture != self.arch:
            raise RuntimeError(f"Wrong archive architecture for {name}: {architecture}")
        shutil.copyfile(candidates[0], self.stage / "lib" / name)

    def build_all(self):
        self.prepare()
        sources, provenance = {}, {}
        for name in PINS:
            sources[name], provenance[name] = self.fetch(name)
            self.dependencies = dict(provenance)
            self.write_attempt("fetching")
        webp_flags = ["-DWEBP_LINK_STATIC=ON", "-DWEBP_USE_THREAD=ON"] + ["-DWEBP_BUILD_" + value + "=OFF" for value in ("ANIM_UTILS", "CWEBP", "DWEBP", "GIF2WEBP", "IMG2WEBP", "VWEBP", "WEBPINFO", "LIBWEBPMUX", "WEBPMUX", "EXTRAS", "WEBP_JS", "FUZZTEST")]
        webp = self.build("libwebp", sources["libwebp"], webp_flags, ["webp", "webpdemux", "sharpyuv"])
        for name in LIBRARIES[:3]:
            self.copy_archive(webp, name)
        include = self.stage / "include/webp"
        include.mkdir()
        for name in ("decode.h", "encode.h", "demux.h", "mux_types.h", "types.h"):
            shutil.copyfile(sources["libwebp"] / "src/webp" / name, include / name)
        # Generic C libaom avoids an unpinned assembler and architecture-specific
        # build-host instruction assumptions. Output is still native Mach-O.
        aom_flags = ["-DAOM_TARGET_CPU=generic", "-DENABLE_DOCS=OFF", "-DENABLE_APPS=OFF", "-DENABLE_EXAMPLES=OFF", "-DENABLE_TESTS=OFF", "-DENABLE_TOOLS=OFF", "-DENABLE_TESTDATA=OFF", "-DENABLE_NASM=OFF", "-DCONFIG_AV1_ENCODER=1", "-DCONFIG_AV1_DECODER=1", "-DCONFIG_MULTITHREAD=1", "-DCONFIG_PIC=1", "-DCONFIG_TUNE_VMAF=0", "-DCONFIG_TUNE_BUTTERAUGLI=0", "-DCONFIG_WEBM_IO=0", "-DCONFIG_LIBYUV=0", "-DCONFIG_HIGHWAY=0", "-DCONFIG_TFLITE=0"]
        verify_aom_option_definitions(sources["libaom"], aom_flags)
        aom = self.build("libaom", sources["libaom"], aom_flags, ["aom"])
        verify_aom_cache((aom / "CMakeCache.txt").read_text(), aom_flags)
        self.copy_archive(aom, "libaom.a")
        shutil.copytree(sources["libaom"] / "aom", self.stage / "include/aom", ignore=shutil.ignore_patterns("*.c", "*.cc"))
        # An explicit imported target binds libavif SYSTEM to this private pin.
        # Prefer CONFIG so no Homebrew/pkg-config fallback can win discovery.
        config = self.stage / "lib/cmake/aom"
        config.mkdir(parents=True)
        (config / "aomConfig.cmake").write_text(f'''add_library(aom STATIC IMPORTED)
set_target_properties(aom PROPERTIES IMPORTED_LOCATION "{self.stage}/lib/libaom.a" INTERFACE_INCLUDE_DIRECTORIES "{self.stage}/include" INTERFACE_LINK_LIBRARIES "m")
set(aom_FOUND TRUE)
set(AOM_VERSION "3.15.0")
''')
        avif_flags = ["-DAVIF_CODEC_AOM=SYSTEM", "-DAVIF_CODEC_AOM_ENCODE=ON", "-DAVIF_CODEC_AOM_DECODE=ON", "-DCMAKE_FIND_PACKAGE_PREFER_CONFIG=ON", f"-Daom_DIR={config}"] + ["-DAVIF_" + value + "=OFF" for value in ("CODEC_DAV1D", "CODEC_LIBGAV1", "CODEC_RAV1E", "CODEC_SVT", "CODEC_AVM", "LIBYUV", "LIBSHARPYUV", "ZLIBPNG", "JPEG", "LIBXML2", "GTEST", "FUZZTEST", "BUILD_APPS", "BUILD_TESTS", "BUILD_EXAMPLES", "ENABLE_WASM", "ENABLE_EXPERIMENTAL_MINI", "ENABLE_EXPERIMENTAL_EXTENDED_PIXI", "ENABLE_COMPLIANCE_WARDEN", "ENABLE_GOLDEN_TESTS")]
        avif = self.build("libavif", sources["libavif"], avif_flags, ["avif_static"])
        self.copy_archive(avif, "libavif.a")
        shutil.copytree(sources["libavif"] / "include/avif", self.stage / "include/avif")
        cache = (avif / "CMakeCache.txt").read_text()
        if f"aom_DIR:PATH={config}" not in cache and f"aom_DIR:UNINITIALIZED={config}" not in cache:
            raise RuntimeError("libavif did not record the pinned private aom config")
        if "AVIF_CODEC_AOM:STRING=SYSTEM" not in cache:
            raise RuntimeError("libavif AOM mode is not SYSTEM")
        self.selftest()
        for source in sources.values():
            self.run(["git", "-C", source, "diff", "--exit-code", "HEAD", "--"])
        manifest = {"schema_version": 1, "architecture": self.arch, "deployment_target": "14.0", "sdk_path": self.sdk, "sdk_version": self.sdk_version, "compiler": self.compiler, "cmake": self.cmake_version, "aom_cpu_implementation": "generic C, native Mach-O architecture", "dependencies": provenance, "libraries": [{"file": name, "sha256_local": sha256(self.stage / "lib" / name), "architecture": self.arch} for name in LIBRARIES], "commands": self.commands, "native_selftest": "passed", "hash_provenance": "All SHA-256 values computed locally; no upstream-published checksum claim"}
        (self.stage / "native-build.json").write_text(json.dumps(manifest, indent=2) + "\n")
        (self.stage / "licenses/README.txt").write_text("PicShot native codec source pins and complete license/notice inventory.\nSee ../native-build.json for versions, provenance, per-file hashes and compiler flags.\nEach directory preserves whole upstream legal files and inline file-specific notices.\nThe inventory intentionally includes notices for disabled optional source components.\nNo optional component listed in a notice is thereby claimed to be linked.\n")
        self.stage.rename(self.base / "install")
        print("Native codec build and C selftests passed: " + str(self.base / "install"))

    def write_attempt(self, status, error=None):
        self.base.mkdir(parents=True, exist_ok=True)
        report = {"schema_version": 1, "status": status, "architecture": self.arch,
                  "deployment_target": "14.0", "commands": self.commands,
                  "dependencies": self.dependencies, "error": error,
                  "compiler": getattr(self, "compiler", None),
                  "sdk_version": getattr(self, "sdk_version", None)}
        (self.base / ("build-attempt-" + self.arch + ".json")).write_text(json.dumps(report, indent=2) + "\n")

    def selftest(self):
        executable = self.work / "codec-selftest"
        bridge = self.root / "Sources/CPicShotCodecs"
        command = [self.cc, "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2", "-arch", self.arch, "-mmacosx-version-min=14.0", "-isysroot", self.sdk, "-I" + str(bridge / "include"), "-I" + str(self.stage / "include"), bridge / "CPicShotCodecs.c", bridge / "tests/CodecSelfTest.c", *[self.stage / "lib" / name for name in ("libwebpdemux.a", "libwebp.a", "libsharpyuv.a", "libavif.a", "libaom.a")], "-lm", "-lc++", "-o", executable]
        self.run(command, timeout=180)
        self.run([executable], timeout=180)
        dependencies = self.run(["/usr/bin/otool", "-L", executable], capture=True)
        for line in dependencies.splitlines()[1:]:
            library = line.strip().split(" ", 1)[0]
            if library and not library.startswith(("/usr/lib/", "/System/Library/")):
                raise RuntimeError("Unexpected runtime dependency: " + library)
        (self.stage / "native-selftest-dependencies.txt").write_text(dependencies + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=("arm64", "x86_64"), default=platform.machine())
    parser.add_argument("--jobs", type=int, default=min(4, os.cpu_count() or 1))
    args = parser.parse_args()
    if not 1 <= args.jobs <= 8:
        parser.error("--jobs must be 1..8")
    validate_host(args.arch)
    builder = Builder(Path(__file__).resolve().parents[1], args.arch, args.jobs)
    try:
        builder.build_all()
    except Exception as error:
        builder.write_attempt("failed", f"{type(error).__name__}: {error}")
        raise
    builder.write_attempt("passed")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print("Native codec build failed closed: " + str(error), file=sys.stderr)
        sys.exit(1)
