import AppKit
import Foundation
import JarvisCore

struct TerminalConfirmer: Confirming {
    func confirm(_ description: String) async -> Bool {
        print("⚠️  \(description). Shall I proceed, sir? [y/N] ", terminator: "")
        return (readLine() ?? "").lowercased().hasPrefix("y")
    }
}

func runCLI() async {
    guard Keychain.apiKey() != nil else {
        print("No API key. Run `jarvis --set-key` or set ANTHROPIC_API_KEY."); return
    }
    let brain = Brain(runner: CommandRunner(confirmer: TerminalConfirmer()))
    let speaker = CommandLine.arguments.contains("--speak") ? Speaker() : nil
    print("Mycroft (terminal). Ctrl-D to quit. Modes: 'use haiku|sonnet|opus|auto'.")
    while true {
        print("\n> ", terminator: "")
        guard let line = readLine(), !line.isEmpty else { if feof(stdin) != 0 { break }; continue }
        switch Intent.parse(line) {
        case .setMode(let m): brain.mode = m; print("Mode: \(m.label)"); continue
        case .spend: print(brain.usage.report()); continue
        case .whatDoYouKnow: print(brain.memory.readBack()); continue
        case .forget(let p): let r = brain.memory.forget(p); print(r.isEmpty ? "Nothing matched." : "Forgotten: \(r.joined(separator: "; "))"); continue
        default: break
        }
        do {
            let reply = try await brain.respond(to: line)
            print("Mycroft [\(brain.lastModel?.label ?? "?")]: \(reply)")
            if let speaker { await speaker.speak(reply) }
        } catch BrainError.offline { print("I'm afraid I'm offline, sir.") }
        catch { print("Error: \(error)") }
    }
    let facts = await brain.learn()
    if !facts.isEmpty { print("Learned: \(facts.joined(separator: "; "))") }
}

let args = CommandLine.arguments
if args.contains("--set-key") {
    print("Paste Anthropic API key: ", terminator: "")
    if let k = readLine(), !k.isEmpty { print(Keychain.setAPIKey(k.trimmingCharacters(in: .whitespaces)) ? "Stored in Keychain." : "Keychain write failed.") }
} else if let i = args.firstIndex(of: "--test-record") {
    // Diagnostic: same path as enrolment (speak, then a fixed-length recording) on the current mic.
    let secs = i + 1 < args.count ? Double(args[i + 1]) ?? 5 : 5
    Task { @MainActor in
        print("mic: \(Recorder.currentMicName)")
        await Speaker().speak("Testing the microphone.")
        NSSound(named: "Tink")?.play()
        try? await Task.sleep(nanoseconds: 400_000_000)
        let start = Date()
        guard let wav = await Recorder().record(startTimeout: 5, fixed: secs) else { print("RESULT: no recording"); exit(1) }
        let samples = WAV.decode((try? Data(contentsOf: wav)) ?? Data())
        try? FileManager.default.removeItem(at: wav)
        let rms = EndpointDetector.rms(samples[...])
        print(String(format: "RESULT: %.1fs of audio in %.1fs, rms %.4f, voiced %.1fs", Double(samples.count) / 16000, Date().timeIntervalSince(start), rms, Voiceprint.voicedSeconds(samples)))
        exit(0)
    }
    dispatchMain()
} else if args.contains("--cli") {
    Task { await runCLI(); exit(0) }
    dispatchMain()
} else {
    let app = NSApplication.shared
    let delegate = MainActor.assumeIsolated { AppController() }
    app.delegate = delegate
    app.run()
}
