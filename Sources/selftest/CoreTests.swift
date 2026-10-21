import Foundation
@testable import MycroftCore

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
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("mycroft-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d.appendingPathComponent(name)
}

func textResp(_ t: String, model: String = "claude-haiku-5-5", usage: [String: Any] = ["input_tokens": 1000, "output_tokens": 100]) -> (Int, [String: Any]) {
    (200, ["content": [["type": "text", "text": t]], "stop_reason": "end_turn", "model": model, "usage": usage])
}

func runCoreTests() {
    runRouterTests(); runIntentTests(); runUsageTests(); runMemoryTests(); runBatteryTests(); runAudioTests(); runBatteryPolicyTests(); runNotesTests()
    let sem = DispatchSemaphore(value: 0)
    Task { await runBrainTests(); sem.signal() }
    sem.wait()
}

func runNotesTests() {
    let (r, f) = (Notes.rs, Notes.fs)
    let raw = "300\(f)old\(r)5\(f)newest\nline two\(r)60\(f)middle\(r)junk\(r)"
    expectEqual(Notes.newest(raw, 2), "newest\nline two\n---\nmiddle\n---\n")
    expectEqual(Notes.newest(raw, 9), "newest\nline two\n---\nmiddle\n---\nold\n---\n")
    expectEqual(Notes.newest("", 5), "")
}

func runRouterTests() {
    expectEqual(Router.model(for: "what's the capital of France", mode: .auto, capReached: false), .sonnet)   // Sonnet is the default
    expectEqual(Router.model(for: "open Safari", mode: .auto, capReached: false), .sonnet)
    expectEqual(Router.model(for: "what's on my screen", mode: .auto, capReached: false), .sonnet)
    expectEqual(Router.model(for: "think deeply about whether to move to Berlin", mode: .auto, capReached: false), .opus)
    expectEqual(Router.model(for: "open Safari", mode: .haiku, capReached: false), .haiku)
    expectEqual(Router.model(for: "hello", mode: .opus, capReached: false), .opus)
    expectEqual(Router.model(for: "think deeply", mode: .opus, capReached: true), .haiku)
}

