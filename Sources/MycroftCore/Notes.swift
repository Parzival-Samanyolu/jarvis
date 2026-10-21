import Foundation

/// Notes app integration through AppleScript, in a "Mycroft" folder.
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

    /// Creates the folder; one that is still called "Jarvis" (the name before the rename) is renamed, notes and all.
    static let ensureFolder = """
    tell application "Notes"
      if not (exists folder "Mycroft") then
        if exists folder "Mycroft" then
          set name of folder "Mycroft" to "Mycroft"
        else
          make new folder with properties {name:"Mycroft"}
        end if
      end if
    end tell
    """

    public static func saveScript(_ text: String) -> String {
        let title = String(text.prefix(40))
        return ensureFolder + """

        tell application "Notes"
          tell folder "Mycroft"
            make new note with properties {name:"\(esc(title))", body:"\(esc(text))"}
          end tell
        end tell
        return "saved"
        """
    }

    public static func save(_ text: String) -> String {
        let r = osascript(saveScript(text)); return r.ok ? "Saved." : "Error: \(r.out)"
    }

    /// Record and field separators for `recent`, which note text will not contain.
    static let rs = "\u{1E}", fs = "\u{1F}"

    /// Latest `n` notes, newest first, separated by blank lines.
    /// Notes does not promise any order, so each note comes back with its age in seconds and is sorted here.
    public static func recent(_ n: Int) -> String {
        let r = osascript(ensureFolder + """

        tell application "Notes"
          set out to ""
          set now to current date
          repeat with nt in (notes of folder "Mycroft")
            set out to out & ((now - (modification date of nt)) as integer) & (character id 31) & (plaintext of nt) & (character id 30)
          end repeat
          return out
        end tell
        """)
        if !r.ok { return "Error: \(r.out)" }
        let text = newest(r.out, n)
        return text.isEmpty ? "No notes yet." : text
    }

    /// Parses "age<US>text<RS>..." and joins the `n` youngest notes.
    static func newest(_ raw: String, _ n: Int) -> String {
        raw.components(separatedBy: rs).compactMap { rec -> (Int, String)? in
            let parts = rec.components(separatedBy: fs)
            guard parts.count >= 2, let age = Int(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            return (age, parts.dropFirst().joined(separator: fs))
        }
        .sorted { $0.0 < $1.0 }.prefix(n).map { $0.1 + "\n---\n" }.joined()
    }

    public static func last() -> String { recent(1) }

    public static func search(_ query: String) -> String {
        let r = osascript(ensureFolder + """

        tell application "Notes"
          set out to ""
          repeat with nt in (notes of folder "Mycroft")
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
