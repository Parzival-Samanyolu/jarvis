import Foundation

/// Energy-based end-of-speech detector (replaces webrtcvad). Feed it 20 ms RMS values.
public struct EndpointDetector {
    public enum Event: Equatable { case waiting, speaking, done(hadSpeech: Bool) }

    public static let frameMs = 20
    public var startTimeout: TimeInterval
    public var maxDuration: TimeInterval = 20
    public var endSilence: TimeInterval = 0.9
    public var minSpeech: TimeInterval = 0.18
    public var calibration: TimeInterval = 0.3

    var elapsed = 0.0, speech = 0.0, silence = 0.0, calSum = 0.0, calN = 0.0
    var started = false

    public init(startTimeout: TimeInterval) { self.startTimeout = startTimeout }

    public var threshold: Float {
        let floor = calN > 0 ? Float(calSum / calN) : 0
        return max(0.015, min(floor, 0.02) * 3)
    }

    public mutating func feed(rms: Float) -> Event {
        let dt = Double(Self.frameMs) / 1000
        elapsed += dt
        if elapsed <= calibration { calSum += Double(rms); calN += 1; return .waiting }
        let loud = rms > threshold
        if !started {
            if loud { speech += dt; if speech >= minSpeech { started = true } } else { speech = 0 }
            if started { return .speaking }
            return elapsed >= startTimeout ? .done(hadSpeech: false) : .waiting
        }
        if loud { silence = 0 } else { silence += dt }
        if silence >= endSilence || elapsed >= maxDuration { return .done(hadSpeech: true) }
        return .speaking
    }

    public static func rms(_ s: ArraySlice<Float>) -> Float {
        guard !s.isEmpty else { return 0 }
        var acc: Float = 0
        for x in s { acc += x * x }
        return (acc / Float(s.count)).squareRoot()
    }
}

public enum WAV {
    /// 16-bit mono PCM WAV from float samples in -1...1.
    public static func encode(_ samples: [Float], sampleRate: Int = 16000) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let dataBytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 32767)
            u16(UInt16(bitPattern: v))
        }
        return d
    }
}

public enum Speech {
    /// whisper.cpp emits things like "[BLANK_AUDIO]" or "(silence)" for noise.
    public static func clean(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\n", with: " ")
        for (open, close) in [("[", "]"), ("(", ")"), ("*", "*"), ("♪", "♪")] {
            while let a = s.range(of: open), let b = s.range(of: close, range: a.upperBound..<s.endIndex) { s.removeSubrange(a.lowerBound..<b.upperBound) }
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!?, "))
        if t.isEmpty || ["you", "thank you", "thanks for watching", "bye", "okay"].contains(t) && s.count < 12 { return "" }
        return s
    }

    public enum Answer { case yes, no, unclear }

    public static func yesNo(_ raw: String) -> Answer {
        let t = " " + raw.lowercased().filter { $0.isLetter || $0 == " " } + " "
        let no = [" no ", " nope ", " don't ", " dont ", " do not ", " stop ", " cancel ", " negative ", " nah ", " never "]
        let yes = [" yes ", " yeah ", " yep ", " yup ", " proceed ", " go ahead ", " do it ", " sure ", " please do ", " affirmative ", " okay ", " ok ", " absolutely ", " certainly "]
        if no.contains(where: t.contains) { return .no }
        if yes.contains(where: t.contains) { return .yes }
        return .unclear
    }

    /// Weekly review answers.
    public static func keepOrDelete(_ raw: String) -> Bool? {
        let t = raw.lowercased()
        if t.contains("delete") || t.contains("remove") || t.contains("forget") { return false }
        if t.contains("keep") || t.contains("yes") || t.contains("fine") || t.contains("good") { return true }
        return nil
    }
}
