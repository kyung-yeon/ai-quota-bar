import AppKit

@MainActor func windowChromeUITests(_ expect: (Bool, String) throws -> Void) throws {
    func all(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + all($0) } }
    let name = "AiQuotaBar.WindowChrome.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: name)!
    defer { preferences.removePersistentDomain(forName: name) }
    let panel = CompletionPanel(visibleFrames: { [NSRect(x: 0, y: 0, width: 1440, height: 1000)] },
        preferences: preferences, reduceMotion: { false })
    panel.panel.alphaValue = 0; panel.panel.ignoresMouseEvents = true
    panel.onSend = { _, _, _, _ in }
    defer { panel.hide() }
    let rows = (0..<12).map { index in
        SessionRow(event: CompletionEvent(id: "resize-\(index)", providerID: "codex", sessionID: "resize-\(index)",
            project: "Sample", directory: "/sample", sessionName: "Session \(index)", completedAt: Date(),
            destination: SessionDestination(host: .orca, target: "term_\(index)")), isOpen: true,
            message: SessionMessage("First\nSecond\nThird\nFourth\nFifth", role: .assistant))
    }
    panel.showSessions(rows, animateNew: false)
    panel.panel.setFrame(NSRect(x: 80, y: 120, width: 720, height: 740), display: true)
    let root = panel.panel.contentView!
    root.layoutSubtreeIfNeeded()
    let grip = all(root).compactMap { $0 as? SessionResizeHandle }.first!
    let hitPoint = grip.convert(NSPoint(x: grip.bounds.midX, y: grip.bounds.midY), to: root)
    try expect(root.hitTest(hitPoint) === grip && grip.acceptsFirstMouse(for: nil) && !grip.mouseDownCanMoveWindow,
        "The visible bottom-right grip receives clicks instead of dragging the window")
    try expect(grip.frame.maxX == root.bounds.maxX && grip.frame.minY == root.bounds.minY,
        "Resize grip sits at the actual native content corner")

    func drag(width: CGFloat, height: CGFloat) {
        root.layoutSubtreeIfNeeded()
        let start = panel.panel.convertPoint(toScreen: grip.convert(NSPoint(x: 9, y: 9), to: nil))
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: panel.panel.convertPoint(fromScreen: point), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        grip.mouseDown(with: event(.leftMouseDown, start))
        let end = NSPoint(x: start.x + width, y: start.y - height)
        grip.mouseDragged(with: event(.leftMouseDragged, end))
        grip.mouseUp(with: event(.leftMouseUp, end))
    }
    let original = panel.panel.frame
    drag(width: -120, height: -180)
    try expect(panel.panel.frame.width == original.width - 120 && panel.panel.frame.height == original.height - 180,
        "Dragging the visible grip inward shrinks a previously enlarged window")
    try expect(panel.panel.frame.minX == original.minX && panel.panel.frame.maxY == original.maxY,
        "Bottom-right resizing keeps the top-left corner anchored")
    let smaller = panel.panel.frame
    drag(width: 80, height: 100)
    try expect(panel.panel.frame.width == smaller.width + 80 && panel.panel.frame.height == smaller.height + 100,
        "Dragging the same grip outward enlarges the window again")
    drag(width: -1000, height: -1000)
    root.layoutSubtreeIfNeeded()
    let cards = all(root).compactMap { $0 as? CompletionCard }
    let next = all(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "completion-next-page" }!
    try expect(panel.panel.frame.width == 380 && panel.panel.frame.height < smaller.height && cards.count == 1,
        "Minimum size fits one complete card instead of locking the current full page")
    try expect(cards.allSatisfy { root.bounds.contains($0.convert($0.bounds, to: root)) }
        && !cards[0].convert(cards[0].bounds, to: root).intersects(next.convert(next.bounds, to: root)),
        "Minimum-size cards and footer remain visible without overlapping")
    try expect(!grip.frame.intersects(next.convert(next.bounds, to: root)), "Resize grip never covers the next-page button")
    let minimum = panel.panel.frame
    panel.showSessions(rows, animateNew: true)
    try expect(panel.panel.frame == minimum, "Refresh preserves the smaller window")
    panel.setPageSize(3)
    drag(width: 140, height: 180)
    let backdrop = all(root).first { $0.identifier?.rawValue == "floating-transparency" }!
    panel.remindUnread()
    try expect(panel.activeReminder != nil && backdrop.superview?.layer?.animation(forKey: "unreadReminder") == nil,
        "Unread reminders animate the indicator while the window surface and title bar remain stationary")
    if let path = ProcessInfo.processInfo.environment["AIQUOTABAR_WINDOW_PREVIEW"], let frame = root.superview {
        frame.layoutSubtreeIfNeeded()
        let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)!
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
}
