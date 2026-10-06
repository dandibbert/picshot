import AppKit

/// A single compact contextual row. These controls edit the same model used by hit testing
/// and export; hidden controls have no separate preview-only state.
@MainActor
final class AnnotationInspector: NSStackView {
    var onEdit: (((inout ImageAnnotation) -> Void) -> Void)?
    private let colorWell = NSColorWell()
    private let widthPicker = NSPopUpButton()
    private var widthGroup = NSStackView()
    private var colorGroup = NSStackView()
    private var swatches: [(NSButton, NSColor)] = []
    private let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .black, .white]
    private let fillToggle = NSButton(checkboxWithTitle: "填充", target: nil, action: nil)
    private let fillWell = NSColorWell()
    private let dashPicker = NSPopUpButton()
    private let opacitySlider = NSSlider(value: 1, minValue: 0.05, maxValue: 1, target: nil, action: nil)
    private let radiusField = NSTextField(string: "0")
    private let rotationField = NSTextField(string: "0")
    private let fontPicker = NSPopUpButton()
    private let sizeField = NSTextField(string: "20")
    private let boldButton = NSButton(title: "B", target: nil, action: nil)
    private let italicButton = NSButton(title: "I", target: nil, action: nil)
    private let underlineButton = NSButton(title: "U", target: nil, action: nil)
    private let hint = NSTextField(labelWithString: "选择标注后拖动控制点；⇧ 保持比例 / 吸附角度")
    private var fillGroup = NSStackView(), dashGroup = NSStackView(), radiusGroup = NSStackView()
    private var opacityGroup = NSStackView(), rotationGroup = NSStackView(), textGroup = NSStackView()
    private let fontNames = ["Helvetica", "TimesNewRomanPSMT", "Menlo-Regular"]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .horizontal; spacing = 7; alignment = .centerY; detachesHiddenViews = true
        edgeInsets = NSEdgeInsets(top: 5, left: 9, bottom: 5, right: 9)
        widthPicker.addItems(withTitles: ["1", "3", "6", "10", "16", "24"])
        widthPicker.target = self; widthPicker.action = #selector(changeWidth); widthPicker.controlSize = .small
        widthPicker.identifier = NSUserInterfaceItemIdentifier("annotation.lineWidth")
        widthPicker.setAccessibilityLabel("线宽（像素）"); fixedWidth(widthPicker, 49)
        widthGroup = group([widthPicker])
        colorWell.controlSize = .small; colorWell.target = self; colorWell.action = #selector(changeColor)
        colorWell.identifier = NSUserInterfaceItemIdentifier("annotation.color")
        colorWell.setAccessibilityLabel("自定义标注颜色"); fixedWidth(colorWell, 25)
        colorGroup = group([colorWell]); colorGroup.spacing = 3
        for (index, color) in colors.enumerated() {
            let button = NSButton(title: "", target: self, action: #selector(selectColor(_:)))
            button.tag = index; button.isBordered = false; button.wantsLayer = true
            button.layer?.backgroundColor = color.cgColor; button.layer?.borderColor = NSColor.gray.cgColor; button.layer?.borderWidth = 0.5
            button.identifier = NSUserInterfaceItemIdentifier("annotation.swatch.\(index)")
            button.setAccessibilityLabel(["红色", "橙色", "黄色", "绿色", "蓝色", "紫色", "黑色", "白色"][index])
            button.toolTip = ["红色", "橙色", "黄色", "绿色", "蓝色", "紫色", "黑色", "白色"][index]; fixedWidth(button, 17)
            button.heightAnchor.constraint(equalToConstant: 17).isActive = true
            colorGroup.addArrangedSubview(button); swatches.append((button, color))
        }
        fillToggle.target = self; fillToggle.action = #selector(changeFill)
        fillToggle.identifier = NSUserInterfaceItemIdentifier("annotation.fill")
        fillToggle.controlSize = .small
        fillWell.target = self; fillWell.action = #selector(changeFillColor)
        fillWell.identifier = NSUserInterfaceItemIdentifier("annotation.fillColor")
        fillWell.setAccessibilityLabel("填充 / 文字背景颜色"); fixedWidth(fillWell, 28)
        fillGroup = group([fillToggle, fillWell])
        dashPicker.addItems(withTitles: AnnotationStrokeStyle.allCases.map(\.title))
        dashPicker.target = self; dashPicker.action = #selector(changeDash); dashPicker.controlSize = .small
        dashPicker.identifier = NSUserInterfaceItemIdentifier("annotation.strokeStyle")
        dashPicker.setAccessibilityLabel("线条样式"); fixedWidth(dashPicker, 64)
        dashGroup = group([dashPicker])
        opacitySlider.target = self; opacitySlider.action = #selector(changeOpacity); opacitySlider.isContinuous = false
        opacitySlider.identifier = NSUserInterfaceItemIdentifier("annotation.opacity")
        opacitySlider.setAccessibilityLabel("不透明度"); opacitySlider.toolTip = "不透明遮盖始终为 100%，不会显示原始像素"
        fixedWidth(opacitySlider, 42); opacityGroup = group([opacitySlider])
        configureField(radiusField, id: "annotation.radius", label: "圆角半径（像素）", action: #selector(changeRadius))
        radiusGroup = group([label("圆角"), radiusField])
        configureField(rotationField, id: "annotation.rotation", label: "旋转角度", action: #selector(changeRotation))
        rotationGroup = group([label("旋转 °"), rotationField])
        fontPicker.addItems(withTitles: ["无衬线", "衬线", "等宽"])
        fontPicker.target = self; fontPicker.action = #selector(changeFont); fontPicker.controlSize = .small
        fontPicker.identifier = NSUserInterfaceItemIdentifier("annotation.font")
        fontPicker.setAccessibilityLabel("字体"); fixedWidth(fontPicker, 72)
        configureField(sizeField, id: "annotation.fontSize", label: "字号（像素）", action: #selector(changeFontSize))
        for (button, identifier, title) in [(boldButton, "bold", "粗体"), (italicButton, "italic", "斜体"), (underlineButton, "underline", "下划线")] {
            button.setButtonType(.toggle); button.bezelStyle = .texturedRounded; button.controlSize = .small
            button.identifier = NSUserInterfaceItemIdentifier("annotation.\(identifier)")
            button.setAccessibilityLabel(title); button.toolTip = title
            button.target = self; button.action = #selector(changeTextTraits); fixedWidth(button, 25)
        }
        textGroup = group([fontPicker, sizeField, boldButton, italicButton, underlineButton])
        hint.font = .systemFont(ofSize: 10); hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail; hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [widthGroup, dashGroup, fillGroup, radiusGroup, textGroup, opacityGroup, rotationGroup, colorGroup] as [NSView] { addArrangedSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func fixedWidth(_ view: NSView, _ width: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false; view.widthAnchor.constraint(equalToConstant: width).isActive = true
    }
    private func label(_ value: String) -> NSTextField {
        let result = NSTextField(labelWithString: value); result.font = .systemFont(ofSize: 11)
        result.textColor = .secondaryLabelColor; return result
    }
    private func group(_ views: [NSView]) -> NSStackView {
        let result = NSStackView(views: views); result.orientation = .horizontal; result.spacing = 4
        result.alignment = .centerY; return result
    }
    private func configureField(_ field: NSTextField, id: String, label: String, action: Selector) {
        field.identifier = NSUserInterfaceItemIdentifier(id); field.setAccessibilityLabel(label)
        field.toolTip = label; field.controlSize = .small; field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.alignment = .right; field.target = self; field.action = action; fixedWidth(field, 35)
    }

    func display(annotation: ImageAnnotation, selected: Bool, enabled: Bool) {
        widthGroup.isHidden = !enabled || annotation.tool == .text
        colorGroup.isHidden = !enabled || [.blur, .pixelate].contains(annotation.tool)
        colorWell.color = NSColor(cgColor: annotation.color) ?? .systemRed
        let widths: [CGFloat] = [1, 3, 6, 10, 16, 24]
        let nearest = widths.indices.min { abs(widths[$0] - annotation.lineWidth) < abs(widths[$1] - annotation.lineWidth) } ?? 1
        widthPicker.selectItem(at: nearest)
        for (button, color) in swatches {
            let selectedColor = color.usingColorSpace(.sRGB), current = colorWell.color.usingColorSpace(.sRGB)
            let selected = selectedColor != nil && current != nil && abs(selectedColor!.redComponent - current!.redComponent) < 0.02 && abs(selectedColor!.greenComponent - current!.greenComponent) < 0.02 && abs(selectedColor!.blueComponent - current!.blueComponent) < 0.02
            button.layer?.borderWidth = selected ? 2 : 0.5
            button.layer?.borderColor = (selected ? NSColor.systemBlue : NSColor.gray).cgColor
        }
        fillGroup.isHidden = !enabled || !annotation.hasShapeFill
        dashGroup.isHidden = !enabled || ![ImageEditorTool.rectangle, .ellipse, .line, .arrow, .freehand].contains(annotation.tool)
        radiusGroup.isHidden = !enabled || ![ImageEditorTool.rectangle, .text].contains(annotation.tool)
        textGroup.isHidden = !enabled || annotation.tool != .text
        opacityGroup.isHidden = !enabled || annotation.tool == .redact
        rotationGroup.isHidden = !enabled || !selected
        hint.isHidden = enabled && annotation.tool == .text
        hint.stringValue = annotation.tool == .redact ? "遮盖始终不透明；旋转 / 缩放后请确认覆盖范围" : "拖动控制点缩放 / 旋转 · ⇧ 约束 · ⌘D 副本"
        fillToggle.title = annotation.tool == .text ? "背景" : "填充"
        fillToggle.state = annotation.fillEnabled ? .on : .off
        fillWell.color = NSColor(cgColor: annotation.fillColor) ?? .yellow; fillWell.isEnabled = annotation.fillEnabled
        dashPicker.selectItem(at: AnnotationStrokeStyle.allCases.firstIndex(of: annotation.strokeStyle) ?? 0)
        opacitySlider.doubleValue = Double(annotation.opacity)
        radiusField.integerValue = Int(annotation.cornerRadius.rounded())
        rotationField.integerValue = Int((annotation.rotation * 180 / .pi).rounded())
        fontPicker.selectItem(at: fontNames.firstIndex(of: annotation.fontName) ?? 0)
        sizeField.integerValue = Int(annotation.effectiveFontSize.rounded())
        boldButton.state = annotation.bold ? .on : .off; italicButton.state = annotation.italic ? .on : .off
        underlineButton.state = annotation.underline ? .on : .off
    }

    func deactivateColorWells() { colorWell.deactivate(); fillWell.deactivate() }

    @objc private func changeColor() { let color = colorWell.color.cgColor; onEdit? { $0.color = color } }
    @objc private func selectColor(_ sender: NSButton) {
        guard colors.indices.contains(sender.tag) else { return }
        let color = colors[sender.tag].cgColor; onEdit? { $0.color = color }
    }
    @objc private func changeWidth() {
        let value = CGFloat(Double(widthPicker.titleOfSelectedItem ?? "3") ?? 3); onEdit? { $0.lineWidth = value }
    }
    @objc private func changeFill() { let enabled = fillToggle.state == .on; onEdit? { $0.fillEnabled = enabled } }
    @objc private func changeFillColor() { let color = fillWell.color.cgColor; onEdit? { $0.fillColor = color } }
    @objc private func changeDash() {
        let index = dashPicker.indexOfSelectedItem
        guard AnnotationStrokeStyle.allCases.indices.contains(index) else { return }
        let style = AnnotationStrokeStyle.allCases[index]; onEdit? { $0.strokeStyle = style }
    }
    @objc private func changeOpacity() { let value = CGFloat(opacitySlider.doubleValue); onEdit? { $0.opacity = value } }
    @objc private func changeRadius() { let value = max(0, min(500, CGFloat(radiusField.doubleValue))); onEdit? { $0.cornerRadius = value } }
    @objc private func changeRotation() {
        let degrees = rotationField.doubleValue
        guard degrees.isFinite else { return }
        let radians = CGFloat(degrees.truncatingRemainder(dividingBy: 360)) * .pi / 180
        onEdit? { $0.rotation = radians }
    }
    @objc private func changeFont() {
        guard fontNames.indices.contains(fontPicker.indexOfSelectedItem) else { return }
        let name = fontNames[fontPicker.indexOfSelectedItem]; onEdit? { $0.fontName = name }
    }
    @objc private func changeFontSize() { let value = max(8, min(300, CGFloat(sizeField.doubleValue))); onEdit? { $0.fontSize = value } }
    @objc private func changeTextTraits() {
        let bold = boldButton.state == .on, italic = italicButton.state == .on, underline = underlineButton.state == .on
        onEdit? { $0.bold = bold; $0.italic = italic; $0.underline = underline }
    }
}
