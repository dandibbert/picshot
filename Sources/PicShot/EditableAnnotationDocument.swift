import Foundation
import CoreGraphics
import PicShotCore

/// Only value metadata is serialized. Assets are immutable, separate PNG files;
/// storage owns safe filenames, atomic replacement, byte quotas and raster decoding.
/// Coordinates are current-base image pixels with a bottom-left origin. A reversible
/// crop viewport retains its base/layers; an irreversible raster edit starts a new
/// base. This format does not invent layers from flattened pixels.
enum EditableAnnotationBaseProvenance: String, Codable {
    case originalCapture, derivedRaster, legacyRaster
}

struct EditableAnnotationDocument {
    var documentID = UUID()
    var originalAssetID: UUID
    var originalPixelWidth: Int
    var originalPixelHeight: Int
    var baseAssetID: UUID
    var basePixelWidth: Int
    var basePixelHeight: Int
    /// Present only for a proven unflattened integral crop of the original raster.
    var baseCropInOriginal: CGRect? = nil
    var cropViewportInBase: CGRect? = nil
    var baseProvenance: EditableAnnotationBaseProvenance = .legacyRaster
    var capturedAt = Date(timeIntervalSince1970: 0)
    var captureTimeZoneIdentifier = "UTC"
    var captureTimestampKnown = false
    var annotations: [ImageAnnotation]
    var numberSequence = NumberedCalloutSequence()
    var outputDecoration = ImageOutputDecoration.none

    func validate() throws { _ = try EditableAnnotationDocumentRecord(self) }

    func expectedOutputPixelSize() throws -> CGSize {
        try validate()
        return try validatedOutputPixelSize()
    }

    fileprivate func validatedOutputPixelSize() throws -> CGSize {
        let width = cropViewportInBase.map { Int($0.width) } ?? basePixelWidth
        let height = cropViewportInBase.map { Int($0.height) } ?? basePixelHeight
        let layout = try ImageOutputDecorationLayout.make(width: width, height: height, decoration: outputDecoration)
        return CGSize(width: layout.width, height: layout.height)
    }

    func validateAssetReferences(originalID: UUID, baseID: UUID, originalWidth: Int,
                                 originalHeight: Int, baseWidth: Int, baseHeight: Int) throws {
        guard originalAssetID == originalID, baseAssetID == baseID,
              originalPixelWidth == originalWidth, originalPixelHeight == originalHeight,
              basePixelWidth == baseWidth, basePixelHeight == baseHeight else {
            throw EditableAnnotationDocumentError.assetMismatch
        }
    }
}

struct EditableCapturePayload {
    var document: EditableAnnotationDocument
    var originalImage: CGImage
    var baseImage: CGImage

    func validate() throws {
        try document.validate()
        guard document.originalAssetID != document.baseAssetID || originalImage === baseImage else {
            throw EditableAnnotationDocumentError.assetMismatch
        }
        try document.validateAssetReferences(originalID: document.originalAssetID, baseID: document.baseAssetID,
            originalWidth: originalImage.width, originalHeight: originalImage.height,
            baseWidth: baseImage.width, baseHeight: baseImage.height)
    }
    func validate(currentImage: CGImage) throws {
        try validate()
        let size = try document.validatedOutputPixelSize()
        guard size.width == CGFloat(currentImage.width), size.height == CGFloat(currentImage.height) else {
            throw EditableAnnotationDocumentError.assetMismatch
        }
    }
}

enum EditableAnnotationDocumentError: LocalizedError, Equatable {
    case tooLarge, invalidJSON, unsupportedVersion, invalidDocument, unsupportedColor, assetMismatch
    var errorDescription: String? {
        switch self {
        case .tooLarge: return "可编辑标注超过安全大小上限，未更改已保存的图片。"
        case .invalidJSON: return "可编辑标注文件损坏，无法恢复图层。"
        case .unsupportedVersion: return "此版本尚不支持该可编辑标注格式。"
        case .invalidDocument: return "可编辑标注包含无效数据，无法恢复图层。"
        case .unsupportedColor: return "标注颜色空间尚不支持无损保存。"
        case .assetMismatch: return "可编辑标注与原图或底图不匹配。"
        }
    }
}

enum EditableAnnotationDocumentCodec {
    static let maximumFileBytes = 8 * 1_024 * 1_024
    static let maximumAnnotations = 2_048
    static let maximumTotalPoints = 131_072
    static let maximumTextUTF16 = 16_384
    static let maximumTotalTextUTF16 = 524_288
    static let maximumDimension = 32_768
    static let maximumPixels = 100_000_000

