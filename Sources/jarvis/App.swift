import AppKit
import Foundation
import IOKit.pwr_mgt
import JarvisCore

enum JState: String { case idle, listening, thinking, speaking, muted, confirming
    var symbol: String {
        switch self {
        case .idle: return "butler"     // drawn by ButlerGlyph, not an SF Symbol
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
    var lines = LinePicker()
    var lastOpening: Date?
    var quitting = false
    var boundedID = 0, speakingBounded = false
    let sleepWatcher = SleepWatcher()

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
            Task { @MainActor in await self?.opening() }
        }
        sleepWatcher.onWillSleep = { [weak self] done in self?.goingToSleep(done) ?? done() }
        sleepWatcher.start()
        Task {
            _ = await Recorder.requestPermission()
            await opening()
            if Keychain.apiKey() == nil { await say("I have no API key, sir. Run jarvis, dash dash set key, in the terminal.") }
            else if !Transcriber.available { await say("I can't hear you yet, sir. Whisper is not installed. See the setup script.") }
            await checkBattery()
            updateWake()
        }
    }

    // MARK: Menu bar

    func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu(); menu.delegate = self
        statusLine = NSMenuItem(title: "Mycroft", action: nil, keyEquivalent: ""); statusLine.isEnabled = false
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
        menu.addItem(NSMenuItem(title: "Quit Mycroft", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        render()
    }

    func render() {
        guard statusItem != nil else { return }
        let img = state == .idle ? ButlerGlyph.image : NSImage(systemSymbolName: state.symbol, accessibilityDescription: "Mycroft \(state.label)")
        statusItem.button?.image = img
        statusItem.button?.title = " \(brain.mode.label)"
        statusLine.title = "Mycroft — \(state.label)"
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
        return state == .muted ? "Wake word: muted" : "Wake word: \"\(Models.wakePhrase)\" is on"
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
            _ = try await brain.respond(to: text, speech: liveSpeech())
            let notice = await capNotice()
            if !notice.isEmpty { speaker.enqueue(notice) }
            await speaker.drain()
            if state == .speaking { state = .thinking }
        } catch {
            if Task.isCancelled { return false }   // the hotkey stopped it; say nothing
            await speaker.drain()
            switch error {
            case BrainError.offline: await say(Lines.offline)
            case BrainError.noKey: await say("I have no API key, sir.")
            default: NSLog("Jarvis error: \(error)"); await say(lines.error())
            }
            return false
        }
        return !Task.isCancelled
    }

    /// Speaks each sentence as soon as it streams in, and shows the speaking state.
    func liveSpeech() -> LiveSpeech {
        LiveSpeech { [weak self] sentence in
            self?.speaker.enqueue(sentence)
            Task { @MainActor in if self?.state == .thinking { self?.state = .speaking } }
        }
    }

