import Foundation

public struct UsageRecord: Codable, Equatable {
    public var ts: Date
    public var model: String
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var searches: Int
    public var cost: Double
}

public final class UsageTracker {
    public static let cap = 80.0
    public static let warnAt = 0.9 * 80.0
    public static let searchCost = 0.01   // $10 per 1,000 searches

    let url: URL
    let calendar: Calendar
    public init(url: URL = Paths.usage, calendar: Calendar = .current) { self.url = url; self.calendar = calendar }

    public static func cost(model: Model, input: Int, output: Int, cacheRead: Int, searches: Int) -> Double {
        let p = model.price
        // `input` is uncached input only; cache reads are billed separately.
        return Double(input) / 1e6 * p.input + Double(output) / 1e6 * p.output
            + Double(cacheRead) / 1e6 * p.cacheRead + Double(searches) * searchCost
    }

    /// Record one API response's `usage` object.
    @discardableResult
    public func record(model: Model, usage: [String: Any], now: Date = Date()) -> UsageRecord {
        let input = usage["input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        let cache = usage["cache_read_input_tokens"] as? Int ?? 0
        let searches = ((usage["server_tool_use"] as? [String: Any])?["web_search_requests"] as? Int) ?? 0
        let r = UsageRecord(ts: now, model: model.rawValue, input: input, output: output, cacheRead: cache, searches: searches,
                            cost: Self.cost(model: model, input: input, output: output, cacheRead: cache, searches: searches))
        append(r)
        return r
    }

    func append(_ r: UsageRecord) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard var line = try? enc.encode(r) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line); try? h.close()
        } else { try? line.write(to: url) }
    }

    public func records() -> [UsageRecord] {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return s.split(separator: "\n").compactMap { try? dec.decode(UsageRecord.self, from: Data($0.utf8)) }
    }

    public func monthRecords(_ now: Date = Date()) -> [UsageRecord] {
        records().filter { calendar.isDate($0.ts, equalTo: now, toGranularity: .month) }
    }
    public func monthTotal(_ now: Date = Date()) -> Double { monthRecords(now).reduce(0) { $0 + $1.cost } }
    public func capReached(_ now: Date = Date()) -> Bool { monthTotal(now) >= Self.cap }
    public func nearCap(_ now: Date = Date()) -> Bool { let t = monthTotal(now); return t >= Self.warnAt && t < Self.cap }

    public func split(_ now: Date = Date()) -> [Model: Double] {
        var out: [Model: Double] = [:]
        for r in monthRecords(now) { if let m = Model(rawValue: r.model) { out[m, default: 0] += r.cost } }
        return out
    }

    /// Spoken-style summary for "How much have I spent?"
    public func report(_ now: Date = Date()) -> String {
        let total = monthTotal(now)
        let parts = split(now).sorted { $0.value > $1.value }.filter { $0.value >= 0.005 }
            .map { "\(Self.money($0.value)) on \($0.key.label)" }
        var s = "This month you've spent \(Self.money(total)) of your \(Int(Self.cap)) dollar cap, sir"
        if !parts.isEmpty { s += ": " + parts.joined(separator: ", ") }
        return s + "."
    }

    static func money(_ v: Double) -> String { String(format: "$%.2f", v) }
}
