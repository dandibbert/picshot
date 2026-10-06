# PicShot 0.8 native WebP and AVIF codecs

## Dependency boundary

The bridge is original C source. Swift imports only `CPicShotCodecs.h`; upstream structs and their layouts remain private in `CPicShotCodecs.c`. The helper links static source-built libraries. There is no Homebrew runtime dependency, downloaded codec executable, model weight, browser implementation, or ImageIO fallback for these writers.

| Dependency | Exact approved version | Immutable Git commit | Official fetch origin |
| --- | --- | --- | --- |
| libwebp | 1.6.0 | `4fa21912338357f89e4fd51cf2368325b59e9bd9` | https://github.com/webmproject/libwebp.git |
| libavif | 1.4.2 | `c5240fc79fe5c2407e10afd35f5505ef6333ea49` | https://github.com/AOMediaCodec/libavif.git |
| libaom | 3.15.0 | `de4c1d1edc49723a78954d30a83690aa1937422f` | https://aomedia.googlesource.com/aom |

libavif's own `LOCAL` recipe selects a different libaom release. This build deliberately uses `AVIF_CODEC_AOM=SYSTEM` with a generated private imported target bound to the source-built 3.15.0 archive. Config-package preference, explicit `aom_DIR`, cache checks, and ignored Homebrew prefixes prevent accidental substitution. Other AV1 backends, libyuv, libavif sharpyuv, JPEG/PNG/XML, tools, examples, tests, fuzzers and experimental features are disabled. WebP keeps only `libwebp.a`, `libsharpyuv.a` and `libwebpdemux.a`. It does not build/link the separate duplicate decoder archive or the mux/animation encoder archive.

libaom explicitly disables its applications, libyuv, Highway, TensorFlow Lite, VMAF, Butteraugli and WebM I/O. The build checks that every requested ENABLE/CONFIG option is actually declared by the pinned source and then verifies effective cache values; an ignored or overridden option is a failure. libaom uses its generic C implementation, compiled into the runner's native Mach-O architecture. This avoids an extra assembler dependency and host-specific SIMD assumptions; it is a performance tradeoff to measure with installed workloads, not a claim of maximum throughput. WebP retains its upstream runtime-dispatched SIMD support. No unverified prebuilt binary is accepted.

## Build, hashes, and notices

On an authorized native macOS runner with Xcode, Python 3 and CMake already available:

```sh
python3 scripts/build-native-codecs.py --arch arm64 --jobs 4
# On a separate native Intel runner:
python3 scripts/build-native-codecs.py --arch x86_64 --jobs 4
```

The deployment target is macOS 14.0 for each architecture. A non-Darwin host, mismatched native architecture or Rosetta process is rejected. Each build starts from a fresh private work tree. No cross-architecture merge or reuse of an existing install is performed.

Only the three explicit source fetches may access the network. Each fetch is bounded to 300 seconds and fetches precisely the approved commit with depth 1 and no tags/submodules. Both `FETCH_HEAD` and checked-out `HEAD` are verified, then `git fsck` runs. All configure/build/selftest commands run under a macOS sandbox denying network access; CMake FetchContent is also fully disconnected. CMake cannot silently sub-fetch an optional dependency. Configure stages have five-minute deadlines, library builds thirty minutes each, and the C selftest three minutes. The outer CI job must also impose its own overall deadline. Processes and descendants are managed by `run-bounded-command.py`, with eight-MiB per-command logs. An actual sandbox error is a failed build, not permission to retry without the sandbox.

Only a completed native selftest publishes `.build/native-codecs/install`:

- `include/`: private upstream headers required to compile the original bridge
- `lib/`: exactly the five static libraries in the table/description above
- `licenses/<dependency>/`: complete verbatim upstream legal files, recursively including nested third-party `LICENSE`, `COPYING`, `PATENTS`, `NOTICE`, `AUTHORS` and `COPYRIGHT` variants
- `licenses/<dependency>/SOURCE_FILE_NOTICES.txt`: original file-specific copyright/license comment blocks from the pinned source tree, with source-path labels; intentionally over-inclusive
- `native-build.json`: exact source commits/tree IDs, locally computed source-tar SHA-256 values, full license inventory/hashes, SDK/compiler versions, architecture, deployment target, all command-line flags, static archive SHA-256 values and successful native selftest status
- `native-selftest-dependencies.txt`: actual `otool -L` output; any non-system runtime dependency fails the build

