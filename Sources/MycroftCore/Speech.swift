import AVFoundation
import Foundation

/// Speaks in-process with one long-lived synthesizer: the voice loads once and queued sentences follow
/// each other without the ~0.75 s start-up a fresh `say` process costs per line. Killable at any moment (hotkey stop).
public final class Speaker {
    /// Changeable at any time (Settings); the next line spoken uses it.
    public var voice: String { get { lock.lock(); defer { lock.unlock() }; return _voice } set { lock.lock(); _voice = newValue; lock.unlock() } }
    public var rate: Int? { get { lock.lock(); defer { lock.unlock() }; return _rate } set { lock.lock(); _rate = newValue; lock.unlock() } }
    private var _voice: String
    private var _rate: Int?
    let lock = NSLock()
    public var onSpeakingChanged: ((Bool) -> Void)?

    public init() {
        _voice = Self.voiceForMode()
        _rate = Self.rateForMode()
    }

    public static func installed() -> [(name: String, locale: String)] { voices(run("/usr/bin/say", ["-v", "?"])) }

    /// Installed voices as (name, locale), from `say -v ?`.
    public static func voices(_ list: String) -> [(name: String, locale: String)] {
        // "Daniel (English (UK)) en_GB    # Hello!": the locale is the last word before the "#".
        list.split(separator: "\n").compactMap { line in
            let left = line.components(separatedBy: " #")[0].trimmingCharacters(in: .whitespaces)
            guard let space = left.lastIndex(of: " ") else { return nil }
            let locale = String(left[left.index(after: space)...])
            guard locale.range(of: #"^[a-z]{2,3}_[A-Z0-9]{2,3}$"#, options: .regularExpression) != nil else { return nil }
            return (left[..<space].trimmingCharacters(in: .whitespaces), locale)
        }
    }

    /// The owner's chosen voice (`voice` in state.json) if installed; otherwise the best British voice:
    /// Premium, then Enhanced (downloaded in System Settings, much more natural), then Daniel.
    public static func pickVoice(installed: [(name: String, locale: String)], chosen: String?) -> String {
        if let chosen, installed.contains(where: { $0.name == chosen }) { return chosen }
        let british = installed.filter { $0.locale == "en_GB" }.map(\.name)
        for tier in ["(Premium)", "(Enhanced)"] {
            if let v = british.first(where: { $0.contains(tier) }) { return v }
        }
        return british.first { $0.hasPrefix("Daniel") } ?? "Daniel"
    }

    /// Undercover mode's voice: a Premium US voice if installed, then Evan (Enhanced), then any Enhanced US voice,
    /// then Samantha.
    public static func pickAmerican(installed: [(name: String, locale: String)]) -> String {
        let us = installed.filter { $0.locale == "en_US" }.map(\.name)
        if let v = us.first(where: { $0.contains("(Premium)") }) { return v }
        if let v = us.first(where: { $0 == "Evan (Enhanced)" }) { return v }
        if let v = us.first(where: { $0.contains("(Enhanced)") }) { return v }
        return us.first { $0.hasPrefix("Samantha") } ?? "Samantha"
    }

    /// The voice for the current persona. Comrade reads English with Milena, a Russian voice, for the accent;
    /// Big Brother is Rocko, the Pasha a male Turkish voice (Cem) or Yelda, Tech Support Aman. Each falls back to the butler's voice.
    public static func voiceForMode(installed: [(name: String, locale: String)] = installed()) -> String {
        func named(_ prefix: String) -> String? { installed.first { $0.name.hasPrefix(prefix) }?.name }
        switch Settings.persona {
        case .undercover: return pickAmerican(installed: installed)
        case .comrade: if let v = named("Milena") { return v }
        case .bigBrother: if let v = named("Rocko") { return v }
        case .pasha:
            // A male Turkish voice if one has been downloaded, otherwise Yelda.
            let turkish = installed.filter { $0.locale == "tr_TR" }.map(\.name)
            if let v = turkish.first(where: { !$0.hasPrefix("Yelda") }) ?? turkish.first { return v }
        case .techSupport:
            if let v = named("Aman") ?? named("Rishi") ?? installed.first(where: { $0.locale == "en_IN" })?.name { return v }
        case .butler: break
        }
        return pickVoice(installed: installed, chosen: Settings.voice)
    }

    /// Words a minute for the current persona: Milena is slowed so her English stays understandable.
    public static func rateForMode() -> Int? {
        switch Settings.persona {
        case .comrade: return 115
        case .bigBrother: return 160
        case .techSupport: return 190   // reading fast from the script
        case .butler, .undercover, .pasha: return Settings.rate
        }
    }

    static func run(_ exe: String, _ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try? p.run(); let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }

    /// The synthesizer's voice for a `say` name: "Arthur (Enhanced)" is called the same, "Daniel (English (UK))" is "Daniel".
    public static func avVoice(_ name: String) -> AVSpeechSynthesisVoice? {
        let locale = installed().first { $0.name == name }?.locale.replacingOccurrences(of: "_", with: "-")
        let all = AVSpeechSynthesisVoice.speechVoices().filter { locale == nil || $0.language == locale }
        return all.first { $0.name == name } ?? all.first { name.hasPrefix($0.name + " (") }
    }

    /// `say` words a minute to the synthesizer's 0...1 rate, from durations measured with Arthur
    /// (0.5, its default, is 185 wpm, the same as `say`'s default).
    public static func avRate(_ wpm: Int) -> Float {
        let points: [(Double, Double)] = [(130, 0.42), (150, 0.45), (185, 0.5), (230, 0.545), (280, 0.59)]
        let w = min(max(Double(wpm), points.first!.0), points.last!.0)
        for (a, b) in zip(points, points.dropFirst()) where w <= b.0 {
            return Float(a.1 + (w - a.0) / (b.0 - a.0) * (b.1 - a.1))
        }
        return Float(points.last!.1)
    }

    let synth = AVSpeechSynthesizer()
    let queue = DispatchQueue(label: "speaker")
    /// Silent playback (volume 0) for tests that time the queue without making a sound.
    var muted = false
    lazy var delegate = Delegate(owner: self)
    var voiceCache: (name: String, voice: AVSpeechSynthesisVoice?)?
    /// Utterances queued and not yet finished; `drain()` waiters resume when it empties.
    var pending = Set<ObjectIdentifier>()
    var waiters: [CheckedContinuation<Void, Never>] = []

    public var isSpeaking: Bool { lock.lock(); defer { lock.unlock() }; return !pending.isEmpty }

    /// Queues a line and returns at once. Safe from any thread. Lines play in the order queued.
    public func enqueue(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let u = AVSpeechUtterance(string: t)
        u.voice = resolvedVoice()
        u.rate = rate.map(Self.avRate) ?? AVSpeechUtteranceDefaultSpeechRate
        if muted { u.volume = 0 }
        lock.lock(); pending.insert(ObjectIdentifier(u)); lock.unlock()
        queue.async { [self] in synth.delegate = delegate; synth.speak(u) }
    }

    func resolvedVoice() -> AVSpeechSynthesisVoice? {
        let name = voice
        lock.lock(); let cached = voiceCache; lock.unlock()
        if let cached, cached.name == name { return cached.voice }
        let v = Self.avVoice(name)
        lock.lock(); voiceCache = (name, v); lock.unlock()
        return v
    }

    /// Waits until everything queued has been spoken (or stopped).
    public func drain() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if pending.isEmpty { lock.unlock(); cont.resume(); return }
            waiters.append(cont); lock.unlock()
        }
    }

    /// Speaks after anything already queued and returns when finished or stopped.
    public func speak(_ text: String) async { enqueue(text); await drain() }

    /// Called when an utterance ends; untracked ones (dropped by `stop()`) are ignored.
    func ended(_ u: AVSpeechUtterance) {
        lock.lock()
        guard pending.remove(ObjectIdentifier(u)) != nil, pending.isEmpty else { lock.unlock(); return }
        let w = waiters; waiters = []; lock.unlock()
        onSpeakingChanged?(false)
        w.forEach { $0.resume() }
    }

    public func stop() {
        lock.lock(); let was = !pending.isEmpty; pending = []; let w = waiters; waiters = []; lock.unlock()
        queue.async { [self] in synth.stopSpeaking(at: .immediate) }
        if was { onSpeakingChanged?(false) }
        w.forEach { $0.resume() }
    }

    final class Delegate: NSObject, AVSpeechSynthesizerDelegate {
        weak var owner: Speaker?
        init(owner: Speaker) { self.owner = owner }
        func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) { owner?.onSpeakingChanged?(true) }
        func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { owner?.ended(u) }
        func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { owner?.ended(u) }
    }
}
