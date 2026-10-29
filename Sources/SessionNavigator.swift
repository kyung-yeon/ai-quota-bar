import AppKit

enum SessionNavigator {
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Navigation never acknowledges the alert: URL handlers cannot prove the session is visible.
    @MainActor static func open(_ original: SessionDestination) async throws {
        let destination = await Task.detached { HerdrClientBinding.resolve(original, directory: CompletionStore.standard.directory) }.value
        guard destination.host != .unsupported else { throw CompletionError.unsupported }
        try validate(destination)
        if destination.host == .terminal {
            guard let pid = destination.terminalPID, let start = destination.terminalStart,
                  await Task.detached(operation: { HerdrClientBinding.startTime(pid) }).value == start else { throw CompletionError.unavailable }
        }
        if let herdr = destination.herdr {
            _ = try await Task.detached {
                try SessionCommand.run(SessionCommand.executable("herdr"), ["agent", "focus", herdr.pane], environment: ["HERDR_SOCKET_PATH": herdr.socket, "HERDR_SESSION": ""])
            }.value
        }
        switch destination.host {
        case .iterm:
            var components = URLComponents()
            components.scheme = "iterm2"
            components.path = "reveal"
            components.queryItems = [URLQueryItem(name: "sessionid", value: destination.target)]
            try openURL(components.url, app: "com.googlecode.iterm2")
        case .warp:
            try openURL(URL(string: destination.target), app: "dev.warp.Warp-Stable")
        case .terminal, .cmux:
            let script = destination.host == .terminal ? terminalScript : cmuxScript
            _ = try await Task.detached {
                try SessionCommand.run("/usr/bin/osascript", ["-e", script, destination.target], timeout: 15)
            }.value
        case .orca:
            _ = try await Task.detached {
                let cli = try SessionCommand.executable("orca", bundled: "/Applications/Orca.app/Contents/Resources/bin/orca")
                var env = ["ORCA_ENVIRONMENT":"", "ORCA_PAIRING_CODE":"", "ORCA_REMOTE_PAIRING":""]
                if let profile = destination.profile { env["ORCA_USER_DATA_PATH"] = profile }
                return try SessionCommand.run(cli, ["terminal", "switch", "--terminal", destination.target, "--json"], environment: env)
            }.value
            try activate("com.stablyai.orca")
        case .wezterm:
            _ = try await Task.detached {
                let cli = try SessionCommand.executable("wezterm", bundled: "/Applications/WezTerm.app/Contents/MacOS/wezterm")
                var env: [String: String] = [:]
                if let socket = destination.socket { env["WEZTERM_UNIX_SOCKET"] = socket }
                return try SessionCommand.run(cli, ["cli", "activate-pane", "--pane-id", destination.target], environment: env)
            }.value
            try activate("com.github.wez.wezterm")
        case .kitty:
            _ = try await Task.detached {
                let cli = try SessionCommand.executable("kitten", bundled: "/Applications/kitty.app/Contents/MacOS/kitten")
                return try SessionCommand.run(cli, ["@", "--to", destination.socket!, "focus-window", "--match", "id:\(destination.target)"])
            }.value
            try activate("net.kovidgoyal.kitty")
        case .unsupported: throw CompletionError.unsupported
        }
    }

    static func validate(_ target: SessionDestination) throws {
        guard CompletionEvent.validID(target.target), !target.target.hasPrefix("-") else { throw CompletionError.unsupported }
        switch target.host {
        case .warp:
            guard let url = URLComponents(string: target.target), ["warp", "warposs"].contains(url.scheme),
                  url.host == "session", url.query == nil, url.fragment == nil, url.user == nil, url.password == nil,
                  url.path.dropFirst().allSatisfy({ $0.isHexDigit || $0 == "-" }), url.path.count > 1 else { throw CompletionError.unsupported }
        case .terminal:
            guard target.target.hasPrefix("/dev/ttys"), target.target.dropFirst(9).allSatisfy(\.isNumber) else { throw CompletionError.unsupported }
        case .wezterm, .kitty:
            guard target.target.allSatisfy(\.isNumber) else { throw CompletionError.unsupported }
            if target.host == .kitty {
                guard let socket = target.socket, socket.hasPrefix("unix:/"), !socket.contains("\n") else { throw CompletionError.unsupported }
            }
        case .cmux:
            guard UUID(uuidString: target.target) != nil else { throw CompletionError.unsupported }
        case .orca:
            guard target.target.hasPrefix("term_"), target.target.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { throw CompletionError.unsupported }
        case .iterm: break
        case .unsupported: throw CompletionError.unsupported
        }
        if let herdr = target.herdr {
            guard CompletionEvent.validID(herdr.pane), !herdr.pane.hasPrefix("-"), herdr.socket.hasPrefix("/"), !herdr.socket.contains("\n") else { throw CompletionError.unsupported }
        }
    }

    @MainActor private static func activate(_ bundleID: String) throws {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              app.activate(options: [.activateIgnoringOtherApps]) else { throw CompletionError.unavailable }
    }
    @MainActor private static func openURL(_ url: URL?, app bundleID: String) throws {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty,
              let url, NSWorkspace.shared.open(url) else { throw CompletionError.unavailable }
    }

    // IDs are argv, never interpolated into AppleScript source.
    static let terminalScript = """
    on run argv
        if application "Terminal" is not running then error "Terminal is not running"
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is item 1 of argv then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return "focused"
                    end if
                end repeat
            end repeat
        end tell
        error "Tab no longer exists"
    end run
    """
    static let cmuxScript = """
    on run argv
        if application "cmux" is not running then error "cmux is not running"
        tell application "cmux"
            repeat with t in terminals
                if id of t is item 1 of argv then
                    focus t
                    return "focused"
                end if
            end repeat
        end tell
        error "Surface no longer exists"
    end run
    """
}
