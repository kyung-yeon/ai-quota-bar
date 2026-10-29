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
    let configuration: [String: Any] = ["theme":"dark", "hooks":["Stop":[["hooks":[["type":"command", "command":"echo existing"]]]]]]
    let original = try JSONSerialization.data(withJSONObject: configuration)
    let installed = try HookInstaller.merged(original, provider: .claude, executable: "/Applications/Ai Quota's.app/Contents/MacOS/AiQuotaBar", remove: false)
    let twice = try HookInstaller.merged(installed, provider: .claude, executable: "/Applications/Ai Quota's.app/Contents/MacOS/AiQuotaBar", remove: false)
    try expect(installed == twice, "Hook setup is idempotent")
    let removed = try HookInstaller.merged(installed, provider: .claude, executable: "/unused", remove: true)
    let restored = try JSONSerialization.jsonObject(with: removed) as! NSDictionary
    try expect(restored == configuration as NSDictionary, "Uninstall preserves unrelated settings and hooks")
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
