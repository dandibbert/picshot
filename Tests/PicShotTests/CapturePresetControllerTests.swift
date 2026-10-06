import XCTest
import AppKit
import PicShotCore
@testable import PicShot

final class CapturePresetControllerTests: XCTestCase {
    @MainActor func testCreateUsesExplicitNameAndDelayAndHidesBeforeSelection() throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CapturePresetStore(directory: directory), controller = CapturePresetController(store: store)
        defer { controller.close() }
        let name: NSTextField = try view("capture-preset-name", in: controller)
        let delay: NSPopUpButton = try view("capture-preset-delay", in: controller)
        name.stringValue = " 工作区域 "; delay.selectItem(withTag: 5)
        var requests: [(String, ScreenshotDelay)] = []
        controller.onCreate = { [weak controller] title, delay in
            XCTAssertFalse(controller?.window?.isVisible ?? true)
            requests.append((title, delay))
        }
        controller.showWindow(nil)
        try press("capture-preset-create", in: controller)
        XCTAssertEqual(requests.count, 1); XCTAssertEqual(requests.first?.0, "工作区域")
        XCTAssertEqual(requests.first?.1, .fiveSeconds); XCTAssertTrue(store.presets.isEmpty)
        name.stringValue = "\n"
        try press("capture-preset-create", in: controller)
        XCTAssertEqual(requests.count, 1)
        let status: NSTextField = try view("capture-preset-status", in: controller)
        XCTAssertTrue(status.stringValue.contains("预设名称"))
    }

    @MainActor func testRenameDelayInvokeAndDeleteUseSelectedRecord() throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CapturePresetStore(directory: directory), saved = try preset()
        try store.add(saved)
        let controller = CapturePresetController(store: store); defer { controller.close() }
        controller.showWindow(nil)
        let table: NSTableView = try view("capture-preset-list", in: controller)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let name: NSTextField = try view("capture-preset-name", in: controller)
        let delay: NSPopUpButton = try view("capture-preset-delay", in: controller)
        name.stringValue = "重命名区域"; delay.selectItem(withTag: 10)
        try press("capture-preset-update", in: controller)
        let updated = try XCTUnwrap(store.preset(id: saved.id))
        XCTAssertEqual(updated.name, "重命名区域"); XCTAssertEqual(updated.delay, .tenSeconds)
        XCTAssertEqual(updated.pixelFrame, saved.pixelFrame)
        var invoked: CapturePreset?
        controller.onInvoke = { [weak controller] preset in
            XCTAssertFalse(controller?.window?.isVisible ?? true)
            invoked = preset
        }
        try press("capture-preset-invoke", in: controller)
        XCTAssertEqual(invoked, updated)
        controller.showWindow(nil)
        try press("capture-preset-delete", in: controller)
        XCTAssertTrue(store.presets.isEmpty)
        XCTAssertTrue(try CapturePresetStore(directory: directory).presets.isEmpty)
        let invoke: NSButton = try view("capture-preset-invoke", in: controller)
        let update: NSButton = try view("capture-preset-update", in: controller)
        XCTAssertFalse(invoke.isEnabled); XCTAssertFalse(update.isEnabled)
    }

    @MainActor func testCancelEscapeAndWindowCloseNeverInvokeOrCreate() throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CapturePresetStore(directory: directory), controller = CapturePresetController(store: store)
        var cancellations = 0, creations = 0, invocations = 0
        controller.onCancel = { cancellations += 1 }
        controller.onCreate = { _, _ in creations += 1 }; controller.onInvoke = { _ in invocations += 1 }
        controller.showWindow(nil)
        let cancel: NSButton = try view("capture-preset-cancel", in: controller)
        XCTAssertEqual(cancel.keyEquivalent, "\u{1b}")
        try press("capture-preset-cancel", in: controller)
        XCTAssertEqual(cancellations, 1); XCTAssertFalse(controller.window?.isVisible ?? true)
        controller.showWindow(nil); controller.window?.performClose(nil)
        XCTAssertEqual(cancellations, 2); XCTAssertEqual(creations, 0); XCTAssertEqual(invocations, 0)
        XCTAssertTrue(store.presets.isEmpty)
    }

    @MainActor func testUpdateFailureIsVisibleInChineseAndDoesNotChangeNameOrDelay() throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CapturePresetStore(directory: directory), saved = try preset()
        try store.add(saved)
        let controller = CapturePresetController(store: store); defer { controller.close() }
        let table: NSTableView = try view("capture-preset-list", in: controller)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let name: NSTextField = try view("capture-preset-name", in: controller)
        let delay: NSPopUpButton = try view("capture-preset-delay", in: controller)
        name.stringValue = ""; delay.selectItem(withTag: 10)
        try press("capture-preset-update", in: controller)
        XCTAssertEqual(store.presets, [saved])
        let status: NSTextField = try view("capture-preset-status", in: controller)
        XCTAssertTrue(status.stringValue.contains("预设名称")); XCTAssertEqual(status.textColor, .systemRed)
        controller.showError(CapturePresetError.loadFailed)
        XCTAssertTrue(status.stringValue.contains("无法读取截图预设"))
    }

    @MainActor func testCapturePermissionAndDisplayErrorsKeepActionableDescriptions() throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CapturePresetStore(directory: directory), controller = CapturePresetController(store: store)
        defer { controller.close() }
        let status: NSTextField = try view("capture-preset-status", in: controller)
        for error in [CaptureError.screenPermission, CaptureError.noDisplay] {
            controller.showError(error)
            XCTAssertEqual(status.stringValue, error.errorDescription)
            XCTAssertEqual(status.textColor, .systemRed)
        }
        XCTAssertFalse(status.stringValue.contains("本地文件权限"))
        for error in [DisplayCompositeError.layoutChanged, .pixelLimit] {
            controller.showError(error)
            XCTAssertEqual(status.stringValue, error.errorDescription)
        }
    }

    @MainActor func testUnrelatedLowLevelErrorDoesNotExposeItsDetailsOrInventDiskFailure() throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CapturePresetStore(directory: directory), controller = CapturePresetController(store: store)
        defer { controller.close() }
        controller.showError(NSError(domain: "FixtureService", code: 99,
            userInfo: [NSLocalizedDescriptionKey: "Private payload /Users/example/secret.json token=fixture-only"]))
        let status: NSTextField = try view("capture-preset-status", in: controller)
        XCTAssertEqual(status.stringValue, "操作未完成，请重试。")
        XCTAssertFalse(status.stringValue.contains("secret.json"))
        XCTAssertFalse(status.stringValue.contains("token="))
        XCTAssertFalse(status.stringValue.contains("本地文件权限"))
    }

    @MainActor private func view<T: NSView>(_ identifier: String, in controller: CapturePresetController) throws -> T {
        let content = try XCTUnwrap(controller.window?.contentView)
        return try XCTUnwrap(descendants(content).first(where: { $0.identifier?.rawValue == identifier }) as? T)
    }
    @MainActor private func descendants(_ root: NSView) -> [NSView] { root.subviews.flatMap { [$0] + descendants($0) } }
    @MainActor private func press(_ identifier: String, in controller: CapturePresetController) throws {
        let button: NSButton = try view(identifier, in: controller)
        XCTAssertTrue(button.isEnabled)
        let action = try XCTUnwrap(button.action)
        XCTAssertTrue(NSApp.sendAction(action, to: button.target, from: button))
    }
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-PresetUITests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func preset() throws -> CapturePreset {
        let display = try CapturePresetDisplay(uuid: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900), pixelWidth: 2880, pixelHeight: 1800, rotationDegrees: 0)
        return try CapturePreset(name: "工作区域", delay: .threeSeconds, display: display,
            topLeftFrame: CGRect(x: 10.5, y: 20.5, width: 31.5, height: 40.5),
            pixelFrame: CGRect(x: 21, y: 41, width: 63, height: 81))
    }
}
