import AppKit
import QuartzCore

@MainActor func completionUITests() throws {
    var checks = 0
    func expect(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "Completion UI test: \(message)", code: 1) }
        checks += 1
    }
    guard let primary = NSScreen.screens.first else { throw CompletionError.unavailable }
    var primaryFrame = primary.visibleFrame
    let secondaryFrame = NSRect(x: primaryFrame.maxX + 100, y: primaryFrame.minY, width: 1200, height: 800)
    var screens = [primaryFrame, secondaryFrame]
    let preferencesName = "AiQuotaBar.UITests.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: preferencesName)!
    defer { preferences.removePersistentDomain(forName: preferencesName) }
    let panel = CompletionPanel(visibleFrames: { screens }, preferences: preferences)
    // Exercise real windows without flashing test alerts on the user's desktop.
    panel.panel.alphaValue = 0
    panel.panel.ignoresMouseEvents = true
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
    let cards = views.compactMap { $0 as? CompletionCard }
    try expect(!cards.isEmpty && cards.allSatisfy { $0.frame.height <= 50 && $0.frame.height > 0 },
               "Completion cards occupy at most one third of the former 142-point height, allowing rounding")
    try expect(cards.allSatisfy { card in
        guard let action = descendants(card).first(where: { $0.identifier?.rawValue == "completion-dismiss" }) else { return false }
        let bounds = action.convert(action.bounds, to: card)
        return bounds.width >= 26 && bounds.height >= 26 && abs(card.bounds.maxX - bounds.maxX - 10) < 1
    }, "Compact action buttons stay aligned to the right edge with usable hit areas")
    try expect(buttons.filter { $0.identifier?.rawValue == "completion-dismiss" || $0.identifier?.rawValue == "completion-open" }
        .allSatisfy { abs($0.frame.width - $0.frame.height) < 0.1 },
        "Icon action buttons are visually square, without native bezel alignment insets")
    try expect(cards.allSatisfy { card in
        let title = descendants(card).compactMap { $0 as? NSButton }.first { !$0.title.isEmpty }
        return (title?.frame.width ?? 0) > card.frame.width * 0.55
    }, "Project and session titles receive the available row width instead of a blank spacer")
    try expect(buttons.allSatisfy { $0.identifier?.rawValue != "completion-copy" }, "The notification has no copy action")
    try expect(panel.panel.isVisible && !panel.panel.hidesOnDeactivate, "Panel stays visible across app changes")
    try expect(panel.panel.level.rawValue >= NSWindow.Level.statusBar.rawValue && !panel.panel.canHide,
               "Floating inbox stays above ordinary and floating application windows")
    try expect(!panel.panel.styleMask.contains(.titled) && !panel.panel.isOpaque,
               "Completion uses its own transparent borderless floating window")
    try expect(panel.panel.collectionBehavior.contains(.fullScreenAuxiliary), "Full-screen auxiliary panel")
    try expect(primaryFrame.contains(panel.panel.frame), "Notification starts on the primary display")
    let draggedOrigin = NSPoint(x: primaryFrame.maxX + 200, y: primaryFrame.minY)
    panel.windowWillMove(Notification(name: NSWindow.willMoveNotification, object: panel.panel))
    panel.panel.setFrameOrigin(draggedOrigin)
    try expect(panel.panel.frame.origin == draggedOrigin, "Dragging across a display edge is not snapped back mid-drag")
    panel.show(events, animateNew: false)
    try expect(secondaryFrame.contains(panel.panel.frame), "Refreshing preserves the display chosen by dragging")
    let movedFrame = panel.panel.frame
    panel.show(Array(events.prefix(2)), animateNew: true)
    try expect(secondaryFrame.contains(panel.panel.frame) && panel.panel.frame.minX == movedFrame.minX
               && panel.panel.frame.maxY == movedFrame.maxY, "New alerts resize below the same position on the chosen display")
    panel.showError("An unavailable session remains unread")
    try expect(secondaryFrame.contains(panel.panel.frame), "Navigation errors stay on the chosen display")
    panel.showError(nil)
    panel.show(events, animateNew: false)
    // Simulate a screen layout change while the secondary display remains connected.
    screens = [primaryFrame.insetBy(dx: 45, dy: 45), secondaryFrame]
    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    try expect(secondaryFrame.contains(panel.panel.frame), "Other display changes do not override the chosen monitor")
    // Simulate disconnecting that display.
    primaryFrame = primaryFrame.insetBy(dx: 45, dy: 45)
    screens = [primaryFrame]
    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    try expect(primaryFrame.contains(panel.panel.frame), "Disconnecting the chosen display returns the panel to the primary display")
    let open = buttons.first { $0.identifier?.rawValue == "completion-open" }!
    open.performClick(nil)
    try expect(opened == "event-0" && dismissed == nil && !all, "Opening the correct session does not dismiss it")
    buttons.first { $0.identifier?.rawValue == "completion-dismiss" }!.performClick(nil)
    try expect(dismissed == "event-0", "Individual confirmation identifies its own card")
    buttons.first { $0.title == L10n.text("모두 확인", "Dismiss all") }!.performClick(nil)
    try expect(all, "Confirm-all action is wired")
    try expect(descendants(panel.panel.contentView!).allSatisfy { !($0 is NSScrollView) }, "The floating inbox has no internal scroll view")
    let next = descendants(panel.panel.contentView!).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "completion-next-page" }
    try expect(next != nil && next!.isEnabled, "Overflow completions are available through page controls")
    next!.performClick(nil)
    let pageOpen = descendants(panel.panel.contentView!).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "completion-open" }!
    pageOpen.performClick(nil)
    try expect(opened != "event-0", "The next page opens its own session")
    panel.show([], animateNew: false)
    try expect(!panel.panel.isVisible, "Last confirmation hides the empty panel")
    try expect(panel.activeWiggle == nil, "Dismissing all cards cancels any running animation")
    panel.showEmpty("Waiting for a completed response")
    try expect(panel.panel.isVisible && !panel.panel.styleMask.contains(.titled), "An empty inbox also uses the custom floating panel")
    panel.show([], animateNew: false)
    let motionSize = NSSize(width: 432, height: 594)
    let motion = CompletionMotion.wiggle(size: motionSize)
    let transforms = (motion.values as! [NSValue]).map { CATransform3DGetAffineTransform($0.caTransform3DValue) }
    let pivot = CGPoint(x: motionSize.width / 2, y: motionSize.height / 2)
    try expect(transforms.allSatisfy { transform in
        let result = pivot.applying(transform)
        return abs(result.x - pivot.x) < 0.001 && abs(result.y - pivot.y) < 0.001
    }, "Rotation pins the top-right corner throughout the motion")
    let angles = transforms.map { atan2($0.b, $0.a) * 180 / .pi }
    try expect(angles.filter { $0 < -2.99 }.count == 3 && angles.filter { $0 > 2.99 }.count == 3,
               "Three full left/right swings reach three degrees")
    try expect(transforms.first!.isIdentity && transforms.last!.isIdentity && abs(motion.duration - 0.77) < 0.001,
               "Seven 0.11-second legs return to the original position")
    try expect(CompletionMotion.interval == 12, "Periodic reminder interval is twelve seconds")
    var reducedMotion = false
    let animated = CompletionPanel(reduceMotion: { reducedMotion })
    animated.panel.alphaValue = 0
    animated.panel.ignoresMouseEvents = true
    animated.show([events[0]], animateNew: true)
    try expect(animated.activeWiggle != nil, "A new completion starts the custom rotation")
    RunLoop.main.run(until: Date().addingTimeInterval(0.055))
    let presented = animated.panel.contentView?.subviews.first?.layer?.presentation()?.transform
    try expect(presented != nil && !CATransform3DIsIdentity(presented!), "The actual floating surface visibly rotates")
    reducedMotion = true
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    try expect(animated.activeWiggle == nil, "Enabling Reduce Motion immediately cancels the rotation")
    animated.animate()
    try expect(animated.activeWiggle == nil, "Reduce Motion suppresses periodic animation")
    reducedMotion = false
    animated.animate()
    animated.show([], animateNew: false)
    try expect(animated.activeWiggle == nil, "Dismissal cancels a running rotation")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aiquota-ui-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let codexConfig = directory.appendingPathComponent("codex/hooks.json")
    let claudeConfig = directory.appendingPathComponent("claude/settings.json")
    try FileManager.default.createDirectory(at: claudeConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"theme":"dark"}"#.utf8).write(to: claudeConfig)
    let environment = ["CODEX_HOME": codexConfig.deletingLastPathComponent().path,
                       "CLAUDE_CONFIG_DIR": claudeConfig.deletingLastPathComponent().path]
    let store = CompletionStore(directory: directory)
    try store.record(events[0])
    let controllerPanel = CompletionPanel()
    controllerPanel.panel.alphaValue = 0
    controllerPanel.panel.ignoresMouseEvents = true
    let controller = CompletionController(store: store, panel: controllerPanel, connect: {
        HookInstaller.connectAvailable(executable: "/Applications/AiQuotaBar.app/Contents/MacOS/AiQuotaBar",
                                       environment: environment, isInstalled: { _ in true })
    })
    controller.start()
    func waitForCount(_ count: Int) {
        let deadline = Date().addingTimeInterval(4)
        while controller.unreadCount != count && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    waitForCount(1)
    let connectionDeadline = Date().addingTimeInterval(4)
    while controller.connectionStates.count < 2 && Date() < connectionDeadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    try expect(FileManager.default.fileExists(atPath: codexConfig.path), "Starting the controller connects Codex without a menu action")
    let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: claudeConfig)) as! [String: Any]
    try expect(settings["theme"] as? String == "dark" && settings["hooks"] != nil, "Starting the controller connects Claude and preserves its existing settings")
    try expect(controller.unreadCount == 1, "Controller restores unread alerts from disk")
    let replacement = CompletionEvent(id: "replacement", providerID: events[0].providerID, sessionID: events[0].sessionID,
        project: events[0].project, directory: events[0].directory, sessionName: "Latest response",
        completedAt: Date().addingTimeInterval(1), destination: SessionDestination())
    try store.record(replacement)
    func hasReplacement() -> Bool {
        descendants(controllerPanel.panel.contentView!).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Latest response" }
    }
    let replacementDeadline = Date().addingTimeInterval(4)
    while !hasReplacement() && Date() < replacementDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    try expect(hasReplacement() && controller.unreadCount == 1,
               "A newer completion updates the visible session card even when the unread count stays one")
    try store.record(events[1])
    waitForCount(2)
    try expect(controller.unreadCount == 2, "Controller discovers a completion received while running")
    guard let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0 is NSPanel }), let content = window.contentView else { throw CompletionError.unavailable }
    let dismiss = descendants(content).compactMap { $0 as? NSButton }.first { $0.title == L10n.text("모두 확인", "Dismiss all") }!
    dismiss.performClick(nil)
    waitForCount(0)
    try expect(controller.unreadCount == 0, "Actual dismiss action updates the controller")
    try expect(try store.load().unread.isEmpty, "Actual dismiss action persists across relaunch")
    controller.showPreview()
    try expect(try store.load().unread.isEmpty && controller.unreadCount == 0, "Preview data never becomes a real unread completion")
    guard let previewWindow = NSApplication.shared.windows.first(where: { $0.isVisible && $0 is NSPanel }), let previewContent = previewWindow.contentView else { throw CompletionError.unavailable }
    let previewViews = descendants(previewContent)
    let sampleOpen = previewViews.compactMap { $0 as? NSButton }.filter { $0.identifier?.rawValue == "completion-open" }
    try expect(!sampleOpen.isEmpty && sampleOpen.allSatisfy { !$0.isEnabled }, "Sample session navigation is visibly disabled")
    try expect(previewViews.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains(L10n.text("예시 데이터", "Sample data")) },
               "Preview is visibly marked as sample data")
    previewViews.compactMap { $0 as? NSButton }.first { $0.title == L10n.text("모두 확인", "Dismiss all") }!.performClick(nil)
    try expect(!previewWindow.isVisible && (try store.load().unread.isEmpty), "Dismissing preview closes it without changing the stored inbox")
    try store.record(events[2])
    waitForCount(1)
    controller.showPreview()
    let previewDismiss = descendants(previewContent).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "completion-dismiss" }!
    previewDismiss.performClick(nil)
    try expect(try store.load().unread.map(\.id) == [events[2].id], "Dismissing a sample cannot acknowledge a real event")
    descendants(previewContent).compactMap { $0 as? NSButton }.first { $0.title == L10n.text("모두 확인", "Dismiss all") }!.performClick(nil)
    try expect(controller.unreadCount == 1 && previewWindow.isVisible, "Closing preview restores the real unread inbox")
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    RunLoop.main.run(until: Date().addingTimeInterval(2.2))
    try expect(previewWindow.isVisible && controller.unreadCount == 1, "Unread floating window remains after app/Space changes and refresh polling")
    try store.acknowledgeAll()
    waitForCount(0)
    print("PASS: \(checks) completion UI and persistence checks")
}
