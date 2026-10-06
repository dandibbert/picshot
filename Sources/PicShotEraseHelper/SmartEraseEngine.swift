import Foundation
import CoreML
import CoreGraphics
import CoreVideo
import PicShotEraseCore

/// One synchronous prediction. The caller is an expendable helper process;
/// Core ML, the compiled model and GPU allocations die with it after the job.
enum SmartEraseEngine {
    static func erase(image: CGImage, mask: Data, modelDirectory: URL, jobDirectory: URL) throws -> CGImage {
        let original = try SmartEraseRaster(image: image)
        let crop = try SmartEraseMask.crop(width: original.width, height: original.height, mask: mask)
        let modelMask = try SmartEraseMask.modelMask(width: original.width, height: original.height, mask: mask, crop: crop)
        let package = try SmartEraseModelPack.materialize(in: jobDirectory, from: modelDirectory)
        let compiled = try MLModel.compileModel(at: package)
        defer { try? FileManager.default.removeItem(at: compiled) }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        let model = try MLModel(contentsOf: compiled, configuration: configuration)
        try validate(model.modelDescription)
        let inputs = try buffers(original: original, mask: modelMask, crop: crop)
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(pixelBuffer: inputs.image),
            "mask": MLFeatureValue(pixelBuffer: inputs.mask)
        ])
        let result = try model.prediction(from: provider)
        guard let output = result.featureValue(for: "output")?.imageBufferValue else { throw SmartEraseError.invalidOutput }
        let predicted = try raster(output)
        return try original.compositing(prediction: predicted, mask: mask, crop: crop).image()
    }

    static func validate(_ description: MLModelDescription) throws {
        guard Set(description.inputDescriptionsByName.keys) == Set(["image", "mask"]),
              Set(description.outputDescriptionsByName.keys) == Set(["output"]) else { throw SmartEraseError.invalidModel }
        for (name, pixelFormat) in [("image", kCVPixelFormatType_32BGRA), ("mask", kCVPixelFormatType_OneComponent8)] {
            guard let constraint = description.inputDescriptionsByName[name]?.imageConstraint,
                  constraint.pixelsWide == 800, constraint.pixelsHigh == 800,
                  constraint.pixelFormatType == pixelFormat else { throw SmartEraseError.invalidModel }
        }
        guard let output = description.outputDescriptionsByName["output"]?.imageConstraint,
              output.pixelsWide == 800, output.pixelsHigh == 800,
              output.pixelFormatType == kCVPixelFormatType_32BGRA else { throw SmartEraseError.invalidModel }
    }

    private static func makeBuffer(format: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, 800, 800, format, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { throw SmartEraseError.invalidInput }
        return buffer
    }

    static func buffers(original: SmartEraseRaster, mask: [UInt8], crop: SmartEraseCrop) throws -> (image: CVPixelBuffer, mask: CVPixelBuffer) {
        guard mask.count == 800 * 800 else { throw SmartEraseError.invalidInput }
        let image = try makeBuffer(format: kCVPixelFormatType_32BGRA)
        let maskImage = try makeBuffer(format: kCVPixelFormatType_OneComponent8)
        guard CVPixelBufferLockBaseAddress(image, []) == kCVReturnSuccess else { throw SmartEraseError.invalidInput }
        defer { CVPixelBufferUnlockBaseAddress(image, []) }
        guard CVPixelBufferLockBaseAddress(maskImage, []) == kCVReturnSuccess else { throw SmartEraseError.invalidInput }
        defer { CVPixelBufferUnlockBaseAddress(maskImage, []) }
        guard let base = CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to: UInt8.self),
              let maskBase = CVPixelBufferGetBaseAddress(maskImage)?.assumingMemoryBound(to: UInt8.self) else { throw SmartEraseError.invalidInput }
        let stride = CVPixelBufferGetBytesPerRow(image), maskStride = CVPixelBufferGetBytesPerRow(maskImage)
        let scale = Double(crop.side) / 800
        for y in 0..<800 {
            for x in 0..<800 {
                let sx = Double(crop.x) + (Double(x) + 0.5) * scale - 0.5
                let sy = Double(crop.y) + (Double(y) + 0.5) * scale - 0.5
                let alpha = original.sample(x: sx, y: sy, channel: 3) / 255
                // Composite transparency onto white for the model only. Original
                // alpha and all unmasked premultiplied RGBA bytes remain intact.
                for channel in 0..<3 {
                    let value = original.sample(x: sx, y: sy, channel: channel) + (1 - alpha) * 255
                    base[y * stride + x * 4 + (2 - channel)] = UInt8(max(0, min(255, value.rounded())))
                }
                base[y * stride + x * 4 + 3] = 255
                maskBase[y * maskStride + x] = mask[y * 800 + x]
            }
        }
        return (image, maskImage)
    }

    private static func raster(_ buffer: CVPixelBuffer) throws -> SmartEraseRaster {
        guard CVPixelBufferGetWidth(buffer) == 800, CVPixelBufferGetHeight(buffer) == 800,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw SmartEraseError.invalidOutput }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { throw SmartEraseError.invalidOutput }
        var rgba = [UInt8](repeating: 255, count: 800 * 800 * 4)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<800 { for x in 0..<800 {
            let source = y * stride + x * 4, destination = (y * 800 + x) * 4
            rgba[destination] = base[source + 2]; rgba[destination + 1] = base[source + 1]; rgba[destination + 2] = base[source]
        } }
        return try SmartEraseRaster(width: 800, height: 800, rgba: rgba)
    }
}