    /// Spoken once per month at 90% and once at the cap.
    func capNotice() async -> String {
        let month = String(ISO8601DateFormatter().string(from: Date()).prefix(7))
        if brain.usage.capReached(), State.get("capNotice") != month {
            State.set("capNotice", month)
            return "Also, sir, you've reached your eighty dollar cap. I'll use Haiku only until the month resets."
        }
        if brain.usage.nearCap(), State.get("warnNotice") != month {
            State.set("warnNotice", month)
            return "A word of caution, sir: you're nearing your eighty dollar cap."
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

    // MARK: Opening line, daily briefing and Sunday review

    /// At every launch and unlock: a fixed opening line, then the briefing if it's the first one today.
    func opening() async {
        guard !greeting, !quitting, sessionTask == nil, state == .idle else { return }
        if let t = lastOpening, Date().timeIntervalSince(t) < 60 { return }   // logging in fires launch and unlock together
        lastOpening = Date()
        greeting = true; defer { greeting = false; updateWake() }
        await say(lines.opening())
        await briefing()
        if state != .muted { state = .idle }
    }

    func briefing() async {
        guard Keychain.apiKey() != nil else { return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())
        guard State.get("lastGreeting") != today else { return }
        let sunday = Calendar.current.component(.weekday, from: Date()) == 1
        state = .thinking
        let notes = Notes.recent(3)
        let prompt = """
        It is the owner's first time at the Mac today, and you have just greeted them, so do not greet them again. Give today's weather in Konya (use web search; just conditions and temperature in Celsius), and mention their latest notes if there are any. Two sentences in total, no more.

        Latest notes (may be empty):
        \(notes)
        """
        do {
            _ = try await brain.oneShot(prompt, model: .sonnet, speech: liveSpeech())
            State.set("lastGreeting", today)
            await speaker.drain()
            if sunday { await weeklyReview() }
        } catch { state = .idle }   // offline or no key: stay quiet, try again at the next unlock
    }

    // MARK: Shutdown line (quit, logout, sleep)

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateNow }
        quitting = true
        resolveConfirm(false); cancelSession()
        Task {
            await speakBounded(lines.shutdown())
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// macOS holds sleep until `done` is called (it gives up after about 30 seconds).
    func goingToSleep(_ done: @escaping () -> Void) {
        guard !quitting, state != .muted else { done(); return }
        resolveConfirm(false); cancelSession(); state = .idle
        Task {
            await speakBounded(lines.shutdown())
            done()
        }
    }

    /// Speaks, but never holds up quitting or sleeping for more than 10 seconds.
    func speakBounded(_ text: String) async {
        boundedID += 1
        let id = boundedID
        // The deadline clock pauses while asleep, so only stop if this same line is still playing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            if self?.boundedID == id, self?.speakingBounded == true { self?.speaker.stop() }
        }
        state = .speaking; speakingBounded = true
        await speaker.speak(text)
        speakingBounded = false; state = .idle
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

/// Tells the app before the Mac sleeps and lets it delay sleep until a line is spoken.
@MainActor
final class SleepWatcher {
    // IOKit message codes (iokit_common_msg macros, which Swift can't import).
    static let canSystemSleep: UInt32 = 0xE000_0270
    static let systemWillSleep: UInt32 = 0xE000_0280

    var onWillSleep: ((@escaping () -> Void) -> Void)?
    private var root: io_connect_t = 0
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0

    func start() {
        let me = Unmanaged.passUnretained(self).toOpaque()
        root = IORegisterForSystemPower(me, &port, { refcon, _, type, arg in
            guard let refcon else { return }
            MainActor.assumeIsolated {   // the port is scheduled on the main queue below
                Unmanaged<SleepWatcher>.fromOpaque(refcon).takeUnretainedValue().handle(type, arg)
            }
        }, &notifier)
        guard root != 0, let port else { NSLog("Jarvis: could not register for sleep notifications"); return }
        IONotificationPortSetDispatchQueue(port, .main)
    }

    private func handle(_ type: UInt32, _ arg: UnsafeMutableRawPointer?) {
        let id = Int(bitPattern: arg), root = root
        switch type {
        case Self.canSystemSleep: IOAllowPowerChange(root, id)
        case Self.systemWillSleep:
            if let onWillSleep { onWillSleep { IOAllowPowerChange(root, id) } } else { IOAllowPowerChange(root, id) }
        default: break
        }
    }
}

/// Menu-bar icon: a bowler hat, monocle and moustache, drawn as a template so it follows light and dark mode.
enum ButlerGlyph {
    static let image: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            // Crown and brim of the bowler.
            let crown = NSBezierPath()
            crown.move(to: NSPoint(x: 4.6, y: 11.2))
            crown.curve(to: NSPoint(x: 9, y: 17), controlPoint1: NSPoint(x: 4.4, y: 15), controlPoint2: NSPoint(x: 6.4, y: 17))
            crown.curve(to: NSPoint(x: 13.4, y: 11.2), controlPoint1: NSPoint(x: 11.6, y: 17), controlPoint2: NSPoint(x: 13.6, y: 15))
            crown.close(); crown.fill()
            NSBezierPath(roundedRect: NSRect(x: 1.5, y: 10, width: 15, height: 2), xRadius: 1, yRadius: 1).fill()
            // Plain eye on the left, monocle on the right.
            NSBezierPath(ovalIn: NSRect(x: 4.9, y: 6.4, width: 2, height: 2)).fill()
            let mono = NSBezierPath(ovalIn: NSRect(x: 9.4, y: 4.9, width: 5, height: 5)); mono.lineWidth = 1.3; mono.stroke()
            NSBezierPath(ovalIn: NSRect(x: 11.1, y: 6.6, width: 1.6, height: 1.6)).fill()
            // Handlebar moustache, mirrored about the centre.
            for flip in [1.0, -1.0] {
                let m = NSBezierPath()
                m.move(to: NSPoint(x: 9, y: 3.6))
                m.curve(to: NSPoint(x: 9 + 5.2 * flip, y: 2.6), controlPoint1: NSPoint(x: 9 + 1.8 * flip, y: 4.4), controlPoint2: NSPoint(x: 9 + 3.6 * flip, y: 2.4))
                m.curve(to: NSPoint(x: 9 + 5.6 * flip, y: 4.6), controlPoint1: NSPoint(x: 9 + 6.4 * flip, y: 2.8), controlPoint2: NSPoint(x: 9 + 6.4 * flip, y: 4.0))
                m.curve(to: NSPoint(x: 9 + 4.4 * flip, y: 1.4), controlPoint1: NSPoint(x: 9 + 6.4 * flip, y: 2.6), controlPoint2: NSPoint(x: 9 + 5.6 * flip, y: 1.4))
                m.curve(to: NSPoint(x: 9, y: 2.4), controlPoint1: NSPoint(x: 9 + 2.8 * flip, y: 1.4), controlPoint2: NSPoint(x: 9 + 1.4 * flip, y: 2.0))
                m.close(); m.fill()
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Mycroft Idle"
        return img
    }()
}
