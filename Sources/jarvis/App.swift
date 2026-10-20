import AppKit
import Foundation
import JarvisCore

enum JState: String { case idle, listening, thinking, speaking, muted, confirming
    var symbol: String {
        switch self {
        case .idle: return "circle"
        case .listening: return "mic.fill"
        case .thinking: return "ellipsis.circle"
        case .speaking: return "speaker.wave.2.fill"
        case .muted: return "mic.slash.fill"
        case .confirming: return "questionmark.circle.fill"
        }
    }
    var label: String { rawValue.capitalized }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate, Confirming {
    let speaker = Speaker()
    let recorder = Recorder()
    let transcriber = Transcriber()
    let hotkey = Hotkey()
    var wake: WakeListener?
    var batteryPolicy = BatteryPolicy()
    var wakeLine: NSMenuItem!
    var brain: Brain!
    var statusItem: NSStatusItem!
    var statusLine: NSMenuItem!
    var spendLine: NSMenuItem!
    var muteItem: NSMenuItem!
    var modeItems: [Mode: NSMenuItem] = [:]
    var state: JState = .idle { didSet { render(); updateWake() } }
    var sessionTask: Task<Void, Never>?
    var confirmCont: CheckedContinuation<Bool, Never>?
    var greeting = false

    // Confirming is called from the Brain's tool loop (off the main actor).
    nonisolated func confirm(_ description: String) async -> Bool { await askToProceed(description) }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        brain = Brain(runner: CommandRunner(confirmer: self))
        brain.conversationLog = Paths.conversationLog
        if let raw = State.get("mode"), let m = Mode(rawValue: raw) { brain.mode = m }
        if Models.wakeWordAvailable { wake = WakeListener(); wake?.onWake = { [weak self] in self?.wakeHeard() }; wake?.onDeviceChange = { [weak self] in self?.updateWake() } }
        buildMenu()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in await self?.checkBattery() } }
        if !hotkey.register({ [weak self] in self?.hotkeyPressed() }) {
            NSLog("Jarvis: could not register ⌥ Space (already taken?)")
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.maybeGreet() }
        }
        Task {
            _ = await Recorder.requestPermission()
            if Keychain.apiKey() == nil { await say("I have no API key, sir. Run jarvis, dash dash set key, in the terminal.") }
            else if !Transcriber.available { await say("I can't hear you yet, sir. Whisper is not installed. See the setup script.") }
            await checkBattery()
            await maybeGreet()
            updateWake()
        }
    }

    // MARK: Menu bar

    func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu(); menu.delegate = self
        statusLine = NSMenuItem(title: "Jarvis", action: nil, keyEquivalent: ""); statusLine.isEnabled = false
        spendLine = NSMenuItem(title: "Spend this month", action: nil, keyEquivalent: ""); spendLine.isEnabled = false
        menu.addItem(statusLine); menu.addItem(spendLine); menu.addItem(.separator())
        wakeLine = NSMenuItem(title: "Wake word", action: nil, keyEquivalent: ""); wakeLine.isEnabled = false
        menu.addItem(wakeLine)
        menu.addItem(.separator())
        let listen = NSMenuItem(title: "Listen now  (⌥ Space)", action: #selector(listenNow), keyEquivalent: ""); listen.target = self
        menu.addItem(listen)
        muteItem = NSMenuItem(title: "Mute", action: #selector(toggleMute), keyEquivalent: ""); muteItem.target = self
        menu.addItem(muteItem); menu.addItem(.separator())
        let modeHeader = NSMenuItem(title: "Model mode", action: nil, keyEquivalent: ""); modeHeader.isEnabled = false
        menu.addItem(modeHeader)
        for m in Mode.allCases {
            let it = NSMenuItem(title: m.label, action: #selector(pickMode(_:)), keyEquivalent: ""); it.target = self
            it.representedObject = m.rawValue; modeItems[m] = it; menu.addItem(it)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Jarvis", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        render()
    }

    func render() {
        guard statusItem != nil else { return }
        let img = NSImage(systemSymbolName: state.symbol, accessibilityDescription: "Jarvis \(state.label)")
        statusItem.button?.image = img
        statusItem.button?.title = " \(brain.mode.label)"
        statusLine.title = "Jarvis — \(state.label)"
        muteItem.title = state == .muted ? "Unmute" : "Mute"
        for (m, it) in modeItems { it.state = m == brain.mode ? .on : .off }
    }

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        Task { @MainActor in
            self.wakeLine.title = self.wakeStatus()
            self.spendLine.title = "Spent this month: " + String(format: "$%.2f of $%.0f", self.brain.usage.monthTotal(), UsageTracker.cap)
        }
    }

    @objc func listenNow() { hotkeyPressed() }
    @objc func toggleMute() { if state == .muted { state = .idle } else { cancelSession(); state = .muted } }
    @objc func pickMode(_ s: NSMenuItem) {
        guard let raw = s.representedObject as? String, let m = Mode(rawValue: raw) else { return }
        setMode(m)
    }
    func setMode(_ m: Mode) { brain.mode = m; State.set("mode", m.rawValue); render() }

    // MARK: Hotkey

    func hotkeyPressed() {
        switch state {
        case .confirming: resolveConfirm(true)
        case .speaking: speaker.stop(); cancelSession(); state = .idle
        case .listening, .thinking: cancelSession(); state = .idle
        case .muted, .idle: startSession()
        }
    }

    func cancelSession() {
        sessionTask?.cancel(); sessionTask = nil
        recorder.cancel(); speaker.stop()
    }

    func startSession() {
        guard sessionTask == nil else { return }
        state = .listening          // also stops the wake listener before the recorder opens the mic
        sessionTask = Task { [weak self] in
            await self?.session()
            self?.sessionTask = nil
            self?.updateWake()
        }
    }

    // MARK: Wake word, voice lock, battery

    func wakeStatus() -> String {
        if wake == nil { return "Wake word: models missing" }
        if batteryPolicy.paused { return "Wake word: paused (battery under 20%)" }
        return state == .muted ? "Wake word: muted" : "Wake word: \"Hey Jarvis\" is on"
    }

    /// The wake listener runs only when Jarvis is idle and the battery is fine.
    func updateWake() {
        guard let wake else { return }
        let should = state == .idle && sessionTask == nil && !greeting && !batteryPolicy.paused
        if should { wake.start() } else { wake.stop() }
    }

    func wakeHeard() {
        guard state == .idle, sessionTask == nil else { return }
        NSSound(named: "Tink")?.play()
        startSession()
    }

    func checkBattery() async {
        guard let status = await Battery.current() else { return }
        switch batteryPolicy.update(status) {
        case .pause(let announce):
            updateWake()
            if announce, wake != nil, state == .idle {
                await say("Battery is below twenty percent, sir. I'll stop listening for my name until you plug in.")
            }
        case .resume: updateWake()
        case .none: break
        }
    }

    // MARK: Conversation

    func session() async {
        var first = true
        while !Task.isCancelled {
            state = .listening
            guard let wav = await recorder.record(startTimeout: first ? 8 : 5) else { break }
            state = .thinking
            let text = await transcriber.transcribe(wav)
            if text.isEmpty { if first { break } else { continue } }
            first = false
            if !(await handle(text)) { break }
        }
        if state != .muted { state = .idle }
        if !Task.isCancelled || brain.conversation.exchanges.count > 0 { Task { _ = await brain.learn() } }
    }

    /// Returns false when the conversation should end.
    func handle(_ text: String) async -> Bool {
        switch Intent.parse(text) {
        case .stop: return false
        case .mute: await say("Muted, sir. Press option space when you need me."); state = .muted; return false
        case .setMode(let m): setMode(m); await say("Using \(m.label), sir."); return true
        case .spend: await say(brain.usage.report()); return true
        case .whatDoYouKnow: await say(brain.memory.readBack()); return true
        case .forget(let p):
            let r = brain.memory.forget(p)
            await say(r.isEmpty ? "I couldn't find anything like that, sir." : "Consider it forgotten, sir.")
            return true
        case .none: break
        }
        do {
            var reply = try await brain.respond(to: text)
            reply += await capNotice()
            await say(reply)
        } catch BrainError.offline { await say("I'm afraid I'm offline, sir."); return false }
        catch BrainError.noKey { await say("I have no API key, sir."); return false }
        catch { NSLog("Jarvis error: \(error)"); await say("Something went wrong on my end, sir."); return false }
        return !Task.isCancelled
    }

    /// Spoken once per month at 90% and once at the cap.
    func capNotice() async -> String {
        let month = String(ISO8601DateFormatter().string(from: Date()).prefix(7))
        if brain.usage.capReached(), State.get("capNotice") != month {
            State.set("capNotice", month)
            return " Also, sir, you've reached your eighty dollar cap. I'll use Haiku only until the month resets."
        }
        if brain.usage.nearCap(), State.get("warnNotice") != month {
            State.set("warnNotice", month)
            return " A word of caution, sir: you're nearing your eighty dollar cap."
        }
        return ""
    }

    func say(_ text: String) async {
        let was = state
        state = .speaking
        await speaker.speak(text)
        if state == .speaking { state = was == .muted ? .muted : (sessionTask == nil ? .idle : .thinking) }
    }

    // MARK: Risky-command confirmation (spoken yes, or the hotkey)

    nonisolated func askToProceed(_ description: String) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            Task { @MainActor in
                self.confirmCont = cont
                self.state = .confirming
                await self.speaker.speak("\(description). Shall I proceed, sir?")
                guard self.confirmCont != nil else { return }
                let wav = await self.recorder.record(startTimeout: 6)
                guard self.confirmCont != nil else { return }
                var answer = false
                if let wav { answer = Speech.yesNo(await self.transcriber.transcribe(wav)) == .yes }
                self.resolveConfirm(answer)
            }
        }
    }

    func resolveConfirm(_ yes: Bool) {
        guard let c = confirmCont else { return }
        confirmCont = nil
        speaker.stop(); recorder.cancel()
        state = .thinking
        c.resume(returning: yes)
    }

    // MARK: Morning greeting and Sunday review

    func maybeGreet() async {
        guard !greeting, sessionTask == nil, state == .idle, Keychain.apiKey() != nil else { return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())
        guard State.get("lastGreeting") != today else { return }
        greeting = true; defer { greeting = false; updateWake() }
        let sunday = Calendar.current.component(.weekday, from: Date()) == 1
        state = .thinking
        let notes = Notes.recent(3)
        let prompt = """
        It is the owner's first unlock of the day. Greet them with a short good morning in character, give today's weather in Konya (use web search; just conditions and temperature in Celsius), and mention their latest notes if there are any. Two or three sentences in total, no more.

        Latest notes (may be empty):
        \(notes)
        """
        do {
            let text = try await brain.oneShot(prompt, model: .sonnet)
            State.set("lastGreeting", today)
            await say(text)
            if sunday { await weeklyReview() }
        } catch { state = .idle }   // offline or no key: stay quiet, try again at the next unlock
        if state != .muted { state = .idle }
    }

    func weeklyReview() async {
        let items = Array(brain.memory.newThisWeek().prefix(10))
        guard !items.isEmpty else { return }
        await say("It's Sunday, sir. Time for the weekly memory review. For each item, say keep or delete.")
        for line in items {
            await say("I learned: \(Memory.fact(of: line))")
            state = .listening
            var verdict: Bool?
            for _ in 0..<2 where verdict == nil {
                guard let wav = await recorder.record(startTimeout: 7) else { break }
                verdict = Speech.keepOrDelete(await transcriber.transcribe(wav))
            }
            if verdict == false { brain.memory.remove(line: line); await say("Deleted.") }
        }
        await say("That's the lot, sir.")
    }
}
