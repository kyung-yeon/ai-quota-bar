import AppKit

private final class StatusMenuWindow: NSPanel {
    var handleKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if handleKey?(event) != true { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleKey?(event) == true || super.performKeyEquivalent(with: event)
    }
}

private final class StatusMenuContent: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { window?.keyDown(with: event) }
}

private final class StatusMenuButton: NSButton {
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
}

/// Own the usage window's backdrop; leave nested menus and their actions native.
@MainActor final class StatusMenuPanel: NSObject, NSWindowDelegate {
    let panel: NSPanel
    private let surface = CompletionSurface(fill: CompletionColors.background, radius: 14)
    private let effect = NSVisualEffectView()
    private let scroll = NSScrollView()
    private let content = StatusMenuContent()
    private let preferences: UserDefaults
    private let reduceTransparency: () -> Bool
    private var rows: [(NSMenuItem, NSButton)] = []
    private var selected = -1
    private var menu: NSMenu?
    private var anchor = NSRect.zero
    private var visibleFrame = NSRect.zero
    private var monitors: [Any] = []
    private var accessibilityObserver: NSObjectProtocol?
    private(set) var isTrackingSubmenu = false
    var onSubmenuClosed: (() -> Void)?
    var onClose: (() -> Void)?
    var isVisible: Bool { panel.isVisible }