Hash fields are explicitly named `sha256_local` or `source_archive_sha256_local`. They are local observations, not upstream-published checksums or signatures. Pinned source/configuration and recorded toolchains make the process reproducible; byte-identical archives across different SDK/compiler releases are not promised.

CMake caches and compile-command databases are retained under `.build/native-codecs/evidence/<architecture>/`. Command logs/reports are under `.build/native-codecs/logs/<architecture>/`. `build-attempt-<architecture>.json` retains partial provenance and failure details even when no completed install is published. Sources and locally hashed tar files remain under `.build/native-codecs/work-<architecture>/`; they are build artifacts, not committed dependencies. No static codec binary or model weight belongs in the source repository.

The app packager must copy the whole `install/licenses` tree and `native-build.json` into the app's resources. Do not replace complete notices with this document or an SPDX label. Primary license material is obtained directly from the exact approved source checkout at build time, not transcribed from search snippets. The inventory includes notices for disabled optional components to avoid losing file-specific terms; their presence does not establish that such a component is linked. libwebp carries its BSD-3-Clause COPYING and PATENTS grant; libavif includes its complete BSD-2-Clause and file-specific LICENSE text; libaom includes its complete LICENSE, PATENTS and nested notices. This records provenance and distribution notices, not a security certification or legal opinion.

## Original C ABI

`PSCodecDefaultOptions(format)` initializes ABI version 1. `PSCodecEncodeRGBA` takes a separately counted input buffer, dimensions, stride, options, a counted writer callback, optional progress callback and caller context. Every callback runs synchronously on the calling thread. Input and context stay caller-owned. Callback bytes are borrowed for the duration of that callback.

Input is top-to-bottom, positive-stride, straight/unpremultiplied RGBA8 in sRGB. A caller supplying premultiplied pixels must unpremultiply/convert before invoking this ABI. The bridge accepts no source metadata, ICC blob, source URL, editor layers or orientation. Width and height must each be 1–16,383 with at most 100,000,000 pixels. Stride must cover the row and fit signed 32-bit upstream APIs; the counted input must cover the last actual pixel, with overflow-safe arithmetic.

Options:

- WebP: real libwebp lossy/lossless encoding, quality 0–100, effort 0–6, optional alpha, alpha quality 0–100. Lossless uses `exact=1` and lossless alpha to preserve even RGB values beneath zero alpha
- AVIF: real libavif/libaom 8-bit encoding; lossless uses full-range 4:4:4 and identity color matrix at lossless color/alpha quality. Lossy uses full-range 4:4:4 with BT.709 matrix, sRGB transfer and quality 0–100. Effort 0–6 maps to libaom speed 10–4
- `preserveAlpha=0` discards alpha without compositing. A white/background flatten must happen upstream if desired
- `maxThreads` is 1–4. libavif receives that limit; WebP enables its own bounded threading when greater than 1
- Encoded byte cap is positive and at most 128 MiB, checked before each write. The cumulative byte count includes the proposed write. Callback failure aborts the encode

Progress is monotonic and cancellation-aware at callback boundaries. WebP exposes codec progress plus incremental writer calls. AVIF performs a synchronous native encode and internally allocates its completed encoded buffer; the wrapper then caps the result and forwards it in 64-KiB writes. It is incorrect to describe AVIF as streaming or bounded to one output chunk in memory. Codec scratch buffers are additional to input/output caps. Cancellation cannot preempt that synchronous AVIF call; the signed process helper must provide its own deadline and termination boundary.

Return 0 is success. All negative codes are errors; partial output must be discarded for every nonzero encode return, even if a final cancellation happened after the last byte callback. The error object is caller-owned with a fixed 256-byte message, accessible through `PSCodecErrorMessage`. No exception crosses the C ABI. Version getters return borrowed static strings.

## Bounded independent verification

`PSCodecDecodeRGBA` creates an opaque, owned decoded result. It rejects animated WebP and AVIF, caps compressed input at 128 MiB, checks explicit pixel/decoded-byte limits before allocating RGBA, and keeps codec structs private. Getters expose immutable tightly packed straight-RGBA bytes and dimensions until `PSCodecDecodedFree`. It is intended for independent encoded-output/fixture checks; decoding still involves native scratch allocations. AVIF container-versus-decoded dimensions are rechecked before RGB conversion.

