import AppKit
import PicShotCore

/// Deliberately converts individual appearance fields; never archive ImageAnnotation.
/// Changing the annotation document schema cannot expand what preferences remember.
enum AnnotationStyleAdapter {
    static func original(tool: ImageEditorTool, captureTimestampKnown: Bool) -> ImageAnnotation {
        var result = ImageAnnotation(tool: tool, points: [], color: NSColor.systemRed.cgColor, fontSize: 20)
        result.freehandSmoothing = true
        result.highlighterMode = .freehand; result.highlighterBlend = .multiply
        if !captureTimestampKnown { result.watermarkTemplate = "PicShot · 编辑于 $yyyy-MM-dd HH:mm:ss$" }
        if tool == .redact { result.color = CGColor(gray: 0, alpha: 1) }
        return result
    }

    static func capture(_ annotation: ImageAnnotation) throws -> AnnotationStyleSettings.Style {
        guard let tool = AnnotationStyleSettings.Tool(rawValue: annotation.tool.rawValue) else {
            throw AnnotationStyleSettings.ValidationError.invalidToolFields
        }
        typealias Value = AnnotationStyleSettings.Value
        var values: [AnnotationStyleSettings.Field: Value] = [:]
        func color(_ value: CGColor) throws -> Value {
            guard let converted = NSColor(cgColor: value)?.usingColorSpace(.sRGB) else {
                throw AnnotationStyleSettings.ValidationError.invalidValue
            }
            let components = [converted.redComponent, converted.greenComponent, converted.blueComponent, converted.alphaComponent]
            guard components.allSatisfy(\.isFinite) else { throw AnnotationStyleSettings.ValidationError.invalidValue }
            let bounded = components.map { Double(min(1, max(0, $0))) }
            return .color(red: bounded[0], green: bounded[1], blue: bounded[2], alpha: bounded[3])
        }
        for field in tool.allowedFields {
            switch field {
            case .color: values[field] = try color(annotation.color)
            case .lineWidth: values[field] = .number(Double(annotation.tool == .number ? annotation.numberRadius / 4 : annotation.lineWidth))
            case .opacity: values[field] = .number(Double(annotation.opacity))
            case .strokeStyle: values[field] = .choice(annotation.strokeStyle.rawValue)
            case .lineCap: values[field] = .choice(annotation.lineCap.rawValue)
            case .lineJoin: values[field] = .choice(annotation.lineJoin.rawValue)
            case .startArrowEnabled: values[field] = .flag(annotation.startArrowEnabled)
            case .endArrowEnabled: values[field] = .flag(annotation.effectiveEndArrowEnabled)
            case .startArrowhead: values[field] = .choice(annotation.startArrowhead.rawValue)
            case .endArrowhead: values[field] = .choice(annotation.endArrowhead.rawValue)
            case .fillEnabled: values[field] = .flag(annotation.fillEnabled)
            case .fillColor: values[field] = try color(annotation.fillColor)
            case .cornerRadius: values[field] = .number(Double(annotation.cornerRadius))
            case .fontName: values[field] = .choice(annotation.fontName)
            case .fontSize: values[field] = .number(Double(annotation.tool == .number ? min(72, annotation.effectiveFontSize) : annotation.effectiveFontSize))
            case .bold: values[field] = .flag(annotation.bold)
            case .italic: values[field] = .flag(annotation.italic)
            case .underline: values[field] = .flag(annotation.underline)
            case .textOutlineEnabled: values[field] = .flag(annotation.textOutlineEnabled)
            case .textOutlineColor: values[field] = try color(annotation.textOutlineColor)
            case .textOutlineWidth: values[field] = .number(Double(annotation.textOutlineWidth))
            case .numberStyle: values[field] = .choice(annotation.numberStyle.rawValue)
            case .eraserMode: values[field] = .choice(annotation.eraserMode.rawValue)
            case .spotlightShape: values[field] = .choice(annotation.spotlightShape.rawValue)
            case .spotlightDim: values[field] = .number(Double(annotation.spotlightDim))
            case .spotlightBorder: values[field] = .flag(annotation.spotlightBorder)
            case .watermarkPlacement: values[field] = .choice(annotation.watermarkPlacement.rawValue)
            case .watermarkSpacing: values[field] = .number(Double(annotation.watermarkSpacing))
            case .magnifierScale: values[field] = .number(Double(annotation.magnifierScale))
            case .magnifierShape: values[field] = .choice(annotation.magnifierShape.rawValue)
            case .magnifierConnector: values[field] = .choice(annotation.magnifierConnector.rawValue)
            case .magnifierSmooth: values[field] = .flag(annotation.magnifierSmooth)
            case .magnifierShowsAnnotations: values[field] = .flag(annotation.magnifierShowsAnnotations)
            case .magnifierShadow: values[field] = .flag(annotation.magnifierShadow)
            case .freehandSmoothing: values[field] = .flag(annotation.freehandSmoothing)
            case .freehandConstraint: values[field] = .number(Double(annotation.freehandConstraint.rawValue))
            case .highlighterMode: values[field] = .choice(annotation.highlighterMode.rawValue)
            case .highlighterBlend: values[field] = .choice(annotation.highlighterBlend.rawValue)
            }
        }
        return try .init(tool: tool, values: values)
    }