    static func encode(_ document: EditableAnnotationDocument) throws -> Data {
        let record = try EditableAnnotationDocumentRecord(document)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        // Also applies the structural budgets used for reading, so every accepted
        // write is readable under exactly the same limits.
        try EditableAnnotationJSONPreflight.validate(data)
        return data
    }

    static func decode(_ data: Data) throws -> EditableAnnotationDocument {
        try EditableAnnotationJSONPreflight.validate(data)
        do {
            let record = try JSONDecoder().decode(EditableAnnotationDocumentRecord.self, from: data)
            try record.validate()
            return try record.restore()
        } catch let error as EditableAnnotationDocumentError { throw error }
        catch { throw EditableAnnotationDocumentError.invalidDocument }
    }

    /// Never read an unbounded Data(contentsOf:) before checking the document cap.
    /// One extra byte catches growth between file metadata inspection and this read.
    static func read(from url: URL) throws -> EditableAnnotationDocument {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maximumFileBytes {
            let remaining = maximumFileBytes + 1 - data.count
            guard let part = try handle.read(upToCount: min(65_536, remaining)), !part.isEmpty else { break }
            data.append(part)
        }
        guard data.count <= maximumFileBytes else { throw EditableAnnotationDocumentError.tooLarge }
        return try decode(data)
    }
}

// These enums have a single stable raw-value representation. Unknown values fail
// decoding; unsupported styles are never replaced with defaults.
extension ImageEditorTool: Codable {}
extension AnnotationStrokeStyle: Codable {}
extension AnnotationLineCap: Codable {}
extension AnnotationLineJoin: Codable {}
extension AnnotationArrowhead: Codable {}
extension AnnotationEraserMode: Codable {}
extension AnnotationRegionShape: Codable {}
extension AnnotationWatermarkPlacement: Codable {}
extension AnnotationMagnifierConnector: Codable {}
extension AnnotationPencilConstraint: Codable {}
extension AnnotationHighlighterMode: Codable {}
extension AnnotationHighlighterBlend: Codable {}

private struct EditableAnnotationRecord: Codable {
    var id: UUID
    var tool: ImageEditorTool
    var points: [CGPoint]
    var color: EditableAnnotationColorRecord
    var lineWidth: CGFloat
    var text: String
    var number: Int
    var numberStyle: String
    var numberComment: String
    var numberCommentSize: CGSize
    var rotation: CGFloat
    var opacity: CGFloat
    var strokeStyle: AnnotationStrokeStyle
    var lineCap: AnnotationLineCap
    var lineJoin: AnnotationLineJoin
    var startArrowEnabled: Bool
    var endArrowEnabled: Bool?
    var startArrowhead: AnnotationArrowhead
    var endArrowhead: AnnotationArrowhead
    var fillEnabled: Bool
    var fillColor: EditableAnnotationColorRecord
    var cornerRadius: CGFloat
    var fontName: String
    var fontSize: CGFloat?
    var bold: Bool
    var italic: Bool
    var underline: Bool
    var textOutlineEnabled: Bool
    var textOutlineColor: EditableAnnotationColorRecord
    var textOutlineWidth: CGFloat
    var textBoxSize: CGSize?
    var eraserMode: AnnotationEraserMode
    var spotlightShape: AnnotationRegionShape
    var spotlightDim: CGFloat
    var spotlightBorder: Bool
    var watermarkPlacement: AnnotationWatermarkPlacement
    var watermarkSpacing: CGFloat
    var watermarkTemplate: String
    var frozenTimestamp: Date
    var frozenTimeZoneIdentifier: String
    var timestampIsCaptureDate: Bool
    var magnifierSource: CGRect?
    var magnifierScale: CGFloat
    var magnifierShape: AnnotationRegionShape
    var magnifierConnector: AnnotationMagnifierConnector
    var magnifierSmooth: Bool
    var magnifierShowsAnnotations: Bool
    var magnifierShadow: Bool
    var arcStartAngle: CGFloat
    var arcSweepAngle: CGFloat
    var freehandSmoothing: Bool
    var freehandConstraint: AnnotationPencilConstraint
    var freehandCorners: [Int]
    var freehandWasSimplified: Bool
    var highlighterMode: AnnotationHighlighterMode
    var highlighterBlend: AnnotationHighlighterBlend
    var mosaicLink: EditableMosaicLinkRecord?

