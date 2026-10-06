# Optional offline model engines

PicShot does not bundle recognition weights, download them at startup, or upload screenshots. A user must explicitly select **Download optional model** and confirm the source, size and license. Downloads use an ephemeral network session without cookies or credentials. Recognition only starts from a user action, works offline after installation, and runs in the bundled native `PicShotMLHelper` executable.

## Formula model

- Publisher: Breezedeus / Pix2Text
- Model: `breezedeus/pix2text-mfr-1.5`
- Immutable Hugging Face revision: `1cef9f0bdcd6a4c63df7de1311fb0894593340cc`
- [Pinned model card and files](https://huggingface.co/breezedeus/pix2text-mfr-1.5/tree/1cef9f0bdcd6a4c63df7de1311fb0894593340cc)
- License: MIT, as stated in the publisher's model-card metadata. This is an optional third-party model, not a PixPin model or asset
- Total download: **119,661,866 bytes** (about 120 MB / 114.1 MiB)
- Downloaded data: two ONNX graphs, tokenizer, model/preprocessing/generation configuration and original model card. No Python code, pickles, plug-ins or remote code execution

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| encoder_model.onnx | 87510770 | 080a3f660f08bc9ebcacdd96e34be6b6400f8c7e62d7cd0dd8251badc37f610b |
| decoder_model.onnx | 32026253 | 917deb98e91a0453c5f234f58a0f32f9fb037de8527c7eb4ed394daf9e692f2a |
| tokenizer.json | 113168 | 4ffbeb2143e6a38324bb6111b7a8109530d38a076a8439aa5777535f0a32758a |
| config.json | 1573 | fe4076f08f6ca75940f6af9268d51928b834979a69bc2145dacee62633a5d53d |
| preprocessor_config.json | 450 | 36a945a7cc645688b9ef64dabae16979cf5f7c1c448569cc306694edc0598b9b |
| generation_config.json | 211 | 7363c031c6142d35a276815b0e285cc289dfb9f51d0b7c63de8f3ed65cc8d8ad |
| README.md | 9441 | 7ae7136c49c64378ff09a86b750ef9c2007ad8e91e148be391e3480bfd9dce97 |

The downloader streams to private staging files with exact size limits and verifies SHA-256 before installing. Partial or failed downloads are removed. Each recognition re-verifies the fixed compiled manifest, including in the helper. The manifest is not downloaded or updated automatically. Redirects are limited to an exact allowlist of the provider's HTTPS delivery hosts, individually scoped to the asset.

Preprocessing: opaque sRGB on white, direct bicubic resize to 384×384, RGB channel order, `(pixel/255 - 0.5)/0.5`, NCHW `[1,3,384,384]`. No center crop or aspect-ratio padding. Bicubic byte rounding can differ by one from Pillow. Encoder output is `[1,578,384]`; autoregressive decoder has `input_ids` int64 and `encoder_hidden_states` float32, returning `[1,L,1868]` logits. Greedy decoding starts at BOS 1 and stops at EOS 2. The tokenizer is **ByteLevel BPE**, not SentencePiece; decoding restores UTF-8 bytes and removes special tokens. There is no KV cache, beam search or hard-coded recognition output.

## Table model

A separate optional SLANet-plus pack contains `slanet-plus.onnx`, 7,758,305 bytes, SHA-256 `d57a942af6a2f57d6a4a0372573c696a2379bf5857c45e2ac69993f3b334514b`.

The pinned source is [RapidAI/RapidTable v2.0.0 on ModelScope](https://www.modelscope.cn/models/RapidAI/RapidTable/resolve/v2.0.0/slanet-plus.onnx). The version URL is protected against changed bytes by the compiled SHA-256. The publisher identifies the model as Apache-2.0. See [table model implementation and attribution](TABLE_MODEL.md) for its independent verification and limitations. Table cell text is obtained locally with Apple Vision, then matched to the actual model's structure and cell geometry; it is not synthesized from OCR line ordering.

## Runtime, process and privacy boundary

- Official Microsoft ONNX Runtime SwiftPM **1.24.2**, commit `b7fb7f7dea8a2469e6335d95a61b8f36d0dc83b2`, MIT
- [Pinned source](https://github.com/microsoft/onnxruntime-swift-package-manager/tree/b7fb7f7dea8a2469e6335d95a61b8f36d0dc83b2)
- Microsoft's full MIT license is retained in [ONNX_RUNTIME_LICENSE.txt](ONNX_RUNTIME_LICENSE.txt); the version-matched [third-party notices](ONNX_RUNTIME_THIRD_PARTY_NOTICES.txt) are also included and must be bundled with redistributed installers
- Only the `onnxruntime` product is linked, only into `PicShotMLHelper`. No ONNX Runtime Extensions or framework loading in the menu-bar UI process
- Official binary distribution from the pinned package: `https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.24.2.zip`, SHA-256 `f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54`
- Helper located only at `PicShot.app/Contents/Helpers/PicShotMLHelper`; app and nested helper signatures are checked before launch. No PATH lookup, shell command or user-specified executable
- The helper is ad-hoc signed in development packages. A valid ad-hoc signature checks integrity, **not publisher identity or Apple notarization**
- A sanitized child environment excludes inherited injection variables, proxies, credentials and Python settings
- A unique 0700 directory holds a 0600 PNG input, bounded diagnostics and 0600 exclusive-created output; the app deletes the directory after process exit, including cancellation/failure. An abrupt OS/app crash can leave a private temporary directory for OS cleanup; this is not secure disk erasure
- Input: one image, max 8192 pixels per dimension, 16 million pixels, 32 MiB encoded bytes. Output: max 1 MiB JSON and 64 KiB formula text
- One model process at a time; two ONNX intra-op threads; 120-second wall time and CPU limits; parent polls RSS and stops jobs exceeding 1 GiB. A 100 ms polling bound may temporarily overshoot. Cancellation sends SIGTERM, then SIGKILL after one second if needed
- Missing, corrupt, incompatible, empty or truncated model output is an explicit error. No fake result or OCR-text-to-LaTeX fallback
- Recognition code has no network calls. The helper is not an App Sandbox security boundary; isolation and fixed verified model files reduce accidental resource/privacy risks but are not a claim of arbitrary-code sandboxing

## Verification boundary

Actual official formula weights were downloaded through the supported approved network route and matched both SHA-256 values. Linux CPU ONNX Runtime 1.24.2 reference inference recognized all three locally authored fixtures:

| Fixture | Expected meaning | Actual decoded output |
| --- | --- | --- |
| pythagorean.png | x²+y²=z² | `x ^ { 2 } + y ^ { 2 } = z ^ { 2 }` |
| energy.png | E=mc² | `E = m c ^ { 2 }` |
| fraction.png | (a+b)/c | `\frac { a + b } { c }` |

Fixtures live under `Tests/PicShotMLHelperTests/Fixtures` and were authored using Matplotlib mathtext. A Python reproduction of the Swift bicubic algorithm differed from Pillow by at most one byte per color channel and produced the same three LaTeX results. This checks genuine model feasibility and tensor/tokenizer contracts, **not macOS native runtime correctness or general recognition accuracy**. Native Swift tests include tokenizer, pinned manifest, checksum/symlink rejection, preprocessing, argument validation and actual-weight integration. The actual-weight test explicitly skips unless `PICSHOT_FORMULA_MODEL_DIR` points at the complete verified pack; it must run and pass on macOS before claiming the native formula feature is validated. It never downloads weights itself.

Run after provisioning the pinned files through an authorized route:

```sh
PICSHOT_FORMULA_MODEL_DIR=/absolute/path/to/pix2text-mfr-1.5-pack swift test --filter FormulaEngineTests
```

This is a single-formula recognizer. Complex handwriting, unusual typography, matrices and multi-line or mixed text pages can be wrong. LaTeX is displayed as editable text; it is not executed as TeX or automatically rendered with shell escape. Users should check every result. Model tests and a bounded helper do not establish full PixPin parity or a zero-memory-leak claim.
