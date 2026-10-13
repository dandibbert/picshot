import AppKit
import PicShotCore
import XCTest
@testable import PicShot

/// The text route shares the owned native sheet and the existing bounded
/// application-loop/layout fixtures; it does not create image-output definitions.
@MainActor
final class LiveScrollTextChoiceTests: XCTestCase {
    func testSavedScriptSelectionRequiresReturnAndEscapeNeverExecutes() throws {
        try withApplicationLoop {
            let parent = try self.parentWindow(); defer { parent.close() }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-ScrollTextChoice-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try TextScriptStore(directory: directory)
            for script in try self.scripts() { try store.add(script) }
            let scripts = store.definitions
            try store.select(id: scripts[0].id)
            let before = store.index
            let manifest = directory.appendingPathComponent(TextScriptStore.manifestFilename)
            let beforeBytes = try Data(contentsOf: manifest)
            let choice = LiveScrollChainChoiceController(textScripts: scripts)
            let picker = try XCTUnwrap(choice.accessoryView as? NSPopUpButton)
            var responses: [NSApplication.ModalResponse] = [], executed: [UUID] = []
            choice.beginSheetModal(for: parent) { response in
                responses.append(response)
                if response == .alertFirstButtonReturn { executed.append(scripts[picker.indexOfSelectedItem].id) }
            }
            defer { choice.cancel() }
            try self.ready(choice)
            XCTAssertEqual(choice.window.identifier?.rawValue, "scroll.live.textScript.sheet")
            XCTAssertEqual(picker.identifier?.rawValue, "scroll.live.textScript.choice")
            XCTAssertEqual(picker.accessibilityLabel(), "选择已保存的文字脚本")
            XCTAssertEqual(picker.numberOfItems, 2); XCTAssertEqual(picker.indexOfSelectedItem, 0)
            XCTAssertEqual(choice.buttons.map { $0.identifier?.rawValue },
                ["scroll.live.textScript.run", "scroll.live.textScript.choice.cancel"])
            XCTAssertEqual(choice.buttons.map(\.keyEquivalent), ["\r", "\u{1b}"])
            XCTAssertTrue(picker.nextKeyView === choice.buttons[0])
            XCTAssertTrue(choice.buttons[0].nextKeyView === choice.buttons[1])
            XCTAssertTrue(choice.buttons[1].nextKeyView === picker)
            XCTAssertTrue(responses.isEmpty); XCTAssertTrue(executed.isEmpty)
            picker.selectItem(at: 1)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(picker.action), to: picker.target, from: picker))
            XCTAssertEqual(choice.selectedNameLabel?.stringValue, scripts[1].name)
            XCTAssertEqual(choice.outputOrderLabel?.stringValue, "本机文字识别 → 文字脚本 → 复制文字")
            XCTAssertTrue(responses.isEmpty, "Selecting a saved script only changes its presentation")
            XCTAssertTrue(executed.isEmpty)
            XCTAssertEqual(store.index, before); XCTAssertEqual(try Data(contentsOf: manifest), beforeBytes)
            XCTAssertTrue(choice.window.performKeyEquivalent(with: try self.key("\r", code: 36, window: choice.window)))
            try self.until { responses.count == 1 && parent.attachedSheet == nil }
            XCTAssertEqual(responses, [.alertFirstButtonReturn]); XCTAssertEqual(executed, [scripts[1].id])
            XCTAssertFalse(choice.window.isVisible)
            XCTAssertTrue(choice.buttons.allSatisfy { !$0.isEnabled && $0.target == nil && $0.action == nil })
            XCTAssertFalse(picker.isEnabled); XCTAssertNil(picker.target); XCTAssertNil(picker.action)
            choice.cancel()
            choice.beginSheetModal(for: parent) { _ in XCTFail("An ended choice cannot execute again") }
            _ = choice.window.performKeyEquivalent(with: try self.key("\r", code: 36, window: choice.window))
            XCTAssertEqual(responses.count, 1)

