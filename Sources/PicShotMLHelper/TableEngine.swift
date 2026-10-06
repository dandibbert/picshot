import Foundation
import CoreGraphics
import OnnxRuntimeBindings
import PicShotFormulaCore
import PicShotTableEngine

enum TableEngine {
    static func recognize(image: CGImage, modelDirectory: URL) throws -> TableRecognitionResult {
        try ModelAssetVerifier.verify(.table, in: modelDirectory)
        let input = try SLANetPlus.preprocess(image: image)
        let environment = try ORTEnv(loggingLevel: .error)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(2)
        try options.setGraphOptimizationLevel(.all)
        let session = try ORTSession(env: environment, modelPath: modelDirectory.appendingPathComponent("slanet-plus.onnx").path, sessionOptions: options)
        guard Set(try session.inputNames()) == [SLANetPlus.inputName] else { throw FormulaError.invalidTensor }
        let value = try FormulaEngine.tensor(input.values, shape: input.shape.map { NSNumber(value: $0) })
        let outputs = try session.run(withInputs: [SLANetPlus.inputName: value],
            outputNames: [SLANetPlus.boxOutputName, SLANetPlus.probabilityOutputName], runOptions: nil)
        let boxes = try floats(outputs[SLANetPlus.boxOutputName], maximumCount: 1024 * 8)
        let probabilities = try floats(outputs[SLANetPlus.probabilityOutputName], maximumCount: 1024 * 50)
        let ocr = try VisionTableOCR.recognize(image: image)
        return try SLANetPlus.decode(boundingBoxes: boxes.values, boxShape: boxes.shape,
            structureProbabilities: probabilities.values, probabilityShape: probabilities.shape,
            imageWidth: image.width, imageHeight: image.height, ocr: ocr)
    }

    private static func floats(_ value: ORTValue?, maximumCount: Int) throws -> (values: [Float], shape: [Int64]) {
        guard let value else { throw FormulaError.invalidTensor }
        let info = try value.tensorTypeAndShapeInfo()
        let shape = info.shape.map(\.int64Value)
        guard info.elementType == .float, shape.count == 3, shape.allSatisfy({ $0 > 0 && $0 <= 1024 }) else { throw FormulaError.invalidTensor }
        let count = shape.reduce(Int64(1), *)
        guard count <= Int64(maximumCount) else { throw FormulaError.invalidTensor }
        let data = try value.tensorData()
        guard data.length == Int(count) * MemoryLayout<Float>.size else { throw FormulaError.invalidTensor }
        let buffer = UnsafeBufferPointer(start: data.bytes.assumingMemoryBound(to: Float.self), count: Int(count))
        return (Array(buffer), shape)
    }
}