    init(_ value: ImageAnnotation) throws {
        id = value.id
        tool = value.tool
        points = value.points
        color = try EditableAnnotationColorRecord(value.color)
        lineWidth = value.lineWidth
        text = value.text
        number = value.number
        numberStyle = value.numberStyle.rawValue
        numberComment = value.numberComment
        numberCommentSize = value.numberCommentSize
        rotation = value.rotation
        opacity = value.opacity
        strokeStyle = value.strokeStyle
        lineCap = value.lineCap
        lineJoin = value.lineJoin
        startArrowEnabled = value.startArrowEnabled
        endArrowEnabled = value.endArrowEnabled
        startArrowhead = value.startArrowhead
        endArrowhead = value.endArrowhead
        fillEnabled = value.fillEnabled
        fillColor = try EditableAnnotationColorRecord(value.fillColor)
        cornerRadius = value.cornerRadius
        fontName = value.fontName
        fontSize = value.fontSize
        bold = value.bold
        italic = value.italic
        underline = value.underline
        textOutlineEnabled = value.textOutlineEnabled
        textOutlineColor = try EditableAnnotationColorRecord(value.textOutlineColor)
        textOutlineWidth = value.textOutlineWidth
        textBoxSize = value.textBoxSize
        eraserMode = value.eraserMode
        spotlightShape = value.spotlightShape
        spotlightDim = value.spotlightDim
        spotlightBorder = value.spotlightBorder
        watermarkPlacement = value.watermarkPlacement
        watermarkSpacing = value.watermarkSpacing
        watermarkTemplate = value.watermarkTemplate
        frozenTimestamp = value.frozenTimestamp
        frozenTimeZoneIdentifier = value.frozenTimeZoneIdentifier
        timestampIsCaptureDate = value.timestampIsCaptureDate
        magnifierSource = value.magnifierSource
        magnifierScale = value.magnifierScale
        magnifierShape = value.magnifierShape
        magnifierConnector = value.magnifierConnector
        magnifierSmooth = value.magnifierSmooth
        magnifierShowsAnnotations = value.magnifierShowsAnnotations
        magnifierShadow = value.magnifierShadow
        arcStartAngle = value.arcStartAngle
        arcSweepAngle = value.arcSweepAngle
        freehandSmoothing = value.freehandSmoothing
        freehandConstraint = value.freehandConstraint
        freehandCorners = value.freehandCorners
        freehandWasSimplified = value.freehandWasSimplified
        highlighterMode = value.highlighterMode
        highlighterBlend = value.highlighterBlend
        mosaicLink = value.mosaicLink.map(EditableMosaicLinkRecord.init)
    }

    func restore() throws -> ImageAnnotation {
        guard let restoredNumberStyle = NumberedCalloutStyle(rawValue: numberStyle) else {
            throw EditableAnnotationDocumentError.invalidDocument
        }
        var value = ImageAnnotation(tool: tool, points: points)
        value.id = id
        value.color = try color.restore()
        value.lineWidth = lineWidth
        value.text = text
        value.number = number
        value.numberStyle = restoredNumberStyle
        value.numberComment = numberComment
        value.numberCommentSize = numberCommentSize
        value.rotation = rotation
        value.opacity = opacity
        value.strokeStyle = strokeStyle
        value.lineCap = lineCap
        value.lineJoin = lineJoin
        value.startArrowEnabled = startArrowEnabled
        value.endArrowEnabled = endArrowEnabled
        value.startArrowhead = startArrowhead
        value.endArrowhead = endArrowhead
        value.fillEnabled = fillEnabled
        value.fillColor = try fillColor.restore()
        value.cornerRadius = cornerRadius
        value.fontName = fontName
        value.fontSize = fontSize
        value.bold = bold
        value.italic = italic
        value.underline = underline
        value.textOutlineEnabled = textOutlineEnabled
        value.textOutlineColor = try textOutlineColor.restore()
        value.textOutlineWidth = textOutlineWidth
        value.textBoxSize = textBoxSize
        value.eraserMode = eraserMode
        value.spotlightShape = spotlightShape
        value.spotlightDim = spotlightDim
        value.spotlightBorder = spotlightBorder
        value.watermarkPlacement = watermarkPlacement
        value.watermarkSpacing = watermarkSpacing
        value.watermarkTemplate = watermarkTemplate
        value.frozenTimestamp = frozenTimestamp
        value.frozenTimeZoneIdentifier = frozenTimeZoneIdentifier
        value.timestampIsCaptureDate = timestampIsCaptureDate
        value.magnifierSource = magnifierSource
        value.magnifierScale = magnifierScale
        value.magnifierShape = magnifierShape
        value.magnifierConnector = magnifierConnector
        value.magnifierSmooth = magnifierSmooth
        value.magnifierShowsAnnotations = magnifierShowsAnnotations
        value.magnifierShadow = magnifierShadow
        value.arcStartAngle = arcStartAngle
        value.arcSweepAngle = arcSweepAngle
        value.freehandSmoothing = freehandSmoothing
        value.freehandConstraint = freehandConstraint
        value.freehandCorners = freehandCorners
        value.freehandWasSimplified = freehandWasSimplified
        value.highlighterMode = highlighterMode
        value.highlighterBlend = highlighterBlend
        value.mosaicLink = mosaicLink?.restore()
        return value
    }
}

