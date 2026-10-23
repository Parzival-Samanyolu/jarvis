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
    expect(Prompts.bigBrother.contains("Nineteen Eighty-Four") && Prompts.comrade.contains("KGB"))
    for list in [Lines.Comrade.opening, Lines.Comrade.errors, Lines.Comrade.shutdown, Lines.Comrade.offline, Lines.Comrade.working, Lines.Comrade.searching,
                 Lines.BigBrother.opening, Lines.BigBrother.errors, Lines.BigBrother.shutdown, Lines.BigBrother.offline, Lines.BigBrother.working, Lines.BigBrother.searching] {
        expect(list.count >= 3)
        for l in list { expect(!l.lowercased().contains("sir"), "persona line still says sir: \(l)") }
    }
    expectEqual(Set(Gesture.comradeLines.keys), Set(Gesture.all.map(\.name)), "every gesture has comrade lines")
    expectEqual(Set(Gesture.bigBrotherLines.keys), Set(Gesture.all.map(\.name)), "every gesture has Big Brother lines")
    expectEqual(Lines.forPersona("b", "u", "c", "x", .comrade), "c")
}
