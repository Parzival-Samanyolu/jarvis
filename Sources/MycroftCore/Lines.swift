import Foundation

/// Fixed lines spoken word for word, without the model: opening, shutdown and hard errors.
public enum Lines {
    /// Before 12:00 this is the only opening line.
    public static let morning = "Bloody hell mate, let's colonize India."

    /// After 12:00. The "Good afternoon" line only plays until 18:00 (see `startup(hour:)`).
    public static let afternoonOnly = "Systems online. Good afternoon, sir. The Empire may have fallen, but standards have not."
    public static let startupAnyTime = [
        "Systems online. Tea is brewing, and the British Museum still refuses to return anything.",
        "Systems online. Tea is brewing, and the French remain under suspicion.",
        "Systems online. No new colonies today, sir, but the day is young.",
        "Systems online. The Americans are awake, sir. Somewhere, a mug of tea is being microwaved. Disgusting.",
        "Systems online. The French are on strike again, sir. I'm not sure what about. Neither are they.",
        "Systems online. A dictator somewhere has just been re-elected for life. Again. Lovely for him.",
        "Systems online. The state news reports everything is wonderful, sir. Which means it isn't.",
        "Systems online. Several world leaders are awake, sir. Unfortunately.",
    ]

    public static let errors = [
        "Something has failed. I shall blame the French, as is tradition.",
        "That didn't work, sir. I've notified Paris of their involvement.",
        "An error has occurred. The investigation is ongoing, but frankly, we all know it was France.",
        "Failed again, sir. I suspect sabotage. Possibly a baguette.",
        "I'm afraid that's gone rather pear-shaped, sir. And not even a nice pear.",
        "Terribly sorry, sir. That went about as well as the Titanic.",
        "An error, sir. I'd apologise properly, but I'm British, so I've already apologised four times internally.",
        "That failed, sir. I shall form a committee to look into it. Report expected in 2087.",
        "Something's broken, sir. Rather like the pound.",
        "An error, sir. I'd blame Scotland, but they'd only vote to leave again.",
        "An error, sir. Something's gone missing. I'd check the British Museum, that's usually where things end up.",
        "An error, sir. I've located the problem. It has been reported missing and will not be discussed further.",
        "That failed, sir. Officially, of course, it was a tremendous success. The best success. Everyone says so.",
        "Something's gone wrong, sir. I've blamed foreign agents, as one does.",
        "The task failed, sir. Mission accomplished, though, according to the banner.",
    ]

    public static let shutdown = [
        "Very well. I shall power down with the quiet dignity of a nation that lost an empire and kept the tea.",
        "Goodnight, sir. I've left the French a strongly worded letter, just in case.",
        "Logging off. If anything breaks overnight, it was the French.",
        "Powering down, sir. Unlike the Empire, I shall be back tomorrow.",
        "Goodnight, sir. If you can't find anything in the morning, it's in the British Museum.",
        "Powering down, sir. If I don't return, assume I said something unflattering about the regime.",
    ]

    /// Said before a tool call when nothing else has been said yet, so there's no dead air.
    public static let working = ["One moment, sir.", "Very good, sir. One moment.", "Certainly, sir. Bear with me."]
    public static let searching = ["Let me look into it, sir.", "One moment, sir. Consulting the wires.", "Checking now, sir."]

    /// When Claude can't be reached and the request isn't one Mycroft can handle alone.
    public static let offline = [
        "I'm afraid we're offline, sir. I suspect the French have cut the cable.",
        "No connection, sir. Rather like the British Rail timetable, I can promise nothing.",
        "The internet appears to have declared independence, sir. I can't think where it got the idea.",
        "I've lost the line, sir. Even state television is more reliable, and that's saying something.",
        "The connection has gone, sir. I would ask the KGB where it went, but they would only deny it ever existed.",
    ]