private struct EditableMosaicLinkRecord: Codable {
    var groupID: UUID
    var additionID: UUID
    var rootAdditionID: UUID
    var target: CGRect
    var includedTargets: [CGRect]
    var excludedTargets: [CGRect]
    var synchronizes: Bool
    init(_ value: AutomaticMosaicLink) {
        groupID = value.groupID; additionID = value.additionID; rootAdditionID = value.rootAdditionID
        target = value.target; includedTargets = value.includedTargets; excludedTargets = value.excludedTargets
        synchronizes = value.synchronizes
    }
    func restore() -> AutomaticMosaicLink {
        AutomaticMosaicLink(groupID: groupID, additionID: additionID, rootAdditionID: rootAdditionID,
            target: target, includedTargets: includedTargets, excludedTargets: excludedTargets, synchronizes: synchronizes)
    }
    func validate() throws {
        try EditableAnnotationValidation.rect(target, positive: true)
        guard includedTargets.count + excludedTargets.count <= AutomaticMosaicReviewState.maximumCandidates else {
            throw EditableAnnotationDocumentError.tooLarge
        }
        let targets = includedTargets + excludedTargets
        for (index, rect) in targets.enumerated() {
            try EditableAnnotationValidation.rect(rect, positive: true)
            guard !targets.prefix(index).contains(rect) else { throw EditableAnnotationDocumentError.invalidDocument }
        }
    }
}

/// No ICC data, color archives, patterns, dynamic NSColor, or external resources.
/// A named color space is recreated only from this allowlist without conversion.
private struct EditableAnnotationColorRecord: Codable {
    var space: String
    var components: [CGFloat]
    private static let namedSpaces: [CFString] = [CGColorSpace.sRGB, CGColorSpace.linearSRGB,
        CGColorSpace.extendedSRGB, CGColorSpace.extendedLinearSRGB, CGColorSpace.displayP3,
        CGColorSpace.genericRGB, CGColorSpace.genericGray, CGColorSpace.genericGrayGamma2_2,
        CGColorSpace.linearGray, CGColorSpace.extendedGray, CGColorSpace.extendedLinearGray]

    init(_ color: CGColor) throws {
        guard let source = color.colorSpace, let values = color.components else {
            throw EditableAnnotationDocumentError.unsupportedColor
        }
        if let name = Self.namedSpaces.first(where: { name in
            guard let known = CGColorSpace(name: name) else { return false }
            return CFEqual(source, known)
        }) { space = name as String }
        else if CFEqual(source, CGColorSpaceCreateDeviceRGB()) { space = "device-rgb" }
        else if CFEqual(source, CGColorSpaceCreateDeviceGray()) { space = "device-gray" }
        else { throw EditableAnnotationDocumentError.unsupportedColor }
        components = values
        try validate()
    }
    private func colorSpace() throws -> CGColorSpace {
        if space == "device-rgb" { return CGColorSpaceCreateDeviceRGB() }
        if space == "device-gray" { return CGColorSpaceCreateDeviceGray() }
        guard let name = Self.namedSpaces.first(where: { ($0 as String) == space }),
              let result = CGColorSpace(name: name) else { throw EditableAnnotationDocumentError.unsupportedColor }
        return result
    }
    func validate() throws {
        let cs = try colorSpace()
        guard components.count == cs.numberOfComponents + 1,
              components.dropLast().allSatisfy({ $0.isFinite && (-16...16).contains($0) }),
              let alpha = components.last, alpha.isFinite, (0...1).contains(alpha) else {
            throw EditableAnnotationDocumentError.invalidDocument
        }
    }
    func restore() throws -> CGColor {
        try validate()
        guard let value = CGColor(colorSpace: try colorSpace(), components: components) else {
            throw EditableAnnotationDocumentError.unsupportedColor
        }
        return value
    }
}

