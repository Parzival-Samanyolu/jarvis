import Foundation

/// The arm's joints, limits, gripper angles and saved poses: `arm.json` in the data folder. Keep the joint
/// order and limits in step with the table in `arm/mycroft_arm/mycroft_arm.ino`.
public struct ArmConfig: Codable, Equatable {
    public struct Joint: Codable, Equatable { public var name: String; public var min: Int; public var max: Int; public var home: Int }
    public var joints: [Joint]
    public var gripperOpen: Int
    public var gripperClosed: Int
    /// Named poses: joint name -> angle. Joints left out stay where they are.
    public var poses: [String: [String: Int]]
    /// Tuned steps that replace a built-in gesture's, by gesture name ("salute", "royal wave"; see Gestures.swift).
    public var gestures: [String: [ArmStep]]? = nil

    public static let standard = ArmConfig(
        joints: [.init(name: "base", min: 0, max: 180, home: 90), .init(name: "shoulder", min: 15, max: 165, home: 90),
                 .init(name: "elbow", min: 15, max: 165, home: 90), .init(name: "wrist_pitch", min: 0, max: 180, home: 90),
                 .init(name: "wrist_roll", min: 0, max: 180, home: 90), .init(name: "gripper", min: 10, max: 120, home: 60)],
        gripperOpen: 110, gripperClosed: 20, poses: [:])

    public static func load(_ url: URL = Paths.arm) -> ArmConfig {
        guard let d = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(ArmConfig.self, from: d) else { return .standard }
        return c
    }

    public func save(_ url: URL = Paths.arm) {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? e.encode(self) { try? d.write(to: url, options: .atomic) }
    }

    /// Index of a joint by name, forgiving about spaces, case and a few everyday words.
    public func index(of raw: String) -> Int? {
        let n = raw.lowercased().replacingOccurrences(of: " ", with: "_")
        let aliases = ["hand": "gripper", "claw": "gripper", "grip": "gripper", "wrist": "wrist_pitch", "twist": "wrist_roll",
                       "waist": "base", "turn": "base", "rotate": "base", "arm": "shoulder"]
        let name = aliases[n] ?? n
        return joints.firstIndex { $0.name == name }
    }

    public func clamp(_ i: Int, _ deg: Int) -> Int { Swift.min(Swift.max(deg, joints[i].min), joints[i].max) }
}

/// A raw serial port (115200 8N1), for the Arduino's USB connection.
final class SerialPort {
    let fd: Int32

    init(path: String, baud: speed_t = speed_t(B115200)) throws {
        fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw ArmError.port("can't open \(path): \(String(cString: strerror(errno)))") }
        var t = termios()
        tcgetattr(fd, &t)
        cfmakeraw(&t)
        cfsetspeed(&t, baud)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tcsetattr(fd, TCSANOW, &t)
        _ = fcntl(fd, F_SETFL, 0)   // blocking again; reads wait in poll() with a timeout
    }

    deinit { close(fd) }

    func write(_ s: String) throws {
        let bytes = Array(s.utf8)
        guard Darwin.write(fd, bytes, bytes.count) == bytes.count else { throw ArmError.port("write failed") }
    }

    /// One line (without the newline), or nil after `timeout` seconds.
    func readLine(timeout: TimeInterval) -> String? {
        var buf: [UInt8] = []
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ms = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            guard poll(&p, 1, ms) > 0 else { continue }
            var c: UInt8 = 0
            guard Darwin.read(fd, &c, 1) == 1 else { return nil }
            if c == 10 { return String(decoding: buf, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            if c != 13 { buf.append(c) }
        }
        return nil
    }

    func drain() { while readLine(timeout: 0.05) != nil {} }
}

public enum ArmError: Error, CustomStringConvertible {
    case notConnected, port(String), arm(String)
    public var description: String {
        switch self {
        case .notConnected: return "No arm found on USB. Plug in the Arduino with the mycroft_arm sketch."
        case .port(let s): return s
        case .arm(let s): return "The arm said: \(s)"
        }
    }
}

