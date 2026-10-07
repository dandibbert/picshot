import AppKit

@MainActor
private enum AnnotationStyleControlFactory {
    static func configure(_ control: NSControl, id: String, label: String, target: AnyObject, action: Selector) {
        control.identifier = .init(id); control.setAccessibilityLabel(label); control.toolTip = label
        control.controlSize = .small; control.target = target; control.action = action
    }
    static func width(_ view: NSView, _ width: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
    }
}

/// Owns only controls; every action immediately edits the inspector's annotation value.
@MainActor
final class AnnotationLineStyleControls: NSObject {
    var onEdit: (((inout ImageAnnotation) -> Void) -> Void)?
    let endings = NSStackView(), stroke = NSStackView()
    private let start = NSButton(checkboxWithTitle: "起", target: nil, action: nil)
    private let end = NSButton(checkboxWithTitle: "终", target: nil, action: nil)
    private let startForm = NSPopUpButton(), endForm = NSPopUpButton()
    private let cap = NSPopUpButton(), join = NSPopUpButton()

    override init() {
        super.init()
        for row in [endings, stroke] {
            row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 4; row.detachesHiddenViews = true
        }
        AnnotationStyleControlFactory.configure(start, id: "annotation.startArrow", label: "显示起点箭头", target: self, action: #selector(changeStart))
        AnnotationStyleControlFactory.configure(end, id: "annotation.endArrow", label: "显示终点箭头", target: self, action: #selector(changeEnd))
        for (picker, id, label, action) in [
            (startForm, "annotation.startArrowhead", "起点箭头形状", #selector(changeStartForm)),
            (endForm, "annotation.endArrowhead", "终点箭头形状", #selector(changeEndForm))] {
            picker.addItems(withTitles: AnnotationArrowhead.allCases.map(\.title))
            AnnotationStyleControlFactory.configure(picker, id: id, label: label, target: self, action: action)
            AnnotationStyleControlFactory.width(picker, 62)
        }
        cap.addItems(withTitles: AnnotationLineCap.allCases.map(\.title))
        join.addItems(withTitles: AnnotationLineJoin.allCases.map(\.title))
        AnnotationStyleControlFactory.configure(cap, id: "annotation.lineCap", label: "线条端点样式", target: self, action: #selector(changeCap))
        AnnotationStyleControlFactory.configure(join, id: "annotation.lineJoin", label: "线条连接样式（尖角超出 10 倍线宽时折平）", target: self, action: #selector(changeJoin))
        AnnotationStyleControlFactory.width(cap, 65); AnnotationStyleControlFactory.width(join, 65)
        let endingViews: [NSView] = [start, startForm, end, endForm]
        endingViews.forEach { endings.addArrangedSubview($0) }
        [cap, join].forEach { stroke.addArrangedSubview($0) }
    }

    func display(_ annotation: ImageAnnotation) {
        start.state = annotation.startArrowEnabled ? .on : .off
        end.state = annotation.effectiveEndArrowEnabled ? .on : .off
        startForm.isEnabled = annotation.startArrowEnabled; endForm.isEnabled = annotation.effectiveEndArrowEnabled
        startForm.selectItem(at: AnnotationArrowhead.allCases.firstIndex(of: annotation.startArrowhead) ?? 0)
        endForm.selectItem(at: AnnotationArrowhead.allCases.firstIndex(of: annotation.endArrowhead) ?? 0)
        cap.selectItem(at: AnnotationLineCap.allCases.firstIndex(of: annotation.lineCap) ?? 0)
        join.selectItem(at: AnnotationLineJoin.allCases.firstIndex(of: annotation.lineJoin) ?? 0)
    }
    @objc private func changeStart() { let value = start.state == .on; onEdit? { $0.startArrowEnabled = value } }
    @objc private func changeEnd() { let value = end.state == .on; onEdit? { $0.endArrowEnabled = value } }
    @objc private func changeStartForm() {
        guard AnnotationArrowhead.allCases.indices.contains(startForm.indexOfSelectedItem) else { return }
        let value = AnnotationArrowhead.allCases[startForm.indexOfSelectedItem]; onEdit? { $0.startArrowhead = value }
    }
    @objc private func changeEndForm() {
        guard AnnotationArrowhead.allCases.indices.contains(endForm.indexOfSelectedItem) else { return }
        let value = AnnotationArrowhead.allCases[endForm.indexOfSelectedItem]; onEdit? { $0.endArrowhead = value }
    }
    @objc private func changeCap() {
        guard AnnotationLineCap.allCases.indices.contains(cap.indexOfSelectedItem) else { return }
        let value = AnnotationLineCap.allCases[cap.indexOfSelectedItem]; onEdit? { $0.lineCap = value }
    }
    @objc private func changeJoin() {
        guard AnnotationLineJoin.allCases.indices.contains(join.indexOfSelectedItem) else { return }
        let value = AnnotationLineJoin.allCases[join.indexOfSelectedItem]; onEdit? { $0.lineJoin = value }
    }
}

@MainActor
final class AnnotationTextOutlineControls: NSObject {
    var onEdit: (((inout ImageAnnotation) -> Void) -> Void)?
    let row = NSStackView()
    private let enabled = NSButton(checkboxWithTitle: "描边", target: nil, action: nil)
    private let color = NSColorWell()
    private let width = NSTextField(string: "2")
    override init() {
        super.init()
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 4; row.detachesHiddenViews = true
        AnnotationStyleControlFactory.configure(enabled, id: "annotation.textOutline", label: "文字描边", target: self, action: #selector(changeEnabled))
        AnnotationStyleControlFactory.configure(color, id: "annotation.textOutlineColor", label: "文字描边颜色", target: self, action: #selector(changeColor))
        AnnotationStyleControlFactory.configure(width, id: "annotation.textOutlineWidth", label: "文字描边宽度（0.5–8 像素）", target: self, action: #selector(changeWidth))
        color.isBordered = false; AnnotationStyleControlFactory.width(color, 20)
        color.heightAnchor.constraint(equalToConstant: 20).isActive = true
        width.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); width.alignment = .right
        AnnotationStyleControlFactory.width(width, 30)
        let views: [NSView] = [enabled, color, width]
        views.forEach { row.addArrangedSubview($0) }
    }
    func display(_ annotation: ImageAnnotation) {
        enabled.state = annotation.textOutlineEnabled ? .on : .off
        color.color = NSColor(cgColor: annotation.textOutlineColor) ?? .white
        color.isEnabled = annotation.textOutlineEnabled; width.isEnabled = annotation.textOutlineEnabled
        color.isHidden = !annotation.textOutlineEnabled; width.isHidden = !annotation.textOutlineEnabled
        width.stringValue = String(format: "%g", Double(annotation.textOutlineWidth))
    }
    func deactivateColorWell() { color.deactivate() }
    @objc private func changeEnabled() { let value = enabled.state == .on; onEdit? { $0.textOutlineEnabled = value } }
    @objc private func changeColor() { let value = color.color.cgColor; onEdit? { $0.textOutlineColor = value } }
    @objc private func changeWidth() {
        guard width.doubleValue.isFinite else { return }
        let value = CGFloat(min(8, max(0.5, width.doubleValue))); onEdit? { $0.textOutlineWidth = value }
    }
}
