import AppKit
import PicShotCore

/// Compact rows embedded in the existing floating palette, with no modal alerts.
@MainActor
final class NumberedCalloutControls: NSObject, NSTextFieldDelegate {
    let primary = NSStackView(), details = NSStackView()
    var onEdit: (((inout ImageAnnotation) -> Void) -> Void)?
    var onNext: ((Int) -> Void)?
    var onRenumber: ((Int) -> Void)?
    var onCloseGaps: ((Bool) -> Void)?
    var onComment: (() -> Void)?
    private let next = NSTextField(string: "1"), value = NSTextField(string: "1")
    private let start = NSTextField(string: "1"), commentSize = NSTextField(string: "20")
    private let nextLabel = NSTextField(labelWithString: "下个")
    private let style = NSPopUpButton()
    private let valueStepper = NSStepper(), nextStepper = NSStepper()
    private let comment = NSButton(title: "注释…", target: nil, action: nil)
    private let leader = NSButton(checkboxWithTitle: "箭头", target: nil, action: nil)
    private let closeGaps = NSButton(checkboxWithTitle: "删除后递补", target: nil, action: nil)
    private let renumber = NSButton(title: "重排", target: nil, action: nil)
    private var selectedGroup = NSStackView()
    private var displayed = ImageAnnotation(tool: .number, points: [])
    private var sequence = NumberedCalloutSequence()
    private var renumberStart = 1
    private var displayedCount = 0

