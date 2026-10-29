import AppKit

@MainActor func completionUITests() throws {
    func expect(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "Completion UI test: \(message)", code: 1) }
    }
    let panel = CompletionPanel()
    defer { panel.panel.orderOut(nil) }
    let events = (0..<5).map { index in
        CompletionEvent(id: "event-\(index)", providerID: "codex", sessionID: "s\(index)", project: "Sample", directory: "/sample",
                        sessionName: "Session \(index)", completedAt: Date(), destination: SessionDestination())
    }
    var opened: String?
    var dismissed: String?
    var all = false
    panel.onOpen = { opened = $0.id }
    panel.onAcknowledge = { dismissed = $0 }
    panel.onAcknowledgeAll = { all = true }
    panel.show(events, animateNew: false)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    panel.panel.contentView?.layoutSubtreeIfNeeded()
    func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    let views = descendants(panel.panel.contentView!)
    let buttons = views.compactMap { $0 as? NSButton }
    try expect(panel.panel.isVisible && !panel.panel.hidesOnDeactivate, "Panel stays visible across app changes")
    try expect(panel.panel.collectionBehavior.contains(.fullScreenAuxiliary), "Full-screen auxiliary panel")
    let open = buttons.first { $0.title == L10n.text("세션 열기", "Open session") }!
    open.performClick(nil)
    try expect(opened == "event-0" && dismissed == nil && !all, "Opening the correct session does not dismiss it")
    buttons.first { $0.title == L10n.text("확인", "Dismiss") }!.performClick(nil)
    try expect(dismissed == "event-0", "Individual confirmation identifies its own card")
    buttons.first { $0.title == L10n.text("모두 확인", "Dismiss all") }!.performClick(nil)
    try expect(all, "Confirm-all action is wired")
    let scroll = views.compactMap { $0 as? NSScrollView }.first!
    try expect(scroll.documentView!.frame.height > scroll.contentSize.height, "Long list scrolls rather than hiding cards")
    panel.show([], animateNew: false)
    try expect(!panel.panel.isVisible, "Last confirmation hides the empty panel")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aiquota-ui-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CompletionStore(directory: directory)
    try store.record(events[0])
    let controller = CompletionController(store: store)
    controller.start()
    func waitForCount(_ count: Int) {
        let deadline = Date().addingTimeInterval(4)
        while controller.unreadCount != count && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    waitForCount(1)
    try expect(controller.unreadCount == 1, "Controller restores unread alerts from disk")
    try store.record(events[1])
    waitForCount(2)
    try expect(controller.unreadCount == 2, "Controller discovers a completion received while running")
    guard let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0 is NSPanel }), let content = window.contentView else { throw CompletionError.unavailable }
    let dismiss = descendants(content).compactMap { $0 as? NSButton }.first { $0.title == L10n.text("모두 확인", "Dismiss all") }!
    dismiss.performClick(nil)
    waitForCount(0)
    try expect(controller.unreadCount == 0, "Actual dismiss action updates the controller")
    try expect(try store.load().unread.isEmpty, "Actual dismiss action persists across relaunch")
    print("PASS: 11 completion UI and persistence checks")
}
