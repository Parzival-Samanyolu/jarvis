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

    /// Name of the mic recordings come from right now (the system default input).
    static var currentMicName: String { AVCaptureDevice.default(for: .audio)?.localizedName ?? "Default mic" }

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { c in AVCaptureDevice.requestAccess(for: .audio) { c.resume(returning: $0) } }
    }

    /// Returns a WAV file URL, or nil if nobody spoke before the timeout (or it was cancelled, or the mic kept failing).
    /// With `fixed` set, records exactly that many seconds and ignores silence.
    /// `onAudio` sees every chunk as it arrives (on the audio thread), for live transcription.
    func record(startTimeout: TimeInterval, fixed: TimeInterval? = nil, onAudio: (([Float]) -> Void)? = nil) async -> URL? {
        lock.withLock { cancelFlag = false; onCancel = nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            final class State {
                var detector: EndpointDetector; var samples: [Float] = []; var frame: [Float] = []; var done = false
                var engine: AVAudioEngine?; var observer: NSObjectProtocol?; var restarts = 0
                init(_ t: TimeInterval) { detector = EndpointDetector(startTimeout: t) }
            }
            let st = State(startTimeout)
            let frameLen = 16000 * EndpointDetector.frameMs / 1000

            func teardown() {
                if let o = st.observer { NotificationCenter.default.removeObserver(o); st.observer = nil }
                st.engine?.inputNode.removeTap(onBus: 0); st.engine?.stop(); st.engine = nil
            }

            // Always runs on the main queue, so `done` is only decided in one place.
            func finish(hadSpeech: Bool) {
                DispatchQueue.main.async {
                    guard !st.done else { return }
                    st.done = true
                    self.lock.withLock { self.onCancel = nil }
                    teardown()
                    guard hadSpeech, !self.cancelled else { cont.resume(returning: nil); return }
                    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jarvis-\(UUID().uuidString).wav")
                    do { try WAV.encode(st.samples).write(to: url); cont.resume(returning: url) } catch { cont.resume(returning: nil) }
                }
            }

            // Opens the current mic on a fresh engine. Audio already recorded is kept.
            func open() {
                let engine = AVAudioEngine()
                let input = engine.inputNode
                guard let rs = Resampler(from: input.outputFormat(forBus: 0)) else { finish(hadSpeech: false); return }
                input.installTap(onBus: 0, bufferSize: 2048, format: rs.inFmt) { [weak self] buf, _ in
                    guard let self, !st.done else { return }
                    if self.cancelled { finish(hadSpeech: false); return }
                    let chunk = rs.convert(buf)
                    st.samples.append(contentsOf: chunk)
                    onAudio?(chunk)
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
                // Device changes stop the engine: a headset connecting, or a Bluetooth headset switching to
                // its mic profile the moment the mic opens. Reopen on the new device instead of giving up.
                st.observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
                    guard !st.done else { return }
                    teardown()
                    st.restarts += 1
                    NSLog("Jarvis: mic changed during recording, reopening (%d)", st.restarts)
                    guard st.restarts <= 5 else { finish(hadSpeech: false); return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if !st.done { open() } }
                }
                st.engine = engine
                do { engine.prepare(); try engine.start() } catch {
                    NSLog("Jarvis: mic failed to start: %@", "\(error)")
                    finish(hadSpeech: false)
                }
            }

            lock.withLock { onCancel = { finish(hadSpeech: false) } }
            if cancelled { finish(hadSpeech: false); return }
            if Thread.isMainThread { open() } else { DispatchQueue.main.async { open() } }
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

/// Speech-to-text. Apple's on-device transcriber when it's available (macOS 26+): it listens while the owner
/// talks, so the words are ready almost as soon as they stop. Whisper (whisper.cpp, base.en) is the fallback.
final class Transcriber {
    static let cliCandidates = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
    static var cli: String? { cliCandidates.first { FileManager.default.isExecutableFile(atPath: $0) } }
    static var model: String { Paths.models.appendingPathComponent("ggml-base.en.bin").path }
    static var whisperAvailable: Bool { cli != nil && FileManager.default.fileExists(atPath: model) }

    /// Set once Apple's transcriber is ready (its model is downloaded on first launch).
    private(set) var appleLocale: Locale?
    var available: Bool { appleLocale != nil || Self.whisperAvailable }

    func prepare() async {
        if #available(macOS 26, *) { appleLocale = await LiveTranscriber.prepare() }
        NSLog("Jarvis: speech-to-text is %@", appleLocale.map { "Apple (\($0.identifier))" } ?? (Self.whisperAvailable ? "Whisper" : "missing"))
    }

    /// A live session to feed while recording, or nil to use Whisper on the finished recording.
    func begin() -> LiveSession? {
        guard let appleLocale else { return nil }
        if #available(macOS 26, *) { return LiveSession(LiveTranscriber(locale: appleLocale)) }
        return nil
    }

    /// The words in `wav`, from the live session if there was one, otherwise (or if it failed) from Whisper.
    func transcribe(_ wav: URL, live: LiveSession? = nil) async -> String {
        defer { try? FileManager.default.removeItem(at: wav) }
        if let live {
            do {
                let text = Speech.clean(try await live.finish())
                if !text.isEmpty { return text }
            } catch { NSLog("Jarvis: Apple transcription failed: %@", "\(error)") }
        }
        return await Self.whisper(wav)
    }

    static func whisper(_ wav: URL) async -> String {
        guard let cli else { return "" }
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: cli)
                p.arguments = ["-m", model, "-f", wav.path, "-nt", "-np", "-l", "en"]
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: ""); return }
                let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                cont.resume(returning: Speech.clean(String(decoding: d, as: UTF8.self)))
            }
        }
    }
}

/// Wraps the macOS 26 transcriber so the rest of the app needn't carry availability checks.
final class LiveSession {
    private let feedFn: ([Float]) -> Void
    private let finishFn: () async throws -> String
    private let cancelFn: () -> Void
    @available(macOS 26, *)
    init(_ t: LiveTranscriber) { feedFn = t.feed; finishFn = t.finish; cancelFn = t.cancel }
    func feed(_ s: [Float]) { feedFn(s) }
    func finish() async throws -> String { try await finishFn() }
    func cancel() { cancelFn() }
}
