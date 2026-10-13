# Typed recovery advice for continuous capture

The build280 warning-copy correction follows build279's typed recovery guidance and the independently qualified experimental build278. Build279 passed all195 selected native scrolling methods but failed visible warning readability, as recorded below. This correction changes recovery feedback and its visibility assertions only; matcher thresholds, accepted source frames, strip transactions, preview pixels, movement behavior, Auto input admission and resource limits remain unchanged. Native validation of the shortened text is pending. This document does not claim installer acceptance or a fix for original227 memory failure.

## Problem and behavior

The assembler previously replaced every non-duplicate matching error with a promise that a small reverse scroll would recover. That is incorrect for every error type. The retained ordinary-article fixture has a concrete counterexample: a native-equivalent viewport at document offset320 followed by328 has uncertain fixed-content boundaries, while continuing forward to336 establishes a valid boundary and produces the expected496-pixel accepted image. Returning is not the only useful action.

The existing matcher already distinguishes lost overlap, uncertain boundaries and unsupported fixed content. The candidate carries that distinction into the current warning surface:

- Lost overlap suggests a small return and retry, without promising success
- An uncertain boundary says `固定边界不明确，请慢滚重试`, asking for slow movement so a later frame can resolve it
- Unsupported fixed content says `固定区域不支持；先完成，再重选正文`, explaining that the user can finish the preserved result and choose a new content region; it does not imply in-place resize support
- A changed established content boundary keeps a separate cautious message
- Other errors retain their existing localized explanation rather than being mislabelled as lost overlap

Auto stops as before. Its stop notice retains the current typed advice, including a later manual retry with a different failure cause. Verified manual movement can recover the session, but never restarts Auto without the user's action. The Help wording no longer presents reverse scrolling as a universal remedy.

## Retained build279 readability failure

The retained `native-audit279/final/live-scroll-warning-native/` evidence contains twelve actual AppKit warning PNGs and their geometry/session receipts. Four Auto screenshots visibly truncate the action at the end: uncertain-boundary and unsupported-fixed-content, each in light and dark appearance. Both full strings measured277.39494163424126pt in the275pt-wide status label at11pt. Their receipts reported `textFits: false` and `intentionalTruncation: true` even though the generic `layout.passed` was true, because that check accepted the complete tooltip/accessibility alternative. The195 passing native methods therefore did not establish visible readability.

Build280 shortens those two messages while retaining the `自动滚动已停：` prefix,11pt status font and310×82pt toolbar. Fresh light/dark screenshots and strict visible-text bounds checks are required before claiming that the correction passes. The build279 failure remains evidence; it is not reclassified as a pass.

## Bounded verification

Build279's six guidance methods extended the exact build278 inventories, with no removed or renamed method: full2440→2446, focused1908→1914 and LiveScroll189→195; the full class count stayed272. Current-source guards first remove the explicit six guidance IDs and reproduce the exact build278 hashes, then retain the older stable/image-chain baseline checks. Guidance methods are not relabelled as image-chain methods. This warning-copy correction adds or renames no test method; the combined build280 inventory remains frozen at2487 methods and the LiveScroll selection remains195.

Assembler tests cover both axes, unchanged accepted anchors/geometry/spool/output, Finish after a rejection, actual retained article320→328→336 forward recovery and the intentionally constructed unsupported-fixed-content route. Session tests verify exact warning strings, tooltip/accessibility text, orange unverified position, accepted preview identity, Finish output, stopped Auto and explicit-only restart. The existing methods now also require complete native status text to fit the275×16pt label at the supported minimum310×82pt toolbar in both themes, with the11pt font unchanged. This assertion runs without an evidence environment variable and requires `textFits: true` and `intentionalTruncation: false`; tooltip/AX fallback cannot satisfy it. Existing complete-frame and native hit-target checks still run. The unsupported fixed-content fixture validates its error route, not broader page-support quality. The defensive changed-bounds branch and default localized-error fallback do not gain a new independent native scenario from these six tests.

The existing focused native job retains at most twelve optional toolbar PNGs and corresponding geometry/session receipts: three reasons, manual/Auto state and light/dark appearance. It reuses the existing owned-window capture helper and restores original appearance. Evidence is saved under an explicitly enabled generated-fixture directory before the stricter visible-text assertions and is retained even when a later assertion fails or throws. These are native AppKit states from controlled session input, not real desktop-capture proof.

The checkpoint uses the existing signed native scrolling demonstration, strict complete-parent reader and exact195-method LiveScroll filter. The420-second process bound, existing40-minute focused job cap and all cleanup/output criteria remain unchanged. No new resource pair, disputed227 rerun or broad distribution is requested by this focused checkpoint.

Local baseline comparison preserves three pre-existing failure entries when an archived exact269 diagnostic contract is deliberately run against current278 source. Those historical checks are not part of this checkpoint's route and are not modified. New current-source inventory expectations are updated separately and must pass their actual normal/optimized portable checks before publication. Actual native compilation, exact test events and retained warning pixels must determine the candidate result.