    init(preferences: UserDefaults = .standard,
         reduceTransparency: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }) {
        self.preferences = preferences; self.reduceTransparency = reduceTransparency
        let window = StatusMenuWindow(contentRect: NSRect(x: 0, y: 0, width: 412, height: 500),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel = window
        super.init()
        panel.delegate = self
        panel.title = "AiQuotaBar"
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .popUpMenu; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = surface
        effect.material = .popover; effect.blendingMode = .behindWindow; effect.state = .active
        effect.wantsLayer = true; effect.layer?.cornerRadius = 14; effect.layer?.masksToBounds = true
        effect.identifier = NSUserInterfaceItemIdentifier("usage-transparency")
        surface.addSubview(effect)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.contentView.drawsBackground = false
        scroll.documentView = content
        surface.addSubview(scroll)
        panel.initialFirstResponder = content
        window.handleKey = { [weak self] event in self?.key(event) ?? false }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAppearance() }
        }
        updateAppearance()
    }

    func updateAppearance() {
        let enabled = preferences.bool(forKey: "floatingTransparency") && !reduceTransparency()
        effect.isHidden = !enabled
        effect.alphaValue = 0.65
        surface.fillOpacity = enabled ? 0.12 : 1
    }

    func show(menu: NSMenu, anchor: NSRect, visibleFrame: NSRect) {
        self.anchor = anchor; self.visibleFrame = visibleFrame
        selected = -1
        reload(menu: menu)
        panel.makeKeyAndOrderFront(nil)
        if monitors.isEmpty {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
                MainActor.assumeIsolated { if self?.isTrackingSubmenu == false { self?.hide() } }
            }) { monitors.append(monitor) }
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, !self.isTrackingSubmenu else { return }
                    if event.window !== self.panel && !self.anchor.contains(NSEvent.mouseLocation) { self.hide() }
                }
                return event
            }) { monitors.append(monitor) }
        }
    }

    func reload(menu: NSMenu) {
        guard !isTrackingSubmenu else { return }
        self.menu = menu
        let offset = scroll.contentView.bounds.origin.y
        let previousSelection = rows.indices.contains(selected) ? rows[selected].0 : nil
        rows = []; content.subviews.forEach { $0.removeFromSuperview() }
        let width: CGFloat = 400
        var y: CGFloat = 4
        for item in menu.items where !item.isHidden {
            if let view = item.view {
                // NSMenuItem-owned views reset their own origin to zero.
                // Position a host instead so successive providers cannot overlap.
                let host = NSView(frame: NSRect(x: 0, y: y, width: width, height: view.frame.height))
                content.addSubview(host); host.addSubview(view)
                view.frame.origin = .zero
                y += view.frame.height
            } else if item.isSeparatorItem {
                let separator = NSBox(frame: NSRect(x: 12, y: y + 5, width: width - 24, height: 1))
                separator.boxType = .separator; content.addSubview(separator); y += 12
            } else if !item.isEnabled && item.action == nil && item.submenu == nil {
                let label = NSTextField(labelWithString: item.title)
                label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor
                label.frame = NSRect(x: 12, y: y + 5, width: width - 24, height: 19)
                content.addSubview(label); y += 28
            } else {
                let button = StatusMenuButton(title: item.title, target: self, action: #selector(activate(_:)))
                button.tag = rows.count; button.isEnabled = item.isEnabled; button.isBordered = false
                button.alignment = .left; button.font = .systemFont(ofSize: 13)
                button.frame = NSRect(x: 12, y: y, width: width - 24, height: 28)
                button.setAccessibilityRole(.menuItem)
                button.setAccessibilityLabel(item.title)
                content.addSubview(button); rows.append((item, button))
                let suffix = item.submenu != nil ? "›" : item.keyEquivalent.isEmpty ? "" : "⌘ " + item.keyEquivalent.uppercased()
                if !suffix.isEmpty {
                    let label = NSTextField(labelWithString: suffix)
                    label.alignment = .right; label.font = .systemFont(ofSize: 13)
                    label.textColor = .secondaryLabelColor
                    label.frame = NSRect(x: button.bounds.width - 48, y: 5, width: 42, height: 18)
                    // Add to the button so clicking the accessory still activates this row.
                    button.addSubview(label)
                }
                y += 28
            }
        }
        content.frame = NSRect(x: 0, y: 0, width: width, height: y + 4)
        let height = min(y + 20, max(120, visibleFrame.height - 12))
        let frame = NSRect(x: min(max(anchor.maxX - 412, visibleFrame.minX + 6), visibleFrame.maxX - 418),
                           y: max(visibleFrame.minY + 6, min(anchor.minY - height - 4, visibleFrame.maxY - height)), width: 412, height: height)
        panel.setFrame(frame, display: true)
        effect.frame = surface.bounds
        scroll.frame = surface.bounds.insetBy(dx: 6, dy: 8)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(offset, max(0, content.frame.height - scroll.contentSize.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
        selected = previousSelection.flatMap { previous in rows.firstIndex { item, _ in
            item.title == previous.title && item.action == previous.action && item.target === previous.target
                && item.tag == previous.tag && item.representedObject as? String == previous.representedObject as? String
        } } ?? -1
        highlightSelection()
        updateAppearance()
    }

    @objc private func activate(_ button: NSButton) { invoke(button.tag) }
    func invoke(_ index: Int) {
        guard rows.indices.contains(index), rows[index].0.isEnabled else { return }
        let (item, button) = rows[index]
        if let submenu = item.submenu {
            isTrackingSubmenu = true
            let chosen = submenu.popUp(positioning: nil, at: NSPoint(x: button.bounds.maxX, y: button.bounds.maxY), in: button)
            isTrackingSubmenu = false
            onSubmenuClosed?()
            if !chosen && !panel.frame.contains(NSEvent.mouseLocation) { hide() }
        } else if let action = item.action {
            hide()
            NSApplication.shared.sendAction(action, to: item.target, from: item)
        }
    }

    private func key(_ event: NSEvent) -> Bool {
        guard isVisible else { return false }
        if event.modifierFlags.contains(.command) { return menu?.performKeyEquivalent(with: event) ?? false }
        if event.keyCode == 53 { hide(); return true }
        if event.keyCode == 125 || event.keyCode == 126 || event.keyCode == 48 {
            guard !rows.isEmpty else { return true }
            let step = event.keyCode == 126 || (event.keyCode == 48 && event.modifierFlags.contains(.shift)) ? -1 : 1
            for _ in rows.indices {
                selected = (selected + step + rows.count) % rows.count
                if rows[selected].0.isEnabled { break }
            }
            highlightSelection(); return true
        }
        if event.keyCode == 124 {
            if rows.indices.contains(selected), rows[selected].0.submenu != nil { invoke(selected) }
            return true
        }
        if [36, 76, 49].contains(event.keyCode), rows.indices.contains(selected) { invoke(selected); return true }
        return false
    }
    private func highlightSelection() {
        for (index, row) in rows.enumerated() { row.1.isHighlighted = index == selected }
        if rows.indices.contains(selected) { content.scrollToVisible(rows[selected].1.frame) }
    }
    func windowDidResignKey(_ notification: Notification) {
        if !isTrackingSubmenu { hide() }
    }
    func hide() {
        monitors.forEach { NSEvent.removeMonitor($0) }; monitors = []
        guard isVisible else { return }
        panel.orderOut(nil); onClose?()
    }
    deinit {
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }
}
