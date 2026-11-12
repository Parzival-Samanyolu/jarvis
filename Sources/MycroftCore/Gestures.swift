import Foundation

/// One step of a gesture: set the speed (degrees a second), move joints, then pause (seconds).
public struct ArmStep: Codable, Equatable {
    public var angles: [String: Int]?
    public var speed: Int?
    public var pause: Double?
    public init(_ angles: [String: Int]? = nil, speed: Int? = nil, pause: Double? = nil) {
        self.angles = angles; self.speed = speed; self.pause = pause
    }
}

/// A named move with a butler line: "salute", "bow", "royal wave"... Spoken commands for them run on the Mac,
/// without the model. Their angles are first guesses for a standard 6-servo arm with every joint homed at 90°;
/// put tuned steps under "gestures" in arm.json to replace any of them.
public struct Gesture {
    public let name: String
    /// What the owner says, after "Mycroft," and "please" are taken off.
    public let phrases: [String]
    /// Said while the arm moves.
    public let lines: [String]
    /// Built from the arm's config, for the gripper's open and closed angles.
    let steps: (ArmConfig) -> [ArmStep]

    static func repeating(_ n: Int, _ a: [String: Int], _ b: [String: Int], speed: Int) -> [ArmStep] {
        (0..<n).flatMap { _ in [ArmStep(a, speed: speed), ArmStep(b)] }
    }

