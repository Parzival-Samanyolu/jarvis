import COrt
import Foundation

public struct OnnxError: Error, CustomStringConvertible { public var description: String }

/// Single-input, single-output float ONNX model (all models Jarvis uses fit this).
public final class OnnxModel {
    let handle: OpaquePointer

    public init(path: String) throws {
        var err = [CChar](repeating: 0, count: 512)
        guard let h = ortshim_load(path, &err, 512) else { throw OnnxError(description: "load \(path): " + String(cString: err)) }
        handle = h
    }
    deinit { ortshim_free(handle) }

    public func run(_ input: [Float], shape: [Int64], maxOutput: Int = 1 << 16) throws -> (data: [Float], shape: [Int64]) {
        var out = [Float](repeating: 0, count: maxOutput)
        var outLen: Int64 = 0
        var outShape = [Int64](repeating: 0, count: 8)
        var outRank: Int32 = 0
        var err = [CChar](repeating: 0, count: 512)
        let rc = ortshim_run(handle, input, shape, Int32(shape.count), &out, Int64(maxOutput), &outLen, &outShape, &outRank, &err, 512)
        guard rc == 0 else { throw OnnxError(description: String(cString: err)) }
        return (Array(out[0..<Int(outLen)]), Array(outShape[0..<Int(outRank)]))
    }
}

public enum Models {
    public static func path(_ name: String) -> String { Paths.models.appendingPathComponent(name).path }
    public static var wakeWordAvailable: Bool {
        ["melspectrogram.onnx", "embedding_model.onnx", "hey_jarvis_v0.1.onnx"].allSatisfy { FileManager.default.fileExists(atPath: path($0)) }
    }
    public static var speakerAvailable: Bool { FileManager.default.fileExists(atPath: path("voxceleb_resnet34_LM.onnx")) }
}
