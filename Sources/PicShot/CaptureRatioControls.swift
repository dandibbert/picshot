import AppKit
import PicShotCore

/// Shared, compact selection-only controls. No annotation shape state or raster
/// enters this view. Callbacks return false to leave an invalid draft editable.
@MainActor
final class CaptureRatioControls: NSStackView, NSTextFieldDelegate {
    var onRatio: ((CaptureAspectRatio?) -> Bool)?
    var onSize: ((Int, Int, CaptureRatioAxis) -> Bool)?
    var onCancel: (() -> Void)?
    private(set) var ratio: CaptureAspectRatio?
    let preset = NSPopUpButton()
    let numerator = NSTextField(string: "16")
    let denominator = NSTextField(string: "9")
    let widthField = NSTextField(string: "")
    let heightField = NSTextField(string: "")
    private let customRow = NSStackView()
    private let swap = NSButton(title: "Swap", target: nil, action: nil)
    private let feedback = NSTextField(labelWithString: "Free selection")
    private var lastAxis: CaptureRatioAxis = .width
    private var enteringCustom = false
    private let prefix: String
    var showsDimensions = true { didSet { dimensionRow.isHidden = !showsDimensions } }
    private let dimensionRow = NSStackView()

    init(prefix: String) {
        self.prefix = prefix
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 4
        identifier = .init(prefix + ".ratioControls")
        preset.addItems(withTitles: ["Free"] + CaptureAspectRatio.presets.map(\.label) + ["Custom…"])
        preset.target = self; preset.action = #selector(selectPreset)
        preset.identifier = .init(prefix + ".ratioPreset")
        preset.setAccessibilityLabel("Selection aspect ratio in source pixels")
        preset.controlSize = .small
        preset.widthAnchor.constraint(equalToConstant: 102).isActive = true
        swap.target = self; swap.action = #selector(swapRatio)
        swap.identifier = .init(prefix + ".ratioSwap"); swap.controlSize = .small; swap.bezelStyle = .rounded
        swap.toolTip = "Swap width and height ratio"
        let row = NSStackView(views: [NSTextField(labelWithString: "Ratio"), preset, swap])
        row.orientation = .horizontal; row.spacing = 5
        for (field, id, label, width) in [(numerator, "ratioNumerator", "Custom ratio numerator, 1 through 10000", 48.0),
                                         (denominator, "ratioDenominator", "Custom ratio denominator, 1 through 10000", 48.0),
                                         (widthField, "pixelWidth", "Selection width in source pixels", 58.0),
                                         (heightField, "pixelHeight", "Selection height in source pixels", 58.0)] {
            field.identifier = .init(prefix + "." + id); field.setAccessibilityLabel(label)
            field.delegate = self; field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            field.controlSize = .small; field.alignment = .right
            field.target = self; field.action = #selector(applyField(_:))
            field.widthAnchor.constraint(equalToConstant: CGFloat(width)).isActive = true
        }
        let custom = NSButton(title: "Set", target: self, action: #selector(applyCustom))
        custom.identifier = .init(prefix + ".ratioApply"); custom.bezelStyle = .rounded; custom.controlSize = .small
        customRow.setViews([numerator, NSTextField(labelWithString: ":"), denominator, custom], in: .leading)
        customRow.orientation = .horizontal; customRow.spacing = 3; customRow.isHidden = true
        row.addArrangedSubview(customRow)
        addArrangedSubview(row)
        let apply = NSButton(title: "Set px", target: self, action: #selector(applySize))
        apply.identifier = .init(prefix + ".sizeApply"); apply.bezelStyle = .rounded; apply.controlSize = .small
        dimensionRow.setViews([NSTextField(labelWithString: "W"), widthField,
                               NSTextField(labelWithString: "H"), heightField, apply], in: .leading)
        dimensionRow.orientation = .horizontal; dimensionRow.spacing = 4
        addArrangedSubview(dimensionRow)
        feedback.font = .systemFont(ofSize: 10); feedback.textColor = .secondaryLabelColor
        feedback.lineBreakMode = .byTruncatingTail
        feedback.identifier = .init(prefix + ".ratioFeedback")
        addArrangedSubview(feedback)
        display(ratio: nil, pixels: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func display(ratio: CaptureAspectRatio?, pixels: CGSize?) {
        self.ratio = ratio
        let index = ratio.flatMap { CaptureAspectRatio.presets.firstIndex(of: $0) }
        preset.selectItem(at: ratio == nil ? 0 : index.map { $0 + 1 } ?? CaptureAspectRatio.presets.count + 1)
        customRow.isHidden = !enteringCustom && (ratio == nil || index != nil)
        swap.isEnabled = ratio != nil
        if let ratio {
            if numerator.currentEditor() == nil { numerator.stringValue = String(ratio.numerator) }
            if denominator.currentEditor() == nil { denominator.stringValue = String(ratio.denominator) }
        }
        for (field, value) in [(widthField, pixels?.width), (heightField, pixels?.height)] {
            field.isEnabled = pixels != nil
            if field.currentEditor() == nil { field.stringValue = value.map { String(Int($0)) } ?? "" }
        }
        (dimensionRow.arrangedSubviews.last as? NSControl)?.isEnabled = pixels != nil
        feedback.stringValue = ratio.map { value in
            let exact = pixels.map { $0.width * CGFloat(value.denominator) == $0.height * CGFloat(value.numerator) } ?? true
            return "\(exact ? "Exact pixel ratio" : "Next resize ratio") \(value.label) · \(value.numerator) × \(value.denominator) px steps"
        } ?? "Free selection · dimensions are source pixels"
        needsLayout = true
    }
    func showError(_ message: String) { feedback.stringValue = message; feedback.toolTip = message }
    private func text(_ field: NSTextField) -> String { (field.currentEditor()?.string ?? field.stringValue).trimmingCharacters(in: .whitespacesAndNewlines) }
    @objc private func selectPreset() {
        let index = preset.indexOfSelectedItem
        guard index >= 0, index <= CaptureAspectRatio.presets.count + 1 else { return }
        if index == CaptureAspectRatio.presets.count + 1 {
            enteringCustom = true; customRow.isHidden = false; window?.makeFirstResponder(numerator); return
        }
        let proposed: CaptureAspectRatio? = index == 0 ? nil : CaptureAspectRatio.presets[index - 1]
        enteringCustom = false
        if onRatio?(proposed) != true { preset.selectItem(at: ratio.flatMap { CaptureAspectRatio.presets.firstIndex(of: $0).map { $0 + 1 } } ?? (ratio == nil ? 0 : CaptureAspectRatio.presets.count + 1)) }
    }
    @objc private func swapRatio() { if let ratio { enteringCustom = false; _ = onRatio?(ratio.swapped) } }
    @objc private func applyCustom() {
        guard let n = Int(text(numerator)), let d = Int(text(denominator)),
              let value = try? CaptureAspectRatio(numerator: n, denominator: d) else {
            showError("Enter whole ratio values from 1 through 10000"); return
        }
        enteringCustom = false
        if onRatio?(value) != true { enteringCustom = true }
    }
    @objc private func applyField(_ field: NSTextField) {
        if field === numerator || field === denominator { applyCustom() }
        else { lastAxis = field === heightField ? .height : .width; applySize() }
    }
    @objc private func applySize() {
        guard let width = Int(text(widthField)), let height = Int(text(heightField)), width > 0, height > 0 else {
            showError("Enter positive whole source-pixel dimensions"); return
        }
        _ = onSize?(width, height, lastAxis)
    }
    func controlTextDidBeginEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField, field === widthField || field === heightField {
            lastAxis = field === heightField ? .height : .width
        }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { onCancel?(); return true }
        if selector == #selector(NSResponder.insertNewline(_:)), let field = control as? NSTextField {
            field.stringValue = textView.string; applyField(field); return true
        }
        return false
    }
}

extension CaptureRatioHandle {
    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .minXMinY: return CGPoint(x: rect.minX, y: rect.minY)
        case .minY: return CGPoint(x: rect.midX, y: rect.minY)
        case .maxXMinY: return CGPoint(x: rect.maxX, y: rect.minY)
        case .maxX: return CGPoint(x: rect.maxX, y: rect.midY)
        case .maxXMaxY: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .maxY: return CGPoint(x: rect.midX, y: rect.maxY)
        case .minXMaxY: return CGPoint(x: rect.minX, y: rect.maxY)
        case .minX: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }
    static func hit(at point: CGPoint, frame: CGRect, tolerance: CGFloat = 7) -> Self? {
        allCases.min { hypot($0.point(in: frame).x - point.x, $0.point(in: frame).y - point.y) < hypot($1.point(in: frame).x - point.x, $1.point(in: frame).y - point.y) }
            .flatMap { hypot($0.point(in: frame).x - point.x, $0.point(in: frame).y - point.y) <= tolerance ? $0 : nil }
    }
    func freelyResized(_ original: CGRect, to point: CGPoint, in bounds: CGRect) -> CGRect {
        var x0 = original.minX, x1 = original.maxX, y0 = original.minY, y1 = original.maxY
        if [.minXMinY, .minXMaxY, .minX].contains(self) { x0 = max(bounds.minX, min(point.x, x1 - 2)) }
        if [.maxXMinY, .maxXMaxY, .maxX].contains(self) { x1 = min(bounds.maxX, max(point.x, x0 + 2)) }
        if [.minXMinY, .minY, .maxXMinY].contains(self) { y0 = max(bounds.minY, min(point.y, y1 - 2)) }
        if [.minXMaxY, .maxY, .maxXMaxY].contains(self) { y1 = min(bounds.maxY, max(point.y, y0 + 2)) }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
