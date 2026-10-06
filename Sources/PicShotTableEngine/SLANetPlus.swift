// Portions adapted from RapidAI/RapidTable, revision 22592283c1f9d7c5a014c96c4ecc57de0b3ebfce.
// Copyright 2025 RapidAI; Copyright (c) 2020 PaddlePaddle Authors. All Rights Reserved.
// Original pre/postprocessing author: SWHL <liekkaskono@163.com>.
// Licensed under Apache-2.0. See docs/TABLE_MODEL.md for attribution and license.
// Modified for PicShot: Swift implementation, strict tensor/grammar validation and OCR uncertainty reporting.
import Foundation
import PicShotCore

public enum SLANetPlus {
    public static let inputName = "x"
    public static let boxOutputName = "save_infer_model/scale_0.tmp_0"
    public static let probabilityOutputName = "save_infer_model/scale_1.tmp_0"
    public static let modelSHA256 = "d57a942af6a2f57d6a4a0372573c696a2379bf5857c45e2ac69993f3b334514b"
    public static let modelByteCount = 7_758_305
    public static let imageSide = 488
    public static let maximumImagePixels = 40_000_000
    public static let minimumStructureConfidence = 0.60
    /// Exact `character` metadata of the pinned ONNX, with the decoder's SOS/EOS added.
    public static let vocabulary: [String] = ["sos", "<thead>", "</thead>", "<tbody>", "</tbody>", "<tr>", "</tr>", "<td", ">", "</td>"]
        + (2...20).map { " colspan=\"\($0)\"" }
        + (2...20).map { " rowspan=\"\($0)\"" }
        + ["<td></td>", "eos"]

    /// BGR, not RGB. Normalize the resized pixels before top-left zero padding, as upstream does.
    /// Bilinear half-pixel sampling matches cv2.resize's geometry; byte rounding may differ by one.
    public static func preprocess(width: Int, height: Int, bgrBytes: [UInt8]) throws -> SLANetInput {
        guard width > 0, height > 0, width <= maximumImagePixels / height,
              bgrBytes.count == width * height * 3 else { throw TableRecognitionError.invalidImage }
        let ratio = Double(imageSide) / Double(max(width, height))
        let resizedWidth = Int(Double(width) * ratio), resizedHeight = Int(Double(height) * ratio)
        guard resizedWidth > 0, resizedHeight > 0 else { throw TableRecognitionError.invalidImage }
        let mean: [Float] = [0.485, 0.456, 0.406], std: [Float] = [0.229, 0.224, 0.225]
        let plane = imageSide * imageSide
        var values = [Float](repeating: 0, count: 3 * plane)
        for y in 0..<resizedHeight {
            let sourceY = max(0, min(Double(height - 1), (Double(y) + 0.5) * Double(height) / Double(resizedHeight) - 0.5))
            let y0 = Int(sourceY), y1 = min(y0 + 1, height - 1), fy = sourceY - Double(y0)
            for x in 0..<resizedWidth {
                let sourceX = max(0, min(Double(width - 1), (Double(x) + 0.5) * Double(width) / Double(resizedWidth) - 0.5))
                let x0 = Int(sourceX), x1 = min(x0 + 1, width - 1), fx = sourceX - Double(x0)
                for channel in 0..<3 {
                    let p00 = Double(bgrBytes[(y0 * width + x0) * 3 + channel])
                    let p01 = Double(bgrBytes[(y0 * width + x1) * 3 + channel])
                    let p10 = Double(bgrBytes[(y1 * width + x0) * 3 + channel])
                    let p11 = Double(bgrBytes[(y1 * width + x1) * 3 + channel])
                    let sample = ((p00 * (1 - fx) + p01 * fx) * (1 - fy) + (p10 * (1 - fx) + p11 * fx) * fy).rounded()
                    values[channel * plane + y * imageSide + x] = (Float(sample) / 255 - mean[channel]) / std[channel]
                }
            }
        }
        return SLANetInput(values: values, shape: [1, 3, Int64(imageSide), Int64(imageSide)],
                           originalWidth: width, originalHeight: height, resizedWidth: resizedWidth, resizedHeight: resizedHeight)
    }