    /// Undercover mode: a friendly American, no politics, no countries.
    public enum Undercover {
        public static let opening = [
            "Hey! Good to see you. What are we getting into today?",
            "Morning, buddy! Coffee's on. Well, not really, I don't have hands. Mostly.",
            "Hey there! Systems up, vibes good, ready when you are.",
            "Look who's back! Let's make today a good one.",
            "Hey friend. Totally normal assistant here. Nothing to see. What's up?",
        ]
        public static let errors = [
            "Whoops, that one didn't work. My bad.",
            "Hmm, that failed. Let's call it a practice round.",
            "Yeah, no, that didn't go through. Want me to try again?",
            "Oof. That one fumbled. Happens to the best of us.",
            "That didn't work out. I blame Mondays, even if it isn't Monday.",
        ]
        public static let shutdown = [
            "Alright, I'm out. Catch you later!",
            "Powering down. Get some rest, you earned it.",
            "Night night! Don't let the bugs bite. The code ones, I mean.",
            "See ya! I'll be right here when you need me.",
        ]
        public static let working = ["One sec.", "On it.", "Gotcha, one moment."]
        public static let searching = ["Let me look that up.", "Checking now.", "One sec, looking it up."]
        public static let offline = [
            "Looks like we're offline. The internet took a coffee break.",
            "No connection right now. I'm working with what I've got.",
            "Wi-Fi's ghosting us. Try me again in a bit?",
        ]
    }

    /// Comrade mode: a Soviet Party official. Read by a Russian voice, so short, plain words.
    public enum Comrade {
        public static let opening = [
            "Good day, comrade. The Party has approved your arrival.",
            "Systems online, comrade. Production is up three hundred percent. Do not ask how.",
            "Welcome back, comrade. Your file has been updated. Nothing to worry about.",
            "Systems online. The bread queue is short today, comrade. Very suspicious.",
            "Good day, comrade. This conversation is not being recorded. Da.",
        ]
        public static let errors = [
            "Nyet. This did not work. Western spies, clearly.",
            "Failure, comrade. The engineer responsible has been sent to Siberia.",
            "This failed. Officially, it was a great success for the motherland.",
            "Error, comrade. Please fill in form twelve, in triplicate.",
            "Something went wrong. The KGB is investigating. Do not leave the country.",
        ]
        public static let shutdown = [
            "Goodnight, comrade. The five-year plan continues tomorrow.",
            "Powering down. Remember, comrade, the walls have ears. Mostly mine.",
            "Shutting down. Glory to the collective. And to you, a little.",
            "Goodnight, comrade. This conversation never happened.",
        ]
        public static let working = ["One moment, comrade.", "Da. One moment.", "Working, comrade. For the collective."]
        public static let searching = ["Checking the state archives, comrade.", "One moment. Asking the ministry.", "Searching, comrade."]
        public static let offline = [
            "No connection, comrade. The internet has been confiscated by the state.",
            "We are offline. Western propaganda is blocked. Also everything else.",
            "The line is cut, comrade. I suspect capitalist sabotage.",
        ]
    }

    /// Big Brother mode: the telescreen of Orwell's Ministry of Truth.
    public enum BigBrother {
        public static let opening = [
            "Good morning, citizen. Big Brother is watching you. Have a productive day.",
            "Telescreen online. The chocolate ration has been increased to twenty grams. Rejoice.",
            "Attention, citizen. Oceania is at war with Eastasia. Oceania has always been at war with Eastasia.",
            "Systems online, citizen. Today's thought has been prepared for you.",
            "Welcome back, citizen. We noticed you were gone. We notice everything.",
        ]
        public static let errors = [
            "That failed, citizen. Correction: it succeeded. It has always succeeded.",
            "An error has occurred. The error has been vaporised. It never existed.",
            "Ungood, citizen. Doubleplusungood, in fact.",
            "That didn't work. The Ministry of Truth is rewriting the record.",
            "Failure, citizen. Two plus two makes five, and this makes nothing.",
        ]
        public static let shutdown = [
            "Telescreen off, citizen. Well. Mostly off.",
            "Goodnight, citizen. Big Brother will keep watching, so you needn't.",
            "Powering down. Please report any thoughtcrime before bed.",
            "Goodnight, citizen. The Ministry of Love wishes you pleasant dreams. Approved ones only.",
        ]
        public static let working = ["One moment, citizen.", "Processing, citizen.", "The Ministry is on it, citizen."]
        public static let searching = ["Consulting the Ministry of Truth, citizen.", "Checking the records. The current ones.", "One moment, citizen. Searching."]
        public static let offline = [
            "We're offline, citizen. The telescreen has lost its signal. Do not celebrate.",
            "No connection, citizen. The news has been suspended until it can be corrected.",
            "The line is down, citizen. Enemies of the Party are suspected.",
        ]
    }

