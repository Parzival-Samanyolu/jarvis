import Foundation
@testable import MycroftCore

/// A pretend Arduino on a pseudo-terminal, speaking the mycroft_arm protocol. Moves finish at once.
final class FakeArm: @unchecked Sendable {
    let master: Int32
    let path: String
    var angles = [90, 90, 90, 90, 90, 60]
    let limits = [(0, 180), (15, 165), (15, 165), (0, 180), (0, 180), (10, 120)]
    var log: [String] = []
    let lock = NSLock()

    init() {
        var m: Int32 = 0, s: Int32 = 0
        var name = [CChar](repeating: 0, count: 128)
        openpty(&m, &s, &name, nil, nil)
        master = m; path = String(cString: name)
        Thread.detachNewThread { [self] in serve() }
    }

    func serve() {
        var buf: [UInt8] = []
        var c: UInt8 = 0
        while read(master, &c, 1) == 1 {
            if c != 10 { if c != 13 { buf.append(c) }; continue }
            let line = String(decoding: buf, as: UTF8.self); buf = []
            lock.withLock { log.append(line) }
            let w = line.split(separator: " ").map(String.init)
            var reply = "OK"
            switch w.first {
            case "PING": reply = "OK mycroft-arm 6"
            case "MOVE":
                let i = Int(w[1])!, d = Int(w[2])!
                let v = min(max(d, limits[i].0), limits[i].1)
                lock.withLock { angles[i] = v }; reply = "OK \(v)"
            case "HOME": lock.withLock { angles = [90, 90, 90, 90, 90, 60] }
            case "POS": reply = "OK " + lock.withLock { angles.map(String.init).joined(separator: " ") }
            case "MOVING": reply = "OK 0"
            case "STOP", "SPEED", "RELAX": break
            default: reply = "ERR unknown command"
            }
            _ = (reply + "\r\n").withCString { write(master, $0, strlen($0)) }
        }
    }
    var commands: [String] { lock.withLock { log } }
}

func runArmTests() {
    let fake = FakeArm()
    let arm = Arm(configURL: tmp("arm.json"))
    arm.findPort = { fake.path }
    arm.bootWait = 2

    var (r, failed) = arm.perform(["action": "status"])
    expect(!failed, r); expect(r.hasPrefix("base 90 (0-180), shoulder 90 (15-165)"), r)
    (r, failed) = arm.perform(["action": "move", "joint": "base", "degrees": 30])
    expect(!failed); expectEqual(r, "Moved: base 30.")
    (r, _) = arm.perform(["action": "move", "joint": "elbow", "degrees": 200])
    expectEqual(r, "Moved: elbow 165 (limit).", "clamped on the Mac too")
    (r, _) = arm.perform(["action": "nudge", "joint": "base", "degrees": -10])
    expectEqual(r, "Moved: base 20.")
    (r, _) = arm.perform(["action": "close_gripper"])
    expectEqual(r, "Gripper closed."); expectEqual(fake.angles[5], 20)
    (r, _) = arm.perform(["action": "move", "joint": "hand", "degrees": 100])
    expectEqual(r, "Moved: gripper 100.", "alias")
    (r, failed) = arm.perform(["action": "move", "joint": "tail", "degrees": 5])
    expect(failed); expect(r.contains("no joint called tail"), r)
    (r, _) = arm.perform(["action": "save_pose", "name": "Wave"])
    expectEqual(r, "Saved pose wave.")
    expectEqual(ArmConfig.load(arm.configURL).poses["wave"]?["base"], 20, "pose saved to disk")
    _ = arm.perform(["action": "home"])
    expectEqual(fake.angles, [90, 90, 90, 90, 90, 60])
    (r, _) = arm.perform(["action": "pose", "name": "wave"])
    expectEqual(r, "Pose wave."); expectEqual(fake.angles[0], 20)
    (r, failed) = arm.perform(["action": "pose", "name": "dance"])
    expect(failed); expect(r.contains("saved: wave"), r)
    (r, failed) = arm.perform(["action": "sequence", "steps": [["angles": ["wrist_roll": 60]], ["angles": ["wrist_roll": 120], "pause": 0.05], ["pose": "wave"]]])
    expect(!failed, r); expectEqual(r, "Done 3 steps.")
    expect(fake.commands.contains("MOVE 4 60") && fake.commands.contains("MOVE 4 120"))
    expect(arm.isConnected)
    (r, _) = arm.perform(["action": "stop"]); expectEqual(r, "Stopped.")
    (r, failed) = arm.perform(["action": "sequence", "steps": [["angles": ["base": 10]]]])
    expect(!failed, "a new request runs after a stop: \(r)")

    // no arm plugged in
    let none = Arm(configURL: tmp("arm2.json")); none.findPort = { nil }
    (r, failed) = none.perform(["action": "home"])
    expect(failed); expect(r.hasPrefix("No arm found"), r)
    expect(!none.isConnected)

    expectEqual(Intent.parse("Stop the arm!"), .armStop)
    expectEqual(Intent.parse("Mycroft, open the gripper"), .armGripper(open: true))
    expectEqual(Intent.parse("Grab it."), .armGripper(open: false))
    expectEqual(Intent.parse("Home the arm please"), .armHome)
    expectEqual(Intent.parse("Mycroft, salute!"), .armGesture("salute"))
    expectEqual(Intent.parse("Give me a salute"), .armGesture("salute"))
    expectEqual(Intent.parse("Take a bow."), .armGesture("bow"))
    expectEqual(Intent.parse("Do the royal wave please"), .armGesture("royal wave"))
    expectEqual(Intent.parse("Pour me some tea"), .armGesture("tea"))
    expectEqual(Intent.parse("Mic drop!"), .armGesture("mic drop"))
    expectEqual(Intent.parse("Wave at me"), .armGesture("wave"))
    expectEqual(Intent.parse("What's the capital of France"), .none)
    // every gesture runs on the fake arm, stays inside the limits and ends at home
    for g in Gesture.all {
        let before = fake.commands.count
        (r, failed) = arm.perform(["action": "gesture", "name": g.name])
        expect(!failed, "\(g.name): \(r)"); expectEqual(r, "Done: \(g.name).")
        let sent = Array(fake.commands[before...])
        expect(sent.contains("HOME"), "\(g.name) goes home")
        expectEqual(sent.last(where: { $0.hasPrefix("SPEED") }), "SPEED 60", "\(g.name) puts the speed back")
        expect(!g.lines.isEmpty && !g.phrases.isEmpty)
        for step in g.steps(arm.config) { for (j, _) in step.angles ?? [:] { expect(arm.config.index(of: j) != nil, "\(g.name): joint \(j)") } }
    }
    let sent = Array(fake.commands.suffix(400))
    expect(sent.contains("MOVE 1 140"), "salute raises the shoulder")
    (r, failed) = arm.perform(["action": "gesture", "name": "moonwalk"])
    expect(failed); expect(r.contains("known: salute, bow"), r)
    // tuned steps in arm.json replace the built-in ones
    var tuned = arm.config; tuned.gestures = ["bow": [ArmStep(["shoulder": 33])]]; tuned.save(arm.configURL)
    let arm2 = Arm(configURL: arm.configURL); arm2.findPort = { fake.path }; arm2.bootWait = 2
    let n2 = fake.commands.count
    _ = arm2.perform(["action": "gesture", "name": "bow"])
    expect(fake.commands[n2...].contains("MOVE 1 33") && !fake.commands[n2...].contains("MOVE 1 50"), "tuned bow")
    expectEqual(fake.angles, [90, 90, 90, 90, 90, 60], "ends at home")
}
