import Foundation

/// How often Mycroft jokes.
public enum Humour: String, CaseIterable {
    case often, normal, rare, off
    public var label: String {
        switch self { case .often: return "Every reply"; case .normal: return "Every other reply"; case .rare: return "Rarely"; case .off: return "Never" }
    }
    /// The instruction that goes into the system prompt.
    var instruction: String {
        switch self {
        case .often: return "Add a dry joke to almost every reply, after the answer."
        case .normal: return "Not every reply needs a joke; roughly every other reply is right."
        case .rare: return "Joke only occasionally, about one reply in five. Otherwise be crisp and helpful."
        case .off: return "Humour is switched off: no jokes or quips at all. Stay polite, formal and brief."
        }
    }
    /// The same, for undercover mode's friendly persona.
    var casualInstruction: String {
        switch self {
        case .often: return "Add a light, friendly joke to most replies, after the answer."
        case .normal: return "A light joke now and then is great; roughly every other reply."
        case .rare: return "Joke only occasionally. Otherwise be quick and helpful."
        case .off: return "No jokes: keep it friendly, warm and brief."
        }
    }
}

/// Who Mycroft is being. The butler is the default; the others are menu-bar costumes.
public enum Persona: String, CaseIterable {
    case butler, undercover, comrade, bigBrother
    public var label: String {
        switch self { case .butler: return "Butler"; case .undercover: return "Undercover"; case .comrade: return "Comrade"; case .bigBrother: return "Big Brother" }
    }
    public var blurb: String {
        switch self {
        case .butler: return "British butler, dry wit"
        case .undercover: return "American voice, friendly and casual, no politics"
        case .comrade: return "Soviet Party official, Russian accent, five-year plans and the KGB"
        case .bigBrother: return "Orwell's Ministry of Truth announcer, 1984"
        }
    }
    /// What the owner is called in fixed lines ("sir" is swapped for this).
    public var address: String {
        switch self { case .butler: return "sir"; case .undercover: return ""; case .comrade: return "comrade"; case .bigBrother: return "citizen" }
    }
}

/// The owner's settings, kept in state.json. Anything unset keeps the original behaviour.
public enum Settings {
    static func bool(_ key: String, _ fallback: Bool) -> Bool { State.get(key).map { $0 == "on" } ?? fallback }
    static func setBool(_ key: String, _ v: Bool) { State.set(key, v ? "on" : "off") }

    public static var voice: String? { get { State.get("voice") } set { State.set("voice", newValue ?? "") } }
    /// Words per minute for `say`; nil is the voice's own pace.
    public static var rate: Int? {
        get { State.get("rate").flatMap(Int.init) }
        set { State.set("rate", newValue.map(String.init) ?? "") }
    }
    public static var humour: Humour {
        get { State.get("humour").flatMap(Humour.init(rawValue:)) ?? .normal }
        set { State.set("humour", newValue.rawValue) }
    }
    /// Which persona is on. Before personas there was only the undercover switch, so that is the fallback.
    public static var persona: Persona {
        get { State.get("persona").flatMap(Persona.init(rawValue:)) ?? (bool("undercover", false) ? .undercover : .butler) }
        set { State.set("persona", newValue.rawValue) }
    }
    /// Undercover mode: an American voice and a friendly, casual persona with no politics.
    public static var undercover: Bool { persona == .undercover }
    public static var followUp: Bool { get { bool("followUp", true) } set { setBool("followUp", newValue) } }
    public static var openingLine: Bool { get { bool("openingLine", true) } set { setBool("openingLine", newValue) } }
    public static var shutdownLine: Bool { get { bool("shutdownLine", true) } set { setBool("shutdownLine", newValue) } }
    public static var briefing: Bool { get { bool("briefing", true) } set { setBool("briefing", newValue) } }
    public static var wakeWord: Bool { get { bool("wakeWord", true) } set { setBool("wakeWord", newValue) } }
    /// Fast search answers in roughly half the time but reads more results, so costs a little more.
    public static var fastSearch: Bool { get { bool("fastSearch", true) } set { setBool("fastSearch", newValue) } }
    /// Seconds of silence before Mycroft decides you've finished talking.
    public static var endSilence: Double {
        get { State.get("endSilence").flatMap(Double.init).map { min(max($0, 0.5), 3) } ?? 1.5 }
        set { State.set("endSilence", String(newValue)) }
    }
    /// "City, Country", used for weather and local answers.
    public static var city: String {
        get { State.get("city").flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? "Konya, Turkey" }
        set { State.set("city", newValue) }
    }
    public static var cityName: String { city.components(separatedBy: ",")[0].trimmingCharacters(in: .whitespaces) }
    /// Monthly spending cap in dollars.
    public static var cap: Double {
        get { State.get("cap").flatMap(Double.init).map { max(1, $0) } ?? 80 }
        set { State.set("cap", String(newValue)) }
    }
}
