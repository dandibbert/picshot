# Original227 allocation observer

This script is a diagnostic-only, one-launch observer for the exact original227
resource fixture. It does not grant memory acceptance or change the original
2 warmup + 8 measured cycles, PNG validation, memory ceilings, or 590/600-second
app/launcher deadlines. `status: evidence-collected` means the requested evidence
was collected, not that attribution, output validation, or memory acceptance passed.

Run only through the parent workflow after its original certification step:

```
python3 observe-original227-allocations.py \
  --app /absolute/Diagnostic/PicShot.app \
  --launcher /absolute/diagnostic-overlay/scripts/launch-smoke-app.swift \
  --resource-root /absolute/resource \
  --diagnostic-directory /absolute/new-diagnostic-directory \
  --report /absolute/new-observer-report.json \
  --expected-executable-sha256 PINNED_SHA256
```

The resource root must already have `input` and `measure` directories. The observer
starts exactly `/usr/bin/swift LAUNCHER APP ROOT/measure/summary.json` in measure
mode. It passes the private diagnostic directory and UUID token to the launcher.
`configuration.json` contains only the exact protocol/schema/token and the three
approved malloc settings. All inherited `Malloc*` settings are removed from the
observer's native commands and launcher environment. The launcher applies
`MallocStackLogging=full`, `MallocStackLoggingNoCompact=1`, and the generated
logging directory only to the NSWorkspace app.

## Readiness and bounds

Before launching the app, a 20-second readiness budget covers installed tool
help/man checks and a dedicated `hdiutil` UDRW HFS+ image. The mounted filesystem
must have at most 256 MiB actual statfs capacity, be a different device from the
temporary parent and `/`, and occupy the exact generated mountpoint. A real,
non-sparse sentinel write (at most 257 MiB generated data) must receive ENOSPC;
the sentinel is then unlinked and available space checked. Failure stops the probe
without any fallback logging directory.

The same app must then prove its live 65,537-byte calibration allocation in
`vmmap` and address/size `heap` output, and prove symbolized allocation plus later
free history for that exact address in `malloc_history -fullStacks`. A different
size reused at the same address resets the pairing. No workload is released until
both calibration requests succeed.

Eight declared checkpoint sets have at most 10 seconds each, including identity,
owned stack-log FD checks, memory tools, and histories. Malloc-history calls share
one 30-second aggregate budget, including calibration. Native output uses bounded
pipes and pinned, unreaped child process groups from the unchanged
`run-bounded-command.py`; overflow, timeout, access denial, or incomplete child
cleanup is inconclusive. Each tool is capped below 8 MiB and all retained text is
capped at 64 MiB. Native/launcher text has a 62 MiB ceiling, including a cleanup
reserve; protocol metadata and the final report each have a further 1 MiB bound.

## Identity and scope

The independent Swift launch receipt binds the UUID token, owned launcher PID,
NSWorkspace-returned app PID and launch date, selected canonical executable, and
SHA-256. Kernel process birth must match launch dates within 1 ms; failure never
widens the tolerance. Exact libproc identity is pinned for the replay, checked
through each probe, and rechecked with the executable hash immediately around
each target tool. No process-name lookup or global process selection is used.

At every calibration/checkpoint, one bounded exact-PID query runs:

```
/usr/sbin/lsof -nP -a -p OWNED_APP_PID -F0pftDn
```

The query is checked against native identity immediately before/after. Only
stack-log FD/path/device evidence is retained; unrelated filenames are discarded
in memory. At least one active numeric regular-file stack-log descriptor must
resolve inside the exact owned directory on the pinned volume device. Any
outside-volume stack log, missing/ambiguous field, denied access, or unsupported
format stops the replay. There is no alternate descriptor collector.

`vmmap -w` is always used. `-resident` is added to those same calls only if the
installed documentation advertises it. Missing per-region resident/reusable
columns are explicitly `unsupported-inconclusive`; process totals never substitute
for per-region evidence. There are no extra snapshots, custom VM walking, or
full-memory dumps.

Heap parsing rejects incomplete/unrecognized allocation-address rows. Histories
select up to two large addresses per checkpoint, prioritizing a disappeared prior
address when available and new/changed allocations across sizes. Selection has no
4,177,920-byte equality filter. Allocations born and freed entirely between
snapshots may remain unattributed, and selected histories are not an exhaustive
allocation census. Every selected history is extracted while the app is alive,
before the corresponding reply permits progress or final exit.

## Cleanup and downstream gating

Python signals only its owned launcher group. The retained NSWorkspace application
handle in the original launcher owns app termination. Before detaching/deleting
the image, the observer requires the exact app birth identity to have retired.
It records hashes/sizes of the bounded raw journals after app retirement, then
removes only its own image and temporary directories. If retirement or detach is
unproven, the report is inconclusive and retains the generated location for review;
it never claims cleanup or silently changes logging destinations.

Downstream independent decoders must require `appRetirementConfirmed`,
`launcherCleanupConfirmed`, every `nativeCommands[].cleanupConfirmed`, and a known
boolean `appLaunched`. A detach failure does not erase independently verifiable
outputs after every process retired. Final diagnostic completion additionally
requires `volumeCleanupConfirmed`. `appLaunched=false` means the launcher was
never started; `null` means launch is not yet proven; `true` means its exact app
receipt was verified. `memoryAcceptance`, `installerAcceptance`, and
`zeroLeakClaimed` remain false. The parent owns all original functional/resource
validation and any final cross-snapshot attribution analysis.

Portable negative checks:

```
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s diagnostic-overlay/scripts/tests -p test_original227_allocation_observer.py -v
```

These tests exercise real bounded subprocess overflow/timeout/descendant cleanup,
protocol and filesystem rejection, identity mismatch, capacity evidence, history
pairing and reuse, complete heap parsing, and exact owned log FD filtering. Native
macOS capability, image mounting, and application replay remain runtime checks.
