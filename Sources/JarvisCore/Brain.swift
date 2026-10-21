import Foundation

public protocol Transport {
    func send(_ body: [String: Any], headers: [String: String]) async throws -> (status: Int, data: Data)
    /// With status 200, hands each server-sent event to `onEvent`; otherwise returns the error body.
    func stream(_ body: [String: Any], headers: [String: String], onEvent: ([String: Any]) throws -> Void) async throws -> (status: Int, data: Data)
}

public extension Transport {
    /// Fallback for transports that can't stream: one request, replayed as events.
    func stream(_ body: [String: Any], headers: [String: String], onEvent: ([String: Any]) throws -> Void) async throws -> (status: Int, data: Data) {
        let (status, data) = try await send(body, headers: headers)
        guard status == 200 else { return (status, data) }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        for e in StreamAssembler.events(for: json) { try onEvent(e) }
        return (status, Data())
    }
}

public struct URLSessionTransport: Transport {
    public init() {}
    func request(_ body: [String: Any], headers: [String: String]) throws -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }
    public func send(_ body: [String: Any], headers: [String: String]) async throws -> (status: Int, data: Data) {
        let (d, r) = try await URLSession.shared.data(for: try request(body, headers: headers))
        return ((r as? HTTPURLResponse)?.statusCode ?? 0, d)
    }
    public func stream(_ body: [String: Any], headers: [String: String], onEvent: ([String: Any]) throws -> Void) async throws -> (status: Int, data: Data) {
        var body = body; body["stream"] = true
        let (bytes, r) = try await URLSession.shared.bytes(for: try request(body, headers: headers))
        let status = (r as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var d = Data(); for try await b in bytes { d.append(b) }
            return (status, d)
        }
        for try await line in bytes.lines where line.hasPrefix("data:") {
            if let e = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any] { try onEvent(e) }
        }
        return (status, Data())
    }
}

/// Speaks a reply while it streams in: whole sentences as they complete, plus a short line before a slow tool.
public final class LiveSpeech {
    let say: (String) -> Void
    var splitter = SentenceSplitter()
    public private(set) var spokeAnything = false
    public init(_ say: @escaping (String) -> Void) { self.say = say }

    func text(_ t: String) { for s in splitter.add(t) { speak(s) } }
    func flush() { if let s = splitter.flush() { speak(s) } }
    func speak(_ s: String) { spokeAnything = true; say(s) }
    /// Before the first tool call of a request, if nothing has been said yet, say something.
    func toolStarting(_ name: String) {
        flush()
        // Server tools (web search, and the code it runs to filter results) are lookups; the rest act on the Mac.
        let onMac = ["run_command", "notes", "look_at_screen"].contains(name)
        if !spokeAnything { speak((onMac ? Lines.working : Lines.searching).randomElement()!) }
    }
}

public enum BrainError: Error, Equatable {
    case noKey
    case offline
    case api(Int, String)
}

public final class Brain {
    public var mode: Mode = .auto
    public private(set) var lastModel: Model?
    public let usage: UsageTracker
    public let memory: Memory
    public let conversation: Conversation
    let transport: Transport
    let runner: CommandRunner
    let apiKey: () -> String?
    var useFallbacks = true
    /// When set, every exchange (what was heard, what Jarvis said) is appended here. Off in tests.
    public var conversationLog: URL?
    /// Current time for the system prompt (replaceable in tests).
    var clock: () -> Date = Date.init
    public static let maxToolRounds = 8

    public init(transport: Transport = URLSessionTransport(), runner: CommandRunner, usage: UsageTracker = UsageTracker(),
                memory: Memory = Memory(), conversation: Conversation = Conversation(), apiKey: @escaping () -> String? = Keychain.apiKey) {
        self.transport = transport; self.runner = runner; self.usage = usage; self.memory = memory
        self.conversation = conversation; self.apiKey = apiKey
    }

    // MARK: Public API

    /// One spoken exchange: the user's words in, Jarvis's reply out. Updates short-term context.
    public func respond(to text: String, speech: LiveSpeech? = nil) async throws -> String {
        conversation.expireIfIdle()
        runner.beginRequest()
        let model = Router.model(for: text, mode: mode, capReached: usage.capReached())
        var actions: [Conversation.Action] = []
        let reply = try await run(messages: conversation.messages() + [["role": "user", "content": text]], model: model,
                                  deep: Router.deepThinking.contains(where: text.lowercased().contains), actions: &actions, speech: speech)
        conversation.add(user: text, assistant: reply, actions: actions)
        logExchange(heard: text, reply: reply)
        return reply
    }

    /// A self-contained request (morning greeting): does not touch the conversation.
    public func oneShot(_ prompt: String, model: Model = .haiku, speech: LiveSpeech? = nil) async throws -> String {
        runner.beginRequest()
        var ignored: [Conversation.Action] = []
        return try await run(messages: [["role": "user", "content": prompt]], model: usage.capReached() ? .haiku : model, deep: false, actions: &ignored, speech: speech)
    }

