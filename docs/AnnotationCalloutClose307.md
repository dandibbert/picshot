# Native callout close diagnosis at 307e824a

The 0.13 candidate at `307e824ac4654931f7c4caeb0a8e33a961f2e685` **failed** its installed early annotation gate on both architectures. This record preserves that failure. Neither the later observations nor a cleanup control changes its acceptance result.

Source-qualified evidence:

- [Run 37626674223](https://github.com/dandibbert/picshot/actions/runs/37626674223), ARM job `112810105140`, Intel job `112810105403`
- ARM UI artifact `11484419330`: 4,974,589 bytes; SHA-256 `5426bf1b20a5d5b9ec6253a07349c65341e3adcb0db857d3b020fdc7de04cf74`
- Intel QA artifact `11485746252`: 5,159,410 bytes; SHA-256 `d0811eca4522b600099fb6a9867d4b3147724e0dcf22b8e5be9bb2a954668b04`
- The nested `annotation-callout-close-diagnostics.json` files each contain 36 observations across the original failure and 11 controls. Both report `acceptanceStatus: failed`, `status: completed`, and no input survivors at the final observation.

## What the native observations establish

Each input was observed after nominal 10, 100 and 1,000 milliseconds. Actual monotonic elapsed times are retained in the reports; a nominal sample is not an exact release timestamp.

| Object group | Original, non-inlined, untyped and plain NSTextView controls | Text-container disconnection control |
| --- | --- | --- |
| Editor, window, box, session, undo manager | Gone at the first observation on both architectures | Gone at the first observation |
| Native text view and observed input context | Present at the 10/100 ms observations; gone at the 1,000 ms observation | Same delayed native-view pattern |
| Text storage, TextKit 2 layout manager and text container | Still present at the 1,000 ms observation | Gone from the first observation onward |

The other isolated controls were delayed-perform cancellation, closing undo groups, closing the spelling document, disabling text checking, discarding marked text and retiring editability. None changed the observed native-view delay or released the text-system graph by the 1,000 ms sample. The combined control included disconnection and matched its prompt graph release.

The latest 1,000 ms sample occurred at 1,059.997 ms on ARM and 1,052.013 ms on Intel. These are observation times, not demonstrated deallocation latency. The diagnostic used a cooperative 20-second budget and the existing outer installed-app command bound. It did not identify the specific native object retaining the view, measure a process-memory plateau, or establish indefinite leakage of the text-system objects.

Apple documents `NSTextContainer.textView = nil` as the public operation for disconnecting a view from the text system. Apple also states that an input context does not retain its client, so observing the context alongside the view is not causal proof. See [text-view disconnection](https://developer.apple.com/documentation/appkit/nstextcontainer/textview) and [input-context client ownership](https://developer.apple.com/documentation/appkit/nstextinputcontext/client).

## Consequence for the correction and acceptance contract

The blanket assumption that every native NSTextView must deallocate at the scheduled 10 ms check is contradicted by the plain AppKit and untyped controls. Simply extending that sleep would hide the independently observed text-backing lifetime.

The proposed correction therefore disconnects the comment's text container only when its editing session is terminal, after capturing any accepted text and geometry. The revised gate must distinguish:

1. Synchronous detachment plus the existing scheduled 10 ms owner check, with actual elapsed time recorded. Editor/window/session/undo and the detached text storage/layout/container graph must be released. Immediate post-scope state is additional observation, not an unmeasured zero-millisecond promise.
2. A separately named framework-retirement gate, using monotonic samples and a strict 2,000 ms deadline for each detached native input and any observed context. Six rapid closes record overlap, first-nil and last-retained samples, and require no pending objects at the end. The six-case maximum is a fixture bound, not an application-wide quota.

The 2,000 ms bound is a new, explicitly different acceptance contract informed by native controls. It was **not validated by this failed diagnostic run**. The implementation, native regressions, evidence checker and final ZIP/DMG acceptance must all be verified at the eventual final source. Existing RSS/footprint caveats and the unchanged production image decoder remain independent.
