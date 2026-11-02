import AppKit

@MainActor func sessionFilterUITests(_ expect: (Bool, String) throws -> Void) throws {
    func all(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + all($0) } }
    let name = "AiQuotaBar.Filters.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: name)!
    defer { preferences.removePersistentDomain(forName: name) }
    let panel = CompletionPanel(visibleFrames: { [NSRect(x: 0, y: 0, width: 1440, height: 1000)] }, preferences: preferences, reduceMotion: { true })
    panel.panel.alphaValue = 0; panel.panel.ignoresMouseEvents = true
    panel.onSend = { _, _, _, _ in }
    defer { panel.hide() }
    var rows = (0..<5).map { index in
        SessionRow(event: CompletionEvent(id: "filter-\(index)", providerID: "codex", sessionID: "filter-\(index)",
            project: "Sample", directory: "/sample", sessionName: "Session \(index)", completedAt: Date(),
            destination: SessionDestination(host: .orca, target: "term_\(index)")), isOpen: true, needsAttention: false)
    }
    rows[1].parentID = rows[0].id; rows[1].depth = 1; rows[1].activity = .running; rows[1].needsAttention = true
    rows[2].needsAttention = true; rows[2].isOpen = false
    rows[4].activity = .running
    panel.showSessions(rows, animateNew: false)
    let root = panel.panel.contentView!
    func button(_ id: String) -> NSButton? {
        all(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "session-filter-\(id)" }
    }
    func visibleIDs() -> Set<String> { Set(all(root).compactMap { ($0 as? CompletionCard)?.row.id }) }
    try expect(["all", "completed", "running"].allSatisfy { button($0) != nil }, "All three status tags are clickable session filters")
    try expect(button("all")!.state == .on && visibleIDs() == Set(rows.map(\.id)), "All is selected initially and includes every session")
    root.layoutSubtreeIfNeeded()
    let header = all(root).first { $0.identifier?.rawValue == "completion-header" }!
    let summary = button("running")!.superview!
    try expect(abs(header.convert(header.bounds, to: root).maxX - summary.convert(summary.bounds, to: root).maxX) < 1,
        "Filter tags stay aligned to the right edge of the header")
    let savedFrame = panel.panel.frame
    button("completed")!.performClick(nil)
    try expect(visibleIDs() == Set(rows.prefix(3).map(\.id)) && button("completed")!.state == .on && button("all")!.state == .off,
        "Completed selects unread sessions and retains their parent context")
    button("running")!.performClick(nil)
    try expect(visibleIDs() == Set([rows[0].id, rows[1].id, rows[4].id]) && panel.panel.frame == savedFrame,
        "Working filters active sessions without resizing the window")
    panel.setPageSize(1)
    var visited = Set<String>()
    for _ in 0..<5 {
        visited.formUnion(visibleIDs())
        let next = all(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "completion-next-page" }!
        if !next.isEnabled { break }
        next.performClick(nil)
    }
    try expect(visited == Set([rows[0].id, rows[1].id, rows[4].id]), "Pagination stays within the selected filter after changing page capacity")
    panel.setPageSize(10)
    button("all")!.performClick(nil)
    let input = all(root).compactMap { $0 as? SessionComposer }.first { $0.row.id == rows[3].id }!
    panel.panel.makeFirstResponder(input.editor)
    input.editor.insertText("Preserve across filters", replacementRange: NSRange(location: NSNotFound, length: 0))
    button("running")!.performClick(nil)
    button("all")!.performClick(nil)
    try expect(all(root).compactMap { $0 as? SessionComposer }.contains { $0.row.id == rows[3].id && $0.draft == "Preserve across filters" },
        "Switching filters preserves drafts for sessions hidden by the filter")
    button("running")!.performClick(nil)
    rows[1].activity = .idle; rows[4].activity = .idle
    panel.showSessions(rows, animateNew: false)
    let total = all(root).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "session-status-all" }
    try expect(visibleIDs().isEmpty && button("running")!.state == .on && total?.stringValue == L10n.text("전체 5개", "All 5")
        && all(root).contains { $0.identifier?.rawValue == "session-filter-empty" },
        "A zero-result filter shows an empty state and preserves global totals and selection")
    button("all")!.performClick(nil)
    try expect(visibleIDs() == Set(rows.map(\.id)), "All restores sessions after a filtered list becomes empty")
    button("all")!.performClick(nil)
    try expect(button("all")!.state == .on, "Clicking the selected filter keeps it selected")
    header.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown,
        location: header.convert(NSPoint(x: 10, y: 10), to: nil), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.panel.windowNumber,
        context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!)
    root.layoutSubtreeIfNeeded()
    let completed = button("completed")!
    let point = completed.convert(NSPoint(x: completed.bounds.midX, y: completed.bounds.midY), to: root)
    let hit = root.hitTest(point)
    completed.performClick(nil)
    try expect(hit === completed && preferences.bool(forKey: "sessionPanelCollapsed") && completed.state == .on,
        "Collapsed header routes tag clicks to the filter without dragging or expanding the window")
}
