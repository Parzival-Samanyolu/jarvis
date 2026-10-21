import Foundation

/// Speaks through `say`. Killable at any moment (hotkey stop).
public final class Speaker {
    /// Changeable at any time (Settings); the next line spoken uses it.
    public var voice: String { get { lock.lock(); defer { lock.unlock() }; return _voice } set { lock.lock(); _voice = newValue; lock.unlock() } }
    public var rate: Int? { get { lock.lock(); defer { lock.unlock() }; return _rate } set { lock.lock(); _rate = newValue; lock.unlock() } }
    private var _voice: String
    private var _rate: Int?
    var process: Process?
    let lock = NSLock()
    public var onSpeakingChanged: ((Bool) -> Void)?

    public init() {
        _voice = Self.pickVoice(installed: Self.installed(), chosen: Settings.voice)
        _rate = Settings.rate
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

    static func run(_ exe: String, _ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try? p.run(); let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }

    public var isSpeaking: Bool { lock.lock(); defer { lock.unlock() }; return process?.isRunning ?? false }

    /// Lines play one after another, in the order queued. `stop()` drops everything queued.
    var tail: Task<Void, Never>?
    var generation = 0

    /// Queues a line and returns at once. Safe from any thread.
    public func enqueue(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        lock.lock()
        let prev = tail, gen = generation
        tail = Task { [weak self] in
            await prev?.value
            guard let self, self.current(gen) else { return }
            await self.play(t)
        }
        lock.unlock()
    }

    /// Waits until everything queued so far has been spoken (or stopped).
    public func drain() async { await currentTail()?.value }
    func currentTail() -> Task<Void, Never>? { lock.lock(); defer { lock.unlock() }; return tail }

    /// Speaks after anything already queued and returns when finished or stopped.
    public func speak(_ text: String) async { enqueue(text); await drain() }

    func current(_ gen: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return gen == generation }

    func play(_ t: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = ["-v", voice] + (rate.map { ["-r", String($0)] } ?? []) + ["--", t]
            p.terminationHandler = { [weak self] _ in
                self?.lock.lock(); self?.process = nil; self?.lock.unlock()
                self?.onSpeakingChanged?(false)
                cont.resume()
            }
            lock.lock(); process = p; lock.unlock()
            do { try p.run(); onSpeakingChanged?(true) } catch { lock.lock(); process = nil; lock.unlock(); cont.resume() }
        }
    }

    public func stop() {
        lock.lock(); generation += 1; let p = process; lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }
}
