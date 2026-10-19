import Foundation

public enum Model: String, CaseIterable, Codable {
    case haiku = "claude-haiku-5-5"
    case sonnet = "claude-sonnet-5-5"
    case opus = "claude-opus-5-5"

    public var label: String {
        switch self { case .haiku: return "Haiku"; case .sonnet: return "Sonnet"; case .opus: return "Opus" }
    }
    /// USD per million tokens (input, output, cache read).
    var price: (input: Double, output: Double, cacheRead: Double) {
        switch self {
        case .haiku: return (0.10, 0.50, 0.01)
        case .sonnet: return (2.00, 10.00, 0.20)
        case .opus: return (4.00, 20.00, 0.20)
        }
    }
}

public enum Mode: String, CaseIterable, Codable {
    case auto, haiku, sonnet, opus
    public var label: String { rawValue.capitalized }
    public var fixedModel: Model? {
        switch self { case .auto: return nil; case .haiku: return .haiku; case .sonnet: return .sonnet; case .opus: return .opus }
    }
}

public enum Router {
    static let deepThinking = ["think deeply", "think hard", "think carefully", "deep thinking", "think this through", "really think", "use your best", "deeply"]
    static let commandWords = ["open ", "launch ", "quit ", "close ", "run ", "create ", "make a folder", "make a file", "delete ", "remove ", "move ", "copy ", "rename ", "find ", "list ", "show me the files", "volume", "brightness", "mute the", "play ", "pause", "skip", "turn on", "turn off", "set ", "switch ", "install ", "download ", "organise", "organize", "empty the", "screenshot", "wifi", "bluetooth", "dark mode", "do not disturb", "lock the", "sleep", "restart", "shut down", "terminal", "folder", "file", "desktop", "downloads"]
    static let screenWords = ["my screen", "the screen", "on screen", "look at this", "what am i looking at", "what's this", "what is this"]

    /// Auto mode: Haiku for questions, Sonnet for commands and screen reading, Opus when asked for deep thinking.
    public static func model(for text: String, mode: Mode, capReached: Bool) -> Model {
        if capReached { return .haiku }
        if let m = mode.fixedModel { return m }
        let t = text.lowercased()
        if deepThinking.contains(where: t.contains) { return .opus }
        if screenWords.contains(where: t.contains) { return .sonnet }
        if commandWords.contains(where: t.contains) { return .sonnet }
        return .haiku
    }
}

/// Things the user says that Jarvis handles locally, without a model call.
public enum Intent: Equatable {
    case mute
    case stop
    case setMode(Mode)
    case spend
    case whatDoYouKnow
    case forget(String)
    case none

    public static func parse(_ raw: String) -> Intent {
        var t = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,"))
        if t.hasPrefix("jarvis,") { t = String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        if t.hasPrefix("jarvis ") { t = String(t.dropFirst(7)) }
        if ["stop", "stop it", "be quiet", "quiet", "shut up", "enough"].contains(t) { return .stop }
        if ["mute", "mute yourself", "go mute", "mute listening"].contains(t) { return .mute }
        for m in Mode.allCases {
            if t == "use \(m.rawValue)" || t == "switch to \(m.rawValue)" || t == "\(m.rawValue) mode" || t == "use \(m.rawValue) mode" || t == "go to \(m.rawValue)" { return .setMode(m) }
        }
        if t == "use auto" || t == "automatic mode" { return .setMode(.auto) }
        if t.contains("how much") && (t.contains("spent") || t.contains("spend") || t.contains("cost")) { return .spend }
        if t.contains("what do you know about me") || t.contains("what have you learned about me") { return .whatDoYouKnow }
        for p in ["forget that i ", "forget that i'm ", "forget i ", "forget that "] where t.hasPrefix(p) {
            var rest = String(t.dropFirst(p.count))
            if p == "forget that i'm " { rest = "am " + rest }
            return .forget(rest)
        }
        return .none
    }
}