/// The robotic arm: an Arduino running `arm/mycroft_arm`, found on USB and opened on first use.
public final class Arm: @unchecked Sendable {
    public private(set) var config: ArmConfig
    let configURL: URL
    let queue = DispatchQueue(label: "mycroft.arm")
    private var port: SerialPort?
    /// Where to look for it; replaceable in tests.
    var findPort: () -> String? = Arm.usbPort
    /// The Arduino restarts when the port opens; give it this long to say hello.
    var bootWait: TimeInterval = 4
    /// Set by `stop()`: whatever move or sequence is running gives up.
    private var halted = false
    private let flagLock = NSLock()
    private var isHalted: Bool { flagLock.withLock { halted } }
    func clearHalt() { flagLock.withLock { halted = false } }
    func checkHalt() throws { if isHalted { throw ArmError.arm("stopped by the owner") } }

    /// True once the arm has been found and opened (so "stop" never has to wait for it to boot).
    public var isConnected: Bool { queue.sync { port != nil } }

    public init(configURL: URL = Paths.arm) {
        self.configURL = configURL
        config = ArmConfig.load(configURL)
    }

    /// The first USB serial device that looks like an Arduino or a USB-serial adapter.
    static func usbPort() -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names.sorted().first { n in
            ["cu.usbmodem", "cu.usbserial", "cu.wchusbserial", "cu.SLAB_USBtoUART"].contains { n.hasPrefix($0) }
        }.map { "/dev/" + $0 }
    }

    /// Sends one command and returns what follows "OK". Reconnects once if the arm was unplugged.
    @discardableResult
    func send(_ command: String) throws -> String {
        try queue.sync {
            for attempt in 0..<2 {
                do {
                    let p = try connect()
                    try p.write(command + "\n")
                    guard let reply = p.readLine(timeout: 2) else { throw ArmError.port("no reply") }
                    if reply.hasPrefix("OK") { return String(reply.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
                    throw ArmError.arm(reply.hasPrefix("ERR") ? String(reply.dropFirst(4)) : reply)
                } catch ArmError.port where attempt == 0 {
                    port = nil   // unplugged or reset: open it again
                }
            }
            throw ArmError.notConnected
        }
    }

    private func connect() throws -> SerialPort {
        if let port { return port }
        guard let path = findPort() else { throw ArmError.notConnected }
        let p = try SerialPort(path: path)
        let deadline = Date().addingTimeInterval(bootWait)
        while Date() < deadline {
            p.drain()
            try p.write("PING\n")
            if let r = p.readLine(timeout: 0.4), r.hasPrefix("OK mycroft-arm") { port = p; return p }
        }
        throw ArmError.port("the device at \(path) doesn't answer like the Mycroft arm sketch")
    }

    // MARK: Moves

    /// Current angles by joint name.
    public func positions() throws -> [String: Int] {
        let nums = try send("POS").split(separator: " ").compactMap { Int($0) }
        return Dictionary(uniqueKeysWithValues: zip(config.joints.map(\.name), nums))
    }

    /// Starts moving joints to angles (clamped), then waits until the arm is still.
    public func move(_ angles: [String: Int]) throws -> String {
        var done: [String] = []
        for (name, deg) in angles.sorted(by: { $0.key < $1.key }) {
            guard let i = config.index(of: name) else { throw ArmError.arm("there's no joint called \(name)") }
            let d = config.clamp(i, deg)
            try send("MOVE \(i) \(d)")
            done.append("\(config.joints[i].name) \(d)\(d != deg ? " (limit)" : "")")
        }
        try waitUntilStill()
        return "Moved: " + done.joined(separator: ", ") + "."
    }

    public func nudge(_ name: String, by delta: Int) throws -> String {
        guard let i = config.index(of: name) else { throw ArmError.arm("there's no joint called \(name)") }
        let now = try positions()[config.joints[i].name] ?? config.joints[i].home
        return try move([config.joints[i].name: now + delta])
    }

    public func gripper(open: Bool) throws -> String {
        guard config.index(of: "gripper") != nil else { throw ArmError.arm("this arm has no gripper") }
        _ = try move(["gripper": open ? config.gripperOpen : config.gripperClosed])
        return open ? "Gripper open." : "Gripper closed."
    }

    public func home() throws -> String { try send("HOME"); try waitUntilStill(); return "Home." }

    public func stop() throws -> String {
        flagLock.withLock { halted = true }
        try send("STOP")
        return "Stopped."
    }

    public func relax() throws -> String { try send("RELAX"); return "Motors off; the arm is limp." }

    public func setSpeed(_ degPerSecond: Int) throws -> String {
        let v = min(max(degPerSecond, 10), 180)
        try send("SPEED \(v)")
        return "Speed \(v) degrees a second."
    }

    public func pose(_ name: String) throws -> String {
        let key = name.lowercased()
        guard let angles = config.poses[key] else {
            let known = config.poses.keys.sorted()
            throw ArmError.arm("no pose called \(name)" + (known.isEmpty ? "; none saved yet" : "; saved: " + known.joined(separator: ", ")))
        }
        _ = try move(angles)
        return "Pose \(key)."
    }

    /// Remembers where the arm is now under a name.
    public func savePose(_ name: String) throws -> String {
        let p = try positions()
        config.poses[name.lowercased()] = p
        config.save(configURL)
        return "Saved pose \(name.lowercased())."
    }

    /// Steps run in order; each waits for the arm to stop, then pauses (seconds) if asked. For waves, nods, demos.
    public func sequence(_ steps: [[String: Any]]) throws -> String {
        flagLock.withLock { halted = false }
        guard steps.count <= 40 else { throw ArmError.arm("too many steps; 40 at most") }
        for s in steps {
            if isHalted { throw ArmError.arm("stopped by the owner") }
            if let p = s["pose"] as? String { _ = try pose(p) }
            if let a = s["angles"] as? [String: Any] {
                _ = try move(a.compactMapValues { ($0 as? Int) ?? ($0 as? Double).map { Int($0) } })
            }
            if let pause = (s["pause"] as? Double) ?? (s["pause"] as? Int).map(Double.init), pause > 0 {
                Thread.sleep(forTimeInterval: min(pause, 5))
            }
        }
        return "Done \(steps.count) steps."
    }

    func waitUntilStill(timeout: TimeInterval = 15) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isHalted { throw ArmError.arm("stopped by the owner") }
            if try send("MOVING") == "0" { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    public func status() throws -> String {
        let p = try positions()
        let poses = config.poses.keys.sorted()
        return config.joints.map { "\($0.name) \(p[$0.name].map(String.init) ?? "?") (\($0.min)-\($0.max))" }.joined(separator: ", ")
            + ". Poses: " + (poses.isEmpty ? "none" : poses.joined(separator: ", ")) + "."
    }

    // MARK: Tool

    /// The `arm` tool: text for the model, and whether it failed. Blocks while the arm moves, so call off the main thread.
    public func perform(_ input: [String: Any]) -> (String, Bool) {
        let name = input["name"] as? String ?? ""
        let deg = (input["degrees"] as? Int) ?? (input["degrees"] as? Double).map { Int($0) }
        if input["action"] as? String != "stop" { flagLock.withLock { halted = false } }
        do {
            switch input["action"] as? String {
            case "move":
                guard let j = input["joint"] as? String, let deg else { return ("move needs joint and degrees.", true) }
                return (try move([j: deg]), false)
            case "nudge":
                guard let j = input["joint"] as? String, let deg else { return ("nudge needs joint and degrees.", true) }
                return (try nudge(j, by: deg), false)
            case "open_gripper": return (try gripper(open: true), false)
            case "close_gripper": return (try gripper(open: false), false)
            case "home": return (try home(), false)
            case "gesture": return (try perform(gesture: name), false)
            case "stop": return (try stop(), false)
            case "relax": return (try relax(), false)
            case "speed":
                guard let deg else { return ("speed needs degrees (per second).", true) }
                return (try setSpeed(deg), false)
            case "pose": return (try pose(name), false)
            case "save_pose":
                guard !name.isEmpty else { return ("save_pose needs a name.", true) }
                return (try savePose(name), false)
            case "sequence":
                guard let steps = input["steps"] as? [[String: Any]] else { return ("sequence needs steps.", true) }
                return (try sequence(steps), false)
            default: return (try status(), false)
            }
        } catch {
            return ("\(error)", true)
        }
    }

    /// For the tool description: the joints and their limits.
    public var summary: String {
        config.joints.map { "\($0.name) \($0.min)-\($0.max), home \($0.home)" }.joined(separator: "; ")
    }
}
