import Foundation
@testable import JarvisCore

struct Yes: Confirming { var answer = true; func confirm(_ d: String) async -> Bool { answer } }

final class StubTransport: Transport {
    var responses: [(Int, [String: Any])]
    var requests: [[String: Any]] = []
    var headers: [[String: String]] = []
    init(_ r: [(Int, [String: Any])]) { responses = r }
    func send(_ body: [String: Any], headers h: [String: String]) async throws -> (status: Int, data: Data) {
        requests.append(body); headers.append(h)
        let (s, j) = responses.isEmpty ? (200, ["content": [["type": "text", "text": "ok"]], "stop_reason": "end_turn"] as [String: Any]) : responses.removeFirst()
        return (s, try JSONSerialization.data(withJSONObject: j))
    }
}

func tmp(_ name: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d.appendingPathComponent(name)
}

func textResp(_ t: String, model: String = "claude-haiku-5-5", usage: [String: Any] = ["input_tokens": 1000, "output_tokens": 100]) -> (Int, [String: Any]) {
    (200, ["content": [["type": "text", "text": t]], "stop_reason": "end_turn", "model": model, "usage": usage])
}

func runCoreTests() {
    runRouterTests(); runIntentTests(); runUsageTests(); runMemoryTests(); runBatteryTests()
    let sem = DispatchSemaphore(value: 0)
    Task { await runBrainTests(); sem.signal() }
    sem.wait()
}

func runRouterTests() {
    expectEqual(Router.model(for: "what's the capital of France", mode: .auto, capReached: false), .haiku)
    expectEqual(Router.model(for: "open Safari", mode: .auto, capReached: false), .sonnet)
    expectEqual(Router.model(for: "what's on my screen", mode: .auto, capReached: false), .sonnet)
    expectEqual(Router.model(for: "think deeply about whether to move to Berlin", mode: .auto, capReached: false), .opus)
    expectEqual(Router.model(for: "open Safari", mode: .haiku, capReached: false), .haiku)
    expectEqual(Router.model(for: "hello", mode: .opus, capReached: false), .opus)
    expectEqual(Router.model(for: "think deeply", mode: .opus, capReached: true), .haiku)
}

func runIntentTests() {
    expectEqual(Intent.parse("Jarvis, mute."), .mute)
    expectEqual(Intent.parse("stop"), .stop)
    expectEqual(Intent.parse("Jarvis, use Opus"), .setMode(.opus))
    expectEqual(Intent.parse("Use auto."), .setMode(.auto))
    expectEqual(Intent.parse("How much have I spent?"), .spend)
    expectEqual(Intent.parse("What do you know about me?"), .whatDoYouKnow)
    expectEqual(Intent.parse("Forget that I like jazz."), .forget("like jazz"))
    expectEqual(Intent.parse("Forget that I'm vegetarian"), .forget("am vegetarian"))
    expectEqual(Intent.parse("What's the weather"), .none)
}

func runUsageTests() {
    let cal = Calendar(identifier: .gregorian)
    let u = UsageTracker(url: tmp("usage.jsonl"), calendar: cal)
    let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 12))!
    // Opus: 1M in = $4, 1M out = $20
    expect(abs(UsageTracker.cost(model: .opus, input: 1_000_000, output: 1_000_000, cacheRead: 0, searches: 0) - 24) < 1e-9)
    expect(abs(UsageTracker.cost(model: .haiku, input: 1_000_000, output: 0, cacheRead: 0, searches: 3) - 0.13) < 1e-9)
    u.record(model: .opus, usage: ["input_tokens": 1_000_000, "output_tokens": 0], now: now)
    u.record(model: .haiku, usage: ["input_tokens": 100_000, "output_tokens": 100_000, "server_tool_use": ["web_search_requests": 2]], now: now)
    let lastMonth = cal.date(byAdding: .month, value: -1, to: now)!
    u.record(model: .opus, usage: ["input_tokens": 10_000_000], now: lastMonth)
    expect(abs(u.monthTotal(now) - (4 + 0.01 + 0.05 + 0.02)) < 1e-6, "total \(u.monthTotal(now))")
    expect(!u.capReached(now)); expect(!u.nearCap(now))
    u.record(model: .opus, usage: ["output_tokens": 3_600_000], now: now)  // +$72
    expect(u.nearCap(now), "near cap \(u.monthTotal(now))")
    u.record(model: .opus, usage: ["output_tokens": 500_000], now: now)    // +$10
    expect(u.capReached(now)); expect(!u.nearCap(now))
    expectEqual(Router.model(for: "think deeply", mode: .auto, capReached: u.capReached(now)), .haiku)
    let next = cal.date(byAdding: .month, value: 1, to: now)!
    expect(!u.capReached(next), "cap resets with the month")
    expect(u.report(now).contains("Opus"))
}

