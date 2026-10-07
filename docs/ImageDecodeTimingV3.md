# Opt-in decoder timing observations v3

Prepared instrumentation only; native compilation and execution are pending. The [completed Intel da8dde5 result](ImageDecodeLargeDA8Intel.md) and ARM evidence expose approximately 80 ms between child response preparation and parent exit confirmation, plus unattributed native main-queue stalls. This variant measures those boundaries; it changes no decoder, verifier, preview default, admission cap or scheduling policy.

## Explicit route

After building the signed app and helper containing the explicit timing route:

```sh
scripts/image-decode-large-attribution.sh --timing-v3 /absolute/PicShot.app /absolute/new-evidence-directory
```

This runs the same two preparations, four large headless cells and two 5K UI cells as `--compare`, with the same counts, bounds, pixels and cancellation checks. The explicit parent selector is `PICSHOT_IMAGE_DECODE_LARGE_TIMING=3`; every other nonempty value is rejected. Only that selector causes the parent to launch `--image-draw-decode-diagnostic-v3`. Request/stdout protocol remains strict `image-decode-helper-v2`; normal v1/v2 and the `--compare` runner leave timing disabled. A separate `[decode-timing-v3]` workflow selector chooses these observations without producing installers or changing the normal package gates.

Instrumented named reports carry `timingInstrumentationVersion=3`. Preparation supplies the same immutable input, so its manifest format remains unchanged. The checker requires `--timing-v3` to accept instrumented reports and rejects missing timing evidence in that mode; it accepts both captured da8dde5 architectures unchanged in baseline mode.

## Child and parent boundaries

Existing `responsePreparedUptimeSeconds` remains the timestamp immediately before the original terminal sender. The instrumented child records:

1. `terminalWriteStartedUptimeSeconds`, immediately before the existing terminal `writer.send`
2. `terminalWriteCompletedUptimeSeconds`, only after that call succeeds, including its encoding/locking/writing cost
3. `runReturnedUptimeSeconds`, in a wrapper after `run()` and its deferred cleanup return
4. `framePreparedUptimeSeconds`, before encoding the separate timing frame

The child emits one LF-terminated `image-decode-tail-v3` JSON frame on stderr after return. It includes PID, the last terminal-write attempt count and success. The frame is capped at 1,024 bytes; finite monotone timestamps, strict keys, duplicate/depth/trailing checks and exactly one frame are enforced. The original ordinary stderr cap remains 8 KiB, stdout stays capped at 128 KiB, and terminal ordering is unchanged. The timing writer uses a nonblocking descriptor and a 50 ms write deadline, restores descriptor flags and preserves the original child return code on observation failure. This added frame/encoding/write is diagnostic overhead, not a free observation.

The parent records `terminalFrameReadReturned` for the successful pipe read that contains the complete terminal event, and `terminalFrameDecodedAtReceipt` after strict event decoding and the existing receipt-memory observation. If a frame spans reads, the first byte is not timed. It separately records its first observed `isRunning=false`, then `waitUntilExitStarted` and `waitUntilExitCompleted`. Original exit, drainage, pixel verification, owned cleanup and admission release remain required.

These boundaries can distinguish a terminal sender delay, return/teardown delay, process observation delay and a blocking exit wait. They do not identify an exact kernel exit time or prove why a delay occurred. A terminal read can precede the child's sender return, or happen after the exit wait when the parent drains queued bytes; the checker deliberately permits both valid orders.

Normal controlled cancellation that returns through `run()` emits the timing frame. Cancellation before child launch reports `notLaunched` with no frame. A crash, hard `_exit`, forced termination, blocked/broken stderr pipe or failed timing serialization can leave it absent/partial. Such loss is explicit (`pending`, `absent`, `oversized` or `malformed`) and cannot pass instrumented timing validation. A valid trace alone never proves exit or cleanup.

## Main-queue observations

The existing one-outstanding-acknowledgement probe retains its histogram and counts. When timing is enabled it additionally retains:

- At most **8 worst** acknowledgements: queued/acknowledged monotonic uptime, delay, phase at enqueue and phase at acknowledgement
- At most **64 phase transitions** with fixed labels: setup, source construction, controller/snapshot construction, warmup/steady preview, debounce, active Cancel, post-decode Close, late result, evidence capture, settle and cleanup

Overflow or invalid time is explicit and fails the instrumented report check. No controller, image or unbounded callback array is retained. The timeline allows overlap with a long acknowledgement interval to be inspected; the phase labels do not establish causation. Controller and snapshot construction are measured together around the existing constructor, not split inside production code. The worst-eight list is not a complete trace of every stall.

The added maximum scalar-width payload rehearses at about 22 KiB and has a native assertion below 32 KiB. The existing 2 MiB diagnostic report cap, 4 MiB preview cap, deadlines, sampled memory watchdogs and 100 ms observation flag stay unchanged. No signature verdict is cached, no helper is reused, and no display mode is changed. A 1× native window stays recorded as 1×; genuine Retina coverage is still absent in the available environment.

`parentLossVerified=false` remains explicit. Early parent death/hard exit can strand files. This instrumented comparison is not a production memory or responsiveness fix, and it does not claim total-system reclamation.