private struct EditableSequenceRecord: Codable {
    var nextValue: Int
    var isExhausted: Bool
    var closesGapsOnDelete: Bool
    init(_ value: NumberedCalloutSequence) {
        nextValue = value.nextValue; isExhausted = value.isExhausted; closesGapsOnDelete = value.closesGapsOnDelete
    }
    func validate() throws {
        guard (1...NumberedCalloutSequence.maximumValue).contains(nextValue),
              !isExhausted || nextValue == NumberedCalloutSequence.maximumValue else {
            throw EditableAnnotationDocumentError.invalidDocument
        }
    }
    func restore() -> NumberedCalloutSequence {
        var value = NumberedCalloutSequence(); value.setNext(nextValue)
        if isExhausted { value.didInsert(NumberedCalloutSequence.maximumValue) }
        value.closesGapsOnDelete = closesGapsOnDelete
        return value
    }
}

private struct EditableDecorationRecord: Codable {
    struct Color: Codable {
        var red: Double; var green: Double; var blue: Double; var alpha: Double
    }
    var enabled: Bool
    var cornerRadius: Double
    var borderEnabled: Bool
    var borderWidth: Double
    var borderColor: Color
    var shadowEnabled: Bool
    var shadowBlur: Double
    var shadowOffsetX: Double
    var shadowOffsetY: Double
    var shadowOpacity: Double
    init(_ value: ImageOutputDecoration) {
        enabled = value.enabled; cornerRadius = value.cornerRadius; borderEnabled = value.borderEnabled
        borderWidth = value.borderWidth
        borderColor = Color(red: value.borderColor.red, green: value.borderColor.green,
                            blue: value.borderColor.blue, alpha: value.borderColor.alpha)
        shadowEnabled = value.shadowEnabled; shadowBlur = value.shadowBlur
        shadowOffsetX = value.shadowOffsetX; shadowOffsetY = value.shadowOffsetY; shadowOpacity = value.shadowOpacity
    }
    func restore() -> ImageOutputDecoration {
        ImageOutputDecoration(enabled: enabled, cornerRadius: cornerRadius, borderEnabled: borderEnabled,
            borderWidth: borderWidth, borderColor: .init(red: borderColor.red, green: borderColor.green,
            blue: borderColor.blue, alpha: borderColor.alpha), shadowEnabled: shadowEnabled, shadowBlur: shadowBlur,
            shadowOffsetX: shadowOffsetX, shadowOffsetY: shadowOffsetY, shadowOpacity: shadowOpacity)
    }
}

private struct EditableAnnotationDocumentRecord: Codable {
    var format: String
    var version: Int
    var coordinates: String
    var documentID: UUID
    var originalAssetID: UUID
    var originalPixelWidth: Int
    var originalPixelHeight: Int
    var baseAssetID: UUID
    var basePixelWidth: Int
    var basePixelHeight: Int
    var baseCropInOriginal: CGRect?
    var cropViewportInBase: CGRect?
    var baseProvenance: EditableAnnotationBaseProvenance
    var capturedAt: Date
    var captureTimeZoneIdentifier: String
    var captureTimestampKnown: Bool
    var annotations: [EditableAnnotationRecord]
    var numberSequence: EditableSequenceRecord
    var outputDecoration: EditableDecorationRecord

