import AppKit
import XCTest
import PicShotCore
@testable import PicShot

/// Native owned sheets use the same bounded application-loop contract as the
/// existing chain controller tests. No private AppKit subviews are inspected.
@MainActor
final class LiveScrollChainChoiceControllerTests: XCTestCase {
    func testNativeReturnConfirmsExplicitSelectionOnceAndEscapeCancelsWithoutAutomaticRun() throws {
        try withApplicationLoop {
            let parent = try self.parentWindow(); defer { parent.close() }
            let definitions = try self.definitions()
            let choice = self.choice(definitions: definitions)
            var responses: [NSApplication.ModalResponse] = [], selected: [UUID] = []
            let picker = try XCTUnwrap(choice.accessoryView as? NSPopUpButton)
            choice.beginSheetModal(for: parent) { response in
                responses.append(response)
                if response == .alertFirstButtonReturn { selected.append(definitions[picker.indexOfSelectedItem].id) }
            }
            defer { choice.cancel() }
            try self.ready(choice)
            XCTAssertEqual(picker.indexOfSelectedItem, 0)
            XCTAssertEqual(picker.numberOfItems, 2)
            XCTAssertTrue(responses.isEmpty); XCTAssertTrue(selected.isEmpty)
            picker.selectItem(at: 1)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(picker.action), to: picker.target, from: picker))
            XCTAssertEqual(picker.indexOfSelectedItem, 1)
            XCTAssertEqual(choice.selectedNameLabel?.stringValue, definitions[1].name)
            XCTAssertTrue(responses.isEmpty, "Opening or selecting a chain must not execute the primary action")
            XCTAssertTrue(choice.window.performKeyEquivalent(with: try self.key("\r", code: 36, window: choice.window)))
            try self.until { responses.count == 1 && parent.attachedSheet == nil }
            XCTAssertEqual(responses, [.alertFirstButtonReturn]); XCTAssertEqual(selected, [definitions[1].id])
            XCTAssertFalse(choice.window.isVisible)
            XCTAssertTrue(choice.buttons.allSatisfy { !$0.isEnabled && $0.target == nil && $0.action == nil })
            choice.cancel()
            choice.beginSheetModal(for: parent) { _ in XCTFail("An ended choice must not be presented again") }
            _ = choice.window.performKeyEquivalent(with: try self.key("\r", code: 36, window: choice.window))
            XCTAssertEqual(responses.count, 1); XCTAssertNil(parent.attachedSheet)

