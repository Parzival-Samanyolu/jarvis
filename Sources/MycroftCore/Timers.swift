import Foundation

/// Countdown timers and reminders ("remind me in 10 minutes", "remind me at 6pm"). When one ends, `onFire` is
/// called on the main queue and the app says so aloud. They're saved to `file`, so a restart doesn't lose them,
/// and they run on the wall clock, so one that ends while the Mac sleeps fires as soon as it wakes.
public final class Timers: @unchecked Sendable {
    public struct Item: Equatable, Codable {
        public let id: Int
        public let seconds: Int
        /// What to remind the owner of ("drink some water"); empty for a plain timer.
        public let label: String
        public let ends: Date

        /// What Mycroft says when it ends.
        public var announcement: String {
            label.isEmpty ? "Sir, your \(Timers.spoken(seconds, plural: false)) timer is up." : "Sir, you asked me to remind you to \(label)."
        }
    }

    public var onFire: ((Item) -> Void)?
    private let lock = NSLock()
    private var items: [Int: (item: Item, work: DispatchWorkItem)] = [:]
    private var nextID = 1
    let file: URL?
    /// Timers that ended while Mycroft wasn't running are still announced if they ended within this long.
    public static let lateLimit: TimeInterval = 12 * 3600

    public init(file: URL? = nil) { self.file = file }

    /// Loads the saved timers: schedules the ones still running and fires (late) the ones that ended while
    /// Mycroft was closed. Call once, after setting `onFire`.
    public func restore(now: Date = Date()) {
        guard let file, let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([Item].self, from: data) else { return }
        lock.withLock {
            for item in saved where item.ends > now.addingTimeInterval(-Self.lateLimit) {
                nextID = max(nextID, item.id + 1)
                schedule(item, now: now)
            }
        }
        save()
    }

    /// Must hold `lock`.
    private func schedule(_ item: Item, now: Date) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.lock.withLock({ self.items.removeValue(forKey: item.id) }) != nil else { return }
            self.save()
            self.onFire?(item)
        }
        items[item.id] = (item, work)
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(0, item.ends.timeIntervalSince(now)), execute: work)
    }

    private func save() {
        guard let file else { return }
        let all = active
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(all) { try? d.write(to: file, options: .atomic) }
    }

    public var active: [Item] { lock.withLock { items.values.map(\.item).sorted { $0.ends < $1.ends } } }

    @discardableResult
    public func start(seconds: Int, label: String = "", now: Date = Date()) -> Item {
        let item = lock.withLock {
            let item = Item(id: nextID, seconds: seconds, label: label, ends: now.addingTimeInterval(TimeInterval(seconds)))
            nextID += 1
            schedule(item, now: now)
            return item
        }
        save()
        return item
    }

    /// Cancels every timer and returns how many there were.
    @discardableResult
    public func cancelAll() -> Int {
        let n = lock.withLock {
            let n = items.count
            for (_, v) in items { v.work.cancel() }
            items = [:]
            return n
        }
        save()
        return n
    }

    /// "Your 25 minute timer has 12 minutes left, sir." for each running timer.
    public func status(now: Date = Date()) -> String {
        let a = active
        if a.isEmpty { return "There's no timer running, sir." }
        return a.map { i -> String in
            let left = Timers.spoken(max(1, Int(i.ends.timeIntervalSince(now).rounded())))
            return i.label.isEmpty ? "Your \(Timers.spoken(i.seconds, plural: false)) timer has \(left) left, sir." : "\(left.prefix(1).uppercased() + left.dropFirst()) until I remind you to \(i.label), sir."
        }.joined(separator: " ")
    }

    /// 1500 -> "25 minutes", 5400 -> "1 hour and 30 minutes". With `plural: false` it reads as an adjective:
    /// "your 25 minute timer".
    public static func spoken(_ seconds: Int, plural: Bool = true) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(plural && n != 1 ? "s" : "")" }
        var parts: [String] = []
        if h > 0 { parts.append(unit(h, "hour")) }
        if m > 0 { parts.append(unit(m, "minute")) }
        if s > 0 && h == 0 { parts.append(unit(s, "second")) }
        return parts.isEmpty ? unit(0, "second") : parts.joined(separator: " and ")
    }

    /// Seconds from `now` until a clock time in `t`: "at 6", "at 6pm", "at 6:30 pm", "at 18:30". Without am or pm,
    /// the next time the clock shows it (6 at 4pm means 6pm). Nil if there's no time.
    static func secondsUntilClockTime(in t: String, now: Date, calendar: Calendar = .current) -> (seconds: Int, range: Range<String.Index>)? {
        let re = try! NSRegularExpression(pattern: #"\bat (\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?|o'clock)?(?=\W|$)"#)
        guard let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), let r = Range(m.range, in: t),
              let hr = Range(m.range(at: 1), in: t), var h = Int(t[hr]), h < 24 else { return nil }
        let minute = Range(m.range(at: 2), in: t).flatMap { Int(t[$0]) } ?? 0
        guard minute < 60 else { return nil }
        let suffix = Range(m.range(at: 3), in: t).map { String(t[$0]).replacingOccurrences(of: ".", with: "") } ?? ""
        if suffix == "pm", h < 12 { h += 12 }
        if suffix == "am", h == 12 { h = 0 }
        let either = suffix.hasSuffix("m") || h > 12 || h == 0 ? [h] : [h, (h + 12) % 24]
        let next = either.compactMap { hour in
            calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute, second: 0), matchingPolicy: .nextTime)
        }.min()
        guard let next else { return nil }
        return (Int(next.timeIntervalSince(now).rounded()), r)
    }

    static let numberWords: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "twenty five": 25, "twenty-five": 25,
        "thirty": 30, "forty": 40, "forty five": 45, "forty-five": 45, "fifty": 50, "sixty": 60, "ninety": 90,
    ]

    /// The total length of every "25 minutes", "an hour", "1 hour 30 minutes", "half an hour" in `t`
    /// (lowercased), and the ranges they cover, or nil if there are none.
    static func duration(in t: String) -> (seconds: Int, ranges: [Range<String.Index>])? {
        var total = 0, ranges: [Range<String.Index>] = []
        for (phrase, secs) in [("an hour and a half", 5400), ("half an hour", 1800), ("a minute and a half", 90)] {
            if let r = t.range(of: phrase) { total += secs; ranges.append(r) }
        }
        let words = numberWords.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        let re = try! NSRegularExpression(pattern: #"\b(\d+|"# + words + #")\s*(hours?|hrs?|minutes?|mins?|seconds?|secs?)\b"#)
        for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
            guard let r = Range(m.range, in: t), !ranges.contains(where: { $0.overlaps(r) }),
                  let nr = Range(m.range(at: 1), in: t), let ur = Range(m.range(at: 2), in: t) else { continue }
            let n = Int(t[nr]) ?? numberWords[String(t[nr])] ?? 0
            let u = t[ur]
            total += n * (u.hasPrefix("h") ? 3600 : u.hasPrefix("m") ? 60 : 1)
            ranges.append(r)
        }
        return total > 0 ? (total, ranges) : nil
    }
}
