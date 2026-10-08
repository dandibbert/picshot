# Exact-source recording diagnostic result

Run [37697840669](https://github.com/dandibbert/picshot/actions/runs/37697840669), build 95, attempt 1, source `03e7080ef0d0baafcd9e42dbcddd697ee943aa64`: terminal success on both architectures.

The earlier af11 Intel installed ZIP broad-smoke failure did not reproduce in this separate recording-only process. Its exact failing wait remains unknown. No production correction is justified by this passing diagnostic alone. This run created no ZIP/DMG installer and does not clear the earlier installer gates.

| Observation | ARM | Intel |
|---|---:|---:|
| Native selected tests | 77 passed, 0 failures | 77 passed, 0 failures |
| Fixture elapsed | 4.144190s | 4.241720s |
| Warmup elapsed | 1.339395s | 1.649238s |
| Trace events / dropped | 162 / 0 | 162 / 0 |
| All four cycles | 7 frames, 95 pixel checks each | 7 frames, 95 pixel checks each |
| Retained objects after each cycle | 0 | 0 |
| Owned root removed / owned app exit | confirmed | confirmed |

ARM: warmup `refresh-camera-crop` required 26 attempts over 0.080856s; longest synchronous attempt 0.008873s. All other append/refresh operations, including every measured-cycle operation, accepted on their first attempt. Longest overall append/refresh boundary was `refresh-camera-crop` in warmup: 0.080856s.

Intel: warmup `refresh-camera-crop` required 38 attempts over 0.085371s; longest synchronous attempt 0.008510s. All other append/refresh operations, including every measured-cycle operation, accepted on their first attempt. Longest overall append/refresh boundary was `append-screen-0` in warmup: 0.120325s.

Each writer reached status 2 (completed) and released its tracked frames. Both traces stayed within 128 KiB, retained all 162 events and recorded no failures or write errors. No screen/camera/microphone capture or permission request occurred. Existing memory envelopes passed.

Times include diagnostic phase-boundary work and are observational. The repeated warmup crop attempts do not by themselves identify which guard rejected work. A passing isolated process does not exclude a failure dependent on the preceding broad-smoke workload, scheduling or runtime state. No automatic retry, timeout change, source edit or publication was performed during monitoring.

## Evidence

Paths below describe the retained diagnostic artifacts, not files in this source repository.

- ARM: `arm/evidence/recording-wait/`
- Intel: `intel/evidence/recording-wait/`
- `analysis.json`: exact artifact hashes, executable hashes, source/run/job IDs, all named wait timings and validation results
- Per-architecture `recording-wait-tests.log` and bounded-command JSON preserve native test results

Both downloaded artifact ZIPs were verified for exact size, SHA-256 and ZIP CRC before safe extraction.

The next full installed candidate retains the opt-in trace in the original broad-smoke ordering. That observation is still pending; this isolated result does not substitute for it.
