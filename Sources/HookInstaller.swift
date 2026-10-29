import Foundation

enum HookInstaller {
    static let flag = "--completion-hook"
    static let events = ["SessionStart", "UserPromptSubmit", "Stop"]

    static func configurationURL(_ provider: Provider, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let override = environment[provider == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"]
        let directory = override.map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(provider == .codex ? ".codex" : ".claude")
        return directory.appendingPathComponent(provider == .codex ? "hooks.json" : "settings.json")
    }

    static func merged(_ original: Data?, provider: Provider, executable: String, remove: Bool) throws -> Data {
        var root: [String: Any] = [:]
        if let original {
            guard let value = try JSONSerialization.jsonObject(with: original) as? [String: Any] else { throw CompletionError.invalidEvent }
            root = value
        }
        if let hooks = root["hooks"], !(hooks is [String: Any]) { throw CompletionError.invalidEvent }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in events {
            if let value = hooks[event], !(value is [[String: Any]]) { throw CompletionError.invalidEvent }
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups = try groups.compactMap { group in
                guard let handlers = group["hooks"] as? [[String: Any]] else { throw CompletionError.invalidEvent }
                let kept = handlers.filter { handler in
                    guard let command = handler["command"] as? String else { return true }
                    return !command.contains(" \(flag) \(provider.rawValue)")
                }
                if kept.count == handlers.count { return group }
                guard !kept.isEmpty else { return nil }
                var copy = group; copy["hooks"] = kept; return copy
            }
            if !remove {
                groups.append(["hooks": [["type": "command", "command": "\(SessionNavigator.shellQuote(executable)) \(flag) \(provider.rawValue)", "timeout": 5]]])
            }
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    static func install(_ provider: Provider, executable: String, remove: Bool = false, configuration: URL? = nil) throws {
        let url = configuration ?? configurationURL(provider)
        let fm = FileManager.default
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw CompletionError.unavailable }
        let original = fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        let data = try merged(original, provider: provider, executable: executable, remove: remove)
        guard data != original else { return }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let original {
            let backup = url.appendingPathExtension("aiquotabar-backup-\(UUID().uuidString)")
            try original.write(to: backup, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        // Detect an intervening edit before replacing the file; keep all original settings.
        let current = fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        guard current == original else { throw CompletionError.busy }
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
