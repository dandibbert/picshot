import Foundation
import CoreGraphics
import OnnxRuntimeBindings
import PicShotFormulaCore

/// The runtime and weights exist only in this short-lived executable, never in
/// the menu-bar application's address space. There are no network calls here.
enum FormulaEngine {
    static func recognize(image: CGImage, modelDirectory: URL) throws -> FormulaRecognitionResult {
        let start = Date()
        try ModelAssetVerifier.verify(.formula, in: modelDirectory)
        let tokenizer = try FormulaTokenizer(data: Data(contentsOf: modelDirectory.appendingPathComponent("tokenizer.json")))
        let environment = try ORTEnv(loggingLevel: .error)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(2)
        try options.setGraphOptimizationLevel(.all)
        let encoder = try ORTSession(env: environment, modelPath: modelDirectory.appendingPathComponent("encoder_model.onnx").path, sessionOptions: options)
        let decoder = try ORTSession(env: environment, modelPath: modelDirectory.appendingPathComponent("decoder_model.onnx").path, sessionOptions: options)
        guard Set(try encoder.inputNames()) == ["pixel_values"],
              Set(try decoder.inputNames()) == ["input_ids", "encoder_hidden_states"] else { throw FormulaError.invalidTensor }
        let pixels = try FormulaImagePreprocessor.tensor(image)
        let pixelValue = try tensor(pixels, shape: [1, 3, 384, 384])
        let encoded = try encoder.run(withInputs: ["pixel_values": pixelValue], outputNames: ["last_hidden_state"], runOptions: nil)
        guard let hidden = encoded["last_hidden_state"] else { throw FormulaError.invalidTensor }
        let info = try hidden.tensorTypeAndShapeInfo()
        guard info.elementType == .float, info.shape.map(\.intValue) == [1, 578, 384] else { throw FormulaError.invalidTensor }
        var ids: [Int64] = [1]
        for _ in 0..<MLJobLimits.formulaTokens {
            guard Date().timeIntervalSince(start) < MLJobLimits.seconds else { throw FormulaError.timeLimit }
            let next: Int64 = try autoreleasepool {
                let input = try ids.withUnsafeBytes {
                    try ORTValue(tensorData: NSMutableData(bytes: $0.baseAddress!, length: $0.count), elementType: .int64, shape: [1, NSNumber(value: ids.count)])
                }
                let results = try decoder.run(withInputs: ["input_ids": input, "encoder_hidden_states": hidden], outputNames: ["logits"], runOptions: nil)
                guard let logits = results["logits"] else { throw FormulaError.invalidTensor }
                let shape = try logits.tensorTypeAndShapeInfo()
                guard shape.elementType == .float, shape.shape.map(\.intValue) == [1, ids.count, 1868] else { throw FormulaError.invalidTensor }
                let raw = try logits.tensorData()
                guard raw.length == ids.count * 1868 * MemoryLayout<Float>.size else { throw FormulaError.invalidTensor }
                let values = raw.bytes.assumingMemoryBound(to: Float.self).advanced(by: (ids.count - 1) * 1868)
                var best = 0
                for index in 0..<1868 {
                    guard values[index].isFinite else { throw FormulaError.invalidTensor }
                    if values[index] > values[best] { best = index }
                }
                return Int64(best)
            }
            if next == 2 {
                let latex = try tokenizer.decode(ids)
                guard !latex.isEmpty else { throw FormulaError.emptyResult }
                return FormulaRecognitionResult(latex: latex, tokenCount: ids.count - 1, modelID: ModelPackManifest.formula.id,
                    warnings: ["机器识别可能出错；请核对 LaTeX，尤其是手写、复杂矩阵和多行公式。"])
            }
            ids.append(next)
        }
        // Never silently present truncated LaTeX as a successful recognition.
        throw FormulaError.tokenLimit
    }

    static func tensor(_ values: [Float], shape: [NSNumber]) throws -> ORTValue {
        try values.withUnsafeBytes {
            try ORTValue(tensorData: NSMutableData(bytes: $0.baseAddress!, length: $0.count), elementType: .float, shape: shape)
        }
    }
}
