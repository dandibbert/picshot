import AppKit
import PicShotCore

/// Compact contextual rows. These controls edit the same model used by hit testing
/// and export; hidden controls have no separate preview-only state.
@MainActor
final class AnnotationInspector: EditorFloatingSurface {
    let numberControls = NumberedCalloutControls()
    var numberSequence = NumberedCalloutSequence()
    var numberCount = 0
    var onEdit: (((inout ImageAnnotation) -> Void) -> Void)?
    enum StyleAction: Int { case save, restore, reset }
    var onStyleAction: ((StyleAction, ImageAnnotation) -> Void)?
    var hasSavedStyle = false
    private let styleMenu = EditorToolbarPopupButton(frame: .zero, pullsDown: true)
    var onClearAnnotations: (() -> Void)?
    var onFinishPolyline: (() -> Void)?
    var onCancelPolyline: (() -> Void)?
    var onAutomaticMosaic: (() -> Void)?
    var onMosaicSync: ((Bool) -> Void)?
    var onMosaicAdd: (() -> Void)?
    private let automaticMosaicButton = NSButton(title: "查找相同内容…", target: nil, action: nil)
    private let mosaicSyncButton = NSButton(checkboxWithTitle: "同步增删", target: nil, action: nil)
    private let mosaicAddButton = NSButton(title: "+ 区域", target: nil, action: nil)
    private var mosaicGroup = NSStackView()
    var polylinePointCount = 0
    private var primaryRow = NSStackView()
    private let detailButton = NSButton(title: "…", target: nil, action: nil)
    private var detailsGroup = NSStackView()
    private var showsDetails = false
    private var previousTool: ImageEditorTool?
    private var displayedAnnotation = ImageAnnotation(tool: .arrow, points: [])
    private var displayedSelected = false, displayedEnabled = false
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
    private var textTraitsGroup = NSStackView()
    private let lineStyles = AnnotationLineStyleControls()
    private let textOutline = AnnotationTextOutlineControls()
    private let eraserModePicker = NSPopUpButton()
    private let clearAnnotationsButton = NSButton(title: "清空标注", target: nil, action: nil)
    private var eraserGroup = NSStackView()
    private let spotlightShapePicker = NSPopUpButton()
    private let spotlightDimSlider = NSSlider(value: 0.55, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let spotlightBorderToggle = NSButton(checkboxWithTitle: "边框", target: nil, action: nil)
    private var spotlightGroup = NSStackView()
    private let watermarkTemplateField = NSTextField(string: "PicShot · $yyyy-MM-dd HH:mm:ss$")
    private let watermarkPlacementPicker = NSPopUpButton()
    private let watermarkSpacingField = NSTextField(string: "48")
    private let watermarkTimestampButton = NSButton(title: "+ 时间", target: nil, action: nil)
    private var watermarkGroup = NSStackView(), watermarkSpacingGroup = NSStackView()
    private let magnifierShapePicker = NSPopUpButton()
    private let magnifierScaleField = NSTextField(string: "2")
    private let magnifierConnectorPicker = NSPopUpButton()
    private let magnifierSmoothToggle = NSButton(checkboxWithTitle: "平滑", target: nil, action: nil)
    private let magnifierShadowToggle = NSButton(checkboxWithTitle: "阴影", target: nil, action: nil)
    private let magnifierAnnotationsToggle = NSButton(checkboxWithTitle: "包含标注", target: nil, action: nil)
    private var magnifierGroup = NSStackView(), magnifierOptionsGroup = NSStackView()
    private let arcStartField = NSTextField(string: "0")
    private let arcSweepField = NSTextField(string: "270")
    private var arcAnglesGroup = NSStackView()
    private let pathFinishButton = NSButton(title: "完成", target: nil, action: nil)
    private let pathCancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let pathHint = NSTextField(labelWithString: "单击加点 · 双击/↩完成 · ⌫退点")
    private var pathActionsGroup = NSStackView()
    private let pencilSmoothToggle = NSButton(checkboxWithTitle: "平滑", target: nil, action: nil)
    private let pencilConstraintPicker = NSPopUpButton()
    private let highlighterModePicker = NSPopUpButton()
    private let highlighterBlendPicker = NSPopUpButton()
    private var pencilGroup = NSStackView(), highlighterGroup = NSStackView()
    private let fontNames = ["Helvetica", "TimesNewRomanPSMT", "Menlo-Regular"]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .vertical; spacing = 5; alignment = .leading; detachesHiddenViews = true
        edgeInsets = NSEdgeInsets(top: 5, left: 9, bottom: 5, right: 9)
        automaticMosaicButton.target = self; automaticMosaicButton.action = #selector(findAutomaticMosaic)
        automaticMosaicButton.identifier = .init("annotation.automaticMosaic")
        automaticMosaicButton.toolTip = "在原始截图中查找同尺寸、未旋转的相同内容"
        automaticMosaicButton.controlSize = .small; automaticMosaicButton.bezelStyle = .rounded
        mosaicSyncButton.target = self; mosaicSyncButton.action = #selector(changeMosaicSync)
        mosaicSyncButton.identifier = .init("annotation.mosaicSync"); mosaicSyncButton.controlSize = .small
        mosaicSyncButton.toolTip = "开启时，区域增删和样式会应用到已包括的相同内容；排除项不会恢复"
        mosaicAddButton.target = self; mosaicAddButton.action = #selector(addMosaicRegion)
        mosaicAddButton.identifier = .init("annotation.mosaicAdd"); mosaicAddButton.controlSize = .small
        mosaicAddButton.toolTip = "拖出补充区域；同步开启时，在相同内容的对应位置添加"
        mosaicGroup = group([automaticMosaicButton, mosaicSyncButton, mosaicAddButton])
        widthPicker.addItems(withTitles: ["1", "3", "4", "6", "10", "16", "24"])
        widthPicker.target = self; widthPicker.action = #selector(changeWidth); widthPicker.controlSize = .small
        widthPicker.identifier = NSUserInterfaceItemIdentifier("annotation.lineWidth")
        widthPicker.setAccessibilityLabel("线宽（像素）"); fixedWidth(widthPicker, 49)
        widthGroup = group([widthPicker])
        colorWell.isBordered = false; colorWell.controlSize = .small; colorWell.target = self; colorWell.action = #selector(changeColor)
        colorWell.identifier = NSUserInterfaceItemIdentifier("annotation.color")
        colorWell.setAccessibilityLabel("自定义标注颜色"); fixedWidth(colorWell, 20); colorWell.heightAnchor.constraint(equalToConstant: 20).isActive = true
        colorGroup = group([colorWell]); colorGroup.spacing = 3
        for (index, color) in colors.enumerated() {
            let button = NSButton(title: "", target: self, action: #selector(selectColor(_:)))
            button.tag = index; button.isBordered = false; button.wantsLayer = true
            button.layer?.cornerRadius = 2; button.layer?.backgroundColor = color.cgColor; button.layer?.borderColor = NSColor.gray.cgColor; button.layer?.borderWidth = 0.5
            button.identifier = NSUserInterfaceItemIdentifier("annotation.swatch.\(index)")
            button.setAccessibilityLabel(["红色", "橙色", "黄色", "绿色", "蓝色", "紫色", "黑色", "白色"][index])
            button.toolTip = ["红色", "橙色", "黄色", "绿色", "蓝色", "紫色", "黑色", "白色"][index]; fixedWidth(button, 17)
            button.heightAnchor.constraint(equalToConstant: 17).isActive = true
            colorGroup.addArrangedSubview(button); swatches.append((button, color))
        }
        fillToggle.target = self; fillToggle.action = #selector(changeFill)
        fillToggle.identifier = NSUserInterfaceItemIdentifier("annotation.fill")
        fillToggle.controlSize = .small
        fillWell.isBordered = false; fillWell.target = self; fillWell.action = #selector(changeFillColor)
        fillWell.identifier = NSUserInterfaceItemIdentifier("annotation.fillColor")
        fillWell.setAccessibilityLabel("填充 / 文字背景颜色"); fixedWidth(fillWell, 20); fillWell.heightAnchor.constraint(equalToConstant: 20).isActive = true
        fillGroup = group([fillToggle, fillWell])
        dashPicker.addItems(withTitles: AnnotationStrokeStyle.allCases.map(\.title))
        dashPicker.target = self; dashPicker.action = #selector(changeDash); dashPicker.controlSize = .small
        dashPicker.identifier = NSUserInterfaceItemIdentifier("annotation.strokeStyle")
        dashPicker.setAccessibilityLabel("线条样式"); fixedWidth(dashPicker, 64)
        dashGroup = group([dashPicker])
        opacitySlider.target = self; opacitySlider.action = #selector(changeOpacity); opacitySlider.isContinuous = false
        opacitySlider.identifier = NSUserInterfaceItemIdentifier("annotation.opacity")
        opacitySlider.setAccessibilityLabel("不透明度"); opacitySlider.toolTip = "调整当前标注的不透明度"
        fixedWidth(opacitySlider, 42); opacityGroup = group([label("不透明度"), opacitySlider])
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
        textTraitsGroup = group([boldButton, italicButton, underlineButton])
        textGroup = group([textTraitsGroup, fontPicker, sizeField])
        lineStyles.onEdit = { [weak self] edit in self?.onEdit?(edit) }
        textOutline.onEdit = { [weak self] edit in self?.onEdit?(edit) }
        configureToolControls()
        styleMenu.identifier = .init("annotation.savedStyles")
        styleMenu.controlSize = .small; styleMenu.bezelStyle = .rounded
        styleMenu.setAccessibilityLabel("此工具的默认样式")
        styleMenu.toolTip = "保存或恢复此工具的外观；仅用于以后新建，不修改已有标注"
        styleMenu.addItem(withTitle: "样式")
        styleMenu.item(at: 0)?.identifier = .init("annotation.savedStyles.title")
        styleMenu.item(at: 0)?.tag = -1
        styleMenu.menu?.autoenablesItems = false
        for (action, title, id) in [(StyleAction.save, "保存为此工具默认", "save"),
                                    (.restore, "恢复已保存样式", "restore"),
                                    (.reset, "重置为原始样式", "reset")] {
            let item = NSMenuItem(title: title, action: #selector(performStyleAction(_:)), keyEquivalent: "")
            item.tag = action.rawValue; item.target = self; item.identifier = .init("annotation.savedStyles." + id)
            styleMenu.menu?.addItem(item)
        }
        styleMenu.menu?.addItem(.separator())
        let scope = NSMenuItem(title: "仅用于以后新建，不改现有标注", action: nil, keyEquivalent: "")
        scope.identifier = .init("annotation.savedStyles.scope")
        scope.isEnabled = false; styleMenu.menu?.addItem(scope)
        fixedWidth(styleMenu, 60)
        numberControls.onEdit = { [weak self] edit in self?.onEdit?(edit) }
        hint.font = .systemFont(ofSize: 10); hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail; hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailButton.target = self; detailButton.action = #selector(toggleDetails)
        detailButton.isBordered = false; detailButton.font = .systemFont(ofSize: 17, weight: .medium)
        detailButton.identifier = NSUserInterfaceItemIdentifier("annotation.details")
        detailButton.setAccessibilityLabel("更多样式：不透明度、旋转、圆角、端点与连接"); detailButton.toolTip = "更多样式"
        fixedWidth(detailButton, 24)
        detailsGroup = group([opacityGroup, rotationGroup, radiusGroup])
        primaryRow = group([textGroup, widthGroup, dashGroup, fillGroup, colorGroup, detailButton])
        primaryRow.spacing = 7; detailsGroup.spacing = 7
        addArrangedSubview(primaryRow); addArrangedSubview(detailsGroup)
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
        result.alignment = .centerY; result.detachesHiddenViews = true; return result
    }
    private func configureField(_ field: NSTextField, id: String, label: String, action: Selector) {
        field.identifier = NSUserInterfaceItemIdentifier(id); field.setAccessibilityLabel(label)
        field.toolTip = label; field.controlSize = .small; field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.alignment = .right; field.target = self; field.action = action; fixedWidth(field, 35)
    }

    private func configurePicker(_ picker: NSPopUpButton, titles: [String], id: String, label: String,
                                 width: CGFloat = 68, action: Selector) {
        picker.addItems(withTitles: titles); picker.target = self; picker.action = action; picker.controlSize = .small
        picker.identifier = NSUserInterfaceItemIdentifier(id); picker.setAccessibilityLabel(label); picker.toolTip = label
        fixedWidth(picker, width)
    }

    private func configureToggle(_ button: NSButton, id: String, label: String, action: Selector) {
        button.target = self; button.action = action; button.controlSize = .small
        button.identifier = NSUserInterfaceItemIdentifier(id); button.setAccessibilityLabel(label); button.toolTip = label
    }

    private func configureToolControls() {
        configureToggle(pencilSmoothToggle, id: "annotation.pencilSmoothing", label: "平滑笔迹", action: #selector(changePencilSmoothing))
        pencilSmoothToggle.toolTip = "对画笔样本做有界平滑；Shift 直线保持笔直"
        configurePicker(pencilConstraintPicker, titles: AnnotationPencilConstraint.allCases.map(\.title),
                        id: "annotation.pencilConstraint", label: "按住 Shift 时的直线角度", width: 92, action: #selector(changePencilConstraint))
        pencilConstraintPicker.toolTip = "绘制时随时按住 Shift，以当前位置为起点画直线；松开继续手绘"
        pencilGroup = group([pencilSmoothToggle, label("⇧"), pencilConstraintPicker])
        configurePicker(highlighterModePicker, titles: AnnotationHighlighterMode.allCases.map(\.title),
                        id: "annotation.highlighterMode", label: "荧光笔形状", action: #selector(changeHighlighterMode))
        configurePicker(highlighterBlendPicker, titles: AnnotationHighlighterBlend.allCases.map(\.title),
                        id: "annotation.highlighterBlend", label: "荧光笔混合模式", width: 82, action: #selector(changeHighlighterBlend))
        highlighterBlendPicker.toolTip = "正片叠底适合浅色背景并保留深色字；半透明适合深色背景"
        highlighterGroup = group([highlighterModePicker, highlighterBlendPicker])
        configureField(arcStartField, id: "annotation.arcStart", label: "圆弧起始角度（度）", action: #selector(changeArcStart))
        configureField(arcSweepField, id: "annotation.arcSweep", label: "圆弧扫过角度（±1–360 度，负数顺时针）", action: #selector(changeArcSweep))
        arcAnglesGroup = group([label("起点 °"), arcStartField, label("扫角 °"), arcSweepField])
        for (button, id, text, action) in [
            (pathFinishButton, "annotation.finishPolyline", "完成折线 · Return / 双击", #selector(finishPolyline)),
            (pathCancelButton, "annotation.cancelPolyline", "取消折线 · Escape", #selector(cancelPolyline))] {
            button.bezelStyle = .rounded
            configureToggle(button, id: id, label: text, action: action)
        }
        pathHint.font = .systemFont(ofSize: 10); pathHint.textColor = .secondaryLabelColor
        pathHint.identifier = NSUserInterfaceItemIdentifier("annotation.polylineHint")
        pathHint.toolTip = "逐点单击；Shift 吸附 45°；双击或 Return 完成；Backspace / ⌘Z 撤回一点；Escape 取消；最多 256 个顶点"
        pathActionsGroup = group([pathFinishButton, pathCancelButton, pathHint])

        configurePicker(eraserModePicker, titles: AnnotationEraserMode.allCases.map(\.title),
                        id: "annotation.eraserMode", label: "橡皮擦模式", action: #selector(changeEraserMode))
        eraserGroup = group([eraserModePicker])
        clearAnnotationsButton.target = self; clearAnnotationsButton.action = #selector(clearAnnotations)
        clearAnnotationsButton.bezelStyle = .rounded; clearAnnotationsButton.controlSize = .small
        clearAnnotationsButton.identifier = NSUserInterfaceItemIdentifier("annotation.clearAnnotations")
        clearAnnotationsButton.setAccessibilityLabel("清空全部标注")
        clearAnnotationsButton.toolTip = "清空全部标注，可撤销；原始图片保持不变"

        configurePicker(spotlightShapePicker, titles: AnnotationRegionShape.allCases.map(\.title),
                        id: "annotation.spotlightShape", label: "聚光灯形状", action: #selector(changeSpotlightShape))
        spotlightDimSlider.target = self; spotlightDimSlider.action = #selector(changeSpotlightDim); spotlightDimSlider.isContinuous = false
        spotlightDimSlider.identifier = NSUserInterfaceItemIdentifier("annotation.spotlightDim")
        spotlightDimSlider.setAccessibilityLabel("聚光灯外部暗度"); spotlightDimSlider.toolTip = "调整聚光灯外部的暗度"
        fixedWidth(spotlightDimSlider, 66)
        configureToggle(spotlightBorderToggle, id: "annotation.spotlightBorder", label: "显示聚光灯边框", action: #selector(changeSpotlightBorder))
        spotlightGroup = group([spotlightShapePicker, label("暗度"), spotlightDimSlider, spotlightBorderToggle])

        watermarkTemplateField.identifier = NSUserInterfaceItemIdentifier("annotation.watermarkTemplate")
        watermarkTemplateField.setAccessibilityLabel("水印文字与时间模板")
        watermarkTemplateField.toolTip = "可插入 $yyyy-MM-dd HH:mm:ss$；时间固定为此截图的时间，回车确认"
        watermarkTemplateField.font = .systemFont(ofSize: 11); watermarkTemplateField.controlSize = .small
        watermarkTemplateField.target = self; watermarkTemplateField.action = #selector(changeWatermarkTemplate)
        watermarkTemplateField.placeholderString = "水印文字"; fixedWidth(watermarkTemplateField, 230)
        watermarkTimestampButton.target = self; watermarkTimestampButton.action = #selector(insertWatermarkTimestamp)
        watermarkTimestampButton.bezelStyle = .rounded; watermarkTimestampButton.controlSize = .small
        watermarkTimestampButton.identifier = NSUserInterfaceItemIdentifier("annotation.watermarkTimestamp")
        watermarkTimestampButton.setAccessibilityLabel("插入水印时间模板")
        watermarkTimestampButton.toolTip = "插入 $yyyy-MM-dd HH:mm:ss$（使用水印创建时的时间）"
        configurePicker(watermarkPlacementPicker, titles: AnnotationWatermarkPlacement.allCases.map(\.title),
                        id: "annotation.watermarkPlacement", label: "水印位置", width: 88, action: #selector(changeWatermarkPlacement))
        configureField(watermarkSpacingField, id: "annotation.watermarkSpacing", label: "平铺水印间距（像素）", action: #selector(changeWatermarkSpacing))
        watermarkGroup = group([watermarkTemplateField, watermarkTimestampButton, watermarkPlacementPicker])
        watermarkSpacingGroup = group([label("间距"), watermarkSpacingField])

        configurePicker(magnifierShapePicker, titles: AnnotationRegionShape.allCases.map(\.title),
                        id: "annotation.magnifierShape", label: "放大镜形状", action: #selector(changeMagnifierShape))
        configureField(magnifierScaleField, id: "annotation.magnifierScale", label: "放大倍数（1–8 倍）", action: #selector(changeMagnifierScale))
        configurePicker(magnifierConnectorPicker, titles: AnnotationMagnifierConnector.allCases.map(\.title),
                        id: "annotation.magnifierConnector", label: "放大镜连接线", width: 80, action: #selector(changeMagnifierConnector))
        configureToggle(magnifierSmoothToggle, id: "annotation.magnifierSmooth", label: "平滑放大像素", action: #selector(changeMagnifierOptions))
        configureToggle(magnifierShadowToggle, id: "annotation.magnifierShadow", label: "显示放大镜阴影", action: #selector(changeMagnifierOptions))
        configureToggle(magnifierAnnotationsToggle, id: "annotation.magnifierShowsAnnotations", label: "放大内容包含已有标注", action: #selector(changeMagnifierOptions))
        magnifierAnnotationsToggle.toolTip = "隐藏普通标注；不透明遮盖始终保留，避免放大镜泄露已遮盖内容"
        magnifierGroup = group([magnifierShapePicker, label("倍数"), magnifierScaleField])
        magnifierOptionsGroup = group([label("连接线"), magnifierConnectorPicker, magnifierSmoothToggle, magnifierShadowToggle, magnifierAnnotationsToggle])
    }

    private func configureRows(for tool: ImageEditorTool) {
        // Reparent only when the tool changes. No duplicate controls or independent style state.
        for row in [primaryRow, detailsGroup] {
            for view in row.arrangedSubviews { row.removeArrangedSubview(view); view.removeFromSuperview() }
        }
        let primary: [NSView], secondary: [NSView]
        widthPicker.removeAllItems()
        widthPicker.addItems(withTitles: [.freehand, .highlighter].contains(tool)
            ? ["1", "3", "4", "6", "10", "16", "24", "32", "48", "64", "96", "128", "256"]
            : (tool == .eraser ? ["4", "8", "16", "24", "32", "48", "64", "96"] : ["1", "3", "4", "6", "10", "16", "24"]))
        switch tool {
        case .freehand:
            primary = [widthGroup, dashGroup, colorGroup]
            secondary = [pencilGroup, opacityGroup, rotationGroup]
        case .highlighter:
            primary = [highlighterGroup, widthGroup, colorGroup]
            secondary = [pencilGroup, opacityGroup, rotationGroup]
        case .number:
            primary = [numberControls.primary, widthGroup, colorGroup]
            secondary = [numberControls.details, opacityGroup, rotationGroup]
        case .arc, .sector:
            primary = [widthGroup, dashGroup, fillGroup, colorGroup]
            secondary = [arcAnglesGroup, opacityGroup, rotationGroup]
        case .polyline:
            primary = [widthGroup, dashGroup, lineStyles.endings, colorGroup]
            secondary = [pathActionsGroup, lineStyles.stroke, opacityGroup, rotationGroup]
        case .line, .arrow:
            primary = [widthGroup, dashGroup, lineStyles.endings, colorGroup, detailButton]
            secondary = [lineStyles.stroke, opacityGroup, rotationGroup]
        case .text:
            primary = [textGroup, textOutline.row, fillGroup, colorGroup, detailButton]
            secondary = [opacityGroup, rotationGroup, radiusGroup]
        case .eraser:
            primary = [eraserGroup, widthGroup, clearAnnotationsButton]; secondary = []
        case .spotlight:
            primary = [spotlightGroup, widthGroup, colorGroup]; secondary = []
        case .watermark:
            primary = [watermarkGroup]; secondary = [textGroup, opacityGroup, watermarkSpacingGroup, colorGroup]
        case .magnifier:
            primary = [magnifierGroup, widthGroup, colorGroup]; secondary = [magnifierOptionsGroup]
        case .pixelate, .blur, .redact:
            primary = [widthGroup, colorGroup, detailButton]; secondary = [mosaicGroup, opacityGroup]
        default:
            primary = [textGroup, widthGroup, dashGroup, fillGroup, colorGroup, detailButton]
            secondary = [opacityGroup, rotationGroup, radiusGroup]
        }
        (primary + [styleMenu]).forEach { primaryRow.addArrangedSubview($0) }
        secondary.forEach { detailsGroup.addArrangedSubview($0) }
    }

    func display(annotation: ImageAnnotation, selected: Bool, enabled: Bool) {
        if previousTool != annotation.tool { showsDetails = false; configureRows(for: annotation.tool) }
        previousTool = annotation.tool; displayedAnnotation = annotation; displayedSelected = selected; displayedEnabled = enabled
        let supportsStyle = AnnotationStyleSettings.Tool(rawValue: annotation.tool.rawValue) != nil
        styleMenu.isHidden = !enabled || !supportsStyle
        styleMenu.itemArray.first { $0.identifier?.rawValue == "annotation.savedStyles.scope" }?.title = annotation.tool == .redact
            ? "新遮盖始终为不透明黑色，不改现有标注" : "仅用于以后新建，不改现有标注"
        for item in styleMenu.itemArray {
            guard item.target === self, item.action == #selector(performStyleAction(_:)),
                  let action = StyleAction(rawValue: item.tag) else { continue }
            item.isEnabled = enabled && supportsStyle && onStyleAction != nil && (action != .restore || hasSavedStyle)
            switch action {
            case .save: item.title = "保存为\(annotation.tool.title)默认样式"
            case .restore: item.title = "恢复\(annotation.tool.title)已保存样式"
            case .reset: item.title = "重置\(annotation.tool.title)为原始样式"
            }
        }
        let dedicatedRows: [ImageEditorTool] = [.eraser, .spotlight, .watermark, .magnifier, .arc, .sector, .polyline, .freehand, .highlighter, .number]
        let alwaysShowsDetails = [.watermark, .magnifier, .arc, .sector, .polyline, .pixelate, .blur, .redact, .freehand, .highlighter, .number].contains(annotation.tool)
        primaryRow.isHidden = !enabled
        detailsGroup.isHidden = !enabled || detailsGroup.arrangedSubviews.isEmpty || (!alwaysShowsDetails && !showsDetails)
        detailButton.isHidden = !enabled || dedicatedRows.contains(annotation.tool) || [.pixelate, .blur, .redact].contains(annotation.tool)
        detailButton.setAccessibilityValue(showsDetails ? "已展开" : "已收起")
        widthGroup.isHidden = !enabled || [.text, .watermark].contains(annotation.tool)
            || (annotation.tool == .spotlight && !annotation.spotlightBorder)
            || (annotation.tool == .eraser && annotation.eraserMode == .rectangle)
            || (annotation.tool == .highlighter && annotation.highlighterMode == .rectangle)
        widthPicker.setAccessibilityLabel(annotation.tool == .eraser ? "橡皮擦宽度（像素）" : "线宽（像素）")
        widthPicker.toolTip = annotation.tool == .eraser ? "橡皮擦宽度（像素）" : "线宽（像素）"
        if annotation.tool == .number {
            widthPicker.setAccessibilityLabel("序号大小，半径为线宽的四倍（14–80 像素）")
            widthPicker.toolTip = "序号大小，也可滚轮调整或用选择工具拖动右上控制点"
            numberControls.display(annotation: annotation, selected: selected, sequence: numberSequence, count: numberCount)
        }
        colorGroup.isHidden = !enabled || [.blur, .pixelate, .eraser].contains(annotation.tool)
            || (annotation.tool == .spotlight && !annotation.spotlightBorder)
        colorWell.color = NSColor(cgColor: annotation.color) ?? .systemRed
        let widthTitle = annotation.lineWidth.rounded() == annotation.lineWidth ? String(Int(annotation.lineWidth)) : String(format: "%.1f", annotation.lineWidth)
        if widthPicker.item(withTitle: widthTitle) == nil { widthPicker.addItem(withTitle: widthTitle) }
        widthPicker.selectItem(withTitle: widthTitle)
        for (button, color) in swatches {
            let selectedColor = color.usingColorSpace(.sRGB), current = colorWell.color.usingColorSpace(.sRGB)
            let selected = selectedColor != nil && current != nil && abs(selectedColor!.redComponent - current!.redComponent) < 0.02 && abs(selectedColor!.greenComponent - current!.greenComponent) < 0.02 && abs(selectedColor!.blueComponent - current!.blueComponent) < 0.02
            button.layer?.borderWidth = selected ? 2 : 0.5
            button.layer?.borderColor = (selected ? NSColor.systemBlue : NSColor.gray).cgColor
        }
        fillGroup.isHidden = !enabled || !annotation.hasShapeFill
        dashGroup.isHidden = !enabled || ![ImageEditorTool.rectangle, .ellipse, .line, .arrow, .freehand, .arc, .sector, .polyline].contains(annotation.tool)
        radiusGroup.isHidden = !enabled || ![ImageEditorTool.rectangle, .text].contains(annotation.tool)
        textGroup.isHidden = !enabled || ![.text, .watermark].contains(annotation.tool)
        textTraitsGroup.isHidden = annotation.tool == .watermark
        opacityGroup.isHidden = !enabled || annotation.tool == .redact
        rotationGroup.isHidden = !enabled || !selected
        hint.isHidden = enabled && annotation.tool == .text
        hint.stringValue = annotation.tool == .redact ? "遮盖始终不透明；请确认覆盖范围" :
            ([ImageEditorTool.blur, .pixelate].contains(annotation.tool) ? "模糊/马赛克不能安全隐藏敏感内容；可改用遮盖" : "拖动控制点 · ⇧ 约束 · ⌥点击穿透 · ⌘D 副本")
        mosaicGroup.isHidden = !enabled || !selected
        automaticMosaicButton.isEnabled = enabled && selected && annotation.supportsAutomaticMosaic
        automaticMosaicButton.toolTip = annotation.mosaicLink == nil ? "在原始截图中查找同尺寸、未旋转的相同内容" : "已关联的结果可用同步/补充区域编辑；重新查找请新建选区"
        mosaicSyncButton.isHidden = annotation.mosaicLink == nil; mosaicAddButton.isHidden = annotation.mosaicLink == nil
        mosaicSyncButton.state = annotation.mosaicLink?.synchronizes == true ? .on : .off
        arcStartField.stringValue = String(format: "%g", Double(annotation.effectiveArcStart * 180 / .pi))
        arcSweepField.stringValue = String(format: "%g", Double(annotation.effectiveArcSweep * 180 / .pi))
        pathFinishButton.isEnabled = polylinePointCount >= 2
        pathCancelButton.isEnabled = polylinePointCount > 0
        pathFinishButton.isHidden = selected && polylinePointCount == 0
        pathCancelButton.isHidden = selected && polylinePointCount == 0
        pathHint.stringValue = selected && polylinePointCount == 0 ? "拖动顶点 · ⇧ 吸附角度" : "单击加点 · 双击/↩完成 · ⌫退点"
        fillToggle.title = annotation.tool == .text ? "背景" : "填充"
        fillToggle.state = annotation.fillEnabled ? .on : .off
        fillWell.color = NSColor(cgColor: annotation.fillColor) ?? .yellow; fillWell.isEnabled = annotation.fillEnabled; fillWell.isHidden = !annotation.fillEnabled
        dashPicker.selectItem(at: AnnotationStrokeStyle.allCases.firstIndex(of: annotation.strokeStyle) ?? 0)
        opacitySlider.doubleValue = Double(annotation.opacity)
        radiusField.integerValue = Int(annotation.cornerRadius.rounded())
        rotationField.integerValue = Int((annotation.rotation * 180 / .pi).rounded())
        fontPicker.selectItem(at: fontNames.firstIndex(of: annotation.fontName) ?? 0)
        sizeField.integerValue = Int(annotation.effectiveFontSize.rounded())
        boldButton.state = annotation.bold ? .on : .off; italicButton.state = annotation.italic ? .on : .off
        underlineButton.state = annotation.underline ? .on : .off
        lineStyles.display(annotation); textOutline.display(annotation)

        pencilSmoothToggle.state = annotation.freehandSmoothing ? .on : .off
        pencilConstraintPicker.selectItem(at: AnnotationPencilConstraint.allCases.firstIndex(of: annotation.freehandConstraint) ?? 0)
        highlighterModePicker.selectItem(at: AnnotationHighlighterMode.allCases.firstIndex(of: annotation.highlighterMode) ?? 0)
        highlighterBlendPicker.selectItem(at: AnnotationHighlighterBlend.allCases.firstIndex(of: annotation.highlighterBlend) ?? 0)
        pencilGroup.isHidden = !enabled || (annotation.tool == .highlighter && annotation.highlighterMode == .rectangle)
        eraserModePicker.selectItem(at: AnnotationEraserMode.allCases.firstIndex(of: annotation.eraserMode) ?? 0)
        clearAnnotationsButton.isEnabled = enabled && onClearAnnotations != nil
        spotlightShapePicker.selectItem(at: AnnotationRegionShape.allCases.firstIndex(of: annotation.spotlightShape) ?? 0)
        spotlightDimSlider.doubleValue = Double(annotation.spotlightDim)
        spotlightBorderToggle.state = annotation.spotlightBorder ? .on : .off
        watermarkTemplateField.toolTip = annotation.timestampIsCaptureDate
            ? "可插入 $yyyy-MM-dd HH:mm:ss$；时间固定为此截图的时间，回车确认"
            : "图片未提供拍摄时间；时间变量固定为本次编辑开始时间，回车确认"
        if watermarkTemplateField.stringValue != annotation.watermarkTemplate { watermarkTemplateField.stringValue = annotation.watermarkTemplate }
        watermarkPlacementPicker.selectItem(at: AnnotationWatermarkPlacement.allCases.firstIndex(of: annotation.watermarkPlacement) ?? 0)
        watermarkSpacingField.integerValue = Int(annotation.watermarkSpacing.rounded())
        watermarkSpacingGroup.isHidden = !enabled || annotation.watermarkPlacement != .tiled
        magnifierShapePicker.selectItem(at: AnnotationRegionShape.allCases.firstIndex(of: annotation.magnifierShape) ?? 0)
        magnifierScaleField.stringValue = String(format: "%g", Double(annotation.magnifierScale))
        magnifierConnectorPicker.selectItem(at: AnnotationMagnifierConnector.allCases.firstIndex(of: annotation.magnifierConnector) ?? 0)
        magnifierSmoothToggle.state = annotation.magnifierSmooth ? .on : .off
        magnifierShadowToggle.state = annotation.magnifierShadow ? .on : .off
        magnifierAnnotationsToggle.state = annotation.magnifierShowsAnnotations ? .on : .off
    }

    @objc private func performStyleAction(_ sender: NSMenuItem) {
        guard displayedEnabled, sender.isEnabled, let action = StyleAction(rawValue: sender.tag),
              AnnotationStyleSettings.Tool(rawValue: displayedAnnotation.tool.rawValue) != nil,
              action != .restore || hasSavedStyle else { return }
        onStyleAction?(action, displayedAnnotation)
    }

    @objc private func findAutomaticMosaic() { onAutomaticMosaic?() }
    @objc private func changeMosaicSync() { onMosaicSync?(mosaicSyncButton.state == .on) }
    @objc private func addMosaicRegion() { onMosaicAdd?() }

    @objc private func toggleDetails() {
        showsDetails.toggle()
        display(annotation: displayedAnnotation, selected: displayedSelected, enabled: displayedEnabled)
        superview?.needsLayout = true
    }

    func deactivateColorWells() { colorWell.deactivate(); fillWell.deactivate(); textOutline.deactivateColorWell() }

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

    @objc private func changePencilSmoothing() {
        let enabled = pencilSmoothToggle.state == .on; onEdit? { $0.freehandSmoothing = enabled }
    }
    @objc private func changePencilConstraint() {
        let index = pencilConstraintPicker.indexOfSelectedItem
        guard AnnotationPencilConstraint.allCases.indices.contains(index) else { return }
        let mode = AnnotationPencilConstraint.allCases[index]; onEdit? { $0.freehandConstraint = mode }
    }
    @objc private func changeHighlighterMode() {
        let index = highlighterModePicker.indexOfSelectedItem
        guard AnnotationHighlighterMode.allCases.indices.contains(index) else { return }
        let mode = AnnotationHighlighterMode.allCases[index]; onEdit? { $0.highlighterMode = mode }
    }
    @objc private func changeHighlighterBlend() {
        let index = highlighterBlendPicker.indexOfSelectedItem
        guard AnnotationHighlighterBlend.allCases.indices.contains(index) else { return }
        let blend = AnnotationHighlighterBlend.allCases[index]; onEdit? { $0.highlighterBlend = blend }
    }

    @objc private func changeArcStart() {
        let degrees = arcStartField.doubleValue
        guard degrees.isFinite else { return }
        let value = AnnotationArcGeometry.normalizedAngle(CGFloat(degrees.truncatingRemainder(dividingBy: 360)) * .pi / 180)
        onEdit? { $0.arcStartAngle = value }
    }
    @objc private func changeArcSweep() {
        let degrees = arcSweepField.doubleValue
        guard degrees.isFinite else { return }
        let value = AnnotationArcGeometry.boundedSweep(CGFloat(min(360, max(-360, degrees))) * .pi / 180)
        onEdit? { $0.arcSweepAngle = value }
    }
    @objc private func finishPolyline() { onFinishPolyline?() }
    @objc private func cancelPolyline() { onCancelPolyline?() }

    @objc private func changeEraserMode() {
        let index = eraserModePicker.indexOfSelectedItem
        guard AnnotationEraserMode.allCases.indices.contains(index) else { return }
        let mode = AnnotationEraserMode.allCases[index]; onEdit? { $0.eraserMode = mode }
    }
    @objc private func clearAnnotations() {
        guard displayedEnabled, displayedAnnotation.tool == .eraser else { return }
        onClearAnnotations?()
    }
    @objc private func changeSpotlightShape() {
        let index = spotlightShapePicker.indexOfSelectedItem
        guard AnnotationRegionShape.allCases.indices.contains(index) else { return }
        let shape = AnnotationRegionShape.allCases[index]; onEdit? { $0.spotlightShape = shape }
    }
    @objc private func changeSpotlightDim() {
        let value = CGFloat(spotlightDimSlider.doubleValue); onEdit? { $0.spotlightDim = value }
    }
    @objc private func changeSpotlightBorder() {
        let enabled = spotlightBorderToggle.state == .on; onEdit? { $0.spotlightBorder = enabled }
    }
    @objc private func changeWatermarkTemplate() {
        let value = watermarkTemplateField.stringValue; onEdit? { $0.watermarkTemplate = value }
    }
    @objc private func insertWatermarkTimestamp() {
        let token = "$yyyy-MM-dd HH:mm:ss$"
        let value: String
        if let editor = watermarkTemplateField.currentEditor() as? NSTextView {
            editor.insertText(token, replacementRange: editor.selectedRange())
            value = editor.string
        } else {
            let existing = watermarkTemplateField.stringValue
            let separator = existing.isEmpty || existing.last?.isWhitespace == true ? "" : " "
            value = existing + separator + token
        }
        watermarkTemplateField.stringValue = value
        // Only the template changes. The annotation's timestamp/time zone stay frozen.
        onEdit? { $0.watermarkTemplate = value }
    }
    @objc private func changeWatermarkPlacement() {
        let index = watermarkPlacementPicker.indexOfSelectedItem
        guard AnnotationWatermarkPlacement.allCases.indices.contains(index) else { return }
        let placement = AnnotationWatermarkPlacement.allCases[index]; onEdit? { $0.watermarkPlacement = placement }
    }
    @objc private func changeWatermarkSpacing() {
        let rawValue = watermarkSpacingField.doubleValue
        guard rawValue.isFinite else { return }
        let value = CGFloat(max(0, min(1_000, rawValue))); onEdit? { $0.watermarkSpacing = value }
    }
    @objc private func changeMagnifierShape() {
        let index = magnifierShapePicker.indexOfSelectedItem
        guard AnnotationRegionShape.allCases.indices.contains(index) else { return }
        let shape = AnnotationRegionShape.allCases[index]; onEdit? { $0.magnifierShape = shape }
    }
    @objc private func changeMagnifierScale() {
        let rawValue = magnifierScaleField.doubleValue
        guard rawValue.isFinite else { return }
        let value = CGFloat(max(1, min(8, rawValue))); onEdit? { $0.magnifierScale = value }
    }
    @objc private func changeMagnifierConnector() {
        let index = magnifierConnectorPicker.indexOfSelectedItem
        guard AnnotationMagnifierConnector.allCases.indices.contains(index) else { return }
        let connector = AnnotationMagnifierConnector.allCases[index]; onEdit? { $0.magnifierConnector = connector }
    }
    @objc private func changeMagnifierOptions() {
        let smooth = magnifierSmoothToggle.state == .on, shadow = magnifierShadowToggle.state == .on
        let annotations = magnifierAnnotationsToggle.state == .on
        onEdit? { $0.magnifierSmooth = smooth; $0.magnifierShadow = shadow; $0.magnifierShowsAnnotations = annotations }
    }
}