func runMemoryTests() {
    let m = Memory(url: tmp("memory.md"), calendar: Calendar(identifier: .gregorian))
    let day = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 10, day: 19).date!
    expectEqual(m.append(["Likes jazz.", "Lives in Konya.", "likes jazz!"], now: day).count, 2)
    expectEqual(m.append(["Likes jazz"], now: day).count, 0)
    expect(m.text().contains("- [2026-10-19] Likes jazz."))
    expectEqual(m.forget("like jazz"), ["Likes jazz."])
    expectEqual(m.lines().count, 1)
    expectEqual(m.forget("play tennis"), [])
    expectEqual(m.lines().count, 1)
    expect(m.readBack().contains("Konya"))
    // Weekly review window
    let old = Calendar(identifier: .gregorian).date(byAdding: .day, value: -30, to: day)!
    m.append(["Old fact."], now: old)
    let recent = m.newThisWeek(now: day)
    expectEqual(recent.map(Memory.fact(of:)), ["Lives in Konya."])
    m.remove(line: recent[0])
    expect(!m.text().contains("Konya"))

    let c = Conversation()
    c.maxExchanges = 3
    let t0 = Date()
    for i in 0..<5 { c.add(user: "q\(i)", assistant: "a\(i)", now: t0) }
    expectEqual(c.exchanges.count, 3); expectEqual(c.exchanges.first?.user, "q2")
    expectEqual(c.messages().count, 6)
    expect(c.expireIfIdle(t0.addingTimeInterval(301))); expectEqual(c.exchanges.count, 0)
    expectEqual(Brain.parseFacts("Sure: [\"A fact.\", \"  \", \"B\"] done"), ["A fact.", "B"])
    expectEqual(Brain.parseFacts("no json"), [])
}

func runBatteryTests() {
    expectEqual(Battery.parse("Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t18%; discharging; 1:02 remaining"), Battery.Status(percent: 18, charging: false))
    expectEqual(Battery.parse("Now drawing from 'AC Power'\n -InternalBattery-0\t100%; charged"), Battery.Status(percent: 100, charging: true))
}

