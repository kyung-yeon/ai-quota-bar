import AppKit

@MainActor func sessionStatusUITests(_ expect: (Bool, String) throws -> Void) throws {
    func all(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + all($0) } }
    let name = "AiQuotaBar.SessionStatus.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: name)!
    defer { preferences.removePersistentDomain(forName: name) }
    let panel = CompletionPanel(preferences: preferences, reduceMotion: { true })
    panel.panel.alphaValue = 0; panel.panel.ignoresMouseEvents = true
    panel.onSend = { _, _, _, _ in }
    defer { panel.hide() }
    var rows = (0..<5).map { index in
        SessionRow(event: CompletionEvent(id: "status-\(index)", providerID: "codex", sessionID: "status-\(index)",
            project: "Sample", directory: "/sample", sessionName: "Session \(index)", completedAt: Date(),
            destination: SessionDestination(host: .orca, target: "term_\(index)")),
            activity: .running, isOpen: true, needsAttention: index < 2)
    }
    rows[1].isOpen = false; rows[1].activity = .idle
    rows[2].parentID = rows[0].id; rows[2].depth = 1
    rows[3].activity = .idle
    rows[4].isOpen = false // A stale running flag on a closed session is not active work.
    panel.setPageSize(1)
    panel.showSessions(rows, animateNew: false)
    let root = panel.panel.contentView!
    func status(_ kind: String) -> String? {
        all(root).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "session-status-\(kind)" }?.stringValue
    }
    try expect(status("completed") == L10n.text("완료 2건", "Done 2") && status("running") == L10n.text("작업 중 2건", "Working 2"),
        "Header tags count unread completions and open running sessions across all pages, including children")
    let next = all(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "completion-next-page" }!
    next.performClick(nil)
    try expect(status("completed") == L10n.text("완료 2건", "Done 2") && status("running") == L10n.text("작업 중 2건", "Working 2"),
        "Navigating pages does not change global status totals")
    all(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "completion-previous-page" }!.performClick(nil)
    let input = all(root).compactMap { $0 as? SessionComposer }.first!
    panel.panel.makeFirstResponder(input.editor)
    input.editor.insertText("Keep this draft", replacementRange: NSRange(location: NSNotFound, length: 0))
    rows[0].activity = .idle; rows[0].needsAttention = false; rows[1].needsAttention = false
    panel.showSessions(rows, animateNew: false)
    try expect(status("completed") == L10n.text("완료 0건", "Done 0") && status("running") == L10n.text("작업 중 1건", "Working 1") && input.draft == "Keep this draft",
        "Status totals keep updating while editing defers list replacement")
    panel.panel.makeFirstResponder(nil)
    panel.showSessions(rows, animateNew: false)
    var frame = panel.panel.frame; frame.size.width = 380
    panel.panel.setFrame(frame, display: true)
    let header = all(root).first { $0.identifier?.rawValue == "completion-header" }!
    header.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown,
        location: header.convert(NSPoint(x: 10, y: 10), to: nil), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.panel.windowNumber,
        context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!)
    root.layoutSubtreeIfNeeded()
    let labels = all(root).compactMap { $0 as? NSTextField }.filter { $0.identifier?.rawValue.hasPrefix("session-status-") == true }
    try expect(preferences.bool(forKey: "sessionPanelCollapsed") && labels.count == 3 && labels.allSatisfy {
        !$0.isHiddenOrHasHiddenAncestor && root.bounds.contains($0.convert($0.bounds, to: root))
            && $0.bounds.width >= $0.intrinsicContentSize.width
    }, "All status tags stay fully visible in a collapsed minimum-width window")
    if let directory = ProcessInfo.processInfo.environment["AIQUOTABAR_STATUS_PREVIEW"] {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            panel.panel.appearance = NSAppearance(named: appearance)
            root.layoutSubtreeIfNeeded()
            let view = root.superview!
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let path = URL(fileURLWithPath: directory).appendingPathComponent("status-\(appearance.rawValue).png")
            try bitmap.representation(using: .png, properties: [:])!.write(to: path)
        }
    }
    panel.showEmpty("No sessions")
    try expect(status("completed") == L10n.text("완료 0건", "Done 0") && status("running") == L10n.text("작업 중 0건", "Working 0"),
        "An empty list clears both status totals")
}
