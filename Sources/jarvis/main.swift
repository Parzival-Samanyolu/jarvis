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
            let start = Date()
            let live = LiveSpeech { s in
                print(String(format: "  [%.1fs] %@", Date().timeIntervalSince(start), s))
                speaker?.enqueue(s)
            }
            _ = try await brain.respond(to: line, speech: live)
            print(String(format: "Mycroft [%@] finished in %.1fs", brain.lastModel?.label ?? "?", Date().timeIntervalSince(start)))
            await speaker?.drain()
        } catch BrainError.offline {
            var reply = Lines.offline.randomElement()!
            if let action = OfflineAction.parse(line) { reply = await action.perform() }
            print("Mycroft [offline]: \(reply)")
        }
        catch { print("Error: \(error)") }
    }
    let facts = await brain.learn()
    if !facts.isEmpty { print("Learned: \(facts.joined(separator: "; "))") }
}

func words(_ s: String) -> [String] {
    s.lowercased().replacingOccurrences(of: "'", with: "").components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
}

/// Word error rate: edits needed to turn what was heard into what was said, per word said.
func wer(_ said: String, _ heard: String) -> Double {
    let a = words(said), b = words(heard)
    var d = Array(0...b.count)
    for i in 1...max(a.count, 1) where !a.isEmpty {
        var prev = d[0]; d[0] = i
        for j in stride(from: 1, through: b.count, by: 1) {
            let cur = d[j]
            d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
            prev = cur
        }
    }
    return Double(d[b.count]) / Double(max(a.count, 1))
}

func sttBench() async {
    let phrases = [
        "Open Safari and go to the BBC website", "What's the weather like in Konya today", "Mycroft, mute",
        "Make a note that I need to buy milk and eggs", "Who won the Champions League final", "Play some Daft Punk on Spotify",
        "How much have I spent this month", "Read my last note", "What's on my screen right now",
        "Turn the volume down a little", "Remind me what I asked you about earlier", "Think hard about whether I should learn French",
    ]
    let voices = ["Daniel", "Samantha", "Moira", "Rishi", "Yelda"]
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stt-bench-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var locales: [(String, Locale)] = []
    if #available(macOS 26, *) {
        for id in ["en-GB", "en-US"] {
            if let l = await LiveTranscriber.prepare(preferred: Locale(identifier: id)) { locales.append((id, l)) } else { print("Apple \(id): unavailable") }
        }
    }
    var totals: [String: (wer: Double, secs: Double, n: Int)] = [:]
    for v in voices {
        for (k, phrase) in phrases.enumerated() {
            let wav = dir.appendingPathComponent("\(v)-\(k).wav")
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = ["-v", v, "-o", wav.path, "--file-format=WAVE", "--data-format=LEI16@16000", phrase]
            try? p.run(); p.waitUntilExit()
            // Same shape as a real recording: a little silence before, the end-of-speech pause after.
            let audio = [Float](repeating: 0, count: 4800) + WAV.decode((try? Data(contentsOf: wav)) ?? Data()) + [Float](repeating: 0, count: 12000)
            var row = "\(v.padding(toLength: 9, withPad: " ", startingAt: 0)) \(phrase.prefix(30).padding(toLength: 31, withPad: " ", startingAt: 0))"
            func note(_ name: String, _ heard: String, _ secs: Double) {
                let e = wer(phrase, heard)
                let t = totals[name] ?? (0, 0, 0); totals[name] = (t.wer + e, t.secs + secs, t.n + 1)
                row += String(format: " | %@ %3.0f%% %.2fs", name, e * 100, secs)
                if e > 0 { row += " \"\(heard)\"" }
            }
            if Transcriber.whisperAvailable {
                let copy = dir.appendingPathComponent("w-\(v)-\(k).wav")
                try? WAV.encode(audio).write(to: copy)
                let t0 = Date(); let heard = await Transcriber.whisper(copy)
                note("whisper", heard, Date().timeIntervalSince(t0))
            }
            if #available(macOS 26, *) {
                for (id, l) in locales {
                    let live = LiveTranscriber(locale: l)
                    // Fed in real time, 100 ms at a time, like the mic.
                    var i = 0
                    while i < audio.count {
                        live.feed(Array(audio[i..<min(i + 1600, audio.count)])); i += 1600
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    let t0 = Date(); let heard = (try? await live.finish()) ?? "(error)"
                    note("apple-" + id, heard, Date().timeIntervalSince(t0))
                }
            }
            print(row)
        }
    }
    print("\nAverages (word error rate, wait after you stop talking):")
    for (k, t) in totals.sorted(by: { $0.key < $1.key }) {
        print(String(format: "  %-13@ %5.1f%%  %.2fs", k, t.wer / Double(t.n) * 100, t.secs / Double(t.n)))
    }
    try? FileManager.default.removeItem(at: dir)
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
} else if let i = args.firstIndex(of: "--test-hear") {
    // Diagnostic: the Mac says a request aloud; the real mic and the app's live transcription path write it down.
    let phrase = i + 1 < args.count ? args[i + 1] : "What's the weather like in Konya today?"
    Task { @MainActor in
        let t = Transcriber(); await t.prepare()
        print("mic: \(Recorder.currentMicName)")
        let live = t.begin()
        print("live transcription: \(live == nil ? "no (Whisper)" : "yes (Apple)")")
        let rec = Recorder()
        Task.detached { try? await Task.sleep(nanoseconds: 600_000_000); let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/say"); p.arguments = [phrase]; try? p.run(); p.waitUntilExit() }
        guard let wav = await rec.record(startTimeout: 6, onAudio: live.map { l in { l.feed($0) } }) else { print("RESULT: nothing heard"); exit(1) }
        let t0 = Date()
        let text = await t.transcribe(wav, live: live)
        print(String(format: "RESULT: \"%@\" (%.2fs after recording ended)", text, Date().timeIntervalSince(t0)))
        exit(0)
    }
    dispatchMain()
} else if args.contains("--stt-bench") {
    // Diagnostic: Whisper vs Apple's live transcriber on synthetic voices with different accents.
    Task { await sttBench(); exit(0) }
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
