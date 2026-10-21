import Foundation

/// An openWakeWord model (`Models.wakeWordFile`), ported to Swift on top of onnxruntime.
/// Pipeline per 80 ms chunk: raw audio -> mel spectrogram -> speech embedding -> wake-word score.
public final class WakeWordDetector {
    public static let chunk = 1280                // 80 ms at 16 kHz
    public var threshold: Float = 0.5
    public var cooldown: TimeInterval = 2.0

    let mel: OnnxModel, embed: OnnxModel, wake: OnnxModel
    var raw: [Float] = []                          // int16-scaled samples
    var melFrames: [[Float]] = Array(repeating: Array(repeating: 1, count: 32), count: 76)
    var embeddings: [[Float]] = []
    var pending: [Float] = []
    var lastFire = Date.distantPast
    public private(set) var lastScore: Float = 0

    public init() throws {
        mel = try OnnxModel(path: Models.path("melspectrogram.onnx"))
        embed = try OnnxModel(path: Models.path("embedding_model.onnx"))
        wake = try OnnxModel(path: Models.path(Models.wakeWordFile))
    }

    /// Feed 16 kHz mono samples in -1...1. Returns true when the wake word was just heard.
    public func feed(_ samples: [Float], now: Date = Date()) -> Bool {
        pending.append(contentsOf: samples)
        var fired = false
        while pending.count >= Self.chunk {
            let chunk = pending.prefix(Self.chunk).map { $0 * 32767 }
            pending.removeFirst(Self.chunk)
            if let score = process(Array(chunk)) {
                lastScore = score
                if score >= threshold, now.timeIntervalSince(lastFire) >= cooldown { lastFire = now; fired = true }
            }
        }
        return fired
    }

    func process(_ chunk: [Float]) -> Float? {
        raw.append(contentsOf: chunk)
        if raw.count > 16000 * 10 { raw.removeFirst(raw.count - 16000 * 10) }
        let need = Self.chunk + 160 * 3
        guard raw.count >= need else { return nil }
        let window = Array(raw.suffix(need))
        guard let m = try? mel.run(window, shape: [1, Int64(need)], maxOutput: 4096) else { return nil }
        // shape [1, 1, frames, 32]; openWakeWord rescales mel values by x/10 + 2
        let frames = m.data.count / 32
        for f in 0..<frames { melFrames.append((0..<32).map { m.data[f * 32 + $0] / 10 + 2 }) }
        if melFrames.count > 970 { melFrames.removeFirst(melFrames.count - 970) }
        let last = melFrames.suffix(76)
        let input = last.flatMap { $0 }
        guard let e = try? embed.run(input, shape: [1, 76, 32, 1], maxOutput: 1024), e.data.count == 96 else { return nil }
        embeddings.append(e.data)
        if embeddings.count > 120 { embeddings.removeFirst(embeddings.count - 120) }
        guard embeddings.count >= 16 else { return nil }
        let feats = embeddings.suffix(16).flatMap { $0 }
        guard let p = try? wake.run(feats, shape: [1, 16, 96], maxOutput: 16), let s = p.data.first else { return nil }
        return s
    }

    public func reset() { raw = []; pending = []; embeddings = []; melFrames = Array(repeating: Array(repeating: 1, count: 32), count: 76) }
}

/// Battery rule for the wake word: pause below 20% when not charging, announce once, resume on charge.
public struct BatteryPolicy {
    public enum Action: Equatable { case none, pause(announce: Bool), resume }
    public private(set) var paused = false
    var announced = false
    public static let lowPercent = 20
    public init() {}

    public mutating func update(_ s: Battery.Status) -> Action {
        if !paused, s.percent < Self.lowPercent, !s.charging {
            paused = true
            let announce = !announced
            announced = true
            return .pause(announce: announce)
        }
        if paused, s.charging {
            paused = false; announced = false
            return .resume
        }
        return .none
    }
}