    init(_ value: EditableAnnotationDocument) throws {
        // Bound collection copies and color-space materialization on the encode path.
        guard value.annotations.count <= EditableAnnotationDocumentCodec.maximumAnnotations else {
            throw EditableAnnotationDocumentError.tooLarge
        }
        var totalPoints = 0, totalCorners = 0, totalText = 0
        for mark in value.annotations {
            guard mark.points.count <= ImageAnnotation.maximumGesturePoints,
                  mark.freehandCorners.count <= ImageAnnotation.maximumGesturePoints,
                  (mark.mosaicLink?.includedTargets.count ?? 0) <= AutomaticMosaicReviewState.maximumCandidates,
                  (mark.mosaicLink?.excludedTargets.count ?? 0) <= AutomaticMosaicReviewState.maximumCandidates else {
                throw EditableAnnotationDocumentError.tooLarge
            }
            totalPoints += mark.points.count; totalCorners += mark.freehandCorners.count
            try EditableAnnotationValidation.textBudget(mark.text, mark.numberComment, mark.watermarkTemplate,
                                                       total: &totalText)
        }
        guard totalPoints <= EditableAnnotationDocumentCodec.maximumTotalPoints,
              totalCorners <= EditableAnnotationDocumentCodec.maximumTotalPoints else {
            throw EditableAnnotationDocumentError.tooLarge
        }
        format = "picshot.editable-annotations"; version = 1; coordinates = "image-pixels-bottom-left"
        documentID = value.documentID; originalAssetID = value.originalAssetID; baseAssetID = value.baseAssetID
        originalPixelWidth = value.originalPixelWidth; originalPixelHeight = value.originalPixelHeight
        basePixelWidth = value.basePixelWidth; basePixelHeight = value.basePixelHeight
        baseCropInOriginal = value.baseCropInOriginal; cropViewportInBase = value.cropViewportInBase
        baseProvenance = value.baseProvenance
        capturedAt = value.capturedAt; captureTimeZoneIdentifier = value.captureTimeZoneIdentifier
        captureTimestampKnown = value.captureTimestampKnown
        annotations = try value.annotations.map(EditableAnnotationRecord.init)
        numberSequence = EditableSequenceRecord(value.numberSequence)
        outputDecoration = EditableDecorationRecord(value.outputDecoration)
        try validate()
    }

    func validate() throws {
        guard format == "picshot.editable-annotations", version == 1,
              coordinates == "image-pixels-bottom-left" else { throw EditableAnnotationDocumentError.unsupportedVersion }
        try EditableAnnotationValidation.dimensions(originalPixelWidth, originalPixelHeight)
        try EditableAnnotationValidation.dimensions(basePixelWidth, basePixelHeight)
        guard originalAssetID != baseAssetID || (originalPixelWidth == basePixelWidth && originalPixelHeight == basePixelHeight) else {
            throw EditableAnnotationDocumentError.assetMismatch
        }
        if let crop = baseCropInOriginal {
            try EditableAnnotationValidation.rect(crop, positive: true)
            guard crop.origin.x >= 0, crop.origin.y >= 0, crop.origin.x.rounded() == crop.origin.x,
                  crop.origin.y.rounded() == crop.origin.y, crop.width == CGFloat(basePixelWidth),
                  crop.height == CGFloat(basePixelHeight), crop.maxX <= CGFloat(originalPixelWidth),
                  crop.maxY <= CGFloat(originalPixelHeight),
                  originalAssetID != baseAssetID || crop.origin == .zero else {
                throw EditableAnnotationDocumentError.assetMismatch
            }
        }
        if let viewport = cropViewportInBase {
            try EditableAnnotationValidation.rect(viewport, positive: true)
            guard viewport.origin.x >= 0, viewport.origin.y >= 0,
                  [viewport.origin.x, viewport.origin.y, viewport.width, viewport.height].allSatisfy({ $0.rounded() == $0 }),
                  viewport.maxX <= CGFloat(basePixelWidth), viewport.maxY <= CGFloat(basePixelHeight) else {
                throw EditableAnnotationDocumentError.invalidDocument
            }
        }
        try EditableAnnotationValidation.date(capturedAt, zone: captureTimeZoneIdentifier)
        try numberSequence.validate()
        do { try outputDecoration.restore().validate() }
        catch { throw EditableAnnotationDocumentError.invalidDocument }
        guard annotations.count <= EditableAnnotationDocumentCodec.maximumAnnotations else {
            throw EditableAnnotationDocumentError.tooLarge
        }
        var ids = Set<UUID>(), totalPoints = 0, totalText = 0, numbers = 0, linked = 0
        var groups: [UUID: EditableMosaicLinkRecord] = [:]
        var additions: [UUID: UUID] = [:]
        for mark in annotations {
            guard ids.insert(mark.id).inserted else { throw EditableAnnotationDocumentError.invalidDocument }
            try mark.validate(baseWidth: basePixelWidth, baseHeight: basePixelHeight)
            totalPoints += mark.points.count
            try EditableAnnotationValidation.textBudget(mark.text, mark.numberComment, mark.watermarkTemplate, total: &totalText)
            if mark.tool == .number { numbers += 1 }
            if let link = mark.mosaicLink {
                linked += 1
                if let group = groups[link.groupID] {
                    guard group.rootAdditionID == link.rootAdditionID, group.synchronizes == link.synchronizes,
                          group.includedTargets == link.includedTargets, group.excludedTargets == link.excludedTargets else {
                        throw EditableAnnotationDocumentError.invalidDocument
                    }
                } else { groups[link.groupID] = link }
                for addition in [link.additionID, link.rootAdditionID] {
                    guard additions[addition] == nil || additions[addition] == link.groupID else {
                        throw EditableAnnotationDocumentError.invalidDocument
                    }
                    additions[addition] = link.groupID
                }
                // Root members may have been deliberately deleted. The remaining
                // group is still valid; rootAdditionID is historical value metadata.
            }
        }
        guard totalPoints <= EditableAnnotationDocumentCodec.maximumTotalPoints,
              numbers <= NumberedCalloutSequence.maximumMarks,
              linked <= AutomaticMosaicModelLimits.maximumLinkedAnnotations else {
            throw EditableAnnotationDocumentError.tooLarge
        }
    }

