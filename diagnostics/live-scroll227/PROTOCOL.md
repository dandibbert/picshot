# PicShot original227 allocation observation overlay

This overlay changes only fixture observation and launch identity/environment handling. It is not a product change or an uninstrumented memory qualification. Apply exactly these runtime files to clean original227 (`e5a859a82b2a7a697e51a0a4d42f34ae4f5602d0`):

- `Sources/PicShot/LiveScrollResourceFixture.swift`
- `Sources/PicShot/LiveScrollAllocationDiagnostic.swift`
- `scripts/launch-smoke-app.swift`

Compile and certify that exact executable without the diagnostic opt-in. Its instrumented run must use the same executable, Foundation PNG writer, 2 warmups plus 8 measured cycles, 218 source frames per cycle, unchanged original output/ownership/cleanup/memory gates, 590-second app budget, 600-second launcher budget, and 180-second per-session budget. Holds consume those existing budgets; nothing extends them.

## Only the app gets stack logging

The external runner first performs its separately bounded 20-second tool/volume readiness check. The runner, native probes, and Swift launcher must have every `Malloc*` environment variable removed. The runner creates a fresh, canonical, owned private directory, and supplies only these diagnostic environment keys to the launcher:

- `PICSHOT_LIVE_SCROLL_ALLOCATION_DIAGNOSTIC`: canonical absolute protocol directory
- `PICSHOT_LIVE_SCROLL_ALLOCATION_DIAGNOSTIC_TOKEN`: UUID unique to this run

It creates owned regular mode0600 `configuration.json` (one hard link, <=16384 bytes) with exactly:

```json
{
  "schemaVersion": 1,
  "protocol": "picshot-live-scroll-allocation-diagnostic-v1",
  "runToken": "RUN-UUID",
  "mallocEnvironment": {
    "MallocStackLogging": "full",
    "MallocStackLoggingNoCompact": "1",
    "MallocStackLoggingDirectory": "/canonical/private/owned/log/directory"
  }
}
```

The launcher requires exact keys, token, values, and directory ownership; it rejects actual inherited `Malloc*` settings under opt-in. It inserts only those three validated settings into the fresh `NSWorkspace.OpenConfiguration.environment`. The app records the actual settings it received. Literal `1` is not accepted or relabeled as `full`. Environment receipts alone do not prove tool capability; the external observer must verify the installed platform's supported semantics and actual live/freed calibration stack history before advancing.

## Owned launch receipt

The launcher publishes `launch.json` after NSWorkspace returns its exact newly created application. Its exact keys are:

- `schemaVersion`: 1
- `protocol`: fixed protocol string above
- `runToken`: matching UUID
- `launcherPID`: retained launcher process PID
- `launcherStartEpochSeconds`: NSRunningApplication launch date of the current launcher
- `appPID`: exact NSWorkspace returned application's PID
- `appLaunchEpochSeconds`: returned application's NSRunningApplication launch date
- `selectedAppPath`: canonical selected bundle path
- `executablePath`: canonical selected `Contents/MacOS/PicShot` path
- `executableSHA256`: selected executable SHA256 computed before launch

The observer must bind its retained Popen launcher, independent kernel birth/path checks, this receipt, and each request identity before invoking any PID-based tool. No process-name discovery is authorized. A request can appear before `launch.json` due to callback scheduling; wait for matching independent launch identity within the request's existing deadline. Never infer process ownership from a request alone.

## Sequential request/reply handshake

Swift publishes `request-0001.json` through `request-0010.json`, each by exclusive atomic rename of a private temporary file. Observer publishes the matching `reply-0001.json` etc. atomically, with no previous destination, regular mode0600 and one hard link. Files are retained. Unknown, premature, failed, malformed, mismatched, or late replies fail the diagnostic. No retry or next checkpoint after a terminal reply failure.

Every request has exactly:

- `schemaVersion`: 1
- `protocol`: fixed string
- `runToken`: UUID
- `sequence`: integer 1..10
- `requestID`: fresh UUID
- `kind`: `calibration-live`, `calibration-released`, or `checkpoint`
- `cycleOrdinal`: integer 0 for calibration; otherwise actual1..10 cycle ordinal
- `phase`: exact string in schedule below
- `identity`: exact object described below
- `publishedUptimeSeconds`: current Foundation system uptime
- `replyDeadlineUptimeSeconds`: authoritative maximum time to receive completed valid reply
- `maximumHoldSeconds`: 15 for calibration or10 for checkpoint
- `fixtureDeadlineUptimeSeconds`: original unchanged590-second deadline
- `mainActorBlocked`: true
- `perturbationLabel`: explicit diagnostic effects label
- `mallocEnvironment`: exact three-key object of actual received values
- `calibration`: null, or `{ "address": "0x...", "requestedBytes": 65537, "usableBytes": <malloc_size result> }`

