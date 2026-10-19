import Foundation

public protocol Confirming {
    /// Ask the owner out loud ("Shall I proceed, sir?"). A spoken yes or the hotkey returns true.
    func confirm(_ description: String) async -> Bool
}

public struct CommandResult {
    public var output: String
    public var exitCode: Int32
    public var declined = false
}

/// `run_command`: zsh shell with safety check, confirmation, logging, secret stripping and a retry cap.
public final class CommandRunner {
    public static let maxRetries = 2
    public static let maxOutput = 6000

    let safety: SafetyChecker
    let confirmer: Confirming
    let logURL: URL
    var failuresThisRequest = 0

    public init(safety: SafetyChecker = SafetyChecker(), confirmer: Confirming, logURL: URL = Paths.commandLog) {
        self.safety = safety; self.confirmer = confirmer; self.logURL = logURL
    }

    /// Call at the start of every user request.
    public func beginRequest() { failuresThisRequest = 0 }

    public func run(_ command: String) async -> CommandResult {
        if failuresThisRequest > Self.maxRetries {
            log(command, "SKIPPED retry limit")
            return CommandResult(output: "Retry limit reached. Stop trying and report the problem to the owner in one line.", exitCode: 1)
        }
        if case .risky(let why) = safety.classify(command) {
            log(command, "RISKY (\(why)) – asking")
            let ok = await confirmer.confirm("This \(why)")
            guard ok else {
                log(command, "DECLINED")
                return CommandResult(output: "The owner declined to run this command. Do not retry it or work around it; acknowledge briefly.", exitCode: 126, declined: true)
            }
            log(command, "APPROVED")
        }
        let r = await Self.execute(command)
        log(command, "exit \(r.exitCode)")
        if r.exitCode != 0 { failuresThisRequest += 1 }
        var out = SecretStripper.strip(r.output)
        if out.count > Self.maxOutput { out = String(out.prefix(Self.maxOutput)) + "\n[output truncated]" }
        if out.isEmpty { out = r.exitCode == 0 ? "(no output)" : "(no output)" }
        return CommandResult(output: "exit code \(r.exitCode)\n" + out, exitCode: r.exitCode)
    }

    static func execute(_ command: String, timeout: TimeInterval = 30) async -> CommandResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-c", command]
                p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
                p.standardInput = FileHandle.nullDevice
                var data = Data()
                let lock = NSLock()
                pipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData; lock.lock(); data.append(d); lock.unlock()
                }
                do { try p.run() } catch { cont.resume(returning: CommandResult(output: "\(error)", exitCode: 127)); return }
                let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                p.waitUntilExit(); timer.cancel()
                pipe.fileHandleForReading.readabilityHandler = nil
                lock.lock(); data.append(pipe.fileHandleForReading.readDataToEndOfFile()); let d = data; lock.unlock()
                cont.resume(returning: CommandResult(output: String(decoding: d, as: UTF8.self), exitCode: p.terminationStatus))
            }
        }
    }

    func log(_ command: String, _ note: String) {
        let f = ISO8601DateFormatter()
        let line = "\(f.string(from: Date()))\t\(note)\t\(command.replacingOccurrences(of: "\n", with: "\\n"))\n"
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: logURL, atomically: true, encoding: .utf8) }
    }
}

public enum Screen {
    /// Silent screenshot, resized so the long side is <= 1568px, returned as base64 PNG.
    public static func capture() async -> String? {
        let raw = NSTemporaryDirectory() + "jarvis-screen-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: raw) }
        let r = await CommandRunner.execute("/usr/sbin/screencapture -x -t png '\(raw)' && /usr/bin/sips -Z 1568 '\(raw)' >/dev/null 2>&1", timeout: 15)
        guard r.exitCode == 0, let d = FileManager.default.contents(atPath: raw), d.count > 1000 else { return nil }
        return d.base64EncodedString()
    }
}

public enum Battery {
    public struct Status: Equatable { public var percent: Int; public var charging: Bool }
    public static func parse(_ pmset: String) -> Status? {
        guard let m = pmset.range(of: #"(\d+)%"#, options: .regularExpression) else { return nil }
        let pct = Int(pmset[m].dropLast()) ?? 0
        let onAC = pmset.contains("AC Power")
        return Status(percent: pct, charging: onAC)
    }
    public static func current() async -> Status? {
        parse((await CommandRunner.execute("pmset -g batt", timeout: 5)).output)
    }
}