    func restore() throws -> EditableAnnotationDocument {
        EditableAnnotationDocument(documentID: documentID, originalAssetID: originalAssetID,
            originalPixelWidth: originalPixelWidth, originalPixelHeight: originalPixelHeight,
            baseAssetID: baseAssetID, basePixelWidth: basePixelWidth, basePixelHeight: basePixelHeight,
            baseCropInOriginal: baseCropInOriginal, cropViewportInBase: cropViewportInBase,
            baseProvenance: baseProvenance, capturedAt: capturedAt, captureTimeZoneIdentifier: captureTimeZoneIdentifier,
            captureTimestampKnown: captureTimestampKnown,
            annotations: try annotations.map { try $0.restore() }, numberSequence: numberSequence.restore(),
            outputDecoration: outputDecoration.restore())
    }
}

private enum EditableAnnotationValidation {
    static func dimensions(_ width: Int, _ height: Int) throws {
        guard width > 0, height > 0, width <= EditableAnnotationDocumentCodec.maximumDimension,
              height <= EditableAnnotationDocumentCodec.maximumDimension,
              width <= EditableAnnotationDocumentCodec.maximumPixels / height else {
            throw EditableAnnotationDocumentError.invalidDocument
        }
    }
    static func scalar(_ value: CGFloat, _ range: ClosedRange<CGFloat> = -1_000_000...1_000_000) throws {
        guard value.isFinite, range.contains(value) else { throw EditableAnnotationDocumentError.invalidDocument }
    }
    static func size(_ value: CGSize) throws {
        try scalar(value.width, 0...1_000_000); try scalar(value.height, 0...1_000_000)
    }
    static func rect(_ value: CGRect, positive: Bool = false) throws {
        try scalar(value.origin.x); try scalar(value.origin.y); try size(value.size)
        if positive && (value.width <= 0 || value.height <= 0) { throw EditableAnnotationDocumentError.invalidDocument }
        try scalar(value.maxX); try scalar(value.maxY)
    }
    static func string(_ value: String, maximum: Int) throws -> Int {
        // Prefix bounds the scan even for a huge in-memory string from a caller.
        let count = value.utf16.prefix(maximum + 1).count
        guard count <= maximum else { throw EditableAnnotationDocumentError.tooLarge }
        return count
    }
    static func textBudget(_ text: String, _ comment: String, _ watermark: String, total: inout Int) throws {
        total += try string(text, maximum: EditableAnnotationDocumentCodec.maximumTextUTF16)
        total += try string(comment, maximum: NumberedCalloutSequence.maximumCommentUTF16)
        total += try string(watermark, maximum: 2_048)
        guard total <= EditableAnnotationDocumentCodec.maximumTotalTextUTF16 else { throw EditableAnnotationDocumentError.tooLarge }
    }
    static func date(_ value: Date, zone: String) throws {
        let seconds = value.timeIntervalSinceReferenceDate
        _ = try string(zone, maximum: 128)
        guard seconds.isFinite, (-63_113_904_000...252_423_993_599).contains(seconds),
              TimeZone(identifier: zone) != nil else { throw EditableAnnotationDocumentError.invalidDocument }
    }
}