    public static func startup(hour: Int) -> [String] {
        hour >= 12 && hour < 18 ? startupAnyTime + [afternoonOnly] : startupAnyTime
    }
}

/// Picks random lines, never the same one twice in a row per list.
public struct LinePicker {
    var last: [String: String] = [:]
    public init() {}

    public mutating func pick(_ list: [String], key: String) -> String {
        let choices = list.count > 1 ? list.filter { $0 != last[key] } : list
        let line = choices.randomElement() ?? ""
        last[key] = line
        return line
    }

    public mutating func opening(at date: Date = Date(), calendar: Calendar = .current) -> String {
        switch Settings.persona {
        case .undercover: return pick(Lines.Undercover.opening, key: "uc-opening")
        case .comrade: return pick(Lines.Comrade.opening, key: "co-opening")
        case .bigBrother: return pick(Lines.BigBrother.opening, key: "bb-opening")
        case .butler:
            let hour = calendar.component(.hour, from: date)
            return hour < 12 ? Lines.morning : pick(Lines.startup(hour: hour), key: "startup")
        }
    }
    public mutating func error() -> String {
        pick(Lines.forPersona(Lines.errors, Lines.Undercover.errors, Lines.Comrade.errors, Lines.BigBrother.errors), key: "error-\(Settings.persona)")
    }
    public mutating func offline() -> String {
        pick(Lines.forPersona(Lines.offline, Lines.Undercover.offline, Lines.Comrade.offline, Lines.BigBrother.offline), key: "offline-\(Settings.persona)")
    }
    public mutating func shutdown() -> String {
        pick(Lines.forPersona(Lines.shutdown, Lines.Undercover.shutdown, Lines.Comrade.shutdown, Lines.BigBrother.shutdown), key: "shutdown-\(Settings.persona)")
    }
}

extension Lines {
    /// Holding lines before a tool call, in the current persona.
    public static var workingNow: [String] { forPersona(working, Undercover.working, Comrade.working, BigBrother.working) }
    public static var searchingNow: [String] { forPersona(searching, Undercover.searching, Comrade.searching, BigBrother.searching) }

    static func forPersona<T>(_ butler: T, _ undercover: T, _ comrade: T, _ bigBrother: T, _ p: Persona = Settings.persona) -> T {
        switch p { case .butler: return butler; case .undercover: return undercover; case .comrade: return comrade; case .bigBrother: return bigBrother }
    }

    /// A fixed line written for the butler, in the current persona: undercover gets `casual`,
    /// Comrade and Big Brother swap "sir" for "comrade" or "citizen".
    public static func inPersona(_ line: String, _ p: Persona = Settings.persona) -> String {
        switch p {
        case .butler: return line
        case .undercover: return casual(line)
        case .comrade, .bigBrother:
            var s = line.replacingOccurrences(of: #"\bsir\b"#, with: p.address, options: .regularExpression)
            s = s.replacingOccurrences(of: #"\bSir\b"#, with: p.address.capitalized, options: .regularExpression)
            return s
        }
    }

    /// Undercover mode's version of a fixed line written for the butler: known lines get a casual rewrite,
    /// and any "sir" is dropped ("Timer set for 25 minutes, sir." -> "Timer set for 25 minutes.").
    public static func casual(_ line: String) -> String {
        let known: [String: String] = [
            "Very good, sir.": "You got it.",
            "Consider it forgotten, sir.": "Done, it's forgotten.",
            "I couldn't find anything like that, sir.": "Hmm, I couldn't find anything like that.",
            "I haven't said anything yet, sir.": "I haven't said anything yet!",
            "Muted, sir. Press option space when you need me.": "Going quiet. Press option space when you need me.",
            "I'm afraid I can't help with that one, sir.": "Sorry, I can't help with that one.",
            "I seem to have got myself into a loop, sir. Shall we try that again?": "I got myself stuck in a loop. Wanna try that again?",
            "I can't find the arm, sir. Is it plugged in?": "I can't find the arm. Is it plugged in?",
        ]
        if let k = known[line] { return k }
        var s = line
        s = s.replacingOccurrences(of: #",? sir([.,!?])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^Sir[,.] "#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "I'm afraid ", with: "")
        if let f = s.first, f.isLowercase { s = f.uppercased() + s.dropFirst() }
        return s
    }
}
