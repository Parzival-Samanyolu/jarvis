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

    /// Auto mode: Sonnet for everything, Opus when asked for deep thinking. Haiku only once the monthly cap is reached.
    public static func model(for text: String, mode: Mode, capReached: Bool) -> Model {
        if capReached { return .haiku }
        if let m = mode.fixedModel { return m }
        if deepThinking.contains(where: text.lowercased().contains) { return .opus }
        return .sonnet
    }
}

/// Things the user says that Mycroft handles locally, without a model call.
public enum Intent: Equatable {
    case mute
    case stop
    case setMode(Mode)
    case spend
    case whatDoYouKnow
    case forget(String)
    case repeatLast
    case timer(seconds: Int, label: String)
    case timerStatus
    case cancelTimers
    case armStop
    case armHome
    case armGripper(open: Bool)
    case armGesture(String)
    case undercover(Bool)
    case none

    static let repeatPhrases: Set<String> = [
        "say that again", "say again", "say it again", "repeat that", "repeat", "repeat it", "repeat yourself",
        "what did you say", "what was that", "come again", "pardon", "pardon me", "sorry what", "what", "one more time",
    ]

    public static func parse(_ raw: String, now: Date = Date()) -> Intent {
        var t = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,"))
        // The name in front ("Mycroft, mute").
        for name in ["mycroft"] {
            if t.hasPrefix(name + ",") { t = String(t.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
            else if t.hasPrefix(name + " ") { t = String(t.dropFirst(name.count + 1)) }
        }
        var polite = t
        for p in ["sorry, ", "sorry ", "please ", "can you ", "could you ", "would you "] where polite.hasPrefix(p) { polite = String(polite.dropFirst(p.count)) }
        for p in [" please", " for me", " sir"] where polite.hasSuffix(p) { polite = String(polite.dropLast(p.count)) }
        if repeatPhrases.contains(polite.trimmingCharacters(in: CharacterSet(charactersIn: ",.?! "))) { return .repeatLast }
        if let timer = parseTimer(polite, now: now) { return timer }
        if let arm = parseArm(polite) { return arm }
        let bare = polite.trimmingCharacters(in: CharacterSet(charactersIn: ",.!? "))
        if ["go undercover", "undercover mode", "undercover mode on", "turn on undercover mode", "undercover on", "enable undercover mode"].contains(bare) { return .undercover(true) }
        if ["undercover mode off", "undercover off", "turn off undercover mode", "blow your cover", "drop the act", "be yourself", "disable undercover mode", "back to normal"].contains(bare) { return .undercover(false) }
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

    /// Quick arm commands that shouldn't wait for the model, above all stopping it.
    static func parseArm(_ t: String) -> Intent? {
        let s = t.trimmingCharacters(in: CharacterSet(charactersIn: ",.!? "))
        if ["stop the arm", "arm stop", "stop arm", "freeze", "freeze the arm", "halt", "halt the arm"].contains(s) { return .armStop }
        if let g = Gesture.matching(s) { return .armGesture(g.name) }
        if ["arm home", "home the arm", "reset the arm", "arm to home", "put the arm home", "send the arm home"].contains(s) { return .armHome }
        if ["open the gripper", "open gripper", "open the hand", "open your hand", "open the claw", "let go", "release", "drop it"].contains(s) { return .armGripper(open: true) }
        if ["close the gripper", "close gripper", "close the hand", "close your hand", "close the claw", "grab", "grab it", "grip"].contains(s) { return .armGripper(open: false) }
        return nil
    }

    /// "Set a timer for 25 minutes", "pomodoro", "remind me in 10 minutes to drink water", "how long is left on
    /// my timer", "cancel the timer". "Remind me at 6 to ..." works too; other reminders ("remind me tomorrow") are left to the model.
    static func parseTimer(_ t: String, now: Date = Date()) -> Intent? {
        let aboutTimer = t.contains("timer") || t.contains("countdown") || t.contains("pomodoro") || t.contains("reminder")
        let reminder = t.hasPrefix("remind me ") || t.contains("reminder")
        if ["how long left", "how much time left", "how much time is left", "how long is left"].contains(t) { return .timerStatus }
        guard aboutTimer || reminder else { return nil }
        let clock = reminder ? Timers.secondsUntilClockTime(in: t, now: now) : nil
        guard let (seconds, ranges) = Timers.duration(in: t) ?? clock.map({ ($0.seconds, [$0.range]) }) else {
            if ["cancel", "stop", "clear", "delete", "remove", "turn off"].contains(where: t.contains) { return .cancelTimers }
            if ["how long", "how much", "left", "remaining"].contains(where: t.contains) { return .timerStatus }
            return t.contains("pomodoro") && !reminder ? .timer(seconds: 25 * 60, label: "") : nil
        }
        guard reminder else { return .timer(seconds: seconds, label: "") }
        // What's left once the length and the filler are taken out: "remind me in 10 minutes to drink water".
        var rest = t
        for r in ranges.sorted(by: { $0.lowerBound > $1.lowerBound }) { rest.replaceSubrange(r, with: " ") }
        for p in ["remind me ", "reminder "] { if let r = rest.range(of: p) { rest = String(rest[r.upperBound...]); break } }
        var words = rest.split(separator: " ").map(String.init)
        let filler: Set<String> = ["in", "after", "for", "and", "to", "about", "that", "i", "need", "should", "have", "of"]
        while let f = words.first, filler.contains(f) { words.removeFirst() }
        while let l = words.last, ["in", "after", "for", "and"].contains(l) { words.removeLast() }
        let label = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",. "))
        return .timer(seconds: seconds, label: label.isEmpty ? "check the time" : label)
    }
}
