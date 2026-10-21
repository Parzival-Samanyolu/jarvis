import AppKit
import MycroftCore
import SwiftUI

/// Settings… (⌘,): every change is saved to state.json and applied at once.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(app: AppController) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: SettingsModel(app: app))))
            w.title = "Mycroft Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)   // a menu-bar app has to bring itself forward
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    weak var app: AppController?
    let voices: [String]
    static let sample = "Very good, sir. Something has failed, and I shall blame the French, as is tradition."

    @Published var voice: String { didSet { Settings.voice = voice; app?.speaker.voice = voice } }
    @Published var customRate: Bool { didSet { applyRate() } }
    @Published var rate: Double { didSet { applyRate() } }
    @Published var humour: Humour { didSet { Settings.humour = humour } }
    @Published var followUp: Bool { didSet { Settings.followUp = followUp } }
    @Published var endSilence: Double { didSet { Settings.endSilence = endSilence } }
    @Published var openingLine: Bool { didSet { Settings.openingLine = openingLine } }
    @Published var shutdownLine: Bool { didSet { Settings.shutdownLine = shutdownLine } }
    @Published var briefing: Bool { didSet { Settings.briefing = briefing } }
    @Published var wakeWord: Bool { didSet { Settings.wakeWord = wakeWord; app?.updateWake() } }
    @Published var city: String
    @Published var startAtLogin: Bool { didSet { if startAtLogin != LoginItem.enabled { LoginItem.set(startAtLogin) } } }
    @Published var mode: Mode { didSet { app?.setMode(mode) } }
    @Published var fastSearch: Bool { didSet { Settings.fastSearch = fastSearch } }
    @Published var cap: Double { didSet { Settings.cap = cap } }
    @Published var facts: [String] = []
    @Published var usage: [UsageRecord] = []
    @Published var confirmWipe = false   // a model property: Command Line Tools can't run SwiftUI's @State macro

    init(app: AppController) {
        self.app = app
        // English voices, the natural-sounding downloads first.
        let english = Speaker.installed().filter { $0.locale.hasPrefix("en_") }.map(\.name)
        func rank(_ v: String) -> Int { v.contains("(Premium)") ? 0 : v.contains("(Enhanced)") ? 1 : 2 }
        voices = Array(Set(english)).sorted { (rank($0), $0) < (rank($1), $1) }
        voice = app.speaker.voice
        customRate = Settings.rate != nil
        rate = Double(Settings.rate ?? 185)
        humour = Settings.humour
        followUp = Settings.followUp
        endSilence = Settings.endSilence
        openingLine = Settings.openingLine
        shutdownLine = Settings.shutdownLine
        briefing = Settings.briefing
        wakeWord = Settings.wakeWord
        city = Settings.city
        startAtLogin = LoginItem.enabled
        mode = app.brain.mode
        fastSearch = Settings.fastSearch
        cap = Settings.cap
        refresh()
    }

    func applyRate() {
        let r = customRate ? Int(rate) : nil
        Settings.rate = r; app?.speaker.rate = r
    }
    func playSample() { app?.speaker.stop(); app?.speaker.enqueue(Self.sample) }
    func saveCity() { city = city.trimmingCharacters(in: .whitespaces); Settings.city = city; city = Settings.city }

    func refresh() {
        facts = app?.brain.memory.lines() ?? []
        usage = app?.brain.usage.monthRecords() ?? []
    }
    func delete(_ line: String) { app?.brain.memory.remove(line: line); refresh() }
    func wipeMemory() {
        guard let memory = app?.brain.memory else { return }
        for l in memory.lines() { memory.remove(line: l) }
        refresh()
    }

    var monthTotal: Double { usage.reduce(0) { $0 + $1.cost } }
    /// Per model: requests, searches, dollars.
    var byModel: [(model: String, requests: Int, searches: Int, cost: Double)] {
        Dictionary(grouping: usage, by: \.model).map { m, rs in
            (Model(rawValue: m)?.label ?? m, rs.count, rs.reduce(0) { $0 + $1.searches }, rs.reduce(0) { $0 + $1.cost })
        }.sorted { $0.cost > $1.cost }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "person.crop.circle") }
            brain.tabItem { Label("Brain & Usage", systemImage: "brain") }
            memory.tabItem { Label("Memory", systemImage: "list.bullet.rectangle") }
        }
        .padding(12)
        .frame(width: 560, height: 560)
        .onAppear { model.refresh() }
    }

    var general: some View {
        Form {
            Section("Voice") {
                HStack {
                    Picker("Voice", selection: $model.voice) { ForEach(model.voices, id: \.self) { Text($0).tag($0) } }
                    Button("Play sample") { model.playSample() }
                }
                Toggle("Custom speaking speed", isOn: $model.customRate)
                if model.customRate {
                    HStack {
                        Text("Slower").foregroundStyle(.secondary)
                        Slider(value: $model.rate, in: 130...280, step: 5) { editing in if !editing { model.playSample() } }
                        Text("Faster").foregroundStyle(.secondary)
                    }
                    Text("\(Int(model.rate)) words a minute").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Personality") {
                Picker("Jokes", selection: $model.humour) { ForEach(Humour.allCases, id: \.self) { Text($0.label).tag($0) } }
                Toggle("Opening line at launch and unlock", isOn: $model.openingLine)
                Toggle("Shutdown line on quit and sleep", isOn: $model.shutdownLine)
                Toggle("Daily briefing (weather and notes, first unlock of the day)", isOn: $model.briefing)
            }
            Section("Listening") {
                Toggle("Wake word (\"Hey Mycroft\")", isOn: $model.wakeWord)
                Toggle("Keep listening for a follow-up after each reply", isOn: $model.followUp)
                Slider(value: $model.endSilence, in: 0.5...3, step: 0.25) { Text("Wait after you stop talking") }
                Text(String(format: "%g seconds of silence ends what you say", model.endSilence)).font(.caption).foregroundStyle(.secondary)
            }
            Section("Home and startup") {
                HStack {
                    TextField("Home city", text: $model.city, prompt: Text("City, Country")).onSubmit { model.saveCity() }
                    Button("Save") { model.saveCity() }
                }
                Toggle("Start Mycroft when you log in", isOn: $model.startAtLogin)
            }
        }
        .formStyle(.grouped)
    }

    var brain: some View {
        Form {
            Section("Brain") {
                Picker("Model", selection: $model.mode) { ForEach(Mode.allCases, id: \.self) { Text($0.label).tag($0) } }
                Text("Auto uses Sonnet, and Opus when you ask it to think hard.").font(.caption).foregroundStyle(.secondary)
                Picker("Web search", selection: $model.fastSearch) {
                    Text("Fast (about 3–6 s, about 2–5¢ a search)").tag(true)
                    Text("Cheaper (about 11–16 s, about 2¢ a search)").tag(false)
                }
            }
            Section("Spending") {
                Stepper(value: $model.cap, in: 5...500, step: 5) { Text("Monthly cap: $\(Int(model.cap))") }
                ProgressView(value: min(model.monthTotal, model.cap), total: model.cap) {
                    Text(String(format: "This month: $%.2f of $%.0f", model.monthTotal, model.cap))
                }
                Text("At the cap Mycroft switches to Haiku until the month resets.").font(.caption).foregroundStyle(.secondary)
            }
            Section("This month by model") {
                if model.byModel.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
                ForEach(model.byModel, id: \.model) { row in
                    HStack {
                        Text(row.model).frame(width: 70, alignment: .leading)
                        Text("\(row.requests) requests").foregroundStyle(.secondary)
                        if row.searches > 0 { Text("· \(row.searches) searches").foregroundStyle(.secondary) }
                        Spacer()
                        Text(String(format: "$%.2f", row.cost)).monospacedDigit()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    var memory: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What Mycroft has learned about you").font(.headline)
            if model.facts.isEmpty {
                Spacer(); Text("Nothing yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity); Spacer()
            } else {
                List {
                    ForEach(model.facts, id: \.self) { line in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading) {
                                Text(Memory.fact(of: line))
                                if let d = Memory.date(of: line) { Text(d).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Button(role: .destructive) { model.delete(line) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help("Forget this")
                        }
                    }
                }
            }
            HStack {
                Text("\(model.facts.count) facts").foregroundStyle(.secondary)
                Spacer()
                Button("Forget everything…", role: .destructive) { model.confirmWipe = true }.disabled(model.facts.isEmpty)
            }
        }
        .confirmationDialog("Forget everything Mycroft has learned about you?", isPresented: $model.confirmWipe) {
            Button("Forget everything", role: .destructive) { model.wipeMemory() }
        } message: { Text("This can't be undone.") }
    }
}

/// Start at login is the LaunchAgent the installer sets up; switching it off disables it without stopping Mycroft now.
enum LoginItem {
    static let label = "com.mycroft.app"
    static var plistExists: Bool {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist")
    }
    static var enabled: Bool {
        guard plistExists else { return false }
        let out = launchctl(["print-disabled", "gui/\(getuid())"])
        return !out.split(separator: "\n").contains { $0.contains("\"\(label)\"") && ($0.contains("disabled") || $0.contains("true")) }
    }
    static func set(_ on: Bool) { _ = launchctl([on ? "enable" : "disable", "gui/\(getuid())/\(label)"]) }

    @discardableResult
    static func launchctl(_ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try? p.run(); let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }
}
