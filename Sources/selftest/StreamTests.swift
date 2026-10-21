import Foundation
@testable import JarvisCore

func runLinesTests() {
    let cal = Calendar(identifier: .gregorian)
    func at(_ h: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: h, minute: 5))! }
    var p = LinePicker()
    for h in [0, 7, 11] { expectEqual(p.opening(at: at(h), calendar: cal), Lines.morning, "before noon: \(h)") }
    for h in [12, 15, 20, 23] {
        let l = p.opening(at: at(h), calendar: cal)
        expect(l.hasPrefix("Systems online."), l)
        expect(!l.contains("Good morning"), l)
    }
    expect(!Lines.startup(hour: 20).contains(Lines.afternoonOnly), "no good afternoon in the evening")
    expect(Lines.startup(hour: 14).contains(Lines.afternoonOnly))
    var last = ""
    for _ in 0..<50 { let e = p.error(); expect(e != last, "never the same line twice in a row"); last = e }
    for _ in 0..<10 { expect(Lines.shutdown.contains(p.shutdown())) }
    // The morning line belongs to the app, not the model
    expect(!Prompts.persona.contains("colonize"))
    expect(Prompts.persona.contains("blame the French"))
}

func runSplitterTests() {
    var s = SentenceSplitter()
    expectEqual(s.add("Right away, sir. It is 3.5 deg"), ["Right away, sir."])
    expectEqual(s.add("rees in Konya"), [])
    expectEqual(s.add(". Rather warm! Shall I"), ["It is 3.5 degrees in Konya.", "Rather warm!"])
    expectEqual(s.flush(), "Shall I")
    expectEqual(s.flush(), nil)
    // very short fragments wait for the next sentence
    var t = SentenceSplitter()
    expectEqual(t.add("Yes. Done, sir, and quite right too. "), ["Yes. Done, sir, and quite right too."])
}

func runAssemblerTests() throws {
    var spoken = "", tools: [String] = []
    var a = StreamAssembler()
    a.onText = { spoken += $0 }; a.onToolStart = { tools.append($0) }
    let events: [[String: Any]] = [
        ["type": "message_start", "message": ["model": "claude-sonnet-5-5", "usage": ["input_tokens": 50, "cache_read_input_tokens": 40]]],
        ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": ""]],
        ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "hm"]],
        ["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": "SIG"]],
        ["type": "content_block_stop", "index": 0],
        ["type": "content_block_start", "index": 1, "content_block": ["type": "text", "text": ""]],
        ["type": "content_block_delta", "index": 1, "delta": ["type": "text_delta", "text": "Opening "]],
        ["type": "content_block_delta", "index": 1, "delta": ["type": "text_delta", "text": "Safari."]],
        ["type": "content_block_stop", "index": 1],
        ["type": "content_block_start", "index": 2, "content_block": ["type": "tool_use", "id": "t1", "name": "run_command", "input": [:] as [String: Any]]],
        ["type": "content_block_delta", "index": 2, "delta": ["type": "input_json_delta", "partial_json": "{\"command\": \"open"]],
        ["type": "content_block_delta", "index": 2, "delta": ["type": "input_json_delta", "partial_json": " -a Safari\"}"]],
        ["type": "content_block_stop", "index": 2],
        ["type": "message_delta", "delta": ["stop_reason": "tool_use"], "usage": ["output_tokens": 30]],
        ["type": "message_stop"],
    ]
    for e in events { try a.handle(e) }
    let c = a.content
    expectEqual(c.count, 3)
    expectEqual(c[0]["signature"] as? String, "SIG")
    expectEqual(c[0]["thinking"] as? String, "hm")
    expectEqual(c[1]["text"] as? String, "Opening Safari.")
    expectEqual((c[2]["input"] as? [String: Any])?["command"] as? String, "open -a Safari")
    expectEqual(a.stopReason, "tool_use")
    expectEqual(a.usage["input_tokens"] as? Int, 50); expectEqual(a.usage["output_tokens"] as? Int, 30)
    expectEqual(spoken, "Opening Safari."); expectEqual(tools, ["run_command"])
    // A tool with no input keeps its empty input
    var b = StreamAssembler()
    try b.handle(["type": "content_block_start", "index": 0, "content_block": ["type": "tool_use", "id": "t", "name": "look_at_screen", "input": [:] as [String: Any]]])
    try b.handle(["type": "content_block_delta", "index": 0, "delta": ["type": "input_json_delta", "partial_json": ""]])
    try b.handle(["type": "content_block_stop", "index": 0])
    expect((b.content.first?["input"] as? [String: Any])?.isEmpty == true)
    // Mid-stream error event throws
    var e = StreamAssembler()
    do { try e.handle(["type": "error", "error": ["type": "overloaded_error", "message": "Overloaded"]]); expect(false, "should throw") }
    catch { expectEqual(error as? BrainError, .api(529, "Overloaded")) }
    // After a mid-stream fallback, thinking and tool calls from before the marker are dropped; text is kept
    var f = StreamAssembler()
    for (i, blk) in [["type": "thinking", "thinking": "", "signature": "x"], ["type": "text", "text": "Partial."],
                     ["type": "fallback"], ["type": "text", "text": "Fine."]].enumerated() {
        try f.handle(["type": "content_block_start", "index": i, "content_block": blk])
    }
    expectEqual(f.content.map { $0["type"] as? String ?? "" }, ["text", "fallback", "text"])
}

