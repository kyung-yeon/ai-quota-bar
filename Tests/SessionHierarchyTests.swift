import Foundation

/// Headless regressions: explicit lifecycle ancestry must survive unread completion storage.
func sessionHierarchyTests() throws {
    var checks = 0
    var failures: [String] = []
    func expect(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { failures.append(message) }
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aiquota-hierarchy-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    func store(_ name: String) -> CompletionStore { CompletionStore(directory: directory.appendingPathComponent(name)) }
    func hook(_ store: CompletionStore, _ name: String, session: String,
              extra: [String: Any] = [:], environment: [String: String] = [:]) throws {
        let payload: [String: Any] = ["hook_event_name": name, "session_id": session,
                                      "cwd": "/headbot", "turn_id": session + "-turn"]
        try store.receive(JSONSerialization.data(withJSONObject: payload.merging(extra) { _, new in new }),
                          provider: .codex, environment: environment)
    }
    func startFamily(_ store: CompletionStore) throws {
        try hook(store, "SessionStart", session: "parent")
        try hook(store, "SubagentStart", session: "parent", extra: ["agent_id": "child",
            "agent_type": "reviewer", "agent_name": "Review worker", "model": "model-example"])
    }
    let parentID = "codex\u{0}parent"
    let childID = "codex\u{0}child"

    let closed = store("closed-child")
    try startFamily(closed)
    try hook(closed, "Stop", session: "child")
    try hook(closed, "SessionEnd", session: "child")
    var rows = SessionRow.make(state: try closed.load(), discovered: [])
    var child = rows.first { $0.id == childID }
    expect(child?.parentID == parentID && child?.depth == 1,
           "An unread child remains beneath its live parent after child SessionEnd")
    expect(child?.isOpen == false && child?.needsAttention == true && child?.opensParent == true,
           "A closed unread child preserves attention and parent-navigation semantics")

    try hook(closed, "SessionEnd", session: "parent")
    // Re-open the file through a fresh store instance, as an app relaunch would.
    let reopened = CompletionStore(directory: closed.directory)
    rows = SessionRow.make(state: try reopened.load(), discovered: [])
    child = rows.first { $0.id == childID }
    let context = rows.first { $0.id == parentID }
    expect(context != nil && context?.isOpen == false && context?.needsAttention == false,
           "Parent exit preserves a closed context row for its unread child across app relaunch")
    expect(child?.parentID == parentID && child?.depth == 1 && child?.opensParent == true,
           "Parent exit and app relaunch cannot promote an unread child to a root")
    expect(try reopened.load().unread.count == 1,
           "Retaining closed parent context does not invent a parent completion")

    try hook(reopened, "SessionStart", session: "parent")
    rows = SessionRow.make(state: try reopened.load(), discovered: [])
    child = rows.first { $0.id == childID }
    expect(rows.filter { $0.id == parentID }.count == 1 && rows.first { $0.id == parentID }?.isOpen == true,
           "Resuming the same parent reuses its context row")
    expect(child?.parentID == parentID && child?.depth == 1 && child?.isOpen == false,
           "Resuming a parent restores its unread child without reopening that child")
    try reopened.acknowledge(child!.event.id)
    expect(try reopened.load().closedSessions?.isEmpty != false
           && SessionRow.make(state: reopened.load(), discovered: []).map(\.id) == [parentID],
           "Acknowledging the last child removes retained closed context without removing its live parent")

    let roleStore = store("child-role")
    try startFamily(roleStore)
    for name in ["SessionStart", "UserPromptSubmit", "Stop"] {
        try hook(roleStore, name, session: "child")
        let row = SessionRow.make(state: try roleStore.load(), discovered: []).first { $0.id == childID }
        expect(row?.event.project == "Review worker" && row?.event.sessionName == "model-example"
               && row?.parentID == parentID && row?.opensParent == true,
               "Child \(name) preserves its assigned name, model, and parent relationship")
    }

    let shared = store("shared-terminal")
    let destination = SessionDestination(host: .orca, target: "term_hierarchy")
    let synthetic = CompletionEvent(id: "runtime:parent-turn", providerID: "codex", sessionID: "orca:parent",
        project: "headbot", directory: "/headbot", sessionName: "Parent runtime",
        completedAt: Date(), destination: destination)
    try shared.record(synthetic)
    let orca = ["TERM_PROGRAM": "Orca", "ORCA_TERMINAL_HANDLE": "term_hierarchy"]
    try hook(shared, "SubagentStart", session: "parent", extra: ["agent_id": "child", "agent_type": "reviewer"], environment: orca)
    try hook(shared, "UserPromptSubmit", session: "child", environment: orca)
    var retained = try shared.load().events.first { $0.id == synthetic.id }
    expect(retained != nil && retained?.sessionID != "child",
           "A child sharing the parent terminal cannot adopt the root runtime completion identity")
    try hook(shared, "Stop", session: "child", environment: orca)
    retained = try shared.load().events.first { $0.id == synthetic.id }
    expect(retained != nil && retained?.sessionID != "child" && retained?.acknowledgedAt == nil,
           "Completing a child cannot acknowledge or replace the root runtime completion")
    let rootRuntime = LiveSession(event: synthetic, activity: .idle, updatedAt: Date())
    let familyRows = SessionRow.make(state: try shared.load(), discovered: [rootRuntime])
    expect(familyRows.count == 2 && familyRows.map(\.depth) == [0, 1],
           "A root runtime completion and its child share one parent context without a synthetic duplicate")
    let fallback = store("child-before-parent-fallback")
    try hook(fallback, "SessionStart", session: "parent", environment: orca)
    try hook(fallback, "SubagentStart", session: "parent", extra: ["agent_id": "child"], environment: orca)
    var working = rootRuntime; working.activity = .running; working.updatedAt = Date.distantPast
    try hook(fallback, "Stop", session: "child", environment: orca)
    var finished = rootRuntime; finished.completionToken = "completed"; finished.updatedAt = Date()
    try fallback.recordObservedCompletions([finished], previous: [working])
    expect(try Set(fallback.load().unread.map(\.sessionID)) == ["parent", "child"],
           "A child completion cannot suppress the parent's observed runtime completion")

    let historical = store("acknowledged-child")
    try hook(historical, "SubagentStart", session: "parent", extra: ["agent_id": "child"], environment: orca)
    try hook(historical, "Stop", session: "child", environment: orca)
    try hook(historical, "SessionEnd", session: "parent", environment: orca)
    try historical.acknowledgeAll()
    let rediscovered = SessionRow.make(state: try historical.load(), discovered: [rootRuntime])
    expect(rediscovered.count == 1 && rediscovered[0].id == rootRuntime.key,
           "An acknowledged closed child is never adopted as a newly discovered root")
    try historical.recordObservedCompletions([finished], previous: [working])
    expect(try historical.load().unread.map(\.sessionID) == [rootRuntime.event.sessionID],
           "Historical child provenance survives closed-context cleanup during runtime fallback")

    let independent = store("independent-jobs")
    for session in ["job-a", "job-b"] {
        try hook(independent, "Stop", session: session)
        try hook(independent, "SessionEnd", session: session)
    }
    rows = SessionRow.make(state: try independent.load(), discovered: [])
    expect(rows.count == 2 && rows.allSatisfy { $0.parentID == nil && $0.depth == 0 },
           "Unrelated completed jobs remain separate roots even with identical project and directory")

    let automatic = store("automatic-exec")
    let automatedEnvironment = ["AIQUOTABAR_EPHEMERAL_EXEC": "1"]
    try hook(automatic, "SessionStart", session: "automatic-job", environment: automatedEnvironment)
    try hook(automatic, "SubagentStart", session: "automatic-job", extra: ["agent_id": "automatic-child"], environment: automatedEnvironment)
    try hook(automatic, "Stop", session: "automatic-job", environment: automatedEnvironment)
    expect(try automatic.load().unread.isEmpty && automatic.load().sessions?.isEmpty != false,
           "Verified ephemeral exec jobs do not create interactive rows or completion alerts")
    try startFamily(automatic)
    try hook(automatic, "SubagentStop", session: "parent", extra: ["agent_id": "child"], environment: automatedEnvironment)
    let stoppedChild = try automatic.load().sessions![completionHash(childID)]!
    expect(stoppedChild.activity == .idle && stoppedChild.event.project == "Review worker"
           && stoppedChild.event.sessionName == "model-example",
           "A known child's SubagentStop survives filtering and preserves omitted name/model fields")
    try hook(automatic, "Stop", session: "child", environment: automatedEnvironment)
    let explicitChild = SessionRow.make(state: try automatic.load(), discovered: []).first { $0.id == childID }
    expect(explicitChild?.needsAttention == true && explicitChild?.depth == 1,
           "Explicit native child ownership takes precedence over automatic invocation filtering")

    if !failures.isEmpty {
        throw NSError(domain: "Session hierarchy regressions", code: failures.count,
                      userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "\n")])
    }
    print("PASS: \(checks) session hierarchy persistence checks")
}
