import Foundation

/// Rebuilds a Messages API response from its server-sent events, block by block, so the content can be
/// sent back unchanged on the next tool round (thinking signatures, tool inputs, server tool results).
struct StreamAssembler {
    var blocks: [Int: [String: Any]] = [:]
    var partialJSON: [Int: String] = [:]
    var model: String?
    var stopReason = "end_turn"
    var usage: [String: Any] = [:]
    /// Called with each new piece of reply text, and when a tool call starts (its name).
    var onText: ((String) -> Void)?
    var onToolStart: ((String) -> Void)?

    mutating func handle(_ e: [String: Any]) throws {
        let index = e["index"] as? Int ?? 0
        switch e["type"] as? String {
        case "message_start":
            let m = e["message"] as? [String: Any] ?? [:]
            model = m["model"] as? String
            if let u = m["usage"] as? [String: Any] { usage.merge(u) { $1 } }
        case "content_block_start":
            let b = e["content_block"] as? [String: Any] ?? [:]
            blocks[index] = b
            let type = b["type"] as? String
            if type == "tool_use" || type == "server_tool_use" { onToolStart?(b["name"] as? String ?? "") }
            if type == "text", let t = b["text"] as? String, !t.isEmpty { onText?(t) }
        case "content_block_delta":
            let d = e["delta"] as? [String: Any] ?? [:]
            var b = blocks[index] ?? [:]
            switch d["type"] as? String {
            case "text_delta":
                let t = d["text"] as? String ?? ""
                b["text"] = (b["text"] as? String ?? "") + t
                onText?(t)
            case "thinking_delta": b["thinking"] = (b["thinking"] as? String ?? "") + (d["thinking"] as? String ?? "")
            case "signature_delta": b["signature"] = d["signature"]
            case "input_json_delta": partialJSON[index, default: ""] += d["partial_json"] as? String ?? ""
            case "citations_delta":
                if let c = d["citation"] { b["citations"] = (b["citations"] as? [Any] ?? []) + [c] }
            default: break
            }
            blocks[index] = b
        case "content_block_stop":
            if let json = partialJSON.removeValue(forKey: index), !json.isEmpty {
                blocks[index]?["input"] = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? [:]
            }
        case "message_delta":
            if let d = e["delta"] as? [String: Any], let s = d["stop_reason"] as? String { stopReason = s }
            if let u = e["usage"] as? [String: Any] { usage.merge(u) { $1 } }
        case "error":
            let err = e["error"] as? [String: Any] ?? [:]
            throw BrainError.api(529, (err["message"] as? String) ?? (err["type"] as? String) ?? "stream error")
        default: break   // ping, message_stop
        }
    }

    /// The finished content, in order. After a mid-stream fallback, model-internal blocks from before the
    /// last `fallback` marker are left out, as the API asks.
    var content: [[String: Any]] {
        let ordered = blocks.keys.sorted().compactMap { blocks[$0] }
        guard let cut = ordered.lastIndex(where: { $0["type"] as? String == "fallback" }) else { return ordered }
        let internalTypes: Set<String> = ["thinking", "redacted_thinking", "tool_use"]
        let resultIDs = Set(ordered.compactMap { $0["tool_use_id"] as? String })
        return ordered.enumerated().compactMap { i, b in
            guard i < cut else { return b }
            let type = b["type"] as? String ?? ""
            if internalTypes.contains(type) { return nil }
            if type == "server_tool_use", !resultIDs.contains(b["id"] as? String ?? "") { return nil }
            return b
        }
    }

    /// Replays a complete (non-streamed) response as events. Lets plain transports, such as the test stub, stream.
    static func events(for json: [String: Any]) -> [[String: Any]] {
        var ev: [[String: Any]] = [["type": "message_start", "message": ["model": json["model"] ?? "", "usage": json["usage"] ?? [:]]]]
        for (i, b) in (json["content"] as? [[String: Any]] ?? []).enumerated() {
            if b["type"] as? String == "text" {
                var start = b; start["text"] = ""
                ev.append(["type": "content_block_start", "index": i, "content_block": start])
                ev.append(["type": "content_block_delta", "index": i, "delta": ["type": "text_delta", "text": b["text"] ?? ""]])
            } else {
                ev.append(["type": "content_block_start", "index": i, "content_block": b])
            }
            ev.append(["type": "content_block_stop", "index": i])
        }
        ev.append(["type": "message_delta", "delta": ["stop_reason": json["stop_reason"] ?? "end_turn"], "usage": [:] as [String: Any]])
        ev.append(["type": "message_stop"])
        return ev
    }
}

/// Cuts streamed text into whole sentences so each can be spoken as soon as it is complete.
public struct SentenceSplitter {
    var buffer = ""
    public init() {}

    /// Adds text and returns any sentences now complete. A sentence ends at . ! ? or a newline followed by
    /// whitespace, so "3.5" and "e.g." mid-word don't split; very short fragments wait for more.
    public mutating func add(_ text: String) -> [String] {
        buffer += text
        var out: [String] = []
        var start = buffer.startIndex
        var i = buffer.startIndex
        while i < buffer.endIndex {
            let c = buffer[i]
            let next = buffer.index(after: i)
            if (c == "\n") || (".!?".contains(c) && next < buffer.endIndex && buffer[next].isWhitespace) {
                let s = buffer[start..<next].trimmingCharacters(in: .whitespacesAndNewlines)
                if s.count >= 6 || c == "\n" {
                    if !s.isEmpty { out.append(s) }
                    start = next
                }
            }
            i = next
        }
        buffer = String(buffer[start...])
        return out
    }

    /// Whatever is left at the end of the reply.
    public mutating func flush() -> String? {
        let s = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return s.isEmpty ? nil : s
    }
}