`PSCodecWebPAnimationOpen` independently demuxes the complete container, checks every frame's bounds/completeness/timing, rejects too many frames or an oversized canvas, and copies the bounded encoded input. `PSCodecAnimationNext` uses libwebp's independent animation decoder to return every fully composited canvas, including transparent replacements. It returns exact per-frame integer milliseconds and has an explicit end status. It never substitutes the first frame for an animation. Zero-duration frames are preserved by this verification API even if the product's animation writer enforces a stricter positive-duration policy. Total timeline is limited to signed 32-bit milliseconds to match the upstream decoder. Frame count is at most 10,000; explicit caller caps may be smaller.

The returned animation frame pointer is borrowed until the next `Next` or `Free`. The decoder owns additional compositing buffers; the caller's decoded-byte cap is per canvas and does not describe a total native memory ceiling. The API does not retain decoded copies of all frames.

## Verification status and commands

Portable checks:

```sh
python3 -m unittest discover -s scripts/tests -p test_build_native_codecs.py -v
python3 -m py_compile scripts/build-native-codecs.py
```

These test approved pins, wrong-host/architecture rejection, pin mismatch rejection, complete nested legal-file preservation, and forbidden duplicate/sub-fetch choices. They neither fetch sources nor establish that a Mac binary links or runs.

The native build compiles `Sources/CPicShotCodecs/tests/CodecSelfTest.c` with warnings as errors against the actual five archives, then runs it. It checks runtime dependency versions; actual WebP/AVIF container magic; full lossless RGBA equality including alpha-zero RGB; opaque output; actual lossy-quality changes; alpha preservation; invalid/truncated decode; dimensions/stride/output caps; callback abort/cancellation; and independently demuxed, fully decoded three-frame 7×5 animation with exact 17/101/0-ms timing. This source is excluded from the SwiftPM C target. A passing native selftest does not replace signed helper, process-lifecycle, app UI, resource or installed-package tests.

Initial implementation was prepared in a Linux source workspace without downloading or compiling the codec sources there. Native ARM/Intel CI results are required before marking either architecture verified. The first diagnostic runs should retain logs, complete provenance/notices, source hashes, archive hashes and selftest output before proceeding to app packaging.

## Verified dependency-only checkpoint

Commit `51260f2d4122fc9cdba1ad5bdc6f6a6c21677d8b` passed native ARM64 and Intel dependency jobs in [run 37521945118](https://github.com/dandibbert/picshot/actions/runs/37521945118): [ARM job 112469309050](https://github.com/dandibbert/picshot/actions/runs/37521945118/job/112469309050), [Intel job 112469309394](https://github.com/dandibbert/picshot/actions/runs/37521945118/job/112469309394). Both report genuine C encode/decode, complete animation verification and exact lossless RGBA selftests with WebP 1.6.0, AVIF 1.4.2 and AOM v3.15.0. The native toolchain was Xcode 16.4 / Apple Clang 17 / SDK 15.5; minimum deployment remains macOS 14. This does not establish actual macOS 14 runtime acceptance, whole-app helper integration, UI, cancellation or installed-resource acceptance.

Both independently built architectures produced the same source-archive SHA-256 values:

| Source | Locally computed Git-archive SHA-256 |
| --- | --- |
| libwebp | `00b71e1030146195239922bb241895d22c4f7f2d2b173c083000a448479ff5b3` |
| libaom | `e5499eb8d5ff6e1886ab4103c29271f9bcc3d4c8903245ccea2fd96c28b2976f` |
| libavif | `2c84afde7ea25afbf3ed9981d65a87723920137e1033f5e4fb48c76c4566ede1` |

These are locally computed hashes of exact verified Git objects, not upstream-published checksums. Each architecture's 20 complete legal/notice files match its manifest hashes. Actual selftest dynamic linkage includes system libraries only. AOM's critical option-definition/effective-cache checks passed. Upstream CMake reported only inapplicable `AVIF_ENABLE_WASM`, C++ compiler settings for C-only targets, and no-active-FetchContent hints as unused; this is not a claim that every supplied optional setting controls linked code. AOM uses generic C in native Mach-O files, not Rosetta; AVIF performance remains to be measured in the installed app.
