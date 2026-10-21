import AVFoundation
import Foundation
import Speech

/// Apple's on-device speech-to-text (macOS 26+), fed while the owner is still talking, so the words are
/// ready almost as soon as they stop. One instance per utterance.
@available(macOS 26, *)
public final class LiveTranscriber: @unchecked Sendable {
    /// Names it would otherwise mishear.
    public static let hints = ["Mycroft", "Konya", "Haiku", "Sonnet", "Opus", "Safari", "Spotify"]
    static let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    private let raw: AsyncStream<[Float]>.Continuation
    private let task: Task<String, Error>

    /// Starts loading at once; audio fed before it is ready waits in a queue, so the mic never waits for it.
    public init(locale: Locale) {
        let (stream, cont) = AsyncStream<[Float]>.makeStream()
        raw = cont
        task = Task { try await Self.run(locale: locale, audio: stream) }
    }

    /// 16 kHz mono samples, from any thread.
    public func feed(_ samples: [Float]) { if !samples.isEmpty { raw.yield(samples) } }

    /// Ends the audio and returns the text.
    public func finish() async throws -> String {
        raw.finish()
        return try await task.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func cancel() { raw.finish(); task.cancel() }

    /// The supported locale closest to `preferred`, with its model installed (downloaded on first use),
    /// or nil if Apple's transcriber can't be used here.
    public static func prepare(preferred: Locale = Locale(identifier: "en-GB")) async -> Locale? {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: preferred) else { return nil }
        let installed = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
        if !installed.contains(locale.identifier(.bcp47)) {
            do {
                try await AssetInventory.assetInstallationRequest(supporting: [SpeechTranscriber(locale: locale, preset: .transcription)])?.downloadAndInstall()
            } catch {
                NSLog("Jarvis: speech model download failed: %@", "\(error)")
                return nil
            }
        }
        return locale
    }

    private static func run(locale: Locale, audio: AsyncStream<[Float]>) async throws -> String {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) ?? sourceFormat
        let converter = format == sourceFormat ? nil : AVAudioConverter(from: sourceFormat, to: format)
        let context = AnalysisContext()
        context.contextualStrings[.general] = hints
        try await analyzer.setContext(context)
        try await analyzer.prepareToAnalyze(in: format)

        let (inputs, input) = AsyncStream<AnalyzerInput>.makeStream()
        let pump = Task {
            for await samples in audio {
                if let b = convert(samples, to: format, with: converter) { input.yield(AnalyzerInput(buffer: b)) }
            }
            input.finish()
        }
        let collect = Task {
            var text = ""
            for try await r in transcriber.results { text += String(r.text.characters) }
            return text
        }
        try await analyzer.start(inputSequence: inputs)
        await pump.value
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collect.value
    }

    private static func convert(_ samples: [Float], to format: AVAudioFormat, with converter: AVAudioConverter?) -> AVAudioPCMBuffer? {
        guard let src = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        src.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        guard let converter else { return src }
        let cap = AVAudioFrameCount(Double(samples.count) * format.sampleRate / 16000) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return src
        }
        return err == nil ? out : nil
    }
}