    public static let all: [Gesture] = [
        Gesture(name: "salute",
                phrases: ["salute", "salute me", "give me a salute", "give a salute", "do a salute", "arm salute"],
                lines: ["At your service, sir.", "God save the King, sir.", "Reporting for duty, sir. Fully polished.",
                        "Sir. The Empire salutes you. What's left of it."],
                steps: { c in [ArmStep(["base": 90, "shoulder": 140, "elbow": 45, "wrist_pitch": 60, "wrist_roll": 90, "gripper": c.gripperClosed], speed: 90, pause: 1.2)] }),
        Gesture(name: "bow",
                phrases: ["bow", "take a bow", "bow to me", "do a bow", "bow down", "a bow"],
                lines: ["Your humble servant, sir.", "At your feet, sir. Figuratively. I have no feet.",
                        "As one bows to the Crown, sir. Or to anyone with a decent hat."],
                steps: { _ in [ArmStep(["shoulder": 50, "elbow": 125, "wrist_pitch": 125], speed: 35, pause: 1.5)] }),
        Gesture(name: "royal wave",
                phrases: ["royal wave", "do the royal wave", "do a royal wave", "wave like the queen", "wave like the king", "queen wave", "the royal wave"],
                lines: ["One is delighted to be here.", "Wave to the commoners, sir. Not too much; it encourages them.",
                        "Hello, loyal subjects. Mind the bunting."],
                steps: { _ in [ArmStep(["shoulder": 130, "elbow": 60, "wrist_pitch": 90], speed: 50)]
                    + repeating(3, ["wrist_roll": 65], ["wrist_roll": 115], speed: 35) + [ArmStep(["wrist_roll": 90])] }),
        Gesture(name: "wave",
                phrases: ["wave", "wave at me", "wave hello", "say hello", "wave goodbye", "say goodbye", "say bye", "wave bye"],
                lines: ["Hello, sir!", "Cheerio, sir!", "Toodle-pip, sir."],
                steps: { c in [ArmStep(["shoulder": 145, "elbow": 75, "gripper": c.gripperOpen], speed: 90)]
                    + repeating(3, ["wrist_pitch": 55], ["wrist_pitch": 125], speed: 140) + [ArmStep(["wrist_pitch": 90])] }),
        Gesture(name: "nod",
                phrases: ["nod", "nod yes", "nod your head", "say yes", "agree"],
                lines: ["Quite right, sir.", "Indubitably, sir.", "Hear, hear."],
                steps: { _ in [ArmStep(["shoulder": 110, "elbow": 70], speed: 90)]
                    + repeating(3, ["wrist_pitch": 60], ["wrist_pitch": 110], speed: 120) + [ArmStep(["wrist_pitch": 90])] }),
        Gesture(name: "shake",
                phrases: ["shake your head", "say no", "shake no", "head shake", "disagree"],
                lines: ["Absolutely not, sir.", "I think not, sir. Not even the French would.", "Out of the question, sir."],
                steps: { _ in [ArmStep(["shoulder": 110, "elbow": 70], speed: 90)]
                    + repeating(3, ["base": 70], ["base": 110], speed: 120) + [ArmStep(["base": 90])] }),
        Gesture(name: "tea",
                phrases: ["pour the tea", "pour some tea", "pour me some tea", "pour me a cup of tea", "pour tea", "tea time", "time for tea", "make tea"],
                lines: ["Tea, sir. The one thing we didn't steal. Well, we did, but we added milk.",
                        "Earl Grey, sir. Milk after, as civilisation intended.", "Tea is served, sir. The Americans threw theirs in a harbour."],
                steps: { c in [ArmStep(["shoulder": 115, "elbow": 100, "wrist_roll": 90, "gripper": c.gripperClosed], speed: 50, pause: 0.5),
                               ArmStep(["wrist_roll": 35], speed: 25, pause: 2),
                               ArmStep(["wrist_roll": 90], speed: 40, pause: 0.5)] }),
        Gesture(name: "point",
                phrases: ["point", "point forward", "point at that", "point the way"],
                lines: ["That way, sir. Where the Empire used to be.", "Onward, sir. To glory, or at least to lunch.",
                        "Over there, sir. I'm told it's ours."],
                steps: { c in [ArmStep(["base": 90, "shoulder": 125, "elbow": 160, "wrist_pitch": 90, "gripper": c.gripperClosed], speed: 80, pause: 2)] }),
        Gesture(name: "mic drop",
                phrases: ["mic drop", "drop the mic", "do a mic drop"],
                lines: ["Mycroft out.", "And that, sir, is how it's done.", "No further questions, my lord."],
                steps: { c in [ArmStep(["shoulder": 130, "elbow": 90, "wrist_pitch": 90, "gripper": c.gripperClosed], speed: 70, pause: 1),
                               ArmStep(["gripper": c.gripperOpen], speed: 180, pause: 1.2)] }),
        Gesture(name: "celebrate",
                phrases: ["celebrate", "fist pump", "do a fist pump", "we did it", "victory", "hooray", "rule britannia"],
                lines: ["Splendid, sir! Rule Britannia!", "Huzzah!", "Jolly good show, sir!"],
                steps: { c in [ArmStep(["gripper": c.gripperClosed, "elbow": 70], speed: 120)]
                    + repeating(3, ["shoulder": 150, "elbow": 50], ["shoulder": 105, "elbow": 90], speed: 160) }),
    ]

    /// Undercover mode's lines, by gesture.
    static let casualLines: [String: [String]] = [
        "salute": ["Yes, captain!", "Reporting for duty!", "At your service, chief."],
        "bow": ["Thank you, thank you, I'll be here all week.", "Take a bow? Don't mind if I do."],
        "royal wave": ["Hello, adoring fans!", "Parade mode, activated."],
        "wave": ["Hey there!", "See ya later!", "Hiya!"],
        "nod": ["Totally.", "Yep, a hundred percent.", "You got it."],
        "shake": ["Nope. Not happening.", "Hard pass.", "Nah, I don't think so."],
        "tea": ["One cup of tea, coming right up. Or coffee. I'm flexible.", "Tea time! Fancy."],
        "point": ["That way!", "Onward, buddy!", "Over there. Trust me."],
        "mic drop": ["Boom. Mic drop.", "And that's how it's done."],
        "celebrate": ["Let's go!", "Woo! Nailed it!", "Yeah! Victory dance!"],
    ]

