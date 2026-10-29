import Foundation

func completionTests() throws {
    var count = 0
    func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw NSError(domain: "Completion test: \(message)", code: 1) }
        count += 1
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aiquota-completions-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CompletionStore(directory: directory)
    let payload = Data(#"{"type":"agent-turn-complete","thread-id":"session-a","turn-id":"turn-1","cwd":"/projects/example","last-assistant-message":"PRIVATE RESPONSE"}"#.utf8)
    let event = try CompletionEvent.decode(payload, provider: .codex, environment: ["ITERM_SESSION_ID": "w0t0p0:session-123"])
    try expect(event?.sessionID == "session-a", "Codex session identity")
    try expect(event?.project == "example", "Project from cwd")
    try expect(event?.destination.host == .iterm, "Origin terminal captured")
    try store.record(event!)
    try store.record(event!)
    try expect(try store.load().unread.count == 1, "Repeated delivery produces one alert")
    try expect(!String(data: try Data(contentsOf: store.file), encoding: .utf8)!.contains("PRIVATE RESPONSE"), "Transcript text is never persisted")
    try store.acknowledge(event!.id)
    try store.record(event!)
    try expect(try CompletionStore(directory: directory).load().unread.isEmpty, "Acknowledged event stays acknowledged after replay and restart")
    let other = try CompletionEvent.decode(Data(#"{"type":"agent-turn-complete","thread-id":"session-b","turn-id":"turn-1","cwd":"/projects/example"}"#.utf8), provider: .codex, environment: [:])!
    try store.record(other)
    try expect(try store.load().unread.count == 1, "Same turn identifier in another session is independent")
    try store.acknowledgeAll()
    try expect(try store.load().unread.isEmpty, "Acknowledge all")
    let newest = try CompletionEvent.decode(Data(#"{"type":"agent-turn-complete","thread-id":"session-b","turn-id":"turn-2","cwd":"/projects/example"}"#.utf8), provider: .codex, environment: [:])!
    try store.record(newest)
    try store.acknowledge(Set([other.id]))
    try expect(try store.load().unread.map(\.id) == [newest.id], "Confirming a snapshot does not dismiss a concurrently arriving event")
    let grouped = CompletionStore(directory: directory.appendingPathComponent("grouped"))
    let base = Date()
    func completion(_ id: String, _ offset: TimeInterval, provider: String = "codex", session: String = "same-session") -> CompletionEvent {
        CompletionEvent(id: id, providerID: provider, sessionID: session, project: "Project", directory: "/project",
                        sessionName: id, completedAt: base.addingTimeInterval(offset),
                        destination: SessionDestination(host: .orca, target: "term_" + id))
    }
    let earliest = completion("first", 0), latest = completion("latest", 1)
    try grouped.record(earliest); try grouped.record(latest)
    try expect(try grouped.load().unread.map(\.id) == [latest.id], "A newer completion replaces the unread card for its provider and session")
    try expect(try grouped.load().unread.first?.destination == latest.destination, "The replacement keeps the latest session label and navigation target")
    try grouped.record(earliest)
    try grouped.record(completion("delayed-old", -1))
    try expect(try grouped.load().unread.map(\.id) == [latest.id], "Replayed and delayed older completions cannot replace the latest card")
    try grouped.acknowledge(Set([earliest.id]))
    try expect(try grouped.load().unread.map(\.id) == [latest.id], "Dismissing an older card does not hide its newer replacement")
    try grouped.record(completion("claude-same-id", 2, provider: "claude"))
    try grouped.record(completion("other-session", 3, session: "other"))
    try expect(try grouped.load().unread.count == 3, "Different providers and sessions keep independent cards")
    try grouped.acknowledge(latest.id)
    try expect(try grouped.load().unread.allSatisfy { $0.providerID != "codex" || $0.sessionID != "same-session" },
               "Dismissing the latest card cannot reveal an older completion")
    let legacy = CompletionState(events: [earliest, latest])
    try JSONEncoder().encode(legacy).write(to: grouped.file)
    try expect(try CompletionStore(directory: grouped.directory).load().unread.map(\.id) == [latest.id],
               "Relaunch coalesces multiple unread cards saved by older app versions")
    try grouped.acknowledge(latest.id)
    try grouped.record(earliest)
    try expect(try grouped.load().unread.isEmpty, "Legacy older IDs remain suppressed after acknowledging the latest")
    try grouped.record(completion("tie-a", 5)); try grouped.record(completion("tie-b", 5))
    try expect(try grouped.load().unread.map(\.id) == ["tie-b"], "Equal timestamps use the most recently received completion")
    for kind in ["SessionStart", "SessionEnd", "SubagentStop", "Interrupt", "StopFailure"] {
        let data = try JSONSerialization.data(withJSONObject: ["hook_event_name": kind, "session_id": "s", "cwd": "/p"])
        try expect(try CompletionEvent.decode(data, provider: .claude, environment: [:]) == nil, "\(kind) is not a completion")
    }
    let claude = try CompletionEvent.decode(Data(#"{"hook_event_name":"Stop","session_id":"s","prompt_id":"p","cwd":"/project","stop_hook_active":false}"#.utf8), provider: .claude, environment: [:])
    try expect(claude != nil, "Claude Stop completion")
    let nested = SessionDestination.capture(environment: ["HERDR_PANE_ID":"w1:p2", "HERDR_SOCKET_PATH":"/tmp/herdr.sock", "CMUX_SURFACE_ID":"123", "CMUX_WORKSPACE_ID":"456"])
    try expect(nested.host == .cmux && nested.herdr?.pane == "w1:p2", "Herdr keeps its outer cmux destination")
    try expect(SessionDestination.capture(environment: ["TERM_PROGRAM":"vscode"]).host == .unsupported, "Do not guess unsupported IDE tab")
    try expect(SessionDestination.capture(environment: ["TMUX":"/tmp/tmux,1,0", "ITERM_SESSION_ID":"old"]).host == .unsupported, "Do not trust inherited outer IDs inside tmux")
    try expect(SessionDestination.capture(environment: ["ORCA_TERMINAL_HANDLE":"term_abc"]).host == .orca, "Orca runtime-issued handle")
    try expect(SessionDestination.capture(environment: ["TERM_PROGRAM":"vscode", "ITERM_SESSION_ID":"inherited"]).host == .unsupported, "IDE ignores inherited outer terminal ID")
    try expect(SessionDestination.capture(environment: ["TERM_PROGRAM":"Orca", "ORCA_TERMINAL_HANDLE":"term_abc", "CMUX_SURFACE_ID":"inherited", "CMUX_WORKSPACE_ID":"inherited"]).host == .orca, "Orca ignores inherited cmux origin")
    let configuration: [String: Any] = ["theme":"dark", "hooks":["Stop":[["hooks":[["type":"command", "command":"echo existing"], ["type":"command", "command":"echo ' --completion-hook claude'"]]]]]]
    let original = try JSONSerialization.data(withJSONObject: configuration)
    let installed = try HookInstaller.merged(original, provider: .claude, executable: "/Applications/Ai Quota's.app/Contents/MacOS/AiQuotaBar", remove: false)
    let twice = try HookInstaller.merged(installed, provider: .claude, executable: "/Applications/Ai Quota's.app/Contents/MacOS/AiQuotaBar", remove: false)
    try expect(installed == twice, "Hook setup is idempotent")
    let removed = try HookInstaller.merged(installed, provider: .claude, executable: "/unused", remove: true)
    let restored = try JSONSerialization.jsonObject(with: removed) as! NSDictionary
    try expect(restored == configuration as NSDictionary, "Uninstall preserves unrelated settings and hooks")
    let customized: [String: Any] = ["hooks": ["Stop": [["matcher": "custom", "hooks": [["type": "command",
        "command": "'/old/AiQuotaBar' --completion-hook codex", "enabled": false, "timeout": 9]]]]]]
    let relocated = try HookInstaller.merged(JSONSerialization.data(withJSONObject: customized), provider: .codex,
        executable: "/new/AiQuotaBar", remove: false)
    let relocatedRoot = try JSONSerialization.jsonObject(with: relocated) as! [String: Any]
    let stopGroups = (relocatedRoot["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
    let stopHandler = (stopGroups[0]["hooks"] as! [[String: Any]])[0]
    try expect(stopGroups[0]["matcher"] as? String == "custom" && stopHandler["enabled"] as? Bool == false && stopHandler["timeout"] as? Int == 9,
               "Automatic repair preserves explicitly disabled and customized AiQuotaBar hooks")
    try expect(stopHandler["command"] as? String == "'/new/AiQuotaBar' --completion-hook codex", "Moving the app updates the hook executable path")
    let profiles = directory.appendingPathComponent("profiles")
    let codexConfiguration = profiles.appendingPathComponent("codex/hooks.json")
    let claudeConfiguration = profiles.appendingPathComponent("claude/settings.json")
    let environment = ["CODEX_HOME": codexConfiguration.deletingLastPathComponent().path,
                       "CLAUDE_CONFIG_DIR": claudeConfiguration.deletingLastPathComponent().path]
    let executable = "/Applications/AiQuotaBar.app/Contents/MacOS/AiQuotaBar"
    let absent = HookInstaller.connectAvailable(executable: executable, environment: environment, isInstalled: { _ in false })
    try expect(absent.values.allSatisfy { $0 == .notInstalled } && !FileManager.default.fileExists(atPath: profiles.path), "Missing CLIs do not create configuration files")
    let connected = HookInstaller.connectAvailable(executable: executable, environment: environment, isInstalled: { _ in true })
    try expect(connected.values.allSatisfy { $0 == .configured }, "Newly installed CLIs are connected on the next check")
    let first = try Data(contentsOf: codexConfiguration)
    _ = HookInstaller.connectAvailable(executable: executable, environment: environment, isInstalled: { _ in true })
    try expect(try Data(contentsOf: codexConfiguration) == first, "Repeated automatic connection does not rewrite hooks")
    try expect(try FileManager.default.contentsOfDirectory(atPath: codexConfiguration.deletingLastPathComponent().path) == ["hooks.json"], "Unchanged automatic checks create no backups")
    try Data("invalid".utf8).write(to: codexConfiguration)
    let partial = HookInstaller.connectAvailable(executable: executable, environment: environment, isInstalled: { _ in true })
    try expect(partial[.codex]?.hasError == true && partial[.claude] == .configured, "One broken configuration does not prevent the other provider connecting")
    try expect(try String(contentsOf: codexConfiguration, encoding: .utf8) == "invalid", "Automatic connection preserves invalid configuration")
    try HookInstaller.setAutomaticConnection(false, configuration: codexConfiguration)
    let disconnected = HookInstaller.connectAvailable(executable: executable, environment: environment, isInstalled: { _ in true })
    try expect(disconnected[.codex] == .disconnected, "An explicitly disconnected profile is not automatically reconnected")
    try Data("{}".utf8).write(to: codexConfiguration)
    try HookInstaller.setAutomaticConnection(true, configuration: codexConfiguration)
    let reconnected = HookInstaller.connectAvailable(executable: executable, environment: environment, isInstalled: { _ in true })
    try expect(reconnected[.codex] == .configured, "Explicitly reconnecting re-enables automatic updates")
    for target in [SessionDestination(host: .warp, target:"https://evil.example"), SessionDestination(host: .warp, target:"warp://session/abc?command=oops"), SessionDestination(host: .orca, target:"--help"), SessionDestination(host: .kitty, target:"1", socket:"tcp:evil:123") ] {
        do { try SessionNavigator.validate(target); try expect(false, "Unsafe navigation target rejected") }
        catch CompletionError.unsupported { count += 1 }
    }
    let quoted = SessionNavigator.shellQuote("a'$(touch nope)")
    let echoed = try SessionCommand.run("/bin/sh", ["-c", "printf %s " + quoted])
    try expect(String(data: echoed, encoding: .utf8) == "a'$(touch nope)", "Resume command shell quoting is literal")
    let binding = HerdrClientBinding(paneSocket: "/tmp/herdr.sock", processID: Int32(ProcessInfo.processInfo.processIdentifier),
                                    processStart: "test-start", destination: SessionDestination(host: .iterm, target: "session"))
    try expect(binding.matches(socket: "/tmp/herdr.sock", runningStart: "test-start"), "Herdr live attachment matches socket and process lifetime")
    try expect(!binding.matches(socket: "/tmp/herdr.sock", runningStart: "reused-pid"), "Herdr cannot navigate a reused PID")
    try expect(!binding.matches(socket: "/tmp/other.sock", runningStart: "test-start"), "Herdr named sessions stay independent")
    print("PASS: \(count) completion checks")
}
