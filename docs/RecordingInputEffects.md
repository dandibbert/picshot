# Recording input effects

This is the 0.17 implementation candidate. Native validation and installer acceptance are pending; the latest accepted ARM package is 0.16.0/build154.

The recording controls offer three independent, default-off options: click rings, scroll direction, and shortcut labels. Effects are drawn into the same bounded recording compositor as the camera and live annotations. They are part of the saved video and therefore remain visible in exports derived from that video. Turning an option off changes future frames; it cannot remove an effect already encoded.

The input state keeps at most 48 scalar events. Clicks last 0.7 seconds, scroll indicators 0.85 seconds, and shortcut labels at most 1.2 seconds. It holds no screen images, native event objects, application text, or persistent keystroke history. The encoder's existing frame-rate, duration, file-size and surface-pool limits remain in force. These bounds do not establish a whole-app memory ceiling.

Shortcut input accepts only a fixed whitelist of physical key codes accompanied by Command or Control. Labels describe those physical keys using a fixed vocabulary, independently of the active keyboard layout. Ordinary typing, Option-only and Shift-only input are excluded. The implementation never reads event character strings or accessibility text values. Secure input and unavailable, unknown or secure accessibility focus suppress shortcut display. A third-party app can provide inaccurate accessibility semantics, so this does not certify every custom password field; pause input effects before sensitive work.

Permission checks are read-only. The app does not grant or automatically request Input Monitoring or Accessibility permission for this feature. When an option needs access, the controls explain the missing permission and allow an explicit settings visit and recheck. PicShot's own controls are excluded from both the movie and global input monitoring.

Pause, Stop, cancellation and recording errors remove the monitor and clear events. Resume rejects callbacks queued before the new boundary. Effects end for future output at the Stop request, before potentially slow encoder or disk finalization. Screen coordinates use the event's original point, transformed to the selected recording rectangle; pointer events outside that rectangle are ignored.

The planned native checks use injected input metadata and permissions, bounded synthetic video, independent frame decoding, and native control previews. They do not grant OS permissions, post global input, or prove event delivery from other applications on a physical Mac.

## Platform references

- [Apple AppKit event monitors](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html): global monitor scope and keyboard accessibility requirement
- [Apple Secure Event Input](https://developer.apple.com/library/archive/technotes/tn2150/_index.html): secure-input behavior
- [Input Monitoring preflight](https://developer.apple.com/documentation/coregraphics/cgpreflightlisteneventaccess()): read-only access check
- [Accessibility attribute reads](https://developer.apple.com/documentation/applicationservices/1462085-axuielementcopyattributevalue): role/subrole queries; no text values are read here
