import Foundation

func messageTests() throws {
    var checks = 0
    func expect(_ value: Bool, _ message: String) throws {
        checks += 1
        if !value { throw NSError(domain: "Message test: \(message)", code: 1) }
    }
    try expect(SessionMessage(" \n\t", role: .user) == nil, "Blank text does not create an empty preview")
    let tail = SessionMessage("older\r\n1\n\n2\n3\n4\n5\n", role: .assistant)!
    try expect(tail.text == "1\n2\n3\n4\n5", "The last five nonempty lines survive CRLF and trailing blanks")
    let unicode = SessionMessage(String(repeating: "한🙂", count: 5000) + "끝", role: .assistant)!
    try expect(unicode.text.count == 1200 && unicode.text.hasSuffix("끝"), "Long Unicode messages are bounded without losing the tail")
    let escapes = SessionMessage("\u{1b}[31mred\u{1b}[0m\u{1b}]0;hidden\u{7}\u{0}", role: .assistant)
    try expect(escapes?.text == "red", "Terminal colors, OSC commands and controls are removed")
    try expect(SessionMessage.runtime(["lastAssistantMessage": "Answer", "prompt": "Request"])?.role == .assistant, "Runtime prefers its last reported response")
    try expect(SessionMessage.runtime(["lastAssistantMessage": "", "prompt": "Request"])?.role == .user, "A missing response falls back to a labeled request")

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aiquota-messages-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = CompletionStore(directory: folder)
    func send(_ name: String, id: String = "one", provider: Provider = .codex, extra: [String: Any] = [:]) throws {
        let base: [String: Any] = ["hook_event_name": name, "session_id": id, "cwd": "/same-project"]
        try store.receive(JSONSerialization.data(withJSONObject: base.merging(extra) { _, next in next }), provider: provider, environment: [:])
    }
    func message(_ id: String = "one", provider: Provider = .codex) throws -> SessionMessage? {
        try store.load().messages?[completionHash(provider.rawValue + "\u{0}" + id)]
    }
    try send("UserPromptSubmit", extra: ["prompt": "New request", "turn_id": "new"])
    try send("Stop", extra: ["last_assistant_message": "Old response", "turn_id": "old"])
    try expect(try message()?.text == "New request", "A stale turn cannot replace the current request excerpt")
    try send("Stop", extra: ["last_assistant_message": "Current response", "turn_id": "new"])
    try expect(try message()?.text == "Current response", "The matching response replaces its request")
    try send("Stop", id: "two", extra: ["last_assistant_message": "Other session", "turn_id": "two"])
    try send("Stop", provider: .claude, extra: ["last_assistant_message": "Claude response", "prompt_id": "c1"])
    try expect(try message("two")?.text == "Other session" && message(provider: .claude)?.text == "Claude response", "Shared projects and native IDs never mix providers or sessions")
    try send("UserPromptSubmit", extra: ["turn_id": "next"])
    try expect(try message() == nil, "A new prompt with unavailable text clears the previous response")
    try send("SubagentStart", extra: ["agent_id": "child"])
    try send("SubagentStop", extra: ["agent_id": "child", "last_assistant_message": "Child report"])
    try expect(try message("child")?.text == "Child report" && message() == nil, "Child reports remain on the child's own row")
    try send("SubagentStop", extra: ["agent_id": "unknown", "last_assistant_message": "Internal report"])
    try expect(try message("unknown") == nil, "Untracked internal agents cannot create previews")
    try send("Stop", extra: ["turn_id": "next", "last_assistant_message": "Retained answer"])
    try send("SessionEnd")
    try expect(try message()?.text == "Retained answer", "Unread closed sessions restore their bounded excerpt")
    let events = try store.load().unread.filter { $0.sessionKey == "codex\u{0}one" }
    try store.acknowledge(Set(events.map(\.id)))
    try expect(try message() == nil && message("child") == nil, "Acknowledging a closed family removes its message data")
    try expect(try message("two") != nil, "Cleanup does not remove another open session's excerpt")

    let terminals = Data(#"{"terminals":[{"handle":"term_one","tabId":"t","leafId":"1","connected":true,"agentIdentity":"codex","worktreePath":"/same-project"},{"handle":"term_two","tabId":"t","leafId":"2","connected":true,"agentIdentity":"codex","worktreePath":"/same-project"}]}"#.utf8)
    let worktrees = Data(#"{"worktrees":[{"agents":[{"paneKey":"t:2","state":"working","hasLivePty":true,"lastAssistantMessage":"Second pane"},{"paneKey":"t:1","state":"working","hasLivePty":true,"lastAssistantMessage":"First pane","children":[{"kind":"agent","id":"worker","state":"working"}]}]}]}"#.utf8)
    let live = try OrcaSessionDiscovery.parse(terminals: terminals, worktrees: worktrees)
    let rows = SessionRow.make(state: CompletionState(), discovered: live)
    try expect(rows.first { $0.event.destination.target == "term_one" && $0.depth == 0 }?.message?.text == "First pane", "Runtime messages match exact panes rather than project names or ordering")
    try expect(rows.first { $0.event.destination.target == "term_two" }?.message?.text == "Second pane", "Other pane keeps its own response")
    try expect(rows.first { $0.depth == 1 }?.message == nil, "A child never borrows its parent's message")
    try expect(!String(data: JSONEncoder().encode(live), encoding: .utf8)!.contains("First pane"), "Live runtime reads are not serialized as transcript snapshots")
    var native = live[0]
    native.event = CompletionEvent(id: "native", providerID: "codex", sessionID: "native", project: "project", directory: "/project", sessionName: "Native", completedAt: Date(), destination: live[0].event.destination)
    let nativeState = CompletionState(sessions: [completionHash(native.key): native])
    let merged = SessionRow.make(state: nativeState, discovered: live)
    try expect(merged.first { $0.event.sessionID == "native" }?.message?.text == "First pane", "Native identity adoption retains the runtime excerpt on that pane")
    var newerNative = native
    newerNative.updatedAt = Date()
    newerNative.messageCleared = true
    let clearedState = CompletionState(sessions: [completionHash(newerNative.key): newerNative])
    let clearedRows = SessionRow.make(state: clearedState, discovered: live)
    try expect(clearedRows.first { $0.event.sessionID == "native" }?.message == nil, "A newer native clear cannot resurrect an older runtime response")
    let childMessages = Data(#"{"worktrees":[{"agents":[{"paneKey":"t:1","state":"working","hasLivePty":true,"lastAssistantMessage":"Parent only","children":[{"kind":"agent","id":"worker","state":"working","lastMessage":"Child only"}]}]}]}"#.utf8)
    let childRows = SessionRow.make(state: CompletionState(), discovered: try OrcaSessionDiscovery.parse(terminals: terminals, worktrees: childMessages))
    try expect(childRows.first { $0.depth == 1 }?.message?.text == "Child only", "Canonical Orca children use their own lastMessage field")
    var done = live[0]; done.activity = .idle; done.completionToken = "done"
    try store.recordObservedCompletions([done], previous: [live[0]])
    try expect(try message(done.event.sessionID)?.text == "First pane", "Observed runtime completion persists only its bounded preview")
    let adoptedStore = CompletionStore(directory: folder.appendingPathComponent("adopted"))
    try adoptedStore.recordObservedCompletions([done], previous: [live[0]])
    let begin: [String: Any] = ["hook_event_name": "SessionStart", "session_id": "adopted", "cwd": "/same-project"]
    try adoptedStore.receive(JSONSerialization.data(withJSONObject: begin), provider: .codex,
        environment: ["TERM_PROGRAM": "orca", "ORCA_TERMINAL_HANDLE": "term_one"])
    try adoptedStore.receive(JSONSerialization.data(withJSONObject: begin.merging(["hook_event_name": "SessionEnd"]) { _, next in next }), provider: .codex, environment: [:])
    let adoptedRow = SessionRow.make(state: try adoptedStore.load(), discovered: []).first { $0.event.sessionID == "adopted" }
    try expect(adoptedRow?.message?.text == "First pane", "Runtime excerpt survives native identity adoption, closure and reload")
    try send("UserPromptSubmit", id: "notify", extra: ["turn_id": "fresh", "prompt": "Current notify request"])
    let staleNotify: [String: Any] = ["type": "agent-turn-complete", "thread-id": "notify", "turn-id": "stale", "cwd": "/same-project", "last-assistant-message": "Stale notify response"]
    try store.receive(JSONSerialization.data(withJSONObject: staleNotify), provider: .codex, environment: [:])
    try expect(try message("notify")?.text == "Current notify request", "Notify turn-id alias rejects stale responses")
    var nativeChild = live.first { $0.parentKey != nil }!
    nativeChild.updatedAt = Date()
    let childState = CompletionState(sessions: [completionHash(nativeChild.key): nativeChild], messages: [completionHash(nativeChild.key): SessionMessage("New child response", role: .assistant)!])
    let discoveredChildren = try OrcaSessionDiscovery.parse(terminals: terminals, worktrees: childMessages)
    let freshChild = SessionRow.make(state: childState, discovered: discoveredChildren).first { $0.event.sessionID == "worker" }
    try expect(freshChild?.message?.text == "New child response", "Older child runtime snapshots cannot replace a newer native excerpt")
    newerNative.messageCleared = nil
    let legacyState = CompletionState(sessions: [completionHash(newerNative.key): newerNative])
    try expect(SessionRow.make(state: legacyState, discovered: live).first { $0.event.sessionID == "native" }?.message?.text == "First pane", "Legacy records without message metadata can show available runtime text")
    try send("SubagentStart", id: "reuse-parent", extra: ["agent_id": "reuse-child"])
    try send("UserPromptSubmit", id: "reuse-child", extra: ["turn_id": "old-child-turn", "prompt": "Old child request"])
    try send("Stop", id: "reuse-child", extra: ["turn_id": "old-child-turn", "last_assistant_message": "Old child answer"])
    try send("SubagentStart", id: "reuse-parent", extra: ["agent_id": "reuse-child", "turn_id": "new-child-turn"])
    try expect(try message("reuse-child") == nil, "Restarting a child clears its excerpt despite an old turn context")
    try send("UserPromptSubmit", id: "cleared", extra: ["turn_id": "clear-turn"])
    for name in ["SessionStart", "Stop"] {
        try send(name, id: "cleared", extra: ["source": "compact", "turn_id": "clear-turn"])
        var state = try store.load()
        let key = completionHash("codex\u{0}cleared")
        try expect(state.sessions?[key]?.messageCleared == true, "Lifecycle replacement preserves an intentional message clear")
        state.sessions?[key]?.event.destination = live[0].event.destination
        let cleared = SessionRow.make(state: state, discovered: live).first { $0.event.sessionID == "cleared" }
        try expect(cleared?.message == nil, "Compaction and empty stop cannot resurrect older runtime text")
    }
    print("PASS: \(checks) session message checks")
}
