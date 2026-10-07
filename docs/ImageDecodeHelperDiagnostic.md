# Opt in PNG decode helper diagnostic

Prepared diagnostic only. Native compilation and execution of this new route are pending. The [completed ARM64 and Intel actual-draw result](ImageRasterMaterialization59.md) found +40.5 MiB volatile resident backing for production preview plus drawing, +20.25 MiB for no-cache full decode plus drawing, and zero volatile growth for drawing already-decoded owned RGBA over 12 measured cycles. The raw control excluded PNG decoding.

This experiment includes actual PNG decoding in a fresh signed bundle helper for each cycle, followed by actual owned-RGBA drawing in the parent. It changes no production preview defaults, normal codec request/response protocol, or resource gates.

## Run and selectors

Use an existing signed native app that contains this diagnostic, with a new evidence directory:

```sh
scripts/image-decode-helper-attribution.sh --compare /absolute/PicShot.app /absolute/new-evidence-directory
```

The standalone runner verifies the app and helper signatures, architecture and embedded diagnostic protocol, prepares synthetic inputs in a separate process, then launches four fresh parent processes:

- `production-control`: unchanged production PNG preview and actual drawing, 2 warmups +12 measured cycles
- `isolated-decode`: 14 sequential new signed helpers, each performing PNG decode and actual raster drawing before the parent draws the returned raw pixels; 2 +12
- `cancel-after-decode`: one child actually decodes/draws, signals its diagnostic pre-publication hold, and receives a real cancellation command
- `timeout-after-decode`: the same bounded hold reaches its real work deadline

Direct parent selectors are `PICSHOT_IMAGE_DRAW_HELPER_MODE` and `PICSHOT_IMAGE_DRAW_HELPER_INPUT_DIRECTORY`. Mixed diagnostic modes and overrides are rejected. The helper's explicit `--image-draw-decode-diagnostic-v1` entry is separate from its unchanged no-argument production export route. No executable override or shell is used.

## Pixels and lifetime

Every successful cell uses immutable 768×576 PNG bytes and a canonical premultiplied sRGB RGBA reference created in the preparation process. **Only PNG bytes and bounded request metadata enter the child job. The child never receives the reference RGBA.** It validates PNG framing, source completeness, type, count, dimensions, depth and orientation, creates a full image with caching disabled, and draws/readbacks exactly 1,769,472 bytes.

The parent confirms child exit before reading raw output. It validates file identity, size and digest, compares every raw byte with the reference, copies into an owned CGDataProvider, draws into one reused destination, and compares every destination channel exactly. There are no per-cycle image or decoded-Data arrays. This first version deliberately includes a transient raw Data buffer plus the owned-provider copy; it does not claim zero-copy IPC.

The shared native-export admission lease is held until child exit and private-job cleanup are confirmed. Unknown files, symlinks, hard links or substituted directories make cleanup fail closed. Unconfirmed exit retains admission and stops subsequent work. Child parent-loss handling stops the worker; cleanup is attempted only after worker completion. An independent hard backstop can end an uncooperative child, leaving cleanup to the live parent rather than deleting files while native code might still write.

**Parent-loss limit:** the four cells do not test abrupt parent death. Death before helper startup, or a later hard exit while native work is stalled and no parent survives, can strand the private PNG/request/output job. There is no orphan reaper in this prototype. Cooperative cancellation/deadline cleanup with a live parent must not be generalized to those cases.

## Evidence and cost

Named reports are `image-decode-helper-<mode>.json`. Each records parent self-Mach boundaries, child self-Mach phases, periodic 10 ms sampled peaks, owned-child RSS polling, process exit/termination facts, file cleanup/admission state, raw and destination hashes, ownership callbacks, and timings. All accounting observations retain kernel status and returned counts. Successful comparison validation requires actual volatile fields; missing observations never become zero.

Child phases distinguish image creation, actual drawing/readback, context release, output close and decode-pool exit. Parent observations cover the overall helper operation, returned raw data before drawing, actual drawing, pool exit and settling. There are no separate parent memory observations immediately after staging, confirmed exit, or raw read/cleanup, so those individual transport phases cannot yet be attributed. Separate child/parent maxima, receipt-time pairs and any independent-maxima sum are explicitly scoped. They are not simultaneous lifetime peaks, hard upper bounds or unique physical RAM usage; shared pages, kernel file cache, GPU and other processes remain outside those claims.

`fullLifecycleSeconds` begins before signature validation/input staging and includes launch, decode, raw writing, process exit, pipe drainage, raw read/hash/copy, parent draw/full validation, pool exit and owned cleanup. `timeToValidatedPixelsSeconds` stops immediately after the exact pixel check. The 0.18-second settle is separate. Signature, staging, launch-through-exit, raw-read/hash, child creation/draw/write and cleanup subphases are also retained. The production control uses the same full-lifecycle boundary.

Bounds are fixed: 8 MiB PNG; 1,769,472 raw bytes; 4 KiB request; 16 KiB event including LF; 128 KiB stdout; 8 KiB stderr; 2 MiB diagnostic report. A scalar-width report stress test covers the full bounded schema; production protocol ceilings are untouched. Child work is limited to five seconds with an independent six-second hard backstop and nine-second parent exit-confirmation bound. Parent arms have a 180-second cooperative and 200-second outer deadline. A 256 MiB sampled child RSS/footprint watchdog is not an instantaneous quota. The launcher caps the app log at 1 MiB and records outer-deadline failures without inferring child cleanup.

The one-shot fault probes must show actual post-decode readiness, no accepted raw output, confirmed exit and cleanup. Successful measured cells must show all 14 real draws and exact pixel checks. Provider callbacks are ownership evidence only. Even a flat parent trend would establish a bounded isolation candidate, not a production remedy: concurrency, startup/IPC latency, file-cache use, larger inputs and real UI behavior still matter. No global pressure, VM purge, new dependency, model or permission is used.
