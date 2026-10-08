# Build 117 component observations and remaining hold

Source [430960b89813c7965d133364d28bbda0e093a3bf](https://github.com/dandibbert/picshot/commit/430960b89813c7965d133364d28bbda0e093a3bf), [run 37803873167](https://github.com/dandibbert/picshot/actions/runs/37803873167), is **not a completed component matrix or accepted 0.16 package**. The two focused native lanes each pass 282/282 with no skips; the ARM installed output guard passes 24 cases / 432 rejected attempts. These overlapping stages are not additive coverage totals. Accepted deliveries remain ARM 0.15.1/build 111 and Intel 0.11/build 69.

## Actual source-bound control work

The ARM app-only diagnostic runs on macOS 15.7.9 (24G830). All seven processes use executable SHA-256 `c3e8c1691c8850f6e729811d915969d412db2285912b362a49067265f3d5781f`, 20,568,624 bytes. Signing and relocation are checked in CI. The artifact retains reports and source/binary identity, not the signed executable itself; independent offline replay therefore uses archived identity and does not revalidate the absent binary or its signing seal.

Preparation and a fresh certification process bind the full-size original/base (3840×2160), current (2414×1574), immutable PNG/raw bytes, metadata, and editable document to the prior build 113 complete RGBA goldens. Four certification comparisons, including controller replay, cover 96,752,288 bytes exactly. Native PNG metadata contains only the audited sRGB/dimensions EXIF structure. No fixture pixels, tolerances or references changed to pass.

Three consumers complete two warmups and eight measured cycles each, with exact pixels, all required counters, explicit buffer callbacks, removed cycle directories and no owned descriptors/jobs/reservations at the reported endpoints:

- `raw-draw`: three owned full-size inputs and three actual validation draws per cycle
- `png-write`: the same inputs/draws plus three production PNG writes per cycle; outputs are not decoded or hashed in this process
- `png-decode-draw`: three full-size ImageIO decodes from retained PNG Data, then three actual validation draws per cycle

A later fresh process independently decodes and compares all 30 written PNGs, 5,761,650 encoded bytes in total. Writer evidence files intentionally remain in the artifact. The complete PNG/raw/document input bundle is 82,141,127 bytes. Equal retained inputs and validation destinations do not make these operations equal work: subtracting totals does not establish allocator ownership or a whole-product saving.

## Memory remains material

MiB below means 1,048,576 bytes. Every entry, preparation, warmup, measured cycle, late increment, destination release and final input release is retained in the native reports. Kernel fields are separate observations with overlapping ledgers; they are not added as independent causes.

| Control | Entry→preparation RSS | Preparation→warmup RSS | Warmup→measured RSS | Warmup→measured volatile resident | Entry→final RSS | Entry→final footprint | Entry→final reusable |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Raw draw | +215.40625 | +78.109375 | −2.6875 | 0 | +290.84375 | +2.640991 | +290.140625 |
| PNG write | +215.546875 | +79.25 | +0.6875 | 0 | +295.484375 | +3.547363 | +290.9375 |
| PNG decode/draw | +215.453125 | +156.34375 | +619.96875 | +622.375 | +991.765625 | +2.595703 | +213.5625 |

Raw/write volatile resident is 0.015625 MiB after warmup and remains at that value. Their last three RSS increments are respectively +0.0625/+0.09375/+0.078125 MiB and +0.078125/+0.125/+0.09375 MiB. Their RSS peaks are 360.390625 and 362.3125 MiB. The large entry-to-final RSS cost remains visible even though the kernel classifies almost all of that increase as reusable. That classification is not physical reclamation, a proven allocator owner, a cost-free buffer or a stable-memory conclusion.

PNG decode/draw retains 777.984375 MiB volatile resident at final cleanup, with final RSS 1058.484375 MiB and RSS peak 1214.0625 MiB. Every measured-to-measured volatile-resident increment is 77.796875 MiB; the final three RSS increments are +77.984375/+77.890625/+77.953125 MiB. Its reusable increase is 213.5625 MiB and internal increase 780.0625 MiB. Footprint falls after explicit destination/input release while RSS/volatile backing remain; the footprint number does not close this issue. Compressed and volatile-compressed counters are zero in these recorded boundaries. No memory pressure, purge or allocator relief is used.

## Editable control failed before any completed cycle

`editable-render-pin` reports `Restored document changed` after 0.646628 seconds. Its launch envelope contains the error, while its component sidecar preserves partial diagnostics, so the final strict checker rejects their mismatch. All seven owned exits are confirmed, but exit 0 is not native success. **This cell has zero completed cycles**, and its preparation/partial observations cannot be promoted to a 2+8 result.

The prepared document records an unknown capture time: `captureTimestampKnown=false`, `captureTimeZoneIdentifier=UTC`, and Unix epoch 0 (JSON's 2001-reference timestamp −978307200). Source inspection finds that `restoreCaptureTimestamp` replaces this unknown epoch with the current date, which `editablePayload` then serializes. The artifact does not contain a field-by-field restored-document diff. The proposed production correction preserves stored capture metadata and uses a separate editor-session date for newly authored unknown-time watermarks. Its native regressions and the unchanged document-fidelity gate must pass before that correction is accepted.

The next diagnostic adds a separate full-size vImage-owned normalization consumer before actual drawing. It retains every existing control, exact input/pixel checks, original end-to-end acceptance workload and inner resource limit. It is an experiment, not a production decoder switch, a general color/depth fidelity claim or an accepted remedy. 0.16 remains held until complete matched functional, memory, model and installed gates support delivery.