func runLiveSpeechTests() async {
    let usage = UsageTracker(url: tmp("u.jsonl"))
    let runner = CommandRunner(confirmer: Yes(), logURL: tmp("c.log"))
    // Plain answer is spoken sentence by sentence, and returned whole
    let t = StubTransport([textResp("Paris, sir. Rather a long way from the Empire, these days.")])
    let brain = Brain(transport: t, runner: runner, usage: usage, memory: Memory(url: tmp("m.md")), apiKey: { "k" })
    var said: [String] = []
    let r = try? await brain.respond(to: "capital of France?", speech: LiveSpeech { said.append($0) })
    expectEqual(r, "Paris, sir. Rather a long way from the Empire, these days.")
    expectEqual(said, ["Paris, sir.", "Rather a long way from the Empire, these days."])
    expectEqual((t.requests[0]["output_config"] as? [String: Any])?["effort"] as? String, "low")
    // A tool call with nothing said first gets a holding line; the answer follows
    let t2 = StubTransport([
        (200, ["content": [["type": "tool_use", "id": "t1", "name": "run_command", "input": ["command": "echo hi"]]], "stop_reason": "tool_use", "model": "claude-sonnet-5-5", "usage": ["input_tokens": 10, "output_tokens": 5]]),
        textResp("Done, sir.", model: "claude-sonnet-5-5"),
    ])
    let b2 = Brain(transport: t2, runner: runner, usage: usage, memory: Memory(url: tmp("m.md")), apiKey: { "k" })
    said = []
    _ = try? await b2.respond(to: "say hi in the shell", speech: LiveSpeech { said.append($0) })
    expectEqual(said.count, 2, "\(said)")
    expect(Lines.working.contains(said.first ?? ""), "\(said)")
    expectEqual(said.last, "Done, sir.")
    expectEqual(((t2.requests[1]["messages"] as? [[String: Any]])?[2]["content"] as? [[String: Any]])?.first?["type"] as? String, "tool_use", "streamed tool call sent back")
    // Think hard -> high effort
    let t3 = StubTransport([textResp("Hmm.")])
    let b3 = Brain(transport: t3, runner: runner, usage: usage, memory: Memory(url: tmp("m.md")), apiKey: { "k" })
    _ = try? await b3.respond(to: "think hard about tea", speech: LiveSpeech { _ in })
    expectEqual((t3.requests[0]["output_config"] as? [String: Any])?["effort"] as? String, "high")
}

func runOfflineTests() async {
    expectEqual(OfflineAction.parse("What time is it?"), .time)
    expectEqual(OfflineAction.parse("Mycroft, what's the time"), .time)
    expectEqual(OfflineAction.parse("What day is it today?"), .date)
    expectEqual(OfflineAction.parse("How's my battery?"), .battery)
    expectEqual(OfflineAction.parse("Turn the volume up"), .volumeUp)
    expectEqual(OfflineAction.parse("Make it quieter, volume down please"), .volumeDown)
    expectEqual(OfflineAction.parse("Set the volume to 30 percent."), .volumeSet(30))
    expectEqual(OfflineAction.parse("Open Safari."), .open("Safari"))
    expectEqual(OfflineAction.parse("please launch system settings"), .open("System Settings"))
    expectEqual(OfflineAction.parse("Make a note that I need to buy Milk."), .note("I need to buy Milk"))
    expectEqual(OfflineAction.parse("Note that the boiler man comes Tuesday"), .note("the boiler man comes Tuesday"))
    expectEqual(OfflineAction.parse("Who won the Champions League?"), nil)
    expectEqual(OfflineAction.parse("What's the weather in Konya?"), nil)
    let cal = Calendar(identifier: .gregorian)
    let d = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 14, minute: 5))!
    let time = await OfflineAction.time.perform(now: d)
    expect(time.hasPrefix("It's 2:05") && time.hasSuffix("sir."), time)
    expectEqual(await OfflineAction.date.perform(now: d), "It's Wednesday 21 October, sir.")
    expectEqual(await OfflineAction.open("Definitely Not An App 123").perform(), "I can't find an app called Definitely Not An App 123, sir.")
    expectEqual(Lines.offline.count, 5)
    var p = LinePicker(); var last = ""
    for _ in 0..<20 { let l = p.offline(); expect(l != last); last = l }
}

func runVoiceTests() {
    let list = """
    Daniel (English (UK)) en_GB    # Hello! My name is Daniel.
    Grandpa (English (UK)) en_GB    # Hello! My name is Grandpa.
    Jamie (Premium)     en_GB    # Hello! My name is Jamie.
    Samantha (Enhanced) en_US    # Hello! My name is Samantha.
    """
    let v = Speaker.voices(list)
    expectEqual(v.count, 4)
    expectEqual(v[2].name, "Jamie (Premium)"); expectEqual(v[2].locale, "en_GB")
    expectEqual(Speaker.pickVoice(installed: v, chosen: nil), "Jamie (Premium)")
    expectEqual(Speaker.pickVoice(installed: v, chosen: "Grandpa (English (UK))"), "Grandpa (English (UK))")
    expectEqual(Speaker.pickVoice(installed: v, chosen: "Not Installed"), "Jamie (Premium)")
    expectEqual(Speaker.pickVoice(installed: Array(v.prefix(2)), chosen: nil), "Daniel (English (UK))")
}
