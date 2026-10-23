import COrt
import Foundation

public struct OnnxError: Error, CustomStringConvertible { public var description: String }

/// Single-input, single-output float ONNX model (all models Mycroft uses fit this).
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
    /// The wake word: openWakeWord's pre-trained "hey_mycroft" model (v0.5.1 release).
    public static let wakeWordFile = "hey_mycroft_v0.1.onnx"
    public static let wakePhrase = "Hey Mycroft"
    public static var wakeWordAvailable: Bool {
        ["melspectrogram.onnx", "embedding_model.onnx", wakeWordFile].allSatisfy { FileManager.default.fileExists(atPath: path($0)) }
    }
}