    /// After a conversation, extract lasting facts with Haiku and append them to memory.
    @discardableResult
    public func learn() async -> [String] {
        let transcript = conversation.transcript
        guard !transcript.isEmpty else { return [] }
        let known = memory.lines().map(Memory.fact(of:)).joined(separator: "\n")
        let body: [String: Any] = [
            "model": Model.haiku.rawValue, "max_tokens": 600,
            "system": Prompts.memoryExtract,
            "output_config": ["effort": "low"],
            "messages": [["role": "user", "content": "Known facts:\n\(known.isEmpty ? "(none)" : known)\n\nConversation:\n\(transcript)"]],
        ]
        guard let resp = try? await call(body, model: .haiku) else { return [] }
        return memory.append(Self.parseFacts(Self.text(of: resp.content)))
    }

    public static func parseFacts(_ s: String) -> [String] {
        guard let a = s.firstIndex(of: "["), let b = s.lastIndex(of: "]"), a < b,
              let arr = try? JSONSerialization.jsonObject(with: Data(s[a...b].utf8)) as? [Any] else { return [] }
        return arr.compactMap { $0 as? String }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    func logExchange(heard: String, reply: String) {
        guard let url = conversationLog else { return }
        let t = ISO8601DateFormatter().string(from: Date())
        let line = "\(t)\tYou: \(heard)\n\(t)\tJarvis [\(lastModel?.label ?? "?")]: \(reply.replacingOccurrences(of: "\n", with: " "))\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }

    // MARK: Tool loop

    struct Response { var content: [[String: Any]]; var stopReason: String; var model: Model }

    /// Runs the tool loop. Every client tool call is appended to `actions` (result shortened) for the history.
    /// With `speech`, the reply streams and is spoken as it arrives; everything returned has been spoken.
    func run(messages initial: [[String: Any]], model: Model, deep: Bool, actions: inout [Conversation.Action], speech: LiveSpeech? = nil) async throws -> String {
        // The clock rides in a role:system message after the owner's words, so the cached system prompt and
        // tools stay byte-identical. Built once per request: thinking blocks from earlier tool rounds are
        // bound to the conversation as sent.
        var msgs = initial + [["role": "system", "content": Prompts.timeNote(clock())]]
        lastModel = model
        let system = Prompts.system(memory: memory.text())
        for _ in 0..<Self.maxToolRounds {
            let body = requestBody(model: model, system: system, messages: msgs, deep: deep)
            let resp = try await call(body, model: model, speech: speech)
            msgs.append(["role": "assistant", "content": resp.content])
            switch resp.stopReason {
            case "tool_use":
                var results: [[String: Any]] = []
                for b in resp.content where b["type"] as? String == "tool_use" {
                    let r = await execute(b)
                    results.append(r)
                    actions.append(Self.action(b, r))
                }
                msgs.append(["role": "user", "content": results])
            case "pause_turn":
                continue
            case "refusal":
                return Self.spoken("I'm afraid I can't help with that one, sir.", speech)
            default:
                speech?.flush()
                let t = Self.text(of: resp.content)
                return t.isEmpty ? Self.spoken("Very good, sir.", speech) : t
            }
        }
        return Self.spoken("I seem to have got myself into a loop, sir. Shall we try that again?", speech)
    }

    static func spoken(_ line: String, _ speech: LiveSpeech?) -> String { speech?.speak(line); return line }

    func requestBody(model: Model, system: String, messages: [[String: Any]], deep: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 2048,
            // Breakpoints: end of tools (memory edits don't evict them), end of system, plus automatic
            // caching for the growing conversation.
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": messages,
            "tools": Self.cachedTools(for: model),
            "cache_control": ["type": "ephemeral"],
            // Low effort keeps spoken replies quick; "think hard" requests get high.
            "output_config": ["effort": deep ? "high" : "low"],
        ]
        if useFallbacks && model != .haiku { body["fallbacks"] = "default" }
        return body
    }

    static func cachedTools(for model: Model) -> [[String: Any]] {
        var t = tools(for: model)
        t[t.count - 1]["cache_control"] = ["type": "ephemeral"]
        return t
    }

    static func tools(for model: Model) -> [[String: Any]] {
        let search: [String: Any] = [
            // The basic search, not web_search_20260209: its result filtering roughly doubled spoken answer
            // times (weather 11s vs 6.5s, a sports result 16.6s vs 3.5s, measured 2026-10-21).
            "type": "web_search_20250305",
            "name": "web_search", "max_uses": 3,
            "user_location": ["type": "approximate", "city": "Konya", "country": "TR", "timezone": "Europe/Istanbul"],
        ]
        func schema(_ props: [String: Any], required: [String]) -> [String: Any] {
            ["type": "object", "properties": props, "required": required, "additionalProperties": false]
        }
        return [
            search,
            ["name": "run_command",
             "description": "Run a zsh command on the owner's Mac (cwd is the home folder) and return its output. Handles files, apps (open -a), and system settings or media via osascript.",
             "input_schema": schema(["command": ["type": "string", "description": "The zsh command line"]], required: ["command"])],
            ["name": "look_at_screen",
             "description": "Take a screenshot of the owner's screen. Only use when the owner asks about what is on their screen.",
             "input_schema": schema([:], required: [])],
            ["name": "notes",
             "description": "Save to or read from the 'Jarvis' folder in the Notes app.",
             "input_schema": schema(["action": ["type": "string", "enum": ["save", "search", "last", "recent"]],
                                     "text": ["type": "string", "description": "Note text for save, or search words for search"]], required: ["action"])],
        ]
    }

    /// What history keeps of a tool call: the call itself and a short text form of its result (no images).
    static func action(_ call: [String: Any], _ result: [String: Any]) -> Conversation.Action {
        var text: String
        if let s = result["content"] as? String { text = s }
        else if let blocks = result["content"] as? [[String: Any]] {
            text = blocks.compactMap { $0["type"] as? String == "image" ? "[screenshot taken]" : $0["text"] as? String }.joined(separator: " ")
        } else { text = "" }
        if text.count > 600 { text = String(text.prefix(600)) + " [shortened]" }
        return Conversation.Action(id: call["id"] as? String ?? "", name: call["name"] as? String ?? "",
                                   input: call["input"] as? [String: Any] ?? [:], result: text, isError: result["is_error"] as? Bool ?? false)
    }

    func execute(_ block: [String: Any]) async -> [String: Any] {
        let id = block["id"] as? String ?? ""
        let input = block["input"] as? [String: Any] ?? [:]
        var content: Any
        var isError = false
        switch block["name"] as? String {
        case "run_command":
            guard let cmd = input["command"] as? String, !cmd.isEmpty else { content = "Missing command."; isError = true; break }
            let r = await runner.run(cmd)
            content = r.output; isError = r.exitCode != 0
        case "look_at_screen":
            if let b64 = await Screen.capture() {
                content = [["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": b64]],
                           ["type": "text", "text": "Screenshot of the owner's screen."]]
            } else { content = "Could not capture the screen. Screen Recording permission may be missing."; isError = true }
        case "notes":
            let text = (input["text"] as? String) ?? ""
            switch input["action"] as? String {
            case "save": content = text.isEmpty ? "Nothing to save." : Notes.save(text)
            case "search": content = Notes.search(text)
            case "recent": content = Notes.recent(5)
            default: content = Notes.last()
            }
        default:
            content = "Unknown tool."; isError = true
        }
        var r: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": content]
        if isError { r["is_error"] = true }
        return r
    }