private extension EditableAnnotationRecord {
    func validate(baseWidth: Int, baseHeight: Int) throws {
        guard tool != .select, tool != .crop, !points.isEmpty,
              NumberedCalloutStyle(rawValue: numberStyle) != nil,
              (1...NumberedCalloutSequence.maximumValue).contains(number),
              points.count <= ImageAnnotation.maximumGesturePoints,
              freehandCorners.count <= ImageAnnotation.maximumGesturePoints,
              freehandCorners.allSatisfy({ points.indices.contains($0) }) else {
            throw EditableAnnotationDocumentError.invalidDocument
        }
        for point in points { try EditableAnnotationValidation.scalar(point.x); try EditableAnnotationValidation.scalar(point.y) }
        try color.validate(); try fillColor.validate(); try textOutlineColor.validate()
        for value in [lineWidth, cornerRadius, textOutlineWidth] { try EditableAnnotationValidation.scalar(value, 0...4_096) }
        for value in [opacity, spotlightDim] { try EditableAnnotationValidation.scalar(value, 0...1) }
        for value in [rotation, arcStartAngle, arcSweepAngle] { try EditableAnnotationValidation.scalar(value) }
        try EditableAnnotationValidation.scalar(watermarkSpacing, 0...1_000_000)
        try EditableAnnotationValidation.scalar(magnifierScale, 1...8)
        try EditableAnnotationValidation.size(numberCommentSize)
        if let fontSize { try EditableAnnotationValidation.scalar(fontSize, 0...4_096) }
        if let textBoxSize { try EditableAnnotationValidation.size(textBoxSize) }
        if let magnifierSource { try EditableAnnotationValidation.rect(magnifierSource) }
        if tool == .magnifier { try validateMagnifierSampling(baseWidth: baseWidth, baseHeight: baseHeight) }
        _ = try EditableAnnotationValidation.string(fontName, maximum: 256)
        try EditableAnnotationValidation.date(frozenTimestamp, zone: frozenTimeZoneIdentifier)
        if let mosaicLink {
            guard [.pixelate, .blur, .redact].contains(tool) else { throw EditableAnnotationDocumentError.invalidDocument }
            try mosaicLink.validate()
        }
    }
}

private extension EditableAnnotationRecord {
    func validateMagnifierSampling(baseWidth: Int, baseHeight: Int) throws {
        // Match localBounds for the magnifier without constructing a runtime mark.
        guard let first = points.first else { throw EditableAnnotationDocumentError.invalidDocument }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let lens = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let source = magnifierSource ?? lens
        // New source gestures require >1 pixel on both axes; source handle edits
        // clamp to 2 pixels. resizedMagnifierLens uses max(2, sourceSize)*scale,
        // where scale is 1...8. Preserve fractional origins/sizes without rounding.
        // Point translation can lose a few ulps while subtracting the lens
        // endpoints. This tolerance covers that at the bounded ±1e6 coordinates;
        // it does not round or rewrite any stored geometry.
        let minimumLensDimension: CGFloat = 2 - 1e-9
        guard source.width > 1, source.height > 1,
              lens.width >= minimumLensDimension, lens.height >= minimumLensDimension,
              source.maxX > source.minX, source.maxY > source.minY else {
            throw EditableAnnotationDocumentError.invalidDocument
        }
        // Verify the actual affine sampling used by AnnotationMagnifierRenderer.
        // Finite inputs alone are insufficient: divisions or origin*scale can
        // overflow. Check both axes, translation, inverse and full drawn extent.
        let sx = lens.width / source.width, sy = lens.height / source.height
        let tx = lens.minX - source.minX * sx, ty = lens.minY - source.minY * sy
        let determinant = sx * sy
        guard [sx, sy, tx, ty, determinant].allSatisfy(\.isFinite),
              sx > 0, sy > 0, determinant > 0 else { throw EditableAnnotationDocumentError.invalidDocument }
        let sampling = CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: tx, ty: ty)
        let inverse = sampling.inverted()
        guard [inverse.a, inverse.b, inverse.c, inverse.d, inverse.tx, inverse.ty].allSatisfy(\.isFinite) else {
            throw EditableAnnotationDocumentError.invalidDocument
        }
        let sampledExtent = CGRect(x: 0, y: 0, width: baseWidth, height: baseHeight).applying(sampling)
        guard [sampledExtent.minX, sampledExtent.minY, sampledExtent.maxX, sampledExtent.maxY,
               sampledExtent.width, sampledExtent.height].allSatisfy(\.isFinite),
              sampledExtent.width > 0, sampledExtent.height > 0,
              sampledExtent.maxX > sampledExtent.minX, sampledExtent.maxY > sampledExtent.minY else {
            throw EditableAnnotationDocumentError.invalidDocument
        }
    }
}
