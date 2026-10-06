# Optional offline table structure recognition

## Scope and status

`PicShotTableEngine` is separate from the structured table editor. It consumes a genuine SLANet-plus model output, decodes explicit HTML row/column spans, and matches locally recognized Apple Vision text to model cell geometry. It does not turn OCR rows or TSV into claimed model structure.

The model is an **optional download**, not bundled weights. A short-lived native `PicShotMLHelper` runs one recognition job and exits; Apple Vision text recognition and ONNX inference use the local crop. The only network operation is an explicit model-pack download. Screenshots are not transmitted.

Validation to date:

- The original RapidAI download was independently fetched and verified, 7,758,305 bytes, SHA-256 below
- ONNX Runtime 1.24.2 CPU reference inference on two authored fixtures passed: a 3 × 3 table (mean token confidence 0.9999926) and a 4 × 3 table with a three-column merged header (0.9999919)
- A NumPy transcription of the native bilinear/Float32 preprocessing differed from OpenCV by at most one byte (under 0.8% of resized samples) on both fixtures; both real-model token sequences were unchanged
- Full real output tensors and the authored input PNGs are included in `Tests/PicShotTableEngineTests/Fixtures`, allowing deterministic Swift decoder replay without weights or network
- A third authored fixture exposes a **known accuracy failure**: its ground truth is three rows and a two-row merged label, but this model predicts four rows and `rowspan="3"` at 0.997 confidence. The input and actual output are retained as `known-failure-rowspan-*`; the adapter rejects this sample because a predicted cell extends beyond the allowed crop bounds; its regression test expects `invalidCellGeometry`, not a successful table
- Native Swift compilation, Apple Vision text accuracy, and native helper inference must be verified by macOS CI. The reference inference alone is **not** proof that the native end-to-end feature passes

## Pinned model and provenance

