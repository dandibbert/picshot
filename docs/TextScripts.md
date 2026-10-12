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

## Build251 post-launch trap; runtime integration held

Source `2d0bcc6dcd563f20289dfc7847e6c94d64fa987c`, [run38318568054](https://github.com/dandibbert/picshot/actions/runs/38318568054), passes all 14 unit methods, signing and final sole-entitlement inspection. The first actual helper call then exits with `SIGTRAP` (signal 5), observed after 0.032 seconds. Its app/helper static identities validate; stdin receives 195 generated bytes, stdout/stderr each return 0 bytes, and the parent confirms child exit, pipe drainage, zero retained response and released admission. The gate stops after signed-source identity and that failed first transformation. File/network denials, later cancellation/resource and parent-loss cases are unrun. A valid signature is not evidence of successful sandbox initialization. The retained archive contains no crash reason/stack, so this result alone does not establish the trapping layer.

Artifact 11777778666 is 307,323 bytes, SHA-256 `89b284f706875b71a7e1b0567121fad1f4e4f0f459d219661140f35085efbfb8`. The next focused diagnostic keeps helper/client/gate/tests, entitlements and all limits byte-identical, and adds only bounded post-failure collection of the matching generated helper crash record. PID, time and executable identity must match; an absent or insufficiently bound crash remains explicitly unavailable. It preserves the failed gate result and does not authorize an additional entitlement, an unsandboxed fallback, UI integration or a scripting installer.

## Build252 identifies missing signed helper metadata

The unchanged-runtime diagnostic at source `85f905aa44a860eeb8d3f4f6ca53d063293c84c2`, [run38319630273](https://github.com/dandibbert/picshot/actions/runs/38319630273), preserves the first-transform failure and all 14 passing unit methods. Its matching owned crash record identifies `_libsecinit_appsandbox.cold.6` during loader initialization. The application-specific reason says Code Signing Services cannot find `kCFBundleIdentifierKey` in the helper's signed Info.plist when obtaining its sandbox container identifier. PID, parent PID, launch/capture times and the signed helper's Mach-O UUID match; the path was OS-redacted. The archive contains the bounded extracted reason/stack and original crash hash, without the full crash report or unrelated logs.

This establishes a packaging metadata defect before helper main. The next candidate embeds a checked-in Info.plist in `__TEXT,__info_plist` for each helper, using its existing exact code-signing identifier. After outer signing, a read-only public Security API inspection requires the secured `kSecCodeInfoPList` dictionary to equal that intended metadata. Helper source, client, native gate, unit tests, sole sandbox entitlement and every runtime bound remain unchanged. Actual sandbox launch and the complete original capability/lifecycle gate must still pass before integration. [Apple's single-file tool metadata guidance](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html), [secured plist dictionary key](https://developer.apple.com/documentation/security/kseccodeinfoplist).

The retained diagnostic archive is artifact 11778560803, 309,754 bytes, SHA-256 `876cfb838c9fad7f64bfb52e8afa616fe71e02b794b514c3ce13b73eb659691c`. This reason does not justify adding an entitlement or removing the sandbox.
