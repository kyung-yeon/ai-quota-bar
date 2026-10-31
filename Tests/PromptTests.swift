import Foundation

func promptTests() throws {
    var checks = 0
    func expect(_ value: Bool, _ message: String) throws {
        checks += 1
        if !value { throw NSError(domain: "Prompt test: \(message)", code: 1) }
    }
    let event = CompletionEvent(id: "sample", providerID: "codex", sessionID: "one", project: "Sample", directory: "/sample",
        sessionName: "Sample", completedAt: Date(), destination: SessionDestination(host: .orca, target: "term_sample"))
    var row = SessionRow(event: event, isOpen: true)
    var writes: [[String: Any]] = [], calls = 0, shows = 0
    var status = "idle", provider = "codex", host = "local", replacePTY = false, failSubmit = false
    let call: SessionPromptSender.Call = { method, params in
        calls += 1
        if method == "terminal.show" {
            shows += 1
            return ["terminal": ["handle": "term_sample", "connected": true, "orphaned": false,
                "agentIdentity": provider, "executionHostId": host, "ptyId": replacePTY && shows > 1 ? "replacement" : "pty"]]
        }
        if method == "terminal.agentStatus" { return ["agentStatus": ["handle": "term_sample", "isRunningAgent": true, "status": status]] }
        writes.append(params)
        if failSubmit && params["enter"] as? Bool == true { throw PromptSendError.unavailable }
        return ["send": ["handle": "term_sample", "accepted": true]]
    }
    let text = "한글 요청\nsecond line; $(echo untouched)"
    _ = try SessionPromptSender.send(row, text: text, call: call, settle: {})
    try expect(writes.count == 2 && calls == 6, "Each write has a fresh identity and agent-status check")
    try expect(writes[0]["text"] as? String == "\u{1b}[200~" + text + "\u{1b}[201~" && writes[0]["enter"] == nil, "Literal multiline input is pasted without a submit suffix")
    try expect(writes[1]["enter"] as? Bool == true && writes[1]["text"] == nil, "Submit is a separate guarded request")
    try expect(writes.allSatisfy { $0["requireAgentStatus"] as? String == "sendable" && $0["terminal"] as? String == "term_sample" }, "Both writes require a live sendable agent on the explicit target")
    func rejected(_ text: String = "request", expected: PromptSendError = .notReady, afterWrite: Bool = false) throws {
        writes = []; calls = 0; shows = 0
        do { _ = try SessionPromptSender.send(row, text: text, call: call, settle: {}); try expect(false, "Expected refusal") }
        catch let error as PromptSendError { try expect(error == expected && (afterWrite || writes.isEmpty), "Unsafe inputs are refused without shell fallback") }
    }
    row.activity = .running; try rejected()
    row.activity = .unknown; try rejected()
    row.activity = .idle; row.isOpen = false; try rejected()
    row.isOpen = true; row.opensParent = true; try rejected()
    row.opensParent = false; row.event.destination.host = .iterm; try rejected()
    row.event.destination.host = .orca
    try rejected(" \n", expected: .invalidText)
    try rejected(String(repeating: "가", count: 8001), expected: .invalidText)
    try rejected("hello\u{1b}[201~\ncommand", expected: .invalidText)
    try rejected("hello\u{0}", expected: .invalidText)
    provider = "claude"; try rejected(expected: .unavailable); provider = "codex"
    host = "ssh:remote"; try rejected(expected: .unavailable); host = "local"
    status = "permission"; try rejected(); status = "idle"
    replacePTY = true; try rejected(expected: .uncertain, afterWrite: true)
    try expect(writes.count == 1, "PTY replacement after paste prevents Enter and any automatic retry")
    replacePTY = false; failSubmit = true; try rejected(expected: .uncertain, afterWrite: true)
    try expect(writes.count == 2, "Lost submit acknowledgement is not replayed")
    failSubmit = false; writes = []; calls = 0; shows = 0
    do {
        _ = try SessionPromptSender.send(row, text: "request", call: call, settle: { status = "working" })
        try expect(false, "Working transition must block submit")
    } catch PromptSendError.uncertain { try expect(writes.count == 1, "New work after paste stops the submit stage") }
    print("PASS: \(checks) guarded prompt delivery checks")
}
