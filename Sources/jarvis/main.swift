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
    print("Jarvis (terminal). Ctrl-D to quit. Modes: 'use haiku|sonnet|opus|auto'.")
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
            print("Jarvis [\(brain.lastModel?.label ?? "?")]: \(reply)")
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
} else if args.contains("--cli") {
    Task { await runCLI(); exit(0) }
    dispatchMain()
} else {
    let app = NSApplication.shared
    let delegate = MainActor.assumeIsolated { AppController() }
    app.delegate = delegate
    app.run()
}
