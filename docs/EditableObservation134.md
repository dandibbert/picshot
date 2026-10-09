# Build 134: installed preview path identity refusal

Source `0e67d5599765c53b7602ce2d387e68bad1c75d67`, tree
`4f74a7e49d5ea44f02bd3a5f5000f689a85f342e`,
[run 37884793424](https://github.com/dandibbert/picshot/actions/runs/37884793424).
This production-default candidate is **not accepted**. ARM job 113672256254
failed during early installed ZIP verification, before native suites, actual
models, both final installed workflows and the new default resource gate.
The accepted ARM 0.15.1 and Intel 0.11 installers remain unchanged.

Normal and Python `-O` portable contracts passed. The signed app compiled,
native UI reports passed, and the prior effect-output guard reported 24 cases
and 432 rejected outputs. The separate editable functional process also
reported `passed` and confirmed its owned exit, but the strict independent
identity check refused its `bundlePath` before accepting that evidence.

## Exact path difference

The early script extracted the ZIP using bare `mktemp -d`. Native Foundation
reported `/var/folders/nj/vtw8zd2j31d1gdrtntc5y4600000gn/T/tmp.r4D2IeBGNJ/PicShot.app`;
the Python POSIX resolution retained the physical `/private/var/...` prefix.
The report and launcher agree on PID 22616, and the native functional phase
took 13.359 seconds. The report gives executable size 21,438,832 bytes and
SHA-256 `fe9cd04f913aa64bf93ccbdf8e7308ef70286957e6af1c84d777ee27937acd0e`.
The QA archive does not contain that executable, so its self-reported hash
does not independently qualify a final installer.

The raw QA archive is 7,781,167 bytes, SHA-256
`46e432d78a94ed060deb6f6c17bb8c921bd8ae68901fec1b8cf14ecb394b26e7`,
artifact 11595509568. A diagnostic replay changing only the comparison path
spelling passes the remaining functional, ownership and visual checks in
normal and `-O` Python. That isolates the refusal; it is not acceptance and
does not modify the archived evidence or strict production checker.

## Narrow correction and next gates

All six installed-app extraction scripts now use exclusive temporary
directories beneath the physical repository `dist` directory, with `cd -P`
and a canonical parent check. The final ZIP/DMG script already used that
location; its parent check now precedes creating the evidence subdirectory.
No app source, pixel operation, identity equality, resource threshold,
deadline, fixture workload or checker assertion changes.

Four portable regressions execute the actual shell preflight across all six
extractors, using an extraction stub that fails before any native app launch.
They cover unique workspace directories and cleanup after failure, a linked
repository invocation, refusal of a redirected `dist` without writing through
it, and inventory coverage for every installer extractor. The ten source and
shell tests pass in normal and `-O` Python. These are filesystem/orchestration
tests, not native application acceptance.

Package-only DMG staging and temporary source-comparison copies do not launch
installed apps or produce bundle identity evidence and retain their existing
temporary paths. The next source must rerun the entire normal workflow and
the actual no-override installed-default gate. Build 133's paired memory
results remain source-specific and cannot fill an unrun installed cell.
