import Foundation
#if canImport(CoreML)
import CoreML
#endif
#if canImport(Vision)
import Vision
#endif
#if os(macOS)
import AppKit
#endif

/// A helper that loads a Core ML model and attempts to produce a short description for an image.
/// It prefers Vision classification outputs, then falls back to model string outputs or top class label.
final class CoreMLDescriber {
    #if canImport(CoreML)
    private let model: MLModel
    #else
    init(compiledModelURL: URL) throws {
        throw NSError(domain: "CoreMLDescriber", code: -1, userInfo: [NSLocalizedDescriptionKey: "CoreML is not available on this platform."])
    }
    #endif

    #if canImport(Vision)
    private let vnModel: VNCoreMLModel?
    #endif

    #if canImport(CoreML)
    init(compiledModelURL: URL) throws {
        self.model = try MLModel(contentsOf: compiledModelURL)
        #if canImport(Vision)
        self.vnModel = try? VNCoreMLModel(for: self.model)
        #else
        self.vnModel = nil
        #endif
    }
    #endif

    /// Describe an image at the given URL using the loaded model.
    func describe(imageURL: URL) throws -> String {
        #if canImport(CoreML)
        #if os(macOS)
        guard let img = NSImage(contentsOf: imageURL), let cg = img.cgImage() else {
            throw NSError(domain: "CoreMLDescriber", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to load image at \(imageURL.lastPathComponent)"])
        }
        #else
        throw NSError(domain: "CoreMLDescriber", code: -10, userInfo: [NSLocalizedDescriptionKey: "Only macOS is supported in this sample."])
        #endif

        // 1) Try Vision classification path
        #if canImport(Vision)
        if let vnModel {
            if let label = try classifyWithVision(cgImage: cg, vnModel: vnModel) {
                return label
            }
        }
        #endif

        // 2) Fall back to direct Core ML prediction
        return try predictDirectly(cgImage: cg)
        #else
        throw NSError(domain: "CoreMLDescriber", code: -1, userInfo: [NSLocalizedDescriptionKey: "CoreML is not available on this platform."])
        #endif
    }
}

#if canImport(Vision)
private extension CoreMLDescriber {
    func classifyWithVision(cgImage: CGImage, vnModel: VNCoreMLModel) throws -> String? {
        let request = VNCoreMLRequest(model: vnModel)
        request.imageCropAndScaleOption = .centerCrop
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        guard let results = request.results as? [VNClassificationObservation], let top = results.first else {
            return nil
        }
        return top.identifier
    }
}
#endif

#if canImport(CoreML)
private extension CoreMLDescriber {
    func predictDirectly(cgImage: CGImage) throws -> String {
        let desc = model.modelDescription
        // Find an image input key
        guard let imageInput = desc.inputDescriptionsByName.first(where: { $0.value.type == .image }) else {
            throw NSError(domain: "CoreMLDescriber", code: -3, userInfo: [NSLocalizedDescriptionKey: "Model does not accept image input."])
        }
        let inputKey = imageInput.key
        let constraint = imageInput.value.imageConstraint
        let targetSize = CGSize(width: constraint?.pixelsWide ?? cgImage.width, height: constraint?.pixelsHigh ?? cgImage.height)
        guard let px = Self.pixelBuffer(from: cgImage, size: targetSize, pixelFormat: constraint?.pixelFormatType ?? kCVPixelFormatType_32BGRA) else {
            throw NSError(domain: "CoreMLDescriber", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to create pixel buffer for model input."])
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [inputKey: MLFeatureValue(pixelBuffer: px)])
        let output = try model.prediction(from: provider)

        // Prefer a string output if present
        if let stringOut = output.featureNames.first(where: { output.featureValue(for: $0)?.type == .string }), let val = output.featureValue(for: stringOut)?.stringValue, !val.isEmpty {
            return val
        }
        // Common classification pattern: classLabel string
        if let classLabel = output.featureValue(for: "classLabel")?.stringValue, !classLabel.isEmpty {
            return classLabel
        }
        // Or probabilities dictionary with top label
        if let probs = output.featureValue(for: "classLabelProbs")?.dictionaryValue as? [String: NSNumber], let best = probs.max(by: { $0.value.doubleValue < $1.value.doubleValue })?.key {
            return best
        }
        // Fallback: any string-typed output
        for name in output.featureNames {
            if let fv = output.featureValue(for: name), fv.type == .string, !fv.stringValue.isEmpty {
                return fv.stringValue
            }
        }
        // As a last resort, return a generic placeholder
        return "image"
    }

    static func pixelBuffer(from cgImage: CGImage, size: CGSize, pixelFormat: OSType) -> CVPixelBuffer? {
        var px: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let width = Int(size.width)
        let height = Int(size.height)
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, attrs as CFDictionary, &px) == kCVReturnSuccess, let buffer = px else {
            return nil
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(origin: .zero, size: size))
        return buffer
    }
}
#endif

#if os(macOS)
private extension NSImage {
    func cgImage() -> CGImage? {
        var rect = CGRect(origin: .zero, size: self.size)
        return self.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
#endif
