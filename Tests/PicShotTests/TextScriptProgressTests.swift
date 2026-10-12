import AppKit
import PicShotCore
import XCTest
@testable import PicShot

@MainActor final class TextScriptProgressTests: XCTestCase {
    func testScriptManagerButtonOpensOnlyWhenNoRunOrUnsavedDraftOwnsManager() throws {
        let fixture = try fixture(); defer { fixture.close() }
        var opens = 0; fixture.controller.onManageTextScripts = { opens += 1 }
        let button: NSButton = try view("text-scripts", fixture.controller)
        XCTAssertTrue(button.isEnabled); try dispatch(button); XCTAssertEqual(opens, 1)
        fixture.controller.update(snapshot: try snapshot(status: .preparingText(.transform)))
        XCTAssertFalse(button.isEnabled); try dispatch(button); XCTAssertEqual(opens, 1)
        fixture.controller.update(snapshot: try snapshot(status: .completed))
        let create: NSButton = try view("create", fixture.controller)
        try dispatch(create)
        XCTAssertFalse(button.isEnabled); try dispatch(button); XCTAssertEqual(opens, 1)
    }

    func testTextPhasesAndCommittedCancellationShowOnlySafeMetadata() throws {
        let fixture = try fixture(); defer { fixture.close() }
        let statuses: [(CaptureChainStatus, String)] = [
            (.preparingText(.recognize), "正在识别"), (.preparingText(.transform), "正在运行文字脚本"),
            (.preparingText(.copy), "正在复制"), (.textFailed(.copy, .clipboardRejected), "剪贴板"),
            (.waitingForTextCleanup(.runtime(.exitUnconfirmed)), "清理")
        ]
        let runID = UUID()
        for (status, expected) in statuses {
            fixture.controller.update(snapshot: try snapshot(id: runID, status: status))
            let field: NSTextField = try view("run-status", fixture.controller)
            XCTAssertTrue(field.stringValue.contains(expected)); XCTAssertEqual(field.toolTip, field.stringValue)
            XCTAssertEqual(field.accessibilityLabel(), field.stringValue)
        }
        fixture.controller.update(snapshot: try snapshot(id: runID, status: .cancelled, receipt: .init(characterCount: 42)))
        let receipt: NSTextField = try view("receipt-0", fixture.controller)
        let status: NSTextField = try view("run-status", fixture.controller)
        XCTAssertTrue(receipt.stringValue.contains("42")); XCTAssertTrue(receipt.stringValue.contains("已复制"))
        XCTAssertTrue(status.stringValue.contains("已完成结果仍然保留"))
        XCTAssertFalse(receipt.stringValue.contains("PRIVATE")); XCTAssertFalse(status.stringValue.contains("PRIVATE"))
    }

    func testCleanupProgressBlocksRetryAndCloseReportsTheOwnedRunOnce() throws {
        let fixture = try fixture(); defer { fixture.close() }
        fixture.controller.present()
        let runID = UUID()
        fixture.controller.update(snapshot: try snapshot(id: runID, status: .waitingForTextCleanup(.runtime(.pipesUnconfirmed))))
        let retry: NSButton = try view("retry", fixture.controller)
        let run: NSButton = try view("run", fixture.controller)
        let scripts: NSButton = try view("text-scripts", fixture.controller)
        XCTAssertFalse(retry.isEnabled); XCTAssertTrue(retry.isHidden)
        XCTAssertFalse(run.isEnabled); XCTAssertFalse(scripts.isEnabled)
        var closed: [UUID?] = []
        fixture.controller.onClose = { id, generation in
            XCTAssertTrue(fixture.controller.isCurrentCommand(generation)); closed.append(id)
        }
        fixture.controller.close(); fixture.controller.close()
        XCTAssertEqual(closed.count, 1); XCTAssertEqual(closed.first!, runID)
        fixture.controller.update(snapshot: try snapshot(id: runID, status: .cancelling))
        XCTAssertFalse(fixture.controller.window?.isVisible ?? true)
    }

    func testLightAndDarkProgressAndManagerHaveContainedNonoverlappingControls() throws {
        let fixture = try fixture(); defer { fixture.close() }
        let window = try XCTUnwrap(fixture.controller.window)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance); window.animationBehavior = .none
            fixture.controller.present(); window.setContentSize(NSSize(width: 600, height: 600)); window.center()
            window.contentView?.layoutSubtreeIfNeeded()
            _ = try CaptureChainUIPreviewFixture.assertLayout(window: window, phase: "text-manager-" + appearance.rawValue)
            let metadata = try CaptureChainDefinition(name: String(repeating: "很长名称", count: 16), source: .region, outputs: [.copy])
            fixture.controller.update(snapshot: .init(runID: UUID(), definition: metadata,
                status: .textFailed(.transform, .script(.scriptException)), receipts: [], capturedAt: nil,
                retainedBytes: 40, isTextScript: true, retainedTextBytes: 40))
            window.center(); window.contentView?.layoutSubtreeIfNeeded()
            _ = try CaptureChainUIPreviewFixture.assertLayout(window: window, phase: "text-progress-" + appearance.rawValue)
            XCTAssertEqual(window.contentView?.bounds.height, 270)
            fixture.controller.update(snapshot: try snapshot(status: .completed))
            let manage: NSButton = try view("manage", fixture.controller); try dispatch(manage)
        }
    }

    private struct Fixture {
        let directory: URL
        let controller: CaptureChainController
        @MainActor func close() {
            controller.onClose = nil; controller.onManageTextScripts = nil; controller.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }
    private func fixture() throws -> Fixture {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-TextProgress-" + UUID().uuidString)
        return Fixture(directory: directory, controller: CaptureChainController(store: try CaptureChainStore(directory: directory)))
    }
    private func snapshot(id: UUID = UUID(), status: CaptureChainStatus, receipt: ChainTextCopyReceipt? = nil) throws -> CaptureChainSnapshot {
        .init(runID: id, definition: try CaptureChainDefinition(name: "文字操作", source: .region, outputs: [.copy]),
              status: status, receipts: [], capturedAt: nil, retainedBytes: 0,
              isTextScript: true, textReceipt: receipt, retainedTextBytes: 0)
    }
    private func view<T: NSView>(_ suffix: String, _ controller: CaptureChainController) throws -> T {
        func descendants(_ root: NSView) -> [NSView] { root.subviews.flatMap { [$0] + descendants($0) } }
        let root = try XCTUnwrap(controller.window?.contentView)
        return try XCTUnwrap(descendants(root).first { $0.identifier?.rawValue == "capture-chain-" + suffix } as? T)
    }
    private func dispatch(_ control: NSControl) throws {
        let action = try XCTUnwrap(control.action)
        XCTAssertTrue(NSApp.sendAction(action, to: control.target, from: control))
    }
}
