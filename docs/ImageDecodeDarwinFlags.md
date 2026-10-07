# Darwin F_GETFL regression correction

The two failures in source `5ab01891a7d228b91b437cbfd13bb38845cf5172`, run 37599875645 / ARM job 112721543026 are invalid whole-status comparisons after successful writes. Actual 65537 is `O_WRONLY | FWASWRITTEN`; initial 1 is `O_WRONLY`. `O_NONBLOCK` is 0x4 and is absent in both. This evidence does not show a failed nonblocking-mode restoration.

Apple's versioned XNU sources identify the mechanism:

- [fcntl.h](https://github.com/apple-oss-distributions/xnu/blob/xnu-11417.140.69/bsd/sys/fcntl.h#L134-L136) defines the kernel-owned write-history bit as 0x10000. Its [FCNTLFLAGS mask](https://github.com/apple-oss-distributions/xnu/blob/xnu-11417.140.69/bsd/sys/fcntl.h#L219-L239) includes append, async, sync, data-sync and nonblocking, not that history bit
- [sys_generic.c fp_writev](https://github.com/apple-oss-distributions/xnu/blob/xnu-11417.140.69/bsd/kern/sys_generic.c#L548-L588) sets write history when the write transfers bytes
- [kern_descrip.c F_GETFL/F_SETFL](https://github.com/apple-oss-distributions/xnu/blob/xnu-11417.140.69/bsd/kern/kern_descrip.c#L2705-L2743) returns the converted full status, while F_SETFL replaces only FCNTLFLAGS and preserves the other bits

The patch changes **one XCTest file only**. It compares every public F_SETFL-mutable flag, verifies access mode and full F_GETFD state, and retains exact whole-word equality around the full-pipe timeout using a baseline captured after the setup writes. It adds a direct Darwin-write control that reproduces the history-bit transition and shows F_SETFL cannot clear it, plus a sender case starting nonblocking with close-on-exec set. Exact payload and bounded timeout checks remain.

No helper/writer implementation, signature check, preview default, deadline, report cap, protocol, workflow or installer changes. The sender keeps its existing defer restoration. The private history constant is used only by the direct native regression control, never production code.

Local validation: source/whitespace and observed flag arithmetic checked; patch apply-check against the read-only owner. Swift/macOS is unavailable in this Linux environment, so the amended eight-method helper suite remains native-unrun. Rebuild tests, run `PicShotCodecHelperTests.ImageDecodeTimingTraceTests`, then rerun the 132-test filter (now 134 with the two added controls) and the required full native suite. Do not infer a green native result from this source correction.
