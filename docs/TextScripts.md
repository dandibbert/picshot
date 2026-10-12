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

## Build249 compilation result

Source `64584e6a023afd2115eca2afa0b608912ca3011f`, [run38317618117](https://github.com/dandibbert/picshot/actions/runs/38317618117), stopped in the isolated Swift compilation after 22.822 seconds. The gate combined the SDK's `UInt32` `NOTE_EXIT` and `Int32` `NOTE_EXITSTATUS` before conversion. The next candidate converts each operand to `UInt32` before combining them, retaining both flags and the exact alarm/exit-status assertions. No limit, entitlement, helper behavior or test inventory is changed. Unit execution, final signing and native runtime checks did not run in249; no sandbox or cleanup conclusion follows from this compile result. Original failure artifact11777821918 is retained (2,482 bytes; SHA-256 `92321f627bb363ed32db17fc71f2da54e553387156173e98b13b66ff753a58dd`).

## Build250 default console finding

Source `4b054551ca7de1b4fb18e8e6f973f42142ea1a7e`, [run38317957771](https://github.com/dandibbert/picshot/actions/runs/38317957771), compiled and ran all **14** isolated methods (eight protocol, six engine). Thirteen passed; the absent-host-API test observed `typeof console === 'object'` in the macOS15.7.9 JavaScriptCore context. Final signing and the native process gate did not run. This disproves the assumption that the unconfigured context necessarily lacks a console. The candidate now explicitly removes and locks down the console property through public APIs before user-source compilation, verifying absence and failing closed if configuration fails. The absence assertion remains, with reassignment/deletion and alternate global-access checks added to the same method. The same configuration disables `ShadowRealm`, even when absent, so a user script cannot create a separate unconfigured realm with its own default console. This controls the exposed logging surface; it is not a replacement for OS sandboxing. The checker also corrects its stale 13-method total to the complete 14-method source inventory, including the previously added newline-framing method; no test is removed. Failure artifact11777737672 is retained (3,117 bytes; SHA-256 `0b2a39e5b01fe6bad25146653650aff966b145c71d7261160eccca9f7f311165`).
