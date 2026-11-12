import Foundation
@testable import MycroftCore

// Pure checks only: Settings live in the real state.json, which the running app reads too.
func runUndercoverTests() {
    expectEqual(Lines.casual("Timer set for 25 minutes, sir."), "Timer set for 25 minutes.")
    expectEqual(Lines.casual("Sir, your 25 minute timer is up."), "Your 25 minute timer is up.")
    expectEqual(Lines.casual("Sir, you asked me to remind you to stretch."), "You asked me to remind you to stretch.")
    expectEqual(Lines.casual("Also, sir, you've reached your 80 dollar cap."), "Also, you've reached your 80 dollar cap.")
    expectEqual(Lines.casual("It's 3:05 PM, sir."), "It's 3:05 PM.")
    expectEqual(Lines.casual("Very good, sir."), "You got it.")
    expectEqual(Lines.casual("I'm afraid I can't read the battery, sir."), "I can't read the battery.")
    expectEqual(Lines.casual("Hello there"), "Hello there")

    let installed: [(name: String, locale: String)] = [("Arthur (Enhanced)", "en_GB"), ("Samantha", "en_US"), ("Ava (Enhanced)", "en_US"), ("Evan (Enhanced)", "en_US")]
    expectEqual(Speaker.pickAmerican(installed: installed), "Evan (Enhanced)")
    expectEqual(Speaker.pickAmerican(installed: installed + [("Zoe (Premium)", "en_US")]), "Zoe (Premium)")
    expectEqual(Speaker.pickAmerican(installed: [("Ava (Enhanced)", "en_US")]), "Ava (Enhanced)")
    expectEqual(Speaker.pickAmerican(installed: [("Daniel", "en_GB")]), "Samantha")

    let p = Prompts.undercover.lowercased()
    expect(p.contains("no politics") && p.contains("american") && p.contains("never \"sir\""))
    for word in ["empire", "french", "colonial", "dictator"] where !p.contains("no politics at all") { expect(!p.contains(word), word) }
    for list in [Lines.Undercover.opening, Lines.Undercover.errors, Lines.Undercover.shutdown, Lines.Undercover.offline,
                 Gesture.casualLines.values.flatMap { $0 }] {
        for l in list {
            let t = l.lowercased()
            expect(!["sir", "french", "empire", "british", "dictator", "regime", "colon"].contains { t.contains($0) }, "undercover line: \(l)")
        }
    }
    expectEqual(Set(Gesture.casualLines.keys), Set(Gesture.all.map(\.name)), "every gesture has undercover lines")
    expect(!Prompts.butler.contains("Tools:") && Prompts.tools.hasPrefix("Tools:"), "tools shared by both personas")
    expect(!Prompts.tools.contains("French"), "shared tools section has no butler jokes")

    expectEqual(Intent.parse("Go undercover."), .undercover(true))
    expectEqual(Intent.parse("Mycroft, undercover mode on"), .undercover(true))
    expectEqual(Intent.parse("Blow your cover!"), .undercover(false))
    expectEqual(Intent.parse("Turn off undercover mode please"), .undercover(false))

    expectEqual(Intent.parse("Back to normal"), .undercover(false))

    // Comrade and Big Brother.
    expectEqual(Lines.inPersona("Timer set for 25 minutes, sir.", .comrade), "Timer set for 25 minutes, comrade.")
    expectEqual(Lines.inPersona("Sir, your 25 minute timer is up.", .bigBrother), "Citizen, your 25 minute timer is up.")
    expectEqual(Lines.inPersona("Very good, sir.", .butler), "Very good, sir.")
    expectEqual(Lines.inPersona("Very good, sir.", .undercover), "You got it.")
    expectEqual(Lines.inPersona("A desire to serve.", .comrade), "A desire to serve.", "only whole words")
    for p in Persona.allCases { expectEqual(Persona(rawValue: p.rawValue), p) }
    expect(Prompts.comrade.contains("comrade") && Prompts.bigBrother.contains("citizen"))
    expect(Prompts.bigBrother.contains("Nineteen Eighty-Four") && Prompts.comrade.contains("Gagarin"))
    for list in [Lines.Comrade.opening, Lines.Comrade.errors, Lines.Comrade.shutdown, Lines.Comrade.offline, Lines.Comrade.working, Lines.Comrade.searching,
                 Lines.BigBrother.opening, Lines.BigBrother.errors, Lines.BigBrother.shutdown, Lines.BigBrother.offline, Lines.BigBrother.working, Lines.BigBrother.searching] {
        expect(list.count >= 3)
        for l in list { expect(!l.lowercased().contains("sir"), "persona line still says sir: \(l)") }
    }
    expectEqual(Set(Gesture.comradeLines.keys), Set(Gesture.all.map(\.name)), "every gesture has comrade lines")
    expectEqual(Set(Gesture.bigBrotherLines.keys), Set(Gesture.all.map(\.name)), "every gesture has Big Brother lines")
    expectEqual(Lines.forPersona("b", "u", "c", "x", "p", "m", "t", .comrade), "c")
    expectEqual(Lines.inPersona("Very good, sir.", .pasha), "Peki evladım.")
    expectEqual(Lines.inPersona("Sir, your 25 minute timer is up.", .pasha), "Evladım, zamanlayıcın doldu.")
    expectEqual(Lines.inPersona("Sir, you asked me to remind you to drink water.", .pasha), "Evladım, bana şunu hatırlatmamı istemiştin: drink water")
    expectEqual(Lines.inPersona("Timer set, sir.", .techSupport), "Timer set, sir.")
    expect(Prompts.pasha.contains("Always reply in Turkish") && Prompts.techSupport.contains("gift card"))
    for list in [Lines.Pasha.opening, Lines.Pasha.errors, Lines.Pasha.shutdown, Lines.Pasha.offline,
                 Lines.TechSupport.opening, Lines.TechSupport.errors, Lines.TechSupport.shutdown, Lines.TechSupport.offline] {
        expect(list.count >= 3)
    }
    expectEqual(Set(Gesture.pashaLines.keys), Set(Gesture.all.map(\.name)), "every gesture has Pasha lines")
    expectEqual(Set(Gesture.techSupportLines.keys), Set(Gesture.all.map(\.name)), "every gesture has Tech Support lines")
    // Trump: only clips, "Quiet, piggy" when nothing fits.
    let clips = ["quiet-piggy", "wrong", "tremendous", "you-are-fired"]
    expectEqual(TrumpClips.name(for: "Tremendous.", available: clips), "tremendous")
    expectEqual(TrumpClips.name(for: "you are fired!", available: clips), "you-are-fired")
    expectEqual(TrumpClips.name(for: "Timer set for 25 minutes, sir.", available: clips), "quiet-piggy")
    expectEqual(TrumpClips.name(for: "anything", available: ["wrong"]), "wrong", "no piggy clip: first clip")
    expectEqual(TrumpClips.name(for: "anything", available: []), nil)
    expectEqual(Lines.inPersona("Timer set, sir.", .trump), "Timer set, sir.")
    expectEqual(Lines.forPersona("b", "u", "c", "x", "p", "m", "t", .trump), "t")
    let prompt = Prompts.trump(clips: clips)
    expect(prompt.contains("- quiet-piggy:") && prompt.contains("- you-are-fired:") && prompt.contains("Quiet, quiet, piggy"))
    let known = Set(TrumpClips.meanings.keys)
    for list in [Lines.Trump.opening, Lines.Trump.errors, Lines.Trump.shutdown, Lines.Trump.offline, Lines.Trump.working, Lines.Trump.searching] + Array(Gesture.trumpLines.values) {
        expect(!list.isEmpty && list.allSatisfy(known.contains), "Trump lines are clip names: \(list)")
    }
    expectEqual(Set(Gesture.trumpLines.keys), Set(Gesture.all.map(\.name)), "every gesture has Trump clips")
    expectEqual(Speech.yesNo("Evet, devam et"), .yes)
    expectEqual(Speech.yesNo("Hayır"), .no)
}
