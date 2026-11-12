import Foundation

/// Trump mode speaks only real recordings of Donald J. Trump, kept as short audio files in ~/Mycroft/trump
/// (quiet-piggy.m4a, wrong.m4a, ...). Every line is turned into one of these clips; anything that doesn't
/// name a clip becomes "Quiet, piggy".
public enum TrumpClips {
    public static let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Mycroft/trump")
    public static let fallback = "quiet-piggy"
    static let extensions: Set<String> = ["m4a", "mp3", "wav", "aiff", "caf"]

    /// What each known clip says, for the prompt. Clips not listed here are described by their file name.
    public static let meanings: [String: String] = [
        "quiet-piggy": "\"Quiet, quiet, piggy.\" The default for anything without a better fit",
        "wrong": "\"Wrong!\" for something false or a failure",
        "fake-news": "\"Fake news\" for a doubtful claim, bad news, or a failure",
        "tremendous": "\"Tremendous\" for a task done well",
        "believe-me": "\"Believe me\" for agreeing or promising",
        "so-complicated": "\"Nobody knew it could be so complicated\" for something hard or failed",
        "person-woman-man": "\"Person, woman, man, camera, TV\" for remembering or memory",
        "stable-genius": "\"I'm a very stable genius\" for showing off",
        "concepts-of-a-plan": "\"I have concepts of a plan\" for plans or not knowing how",
        "swear": "A real moment where he swears. Use it rarely, for something really messed up",
        "thank-you": "\"Thank you\" for thanks, goodbyes, or done",
        "you-are-fired": "\"You're fired\" for cancelling, stopping, or goodbye",
        "maga": "\"Make America great again\" for hello, starting, or a big win",
    ]

    /// The clip names in a folder, sorted.
    public static func available(in dir: URL = folder) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(files.filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .map { ($0 as NSString).deletingPathExtension }).sorted()
    }

    /// The clip a line means: "Tremendous." or "you are fired" -> that clip; anything else -> "Quiet, piggy".
    /// Nil only when there are no clips at all.
    public static func name(for text: String, available: [String]) -> String? {
        let key = text.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9 \-]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"[ \-]+"#, with: "-", options: .regularExpression)
        if available.contains(key) { return key }
        return available.contains(fallback) ? fallback : available.first
    }

    public static func file(named name: String, in dir: URL = folder) -> URL? {
        extensions.lazy.map { dir.appendingPathComponent("\(name).\($0)") }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
