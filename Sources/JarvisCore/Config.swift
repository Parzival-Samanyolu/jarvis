import Foundation
import Security

public enum Paths {
    static var override: URL? { ProcessInfo.processInfo.environment["JARVIS_HOME"].map { URL(fileURLWithPath: $0) } }
    static var library: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library") }

    /// Data directory: ~/Library/Application Support/Jarvis. `JARVIS_HOME` puts data and logs in one folder instead.
    public static var dir: URL { override ?? library.appendingPathComponent("Application Support/Jarvis") }
    /// Log directory: ~/Library/Logs/Jarvis (shows up in Console.app).
    public static var logs: URL { override ?? library.appendingPathComponent("Logs/Jarvis") }
    public static var memory: URL { dir.appendingPathComponent("memory.md") }
    public static var usage: URL { dir.appendingPathComponent("usage.jsonl") }
    public static var commandLog: URL { logs.appendingPathComponent("commands.log") }
    public static var conversationLog: URL { logs.appendingPathComponent("conversation.log") }
    public static var state: URL { dir.appendingPathComponent("state.json") }
    public static var models: URL { dir.appendingPathComponent("models") }
}

public enum Keychain {
    static let service = "jarvis"
    static let account = "anthropic-api-key"

    public static func apiKey() -> String? {
        if let k = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !k.isEmpty { return k }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    public static func setAPIKey(_ key: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

/// Tiny JSON-backed key/value store for things like "last greeting date".
public enum State {
    public static func get(_ key: String) -> String? {
        guard let d = try? Data(contentsOf: Paths.state),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return nil }
        return o[key]
    }
    public static func set(_ key: String, _ value: String) {
        var o: [String: String] = [:]
        if let d = try? Data(contentsOf: Paths.state),
           let e = try? JSONSerialization.jsonObject(with: d) as? [String: String] { o = e }
        o[key] = value
        try? FileManager.default.createDirectory(at: Paths.dir, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: o) { try? d.write(to: Paths.state) }
    }
}
