import AppKit
import CoreGraphics
import PicShotCore

/// Cheap current system geometry. The reconfiguration callback also detects a
/// layout that changes and changes back between two of these snapshots.
struct DisplaySystemSnapshot: Equatable {
    struct Display: Equatable {
        let id: CGDirectDisplayID
        let bounds: CGRect
        let backingScale: CGFloat
        let isActive: Bool
        let pixelWidth: Int
        let pixelHeight: Int
        let rotation: Double
        let mirroredTo: CGDirectDisplayID
    }
    let displays: [Display]

    @MainActor static func current() -> DisplaySystemSnapshot {
        DisplaySystemSnapshot(displays: NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            return Display(id: id, bounds: CGDisplayBounds(id), backingScale: screen.backingScaleFactor,
                           isActive: CGDisplayIsActive(id) != 0, pixelWidth: CGDisplayPixelsWide(id), pixelHeight: CGDisplayPixelsHigh(id),
                           rotation: CGDisplayRotation(id), mirroredTo: CGDisplayMirrorsDisplay(id))
        }.sorted { $0.id < $1.id })
    }
}

private final class DisplayChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var changed: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func markChanged() { lock.lock(); value = true; lock.unlock() }
}

private let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, _, userInfo in
    guard let userInfo else { return }
    Unmanaged<DisplayChangeFlag>.fromOpaque(userInfo).takeUnretainedValue().markChanged()
}

final class DisplayConfigurationWatcher {
    private let flag = DisplayChangeFlag()
    private var registered = false

    init() throws {
        let result = CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, Unmanaged.passUnretained(flag).toOpaque())
        guard result == .success else {
            throw CaptureError.failed("Could not monitor display changes (\(result.rawValue)).")
        }
        registered = true
    }

    deinit {
        if registered {
            CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, Unmanaged.passUnretained(flag).toOpaque())
        }
    }

    @MainActor func validate(snapshot: DisplaySystemSnapshot) throws {
        try Task.checkCancellation()
        guard !flag.changed, DisplaySystemSnapshot.current() == snapshot, !flag.changed else {
            throw DisplayCompositeError.layoutChanged
        }
    }
}
