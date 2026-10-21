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
        let hour = calendar.component(.hour, from: date)
        return hour < 12 ? Lines.morning : pick(Lines.startup(hour: hour), key: "startup")
    }
    public mutating func error() -> String { pick(Lines.errors, key: "error") }
    public mutating func offline() -> String { pick(Lines.offline, key: "offline") }
    public mutating func shutdown() -> String { pick(Lines.shutdown, key: "shutdown") }
}
