# Bounded Intel callout retirement diagnostic

This diagnostic is derived from base 003cd44d0b8618e8cf4e43a84b1ac155cfcac3bc. It investigates a missing timing proof without changing the original 2000 ms observed-retirement deadline, scheduled 10 ms owner check, six-cycle workload, maximum 256 samples, object cleanup or accepted JSON schema. It is not an installer release or full acceptance run.

Build 102's original Intel report remains failed. Cycle 3 was last observed pending at 1036.194623 ms after close and first observed nil at 2027.893572 ms, separated by a 991.698949 ms sample gap. That does not measure exact last release or establish scheduling cause. Five of six cycles were created; all sampled application-owned and detached-text-system graphs were zero. A later instrumented execution cannot retrospectively accept that run.

## Isolated workflow routing

A commit containing only the diagnostic marker `[callout-retirement]` selects an Intel-only job. The marker is the first branch in the **workflow-level** concurrency expression, yielding `picshot-<ref>-callout-retirement` rather than the ordinary `picshot-<ref>-current` group. Diagnostic cancellation of an earlier run is disabled. The ordinary build explicitly excludes the marker; all other workflow branches and their normal concurrency choices remain unchanged. Do not combine unrelated diagnostic markers or rerun merely to get a green result.

The dedicated job performs:

1. Portable adversarial checks in ordinary and optimized Python
2. Exactly eleven native source-scoped token/destination tests within the existing 540-second convention, with complete unique test-completion verification
3. Full app-only release compilation and signing within 1800 seconds, using `-Xswiftc -DPICSHOT_CALLOUT_RETIREMENT_DIAGNOSTICS`; no ZIP/DMG installers are created
4. One relocated-app LaunchServices invocation of the original full early-UI route, with the unchanged 600-second launcher deadline and a 630-second outer process guard for startup/owned-app cleanup
5. A separate outcome report that preserves original acceptance and diagnostic capture completeness independently, followed by always-on raw artifact archival

The 1800-second bound is compilation/packaging only. The 630-second wrapper leaves room for the existing 600-second launcher and its 3+3-second cleanup; neither changes the 2000 ms native retirement gate. The diagnostic job has a 60-minute aggregate bound and no rerun loop. If native support tests fail, app packaging and launch are skipped. All raw outcomes still reach the final summary/archive steps when the runner can execute them.

## What the sidecar means

Each already-tracked native input/context owns an associated token, which retains a small locked stamp and weakly references the source. The fixture probe retains only the stamp. Shared source objects reuse their stamp. The six-cycle workload attaches at most twelve token/stamp pairs with one event each. No timer, additional sampling loop, AppKit input-context creation, retained owner/text graph or swizzling is added.

The token records its callback and synchronous weak-read completion using the original monotonic clock, directly on the callback thread before taking its lock. A true weak-nil event by 2000 ms can establish earlier weak retirement in that instrumented execution, even when the original monitor observes nil later. Both input and any tracked context must qualify. A late/missing event remains inconclusive about exact last release. An event while the source is still live is not retirement evidence. Association teardown is not exact heap-free time, and instrumentation can affect timing.

The sidecar path must be absolute, have an existing parent, and sit outside the accepted annotation/UI evidence trees after normalization, symlink resolution and directory-identity checks. Exclusive mode-0600 creation cannot replace existing files, directories, hard links or dangling symlinks. Each execution uses a fresh output directory. Sidecar writing occurs after the original catch records failure and before the same error propagates. Write failures are logged without changing acceptance; partial files are retained as failed diagnostics rather than overwritten.

## Outcomes and artifacts

The summary records `diagnosticCompleteness` separately from the original native fixture statuses. A valid failure snapshot can be `captured` while its status is `original-acceptance-failed`. The collector exits nonzero if any original native fixture gate failed, even when earlier weak-nil timing was captured. The unchanged callout acceptance validator is applied to any reported callout pass. A missing/malformed sidecar or incomplete bounded process is `diagnostic-incomplete`. No result claims full installer acceptance or substitutes for the ordinary outer UI checker pipeline.

Always retain `dist/callout-retirement-*.log`, matching process JSON files and the summary, the entire `dist/evidence/callout-retirement/` tree, and app `build-info.json`. The evidence tree contains actual binary/source/OS/compiler/environment identity, launcher exit, the sidecar, original `ui/preview.json`, combined annotation report, callout report and preceding fixture evidence/screenshots. Launcher exit zero alone is not an original gate pass.

The new Python guards use explicit exceptions, so `python -O` cannot remove them. The unchanged legacy package driver's assertions are kept enabled by clearing inherited `PYTHONOPTIMIZE` for that driver. Native compilation/tests and diagnostic execution were not performed when authoring this integration. Original build-102 acceptance, architecture boundaries and ongoing artifact delivery remain independent.
