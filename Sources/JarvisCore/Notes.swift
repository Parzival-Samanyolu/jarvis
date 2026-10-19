import Foundation

/// Notes app integration through AppleScript, in a "Jarvis" folder.
public enum Notes {
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func osascript(_ script: String) -> (ok: Bool, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (false, "\(error)") }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (p.terminationStatus == 0, out)
    }

    static let ensureFolder = """
    tell application "Notes"
      if not (exists folder "Jarvis") then make new folder with properties {name:"Jarvis"}
    end tell
    """

    public static func saveScript(_ text: String) -> String {
        let title = String(text.prefix(40))
        return ensureFolder + """

        tell application "Notes"
          tell folder "Jarvis"
            make new note with properties {name:"\(esc(title))", body:"\(esc(text))"}
          end tell
        end tell
        return "saved"
        """
    }

    public static func save(_ text: String) -> String {
        let r = osascript(saveScript(text)); return r.ok ? "Saved." : "Error: \(r.out)"
    }

    /// Latest `n` notes, newest first, separated by blank lines.
    public static func recent(_ n: Int) -> String {
        let r = osascript(ensureFolder + """

        tell application "Notes"
          set out to ""
          set ns to notes of folder "Jarvis"
          set c to count of ns
          set i to 0
          repeat with nt in ns
            set i to i + 1
            if i > \(n) then exit repeat
            set out to out & (plaintext of nt) & "\\n---\\n"
          end repeat
          return out
        end tell
        """)
        if !r.ok { return "Error: \(r.out)" }
        return r.out.isEmpty ? "No notes yet." : r.out
    }

    public static func last() -> String { recent(1) }

    public static func search(_ query: String) -> String {
        let r = osascript(ensureFolder + """

        tell application "Notes"
          set out to ""
          repeat with nt in (notes of folder "Jarvis")
            set t to plaintext of nt
            if t contains "\(esc(query))" then set out to out & t & "\\n---\\n"
          end repeat
          return out
        end tell
        """)
        if !r.ok { return "Error: \(r.out)" }
        return r.out.isEmpty ? "No matching notes." : r.out
    }
}