    // MARK: HTTP

    func call(_ body: [String: Any], model: Model, speech: LiveSpeech? = nil) async throws -> Response {
        guard let key = apiKey(), !key.isEmpty else { throw BrainError.noKey }
        var body = body
        for attempt in 0..<3 {
            var headers = ["x-api-key": key]
            if body["fallbacks"] != nil { headers["anthropic-beta"] = "server-side-fallback-2026-07-01" }
            let status: Int, data: Data
            var asm = StreamAssembler()
            if let speech {
                asm.onText = { speech.text($0) }
                asm.onToolStart = { speech.toolStarting($0) }
            }
            do {
                if speech != nil { (status, data) = try await transport.stream(body, headers: headers) { try asm.handle($0) } }
                else { (status, data) = try await transport.send(body, headers: headers) }
            }
            catch let e as URLError where Self.offlineCodes.contains(e.code) { throw BrainError.offline }
            if status == 200, speech != nil {
                let used = asm.model.flatMap(Self.model(named:)) ?? model
                usage.record(model: used, usage: asm.usage)
                return Response(content: asm.content, stopReason: asm.stopReason, model: used)
            }
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            if status == 200 {
                let used = (json["model"] as? String).flatMap(Self.model(named:)) ?? model
                if let u = json["usage"] as? [String: Any] { usage.record(model: used, usage: u) }
                return Response(content: json["content"] as? [[String: Any]] ?? [], stopReason: json["stop_reason"] as? String ?? "end_turn", model: used)
            }
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data, as: UTF8.self)
            if status == 400, body["fallbacks"] != nil, msg.lowercased().contains("fallback") {
                FileHandle.standardError.write(Data("jarvis: API rejected fallbacks (\(msg)); continuing without\n".utf8))
                body["fallbacks"] = nil; useFallbacks = false; continue   // beta shape rejected: carry on without it
            }
            if [429, 500, 502, 503, 529].contains(status), attempt < 2 {
                try? await Task.sleep(nanoseconds: UInt64(1_500_000_000 * Double(attempt + 1))); continue
            }
            throw BrainError.api(status, msg)
        }
        throw BrainError.api(0, "retries exhausted")
    }

    static let offlineCodes: Set<URLError.Code> = [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed, .timedOut, .internationalRoamingOff]

    static func model(named s: String) -> Model? {
        if let m = Model(rawValue: s) { return m }
        if s.contains("opus") { return .opus }
        if s.contains("sonnet") { return .sonnet }
        if s.contains("haiku") { return .haiku }
        return nil
    }

    static func text(of content: [[String: Any]]) -> String {
        content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