- Upstream model: [PaddlePaddle SLANet_plus](https://huggingface.co/PaddlePaddle/SLANet_plus), published as Apache-2.0
- ONNX packaging/export: [RapidAI RapidTable](https://github.com/RapidAI/RapidTable)
- Primary model artifact: `https://www.modelscope.cn/models/RapidAI/RapidTable/resolve/v2.0.0/slanet-plus.onnx`
- Filename: `slanet-plus.onnx`
- Exact size: `7758305` bytes
- SHA-256: `d57a942af6a2f57d6a4a0372573c696a2379bf5857c45e2ac69993f3b334514b`
- Source revision: `22592283c1f9d7c5a014c96c4ecc57de0b3ebfce`
- [Pinned model manifest](https://github.com/RapidAI/RapidTable/blob/22592283c1f9d7c5a014c96c4ecc57de0b3ebfce/rapid_table/default_models.yaml)
- [Pinned preprocessing](https://github.com/RapidAI/RapidTable/blob/22592283c1f9d7c5a014c96c4ecc57de0b3ebfce/rapid_table/table_structure/pp_structure/pre_process.py)
- [Pinned postprocessing](https://github.com/RapidAI/RapidTable/blob/22592283c1f9d7c5a014c96c4ecc57de0b3ebfce/rapid_table/table_structure/pp_structure/post_process.py)
- [Pinned span placement and OCR matching](https://github.com/RapidAI/RapidTable/blob/22592283c1f9d7c5a014c96c4ecc57de0b3ebfce/rapid_table/table_matcher/main.py)

The versioned download URL is additionally content-pinned by its mandatory SHA-256. A changed artifact must be rejected even if the server reuses the same filename/version. The upstream README's approximate 6.8 MB label differs from the verified byte size; use the exact size for model-pack verification and UI.

Research download status: an initial restricted original-source request returned a tunnel 403. A public mirror with the same published digest was fetched for static metadata inspection, then excluded from execution when the access question was raised. The original ModelScope URL was subsequently retried through the supported explicit approval mechanism and succeeded with the expected hash. Both recorded inference fixtures were produced only from this separately retrieved, approved original-source file. A later approved HEAD returned HTTP 200, the same final URL, and the expected `X-Linked-Etag`; no redirect was observed. The application manifest uses the primary URL, not the mirror.

## Tensor contract (inspected from the pinned ONNX)

ONNX IR version 7, default opset 14. All three tensors are float32.

| Role | Name | Shape |
| --- | --- | --- |
| Input | `x` | Dynamic `[N,3,H,W]`; this adapter uses `[1,3,488,488]` |
| Cell quadrilaterals | `save_infer_model/scale_0.tmp_0` | `[1,S,8]` |
| Structure probabilities | `save_infer_model/scale_1.tmp_0` | `[1,S,50]` |

The model includes its autoregressive loop. No external decoder or tokenizer model is required. The second output is already normalized probabilities; the adapter verifies this and does not apply another softmax. Observed sequence lengths were 17 and 23, including special tokens. The decoder requires EOS and refuses truncated output.

The model's `character` metadata contains exactly 48 newline-separated strings. Add `sos` at index 0 and `eos` at 49. Exact resulting vocabulary:

- 1–9: `<thead>`, `</thead>`, `<tbody>`, `</tbody>`, `<tr>`, `</tr>`, `<td`, `>`, `</td>`
- 10–28: ` colspan="2"` through ` colspan="20"`, inclusive; leading space is significant
- 29–47: ` rowspan="2"` through ` rowspan="20"`, inclusive
- 48: `<td></td>`

There is no CTC duplicate collapse. A box is associated with its exact timestep's `<td` or `<td></td>` token; zero/invalid geometry is rejected instead of filtering boxes and shifting subsequent cell assignments.

## Native preprocessing and geometry

1. Rasterize the upright crop in sRGB, composite alpha over white, produce interleaved BGR bytes
2. Preserve aspect ratio and resize the longest side to 488; shorter dimensions are truncated, as upstream does
3. Half-pixel bilinear sampling; round resized byte values, normalize each BGR position with mean `[0.485,0.456,0.406]` and standard deviation `[0.229,0.224,0.225]` after dividing by 255
4. Pad the bottom/right with **normalized zeros**, not normalized black/white pixels
5. Transpose to NCHW

The native bilinear byte rounding can differ from OpenCV's fixed-point implementation by one byte. Geometry, channel order, normalization and padding match the published pipeline. This small sampling difference must remain covered by native real-weight fixtures; do not claim bitwise OpenCV equivalence.

SLANet-plus box decoding scales both axes by the **original crop's longest side**. This is the simplified equivalent of upstream width/height scaling followed by its padding-ratio correction. Scaling Y only by image height on a wide crop is incorrect. Quadrilateral envelopes are used for OCR overlap, consistent with RapidTable's matcher. Strongly rotated/deformed tables are outside the validated scope.

## Failure and uncertainty behavior

- Shape mismatches, nonfinite values, missing EOS, unknown/ill-formed tokens, repeated span attributes, overlapping cells, incomplete rectangular grids and spans extending beyond the final row fail explicitly
- Every result carries a structural-review warning: high confidence does not prove the rows or merges are correct
- Mean structure confidence below 0.60 fails; weaker accepted structures/cells carry a review warning
- Apple Vision uses accurate local OCR; word boxes use top-left pixel coordinates and are matched by IoU, then corner distance
- At least half of an OCR box must lie within a candidate cell; near ties, low-confidence OCR, and non-overlapping text are retained in `unmatchedOCR`
- Multiline text is ordered top-to-bottom and left-to-right, retaining line breaks; input text remains `TableCellValue.text`, including leading `=` characters
- Empty cells remain empty. No text, numbers, formulas, spans, or missing rows are guessed
- A structure without matched text can be returned with an explicit warning, so the editor can preserve a genuine empty table rather than invent content
- The editor must show warnings and the full unmatched text for review, rather than quietly discarding it

## Tests and native CI

Package targets:

```swift
.target(name: "PicShotTableEngine", dependencies: ["PicShotCore"]),
.testTarget(name: "PicShotTableEngineTests", dependencies: ["PicShotTableEngine"], resources: [.process("Fixtures")])
```

`SLANetPlusTests` covers BGR normalization, normalized-zero padding, tensor validation, EOS, explicit spans, occupied-slot placement, geometry, OCR ambiguity, text ordering and lossless Codable transport. `RecordedModelOutputTests` replays the genuine model outputs, asserting 3 × 3 structure and a three-column merged header. `AppleImagePreprocessingTests` checks image orientation/channel order on macOS.

For native end-to-end validation, download and hash-verify the optional model using the approved original source, build `PicShotMLHelper`, then set:

```sh
PICSHOT_TEST_ML_HELPER=/absolute/path/to/PicShotMLHelper \
PICSHOT_TEST_TABLE_MODEL_DIR=/absolute/path/to/model-directory \
swift test --filter RecordedModelOutputTests/testNativeHelperWithRealWeightsWhenConfigured
```

The test launches the native helper on the merged-table PNG, expects the actual rowspan/colspan-capable table result, and checks OCR for `Fruit`, `Apples`, and `12`. Missing paths cause an explicit skip, not a pass. Python/NumPy/OpenCV were used only to generate reference evidence; they are not application dependencies.

## Attribution and license

The port changes the Python/Numpy/OpenCV implementation into Swift and adds strict validation and uncertainty reporting. Original code notices are retained in the Swift source. RapidTable preprocessing/postprocessing author: SWHL (`liekkaskono@163.com`). Span placement/matching includes original PaddlePaddle copyright (2022); model preprocessing includes PaddlePaddle copyright (2020). RapidTable's pinned tree contains `LICENSE` and no `NOTICE` file.

Distributors must include the Apache-2.0 license and these notices with the application/model pack. ONNX Runtime has its own MIT license and notices; its packaging is separate. Apple Vision is an OS framework. The authored fixture PNGs and recorded outputs were created for PicShot from synthetic text, with no user screenshot data.

### Apache License, Version 2.0

```text
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright 2025 RapidAI

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.

```