    /// A validated preset can only change fields allowed for its exact tool.
    /// It never copies a selected object's text, geometry or creation metadata.
    static func apply(_ style: AnnotationStyleSettings.Style, to annotation: inout ImageAnnotation) {
        guard annotation.tool.rawValue == style.tool.rawValue else { return }
        func color(_ value: AnnotationStyleSettings.Value) -> CGColor? {
            guard case .color(let r, let g, let b, let a) = value else { return nil }
            return CGColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
        }
        for (field, value) in style.values {
            switch (field, value) {
            case (.color, _): if let color = color(value) { annotation.color = color }
            case (.fillColor, _): if let color = color(value) { annotation.fillColor = color }
            case (.textOutlineColor, _): if let color = color(value) { annotation.textOutlineColor = color }
            case (.lineWidth, .number(let n)): annotation.lineWidth = CGFloat(n)
            case (.opacity, .number(let n)): annotation.opacity = CGFloat(n)
            case (.cornerRadius, .number(let n)): annotation.cornerRadius = CGFloat(n)
            case (.fontSize, .number(let n)): annotation.fontSize = CGFloat(n)
            case (.textOutlineWidth, .number(let n)): annotation.textOutlineWidth = CGFloat(n)
            case (.spotlightDim, .number(let n)): annotation.spotlightDim = CGFloat(n)
            case (.watermarkSpacing, .number(let n)): annotation.watermarkSpacing = CGFloat(n)
            case (.magnifierScale, .number(let n)): annotation.magnifierScale = CGFloat(n)
            case (.freehandConstraint, .number(let n)): annotation.freehandConstraint = AnnotationPencilConstraint(rawValue: Int(n)) ?? .free
            case (.fillEnabled, .flag(let v)): annotation.fillEnabled = v
            case (.bold, .flag(let v)): annotation.bold = v
            case (.italic, .flag(let v)): annotation.italic = v
            case (.underline, .flag(let v)): annotation.underline = v
            case (.textOutlineEnabled, .flag(let v)): annotation.textOutlineEnabled = v
            case (.startArrowEnabled, .flag(let v)): annotation.startArrowEnabled = v
            case (.endArrowEnabled, .flag(let v)): annotation.endArrowEnabled = v
            case (.spotlightBorder, .flag(let v)): annotation.spotlightBorder = v
            case (.magnifierSmooth, .flag(let v)): annotation.magnifierSmooth = v
            case (.magnifierShowsAnnotations, .flag(let v)): annotation.magnifierShowsAnnotations = v
            case (.magnifierShadow, .flag(let v)): annotation.magnifierShadow = v
            case (.freehandSmoothing, .flag(let v)): annotation.freehandSmoothing = v
            case (.strokeStyle, .choice(let s)): annotation.strokeStyle = AnnotationStrokeStyle(rawValue: s) ?? .solid
            case (.lineCap, .choice(let s)): annotation.lineCap = AnnotationLineCap(rawValue: s) ?? .round
            case (.lineJoin, .choice(let s)): annotation.lineJoin = AnnotationLineJoin(rawValue: s) ?? .round
            case (.startArrowhead, .choice(let s)): annotation.startArrowhead = AnnotationArrowhead(rawValue: s) ?? .open
            case (.endArrowhead, .choice(let s)): annotation.endArrowhead = AnnotationArrowhead(rawValue: s) ?? .open
            case (.fontName, .choice(let s)): annotation.fontName = s
            case (.numberStyle, .choice(let s)): annotation.numberStyle = NumberedCalloutStyle(rawValue: s) ?? .decimal
            case (.eraserMode, .choice(let s)): annotation.eraserMode = AnnotationEraserMode(rawValue: s) ?? .brush
            case (.spotlightShape, .choice(let s)): annotation.spotlightShape = AnnotationRegionShape(rawValue: s) ?? .ellipse
            case (.watermarkPlacement, .choice(let s)): annotation.watermarkPlacement = AnnotationWatermarkPlacement(rawValue: s) ?? .tiled
            case (.magnifierShape, .choice(let s)): annotation.magnifierShape = AnnotationRegionShape(rawValue: s) ?? .ellipse
            case (.magnifierConnector, .choice(let s)): annotation.magnifierConnector = AnnotationMagnifierConnector(rawValue: s) ?? .line
            case (.highlighterMode, .choice(let s)): annotation.highlighterMode = AnnotationHighlighterMode(rawValue: s) ?? .freehand
            case (.highlighterBlend, .choice(let s)): annotation.highlighterBlend = AnnotationHighlighterBlend(rawValue: s) ?? .multiply
            default: break // Unreachable through the validated core initializer/decoder.
            }
        }
    }
}

/// Shared suite reads before each explicit write prevent an older editor from
/// dropping another editor's saved tool. No automatic style writes on drawing.
@MainActor
final class AnnotationStylePresetStore {
    private let defaults: UserDefaults?
    private var transient = AnnotationStyleSettings.defaults
    init(defaults: UserDefaults?) { self.defaults = defaults }
    var settings: AnnotationStyleSettings { defaults.map { .read(from: $0) } ?? transient }
    func save(_ annotation: ImageAnnotation) throws {
        let style = try AnnotationStyleAdapter.capture(annotation)
        var result = settings; result.save(style)
        if let defaults { try result.write(to: defaults) }
        transient = result
    }
    func reset(_ tool: ImageEditorTool) throws {
        guard let tool = AnnotationStyleSettings.Tool(rawValue: tool.rawValue) else { return }
        var result = settings; result.reset(tool)
        if let defaults { try result.write(to: defaults) }
        transient = result
    }
    func style(for tool: ImageEditorTool) -> AnnotationStyleSettings.Style? {
        guard let tool = AnnotationStyleSettings.Tool(rawValue: tool.rawValue) else { return nil }
        return settings.style(for: tool)
    }
}
