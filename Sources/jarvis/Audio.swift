import AVFoundation
import Foundation
import JarvisCore

/// Converts mic buffers to 16 kHz mono floats.
final class Resampler {
    let inFmt: AVAudioFormat
    let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    let conv: AVAudioConverter

    init?(from fmt: AVAudioFormat) {
        guard fmt.sampleRate > 0, let c = AVAudioConverter(from: fmt, to: outFmt) else { return nil }
        inFmt = fmt; conv = c
    }

    func convert(_ buf: AVAudioPCMBuffer) -> [Float] {
        let cap = AVAudioFrameCount(Double(buf.frameLength) * 16000 / inFmt.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return [] }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buf
        }
        guard err == nil, let ch = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
    }
}

/// Records one utterance from the default mic: 16 kHz mono, ends on silence (or after a fixed time).
/// Each recording builds a fresh engine so it always uses the current input device and its format.
final class Recorder {
    private let lock = NSLock()
    private var cancelFlag = false
    private var onCancel: (() -> Void)?

    /// Ends the current recording even if the mic has stopped delivering audio.
    func cancel() {
        let stop = lock.withLock { cancelFlag = true; return onCancel }
        stop?()
    }
    private var cancelled: Bool { lock.withLock { cancelFlag } }

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { c in AVCaptureDevice.requestAccess(for: .audio) { c.resume(returning: $0) } }
    }

    /// Returns a WAV file URL, or nil if nobody spoke before the timeout (or it was cancelled, or the mic changed).
    /// With `fixed` set, records exactly that many seconds and ignores silence.
    func record(startTimeout: TimeInterval, fixed: TimeInterval? = nil) async -> URL? {
        lock.withLock { cancelFlag = false; onCancel = nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            let engine = AVAudioEngine()
            let input = engine.inputNode
            guard let rs = Resampler(from: input.outputFormat(forBus: 0)) else { cont.resume(returning: nil); return }

            final class State {
                var detector: EndpointDetector; var samples: [Float] = []; var frame: [Float] = []; var done = false
                var observer: NSObjectProtocol?
                init(_ t: TimeInterval) { detector = EndpointDetector(startTimeout: t) }
            }
            let st = State(startTimeout)
            let frameLen = 16000 * EndpointDetector.frameMs / 1000

            // Always runs on the main queue, so `done` is only decided in one place.
            func finish(hadSpeech: Bool) {
                DispatchQueue.main.async {
                    guard !st.done else { return }
                    st.done = true
                    if let o = st.observer { NotificationCenter.default.removeObserver(o) }
                    self.lock.withLock { self.onCancel = nil }
                    input.removeTap(onBus: 0); engine.stop()
                    guard hadSpeech, !self.cancelled else { cont.resume(returning: nil); return }
                    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jarvis-\(UUID().uuidString).wav")
                    do { try WAV.encode(st.samples).write(to: url); cont.resume(returning: url) } catch { cont.resume(returning: nil) }
                }
            }

            // A headset connecting or disconnecting stops the engine; end this recording instead of waiting forever.
            st.observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
                NSLog("Jarvis: audio device changed during recording")
                finish(hadSpeech: false)
            }
            lock.withLock { onCancel = { finish(hadSpeech: false) } }
            if cancelled { finish(hadSpeech: false); return }

            input.installTap(onBus: 0, bufferSize: 2048, format: rs.inFmt) { [weak self] buf, _ in
                guard let self, !st.done else { return }
                if self.cancelled { finish(hadSpeech: false); return }
                let chunk = rs.convert(buf)
                st.samples.append(contentsOf: chunk)
                if let fixed {
                    if Double(st.samples.count) >= fixed * 16000 { finish(hadSpeech: true) }
                    return
                }
                st.frame.append(contentsOf: chunk)
                while st.frame.count >= frameLen {
                    let rms = EndpointDetector.rms(st.frame[0..<frameLen])
                    st.frame.removeFirst(frameLen)
                    if case .done(let had) = st.detector.feed(rms: rms) { finish(hadSpeech: had); return }
                }
            }
            do { engine.prepare(); try engine.start() } catch { finish(hadSpeech: false) }
        }
    }
}

/// Always-on "Hey Jarvis" listener. Runs only while Jarvis is idle (see AppController.updateWake).
/// Rebuilds its engine on each start, so it follows the current input device.
final class WakeListener {
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private let queue = DispatchQueue(label: "jarvis.wake")
    private let detector: WakeWordDetector
    private(set) var running = false
    var onWake: (() -> Void)?
    /// Called after the input device changes; the app restarts listening if it is still idle.
    var onDeviceChange: (() -> Void)?

    init?() {
        guard Models.wakeWordAvailable, let d = try? WakeWordDetector() else { return nil }
        detector = d
    }

    func start() {
        guard !running else { return }
        let engine = AVAudioEngine()
        guard let rs = Resampler(from: engine.inputNode.outputFormat(forBus: 0)) else { return }
        queue.sync { detector.reset() }
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: rs.inFmt) { [weak self] buf, _ in
            let samples = rs.convert(buf)
            self?.queue.async {
                guard let self, self.running else { return }
                if self.detector.feed(samples) { DispatchQueue.main.async { self.onWake?() } }
            }
        }
        do { engine.prepare(); try engine.start() } catch { engine.inputNode.removeTap(onBus: 0); return }
        self.engine = engine
        running = true
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.running else { return }
            NSLog("Jarvis: audio device changed; restarting wake listener")
            self.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.onDeviceChange?() }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        engine?.inputNode.removeTap(onBus: 0); engine?.stop(); engine = nil
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
