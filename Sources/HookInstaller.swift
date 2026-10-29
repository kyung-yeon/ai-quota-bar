import Foundation

enum HookConnectionState: Equatable {
    case notInstalled, disconnected, configured, failed(String)

    var hasError: Bool { if case .failed = self { return true }; return false }
    var description: String {
        switch self {
        case .notInstalled: return L10n.text("설치 필요", "Install required")
        case .disconnected: return L10n.text("자동 연결 꺼짐", "Automatic connection off")
        case .configured: return L10n.text("알림 설정 등록됨", "Notification settings registered")
        case .failed(let message): return message
        }
    }
}

enum HookInstallationError: Error, LocalizedError {
    case invalidConfiguration, symbolicLink, hooksDisabled
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return L10n.text("설정 파일의 JSON·훅 형식을 확인해 주세요. 기존 파일은 변경하지 않았습니다.", "Check the configuration's JSON and hook format. The existing file was not changed.")
        case .symbolicLink: return L10n.text("설정 파일이 심볼릭 링크입니다. 실제 설정 폴더에서 연결해 주세요.", "The configuration is a symbolic link. Connect using its real configuration directory.")
        case .hooksDisabled: return L10n.text("이 프로필에서 모든 훅이 비활성화되어 있습니다. 에이전트 설정에서 훅을 활성화한 뒤 연결하세요.", "All hooks are disabled in this profile. Enable them in the agent settings before connecting.")
        }
    }
}

enum HookInstaller {
    static let flag = "--completion-hook"
    static let events = ["SessionStart", "UserPromptSubmit", "Stop"]
    static func setAutomaticConnection(_ enabled: Bool, configuration: URL) throws {
        let marker = configuration.appendingPathExtension("aiquotabar-disabled")
        if enabled {
            if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
        } else {
            try Data("Automatic AiQuotaBar connection disabled for this profile.\n".utf8).write(to: marker, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        }
    }

    static func connectAvailable(executable: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                                 isInstalled: (Provider) -> Bool = { (try? CLIPaths.executable(for: $0)) != nil }) -> [Provider: HookConnectionState] {
        var states: [Provider: HookConnectionState] = [:]
        for provider in Provider.allCases {
            let configuration = configurationURL(provider, environment: environment)
            if FileManager.default.fileExists(atPath: configuration.appendingPathExtension("aiquotabar-disabled").path) {
                states[provider] = .disconnected; continue
            }
            guard isInstalled(provider) else { states[provider] = .notInstalled; continue }
            do {
                try install(provider, executable: executable, configuration: configuration)
                states[provider] = .configured
            } catch { states[provider] = .failed(error.localizedDescription) }
        }
        return states
    }

    static func configurationURL(_ provider: Provider, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let override = environment[provider == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"]
        let directory = override.map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(provider == .codex ? ".codex" : ".claude")
        return directory.appendingPathComponent(provider == .codex ? "hooks.json" : "settings.json")
    }

    static func merged(_ original: Data?, provider: Provider, executable: String, remove: Bool) throws -> Data {
        var root: [String: Any] = [:]
        if let original {
            guard let value = try? JSONSerialization.jsonObject(with: original) as? [String: Any] else { throw HookInstallationError.invalidConfiguration }
            root = value
        }
        if !remove, root["disableAllHooks"] as? Bool == true { throw HookInstallationError.hooksDisabled }
        if let hooks = root["hooks"], !(hooks is [String: Any]) { throw HookInstallationError.invalidConfiguration }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in events {
            if let value = hooks[event], !(value is [[String: Any]]) { throw HookInstallationError.invalidConfiguration }
            var groups = hooks[event] as? [[String: Any]] ?? []
            let command = "\(SessionNavigator.shellQuote(executable)) \(flag) \(provider.rawValue)"
            var found = false
            groups = try groups.compactMap { group in
                guard let handlers = group["hooks"] as? [[String: Any]] else { throw HookInstallationError.invalidConfiguration }
                let kept: [[String: Any]] = handlers.compactMap { handler in
                    guard let existing = handler["command"] as? String, owns(existing, provider: provider) else { return handler }
                    guard !remove, !found else { return nil }
                    found = true
                    // Preserve user choices such as enabled, matcher, timeout, and async.
                    var updated = handler; updated["command"] = command; return updated
                }
                if kept.isEmpty && !handlers.isEmpty { return nil }
                var copy = group; copy["hooks"] = kept; return copy
            }
            if !remove && !found {
                groups.append(["hooks": [["type": "command", "command": command, "timeout": 5]]])
            }
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func owns(_ command: String, provider: Provider) -> Bool {
        let suffix = " \(flag) \(provider.rawValue)"
        guard command.hasSuffix(suffix) else { return false }
        let quoted = String(command.dropLast(suffix.count))
        guard quoted.first == "'", quoted.last == "'", quoted.count >= 2 else { return false }
        let path = String(quoted.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
        return path.hasPrefix("/") && URL(fileURLWithPath: path).lastPathComponent == "AiQuotaBar"
            && SessionNavigator.shellQuote(path) == quoted
    }

    static func install(_ provider: Provider, executable: String, remove: Bool = false, configuration: URL? = nil) throws {
        let url = configuration ?? configurationURL(provider)
        let fm = FileManager.default
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw HookInstallationError.symbolicLink }
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
