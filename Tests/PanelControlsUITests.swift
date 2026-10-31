import AppKit

@MainActor private final class MenuActionFixture: NSObject {
    var received: NSMenuItem?
    @objc func run(_ item: NSMenuItem) { received = item }
}

@MainActor func panelControlsUITests(_ expect: (Bool, String) throws -> Void) throws {
    func all(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + all($0) } }
    let name = "AiQuotaBar.PanelControls.\(UUID().uuidString)"
    let prefs = UserDefaults(suiteName: name)!
    defer { prefs.removePersistentDomain(forName: name) }
    let screen = NSRect(x: 0, y: 0, width: 1728, height: 1084)
    let panel = CompletionPanel(visibleFrames: { [screen] }, preferences: prefs)
    panel.panel.alphaValue = 0; panel.panel.ignoresMouseEvents = true
    panel.onSend = { _, _, _ in }
    defer { panel.hide() }
    let message = SessionMessage("One\nTwo\nThree\nFour\nFive", role: .assistant)!
    let rows = (0..<25).map { index in
        SessionRow(event: CompletionEvent(id: "item-\(index)", providerID: "codex", sessionID: "session-\(index)",
            project: "Sample", directory: "/sample", sessionName: "Session \(index)", completedAt: Date(),
            destination: SessionDestination(host: .orca, target: "term_\(index)")), isOpen: true, message: message)
    }
    panel.showSessions(rows, animateNew: false)
    func cards() -> [CompletionCard] { all(panel.panel.contentView!).compactMap { $0 as? CompletionCard } }
    for size in [1, 2, 3] {
        panel.setPageSize(size)
        try expect(cards().count == size, "Small page selections immediately show the selected number even with previews and inputs")
    }
    panel.setPageSize(20)
    try expect(cards().count >= 4 && screen.contains(panel.panel.frame), "Only one editor's expansion is reserved, so four tall rows fit the reported monitor")
    let footer = all(panel.panel.contentView!).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "completion-page-label" }!
    try expect(footer.stringValue.contains(L10n.text("화면에 맞춰", "fit on screen")), "Footer explains when the display limits the requested page size")
    var visited = Set<String>()
    for _ in 0..<30 {
        let root = panel.panel.contentView!
        root.layoutSubtreeIfNeeded()
        visited.formUnion(cards().map { $0.row.id })
        let next = all(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "completion-next-page" }!
        let point = next.convert(NSPoint(x: next.bounds.midX, y: next.bounds.midY), to: root)
        try expect(root.hitTest(point) === next, "Next-page control is inside the visible hierarchy and receives real mouse hits")
        if !next.isEnabled { break }
        next.performClick(nil)
        panel.showSessions(rows, animateNew: true)
        try expect(!cards().contains { $0.row.id == rows[0].id }, "New completion refresh does not reset a later page to the first page")
    }
    try expect(visited == Set(rows.map(\.id)), "All sessions remain reachable without a list scrollbar")
    panel.hide()

    var reduce = false
    let usage = StatusMenuPanel(preferences: prefs, reduceTransparency: { reduce })
    usage.panel.alphaValue = 0; usage.panel.ignoresMouseEvents = true
    defer { usage.hide() }
    let menu = NSMenu(); menu.autoenablesItems = false
    let card = NSMenuItem(); card.view = ProviderCard(provider: .codex, state: Preview.sampleStates()[.codex]!)
    menu.addItem(card)
    let secondCard = NSMenuItem(); secondCard.view = ProviderCard(provider: .claude, state: Preview.sampleStates()[.claude]!)
    menu.addItem(secondCard)
    let target = MenuActionFixture()
    let action = NSMenuItem(title: "Sample action", action: #selector(MenuActionFixture.run(_:)), keyEquivalent: "r")
    action.target = target; action.tag = 3; action.representedObject = "codex"
    menu.addItem(action)
    let disabled = NSMenuItem(title: "Disabled", action: #selector(MenuActionFixture.run(_:)), keyEquivalent: "")
    disabled.target = target; disabled.isEnabled = false; menu.addItem(disabled)
    let anchor = NSRect(x: 900, y: 1084, width: 180, height: 25)
    usage.show(menu: menu, anchor: anchor, visibleFrame: screen)
    let root = usage.panel.contentView!
    let firstFrame = card.view!.convert(card.view!.bounds, to: root)
    let secondFrame = secondCard.view!.convert(secondCard.view!.bounds, to: root)
    try expect(!firstFrame.intersects(secondFrame), "Menu-owned provider views remain separated instead of both resetting to the same origin")
    let effect = all(usage.panel.contentView!).compactMap { $0 as? NSVisualEffectView }.first!
    try expect(effect.isHidden, "Quota window is opaque when transparency is off")
    func backgroundAlpha() -> CGFloat {
        let view = usage.panel.contentView!
        view.displayIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.colorAt(x: 8, y: bitmap.pixelsHigh / 2)!.alphaComponent
    }
    let opaqueAlpha = backgroundAlpha()
    prefs.set(true, forKey: "floatingTransparency"); usage.updateAppearance()
    try expect(!effect.isHidden && effect.blendingMode == .behindWindow && usage.panel.alphaValue == 0,
        "The same transparency setting now affects the quota window background without fading its text")
    let glassAlpha = backgroundAlpha()
    try expect(opaqueAlpha > 0.95 && glassAlpha < 0.9, "Rendered quota background changes from opaque to translucent when checked")
    reduce = true; usage.updateAppearance()
    try expect(effect.isHidden, "Quota window respects Reduce Transparency")
    reduce = false; usage.updateAppearance()
    try expect(screen.contains(usage.panel.frame), "Quota window fits below its status item within the current monitor")
    usage.invoke(1)
    try expect(target.received == nil && usage.isVisible, "Disabled menu actions cannot run")
    usage.invoke(0)
    try expect(target.received === action && target.received?.tag == 3 && target.received?.representedObject as? String == "codex" && !usage.isVisible,
        "Quota actions receive their original menu item with routing metadata and close the popup")
    usage.show(menu: menu, anchor: anchor, visibleFrame: screen)
    func key(_ code: UInt16, flags: NSEvent.ModifierFlags = [], characters: String = "") {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: usage.panel.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        _ = usage.panel.performKeyEquivalent(with: event)
    }
    target.received = nil
    key(125); key(124)
    try expect(target.received == nil && usage.isVisible, "Right Arrow never executes a selected leaf action")
    key(15, flags: .command, characters: "r")
    try expect(target.received === action, "Command shortcuts still dispatch the original menu item")
    let before = NSMenu(); before.autoenablesItems = false
    for title in ["Setup", "Refresh", "Quit"] {
        let item = NSMenuItem(title: title, action: #selector(MenuActionFixture.run(_:)), keyEquivalent: "")
        item.target = target; before.addItem(item)
    }
    usage.hide(); usage.show(menu: before, anchor: anchor, visibleFrame: screen)
    key(125); key(125)
    let after = NSMenu(); after.autoenablesItems = false
    for title in ["Refresh", "Quit"] {
        let item = NSMenuItem(title: title, action: #selector(MenuActionFixture.run(_:)), keyEquivalent: "")
        item.target = target; after.addItem(item)
    }
    usage.reload(menu: after); key(36)
    try expect(target.received?.title == "Refresh", "An async menu refresh cannot shift keyboard selection from Refresh to Quit")
    usage.show(menu: menu, anchor: anchor, visibleFrame: screen)
    let replacement = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 1800))
    card.view = replacement; usage.reload(menu: menu)
    try expect(replacement.window === usage.panel && screen.contains(usage.panel.frame), "Live quota refresh mounts replacement views and keeps long menus on screen")
    let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: usage.panel.windowNumber,
        context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    usage.panel.keyDown(with: escape)
    try expect(!usage.isVisible, "Escape dismisses the quota popup")
}
