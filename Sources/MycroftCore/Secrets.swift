import Foundation

/// Strips passwords and API keys from command output before it is sent to Claude.
public enum SecretStripper {
    static let patterns: [(String, String)] = [
        (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, "[REDACTED PRIVATE KEY]"),
        (#"sk-ant-[A-Za-z0-9_\-]{8,}"#, "[REDACTED]"),
        (#"sk-[A-Za-z0-9_\-]{20,}"#, "[REDACTED]"),
        (#"gh[pousr]_[A-Za-z0-9]{20,}"#, "[REDACTED]"),
        (#"github_pat_[A-Za-z0-9_]{20,}"#, "[REDACTED]"),
        (#"xox[abprs]-[A-Za-z0-9\-]{10,}"#, "[REDACTED]"),
        (#"AKIA[0-9A-Z]{16}"#, "[REDACTED]"),
        (#"AIza[0-9A-Za-z_\-]{30,}"#, "[REDACTED]"),
        (#"eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#, "[REDACTED JWT]"),
        (#"(?i)(bearer|basic)\s+[A-Za-z0-9._~+/=\-]{16,}"#, "$1 [REDACTED]"),
        (#"(?i)://([^/\s:@]+):([^@\s/]+)@"#, "://$1:[REDACTED]@"),
        // name=value / name: value where the name looks secret
        (#"(?i)\b([A-Za-z0-9_.\-]*(?:password|passwd|passphrase|secret|token|api[_\-]?key|apikey|access[_\-]?key|private[_\-]?key|credential|auth)[A-Za-z0-9_.\-]*)(\s*[=:]\s*)("[^"]*"|'[^']*'|[^\s"',;]+)"#, "$1$2[REDACTED]"),
    ]
    static let compiled: [(NSRegularExpression, String)] = patterns.map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    public static func strip(_ text: String) -> String {
        var s = text
        for (re, rep) in compiled {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: rep)
        }
        return s
    }
}
