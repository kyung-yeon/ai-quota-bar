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
    let events = (0..<15).map { index in
        CompletionEvent(id: "event-\(index)", providerID: "codex", sessionID: "s\(index)", project: "Sample", directory: "/sample",
                        sessionName: "Session \(index)", completedAt: Date(), destination: SessionDestination())
    }
    var opened: String?
    var dismissed: String?
    panel.onOpen = { opened = $0.id }
    panel.onAcknowledge = { dismissed = $0 }
    panel.show(events, animateNew: false)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    panel.panel.contentView?.layoutSubtreeIfNeeded()
    func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    let views = descendants(panel.panel.contentView!)
    let buttons = views.compactMap { $0 as? NSButton }
    let cards = views.compactMap { $0 as? CompletionCard }
    try expect(panel.preferredPageSize == 10 && cards.count == 10, "A default page shows ten rows")
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
    try expect(opened == "event-0" && dismissed == nil, "Opening the correct session does not dismiss it")
    buttons.first { $0.identifier?.rawValue == "completion-dismiss" }!.performClick(nil)
    try expect(dismissed == "event-0", "Individual confirmation identifies its own card")
    try expect(buttons.allSatisfy { $0.title != L10n.text("모두 확인", "Dismiss all") }, "The header has no dismiss-all action")
    try expect(descendants(panel.panel.contentView!).allSatisfy { !($0 is NSScrollView) }, "The floating inbox has no internal scroll view")
    let next = descendants(panel.panel.contentView!).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "completion-next-page" }
    try expect(next != nil && next!.isEnabled, "Overflow completions are available through page controls")
    next!.performClick(nil)
    let pageOpen = descendants(panel.panel.contentView!).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "completion-open" }!
    pageOpen.performClick(nil)
    try expect(opened != "event-0", "The next page opens its own session")
    panel.show([], animateNew: false)
    try expect(!panel.panel.isVisible, "Last confirmation hides the empty panel")
    panel.showEmpty("Waiting for a completed response")
    try expect(panel.panel.isVisible && !panel.panel.styleMask.contains(.titled), "An empty inbox also uses the custom floating panel")
    panel.show([], animateNew: false)
    var reducedMotion = false
    let animated = CompletionPanel(reduceMotion: { reducedMotion })
    animated.panel.alphaValue = 0
    animated.panel.ignoresMouseEvents = true
    animated.show([events[0]], animateNew: true)
    let initialCard = descendants(animated.panel.contentView!).compactMap { $0 as? CompletionCard }.first!
    try expect(initialCard.layer?.animation(forKey: "sessionPromotion")?.duration == 0.6, "New completion uses a gentle 0.6-second slide")
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    let presented = initialCard.layer?.presentation()?.transform
    try expect(presented != nil && !CATransform3DIsIdentity(presented!), "The row visibly slides during promotion")
    try expect(animated.panel.contentView?.subviews.first?.layer?.animationKeys()?.isEmpty ?? true, "Promotion slides without shaking the floating surface")
    reducedMotion = true
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    try expect(initialCard.layer?.animation(forKey: "sessionPromotion") == nil, "Reduce Motion immediately stops the slide")
    animated.show([events[0]], animateNew: true)
    try expect(descendants(animated.panel.contentView!).compactMap { $0 as? CompletionCard }.allSatisfy { $0.layer?.animationKeys()?.isEmpty ?? true }, "Reduce Motion suppresses new promotion animations")
    reducedMotion = false
    animated.show([], animateNew: false)
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
    let controller = CompletionController(store: store, panel: controllerPanel, preferences: preferences, discover: { [] }, connect: {
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
    for remaining in [1, 0] {
        descendants(content).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "completion-dismiss" }!.performClick(nil)
        waitForCount(remaining)
    }
    try expect(controller.unreadCount == 0, "Actual dismiss action updates the controller")
    try expect(try store.load().unread.isEmpty, "Actual dismiss action persists across relaunch")
    try store.record(events[2])
    waitForCount(1)
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    RunLoop.main.run(until: Date().addingTimeInterval(2.2))
    try expect(controllerPanel.panel.isVisible && controller.unreadCount == 1, "Unread floating window remains after app/Space changes and refresh polling")
    try store.acknowledgeAll()
    waitForCount(0)
    let running = SessionRow(event: events[1], activity: .running, isOpen: true, needsAttention: false)
    let idle = SessionRow(event: events[0], activity: .idle, isOpen: true, needsAttention: false)
    animated.showSessions([running, idle], animateNew: false)
    let activityViews = descendants(animated.panel.contentView!)
    let spinners = activityViews.compactMap { $0 as? SessionSpinner }
    try expect(spinners.contains(where: \.isAnimating), "Running sessions have a rotating activity indicator")
    try expect(animated.panel.contentView?.subviews.first?.layer?.animationKeys()?.isEmpty ?? true, "Working rows do not animate the floating surface")
    try expect(activityViews.compactMap { $0 as? CompletionCard }.count == 2, "Both idle and running sessions appear before a completion")
    var attention = idle; attention.needsAttention = true
    animated.showSessions([attention, running], animateNew: true)
    let promoted = descendants(animated.panel.contentView!).compactMap { $0 as? CompletionCard }.first { $0.row.id == idle.id }!
    try expect(promoted.layer?.animation(forKey: "sessionPromotion") != nil, "An existing session animates upward when promoted to attention")
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    try expect((promoted.layer?.presentation()?.frame.minY ?? 0) > promoted.frame.minY,
               "A promoted row starts below its final position and slides upward in the flipped list")
    reducedMotion = true
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    try expect(descendants(animated.panel.contentView!).compactMap { $0 as? SessionSpinner }.allSatisfy { !$0.isAnimating }, "Reduce Motion stops activity animation")
    animated.hide()
    let closeButton = descendants(controllerPanel.panel.contentView!).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "completion-close" }!
    closeButton.performClick(nil)
    try expect(!controller.isOpen && !controllerPanel.panel.isVisible, "Header close hides the floating list")
    try store.record(events[4]); waitForCount(1)
    try expect(!controllerPanel.panel.isVisible && controller.unreadCount == 1, "New completions are collected without reopening an explicitly closed panel")
    controller.toggle()
    try expect(controller.isOpen && controllerPanel.panel.isVisible, "Menu toggle reopens the current list")
    controller.toggle()
    let restored = CompletionController(store: store, panel: animated, preferences: preferences, discover: { [] }, connect: { [:] })
    restored.start()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    try expect(!restored.isOpen && !animated.panel.isVisible, "Explicit closed preference survives app relaunch")
    controllerPanel.hide()
    let recoveryPanel = CompletionPanel(preferences: preferences)
    recoveryPanel.panel.alphaValue = 0; recoveryPanel.panel.ignoresMouseEvents = true
    defer { recoveryPanel.hide() }
    let recoveryPreferences = UserDefaults(suiteName: preferencesName + ".recovery")!
    defer { recoveryPreferences.removePersistentDomain(forName: preferencesName + ".recovery") }
    let discovery = SessionDiscoveryFixture()
    let runtimeEvent = CompletionEvent(id: "runtime-ui", providerID: "codex", sessionID: "orca:ui", project: "Recovery", directory: "/sample",
        sessionName: "Recovery", completedAt: Date(), destination: SessionDestination(host: .orca, target: "term_recovery"))
    let live = LiveSession(event: runtimeEvent, activity: .running, updatedAt: Date())
    discovery.set([live])
    let recovery = CompletionController(store: CompletionStore(directory: directory.appendingPathComponent("recovery")), panel: recoveryPanel,
        preferences: recoveryPreferences, discover: { try discovery.read() }, connect: { [:] })
    recovery.start()
    func waitForActivity(_ activity: SessionActivity) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if descendants(recoveryPanel.panel.contentView!).compactMap({ $0 as? CompletionCard }).first?.row.activity == activity { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }
    try expect(waitForActivity(.running), "Runtime discovery displays a working session")
    discovery.set(nil)
    try expect(waitForActivity(.unknown), "A temporary discovery failure retains the session with unknown activity")
    var done = live; done.activity = .idle; done.updatedAt = Date(); done.completionToken = "recovered"
    discovery.set([done])
    _ = waitForActivity(.idle)
    try expect(recovery.unreadCount == 1, "Recovery after a failed poll detects completion from the last successful working snapshot")
    recovery.close()
    var treeParent = idle
    treeParent.event = events[0]
    var treeChild = running
    treeChild.parentID = treeParent.id
    treeChild.opensParent = true
    let treeRows = SessionTree.order([treeChild, treeParent])
    animated.showSessions(treeRows, animateNew: false)
    animated.panel.contentView?.layoutSubtreeIfNeeded()
    let treeCards = descendants(animated.panel.contentView!).compactMap { $0 as? CompletionCard }
    let childCard = treeCards.first { $0.row.depth == 1 }!
    try expect(treeCards.count == 2 && childCard.frame.height == 36,
               "Subagents use compact indented rows beneath their parent")
    let childSurface = childCard.subviews.first!
    try expect(childSurface.frame.minX > 0, "Child surfaces leave space for tree connector lines")
    let childOpen = descendants(childCard).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "completion-open" }!
    try expect(childOpen.toolTip == L10n.text("부모 세션 열기", "Open parent session"), "Child navigation explicitly identifies its parent terminal destination")
    try expect(descendants(animated.panel.contentView!).allSatisfy { !($0 is NSScrollView) }, "Tree layout retains pagination without internal scrolling")
    animated.showSessions([idle, running], animateNew: false)
    animated.remindUnread()
    try expect(animated.activeReminder == nil, "Working and idle rows never trigger the periodic reminder")
    animated.showSessions([attention, running], animateNew: false)
    reducedMotion = false
    animated.remindUnread()
    try expect(animated.activeReminder != nil, "An unread completed response enables the periodic reminder")
    animated.showSessions([idle, running], animateNew: false)
    try expect(animated.activeReminder == nil, "Confirming the last completion stops the reminder even when sessions remain open")
    animated.hide()
    animated.remindUnread()
    try expect(animated.activeReminder == nil, "Closing the panel stops reminder motion")
    panel.show(events, animateNew: false)
    panel.setPageSize(5)
    try expect(descendants(panel.panel.contentView!).compactMap { $0 as? CompletionCard }.count == 5,
               "Changing the page size immediately updates a visible panel")
    let savedSizePanel = CompletionPanel(preferences: preferences)
    try expect(savedSizePanel.preferredPageSize == 5, "Rows per page persists across a new panel instance")
    panel.hide()
    panel.setPageSize(15)
    try expect(!panel.panel.isVisible && panel.preferredPageSize == 15, "Changing size while hidden does not reopen the panel")
    panel.setPageSize(0)
    try expect(panel.preferredPageSize == 15, "Invalid page size cannot create an empty or unbounded layout")
    panel.setPageSize(5)
    panel.show(events, animateNew: false)
    let header = descendants(panel.panel.contentView!).first { $0.identifier?.rawValue == "completion-header" }
    try expect(header != nil, "The floating header exposes a double-click target")
    func clickHeader(_ clicks: Int) {
        let location = header!.convert(NSPoint(x: 15, y: header!.bounds.midY), to: nil)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.panel.windowNumber,
            context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        header!.mouseDown(with: event)
    }
    let expandedFrame = panel.panel.frame
    clickHeader(2)
    try expect(panel.panel.frame.height <= 100 && panel.panel.frame.maxY == expandedFrame.maxY,
               "Double-click collapses to just the header while keeping the top edge fixed")
    try expect(descendants(panel.panel.contentView!).compactMap { $0 as? CompletionCard }.allSatisfy(\.isHiddenOrHasHiddenAncestor),
               "Collapsed session cards cannot be seen or clicked")
    panel.show(Array(events.prefix(8)), animateNew: true)
    panel.showError("Example error")
    try expect(panel.panel.frame.height <= 100, "Completions and errors cannot expand a collapsed panel")
    let restoredCollapse = CompletionPanel(visibleFrames: { screens }, preferences: preferences)
    restoredCollapse.panel.alphaValue = 0; restoredCollapse.panel.ignoresMouseEvents = true
    restoredCollapse.show(events, animateNew: false)
    try expect(restoredCollapse.panel.frame.height <= 100, "Collapsed preference survives a new panel instance")
    restoredCollapse.hide()
    clickHeader(2)
    try expect(panel.panel.frame.height > 100 && panel.panel.frame.maxY == expandedFrame.maxY,
               "A second double-click restores the current list below the same header")
    try expect(descendants(panel.panel.contentView!).compactMap { $0 as? CompletionCard }.count == 5,
               "Expanding retains the selected page size")
    let closeInHeader = descendants(header!).compactMap { $0 as? NSButton }.first!
    let buttonPoint = closeInHeader.convert(NSPoint(x: closeInHeader.bounds.midX, y: closeInHeader.bounds.midY), to: header!.superview)
    try expect(header!.hitTest(buttonPoint) === closeInHeader, "The close button keeps its own hit target")
    let planSteps: [ProgressStep] = (0..<7).map { index in
        let title = index == 4 ? L10n.text("설계 검토", "Design review") : "Step \(index + 1)"
        let status: ProgressStatus = index < 4 ? .completed : index == 4 ? .inProgress : .pending
        return ProgressStep(id: String(index), title: title, status: status)
    }
    let plan = SessionProgress(steps: planSteps, totalKnown: true)
    var progressing = SessionRow(event: events[0], activity: .running, isOpen: true, needsAttention: false, progress: plan)
    panel.showSessions([progressing], animateNew: false)
    panel.panel.contentView?.layoutSubtreeIfNeeded()
    let progressCard = descendants(panel.panel.contentView!).compactMap { $0 as? CompletionCard }.first!
    let progressLabel = descendants(progressCard).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "session-progress-label" }
    try expect(progressLabel?.stringValue.contains("5/7") == true, "The active fifth stage appears in the session row")
    try expect(progressLabel?.toolTip?.contains("Step 7") == true, "The full checklist remains available in the tooltip")
    let bar = descendants(progressCard).first { $0.identifier?.rawValue == "session-progress-bar" }
    try expect(bar != nil && bar!.bounds.width > 100 && bar!.bounds.height > 0, "The compact card includes a visible progress strip")
    try expect(progressCard.frame.height <= 48.1, "Progress never enlarges the compact session card")
    try expect(progressCard.bounds.contains(bar!.convert(bar!.bounds, to: progressCard)), "The progress strip stays inside its card")
    progressing.progress?.steps[4].status = .completed
    progressing.progress?.steps[5].status = .inProgress
    panel.showSessions([progressing], animateNew: false)
    let updatedProgress = descendants(panel.panel.contentView!).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "session-progress-label" }
    try expect(updatedProgress?.stringValue.contains("6/7") == true, "New plan state updates the existing session row")
    progressing.progress?.totalKnown = false
    panel.showSessions([progressing], animateNew: false)
    try expect(descendants(panel.panel.contentView!).allSatisfy { $0.identifier?.rawValue != "session-progress-bar" }, "An incomplete inventory does not draw an overall progress strip")
    progressing.progress = nil
    panel.showSessions([progressing], animateNew: false)
    try expect(descendants(panel.panel.contentView!).allSatisfy { $0.identifier?.rawValue != "session-progress-label" }, "Sessions without a plan retain their ordinary subtitle")
    panel.hide()
    print("PASS: \(checks) completion UI and persistence checks")
}

private final class SessionDiscoveryFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [LiveSession]?
    func set(_ value: [LiveSession]?) { lock.lock(); defer { lock.unlock() }; self.value = value }
    func read() throws -> [LiveSession] {
        lock.lock(); defer { lock.unlock() }
        guard let value else { throw CompletionError.unavailable }
        return value
    }
}
