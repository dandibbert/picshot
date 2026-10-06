# Optional offline smart erase: implementation and validation gate

Status: **real macOS ARM64 Core ML inference passed; optional smart erase is enabled**. The owner explicitly approved the selected author’s Google Drive large-file warning on 2026-10-06, and all three model files are pinned to the verified bytes below. Native evidence: commit `104e42e`, GitHub Actions run `37426021201`, ARM64 job `112145744179`. The fixture improved masked reconstruction MAE from `98.8802269` to `1.5883125`, changed `12,302` masked pixels, and passed exact unchanged-outside-mask and alpha assertions. That run passed 180 regular tests and 12 real-model tests, and packaged signed helpers. Intel real-model validation was still running when this record was written; do not treat the ARM64 result as an Intel pass. There is no replacement fill, blur, hosted inference, or Python runtime.

## Source and license verification (2026-10-06)

- Original research/code: [advimman/lama](https://github.com/advimman/lama), Apache-2.0, copyright 2021 Samsung Research. Full license: `SmartErase_LaMa_LICENSE.txt`
- Conversion project: [mallman/CoreMLaMa](https://github.com/mallman/CoreMLaMa), commit `55550555a01a235357cac3f066f31dce21f22264`, Apache-2.0, copyright 2023 Michael S. Allman. Full license: `SmartErase_CoreMLaMa_LICENSE.txt`
- The original converter obtains Big LaMa through IOPaint. [IOPaint's own source](https://github.com/Sanster/IOPaint/blob/main/iopaint/model/lama.py) pins MD5 `e3aa4aaa15225a33ec84f9f4bc47e500` for [the author-published TorchScript release](https://github.com/Sanster/models/releases/download/add_big_lama/big-lama.pt). The downloaded file matched it; measured SHA-256 was `344c77bbcb158f17dd143070d1e789f38a66c04202311ae3a258ef66667a9ea9`. This research-only file is not bundled or executed by the app
- Selected preconverted distribution: the Google Drive [LaMa.mlpackage folder](https://drive.google.com/drive/folders/1s_uICJQykFFxgVubpBNeLLDL0JsxgdCd) linked by its converter/distributor in [john-rocky/CoreML-Models](https://github.com/john-rocky/CoreML-Models#lama). The distributor identifies Apache-2.0, original LaMa and CoreMLaMa. Model metadata identifies `https://github.com/advimman/lama` as author, `Apache2.0 License`, and `john-rocky/CoreML-Models` as converter
- The original project lists CoreMLaMa as a non-official third-party conversion. PicShot must label the optional pack as this conversion rather than implying Samsung or Apple distributes PicShot

### Verified selected graph contract

The exact protobuf was parsed locally with Apple's `coremltools` 8.3.0, not inferred from a model card:

- Core ML specification 6, ML Program `CoreML5`
- Input `image`: RGB image, 800×800; input `mask`: grayscale image, 800×800
- Output `output`: RGB image, 800×800
- Float-valued graph outputs are FP32 (4,545 FLOAT32 entries, zero FLOAT16 entries). Other values are integer, Boolean and string constants
- Normalization and output scaling follow CoreMLaMa: image / 255, mask > 0, output clamped to 0...255
- Runtime configuration: CPU + GPU, matching the conversion author's macOS recommendation; no Neural Engine / FP16 claim

Verified flat files:

| Local pack filename | Bytes | SHA-256 | Author's Drive file ID |
| --- | ---: | --- | --- |
| Manifest.json | 617 | c814fff3cedf827c044094545ef80b0280b6cb8dd0e5c0bcf69fd31921191e58 | 1-40HIeUCpHanmU_RDAylmMfBqylcdHlV |
| model.mlmodel | 1,101,809 | 06a100ef99e0fd16326a3a8c4a687d13f7b26f544ea906a75338932d8554f953 | 1-QSt2xEbpoRJCO8wSS40Epk00PNis3an |
| weight.bin | 215,544,960 | d0541f6044a94cd4982bfdac074fc1ccfe11d8f1f590c299d6b5071b501fc184 | 1-SAHMkDJLY3eHQYhtu80S2elcy6i_tVH |

Total pack: 216,647,386 bytes. The approved download returns application/octet-stream. The fixed `drive.usercontent.google.com/download?id=…&export=download&confirm=t` endpoint was verified separately; all three asset SHA-256 values are pinned. All 893 graph references name the expected weight file with offsets inside its byte length. The app’s opt-in download alert explicitly explains Google’s large-file scanning limitation. Never send image data to a download endpoint.

### Rejected alternative

The independently authored `Jia-Liu/big-lama-coreml` archive at revision `5bc9fc233547beca7ca4307be4bbca5e04e57e66` was inspected before selection. Despite its model card describing FP32 image features, its graph has float32 MLMultiArray features and predominantly float16 operations. It is not compatible with the selected contract, not configured in PicShot and not a fallback for the warning-gated selected file.

## Runtime and UX

- The editor paints capsules in original image coordinates, with 2...256 px brush diameter, undo per stroke, clear, original/result toggle and a single apply callback. Editing the mask invalidates the previous result
- Mask painting retains vector strokes rather than full-resolution undo snapshots. Bounds: 512 strokes / 32,768 sampled points
- A context square encloses the mask, normally at least 512 source pixels, plus 64 px context on each side where possible. Rectangular image edges are replicated, not stretched. Model masks are max-pooled so thin strokes survive downsampling, and include every marked bilinear input tap plus replicated edge padding to prevent marked content leaking into context
- The model predicts real content in the marked region. Only marked RGB bytes are composited back. Original alpha and every unmarked canonical sRGB RGBA byte are retained. Large selections lose detail at 800×800; the UI tells the user to inspect before applying
- Smart erase is not confidential-data redaction. The UI directs users to opaque redaction for secrets
- The optional download uses the shared `ModelPackService`: explicit user action, fixed per-file sizes and SHA-256, host-restricted HTTPS redirects, private staging, bounded streaming and cancellation. No startup download and no model loaded in the menu bar process
- Files are copied into three fixed paths in a private `.mlpackage`, then reverified. No archive extraction, arbitrary model selection, downloaded executable code, dynamic Python or shell command
- `PicShotEraseHelper` is a separate signed bundle-relative executable. The parent checks the outer bundle and nested helper signature plus symlink-free exact paths before launch. It passes exact arguments and a minimal environment, runs one erase job globally, and never invokes a shell
- Parent bounds: 16 MP, 8,192 px per side, 80 MB image files, 150 s wall time and 2 GiB measured process RSS. These are not a guarantee of total GPU/system memory usage. Helper additionally has CPU/file rlimits
- Cancellation/Close sends SIGTERM and escalates to SIGKILL after one second if necessary. The parent waits for exit before deleting its private 0700 job directory / 0600 files. Core ML's temporary compiled package is removed on ordinary completion; process temp artifacts live under the same private job directory. The helper exits after one job. Its own 250 ms watchdog checks parent liveness and wall time and exits if either fails. It deliberately retains the job marker rather than deleting concurrently with Core ML writers. If the app crashes, private job files can remain until a later erase job triggers the constrained sweep. That sweep removes only hour-old, marked, owner-matching 0700 jobs whose parent and helper PIDs are both dead; unmarked paths and symlinks are never swept. Normal parent cleanup runs after the helper exits and can recover its own just-created job even if the marker is damaged

## Integration contract (owner edits)

Add targets:

```swift
.target(name: "PicShotEraseCore", dependencies: ["PicShotFormulaCore"]),
.executableTarget(name: "PicShotEraseHelper", dependencies: ["PicShotEraseCore"]),
.testTarget(name: "PicShotEraseCoreTests", dependencies: ["PicShotEraseCore"]),
.testTarget(name: "PicShotEraseHelperTests", dependencies: ["PicShotEraseHelper", "PicShotEraseCore"])
```

Add `PicShotEraseCore` to `PicShot` dependencies. If shipping an earlier milestone, do not stage the erasure files, or exclude `SmartEraseController.swift` until this target is added.

- UI API: `SmartEraseController(image: sourceCGImage, onApply: { updatedCGImage in ... })`. Retain the controller while open; apply through the editor's normal undoable image replacement path
- Build/package `PicShotEraseHelper` at `PicShot.app/Contents/Helpers/PicShotEraseHelper`. Sign it with identifier `local.picshot.erase-helper` before signing the outer app and verify the complete bundle. Do not grant extra entitlements
- Copy the two Apache license files and this source notice into the app's licenses/resources directory. No model files or Python dependencies need to be bundled
- The approved candidate is fully hash-pinned. `nativeValidationComplete = true` records the ARM64 native fixture result above. Any replacement model or materially changed preprocessing must pass that real-model gate again before enablement

## Tests and exact completion gate

Sources include unit tests for stroke rasterization, quick drag gaps, size/coordinate bounds, empty/full masks, thin-mask downsampling, non-square edge masks, alpha/orientation, exact outside-mask composition, pixel-buffer orientation, bilinear/replicated-padding mask support, strict helper arguments, private-job ownership and constrained stale cleanup.

Provision the fixed approved source with `python3 scripts/SmartErase-fetch-fixture.py` (developer/CI only, not bundled in the app). It fails on any access denial, unexpected redirect or hash mismatch with no alternate source.

The genuine-inference test is `SmartEraseEngineTests.testRealCoreMLRemovesMarkedObjectAndPreservesOutsidePixels`. Set `PICSHOT_ERASE_MODEL_DIR` to a directory containing the three approved and hash-pinned flat assets. The test creates a deterministic owned image with a textured gradient and a red central object, runs the actual Core ML model, and checks:

1. Same dimensions; every unpainted RGBA byte and all alpha values unchanged
2. At least 10,000 masked pixels changed; at least six distinct reconstructed red-channel values (rejects an unchanged image or flat fill)
3. Masked reconstruction error against the known clean texture improves by at least 50%
4. Wall time is below the helper's 150-second bound

No exact generated pixels are assumed across GPU hardware. Without the environment variable it is explicitly **skipped**, not passed. The test uses the fully pinned candidate independently of the user-facing enablement flag, so future candidates can be tested while gated. CI needs a hard job timeout and must retain the native fixture result. Successful portable/unit checks alone are not evidence that smart erase works.

Also exercise the packaged helper, not only the engine: paint/undo/clear, repeat runs, Cancel while loading, window Close during prediction, timeout recovery, invalid signature, corrupt/missing model, non-square image and large-region warning. Confirm no running helper remains and no job directory remains after terminal outcomes. Measure parent RSS before and after repeated jobs; do not call this “zero leaks.”

### Verification performed in this environment

Passed locally: primary source/Apache license review; official TorchScript byte integrity; approved original Core ML graph, manifest and weight downloads; exact byte hashes and protobuf contract inspection; all 893 weight-reference offsets; source-level security/contract review.

Passed on native macOS ARM64 CI: Swift compilation, the real Core ML fixture and exact outside-mask/alpha checks described above. Commit `104e42e`, run `37426021201`, job `112145744179`: 180 regular tests and 12 real-model tests passed; helper packaging/signing passed. The local Linux workspace itself did not execute Swift/Core ML.

Remaining at this checkpoint: Intel real-model result; packaged UI/process cancellation, application-Quit and repeated-run memory evidence. Do not claim zero leaks or completed full PixPin parity from the inference fixture alone.
