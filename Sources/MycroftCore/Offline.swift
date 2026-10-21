import Foundation
import Network

/// What Mycroft can still do without the internet, with ready-made replies.
public enum OfflineAction: Equatable {
    case time, date, battery
    case volumeUp, volumeDown, volumeSet(Int)
    case open(String)
    case note(String)

    /// Recognises the simple requests Mycroft handles itself when Claude can't be reached.
    public static func parse(_ raw: String) -> OfflineAction? {
        var t = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?")))
        for name in ["mycroft"] where t.hasPrefix(name) {
            t = String(t.dropFirst(name.count)).trimmingCharacters(in: CharacterSet(charactersIn: ", ").union(.whitespaces))
        }
        for p in ["please ", "can you ", "could you "] where t.hasPrefix(p) { t = String(t.dropFirst(p.count)) }

        for p in ["make a note that ", "make a note ", "take a note that ", "take a note ", "note that ", "note down ", "write down "] where t.hasPrefix(p) {
            let original = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?")))
            let rest = String(original.suffix(t.count - p.count))   // same words, with the owner's capitals
            return rest.isEmpty ? nil : .note(rest.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if t.contains("battery") { return .battery }
        if t.contains("what time") || t == "time" || t.hasSuffix("the time") { return .time }
        if t.contains("what day") || t.contains("the date") || t.contains("what's today") || t.contains("today's date") { return .date }
        if t.contains("volume") || t.contains("louder") || t.contains("quieter") || t.hasPrefix("turn it ") {
            if let m = t.range(of: #"\d{1,3}"#, options: .regularExpression), let n = Int(t[m]) { return .volumeSet(min(n, 100)) }
            if t.contains("up") || t.contains("louder") || t.contains("raise") || t.contains("increase") { return .volumeUp }
            if t.contains("down") || t.contains("quieter") || t.contains("lower") || t.contains("decrease") { return .volumeDown }
            return nil
        }
        for p in ["open ", "launch ", "start "] where t.hasPrefix(p) {
            var app = String(t.dropFirst(p.count))
            for s in [" for me", " app", " application"] where app.hasSuffix(s) { app = String(app.dropLast(s.count)) }
            app = app.trimmingCharacters(in: .whitespaces)
            return app.isEmpty ? nil : .open(app.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " "))
        }
        return nil
    }

    /// Does it and returns what to say.
    public func perform(now: Date = Date()) async -> String {
        switch self {
        case .time:
            let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "h:mm a"
            return "It's \(f.string(from: now)), sir."
        case .date:
            let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEEE d MMMM"
            return "It's \(f.string(from: now)), sir."
        case .battery:
            guard let b = await Battery.current() else { return "I can't read the battery, sir." }
            return "The battery is at \(b.percent) percent, sir\(b.charging ? ", and on the mains" : "")."
        case .volumeUp, .volumeDown, .volumeSet:
            let target: String
            switch self {
            case .volumeSet(let n): target = "\(n)"
            case .volumeUp: target = "(output volume of (get volume settings)) + 15"
            default: target = "(output volume of (get volume settings)) - 15"
            }
            let r = await CommandRunner.execute("osascript -e 'set volume output volume \(target)' -e 'output volume of (get volume settings)'", timeout: 5)
            let now = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return r.exitCode == 0 && !now.isEmpty ? "Volume at \(now) percent, sir." : "The volume refuses to cooperate, sir."
        case .open(let app):
            let safe = app.replacingOccurrences(of: "'", with: "")
            let r = await CommandRunner.execute("open -a '\(safe)'", timeout: 10)
            return r.exitCode == 0 ? "Opening \(app), sir." : "I can't find an app called \(app), sir."
        case .note(let text):
            _ = Notes.save(text)
            return "Noted, sir."
        }
    }
}

/// Watches the network so an offline request is answered at once instead of waiting for a failed call.
public final class Connectivity: @unchecked Sendable {
    public static let shared = Connectivity()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var online = true
    public var onChange: ((Bool) -> Void)?

    public var isOnline: Bool { lock.lock(); defer { lock.unlock() }; return online }

    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let now = path.status == .satisfied
            self.lock.lock(); let changed = now != self.online; self.online = now; self.lock.unlock()
            if changed { self.onChange?(now) }
        }
        monitor.start(queue: DispatchQueue(label: "mycroft.network"))
    }
}
