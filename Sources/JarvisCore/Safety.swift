import Foundation

public enum Risk: Equatable {
    case safe
    case risky(String)
    public var isRisky: Bool { if case .risky = self { return true }; return false }
}

/// Classifies a zsh command line. Harmless commands run instantly; risky ones need a spoken yes.
public struct SafetyChecker {
    public var home: String
    public var exists: (String) -> Bool

    public init(home: String = NSHomeDirectory(), exists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.home = home; self.exists = exists
    }

    static let alwaysRisky: [String: String] = [
        "rm": "deletes files", "rmdir": "deletes folders", "unlink": "deletes files", "srm": "deletes files",
        "sudo": "needs administrator rights", "su": "switches user", "doas": "needs administrator rights",
        "kill": "ends processes", "killall": "ends processes", "pkill": "ends processes",
        "chmod": "changes permissions", "chown": "changes ownership", "chgrp": "changes ownership",
        "diskutil": "touches disks", "hdiutil": "touches disk images", "dd": "writes raw disk data", "mkfs": "formats disks",
        "fdisk": "touches disks", "newfs": "formats disks", "tmutil": "changes backups",
        "networksetup": "changes network settings", "ifconfig": "changes network settings", "route": "changes network routes",
        "pfctl": "changes the firewall", "scutil": "changes system configuration", "airport": "changes wifi",
        "launchctl": "changes background services", "shutdown": "powers off", "reboot": "restarts", "halt": "powers off",
        "eval": "runs arbitrary code", "csrutil": "changes system protection", "spctl": "changes security policy",
        "dscl": "changes accounts", "sysadminctl": "changes accounts", "passwd": "changes passwords",
        "crontab": "changes scheduled jobs", "visudo": "edits sudoers", "mount": "mounts disks", "umount": "unmounts disks",
    ]
    static let wrappers: Set<String> = ["command", "builtin", "nohup", "time", "env", "exec", "nice", "caffeinate"]
    static let writers: Set<String> = ["touch", "mkdir", "tee", "ln", "install", "truncate", "rsync", "unzip", "tar", "git", "curl", "wget", "ditto"]

