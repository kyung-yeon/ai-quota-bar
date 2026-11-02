import AppKit

@MainActor private final class MenuActionFixture: NSObject {
    var received: NSMenuItem?
    @objc func run(_ item: NSMenuItem) { received = item }
}

@MainActor func panelControlsUITests(_ expect: (Bool, String) throws -> Void) throws {
    func all(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + all($0) } }
    func tintCoversBackdrop(_ window: NSWindow) -> Bool {
        window.contentView?.layoutSubtreeIfNeeded()
        guard let glass = all(window.contentView!).compactMap({ $0 as? CompletionGlass }).first,
              let tint = glass.subviews.first(where: { $0.identifier?.rawValue == "glass-tint" }) else { return false }
        return glass.bounds.width > 0 && glass.bounds.height > 0 && tint.frame == glass.bounds
    }
    let name = "AiQuotaBar.PanelControls.\(UUID().uuidString)"
    let prefs = UserDefaults(suiteName: name)!
    defer { prefs.removePersistentDomain(forName: name) }
    let screen = NSRect(x: 0, y: 0, width: 1728, height: 1084)
    let panel = CompletionPanel(visibleFrames: { [screen] }, preferences: prefs)
    panel.panel.alphaValue = 0; panel.panel.ignoresMouseEvents = true
    panel.onSend = { _, _, _, _ in }
    defer { panel.hide() }
    let message = SessionMessage("One\nTwo\nThree\nFour\nFive", role: .assistant)!
    let rows = (0..<25).map { index in
        SessionRow(event: CompletionEvent(id: "item-\(index)", providerID: "codex", sessionID: "session-\(index)",
            project: "Sample", directory: "/sample", sessionName: "Session \(index)", completedAt: Date(),
            destination: SessionDestination(host: .orca, target: "term_\(index)")), isOpen: true, message: message)
    }
    panel.showSessions(rows, animateNew: false)
    try expect(tintCoversBackdrop(panel.panel), "Floating tint covers the full material after initial layout")
    func cards() -> [CompletionCard] { all(panel.panel.contentView!).compactMap { $0 as? CompletionCard } }
    for size in [1, 2, 3] {
        panel.setPageSize(size)
        try expect(cards().count == size, "Small page selections immediately show the selected number even with previews and inputs")
    }
    panel.setPageSize(20)
    try expect(tintCoversBackdrop(panel.panel), "Floating tint follows window resizing after page-size changes")
    try expect(cards().count >= 4 && screen.contains(panel.panel.frame), "Only one editor's expansion is reserved, so four tall rows fit the reported monitor")
    let footer = all(panel.panel.contentView!).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "completion-page-label" }!
    try expect(footer.stringValue.contains(L10n.text("창에 맞춰", "fit in window")), "Footer explains when the window limits the requested page size")
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
    let settings = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
    settings.submenu = NSMenu(); menu.addItem(settings)
    let anchor = NSRect(x: 900, y: 1084, width: 180, height: 25)
    usage.show(menu: menu, anchor: anchor, visibleFrame: screen)
    let root = usage.panel.contentView!
    let firstFrame = card.view!.convert(card.view!.bounds, to: root)
    let secondFrame = secondCard.view!.convert(secondCard.view!.bounds, to: root)
    try expect(!firstFrame.intersects(secondFrame), "Menu-owned provider views remain separated instead of both resetting to the same origin")
    let effect = all(usage.panel.contentView!).compactMap { $0 as? NSVisualEffectView }.first!
    try expect(effect.isHidden, "Quota window is opaque when transparency is off")
    prefs.set(true, forKey: "floatingTransparency"); usage.updateAppearance()
    try expect(tintCoversBackdrop(usage.panel), "Usage tint covers the full material after initial layout")
    try expect(!effect.isHidden && effect.blendingMode == .behindWindow && usage.panel.alphaValue == 0,
        "The same transparency setting now affects the quota window background without fading its text")
    try expect(effect.maskImage != nil && effect.layer?.masksToBounds != true,
        "The usage backdrop uses the native rounded material mask")
    // At the endpoints there is either a solid fill or no backdrop. Unlike blur
    // strength, these two cases can be verified in an AppKit-rendered bitmap.
    func backgroundAlpha(_ root: NSView, at point: NSPoint) -> CGFloat {
        root.layoutSubtreeIfNeeded()
        let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
        root.cacheDisplay(in: root.bounds, to: bitmap)
        let x = Int(point.x * CGFloat(bitmap.pixelsWide) / root.bounds.width)
        let y = Int(point.y * CGFloat(bitmap.pixelsHigh) / root.bounds.height)
        return bitmap.colorAt(x: x, y: y)!.alphaComponent
    }
    for percent in [0, 100, 0] {
        panel.setTransparencyPercent(percent); usage.updateAppearance()
        let alpha = backgroundAlpha(usage.panel.contentView!, at: NSPoint(x: 3, y: usage.panel.contentView!.bounds.midY))
        try expect(percent == 0 ? alpha > 0.98 : alpha < 0.02,
            "Rendered usage background follows the \(percent) percent endpoint")
        try expect(all(usage.panel.contentView!).compactMap { $0 as? NSTextField }.allSatisfy { $0.alphaValue == 1 },
            "Transparency never fades quota text")
    }
    panel.setTransparencyPercent(70); usage.updateAppearance()
    reduce = true; usage.updateAppearance()
    try expect(effect.isHidden, "Quota window respects Reduce Transparency")
    reduce = false; usage.updateAppearance()
    try expect(screen.contains(usage.panel.frame), "Quota window fits below its status item within the current monitor")
    let hoverRow = all(root).compactMap { $0 as? NSButton }.first { $0.title == action.title }!
    let enter = NSEvent.enterExitEvent(with: .mouseEntered,
        location: hoverRow.convert(NSPoint(x: 10, y: 10), to: nil), modifierFlags: [], timestamp: 0,
        windowNumber: usage.panel.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
    hoverRow.mouseEntered(with: enter)
    try expect(hoverRow.isHighlighted, "Pointer entry highlights the top-level usage menu row")
    hoverRow.updateTrackingAreas()
    try expect(hoverRow.trackingAreas.contains { $0.options.contains([.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways]) },
        "Visible menu rows track pointer movement even when the menu-bar app is inactive")
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        hoverRow.appearance = NSAppearance(named: appearance)
        try expect(backgroundAlpha(hoverRow, at: NSPoint(x: hoverRow.bounds.midX, y: 3)) > 0.98,
            "Hover paints an opaque full-row highlight in \(appearance.rawValue)")
    }
    hoverRow.appearance = nil
    let settingsRow = all(root).compactMap { $0 as? NSButton }.first { $0.title == settings.title }!
    settingsRow.mouseEntered(with: enter)
    try expect(settingsRow.isHighlighted && !hoverRow.isHighlighted, "Moving onto Settings highlights only that row")
    hoverRow.mouseExited(with: enter)
    try expect(settingsRow.isHighlighted, "A late exit from the previous row leaves the current highlight intact")
    settingsRow.mouseExited(with: enter)
    try expect(!settingsRow.isHighlighted, "Leaving the row removes its highlight")
    try expect(backgroundAlpha(settingsRow, at: NSPoint(x: settingsRow.bounds.midX, y: 3)) < 0.02,
        "Leaving a row also removes the rendered background")
    hoverRow.mouseMoved(with: enter)
    let disabledRow = all(root).compactMap { $0 as? NSButton }.first { $0.title == disabled.title }!
    disabledRow.mouseEntered(with: enter)
    try expect(!disabledRow.isHighlighted && !hoverRow.isHighlighted, "Disabled rows never retain hover selection")
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
    let keyboardRow = all(root).compactMap { $0 as? NSButton }.first { $0.title == action.title }!
    try expect(keyboardRow.isHighlighted, "Keyboard selection uses the same row highlight")
    settingsRow.mouseEntered(with: enter)
    try expect(keyboardRow.isHighlighted, "Detached rows cannot change selection after a menu rebuild")
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
    try expect(tintCoversBackdrop(usage.panel), "Usage tint follows window resizing after a quota refresh")
    try expect(replacement.window === usage.panel && screen.contains(usage.panel.frame), "Live quota refresh mounts replacement views and keeps long menus on screen")
    let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: usage.panel.windowNumber,
        context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    usage.panel.keyDown(with: escape)
    try expect(!usage.isVisible, "Escape dismisses the quota popup")
}
