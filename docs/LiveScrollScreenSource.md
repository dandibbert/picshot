# Continuous scrolling screen source

`LiveScrollScreenSource` is a new, passive source. The legacy manual and automatic
drivers are unchanged. The session owns this source, serially calls `nextFrame`,
processes/releases each returned image, and awaits `pauseAndDrain` or `stop`.

## Contract

- `init(displayID:region:screenSize:expectedPixelSize:lockedTarget:)` accepts the
  selected display's local, top-left logical region
- `start()` / `resume()` are async and throwing. Initial content discovery happens
  once; pauses retain the filter and create a fresh stream on resume
- `nextFrame(timeout: 0.75)` is async and throwing and returns `Frame?`. Nil means
  no complete frame arrived by the idle deadline, which is normal for static content
- Frame fields: owned `image`, `sequence`, `generation`, `timestamp`, normalized `region`
- `pauseAndDrain()` invalidates the generation immediately, releases the pending
  buffer, stops/detaches the stream and drains its callback queue and pending reader
- `moveRegion(to:)` requires completed pause. The display, pixel size, PID and window
  ID remain locked; only position and explicitly followed target bounds can change
- `stop()` also makes the source terminal. Cancellation of a read/start drains and
  stops it; use explicit `pauseAndDrain()` for a resumable pause
- Each SDK operation has a three-second deadline. Stopping during a pending start
  can require its remaining deadline plus the three-second stop/drain deadline
  (at most six seconds, excluding normal executor scheduling). A timeout reports
  failure and blocks resume; it never claims capture stopped successfully

## Bounds and evidence

The stream requests the cropped native-resolution region in BGRA/sRGB, 15 fps,
queueDepth 3, no audio/cursor, with this process's applications excluded. There is
one latest pending CVPixelBuffer and one serially consumed frame. Overwrites release
the previous pending buffer. The source retains no returned CGImage and performs
no frame hash. Each consumed CGImage owns one copy of the cropped raster, so later
ScreenCaptureKit buffer reuse cannot change an already returned image.

Counters contain only frame counts and dimensions: received, replaced, consumed,
rejected, incomplete, idle timeouts, current/peak pending, waiting readers, width,
height and stream queue depth. Content-discovery/start/confirmed-stop counts are
also available. No screenshot, hash or window title is logged.

Eight XCTest cases in `LiveScrollScreenSourceTests` cover replacement/ARC ownership,
close and generation isolation, cancellation, concurrent wait rejection, idle
completion, cropped native configuration and image survival after buffer reuse.
They use synthetic buffers only and never invoke ScreenCaptureKit or TCC discovery.
Run them on macOS with `swift test --filter LiveScrollScreenSourceTests`.

Linux source-policy checks passed. Native compilation, these XCTest cases, physical
display capture/TCC, real scrolling, Retina/multiple displays and OS stop/start
behavior remain unverified until their distinct native runs. Synthetic evidence
must not be reported as real capture evidence.

## Apple API references

- [SCStreamConfiguration](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration)
- [Queue depth](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/queuedepth)
- [Source rectangle](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/sourcerect)
- [Shareable-content discovery](https://developer.apple.com/documentation/screencapturekit/scshareablecontent/getexcludingdesktopwindows(_:onscreenwindowsonly:completionhandler:))
- [Stream start](https://developer.apple.com/documentation/screencapturekit/scstream/startcapture(completionhandler:))