    public func classify(_ command: String) -> Risk {
        let lower = command.lowercased()
        // Piping downloads into an interpreter, and admin-privilege AppleScript.
        let pipeToShell = try! NSRegularExpression(pattern: #"\|\s*(sudo\s+)?(ba|z|da|k)?sh\b|\|\s*(sudo\s+)?(python3?|perl|ruby|node)\b"#)
        if pipeToShell.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil { return .risky("pipes a download into a shell") }
        if lower.contains("with administrator privileges") { return .risky("needs administrator rights") }
        if lower.contains("$(curl") || lower.contains("`curl") || lower.contains("<(curl") { return .risky("runs downloaded code") }

        for seg in Self.split(command) {
            let words = Self.words(seg.text)
            guard let (cmd, args) = Self.commandAndArgs(words) else { continue }
            let name = (cmd as NSString).lastPathComponent
            if let why = Self.alwaysRisky[name] { return .risky(why) }
            if ["sh", "bash", "zsh"].contains(name), args.contains("-c") { return .risky("runs a nested shell") }
            if name == "defaults", args.first == "write" || args.first == "delete" { return .risky("changes system settings") }
            if name == "mv" || name == "cp" || name == "ditto" {
                let paths = args.filter { !$0.hasPrefix("-") }
                if name == "mv" && paths.count >= 2 { if let r = outside(paths) { return r } }
                if let dest = paths.last, paths.count >= 2 {
                    let d = expand(dest)
                    if exists(d) && !Self.isDirectory(d) { return .risky("overwrites an existing file") }
                    if exists(d) && Self.isDirectory(d) {
                        for src in paths.dropLast() where exists(d + "/" + (src as NSString).lastPathComponent) { return .risky("overwrites an existing file") }
                    }
                    if let r = outside([dest]) { return r }
                }
            }
            if name == "sed" && args.contains(where: { $0.hasPrefix("-i") }) { return .risky("edits files in place") }
            if Self.writers.contains(name) || name == "cp" || name == "mv" {
                if name != "git" && name != "curl" && name != "wget", let r = outside(args.filter { !$0.hasPrefix("-") }) { return r }
                if name == "curl" || name == "wget", let o = Self.outputTarget(args), let r = outside([o]) { return r }
            }
            // Redirections anywhere in the segment.
            for target in Self.redirectTargets(seg.text) {
                if let r = outside([target]) { return r }
            }
        }
        return .safe
    }

    func expand(_ p: String) -> String {
        if p == "~" { return home }
        if p.hasPrefix("~/") { return home + String(p.dropFirst(1)) }
        if p.hasPrefix("$HOME") { return home + String(p.dropFirst(5)) }
        if p.hasPrefix("/") { return p }
        return home + "/" + p   // commands run with the home folder as cwd
    }

    /// Returns a risk if any path resolves outside the home folder.
    func outside(_ paths: [String]) -> Risk? {
        for p in paths {
            if p.contains("$") && !p.hasPrefix("$HOME") { continue }
            if p == "/dev/null" || p == "/dev/stdout" || p == "/dev/stderr" { continue }
            guard p.hasPrefix("/") || p.hasPrefix("~") || p.hasPrefix("$HOME") || p.contains("..") else { continue }
            let std = (expand(p) as NSString).standardizingPath
            if std != home && !std.hasPrefix(home + "/") { return .risky("changes files outside your home folder") }
        }
        return nil
    }

    static func isDirectory(_ p: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue
    }

    static func commandAndArgs(_ words: [String]) -> (String, [String])? {
        var i = 0
        while i < words.count {
            let w = words[i]
            if w.contains("=") && !w.hasPrefix("-") && !w.hasPrefix("/") && w.firstIndex(of: "=")! > w.startIndex && w.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil { i += 1; continue }
            if wrappers.contains(w) { i += 1; continue }
            if w == "(" || w == "{" || w == "!" { i += 1; continue }
            return (w, Array(words[(i + 1)...]))
        }
        return nil
    }

    static func outputTarget(_ args: [String]) -> String? {
        for (i, a) in args.enumerated() {
            if (a == "-o" || a == "-O" || a == "--output") && i + 1 < args.count { return args[i + 1] }
        }
        return nil
    }

    static func redirectTargets(_ seg: String) -> [String] {
        var out: [String] = []
        let re = try! NSRegularExpression(pattern: #"(?:^|[^<0-9&])(?:[12]?>>?|&>)\s*([^\s;&|<>]+)"#)
        for m in re.matches(in: seg, range: NSRange(seg.startIndex..., in: seg)) {
            if let r = Range(m.range(at: 1), in: seg) {
                let t = String(seg[r]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !t.hasPrefix("&") { out.append(t) }
            }
        }
        return out
    }

    struct Segment { var text: String }

    /// Splits on ; && || | & and newlines, outside quotes.
    static func split(_ s: String) -> [Segment] {
        var segs: [Segment] = [], cur = "", quote: Character? = nil, prev: Character = " "
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                cur.append(c)
                if c == q && !(q == "\"" && prev == "\\") { quote = nil }
            } else if c == "'" || c == "\"" {
                quote = c; cur.append(c)
            } else if c == ";" || c == "\n" || c == "|" || (c == "&" && !(i + 1 < chars.count && chars[i + 1] == ">") && !(i > 0 && (chars[i - 1] == ">" || chars[i - 1] == "<"))) {
                if !cur.trimmingCharacters(in: .whitespaces).isEmpty { segs.append(Segment(text: cur)) }
                cur = ""
                if i + 1 < chars.count && (c == "|" || c == "&") && chars[i + 1] == c { i += 1 }
            } else { cur.append(c) }
            prev = c; i += 1
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { segs.append(Segment(text: cur)) }
        return segs
    }

    /// Shell-like word split honouring quotes (quotes removed).
    static func words(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character? = nil, has = false
        var esc = false
        for c in s {
            if esc { cur.append(c); esc = false; continue }
            if c == "\\" && quote != "'" { esc = true; continue }
            if let q = quote { if c == q { quote = nil } else { cur.append(c) }; continue }
            if c == "'" || c == "\"" { quote = c; has = true; continue }
            if c == " " || c == "\t" { if has || !cur.isEmpty { out.append(cur) }; cur = ""; has = false; continue }
            cur.append(c)
        }
        if has || !cur.isEmpty { out.append(cur) }
        return out
    }
}
