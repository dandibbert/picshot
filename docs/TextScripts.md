# Bounded text scripting: native runtime decision gate

The user-facing goal is one region capture → local OCR → a saved JavaScript text transformation → checked text Copy. This document describes the initial runtime experiment only. No script manager, OCR/script integration or script-enabled installer is delivered by this checkpoint. The current experimental build248 still provides image-output chains; stable214 and original227 memory failures remain unchanged.

## Language and process boundary

The candidate compiles an editable function body with the public JavaScriptCore C `JSObjectMakeFunction` API, passing recognized text as a separate string argument. It never interpolates input into source. A fresh noninspectable context has no native host objects, JSExport bridge, capture/clipboard/UI access, Node/JXA/browser APIs, file/network/process facilities or downloaded modules. Standard JavaScript language features remain available, including loops, allocation, regular expressions and nondeterministic Date/random values. This is not a small expression language or a deterministic-evaluation guarantee.

Only a primitive string can be returned. Objects, promises and boxed strings are rejected before coercion; exception values are never stringified. UTF-16 is inspected before allocating a native result, malformed surrogates are rejected, and accepted output preserves its characters without trimming. Errors use fixed codes, with no script/OCR/returned-text content in process metrics or stderr receipts.

The helper is a separate executable with its own `com.apple.security.app-sandbox=true` entitlement. It has no inheritance, network, user-file, automation or application-group entitlement. The parent remains unsandboxed. Apple documents this independent-child arrangement in [Resolving App Sandbox Inheritance Problems](https://developer.apple.com/forums/thread/706390); PicShot's exact ad hoc signature and launch still require native evidence. Final helper entitlements and signing identities are checked after the outer bundle is signed. There is no unsandboxed fallback, private JavaScriptCore timeout API, sandbox-exec profile or OS-permission acceptance.

The absence of host APIs limits what script code can request. App Sandbox adds OS access restrictions but permits its own container and some system resources; it is not a promise of zero filesystem access or protection against every engine/OS vulnerability. Code-signature validity on an ad hoc build does not establish a verified external publisher.

## Fixed candidate limits

- Source body: 16 KiB UTF-8
- Input and output: 32,768 UTF-16 units; output additionally 128 KiB UTF-8; empty results rejected
- Request: 512 KiB; response: 256 KiB with exact schema/UUID and one newline-terminated response
- One admitted helper; no queued image-bearing requests
- Three-second parent helper-phase acceptance deadline; 0.25-second termination grace, then 0.75-second killed-exit observation
- CPU soft/hard limits: two/three seconds; five-second independent helper alarm; core dumps and regular-file data growth disabled
- Child RSS watchdog: 256 MiB, sampled about every 50 ms; missing observation fails closed

The kernel limits are installed and read back before evaluating code. A sampled RSS watchdog is not a hard memory allocation cap and may overshoot between observations. File-size limits do not bound pipes or heap allocations. Alarm/deadline observations are not universal hard real-time completion guarantees. Deadline, cancellation or failed protocol results cannot be published even if output bytes arrived earlier.

The parent uses bounded nonblocking pipes and only count/EOF drainage for stderr. All pipe endpoints explicitly have close-on-exec set; intended standard descriptors are duplicated for the child. No request/output temporary file or ambient credentials/environment override is provided. A successful result requires validated protocol and observed child exit. Unconfirmed exit or pipes retain admission; after failure/cancellation retained response bytes are discarded while required descriptor/process ownership stays alive for later cleanup.

## Narrow native experiment

The `[text-script-runtime]` job builds a dependency-free temporary SwiftPM package from an exact hash inventory of the new core/helper/client/fixture/test files. It checks a clean checkout and source commit, runs the isolated core/helper XCTest methods, and signs a standalone gate app. This does not rebuild or change the delivered PicShot product, codecs, models or disputed scroll-memory cell.

The normal path uses the actual helper with real pipes, generated Unicode/regex strings, strict diagnostics, absent-host-API checks, input/output bounds, cancellation, CPU/allocation pressure and a main-runloop heartbeat. Native-only probes attempt permission-denied read/write opens on parent-owned generated sentinels and a connection to a parent-owned loopback listener; the parent establishes positive baselines first. These are specific capability checks, not an exhaustive sandbox proof. They never expose a probe to JavaScript or read file contents into a report.

A distinct signed sandboxed **test-only** transport executable exercises malformed, oversized, wrong-identity, duplicate, unterminated, multiple and late responses, blocked termination and stderr flooding through the same parent wire code. It is explicitly injected only in the native gate build and is not a production fallback. A short-lived gate child separately launches the actual helper to verify its parent-loss alarm with owned PID/kqueue exit-status observation.

Reports retain exact source/signing identities, fixed outcomes, bounds, timings, probe errno values, heartbeat gaps and cleanup receipts. They contain generated-input evidence only. A sandbox-launch, identity or cleanup failure blocks this runtime approach until its concrete cause is resolved. No permission exception or resource-limit change is inferred from a failed run.

After independent native review, app integration must preserve image-chain v1 bytes, use one existing capture/receipt owner, freeze saved script/OCR options per run and cache successful transformation for clipboard-only retry. It must reject truncated OCR and avoid the direct OCR UI/automatic-copy route. Those integration and installed-package checks remain future work; this gate alone is not scripting delivery or full PixPin compatibility.