            let cancelled = LiveScrollChainChoiceController(textScripts: scripts)
            let cancelledPicker = try XCTUnwrap(cancelled.accessoryView as? NSPopUpButton)
            var cancelledResponses: [NSApplication.ModalResponse] = []
            cancelled.beginSheetModal(for: parent) { response in
                cancelledResponses.append(response)
                if response == .alertFirstButtonReturn { executed.append(scripts[cancelledPicker.indexOfSelectedItem].id) }
            }
            defer { cancelled.cancel() }
            try self.ready(cancelled)
            cancelledPicker.selectItem(at: 1)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(cancelledPicker.action), to: cancelledPicker.target, from: cancelledPicker))
            XCTAssertTrue(cancelledResponses.isEmpty); XCTAssertEqual(executed, [scripts[1].id])
            XCTAssertTrue(cancelled.window.performKeyEquivalent(with: try self.key("\u{1b}", code: 53, window: cancelled.window)))
            try self.until { cancelledResponses.count == 1 && parent.attachedSheet == nil }
            XCTAssertEqual(cancelledResponses, [.alertSecondButtonReturn]); XCTAssertFalse(cancelled.window.isVisible)
            XCTAssertEqual(executed, [scripts[1].id])
            XCTAssertEqual(store.index, before); XCTAssertEqual(try Data(contentsOf: manifest), beforeBytes)
        }
    }

    func testLongSavedScriptNamesAndConsequencesFitCompactNativeTextRectsInBothAppearances() throws {
        try withApplicationLoop {
            let screen = try XCTUnwrap(NSScreen.main)
            let controls = LiveScrollCaptureController(actions: .init())
            defer { controls.teardown() }
            // Keep the same narrow 480-by-320 capture and nonactivating toolbar
            // placement as the established image-chain native sheet witness.
            let target = CGRect(x: screen.visibleFrame.midX - 240, y: screen.visibleFrame.midY - 160,
                width: 480, height: 320)
            var snapshot = LiveScrollCaptureSnapshot(); snapshot.canApplyTextScript = true
            let scripts = try self.scripts(longNames: true)
            XCTAssertTrue(scripts.allSatisfy { $0.name.count == 64 && TextScriptDefinition.validName($0.name) })
            XCTAssertEqual(scripts[2].name.utf8.count, 256)
            let warning = "确认后将识别当前长图、运行所选文字脚本，并覆盖剪贴板中的文字。"
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                controls.show(snapshot: snapshot, targetFrame: target, visibleFrame: screen.visibleFrame,
                    movementBounds: screen.frame)
                let parent = try XCTUnwrap(controls.toolbarWindow)
                parent.appearance = NSAppearance(named: appearance)
                XCTAssertTrue(parent.styleMask.contains(.nonactivatingPanel)); XCTAssertFalse(parent.canBecomeKey)
                let requested = try XCTUnwrap(controls.placement).toolbar
                XCTAssertEqual(parent.frame.minX, requested.minX, accuracy: 0.5)
                XCTAssertEqual(parent.frame.minY, requested.minY, accuracy: 0.5)
                XCTAssertEqual(parent.frame.width, requested.width, accuracy: 0.5)
                XCTAssertEqual(parent.frame.height, requested.height, accuracy: 0.5)
                let choice = LiveScrollChainChoiceController(textScripts: scripts, consequenceWarning: warning)
                defer { choice.cancel() }
                choice.window.appearance = NSAppearance(named: appearance)
                var responses: [NSApplication.ModalResponse] = []
                choice.beginSheetModal(for: parent) { responses.append($0) }
                try self.ready(choice)
                let root = try XCTUnwrap(choice.window.contentView)
                let picker = try XCTUnwrap(choice.accessoryView as? NSPopUpButton)
                XCTAssertEqual(root.bounds.width, 460, accuracy: 0.5)
                XCTAssertEqual(choice.window.contentMinSize.width, 460)
                XCTAssertEqual(choice.window.contentMaxSize, choice.window.contentMinSize)
                XCTAssertEqual(picker.frame.width, 412, accuracy: 0.5)
                let description: NSTextField = try self.view("scroll.live.textScript.sheet.description", in: root)
                XCTAssertEqual(description.stringValue, "来源：本次长截图。识别后执行所选文字脚本，并复制处理后的文字。")
                XCTAssertEqual(description.toolTip, description.stringValue)
                XCTAssertEqual(description.accessibilityValue() as? String, description.stringValue)
                let warningLabel: NSTextField = try self.view("scroll.live.textScript.sheet.warning", in: root)
                XCTAssertTrue(choice.warningLabel === warningLabel)
                XCTAssertEqual(warningLabel.stringValue, warning)
                XCTAssertEqual(warningLabel.toolTip, warning)
                XCTAssertEqual(warningLabel.accessibilityLabel(), warning)
                XCTAssertEqual(warningLabel.accessibilityValue() as? String, warning)
                XCTAssertEqual(warningLabel.maximumNumberOfLines, 0)
                XCTAssertEqual(warningLabel.lineBreakMode, .byWordWrapping)
                XCTAssertGreaterThanOrEqual(warningLabel.frame.minY, description.frame.maxY)
                XCTAssertTrue(choice.informativeText.contains(warning))
                for index in scripts.indices {
                    picker.selectItem(at: index)
                    XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(picker.action), to: picker.target, from: picker))
                    let name = try XCTUnwrap(choice.selectedNameLabel), steps = try XCTUnwrap(choice.outputOrderLabel)
                    let summary = "本机文字识别 → 文字脚本 → 复制文字"
                    XCTAssertEqual(name.identifier?.rawValue, "scroll.live.textScript.choice.name")
                    XCTAssertEqual(steps.identifier?.rawValue, "scroll.live.textScript.choice.outputs")
                    XCTAssertEqual(name.stringValue, scripts[index].name)
                    XCTAssertEqual(name.toolTip, scripts[index].name)
                    XCTAssertEqual(name.accessibilityValue() as? String, scripts[index].name)
                    XCTAssertEqual(steps.stringValue, summary); XCTAssertEqual(steps.toolTip, summary)
                    XCTAssertEqual(steps.accessibilityValue() as? String, summary)
                    XCTAssertEqual(picker.toolTip, scripts[index].name + " · " + summary)
                    XCTAssertEqual(picker.accessibilityValue() as? String, scripts[index].name + " · " + summary)
                    XCTAssertEqual(picker.selectedItem?.toolTip, scripts[index].name + " · " + summary)
                    XCTAssertTrue(picker.titleOfSelectedItem?.hasSuffix("…") == true)
                    for field in [name, steps, warningLabel] {
                        XCTAssertTrue(field.isSelectable); XCTAssertTrue(field.cell?.wraps == true)
                        XCTAssertFalse(field.isHiddenOrHasHiddenAncestor)
                        XCTAssertTrue(field.visibleRect.insetBy(dx: -0.5, dy: -0.5).contains(field.bounds))
                        let cell = try XCTUnwrap(field.cell)
                        let textRect = cell.drawingRect(forBounds: field.bounds)
                        XCTAssertGreaterThan(textRect.width, 0); XCTAssertGreaterThan(textRect.height, 0)
                        XCTAssertTrue(field.bounds.insetBy(dx: -0.5, dy: -0.5).contains(textRect))
                        let required = cell.cellSize(forBounds: CGRect(x: 0, y: 0, width: field.bounds.width, height: 10_000))
                        XCTAssertLessThanOrEqual(required.width, field.bounds.width + 0.5)
                        XCTAssertLessThanOrEqual(required.height, field.bounds.height + 0.5)
                    }
                    let popupCell = try XCTUnwrap(picker.cell)
                    let titleRect = popupCell.titleRect(forBounds: picker.bounds)
                    XCTAssertGreaterThan(titleRect.width, 0); XCTAssertGreaterThan(titleRect.height, 0)
                    XCTAssertTrue(picker.bounds.insetBy(dx: -0.5, dy: -0.5).contains(titleRect))
                    let titleWidth = (picker.title as NSString).size(withAttributes: [.font: try XCTUnwrap(picker.font)]).width
                    XCTAssertLessThanOrEqual(titleWidth, titleRect.width + 0.5)
                    XCTAssertLessThanOrEqual(popupCell.cellSize.width, picker.bounds.width + 0.5)
                    let layout = try CaptureChainUIPreviewFixture.assertLayout(window: choice.window,
                        phase: "owned-text-choice-" + appearance.rawValue + "-" + String(index))
                    XCTAssertEqual(layout["fullVisibleFramesChecked"] as? Bool, true)
                    XCTAssertEqual(layout["controlsDoNotOverlap"] as? Bool, true)
                }
                XCTAssertEqual(choice.buttons[0].frame.minX - choice.buttons[1].frame.maxX, 24, accuracy: 0.5)
                XCTAssertTrue(responses.isEmpty, "Native layout and selection leave execution explicit")
                choice.cancel()
                try self.until { responses.count == 1 && parent.attachedSheet == nil }
                XCTAssertEqual(responses, [.cancel])
            }
        }
    }

    func testProgressUsesCurrentLongImageAndPreservesOrdinaryRegionTextWording() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-ScrollTextProgress-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = CaptureChainController(store: try CaptureChainStore(directory: directory))
        defer { controller.close() }
        // Snapshot metadata keeps the runner's established region/copy shape;
        // the explicit source flag determines the displayed acquisition route.
        let definition = try CaptureChainDefinition(name: "整理长图文字", source: .region, outputs: [.copy])
        let cases: [(CaptureChainStatus, String, String)] = [
            (.preparingText(.recognize), "当前长图 → 本机文字识别 → 文字脚本 → 复制文字", "区域截图 → 本机文字识别 → 文字脚本 → 复制"),
            (.preparingText(.transform), "当前长图 → 本机文字识别 → 文字脚本 → 复制文字", "区域截图 → 本机文字识别 → 文字脚本 → 复制"),
            (.preparingText(.copy), "当前长图 → 本机文字识别 → 文字脚本 → 复制文字", "区域截图 → 本机文字识别 → 文字脚本 → 复制"),
            (.textFailed(.recognize, .recognitionFailed), "识别失败；重试使用当前长图。", "识别失败；重试使用本次区域截图。"),
            (.textFailed(.transform, .invalidResult), "脚本失败；重试使用本次识别文字和已冻结的脚本。修改脚本前请先取消运行。", "脚本失败；重试使用本次识别文字和已冻结的脚本。修改脚本前请先取消运行。"),
            (.textFailed(.copy, .clipboardRejected), "复制失败；重试只复制已准备好的文字，不会重新识别当前长图或执行脚本。", "复制失败；重试只复制已准备好的文字，不会重新截图、识别或执行脚本。"),
            (.waitingForTextCleanup(.invalidResult), "等待已启动脚本退出并清理管道，期间不能重试或重新处理当前长图。", "等待已启动脚本退出并清理管道，期间不能重试或开始新截图。"),
            (.cancelled, "未复制文字", "未复制文字")
        ]
        let root = try XCTUnwrap(controller.window?.contentView)
        for isLongImage in [true, false] {
            for (status, longDetail, regionDetail) in cases {
                controller.update(snapshot: CaptureChainSnapshot(runID: UUID(), definition: definition,
                    status: status, receipts: [], capturedAt: Date(timeIntervalSince1970: 1), retainedBytes: 0,
                    isTextScript: true, isExistingScrollImage: isLongImage))
                let detail: NSTextField = try view("capture-chain-receipt-0", in: root)
                XCTAssertEqual(detail.stringValue, isLongImage ? longDetail : regionDetail)
                XCTAssertEqual(detail.toolTip, detail.stringValue)
                XCTAssertEqual(detail.accessibilityLabel(), detail.stringValue)
                let heading: NSTextField = try view("capture-chain-run-status", in: root)
                XCTAssertEqual(heading.stringValue.contains("来源：本次长截图"), isLongImage)
                XCTAssertEqual(heading.toolTip, heading.stringValue)
                XCTAssertEqual(heading.accessibilityLabel(), heading.stringValue)
            }
            controller.update(snapshot: CaptureChainSnapshot(runID: UUID(), definition: definition,
                status: .completed, receipts: [], capturedAt: Date(timeIntervalSince1970: 1), retainedBytes: 0,
                isTextScript: true, textReceipt: .init(characterCount: 42), isExistingScrollImage: isLongImage))
            let receipt: NSTextField = try view("capture-chain-receipt-0", in: root)
            XCTAssertEqual(receipt.stringValue, "已复制文字到剪贴板（42 个字符）")
        }
    }

    func testRecognitionFailureGuidanceNamesLongImageWithoutChangingRegionGuidance() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-ScrollTextFailure-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = CaptureChainController(store: try CaptureChainStore(directory: directory))
        defer { controller.close() }
        let definition = try CaptureChainDefinition(name: "整理文字", source: .region, outputs: [.copy])
        let failures: [(ChainTextFailure, String)] = [
            (.captureFailed, "当前长图未准备完成，请重新运行。"),
            (.emptyRecognition, "当前长图中未识别到文字，请取消后重新采集。"),
            (.truncatedRecognition, "当前长图的识别结果被截断，请取消后采集更短的长图。"),
            (.oversizedRecognition, "当前长图的识别文字超过限制，请取消后采集更短的长图。")
        ]
        let root = try XCTUnwrap(controller.window?.contentView)
        for isLongImage in [true, false] {
            for (failure, longMessage) in failures {
                controller.update(snapshot: CaptureChainSnapshot(runID: UUID(), definition: definition,
                    status: .textFailed(.recognize, failure), receipts: [], capturedAt: nil, retainedBytes: 0,
                    isTextScript: true, isExistingScrollImage: isLongImage))
                let heading: NSTextField = try view("capture-chain-run-status", in: root)
                XCTAssertEqual(heading.stringValue, definition.name + " · 操作未完成："
                    + (isLongImage ? longMessage + " · 来源：本次长截图" : failure.message))
                XCTAssertEqual(heading.toolTip, heading.stringValue)
                XCTAssertEqual(heading.accessibilityLabel(), heading.stringValue)
            }
        }
    }

    private func scripts(longNames: Bool = false) throws -> [TextScriptDefinition] {
        let names = longNames ? [String(repeating: "长", count: 64), String(repeating: "W", count: 64), String(repeating: "🧪", count: 64)]
            : ["整理空格", "转换大写"]
        return try names.map { try TextScriptDefinition(name: $0, source: "return text;") }
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
    /// here. This is the established LiveScrollChainChoiceControllerTests contract.
    private func withApplicationLoop(_ body: @escaping @MainActor () throws -> Void) throws {
        _ = NSApplication.shared
        if NSApp.isRunning { try body(); return }
        _ = try XCTUnwrap(NSApp.modalWindow == nil && NSApp.delegate == nil ? true : nil,
            "Standalone UI host unexpectedly has a modal window or application delegate")
        _ = try XCTUnwrap(UserDefaults.standard.object(forKey: "NSOpen") == nil ? true : nil,
            "Standalone UI host unexpectedly has a file-open request")
        let originalPolicy = NSApp.activationPolicy(), state = LiveScrollTextChoiceTestApplicationLoop()
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
                            finish(.failure(NSError(domain: "PicShot.ScrollTextChoiceTestHost", code: 1,
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

@MainActor private final class LiveScrollTextChoiceTestApplicationLoop {
    var result: Result<Void, Error>?
    var timer: Timer?
    var acceptsCallbacks = true
    var activationRequested = false
}
