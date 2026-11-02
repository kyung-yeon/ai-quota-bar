import AppKit

@MainActor func panelWindowUITests(_ expect: (Bool, String) throws -> Void) throws {
    func all(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + all($0) } }
    let name = "AiQuotaBar.WindowTests.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: name)!
    defer { preferences.removePersistentDomain(forName: name) }
    let screen = NSRect(x: 0, y: 0, width: 1440, height: 1000)
    var screens = [screen]
    let panel = CompletionPanel(visibleFrames: { screens }, preferences: preferences)
    panel.panel.alphaValue = 0; panel.panel.ignoresMouseEvents = true
    panel.onSend = { _, _, _ in }
    defer { panel.hide() }
    let styles: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
    try expect(panel.panel.styleMask.isSuperset(of: styles), "Floating sessions support native window controls and edge resizing")
    for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
        try expect(panel.panel.standardWindowButton(kind)?.isEnabled == true,
            "Native window button \(kind.rawValue) is available")
    }
    let rows = (0..<24).map { index in
        SessionRow(event: CompletionEvent(id: "window-\(index)", providerID: "codex", sessionID: "window-\(index)",
            project: "Sample", directory: "/sample", sessionName: "Session \(index)", completedAt: Date(),
            destination: SessionDestination(host: .orca, target: "term_\(index)")), isOpen: true,
            message: SessionMessage("First\nSecond\nThird\nFourth\nFifth", role: .assistant))
    }
    panel.showSessions(Array(rows.prefix(2)), animateNew: false)
    let input = all(panel.panel.contentView!).compactMap { $0 as? SessionComposer }.first!
    input.editor.string = "Keep my draft"; input.textDidChange(Notification(name: NSText.didChangeNotification))
    panel.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification, object: panel.panel))
    panel.panel.setFrame(NSRect(x: 50, y: 100, width: 700, height: 650), display: true)
    panel.showSessions(rows, animateNew: false)
    panel.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: panel.panel))
    let resized = panel.panel.frame
    try expect(resized.size == NSSize(width: 700, height: 650), "Mouse resize keeps the chosen width and height")
    try expect(all(panel.panel.contentView!).compactMap { $0 as? SessionComposer }.contains { $0.draft == "Keep my draft" },
        "Resize preserves session drafts while applying updates received during the drag")
    panel.showSessions(rows, animateNew: true)
    try expect(panel.panel.frame == resized, "New completions never reset a user-sized window")
    panel.setPageSize(1)
    try expect(panel.panel.frame == resized, "Changing rows per page keeps the user's window size")
    panel.setPageSize(10)
    var visited = Set<String>()
    for _ in 0..<30 {
        let root = panel.panel.contentView!; root.layoutSubtreeIfNeeded()
        let cards = all(root).compactMap { $0 as? CompletionCard }
        visited.formUnion(cards.map { $0.row.id })
        try expect(cards.allSatisfy { root.bounds.contains($0.convert($0.bounds, to: root)) }, "Resized page cards stay inside the content area")
        let next = all(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "completion-next-page" }!
        try expect(root.bounds.contains(next.convert(next.bounds, to: root)), "Resized window keeps the pager reachable")
        if !next.isEnabled { break }
        next.performClick(nil)
    }
    try expect(visited == Set(rows.map(\.id)), "Every session remains reachable after resizing without a list scrollbar")
    let header = all(panel.panel.contentView!).first { $0.identifier?.rawValue == "completion-header" }!
    func toggleCollapse() {
        let location = header.convert(NSPoint(x: 15, y: header.bounds.midY), to: nil)
        header.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.panel.windowNumber, context: nil,
            eventNumber: 0, clickCount: 2, pressure: 1)!)
    }
    toggleCollapse(); toggleCollapse()
    try expect(panel.panel.frame == resized, "Collapse and expand preserve the user-sized frame")
    toggleCollapse()
    panel.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification, object: panel.panel))
    var wider = panel.panel.frame; wider.size.width += 80
    panel.panel.setFrame(wider, display: true)
    panel.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: panel.panel))
    toggleCollapse()
    try expect(panel.panel.frame.height == resized.height && panel.panel.frame.width == resized.width + 80,
        "Horizontal resizing while collapsed preserves the expanded height")
    panel.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification, object: panel.panel))
    panel.panel.setFrame(resized, display: true)
    panel.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: panel.panel))
    let restored = CompletionPanel(visibleFrames: { screens }, preferences: preferences)
    restored.panel.alphaValue = 0; restored.panel.ignoresMouseEvents = true
    restored.onSend = { _, _, _ in }
    restored.showSessions(rows, animateNew: false)
    try expect(restored.panel.frame == resized, "User size and position survive a new app window")
    restored.hide()
    let zoom = panel.panel.standardWindowButton(.zoomButton)!
    zoom.performClick(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    try expect(panel.panel.frame == screen.insetBy(dx: 8, dy: 8), "Green button expands on the current monitor")
    panel.showSessions(rows, animateNew: true)
    zoom.performClick(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    try expect(panel.panel.frame == resized, "Green button restores the user's previous size after refresh: \(panel.panel.frame) versus \(resized)")
    panel.panel.performMiniaturize(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    try expect(panel.panel.isMiniaturized, "Yellow button minimizes the floating window")
    panel.showSessions(Array(rows.prefix(3)), animateNew: true)
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
    try expect(panel.panel.isMiniaturized, "Refresh and app switching do not restore a minimized window")
    panel.restoreFromMiniaturized()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    try expect(!panel.panel.isMiniaturized && panel.panel.isVisible && panel.panel.frame == resized,
        "Restoring a minimized window keeps its dimensions")
    screens = [NSRect(x: 0, y: 0, width: 600, height: 650)]
    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    try expect(screens[0].contains(panel.panel.frame), "A smaller monitor clamps a saved window into view")
    var closed = false
    panel.onClose = { closed = true; panel.hide() }
    panel.panel.standardWindowButton(.closeButton)!.performClick(nil)
    try expect(closed && !panel.panel.isVisible, "Red button invokes the existing hide-and-monitor behavior")
}
