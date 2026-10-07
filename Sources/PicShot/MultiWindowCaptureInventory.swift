import AppKit
import CoreGraphics
import PicShotCore

struct MultiWindowSelectionScreen: Equatable {
    let id: UInt32
    let appKitFrame: CGRect
    let quartzFrame: CGRect
    let scale: CGFloat

    func quartzPoint(fromLocal point: CGPoint) -> CGPoint {
        CGPoint(x: quartzFrame.minX + point.x, y: quartzFrame.minY + appKitFrame.height - point.y)
    }
    func localRect(fromQuartz rect: CGRect) -> CGRect {
        CGRect(x: rect.minX - quartzFrame.minX, y: appKitFrame.height - (rect.maxY - quartzFrame.minY),
               width: rect.width, height: rect.height)
    }
    @MainActor static func current() -> [Self] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            return Self(id: id, appKitFrame: screen.frame, quartzFrame: CGDisplayBounds(id), scale: screen.backingScaleFactor)
        }.sorted { $0.id < $1.id }
    }
}

@MainActor
enum MultiWindowInventory {
    /// Metadata only. No AX permission, ScreenCaptureKit request, screenshots or
    /// previews. Quartz returns its list in front-to-back order.
    static func current(screens: [MultiWindowSelectionScreen]) throws -> [MultiWindowDescriptor] {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              rows.count <= MultiWindowCaptureLimits.inventory else { throw MultiWindowCaptureError.invalidWindow }
        var windows: [MultiWindowDescriptor] = []
        for row in rows {
            guard let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let dictionary = row[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
                  let started = app.launchDate?.timeIntervalSince1970 else { continue }
            let scales = screens.filter { $0.quartzFrame.intersects(bounds) }.map(\.scale)
            guard let scale = scales.max() else { continue }
            let owner = row[kCGWindowOwnerName as String] as? String ?? "Window"
            let title = row[kCGWindowName as String] as? String ?? ""
            // Oversized or malformed candidates never become selectable; bounds
            // are checked again against the entire selection before capture.
            if let window = try? MultiWindowDescriptor(id: id, ownerPID: pid, ownerStartedAt: started,
                label: title.isEmpty ? owner : owner + " · " + title, bounds: bounds, maximumScale: scale) {
                windows.append(window)
            }
        }
        guard Set(windows.map(\.id)).count == windows.count else { throw MultiWindowCaptureError.changed }
        return windows
    }
}