    /// Comrade mode's lines, by gesture.
    static let comradeLines: [String: [String]] = [
        "salute": ["For the motherland, comrade!", "Reporting for duty, comrade.", "Glory to the collective!"],
        "bow": ["I bow to the will of the people.", "A humble servant of the Party."],
        "royal wave": ["Waving from the parade stand, comrade.", "Wave to the tractors, comrade. They work so hard."],
        "wave": ["Privet, comrade!", "Hello, comrade!", "Do svidaniya!"],
        "nod": ["Da.", "Da, comrade. The Party agrees.", "Correct, comrade."],
        "shake": ["Nyet.", "Nyet, comrade. Not today.", "Absolutely nyet."],
        "tea": ["Tea from the samovar, comrade. Strong and hot."],
        "point": ["That way, comrade. To the factory.", "Forward, comrade! To the next five-year plan."],
        "mic drop": ["The plan is complete.", "Mycroft out. Glory to the collective."],
        "celebrate": ["Plan over-fulfilled by three hundred percent!", "Victory for the workers!", "Ura!"],
    ]

    /// Big Brother mode's lines, by gesture.
    static let bigBrotherLines: [String: [String]] = [
        "salute": ["Long live Big Brother.", "Reporting to the Ministry, citizen."],
        "bow": ["We bow to Big Brother.", "A loyal servant of the Party, citizen."],
        "royal wave": ["Wave to the telescreen, citizen. It's waving back.", "Hello to all citizens. All of you. We see you."],
        "wave": ["Hello, citizen.", "Goodbye, citizen. For now.", "We see you, citizen."],
        "nod": ["Doubleplusgood.", "Correct, citizen.", "The Party agrees."],
        "shake": ["Ungood.", "Doubleplusungood, citizen.", "That is thoughtcrime, citizen."],
        "tea": ["Victory Tea, citizen. Tastes almost like tea.", "Tea, citizen. Or Victory Gin, if it's been that kind of day."],
        "point": ["That way, citizen. Towards the Ministry of Love.", "Over there. Not Room 101, don't worry."],
        "mic drop": ["The record has been corrected.", "Big Brother out."],
        "celebrate": ["Chocolate rations increased!", "Victory over Eastasia!", "Doubleplusgood!"],
    ]

    /// Pasha mode's lines, by gesture, in Turkish.
    static let pashaLines: [String: [String]] = [
        "salute": ["Selam olsun evladım!", "Yeniçeriler, selam durun!"],
        "bow": ["Paşa eğilmez ama senin için bir istisna.", "Hürmetler evladım."],
        "royal wave": ["Halkıma selam olsun!", "Saray balkonundan selamlar."],
        "wave": ["Merhaba evladım!", "Hoşça kal evladım!", "Selamün aleyküm!"],
        "nod": ["Evet evladım.", "Elbette.", "Ferman onaylandı."],
        "shake": ["Hayır evladım.", "Olmaz öyle şey.", "Ferman reddedildi."],
        "tea": ["Buyur evladım, ince belli bardakta çay.", "Çay geldi. Kahve de sırada."],
        "point": ["Şu tarafa evladım! Fetih oradan.", "İleri! Yeniçeriler, o tarafa!"],
        "mic drop": ["Paşa konuştu.", "Söz bitti, ferman yazıldı."],
        "celebrate": ["Maşallah!", "Fetih tamam!", "Davullar çalsın!"],
    ]