func runIntentTests() {
    expectEqual(Intent.parse("Mycroft, mute."), .mute)
    expectEqual(Intent.parse("Mycroft, mute."), .mute)
    expectEqual(Intent.parse("mycroft stop"), .stop)
    expectEqual(Intent.parse("stop"), .stop)
    expectEqual(Intent.parse("Mycroft, use Opus"), .setMode(.opus))
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
    // cache writes bill at 1.25x input, reads at the cache-read price
    expect(abs(UsageTracker.cost(model: .sonnet, input: 0, output: 0, cacheRead: 1_000_000, cacheWrite: 1_000_000, searches: 0) - (2.5 + 0.2)) < 1e-9)
    let cu = UsageTracker(url: tmp("cu.jsonl"))
    let rec = cu.record(model: .sonnet, usage: ["input_tokens": 100, "output_tokens": 0, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 1_000_000])
    expect(abs(rec.cost - (100 * 2.0 / 1e6 + 2.5)) < 1e-9, "cache write counted: \(rec.cost)")
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
    expectEqual(t.requests[0]["model"] as? String, "claude-sonnet-5-5")
    expectEqual(usage.records().count, 1)
    expectEqual(brain.conversation.exchanges.count, 1)
    // second request includes history
    t.responses = [textResp("Berlin.")]
    _ = try? await brain.respond(to: "and Germany?")
    expectEqual((t.requests[1]["messages"] as? [[String: Any]])?.count, 4)   // history (2), question, time note

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

    // History keeps the commands Mycroft ran, so the next turn can see the earlier action really happened
    t2.responses = [textResp("Still done, sir.", model: "claude-sonnet-5-5")]
    _ = try? await b2.respond(to: "did you do it?")
    let hist = t2.requests.last?["messages"] as? [[String: Any]] ?? []
    expectEqual(hist.map { $0["role"] as? String ?? "" }, ["user", "assistant", "user", "assistant", "user", "system"], "user, tool call, result, reply, new question, time note")
    if hist.count == 5 {
        let call = (hist[1]["content"] as? [[String: Any]])?.first
        expectEqual(call?["type"] as? String, "tool_use")
        expectEqual((call?["input"] as? [String: Any])?["command"] as? String, "echo hello")
        let res = (hist[2]["content"] as? [[String: Any]])?.first
        expectEqual(res?["tool_use_id"] as? String, call?["id"] as? String)
        expect((res?["content"] as? String)?.contains("hello") == true, "result kept in history")
        expectEqual(hist[3]["content"] as? String, "Done, sir.")
    }

    // The system prompt is fixed for a whole request: thinking blocks from earlier tool rounds are bound to it,
    // and the API rejects them (400) if it changes, e.g. when the minute in the timestamp ticks over mid-request.
    let t7 = StubTransport([
        (200, ["content": [["type": "tool_use", "id": "t1", "name": "run_command", "input": ["command": "echo one"]]], "stop_reason": "tool_use", "model": "claude-sonnet-5-5", "usage": ["input_tokens": 10, "output_tokens": 5]]),
        (200, ["content": [["type": "tool_use", "id": "t2", "name": "run_command", "input": ["command": "echo two"]]], "stop_reason": "tool_use", "model": "claude-sonnet-5-5", "usage": ["input_tokens": 10, "output_tokens": 5]]),
        textResp("Done, sir.", model: "claude-sonnet-5-5"),
    ])
    let b7 = Brain(transport: t7, runner: runner, usage: usage, memory: Memory(url: tmp("m.md")), apiKey: { "k" })
    var tick = Date(timeIntervalSince1970: 1_800_000_000)
    b7.clock = { tick = tick.addingTimeInterval(90); return tick }
    b7.mode = .sonnet
    _ = try? await b7.respond(to: "do two things")
    expectEqual(t7.requests.count, 3)
    let systems = t7.requests.map { (($0["system"] as? [[String: Any]])?.first?["text"] as? String) ?? "" }
    expect(Set(systems).count == 1, "same system prompt in every round of one request")

    // Prompt caching: tools and system are cached, the clock lives in a role:system message after the question
    let r0 = t7.requests[0]
    expect(r0["cache_control"] != nil, "automatic caching for the conversation")
    let sys = (r0["system"] as? [[String: Any]])?.first
    expect(sys?["cache_control"] != nil, "system block cached")
    expect((sys?["text"] as? String)?.contains("Current date") == false, "no clock in the cached system prompt")
    expect((r0["tools"] as? [[String: Any]])?.last?["cache_control"] != nil, "tools cached")
    let m0 = r0["messages"] as? [[String: Any]] ?? []
    expectEqual(m0.map { $0["role"] as? String ?? "" }, ["user", "system"], "question, then the time note")
    expect((m0.last?["content"] as? String)?.contains("Current date and time") == true)
    let m2 = t7.requests[2]["messages"] as? [[String: Any]] ?? []
    expectEqual(m2.map { $0["role"] as? String ?? "" }, ["user", "system", "assistant", "user", "assistant", "user"], "time note stays put through the tool loop")

    // Declined risky command is reported, not run
    let marker = NSTemporaryDirectory() + "mycroft-marker-\(UUID().uuidString)"
    let no = CommandRunner(confirmer: Yes(answer: false), logURL: tmp("c.log"))
    let d = await no.run("rm -f \(marker)")
    expect(d.declined)
    let ok = await no.run("echo hi")
    expectEqual(ok.exitCode, 0); expect(ok.output.contains("hi"))
    // A silent success (osascript "play") must read as success, not as "nothing happened"
    let quiet = await no.run("true")
    expect(quiet.output.contains("success"), quiet.output)
    let quietFail = await no.run("false")
    expect(!quietFail.output.contains("success"), quietFail.output)

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

func runAudioTests() {
    func drive(_ d: inout EndpointDetector, rms: Float, ms: Int) -> EndpointDetector.Event {
        var e = EndpointDetector.Event.waiting
        for _ in 0..<(ms / EndpointDetector.frameMs) { e = d.feed(rms: rms); if case .done = e { return e } }
        return e
    }
    // silence only -> times out with no speech
    var d = EndpointDetector(startTimeout: 3)
    expectEqual(drive(&d, rms: 0.004, ms: 3500), .done(hadSpeech: false))
    // quiet room, speech, then silence -> ends after ~0.75s of silence
    d = EndpointDetector(startTimeout: 5)
    expectEqual(drive(&d, rms: 0.004, ms: 500), .waiting)
    expectEqual(drive(&d, rms: 0.08, ms: 1000), .speaking)
    expectEqual(drive(&d, rms: 0.004, ms: 600), .speaking)
    expectEqual(drive(&d, rms: 0.004, ms: 400), .done(hadSpeech: true))
    // a short click is not speech
    d = EndpointDetector(startTimeout: 2)
    _ = drive(&d, rms: 0.004, ms: 400)
    expectEqual(drive(&d, rms: 0.2, ms: 60), .waiting)
    expectEqual(drive(&d, rms: 0.004, ms: 2000), .done(hadSpeech: false))
    // pauses shorter than the end-silence do not cut the sentence
    d = EndpointDetector(startTimeout: 5)
    _ = drive(&d, rms: 0.004, ms: 400); _ = drive(&d, rms: 0.08, ms: 600)
    expectEqual(drive(&d, rms: 0.004, ms: 500), .speaking)
    expectEqual(drive(&d, rms: 0.08, ms: 400), .speaking)
    // noisy room raises the threshold
    d = EndpointDetector(startTimeout: 5)
    _ = drive(&d, rms: 0.018, ms: 400)
    expect(d.threshold > 0.05, "threshold \(d.threshold)")
    // max duration: 40 s of talking is allowed, then it ends
    d = EndpointDetector(startTimeout: 5)
    _ = drive(&d, rms: 0.004, ms: 400)
    expectEqual(drive(&d, rms: 0.1, ms: 35000), .speaking)
    expectEqual(drive(&d, rms: 0.1, ms: 6000), .done(hadSpeech: true))

    let wav = WAV.encode([0, 0.5, -0.5, 1.0])
    expectEqual(wav.count, 44 + 8)
    expectEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
    expectEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")

    expectEqual(Speech.clean("[BLANK_AUDIO]"), "")
    expectEqual(Speech.clean(" (silence) "), "")
    expectEqual(Speech.clean("Open Safari [click]"), "Open Safari")
    expectEqual(Speech.clean("What time is it?"), "What time is it?")
    expect(Speech.yesNo("Yes, go ahead") == .yes); expect(Speech.yesNo("No don't") == .no)
    expect(Speech.yesNo("hmm what") == .unclear); expect(Speech.yesNo("Yeah sure") == .yes)
    expect(Speech.keepOrDelete("delete that") == false); expect(Speech.keepOrDelete("keep") == true)
    expect(Speech.keepOrDelete("what") == nil)
}

// MARK: ML pipelines (wake word, voiceprint) — need the models in ~/Library/Application Support/Mycroft/models

func synth(_ text: String, voice: String, rate: Int = 175) -> [Float] {
    let aiff = NSTemporaryDirectory() + "st-\(UUID().uuidString).aiff", wav = aiff + ".wav"
    _ = shell("/usr/bin/say", ["-v", voice, "-r", "\(rate)", "-o", aiff, text])
    _ = shell("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, wav])
    defer { try? FileManager.default.removeItem(atPath: aiff); try? FileManager.default.removeItem(atPath: wav) }
    return WAV.decode((try? Data(contentsOf: URL(fileURLWithPath: wav))) ?? Data())
}
@discardableResult func shell(_ exe: String, _ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try? p.run(); let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(decoding: d, as: UTF8.self)
}

func wakeScore(_ det: WakeWordDetector, _ audio: [Float]) -> Float {
    det.reset()
    let silence = [Float](repeating: 0, count: 16000)
    var maxScore: Float = 0
    for chunkStart in stride(from: 0, to: silence.count + audio.count + silence.count, by: 1280) {
        let all = silence + audio + silence
        let end = min(all.count, chunkStart + 1280)
        _ = det.feed(Array(all[chunkStart..<end]))
        maxScore = max(maxScore, det.lastScore)
    }
    return maxScore
}

func runMLTests() {
    guard Models.wakeWordAvailable, Models.speakerAvailable else { print("SKIP ML tests: models missing"); return }
    do {
        let det = try WakeWordDetector()
        for v in ["Daniel", "Samantha", "Alex", "Karen"] {
            let s = wakeScore(det, synth(Models.wakePhrase, voice: v))
            expect(s > 0.8, "wake word '\(v)' scored \(s)")
        }
        for phrase in ["Hello there, how are you", "Turn on the lights please", "What time is it", "I use Microsoft Word at work", "Hey, my friend"] {
            let s = wakeScore(det, synth(phrase, voice: "Daniel"))
            expect(s < 0.1, "'\(phrase)' scored \(s)")
        }
        expect(wakeScore(det, [Float](repeating: 0, count: 32000)) < 0.1, "silence")
        // fires exactly once through feed() and respects the cooldown
        det.reset()
        var fires = 0
        let all = [Float](repeating: 0, count: 16000) + synth(Models.wakePhrase, voice: "Daniel") + [Float](repeating: 0, count: 16000)
        for i in stride(from: 0, to: all.count, by: 1280) { if det.feed(Array(all[i..<min(all.count, i + 1280)])) { fires += 1 } }
        expectEqual(fires, 1, "wake fires once")
    } catch { expect(false, "wake word: \(error)") }
}

func runVoiceprintProbe() {
    guard Models.speakerAvailable else { return }
    do {
        let vp = try Voiceprint(threshold: 0.6)
        let text1 = "The quick brown fox jumps over the lazy dog while the sun sets slowly behind the mountains in the distance."
        let text2 = "Please remind me to call my sister tomorrow morning, and tell me what the weather will be like this weekend."
        var embs: [String: [[Float]]] = [:]
        for v in ["Daniel", "Samantha", "Alex", "Karen", "Fred"] {
            embs[v] = [try vp.embedding(synth(text1, voice: v)), try vp.embedding(synth(text2, voice: v))]
        }
        for v in embs.keys.sorted() {
            expect(Cosine.similarity(embs[v]![0], embs[v]![1]) > 0.8, "same voice \(v)")
        }
        let names = embs.keys.sorted()
        for i in 0..<names.count { for j in (i + 1)..<names.count {
            let sim = Cosine.similarity(embs[names[i]]![0], embs[names[j]]![1])
            if ![names[i], names[j]].contains("Alex") || ![names[i], names[j]].contains("Samantha") { // Alex voice is not installed here: it falls back to Samantha
                if ![names[i], names[j]].contains("Karen") || ![names[i], names[j]].contains("Samantha") && ![names[i], names[j]].contains("Alex") { expect(sim < 0.6, "\(names[i]) vs \(names[j]) = \(sim)") }
            }
        } }
        let fast = try vp.embedding(synth(text2, voice: "Daniel", rate: 230))
        expect(Cosine.similarity(embs["Daniel"]![0], fast) > 0.8, "speed change")
        // enrol Daniel, then verify: Daniel passes, Fred and Karen are rejected
        // never touch the real voiceprint.json
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vp-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let tmpVP = try Voiceprint(threshold: 0.6, url: file)
        try tmpVP.enrol(samples: synth(text1 + " " + text2 + " " + text1, voice: "Daniel"), mic: "Built-in")
        expect(tmpVP.isOwner(synth("Open Safari and play some music please", voice: "Daniel")), "owner accepted")
        expect(!tmpVP.isOwner(synth("Open Safari and play some music please", voice: "Fred")), "Fred rejected")
        expect(!tmpVP.isOwner(synth("Open Safari and play some music please", voice: "Karen")), "Karen rejected")
        // a second mic adds a voiceprint instead of replacing the first; re-enrolling a mic replaces only that one
        try tmpVP.enrol(samples: synth(text2 + " " + text1 + " " + text2, voice: "Samantha"), mic: "Headset")
        try tmpVP.enrol(samples: synth(text2 + " " + text1 + " " + text2, voice: "Samantha"), mic: "Headset")
        let reloaded = try Voiceprint(url: file)
        expectEqual(reloaded.enrolledMics, ["Built-in", "Headset"], "one voiceprint per mic, persisted")
        expect(reloaded.isOwner(synth("Open Safari and play some music please", voice: "Daniel")), "first mic still accepted")
        expect(reloaded.isOwner(synth("Open Safari and play some music please", voice: "Samantha")), "second mic accepted")
        expect(!reloaded.isOwner(synth("Open Safari and play some music please", voice: "Fred")), "Fred still rejected")
    } catch { print("probe error: \(error)") }
}

func runBatteryPolicyTests() {
    var p = BatteryPolicy()
    expectEqual(p.update(.init(percent: 50, charging: false)), .none)
    expectEqual(p.update(.init(percent: 19, charging: false)), .pause(announce: true))
    expectEqual(p.update(.init(percent: 18, charging: false)), .none, "announce once")
    expectEqual(p.update(.init(percent: 18, charging: true)), .resume)
    expectEqual(p.update(.init(percent: 15, charging: true)), .none, "charging never pauses")
    expectEqual(p.update(.init(percent: 15, charging: false)), .pause(announce: true), "re-announces after a charge")
}
