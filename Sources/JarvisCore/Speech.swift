import Foundation

/// Speaks through `say`. Killable at any moment (hotkey stop).
public final class Speaker {
    public let voice: String
    var process: Process?
    let lock = NSLock()
    public var onSpeakingChanged: ((Bool) -> Void)?

    public init() {
        // Prefer the Premium download if installed; otherwise plain Daniel.
        let list = Self.run("/usr/bin/say", ["-v", "?"])
        voice = list.contains("Daniel (Premium)") ? "Daniel (Premium)" : (list.contains("Daniel (Enhanced)") ? "Daniel (Enhanced)" : "Daniel")
    }

    static func run(_ exe: String, _ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try? p.run(); let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }

    public var isSpeaking: Bool { lock.lock(); defer { lock.unlock() }; return process?.isRunning ?? false }

    /// Speaks and returns when finished or stopped.
    public func speak(_ text: String) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = ["-v", voice, "--", t]
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
        lock.lock(); let p = process; lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }
}