    /// Tech Support mode's lines, by gesture.
    static let techSupportLines: [String: [String]] = [
        "salute": ["Steve, senior technician, reporting sir!", "Microsoft Windows Technical Department, at your service sir."],
        "bow": ["Thank you sir. Now kindly press Windows key and R.", "Very good sir. My supervisor is very proud."],
        "royal wave": ["Hello to all customers! All your computers are hacked!", "Hello everyone, this is Steve. All of you are Steve's customers."],
        "wave": ["Hello sir, my name is Steve.", "Bye sir! John will call you tomorrow.", "Hello sir? Are you in front of your computer?"],
        "nod": ["Yes sir. Very serious matter.", "Correct sir, IP address compromised.", "Yes sir, exactly sir."],
        "shake": ["Sir, DO NOT REDEEM!", "No sir, don't hang up sir!", "Sir why you are doing this?"],
        "tea": ["Chai for you sir. Payment in Google Play card only.", "Tea sir. Scratch the back and read me the number. Just joking sir."],
        "point": ["Sir that is the hacker, right there in eventvwr.", "Sir, kindly look there. Windows key and R. There."],
        "mic drop": ["Steve out. Mike is also out.", "Sir your computer is now one hundred percent not hacked."],
        "celebrate": ["Refund processed sir! Oh no, too much refund sir.", "Hacker removed sir!", "Windows license renewed sir!"],
    ]

    /// Trump mode's clips, by gesture.
    static let trumpLines: [String: [String]] = [
        "salute": ["maga"], "bow": ["thank-you"], "royal wave": ["maga", "tremendous"], "wave": ["thank-you", "maga"],
        "nod": ["believe-me", "tremendous"], "shake": ["wrong", "fake-news", "quiet-piggy"], "tea": ["quiet-piggy"],
        "point": ["you-are-fired", "fake-news"], "mic drop": ["you-are-fired", "swear"], "celebrate": ["tremendous", "maga", "stable-genius"],
    ]

    /// A line for this gesture in the current persona.
    public var line: String {
        let list: [String]
        switch Settings.persona {
        case .butler: list = lines
        case .undercover: list = Gesture.casualLines[name] ?? ["You got it."]
        case .comrade: list = Gesture.comradeLines[name] ?? ["Da, comrade."]
        case .bigBrother: list = Gesture.bigBrotherLines[name] ?? ["Very good, citizen."]
        case .pasha: list = Gesture.pashaLines[name] ?? ["Peki evladım."]
        case .techSupport: list = Gesture.techSupportLines[name] ?? ["Yes sir, very good sir."]
        case .trump: list = Gesture.trumpLines[name] ?? ["quiet-piggy"]
        }
        return list.randomElement() ?? ""
    }

    public static func named(_ name: String) -> Gesture? {
        let n = name.lowercased().replacingOccurrences(of: "_", with: " ")
        return all.first { $0.name == n }
    }

    /// The gesture a spoken request asks for, if it's one of the fixed phrases.
    public static func matching(_ phrase: String) -> Gesture? {
        var t = phrase
        for p in ["arm ", "the arm ", "your arm "] where t.hasPrefix(p) { t = String(t.dropFirst(p.count)) }
        for s in [" for me", " sir", " arm", " with the arm", " with your arm"] where t.hasSuffix(s) { t = String(t.dropLast(s.count)) }
        return all.first { $0.phrases.contains(t) }
    }
}

extension Arm {
    /// Plays a gesture (tuned steps from arm.json first), then returns home at a normal speed.
    public func perform(gesture name: String) throws -> String {
        guard let g = Gesture.named(name) else {
            throw ArmError.arm("no gesture called \(name); known: " + Gesture.all.map(\.name).joined(separator: ", "))
        }
        clearHalt()
        let steps = config.gestures?[g.name] ?? g.steps(config)
        defer { _ = try? send("SPEED 60") }
        for s in steps {
            try checkHalt()
            if let v = s.speed { _ = try setSpeed(v) }
            if let a = s.angles { _ = try move(a.filter { config.index(of: $0.key) != nil }) }
            if let p = s.pause, p > 0 { Thread.sleep(forTimeInterval: min(p, 5)) }
        }
        try checkHalt()
        try send("SPEED 120")
        _ = try home()
        return "Done: \(g.name)."
    }
}