`identity` has exactly `pid`, `processStartEpochSeconds`, `processStartUptimeSeconds`, `executablePath`, `executableSHA256`. Start epoch comes from NSRunningApplication launchDate. Start uptime is derived once from that launch epoch and current epoch/uptime; it is a stable request fingerprint, not a substitute for independent kernel birth verification. `processStartEpochSeconds` must match `launch.json`'s app launch epoch.

Every reply has exactly:

```json
{
  "schemaVersion": 1,
  "protocol": "picshot-live-scroll-allocation-diagnostic-v1",
  "runToken": "copied from request",
  "sequence": 1,
  "requestID": "copied from request",
  "identity": { "pid": 0, "processStartEpochSeconds": 0, "processStartUptimeSeconds": 0, "executablePath": "copied", "executableSHA256": "copied" },
  "status": "ok",
  "completedUptimeSeconds": 0,
  "errorCode": ""
}
```

Echo the identity object exactly. `completedUptimeSeconds` must be finite, no earlier than publication, no later than the request deadline or app's current uptime. Status is `ok` or `failed`. Success requires empty errorCode; failure requires a nonempty <=128-byte lower-case ASCII letters/digits/hyphens code. Native tool evidence stays in separate bounded observer files, not arbitrary reply text.

## Exact schedule and timing

1. `calibration-live`, cycle0, `calibration-owned-allocation-live`, maximum15s
2. `calibration-released`, cycle0, `calibration-owned-allocation-released`, maximum15s
3. `checkpoint`, cycle4, `released-plus-1000ms`, maximum10s
4. `checkpoint`, cycle5, `pre-finish-pending-edge`, maximum10s
5. `checkpoint`, cycle5, `released-plus-1000ms`, maximum10s
6. `checkpoint`, cycle8, `released-plus-1000ms`, maximum10s
7. `checkpoint`, cycle9, `finish-image-alive-before-png`, maximum10s
8. `checkpoint`, cycle9, `png-finalized-image-alive`, maximum10s
9. `checkpoint`, cycle9, `released-plus-1000ms`, maximum10s
10. `checkpoint`, cycle10, `released-plus-1000ms`, maximum10s

Calibration explicitly mallocs and touches65537 bytes, emits its live address/size, waits for proof, frees that same allocation, and then emits the freed address/size. It is a labelled perturbation. The external observer must prove an attributable live allocation stack and subsequent free history for this exact address, before cycle1. On failure the block is freed and no workload cycle begins.

Maximum requested app hold time is110s. The20-second readiness check is external and before launch. Each calibration request has15s (combined calibration holds30s). Separately, the external observer has a global30-second history-extraction cap across calibration and checkpoint history calls together; those calls consume their enclosing request hold and never add time to it. Each of exactly8 heavy checkpoint sets has10s including all tools, child cleanup, and reply publication. Failed or unproven capability is an evidence failure, not permission to run a partial cycle series.

All handshakes deliberately block the app's main actor, including synchronous Finish delivery. No runloop pumping or reentrancy is introduced. Original memory/backing, release+150ms and release+1000ms scalar, owner and provider observations occur before the post-release hold. A failed post-release handshake records failure and still executes the original spool-removal and ownership assertions. Observed timestamps remain actual; they are not relabeled target times. Scalar `malloc_zone_statistics(NULL)` data is attached alongside every original memory row when opted in; no pressure-relief or allocator-cleanup operation is called.

The diagnostic adds its own small allocations, file I/O and logging overhead, and delays UI work. Results must be labeled instrumented and interpreted together with original uninstrumented evidence. The original output/ownership/memory acceptance gates are not loosened or relabeled.

## Verification limits

The local deterministic tests check overlay scope, unchanged session/gates, exact checkpoint order and publication/forwarding contracts. They are not a native build or tool-capability proof. A macOS compile and native calibration remain mandatory. Apple documents all-zone aggregation for null `malloc_zone_statistics` in its [public header](https://github.com/apple-oss-distributions/libmalloc/blob/main/include/malloc/malloc.h).
