import AppKit

@MainActor func bulkAcknowledgeUITests(_ expect: (Bool, String) throws -> Void) throws {
    func all(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + all($0) } }
    let name = "AiQuotaBar.BulkAcknowledge.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: name)!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    defer { preferences.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
    let store = CompletionStore(directory: directory)
    let events = (0..<14).map { index in
        CompletionEvent(id: "bulk-\(index)", providerID: "codex", sessionID: "bulk-\(index)", project: "Sample",
            directory: "/sample", sessionName: "Session \(index)", completedAt: Date(),
            destination: SessionDestination(host: .orca, target: "term_\(index)"))
    }
    for event in events { try store.record(event) }
    let live = LiveSession(event: events[0], activity: .running, owner: nil, updatedAt: Date())
    let panel = CompletionPanel(preferences: preferences, reduceMotion: { true })
    panel.panel.alphaValue = 0; panel.panel.ignoresMouseEvents = true
    let controller = CompletionController(store: store, panel: panel, preferences: preferences, discover: { [live] }, connect: { [:] })
    defer { controller.close() }
    func wait(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    }
    controller.start()
    wait { controller.unreadCount == events.count }
    let root = panel.panel.contentView!
    let buttons = all(root).compactMap { $0 as? NSButton }
    let bulk = buttons.first { $0.identifier?.rawValue == "completion-dismiss-all" }
    try expect(bulk?.isEnabled == true, "Unread completions enable a bulk acknowledgement button")
    let button = bulk!
    panel.setPageSize(1)
    buttons.first { $0.identifier?.rawValue == "session-filter-running" }!.performClick(nil)
    let input = all(root).compactMap { $0 as? SessionComposer }.first!
    panel.panel.makeFirstResponder(input.editor)
    input.editor.insertText("Keep my next request", replacementRange: NSRange(location: NSNotFound, length: 0))
    var frame = panel.panel.frame; frame.size.width = 380
    panel.panel.setFrame(frame, display: true)
    let header = all(root).first { $0.identifier?.rawValue == "completion-header" }!
    header.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown,
        location: header.convert(NSPoint(x: 10, y: 10), to: nil), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.panel.windowNumber,
        context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!)
    root.layoutSubtreeIfNeeded()
    let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: root)
    try expect(root.hitTest(point) === button && root.bounds.contains(button.convert(button.bounds, to: root)),
        "Bulk acknowledgement remains clickable in a collapsed minimum-width window")
    // This replacement arrives after the displayed snapshot, before the acknowledgement write.
    let fresh = CompletionEvent(id: "bulk-new-response", providerID: events[1].providerID, sessionID: events[1].sessionID,
        project: "Sample", directory: "/sample", sessionName: "New response", completedAt: Date().addingTimeInterval(1),
        destination: events[1].destination)
    try store.record(fresh)
    button.performClick(nil)
    wait { (try? store.load().unread.map(\.id)) == [fresh.id] }
    let state = try store.load()
    try expect(state.unread.map(\.id) == [fresh.id],
        "Bulk acknowledgement covers every page and filter while preserving a newly arrived response")
    wait { controller.unreadCount == 1 }
    try expect(controller.unreadCount == 1 && button.isEnabled,
        "The new unread response stays available for the next acknowledgement")
    button.performClick(nil)
    wait { controller.unreadCount == 0 }
    try expect(controller.unreadCount == 0 && !button.isEnabled,
        "The completed count clears and bulk acknowledgement disables when nothing remains")
    try expect(all(root).compactMap { $0 as? CompletionCard }.contains {
        $0.row.id == live.key && $0.row.isOpen && $0.row.activity == .running && !$0.row.needsAttention
    } && all(root).compactMap { $0 as? SessionComposer }.contains { $0.draft == "Keep my next request" },
        "Acknowledging an earlier response preserves its currently running session and draft")
    try expect(try CompletionStore(directory: directory).load().unread.isEmpty,
        "Bulk acknowledgement persists when the completion store is reopened")
    if let path = ProcessInfo.processInfo.environment["AIQUOTABAR_BULK_PREVIEW"] {
        let view = root.superview!
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
}