            let cancelled = self.choice(definitions: definitions)
            var cancelledResponses: [NSApplication.ModalResponse] = []
            cancelled.beginSheetModal(for: parent) { cancelledResponses.append($0) }
            defer { cancelled.cancel() }
            try self.ready(cancelled)
            XCTAssertTrue(cancelled.window.performKeyEquivalent(with: try self.key("\u{1b}", code: 53, window: cancelled.window)))
            try self.until { cancelledResponses.count == 1 && parent.attachedSheet == nil }
            XCTAssertEqual(cancelledResponses, [.alertSecondButtonReturn])
            XCTAssertFalse(cancelled.window.isVisible)
            XCTAssertEqual(selected, [definitions[1].id])
        }
    }

    func testLongNamesAndReceiptWarningsFitFullNativeFramesAt460PointsInBothAppearances() throws {
        try withApplicationLoop {
            let screen = try XCTUnwrap(NSScreen.main)
            let controls = LiveScrollCaptureController(actions: .init())
            defer { controls.teardown() }
            // Match the installed scroll-chain witness: the real nonactivating
            // toolbar sits below a centered 480-by-320 owned capture region.
            let target = CGRect(x: screen.visibleFrame.midX - 240, y: screen.visibleFrame.midY - 160,
                width: 480, height: 320)
            var snapshot = LiveScrollCaptureSnapshot()
            snapshot.canApplyImageChain = true
            controls.show(snapshot: snapshot, targetFrame: target, visibleFrame: screen.visibleFrame,
                movementBounds: screen.frame)
            let parent = try XCTUnwrap(controls.toolbarWindow)
            let definitions = try self.definitions(longNames: true)
            let receipt = "PNG 已保存：/private/owned/" + String(repeating: "long-receipt-path/", count: 20)
                + "image.png\n已复制到剪贴板（当时的成功写入）\n贴图已保存：" + UUID().uuidString
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for mode in ["initial", "replacement", "abandonment"] {
                    // Reapply product placement for each sheet rather than
                    // letting an earlier AppKit presentation move the parent.
                    controls.show(snapshot: snapshot, targetFrame: target, visibleFrame: screen.visibleFrame,
                        movementBounds: screen.frame)
                    parent.appearance = NSAppearance(named: appearance)
                    XCTAssertTrue(parent.styleMask.contains(.nonactivatingPanel))
                    XCTAssertFalse(parent.canBecomeKey)
                    XCTAssertEqual(parent.frame, try XCTUnwrap(controls.placement).toolbar)
                    XCTAssertLessThan(parent.frame.maxY, screen.visibleFrame.midY)
                    let chooser = mode != "abandonment"
                    let info = mode == "initial" ? "来源：本次长截图。仅执行所选链的图片输出，按保存的顺序处理。"
                        : receipt + "\n开始新动作链会从第一步执行，可能再次保存、复制或贴图。"
                    let choice = LiveScrollChainChoiceController(
                        title: mode == "initial" ? "使用截图链处理当前长图" : mode == "replacement" ? "选择其他动作链重新处理" : "放弃未完成操作并继续采集？",
                        informativeText: info, definitions: chooser ? definitions : [],
                        confirmTitle: mode == "initial" ? "处理当前长图" : mode == "replacement" ? "开始新动作链" : "放弃并继续采集",
                        confirmIdentifier: chooser ? "scroll.live.imageChain.run" : "scroll.live.imageChain.abandon.confirm",
                        cancelIdentifier: chooser ? "scroll.live.imageChain.choice.cancel" : "scroll.live.imageChain.abandon.cancel")
                    choice.window.appearance = NSAppearance(named: appearance)
                    var responses: [NSApplication.ModalResponse] = []
                    choice.beginSheetModal(for: parent) { responses.append($0) }
                    try self.ready(choice)
                    let root = try XCTUnwrap(choice.window.contentView)
                    XCTAssertEqual(root.bounds.width, 460, accuracy: 0.5)
                    XCTAssertEqual(choice.window.contentMinSize.width, 460)
                    XCTAssertEqual(choice.window.contentMaxSize.width, 460)
                    if chooser {
                        let picker = try XCTUnwrap(choice.accessoryView as? NSPopUpButton)
                        XCTAssertEqual(picker.frame.width, 412, accuracy: 0.5)
                        for index in definitions.indices {
                            picker.selectItem(at: index)
                            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(picker.action), to: picker.target, from: picker))
                            let name = try XCTUnwrap(choice.selectedNameLabel), order = try XCTUnwrap(choice.outputOrderLabel)
                            let fullOrder = definitions[index].outputs.map(\.title).joined(separator: " → ")
                            XCTAssertEqual(name.stringValue, definitions[index].name)
                            XCTAssertEqual(name.toolTip, definitions[index].name)
                            XCTAssertEqual(name.accessibilityValue() as? String, definitions[index].name)
                            XCTAssertTrue(name.isSelectable); XCTAssertTrue(name.cell?.wraps == true)
                            XCTAssertEqual(order.stringValue, fullOrder)
                            XCTAssertEqual(order.accessibilityValue() as? String, fullOrder)
                            XCTAssertEqual(picker.accessibilityValue() as? String, definitions[index].name + " · " + fullOrder)
                            XCTAssertEqual(picker.toolTip, definitions[index].name + " · " + fullOrder)
                            XCTAssertTrue(picker.titleOfSelectedItem?.hasSuffix("…") == true)
                            let layout = try CaptureChainUIPreviewFixture.assertLayout(window: choice.window,
                                phase: "owned-choice-" + mode + "-" + appearance.rawValue + "-" + String(index))
                            XCTAssertEqual(layout["fullVisibleFramesChecked"] as? Bool, true)
                            XCTAssertEqual(layout["controlsDoNotOverlap"] as? Bool, true)
                        }
                    } else {
                        XCTAssertNil(choice.accessoryView); XCTAssertNil(choice.selectedNameLabel); XCTAssertNil(choice.outputOrderLabel)
                        let layout = try CaptureChainUIPreviewFixture.assertLayout(window: choice.window,
                            phase: "owned-choice-abandonment-" + appearance.rawValue)
                        XCTAssertEqual(layout["fullVisibleFramesChecked"] as? Bool, true)
                        XCTAssertEqual(layout["controlsDoNotOverlap"] as? Bool, true)
                    }
                    let detail: NSTextField = try self.view("scroll.live.imageChain.sheet.description", in: root)
                    XCTAssertEqual(detail.stringValue, info); XCTAssertEqual(detail.toolTip, info)
                    XCTAssertEqual(detail.accessibilityValue() as? String, info)
                    XCTAssertTrue(responses.isEmpty, "Layout and selection must leave execution explicit")
                    choice.cancel()
                    try self.until { responses.count == 1 && parent.attachedSheet == nil }
                    XCTAssertEqual(responses, [.cancel])
                }
            }
        }
    }

    func testRetiredSheetCommandsCannotCompleteOrCancelReentrantlyPresentedSuccessor() throws {
        try withApplicationLoop {
            let parent = try self.parentWindow(); defer { parent.close() }
            let first = self.choice(definitions: try self.definitions())
            let second = self.choice(definitions: try self.definitions())
            var firstResponses: [NSApplication.ModalResponse] = [], secondResponses: [NSApplication.ModalResponse] = []
            first.beginSheetModal(for: parent) { response in
                firstResponses.append(response)
                XCTAssertTrue(first.buttons.allSatisfy { !$0.isEnabled && $0.target == nil && $0.action == nil })
                second.beginSheetModal(for: parent) { secondResponses.append($0) }
            }
            defer { first.cancel(); second.cancel() }
            try self.ready(first)
            let staleRun = try XCTUnwrap(first.buttons.first)
            let oldTarget = try XCTUnwrap(staleRun.target), oldAction = try XCTUnwrap(staleRun.action)
            XCTAssertTrue(first.window.performKeyEquivalent(with: try self.key("\u{1b}", code: 53, window: first.window)))
            try self.until { firstResponses.count == 1 && parent.attachedSheet === second.window }
            try self.ready(second)
            XCTAssertEqual(firstResponses, [.alertSecondButtonReturn]); XCTAssertTrue(secondResponses.isEmpty)
            XCTAssertTrue(NSApp.sendAction(oldAction, to: oldTarget, from: staleRun))
            _ = first.window.performKeyEquivalent(with: try self.key("\r", code: 36, window: first.window))
            first.cancel()
            XCTAssertTrue(parent.attachedSheet === second.window); XCTAssertTrue(second.window.isVisible)
            XCTAssertEqual(firstResponses.count, 1); XCTAssertTrue(secondResponses.isEmpty)
            XCTAssertTrue(second.window.performKeyEquivalent(with: try self.key("\r", code: 36, window: second.window)))
            try self.until { secondResponses.count == 1 && parent.attachedSheet == nil }
            XCTAssertEqual(secondResponses, [.alertFirstButtonReturn]); XCTAssertEqual(firstResponses.count, 1)
        }
    }

    private func definitions(longNames: Bool = false) throws -> [CaptureChainDefinition] {
        [try CaptureChainDefinition(name: longNames ? String(repeating: "长", count: 64) : "Save Copy Pin",
            source: .preset(UUID()), outputs: [.quickSavePNG, .copy, .pin]),
         try CaptureChainDefinition(name: longNames ? String(repeating: "W", count: 64) : "Pin then Copy",
            source: .region, outputs: [.pin, .copy])]
    }
    private func choice(definitions: [CaptureChainDefinition]) -> LiveScrollChainChoiceController {
        .init(title: "使用截图链处理当前长图", informativeText: "来源：本次长截图。按所选顺序处理。", definitions: definitions,
            confirmTitle: "处理当前长图", confirmIdentifier: "scroll.live.imageChain.run",
            cancelIdentifier: "scroll.live.imageChain.choice.cancel")
    }
    private func parentWindow() throws -> NSWindow {
        let screen = try XCTUnwrap(NSScreen.main)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.animationBehavior = .none
        window.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.midX - 210, y: screen.visibleFrame.maxY - 50))
        window.makeKeyAndOrderFront(nil)
        return window
    }
    private func ready(_ choice: LiveScrollChainChoiceController) throws {
        choice.window.animationBehavior = .none; choice.window.makeKeyAndOrderFront(nil)
        try until { choice.window.isVisible && choice.window.isKeyWindow && choice.window.sheetParent != nil }
        choice.window.contentView?.layoutSubtreeIfNeeded(); choice.window.displayIfNeeded()
    }
    private func key(_ characters: String, code: UInt16, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
    private func until(_ condition: () -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        _ = try XCTUnwrap(condition() ? true : nil, "Owned choice did not reach its bounded native sheet/key barrier")
    }
    private func view<T: NSView>(_ identifier: String, in root: NSView) throws -> T {
        func find(_ view: NSView) -> T? {
            if view.identifier?.rawValue == identifier { return view as? T }
            return view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(find(root))
    }

    /// Borrow a live application loop, or own and stop only the loop established
    /// here. This is the established CaptureChainControllerTests host contract.
    private func withApplicationLoop(_ body: @escaping @MainActor () throws -> Void) throws {
        _ = NSApplication.shared
        if NSApp.isRunning { try body(); return }
        _ = try XCTUnwrap(NSApp.modalWindow == nil && NSApp.delegate == nil ? true : nil,
            "Standalone UI host unexpectedly has a modal window or application delegate")
        _ = try XCTUnwrap(UserDefaults.standard.object(forKey: "NSOpen") == nil ? true : nil,
            "Standalone UI host unexpectedly has a file-open request")
        let originalPolicy = NSApp.activationPolicy(), state = LiveScrollChainChoiceTestApplicationLoop()
        defer {
            state.acceptsCallbacks = false; state.timer?.invalidate(); state.timer = nil
            if NSApp.activationPolicy() != originalPolicy { _ = NSApp.setActivationPolicy(originalPolicy) }
            XCTAssertEqual(NSApp.activationPolicy(), originalPolicy)
        }
        if originalPolicy == .prohibited {
            _ = try XCTUnwrap(NSApp.setActivationPolicy(.accessory) ? true : nil,
                "Native choice interaction requires an activatable owned application")
        }
        let wake = try XCTUnwrap(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0))
        func finish(_ result: Result<Void, Error>) {
            guard state.acceptsCallbacks, state.result == nil else { return }
            state.timer?.invalidate(); state.timer = nil; state.result = result
            NSApp.stop(nil); NSApp.postEvent(wake, atStart: true)
        }
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            MainActor.assumeIsolated {
                guard state.acceptsCallbacks else { return }
                let deadline = ProcessInfo.processInfo.systemUptime + 1
                let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        guard state.acceptsCallbacks, state.result == nil else { return }
                        if NSApp.isRunning && !state.activationRequested {
                            state.activationRequested = true; NSApp.activate(ignoringOtherApps: true)
                        }
                        if NSApp.isRunning && NSApp.isActive {
                            state.timer?.invalidate(); state.timer = nil; finish(Result { try body() })
                        } else if ProcessInfo.processInfo.systemUptime >= deadline {
                            finish(.failure(NSError(domain: "PicShot.ScrollChainChoiceTestHost", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Owned application loop did not become active within one second"])))
                        }
                    }
                }
                state.timer = timer; RunLoop.main.add(timer, forMode: .default)
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain()); NSApp.run()
        state.acceptsCallbacks = false; state.timer?.invalidate(); state.timer = nil
        XCTAssertFalse(NSApp.isRunning)
        try XCTUnwrap(state.result, "Owned application loop exited before its test body completed").get()
    }
}

@MainActor private final class LiveScrollChainChoiceTestApplicationLoop {
    var result: Result<Void, Error>?
    var timer: Timer?
    var acceptsCallbacks = true
    var activationRequested = false
}
