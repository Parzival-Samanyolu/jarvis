import AVFoundation
import Foundation
import JarvisCore

/// Records one utterance from the default mic: 16 kHz mono, ends on silence.
final class Recorder {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var cancelFlag = false

    func cancel() { lock.withLock { cancelFlag = true } }
    private var cancelled: Bool { lock.withLock { cancelFlag } }
    private func resetCancel() { lock.withLock { cancelFlag = false } }

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { c in AVCaptureDevice.requestAccess(for: .audio) { c.resume(returning: $0) } }
    }

    /// Returns a WAV file URL, or nil if nobody spoke before the timeout (or it was cancelled).
    func record(startTimeout: TimeInterval) async -> URL? {
        resetCancel()
        return await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            let input = engine.inputNode
            let inFmt = input.outputFormat(forBus: 0)
            guard inFmt.sampleRate > 0,
                  let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
                  let conv = AVAudioConverter(from: inFmt, to: outFmt) else { cont.resume(returning: nil); return }

            final class State {
                var detector: EndpointDetector; var samples: [Float] = []; var frame: [Float] = []; var done = false
                init(_ t: TimeInterval) { detector = EndpointDetector(startTimeout: t) }
            }
            let st = State(startTimeout)
            let frameLen = 16000 * EndpointDetector.frameMs / 1000

            func finish(hadSpeech: Bool) {
                guard !st.done else { return }
                st.done = true
                DispatchQueue.main.async {
                    input.removeTap(onBus: 0); self.engine.stop()
                    guard hadSpeech, !self.cancelled else { cont.resume(returning: nil); return }
                    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jarvis-\(UUID().uuidString).wav")
                    do { try WAV.encode(st.samples).write(to: url); cont.resume(returning: url) } catch { cont.resume(returning: nil) }
                }
            }

            input.installTap(onBus: 0, bufferSize: 2048, format: inFmt) { [weak self] buf, _ in
                guard let self, !st.done else { return }
                if self.cancelled { finish(hadSpeech: false); return }
                let cap = AVAudioFrameCount(Double(buf.frameLength) * 16000 / inFmt.sampleRate) + 32
                guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return }
                var fed = false
                var err: NSError?
                conv.convert(to: out, error: &err) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true; status.pointee = .haveData; return buf
                }
                guard err == nil, let ch = out.floatChannelData?[0] else { return }
                let chunk = UnsafeBufferPointer(start: ch, count: Int(out.frameLength))
                st.samples.append(contentsOf: chunk)
                st.frame.append(contentsOf: chunk)
                while st.frame.count >= frameLen {
                    let rms = EndpointDetector.rms(st.frame[0..<frameLen])
                    st.frame.removeFirst(frameLen)
                    if case .done(let had) = st.detector.feed(rms: rms) { finish(hadSpeech: had); return }
                }
            }
            do { engine.prepare(); try engine.start() } catch { input.removeTap(onBus: 0); cont.resume(returning: nil) }
        }
    }
}

/// Speech-to-text through whisper.cpp's `whisper-cli` with the base.en model.
struct Transcriber {
    static let cliCandidates = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
    static var cli: String? { cliCandidates.first { FileManager.default.isExecutableFile(atPath: $0) } }
    static var model: String { Paths.models.appendingPathComponent("ggml-base.en.bin").path }
    static var available: Bool { cli != nil && FileManager.default.fileExists(atPath: model) }

    func transcribe(_ wav: URL) async -> String {
        defer { try? FileManager.default.removeItem(at: wav) }
        guard let cli = Self.cli else { return "" }
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: cli)
                p.arguments = ["-m", Self.model, "-f", wav.path, "-nt", "-np", "-l", "en"]
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: ""); return }
                let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                cont.resume(returning: Speech.clean(String(decoding: d, as: UTF8.self)))
            }
        }
    }
}