    /// Consumes the actual ONNX outputs; no TSV, row-clustering, or inferred spans are accepted here.
    public static func decode(boundingBoxes: [Float], boxShape: [Int64],
                              structureProbabilities: [Float], probabilityShape: [Int64],
                              imageWidth: Int, imageHeight: Int, ocr: [TableOCRObservation]) throws -> TableRecognitionResult {
        guard imageWidth > 0, imageHeight > 0, imageWidth <= maximumImagePixels / imageHeight else { throw TableRecognitionError.invalidImage }
        guard probabilityShape.count == 3, probabilityShape[0] == 1, probabilityShape[2] == Int64(vocabulary.count),
              probabilityShape[1] > 0, probabilityShape[1] <= 1024 else {
            throw TableRecognitionError.invalidTensor("expected probabilities [1, S, 50], S ≤ 1024")
        }
        let steps = Int(probabilityShape[1]), classes = vocabulary.count
        guard boxShape == [1, Int64(steps), 8], boundingBoxes.count == steps * 8,
              structureProbabilities.count == steps * classes else {
            throw TableRecognitionError.invalidTensor("mismatched box/probability shape or length")
        }
        guard boundingBoxes.allSatisfy(\.isFinite), structureProbabilities.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1.00001 }) else {
            throw TableRecognitionError.invalidTensor("non-finite values or invalid probabilities")
        }
        var tokens: [String] = [], scores: [Double] = [], boxes: [TableOCRBox] = [], cellScores: [Double] = []
        var reachedEnd = false
        var openSpanCell: Int?
        for step in 0..<steps {
            let offset = step * classes
            var best = 0, sum: Float = 0
            for index in 0..<classes {
                sum += structureProbabilities[offset + index]
                if structureProbabilities[offset + index] > structureProbabilities[offset + best] { best = index }
            }
            guard abs(sum - 1) < 0.02 else { throw TableRecognitionError.invalidTensor("expected normalized softmax probabilities") }
            let token = vocabulary[best]
            if token == "eos" { reachedEnd = true; break }
            if token == "sos" {
                guard step == 0 else { throw TableRecognitionError.unsupportedStructure("unexpected start token") }
                continue
            }
            let confidence = Double(structureProbabilities[offset + best])
            tokens.append(token); scores.append(confidence)
            if token == "<td" || token == "<td></td>" {
                let points = Array(boundingBoxes[(step * 8)..<(step * 8 + 8)])
                boxes.append(try cellBox(points, width: imageWidth, height: imageHeight))
                cellScores.append(confidence)
                openSpanCell = token == "<td" ? cellScores.count - 1 : nil
            } else if let index = openSpanCell {
                cellScores[index] = min(cellScores[index], confidence)
                if token == "</td>" { openSpanCell = nil }
            }
        }
        guard reachedEnd else { throw TableRecognitionError.incompleteSequence }
        guard !scores.isEmpty else { throw TableRecognitionError.unsupportedStructure("empty structure") }
        let confidence = scores.reduce(0, +) / Double(scores.count)
        guard confidence >= minimumStructureConfidence else { throw TableRecognitionError.lowConfidence(confidence) }
        guard ocr.count <= 20_000, ocr.allSatisfy({
            $0.confidence.isFinite && $0.box.x.isFinite && $0.box.y.isFinite && $0.box.width.isFinite && $0.box.height.isFinite
        }) else { throw TableRecognitionError.invalidTensor("invalid or excessive OCR observations") }
        let parsed = try parse(tokens)
        guard parsed.cells.count == boxes.count else { throw TableRecognitionError.invalidTensor("cell/box alignment mismatch") }
        return try match(parsed: parsed, boxes: boxes, cellScores: cellScores, confidence: confidence, ocr: ocr)
    }

    private static func cellBox(_ points: [Float], width: Int, height: Int) throws -> TableOCRBox {
        // Upstream first scales x by width/y by height, then corrects SLANet-plus padding.
        // Both axes simplify to the original image's longest edge, including nonsquare images.
        let scale = Double(max(width, height))
        let xs = stride(from: 0, to: 8, by: 2).map { Double(points[$0]) * scale }
        let ys = stride(from: 1, to: 8, by: 2).map { Double(points[$0]) * scale }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
              maxX > minX, maxY > minY,
              minX >= -0.05 * Double(width), minY >= -0.05 * Double(height),
              maxX <= 1.05 * Double(width), maxY <= 1.05 * Double(height) else {
            throw TableRecognitionError.invalidCellGeometry
        }
        let x = max(0, minX), y = max(0, minY)
        let box = TableOCRBox(x: x, y: y, width: min(Double(width), maxX) - x, height: min(Double(height), maxY) - y)
        guard box.isValid else { throw TableRecognitionError.invalidCellGeometry }
        return box
    }
}
