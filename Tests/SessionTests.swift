import Foundation

func sessionTests() throws {
    var count = 0
    func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw NSError(domain: "Session test: " + message, code: 1) }
        count += 1
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aiquota-sessions-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CompletionStore(directory: directory)
    func receive(_ name: String, session: String = "a", provider: Provider = .codex, extra: [String: Any] = [:]) throws {
        let payload: [String: Any] = ["hook_event_name": name, "session_id": session, "cwd": "/project", "turn_id": "turn-1"]
        try store.receive(JSONSerialization.data(withJSONObject: payload.merging(extra) { _, new in new }), provider: provider, environment: [:])
    }
    try receive("SessionStart")
    var rows = SessionRow.make(state: try store.load(), discovered: [])
    try expect(rows.count == 1 && rows[0].activity == .idle && !rows[0].needsAttention, "Start displays one idle session without an alert")
    try receive("UserPromptSubmit")
    try receive("SessionStart", extra: ["source": "compact"])
    rows = SessionRow.make(state: try store.load(), discovered: [])
    try expect(rows[0].activity == .running && !rows[0].needsAttention, "Prompt starts activity and compaction preserves it without inventing a completion")
    try receive("Stop")
    rows = SessionRow.make(state: try store.load(), discovered: [])
    try expect(rows.count == 1 && rows[0].needsAttention && rows[0].activity == .idle, "Stop promotes the existing session, not a duplicate")
    try store.acknowledgeAll()
    rows = SessionRow.make(state: try store.load(), discovered: [])
    try expect(rows.count == 1 && rows[0].isOpen && !rows[0].needsAttention, "Acknowledgement keeps an open session in the list")
    try receive("UserPromptSubmit"); try receive("Stop")
    try expect(try store.load().sessions!.values.first!.activity == .running, "A replayed old completion cannot stop a newer running turn")
    try receive("UserPromptSubmit"); try receive("Interrupt")
    try expect(try store.load().sessions!.values.first!.activity == .idle && store.load().unread.isEmpty, "Interrupt stops activity without a successful completion")
    try receive("SessionEnd")
    try expect(try SessionRow.make(state: store.load(), discovered: []).isEmpty, "Session end removes an acknowledged session")
    try receive("UserPromptSubmit"); try receive("Stop", extra: ["turn_id": "turn-2"]); try receive("SessionEnd")
    rows = SessionRow.make(state: try store.load(), discovered: [])
    try expect(rows.count == 1 && !rows[0].isOpen && rows[0].needsAttention, "Session exit preserves unread completion")
    try receive("SessionStart", session: "child", extra: ["agent_id": "child-agent"])
    try expect(try store.load().sessions?.isEmpty == true, "Subagents do not masquerade as open main sessions")
    try receive("UserPromptSubmit", session: "b", provider: .claude)
    try receive("SessionStart", session: "c")
    rows = SessionRow.make(state: try store.load(), discovered: [])
    try expect(rows.map(\.event.sessionID) == ["a", "b", "c"], "Attention, running, then idle order")
    try receive("StopFailure", session: "b", provider: .claude)
    try expect(try store.load().unread.count == 1, "Claude API failure does not generate a completion")
    var state = try store.load()
    for key in state.sessions!.keys { state.sessions?[key]?.owner = SessionOwner(pid: 42, startedAt: "old") }
    try expect(SessionRow.make(state: state, discovered: [], isAlive: { _ in false }).count == 1, "Dead or reused process IDs disappear while unread completions survive")

    let terminals = Data(#"{"result":{"terminals":[{"handle":"term_live","tabId":"t","leafId":"p","connected":true,"orphaned":false,"agentIdentity":"codex","worktreePath":"/project","title":"Session","preview":"PRIVATE"},{"handle":"term_closed","tabId":"t","leafId":"p","connected":false,"agentIdentity":"codex","worktreePath":"/project"}],"truncated":false}}"#.utf8)
    let worktrees = Data(#"{"result":{"worktrees":[{"agents":[{"paneKey":"t:p","state":"working","hasLivePty":true,"updatedAt":1000,"prompt":"PRIVATE"}]}]}}"#.utf8)
    let discovered = try OrcaSessionDiscovery.parse(terminals: terminals, worktrees: worktrees)
    try expect(discovered.count == 1 && discovered[0].activity == .running, "Only connected live agent terminals are discovered")
    try expect(!String(data: JSONEncoder().encode(discovered), encoding: .utf8)!.contains("PRIVATE"), "Runtime previews and prompts are never retained")
    var event = rows[0].event
    event.destination = discovered[0].event.destination
    event.acknowledgedAt = nil
    let merged = SessionRow.make(state: CompletionState(events: [event]), discovered: discovered)
    try expect(merged.count == 1 && merged[0].activity == .running && merged[0].needsAttention, "Runtime and hook identities merge without acknowledging a running session")
    let observedStore = CompletionStore(directory: directory.appendingPathComponent("observed"))
    var finished = discovered[0]
    finished.activity = .idle; finished.completionToken = "2000"; finished.updatedAt = Date(timeIntervalSince1970: 2)
    try observedStore.recordObservedCompletions([finished], previous: [])
    try expect(try observedStore.load().unread.isEmpty, "Discovering an already-idle session never invents a completion")
    try observedStore.recordObservedCompletions([finished], previous: discovered)
    try observedStore.recordObservedCompletions([finished], previous: discovered)
    try expect(try observedStore.load().unread.count == 1, "Working-to-completed runtime transitions persist once for pre-existing sessions")
    let adoption = CompletionStore(directory: directory.appendingPathComponent("adoption"))
    try adoption.recordObservedCompletions([finished], previous: discovered)
    let prompt = Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"native-id","cwd":"/project"}"#.utf8)
    try adoption.receive(prompt, provider: .codex, environment: ["TERM_PROGRAM": "Orca", "ORCA_TERMINAL_HANDLE": "term_live"])
    let adopted = SessionRow.make(state: try adoption.load(), discovered: discovered)
    try expect(adopted.count == 1 && adopted[0].event.sessionID == "native-id" && adopted[0].needsAttention && adopted[0].activity == .running,
               "First native hook adopts an unread runtime identity without duplicating or dismissing it")
    try observedStore.acknowledgeAll()
    try observedStore.recordObservedCompletions([finished], previous: discovered)
    try expect(try observedStore.load().unread.isEmpty, "Replaying a runtime completion cannot undo acknowledgement")
    finished.completionToken = nil
    try observedStore.recordObservedCompletions([finished], previous: discovered)
    try expect(try observedStore.load().unread.isEmpty, "Idle without a completion marker does not count as a response")
    do {
        _ = try OrcaSessionDiscovery.parse(terminals: Data(#"{"terminals":[],"truncated":true}"#.utf8), worktrees: worktrees)
        throw NSError(domain: "Truncated discovery accepted", code: 1)
    } catch CompletionError.unavailable { count += 1 }
    print("PASS: \(count) session lifecycle and discovery checks")
}
