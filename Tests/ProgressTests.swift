import Foundation

func progressTests() throws {
    var checks = 0
    func expect(_ value: Bool, _ message: String) throws {
        checks += 1
        if !value { throw NSError(domain: "Progress test: \(message)", code: 1) }
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aiquota-progress-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = CompletionStore(directory: folder)
    func send(_ name: String, session: String = "one", provider: Provider = .codex,
              extra: [String: Any] = [:], environment: [String: String] = [:]) throws {
        var payload: [String: Any] = ["hook_event_name": name, "session_id": session, "cwd": "/sample"]
        if provider == .codex { payload["turn_id"] = "turn-1" }
        try store.receive(JSONSerialization.data(withJSONObject: payload.merging(extra) { _, value in value }), provider: provider, environment: environment)
    }
    func progress(_ session: String = "one", provider: Provider = .codex) throws -> SessionProgress? {
        SessionRow.make(state: try store.load(), discovered: []).first { $0.id == provider.rawValue + "\u{0}" + session }?.progress
    }
    let steps: [[String: Any]] = (0..<7).map { index in
        ["step": index == 4 ? "Design review" : "Step \(index + 1)", "status": index < 4 ? "completed" : index == 4 ? "in_progress" : "pending"]
    }
    func plan(_ list: [[String: Any]], call: String = UUID().uuidString, turn: String = "turn-1") -> [String: Any] {
        ["tool_name": "update_plan", "tool_use_id": call, "turn_id": turn,
         "tool_input": ["plan": list, "explanation": "private explanation"], "tool_response": "Plan updated"]
    }
    try send("UserPromptSubmit")
    try send("PostToolUse", extra: plan(steps, call: "first"))
    let value = try progress()
    try expect(value?.steps.count == 7 && value?.completedCount == 4 && value?.activeIndices == [4], "A plan records seven steps with the fifth active, not five completed")
    try expect(value?.summary.contains("5/7") == true && value?.summary.contains("Design review") == true, "Summary identifies the current stage")
    try expect(try store.load().unread.isEmpty, "Plan updates never create completion alerts")
    try expect(!(String(data: Data(contentsOf: store.file), encoding: .utf8) ?? "").contains("private explanation"), "Only stage metadata is retained")
    try send("PostToolUse", session: "two", extra: plan([["step": "Other session", "status": "pending"]]))
    try expect(try progress("two")?.steps.count == 1 && progress()?.steps.count == 7, "Progress is isolated by native session identity")
    try send("PostToolUse", extra: plan([["step": "Done", "status": "completed"]]))
    try send("PostToolUse", extra: plan(steps, call: "first"))
    try expect(try progress()?.completedCount == 1 && progress()?.steps.count == 1, "Replayed delivery cannot replace a newer plan")
    try send("Stop")
    try expect(try progress()?.completedCount == 1, "Completion preserves the reported plan through store reload")
    try send("UserPromptSubmit", extra: ["turn_id": "turn-2"])
    try expect(try progress() == nil, "A new prompt hides the prior turn's plan")
    try send("PostToolUse", extra: plan(steps, turn: "turn-1"))
    try expect(try progress() == nil, "A late old-turn plan cannot reappear on a new prompt")
    try send("PostToolUse", extra: plan(steps, turn: "turn-2"))
    try send("SessionStart", extra: ["source": "compact", "turn_id": "turn-2"])
    try expect(try progress()?.steps.count == 7, "Compaction does not erase the current plan")
    try send("PostToolUse", extra: plan([], turn: "turn-2"))
    try expect(try progress() == nil, "An explicitly empty plan clears the progress row")
    func claude(_ tool: String, _ input: [String: Any], _ output: [String: Any], session: String = "claude") throws {
        try send("PostToolUse", session: session, provider: .claude, extra: ["tool_name": tool, "tool_use_id": UUID().uuidString,
            "tool_input": input, "tool_response": output])
    }
    try send("SessionStart", session: "claude", provider: .claude, extra: ["source": "startup"])
    try claude("TaskCreate", ["subject": "Research", "description": "private task body"], ["task": ["id": "1", "subject": "Research"]])
    try claude("TaskCreate", ["subject": "Build"], ["task": ["id": "2", "subject": "Build"]])
    try claude("TaskUpdate", ["taskId": "1", "status": "completed"], ["success": true, "taskId": "1", "updatedFields": ["status"], "statusChange": ["from": "pending", "to": "completed"]])
    try claude("TaskUpdate", ["taskId": "2", "status": "in_progress"], ["success": true, "taskId": "2", "updatedFields": ["status"]])
    try expect(try progress("claude", provider: .claude)?.totalKnown == true && progress("claude", provider: .claude)?.activeIndices == [1], "A new unshared task list records every successful task change")
    try claude("TaskUpdate", ["taskId": "2", "status": "completed"], ["success": false, "taskId": "2", "error": "Task not found"])
    try expect(try progress("claude", provider: .claude)?.completedCount == 1, "An unsuccessful task update never claims completion")
    try claude("TaskUpdate", ["taskId": "2", "status": "completed"], ["success": true, "taskId": "wrong", "updatedFields": ["status"]])
    try expect(try progress("claude", provider: .claude)?.completedCount == 1, "A response for another task cannot change the requested task")
    try claude("TaskUpdate", ["taskId": "2", "subject": "Test"], ["success": true, "taskId": "2", "updatedFields": ["subject"]])
    try expect(try progress("claude", provider: .claude)?.steps.last?.title == "Test", "Renaming a task preserves its status and identity")
    try claude("TaskUpdate", ["taskId": "1", "status": "deleted"], ["success": true, "taskId": "1", "updatedFields": ["status"]])
    try expect(try progress("claude", provider: .claude)?.steps.count == 1, "Deleting a task adjusts the denominator")
    try claude("TaskCreate", ["subject": "Late attachment"], ["task": ["id": "9", "subject": "Late attachment"]], session: "late")
    try expect(try progress("late", provider: .claude)?.totalKnown == false, "Attaching mid-session never claims a complete task inventory")
    let snapshot: [[String: Any]] = [["id": "4", "subject": "Before attachment", "status": "completed"], ["id": "9", "subject": "Late attachment", "status": "in_progress"]]
    try claude("TaskList", [:], ["tasks": snapshot], session: "late")
    try expect(try progress("late", provider: .claude)?.totalKnown == true && progress("late", provider: .claude)?.steps.count == 2, "A complete TaskList snapshot repairs a partial inventory")
    try claude("TaskUpdate", ["taskId": "missing", "status": "completed"], ["success": true, "taskId": "missing", "updatedFields": ["status"]], session: "late")
    try expect(try progress("late", provider: .claude)?.totalKnown == false, "An unknown updated task invalidates the full denominator")
    try claude("TodoWrite", ["todos": [["content": "Review", "status": "in_progress", "activeForm": "Reviewing"]]], [:], session: "todo")
    try expect(try progress("todo", provider: .claude)?.steps.first?.title == "Review", "Legacy TodoWrite supplies a full checklist")
    try claude("TaskList", [:], ["tasks": []], session: "late")
    try expect(try progress("late", provider: .claude) == nil, "An empty task list removes obsolete progress")
    try expect(!(String(data: Data(contentsOf: store.file), encoding: .utf8) ?? "").contains("private task body"), "Task descriptions are never persisted")
    try send("SubagentStart", session: "parent", extra: ["agent_id": "child", "agent_name": "Reviewer"])
    try send("PostToolUse", session: "child", extra: plan(steps))
    try expect(try progress("child")?.steps.count == 7 && progress("parent") == nil, "Native subagent progress is separate from its parent")
    try send("Stop", session: "child")
    try send("SessionEnd", session: "parent")
    try expect(try progress("child")?.steps.count == 7, "Unread closed subagents retain progress across relaunch")
    let childEvent = try store.load().unread.first { $0.sessionID == "child" }!
    try store.acknowledge(childEvent.id)
    try expect(try store.load().progress?[completionHash("codex\u{0}child")] == nil, "Acknowledging a closed child removes its progress metadata")
    let configuration = try HookInstaller.merged(nil, provider: .codex, executable: "/app/AiQuotaBar", remove: false)
    let hooks = (try JSONSerialization.jsonObject(with: configuration) as! [String: Any])["hooks"] as! [String: Any]
    let group = (hooks["PostToolUse"] as? [[String: Any]])?.first
    try expect(group?["matcher"] as? String == "^update_plan$", "Automatic registration listens only for Codex plan tools")
    let oldList: [String: Any] = ["tool_name": "TaskList", "tool_use_id": "stale-list", "prompt_id": "old",
        "tool_input": [:], "tool_response": ["tasks": snapshot]]
    try send("UserPromptSubmit", session: "stale", provider: .claude, extra: ["prompt_id": "old"])
    try send("PostToolUse", session: "stale", provider: .claude, extra: oldList)
    try send("UserPromptSubmit", session: "stale", provider: .claude, extra: ["prompt_id": "new"])
    try send("PostToolUse", session: "stale", provider: .claude, extra: oldList.merging(["tool_use_id": "late-old-list"]) { _, new in new })
    try expect(try progress("stale", provider: .claude) == nil, "Claude prompt IDs reject late updates without a Codex turn ID")
    print("PASS: \(checks) session progress checks")
}
