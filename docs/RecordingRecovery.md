# Recording and preview crash recovery (REC-16)

## Status and honest scope

Source implementation and native fixtures are present. **No Swift compiler or macOS runtime is available in the authoring environment. Native compilation, the new tests, and the installed-app SIGKILL fixture must pass on both ARM64 and Intel before this is called verified.** Writer/service/AppMain integration belongs to the recording integration change, not this module alone. Hardware capture, microphone/camera permission timing, disk-removal, genuine power loss, and force-termination of the visible preview window remain manual acceptance gates.

Recovery creates a new independently remuxed MP4 from complete on-disk fragments. It does not resume capture, reconstruct missing/unfinished fragments, restore paused capture devices, grant permissions, or claim that every frame in arbitrary damaged media is repairable. Legacy non-journaled MP4s are not automatically adopted. A file existing on disk is not counted as successful recovery.

## Source format and transaction

`RecordingRecoveryWriterSupport.configure(writer)` configures one-second initial and subsequent movie fragments before `startWriting`. H.264/AAC and the recording's already-composed camera/annotation pixels remain inside those fragments. Apple documents that fragmentation allows partially written movies to be opened after interruption, and that the first fragment must be written before a partial movie can be playable:

- [movieFragmentInterval](https://developer.apple.com/documentation/avfoundation/avassetwriter/moviefragmentinterval)
- [initialMovieFragmentInterval](https://developer.apple.com/documentation/avfoundation/avassetwriter/initialmoviefragmentinterval)

Each `.recording-<canonical UUID>` directory has a bounded, versioned `recovery.json` and a `recovery.lock`. A live writer retains an exclusive nonblocking flock. Discovery skips live sessions without creating lock files. The journal binds to the source device/inode, owned media basename, creation date, duration/byte limits and phase. Candidate snapshots add exact size, modification time and change time; those are rechecked before copy and publication. These are local consistency checks, not cryptographic authenticity against a malicious process running as the same user.

Phases: `capturing → finalized → publishing → published`; an explicit successful recovery becomes `recovered`; explicit discard becomes `discarded`; intentional saved-preview close becomes `dismissed`. Publication records its exact planned destination before the exclusive rename. Crashes on either side find the staged or published file by the same identity. Journal writes use exclusive private temporary files, fsync, atomic rename and directory fsync. Exact intended retries reconcile a prior committed rename without inventing a second destination.

### Critical: cancellation protection

[AVAssetWriter.cancelWriting](https://developer.apple.com/documentation/avfoundation/avassetwriter/cancelwriting()) can delete the writer's output. Merely keeping the staging directory does **not** preserve it.

Before any cancellation of a writing/unknown writer, call `lease.protectBeforeCancellingWriter()`. It creates `recording-preserved.mp4` as a same-directory hard link to the active owned inode, verifies both exact aliases, fsyncs, and durably switches the journal to the protected name. No full movie copy is required. A crash after linking but before journal replacement is still discoverable through the original name. After cancellation removes the original pathname, the protected inode remains. If cancellation leaves both names, discovery accepts two links only when the exact original/protected pair points to that same inode; unrelated/external links are rejected.

Protection is idempotent and deliberately permits an oversize take to be retained even when export admission rejects it. On a link/fsync/journal error, the caller **must not cancel or deallocate the writing encoder, claim preservation, or silently clear the pending take**. Stop capture hardware and keep one pending writer/lease; block new recording, expose the actual error and offer retry-save/protection. No unbounded collection of retained encoders. The integration tests cover that service contract separately.

## Recovery engine

1. Lock the chosen session and revalidate its exact journal, source identity and candidate version
2. Require free disk for the bounded prefix copy, recovered movie and 64 MiB reserve
3. Constant-memory ISO-BMFF parser walks at most 16,384 top-level atoms and never reads entire media into RAM. It preserves all original byte offsets and selects the prefix ending at the last complete initial movie/media or moof/mdat pair. Open-ended or torn capture tails are excluded
4. Copy the prefix in at most 1 MiB buffers into a fresh private workspace; never edit/truncate the source
5. AVFoundation validates one video track, at most two audio tracks, finite duration and bounded dimensions, then passthrough-remuxes into a fresh MP4
6. Verify output duration/audio track count and actually decode first and last video regions. This is endpoint verification, not a full-frame integrity scan of arbitrary user media
7. Fsync the output and exclusively move it to `PicShot-Recovered-<UUID>.mp4` using anchored directory descriptors; fsync the destination directory before suppressing the recovery reminder

Original media is retained on successful recovery, cancellation, malformed media, unsupported format, low disk, export failure, journal failure and destination collision. A successful movie remains published even if its journal update fails; the UI reports the reminder-update warning rather than hiding that saved output.

Scratch creation/publication/cleanup are descriptor-anchored. Native AVFoundation requires pathname URLs, so root/work directory identities are checked at those handoffs and again before publication. The private workspace uses mode 0700. Cleanup uses `unlinkat` without recursive-directory deletion and removes the workspace only when empty. No shell, downloaded executable, network service or third-party dependency is used.

## Bounds

- 4 GiB per admitted source/output, existing recording-specific lower byte limit respected
- Maximum 3,600 seconds plus 1 second metadata tolerance; video <=3,840 per dimension and <=8,294,400 pixels
- One video and at most two audio tracks; one recovery operation per UI model
- 16 KiB journal; 4,096 scanned root entries; 128 pending candidates/warnings; 16,384 atoms; 16 MiB moov and 4 MiB moof bounds
- 1 MiB copy buffer; decoder endpoints reduced to 320 pixels; no retained decoded frame array
- Two-minute shared cancellation deadline covers metadata loads, export and endpoint decoding. Timeout requests the framework's cancellation APIs. Cleanup waits for framework completion rather than force-closing a file still being written. This is not a guarantee that an OS/framework call or faulty storage device will return by a hard wall-clock deadline

Limits stop work and retain media. No automatic age-based eviction or permanent deletion of old recordings is performed. Discard only archives the reminder and preserves the source/journal, with the UI explaining that behavior and offering the recording folder in Finder.

## Integration hooks

All persistence types are in `PicShotCore`.

- Before encoder start: `RecordingRecoveryWriterSupport.configure(writer)`
- After `writer.startWriting()`: `RecordingRecoveryStore(root: directory.deletingLastPathComponent()).begin(stagingDirectory: directory, byteLimit: options.maximumFileSize, durationLimit: options.maximumDuration)`, retaining the returned lease on the writer's serial queue
- After successful finish: `try lease.markFinalized()`
- Durable save: `try lease.publishFinalized(mediaURL: selectedOwnedURL)`, then `lease.closeLease()`; do not recursively remove staging
- Before `cancelWriting`: `try lease.protectBeforeCancellingWriter()`; if protection fails, retain/block/retry as above
- Explicit unfinished discard: protect, cancel, `try lease.discard()`, then close; error abandonment keeps a pending journal rather than marking discard
- Normal launch: retain one `RecordingRecoveryCoordinator`, set `onOpenPreview`, then `presentPending()`
- Recording menu: `presentPending(showIfEmpty: true)`
- Intentional preview close: `previewDidClose(url:)`; application termination is **not** an intentional dismissal
- Earliest main entry, before `AppDelegate` or user-state initialization: `if RecordingRecoveryFixture.runIfRequested() { return }`

The coordinator opens an explicit Chinese AppKit/SwiftUI recovery window. It never automatically opens a camera, microphone, screen capture stream or recovered movie. Controls expose recover-copy, saved-preview open, reveal, explicit discard confirmation, cancellation, and keep-for-later. Saved preview opening does not start playback automatically. Closing the recovery window cancels work without dismissing pending journals.

Existing writer tests that asserted an empty staging root after discard must now assert an archived journal, retained source and no pending recovery. The no-resume/no-finish and durable saved-output invariants remain required. Journal-owned staging must not use legacy recursive `RecordingFileStorage.publish` cleanup.

## Automated verification and remaining gates

Core tests cover malformed/versioned journals, exact owned names, traversal/symlink/hardlink rejection, live-lock discovery, preserved-source identity, same-inode edits, native-free prefix framing, incomplete/extended/open-ended atoms, parser bounds, explicit archival, normal publication/preview dismissal, original preservation on collision, root substitution, nonrecursive scratch cleanup, protection crash boundaries and unrelated extra links.

Native `RecordingRecoveryNativeTests` creates small H.264/AAC media using the shared fragment configuration, calls real `cancelWriting`, checks protected-file survival, recovers and fully decodes video and audio, tests a torn final fragment, and verifies cancellation/malformed media preservation. These are authored tests until the native run passes.

Installed-app abrupt fixture:

- Run the actual signed installed app executable with `PICSHOT_RECOVERY_FIXTURE_MODE=verify` and `PICSHOT_RECOVERY_FIXTURE_REPORT=<report path>`
- It creates its own random token-named temporary root, launches **that executable only** in child mode, and waits for a matching token/PID readiness file after multiple complete fragments exist
- It sends SIGKILL **only to its own still-running Process**, confirms uncaught SIGKILL exit, then discovers the interrupted capture, recovers it and fully decodes every bounded synthetic video/audio sample
- It also publishes a saved-preview journal, reopens a new store, verifies rediscovery and explicit dismissal without deleting the movie. This preview test models process reopening; it does not claim a visible preview UI was force-killed
- It compares every synthetic source byte before/after recovery, confirms cleanup of its own temporary root, and writes JSON with status, source commit/bundle provenance, child exit/signal, no capture/camera/microphone starts, decoded sample counts, recovered duration, fragment count, source preservation and preview-journal result

The parent packaging script supplies a separate 180-second own-process watchdog. No force-kill target is taken from user input or selected from the user's running applications. Ordinary native app launch/package validation and real camera/microphone/screen acceptance remain separate required checks.
