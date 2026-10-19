import Foundation

/// Long-term memory: a plain Markdown file, one "- [yyyy-MM-dd] fact" line per fact.
public final class Memory {
    let url: URL
    let calendar: Calendar
    public init(url: URL = Paths.memory, calendar: Calendar = .current) { self.url = url; self.calendar = calendar }

    static func dateString(_ d: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public func text() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    public func lines() -> [String] { text().split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }

    /// The fact text with the date prefix removed.
    public static func fact(of line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("- ") { s.removeFirst(2) }
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") { s = String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespaces) }
        return s
    }
    public static func date(of line: String) -> String? {
        guard let a = line.firstIndex(of: "["), let b = line.firstIndex(of: "]"), a < b else { return nil }
        return String(line[line.index(after: a)..<b])
    }

    @discardableResult
    public func append(_ facts: [String], now: Date = Date()) -> [String] {
        let existing = Set(lines().map { Self.normalise(Self.fact(of: $0)) })
        var added: [String] = []
        var seen = existing
        for f in facts {
            let t = f.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(Self.normalise(t)).inserted else { continue }
            added.append(t)
        }
        guard !added.isEmpty else { return [] }
        var out = text()
        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
        let d = Self.dateString(now, calendar)
        for a in added { out += "- [\(d)] \(a)\n" }
        write(out)
        return added
    }

    /// "Forget that I..." removes the best-matching line(s). Returns the removed facts.
    @discardableResult
    public func forget(_ phrase: String) -> [String] {
        let keys = Self.keywords(phrase)
        guard !keys.isEmpty else { return [] }
        let all = lines()
        let scored = all.map { line -> (String, Double) in
            let words = Set(Self.keywords(Self.fact(of: line)))
            let hit = keys.filter { k in words.contains(k) || words.contains(where: { $0.hasPrefix(k) || k.hasPrefix($0) && $0.count > 3 }) }.count
            return (line, Double(hit) / Double(keys.count))
        }
        let best = scored.map(\.1).max() ?? 0
        guard best >= 0.6 else { return [] }
        let doomed = Set(scored.filter { $0.1 == best }.map(\.0))
        write(all.filter { !doomed.contains($0) }.joined(separator: "\n") + (all.count > doomed.count ? "\n" : ""))
        return doomed.map(Self.fact(of:))
    }

    public func remove(line: String) {
        write(lines().filter { $0 != line }.joined(separator: "\n") + "\n")
    }

    /// Facts added in the last 7 days (for the Sunday review).
    public func newThisWeek(now: Date = Date()) -> [String] {
        guard let from = calendar.date(byAdding: .day, value: -7, to: now) else { return [] }
        let cutoff = Self.dateString(from, calendar)
        return lines().filter { (Self.date(of: $0) ?? "") > cutoff }
    }

    public func readBack() -> String {
        let facts = lines().map(Self.fact(of:))
        if facts.isEmpty { return "I haven't learned anything about you yet, sir." }
        return "Here is what I know, sir. " + facts.joined(separator: " ")
    }

    func write(_ s: String) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? s.write(to: url, atomically: true, encoding: .utf8)
    }

    static func normalise(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }.split(separator: " ").joined(separator: " ")
    }
    static let stop: Set<String> = ["i", "a", "an", "the", "that", "is", "am", "are", "my", "me", "to", "of", "and", "in", "on", "at", "for", "sir", "user", "he", "his", "has", "have", "was", "it", "this", "i'm", "im", "you", "your", "about", "with", "do", "does", "like", "likes"]
    static func keywords(_ s: String) -> [String] {
        normalise(s).split(separator: " ").map(String.init).filter { !stop.contains($0) }
    }
}

/// Short-term context: the last N exchanges, reset after a few minutes of silence.
public final class Conversation {
    public struct Exchange { public var user: String; public var assistant: String }
    public private(set) var exchanges: [Exchange] = []
    public var maxExchanges = 8
    public var idleReset: TimeInterval = 300
    var lastActivity: Date?

    public init() {}

    public func add(user: String, assistant: String, now: Date = Date()) {
        expireIfIdle(now)
        exchanges.append(Exchange(user: user, assistant: assistant))
        if exchanges.count > maxExchanges { exchanges.removeFirst(exchanges.count - maxExchanges) }
        lastActivity = now
    }
    @discardableResult
    public func expireIfIdle(_ now: Date = Date()) -> Bool {
        if let l = lastActivity, now.timeIntervalSince(l) > idleReset, !exchanges.isEmpty { exchanges = []; return true }
        return false
    }
    public func reset() { exchanges = []; lastActivity = nil }

    public func messages() -> [[String: Any]] {
        exchanges.flatMap { [["role": "user", "content": $0.user], ["role": "assistant", "content": $0.assistant]] }
    }
    public var transcript: String { exchanges.map { "User: \($0.user)\nJarvis: \($0.assistant)" }.joined(separator: "\n") }
}