func runBrainTests() async {
    // Plain answer, routing and usage logging
    let usage = UsageTracker(url: tmp("u.jsonl"))
    let t = StubTransport([textResp("Paris, sir.")])
    let runner = CommandRunner(confirmer: Yes(), logURL: tmp("c.log"))
    let brain = Brain(transport: t, runner: runner, usage: usage, memory: Memory(url: tmp("m.md")), apiKey: { "k" })
    let r = try? await brain.respond(to: "capital of France?")
    expectEqual(r, "Paris, sir.")
    expectEqual(t.requests[0]["model"] as? String, "claude-haiku-5-5")
    expect(t.requests[0]["fallbacks"] == nil, "haiku has no fallbacks")
    expect(t.headers[0]["anthropic-beta"] == nil)
    expectEqual(usage.records().count, 1)
    expectEqual(brain.conversation.exchanges.count, 1)
    // second request includes history
    t.responses = [textResp("Berlin.")]
    _ = try? await brain.respond(to: "and Germany?")
    expectEqual((t.requests[1]["messages"] as? [[String: Any]])?.count, 3)

    // Tool loop: run_command succeeds, result goes back, final text returned; sonnet gets fallbacks
    let t2 = StubTransport([
        (200, ["content": [["type": "tool_use", "id": "t1", "name": "run_command", "input": ["command": "echo hello"]]], "stop_reason": "tool_use", "model": "claude-sonnet-5-5", "usage": ["input_tokens": 10, "output_tokens": 5]]),
        textResp("Done, sir.", model: "claude-sonnet-5-5"),
    ])
    let b2 = Brain(transport: t2, runner: runner, usage: usage, memory: Memory(url: tmp("m.md")), apiKey: { "k" })
    let r2 = try? await b2.respond(to: "run echo hello")
    expectEqual(r2, "Done, sir.")
    expectEqual(t2.requests[0]["model"] as? String, "claude-sonnet-5-5")
    expectEqual(t2.requests[0]["fallbacks"] as? String, "default")
    expectEqual(t2.headers[0]["anthropic-beta"], "server-side-fallback-2026-07-01")
    let msgs = t2.requests[1]["messages"] as? [[String: Any]] ?? []
    let results = msgs.last?["content"] as? [[String: Any]]
    expect((results?.first?["content"] as? String)?.contains("hello") == true, "tool result carries output")
    expectEqual(b2.conversation.exchanges.count, 1)

    // Declined risky command is reported, not run
    let marker = NSTemporaryDirectory() + "jarvis-marker-\(UUID().uuidString)"
    let no = CommandRunner(confirmer: Yes(answer: false), logURL: tmp("c.log"))
    let d = await no.run("rm -f \(marker)")
    expect(d.declined)
    let ok = await no.run("echo hi")
    expectEqual(ok.exitCode, 0); expect(ok.output.contains("hi"))

    // Retry cap: 3 failures, then it refuses to run more
    let rr = CommandRunner(confirmer: Yes(), logURL: tmp("c.log"))
    rr.beginRequest()
    for _ in 0..<3 { let f = await rr.run("false"); expectEqual(f.exitCode, 1) }
    let capped = await rr.run("echo should-not-run")
    expect(capped.output.contains("Retry limit"), capped.output)
    rr.beginRequest()
    let again = await rr.run("echo fine")
    expect(again.output.contains("fine"))

    // Secrets stripped from command output
    let s = await rr.run("echo 'API_KEY=sk-ant-api03-abcdefghijklmnop'")
    expect(!s.output.contains("sk-ant"), s.output)

    // Fallback rejection retries without the beta; 429 retries
    let t3 = StubTransport([(400, ["error": ["message": "unknown field: fallbacks"]]), textResp("fine", model: "claude-opus-5-5")])
    let b3 = Brain(transport: t3, runner: runner, usage: usage, memory: Memory(url: tmp("m.md")), apiKey: { "k" })
    b3.mode = .opus
    expectEqual(try? await b3.respond(to: "hi"), "fine")
    expect(t3.requests[1]["fallbacks"] == nil)

    // No key, API error, cap forces Haiku
    let b4 = Brain(transport: t3, runner: runner, usage: usage, memory: Memory(url: tmp("m.md")), apiKey: { nil })
    do { _ = try await b4.respond(to: "hi"); expect(false, "should throw") } catch { expectEqual(error as? BrainError, .noKey) }
    let t5 = StubTransport([(401, ["error": ["message": "bad key"]])])
    let b5 = Brain(transport: t5, runner: runner, usage: usage, memory: Memory(url: tmp("m.md")), apiKey: { "k" })
    do { _ = try await b5.respond(to: "hi"); expect(false) } catch { expectEqual(error as? BrainError, .api(401, "bad key")) }

    // Learning
    let mem = Memory(url: tmp("m.md"))
    let t6 = StubTransport([textResp("Pong."), textResp("[\"Owns a MacBook Air.\"]")])
    let b6 = Brain(transport: t6, runner: runner, usage: usage, memory: mem, apiKey: { "k" })
    _ = try? await b6.respond(to: "I love my MacBook Air")
    let learned = await b6.learn()
    expectEqual(learned, ["Owns a MacBook Air."])
    expect(mem.text().contains("MacBook"))
    expectEqual(t6.requests[1]["model"] as? String, "claude-haiku-5-5")
}
