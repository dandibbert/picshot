import Foundation

/// AppKit global screen points. The owner converts capture/display-local coordinates
/// once, before presenting the live controls. Negative display origins are supported.
public enum LiveScrollCaptureGeometry {
    public static let toolbarSize = CGSize(width: 310, height: 82)
    public static let compactToolbarSize = CGSize(width: 160, height: 122)
    public static let gap: CGFloat = 8

    public struct Placement: Equatable {
        public let toolbar: CGRect
        public let preview: CGRect
        public let overlapsTarget: Bool
    }

    public static func isUsable(_ frame: CGRect) -> Bool {
        isFinite(frame) && frame.width >= compactToolbarSize.width && frame.height >= compactToolbarSize.height
    }

    public static func isFinite(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isInfinite && frame.minX.isFinite && frame.minY.isFinite &&
            frame.width.isFinite && frame.height.isFinite && frame.width > 0 && frame.height > 0
    }

    /// Prefer a horizontal strip below the target, then a compact strip beside it.
    /// Full-display targets cannot have outside controls: the fallback stays visible
    /// and explicitly reports overlap, so the capture owner must exclude these windows.
    public static func placement(target: CGRect, visibleFrame: CGRect) -> Placement? {
        guard isUsable(visibleFrame), isFinite(target) else { return nil }
        let wide = toolbarSize, compact = compactToolbarSize
        func below(_ size: CGSize) -> CGRect {
            CGRect(x: target.maxX - size.width, y: target.minY - gap - size.height, width: size.width, height: size.height)
        }
        func above(_ size: CGSize) -> CGRect {
            CGRect(x: target.maxX - size.width, y: target.maxY + gap, width: size.width, height: size.height)
        }
        func side(_ size: CGSize, right: Bool) -> CGRect {
            CGRect(x: right ? target.maxX + gap : target.minX - gap - size.width,
                   y: target.minY, width: size.width, height: size.height)
        }
        let candidates = [below(wide), side(compact, right: true), above(wide), side(compact, right: false),
                          below(compact), above(compact)]
        let toolbar = candidates.compactMap { candidate -> CGRect? in
            guard candidate.width <= visibleFrame.width, candidate.height <= visibleFrame.height else { return nil }
            let result = clamp(candidate, to: visibleFrame)
            return result.intersects(target) ? nil : result
        }.first ?? clamp(visibleFrame.width >= wide.width ? below(wide) : below(compact), to: visibleFrame)

        // Try the right and left outside lanes first. If the toolbar occupies a lane,
        // shorten the thumbnail above or below it without hiding any native action.
        let preferredHeight = min(340, max(148, target.height))
        let lanes = [
            CGRect(x: target.maxX + gap, y: visibleFrame.minY, width: max(0, visibleFrame.maxX - target.maxX - gap), height: visibleFrame.height),
            CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: max(0, target.minX - gap - visibleFrame.minX), height: visibleFrame.height),
            CGRect(x: visibleFrame.minX, y: target.maxY + gap, width: visibleFrame.width, height: max(0, visibleFrame.maxY - target.maxY - gap)),
            CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: visibleFrame.width, height: max(0, target.minY - gap - visibleFrame.minY))
        ]
        var preview: CGRect?
        for rawLane in lanes {
            let lane = rawLane.intersection(visibleFrame)
            guard !lane.isNull, lane.width >= 56, lane.height >= 80 else { continue }
            var slots = [lane]
            if lane.intersects(toolbar) {
                slots = [CGRect(x: lane.minX, y: toolbar.maxY + gap, width: lane.width, height: max(0, lane.maxY - toolbar.maxY - gap)),
                         CGRect(x: lane.minX, y: lane.minY, width: lane.width, height: max(0, toolbar.minY - gap - lane.minY)),
                         CGRect(x: lane.minX, y: lane.minY, width: max(0, toolbar.minX - gap - lane.minX), height: lane.height),
                         CGRect(x: toolbar.maxX + gap, y: lane.minY, width: max(0, lane.maxX - toolbar.maxX - gap), height: lane.height)]
            }
            for slot in slots where slot.width >= 56 && slot.height >= 80 {
                let size = CGSize(width: min(112, slot.width), height: min(preferredHeight, slot.height))
                let proposed = CGRect(x: min(max(target.maxX + gap, slot.minX), slot.maxX - size.width),
                                      y: min(max(target.maxY - size.height, slot.minY), slot.maxY - size.height),
                                      width: size.width, height: size.height)
                guard visibleFrame.contains(proposed), !proposed.intersects(toolbar), !proposed.intersects(target) else { continue }
                preview = proposed; break
            }
            if preview != nil { break }
        }
        if preview == nil {
            // A minimal work area may have room for the controls only. A zero preview
            // is intentional there, rather than covering an action with another window.
            let availableHeight = max(0, visibleFrame.maxY - toolbar.maxY - gap)
            if availableHeight >= 80 {
                preview = CGRect(x: visibleFrame.maxX - min(112, visibleFrame.width),
                                 y: visibleFrame.maxY - min(preferredHeight, availableHeight),
                                 width: min(112, visibleFrame.width), height: min(preferredHeight, availableHeight))
            }
        }
        let result = preview ?? .zero
        return Placement(toolbar: toolbar, preview: result,
                         overlapsTarget: toolbar.intersects(target) || (!result.isEmpty && result.intersects(target)))
    }

    public static func clamp(_ frame: CGRect, to visibleFrame: CGRect) -> CGRect {
        CGRect(x: min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - frame.width),
               y: min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - frame.height),
               width: frame.width, height: frame.height)
    }

    /// Top-left normalized viewport coordinates; invalid rectangles never produce
    /// a misleading green marker. Partially visible viewports clip to the thumbnail.
    public static func normalizedViewport(_ fraction: CGRect) -> CGRect? {
        guard isFinite(fraction) else { return nil }
        let clipped = fraction.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return clipped.isNull || clipped.isEmpty ? nil : clipped
    }

    public static func viewportMarker(fraction: CGRect, imageRect: CGRect) -> CGRect? {
        guard let normalized = normalizedViewport(fraction), isFinite(imageRect) else { return nil }
        return CGRect(x: imageRect.minX + normalized.minX * imageRect.width,
                      y: imageRect.minY + normalized.minY * imageRect.height,
                      width: normalized.width * imageRect.width, height: normalized.height * imageRect.height)
    }
}