    override init() {
        super.init()
        for row in [primary, details] { row.orientation = .horizontal; row.spacing = 4; row.alignment = .centerY; row.detachesHiddenViews = true }
        field(next, id: "numberNext", label: "下一个序号（1–3999），此图片内递增", action: #selector(changeNext))
        field(value, id: "numberValue", label: "当前序号值（1–3999），不改变下一个序号", action: #selector(changeValue))
        field(start, id: "numberRenumberStart", label: "全部重排序号的起始值（创建顺序）", action: #selector(changeStart))
        field(commentSize, id: "numberCommentFontSize", label: "序号注释字号（8–72 像素）", action: #selector(changeCommentSize))
        style.addItems(withTitles: NumberedCalloutStyle.allCases.map(\.title)); style.controlSize = .small
        style.target = self; style.action = #selector(changeStyle); identify(style, "numberStyle", "序号显示类型")
        fixed(style, 84)
        for (stepper, id, action) in [(nextStepper, "numberNextStep", #selector(stepNext)), (valueStepper, "numberValueStep", #selector(stepValue))] {
            stepper.minValue = 1; stepper.maxValue = Double(NumberedCalloutSequence.maximumValue); stepper.increment = 1
            stepper.valueWraps = false; stepper.autorepeat = true; stepper.controlSize = .mini
            stepper.target = self; stepper.action = action; identify(stepper, id, id == "numberNextStep" ? "增减下一个序号" : "增减当前序号")
        }
        for (button, id, label, action) in [
            (comment, "numberComment", "编辑附属注释 · A / 双击", #selector(editComment)),
            (leader, "numberLeader", "显示指向箭头；选择工具可拖动端点", #selector(changeLeader)),
            (renumber, "numberRenumber", "按创建顺序重排全部序号，可撤销；过高起始值会下调以容纳全部序号", #selector(renumberAll)),
            (closeGaps, "numberCloseGaps", "删除时大于被删值的序号减一；仅此图片", #selector(changeCloseGaps))] {
            button.target = self; button.action = action; button.controlSize = .small
            if button === comment || button === renumber { button.bezelStyle = .rounded }
            identify(button, id, label)
        }
        selectedGroup = NSStackView(views: [label("当前"), value, valueStepper, comment, leader])
        selectedGroup.spacing = 4; selectedGroup.alignment = .centerY
        for view in [nextLabel, next, nextStepper, style, selectedGroup] { primary.addArrangedSubview(view) }
        for view in [label("从"), start, renumber, closeGaps, label("注释字号"), commentSize] { details.addArrangedSubview(view) }
    }
    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text); field.font = .systemFont(ofSize: 11); return field
    }
    private func identify(_ control: NSControl, _ id: String, _ label: String) {
        control.identifier = .init("annotation.\(id)"); control.setAccessibilityLabel(label); control.toolTip = label
    }
    private func fixed(_ view: NSView, _ width: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false; view.widthAnchor.constraint(equalToConstant: width).isActive = true
    }
    private func field(_ field: NSTextField, id: String, label: String, action: Selector) {
        identify(field, id, label); field.controlSize = .small; field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.alignment = .right; field.delegate = self; field.target = self; field.action = action; fixed(field, 42)
    }
    func display(annotation: ImageAnnotation, selected: Bool, sequence: NumberedCalloutSequence, count: Int) {
        displayed = annotation; self.sequence = sequence
        displayedCount = count
        selectedGroup.isHidden = !selected
        let atMarkLimit = count >= NumberedCalloutSequence.maximumMarks
        nextLabel.stringValue = atMarkLimit ? "已满" : (sequence.isExhausted ? "上限" : "下个")
        for (field, number) in [(next, sequence.nextValue), (value, annotation.number), (start, renumberStart), (commentSize, Int(min(72, annotation.effectiveFontSize)))] {
            if field.currentEditor() == nil { field.integerValue = number }
        }
        nextStepper.integerValue = sequence.nextValue; valueStepper.integerValue = annotation.number
        style.selectItem(at: NumberedCalloutStyle.allCases.firstIndex(of: annotation.numberStyle) ?? 0)
        leader.state = annotation.points.count > 1 ? .on : .off
        closeGaps.state = sequence.closesGapsOnDelete ? .on : .off
        renumber.isEnabled = count > 0
        next.toolTip = atMarkLimit ? "此图片最多 512 个序号；删除部分序号后继续"
            : (sequence.isExhausted ? "3999 已用完；输入一个新的起始值后继续" : "下一个序号（1–3999）；删除默认保留编号间隔")
    }
    private func integer(_ field: NSTextField, fallback: Int) -> Int {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 12, let value = Int(text) else { field.integerValue = fallback; return fallback }
        let bounded = NumberedCalloutSequence.clamp(value); field.integerValue = bounded; return bounded
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)), let field = control as? NSTextField else { return false }
        let original = field === next ? sequence.nextValue : field === value ? displayed.number : field === start ? renumberStart : Int(min(72, displayed.effectiveFontSize))
        field.integerValue = original; textView.string = String(original)
        field.window?.makeFirstResponder(nil)
        return true
    }
    @objc private func changeNext() { onNext?(integer(next, fallback: sequence.nextValue)) }
    @objc private func stepNext() { onNext?(nextStepper.integerValue) }
    @objc private func changeValue() {
        let number = integer(value, fallback: displayed.number)
        guard number != displayed.number else { return }
        onEdit? { $0.number = number }
    }
    @objc private func stepValue() { let number = valueStepper.integerValue; onEdit? { $0.number = number } }
    @objc private func changeStyle() {
        guard NumberedCalloutStyle.allCases.indices.contains(style.indexOfSelectedItem) else { return }
        let choice = NumberedCalloutStyle.allCases[style.indexOfSelectedItem]; onEdit? { $0.numberStyle = choice }
    }
    @objc private func changeStart() { renumberStart = integer(start, fallback: renumberStart) }
    @objc private func renumberAll() {
        changeStart()
        renumberStart = min(renumberStart, max(1, NumberedCalloutSequence.maximumValue - displayedCount + 1))
        start.integerValue = renumberStart; onRenumber?(renumberStart)
    }
    @objc private func changeCloseGaps() { onCloseGaps?(closeGaps.state == .on) }
    @objc private func editComment() { onComment?() }
    @objc private func changeLeader() { let enabled = leader.state == .on; onEdit? { $0.setNumberLeader(enabled) } }
    @objc private func changeCommentSize() {
        let size = min(72, max(8, integer(commentSize, fallback: Int(displayed.effectiveFontSize))))
        guard CGFloat(size) != displayed.effectiveFontSize else { return }
        onEdit? { $0.fontSize = CGFloat(size) }
    }
    func clearCallbacks() { onEdit = nil; onNext = nil; onRenumber = nil; onCloseGaps = nil; onComment = nil }
}
