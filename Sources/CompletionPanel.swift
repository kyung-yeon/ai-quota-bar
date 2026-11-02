import AppKit
import QuartzCore

private final class CompletionList: NSStackView {
    override var isFlipped: Bool { true }
}

private final class CompletionWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class CompletionHeader: NSStackView {
    var onDoubleClick: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSButton ? hit : self
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { onDoubleClick?() }
        else { window?.performDrag(with: event) }
    }
}

@MainActor final class CompletionPanel: NSObject, NSWindowDelegate {
    let panel: NSPanel
    private let chrome = CompletionSurface(fill: CompletionColors.background, radius: 14)
    private let effect = CompletionGlass(material: .hudWindow)
    var translucent: Bool { preferences.bool(forKey: "floatingTransparency") }
    var transparencyPercent: Int { CompletionGlass.percentage(in: preferences) }
    private let reduceTransparency: () -> Bool
    private let list = CompletionList()
    private let stack = NSStackView()
    private let pagination = NSStackView()
    private let pageLabel = CompletionCard.label("", size: 11, color: .secondaryLabelColor)
    private let previous = CompletionButton("", symbol: "chevron.left", plain: true, action: {})
    private let next = CompletionButton("", symbol: "chevron.right", plain: true, action: {})
    private var displayedRows: [SessionRow] = []
    private var pendingRows: [SessionRow]?
    private var composers: [String: SessionComposer] = [:]
    var onSend: ((SessionRow, String, @escaping (Result<String, Error>) -> Void) -> Void)?
    private var editingComposer: SessionComposer? { composers.values.first(where: \.isEditing) }
    private var pageIndex = 0
    private var pageSize = 10
    static let pageSizeOptions = [1, 2, 3, 5, 10, 15, 20]
    var preferredPageSize: Int {
        let value = preferences.integer(forKey: "sessionPageSize")
        return Self.pageSizeOptions.contains(value) ? value : 10
    }
    private let heading = CompletionCard.label("", size: 13)
    private let badge = CompletionCard.label("", size: 12)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var timeRefresh: Timer?
    private var reminder: Timer?
    private let reminderKey = "unreadReminder"
    var activeReminder: CAAnimation? { chrome.layer?.animation(forKey: reminderKey) }
    private var observers: [NSObjectProtocol] = []
    private var count = 0
    private let visibleFrames: () -> [NSRect]
    private let preferences: UserDefaults
    private var isCollapsed: Bool
    private let reduceMotion: () -> Bool
    private var positioning = true
    private var liveResize = false
    private var userContentSize: NSSize?
    private var expandedContentSize: NSSize?
    private var minimumHeight: NSLayoutConstraint!
    static let windowInset: CGFloat = 24
    var onOpen: ((CompletionEvent) -> Void)?
    var onAcknowledge: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onMinimizeChanged: (() -> Void)?

    init(visibleFrames: @escaping () -> [NSRect] = { NSScreen.screens.map(\.visibleFrame) },
         preferences: UserDefaults = .standard,
         reduceTransparency: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency },
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.visibleFrames = visibleFrames
        self.preferences = preferences
        self.isCollapsed = preferences.bool(forKey: "sessionPanelCollapsed")
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        if let size = preferences.array(forKey: "sessionPanelContentSize") as? [Double], size.count == 2,
           size.allSatisfy({ $0.isFinite && $0 > 0 && $0 < 100_000 }) {
            userContentSize = NSSize(width: size[0], height: size[1])
        }
        panel = CompletionWindow(contentRect: NSRect(x: 0, y: 0, width: 504, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        panel.title = L10n.text("AiQuotaBar AI 세션", "AiQuotaBar AI sessions")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true; panel.level = .statusBar; panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.becomesKeyOnlyIfNeeded = true; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        if let saved = preferences.string(forKey: "sessionPanelFrame") {
            let frame = NSRectFromString(saved)
            if [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite), frame.width > 0, frame.height > 0 {
                panel.setFrame(frame, display: false)
            }
        } else if preferences === UserDefaults.standard {
            // Import the former borderless window's position once; test suites
            // and future saves use their own preferences instead of a global name.
            _ = panel.setFrameUsingName("CompletionPanel")
        }
        panel.standardWindowButton(.zoomButton)?.target = self
        panel.standardWindowButton(.zoomButton)?.action = #selector(zoomWindow)
        let canvas = NSView()
        canvas.wantsLayer = true
        panel.contentView = canvas
        chrome.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(chrome)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        badge.font = .systemFont(ofSize: 11, weight: .semibold)
        badge.alignment = .center
        badge.translatesAutoresizingMaskIntoConstraints = false
        let pill = CompletionSurface(fill: CompletionColors.card, radius: 10, border: false)
        pill.addSubview(badge)
        let header = CompletionHeader(views: [heading, pill, NSView()]); header.spacing = 8
        header.heightAnchor.constraint(equalToConstant: 26).isActive = true
        panel.initialFirstResponder = header
        header.identifier = NSUserInterfaceItemIdentifier("completion-header")
        header.toolTip = L10n.text("두 번 클릭하여 접기 또는 펼치기", "Double-click to collapse or expand")
        header.onDoubleClick = { [weak self] in self?.toggleCollapsed() }
        previous.identifier = NSUserInterfaceItemIdentifier("completion-previous-page")
        next.identifier = NSUserInterfaceItemIdentifier("completion-next-page")
        pageLabel.identifier = NSUserInterfaceItemIdentifier("completion-page-label")
        previous.setAccessibilityLabel(L10n.text("이전 알림", "Previous completions"))
        next.setAccessibilityLabel(L10n.text("다음 알림", "Next completions"))
        previous.perform = { [weak self] in self?.changePage(-1) }
        next.perform = { [weak self] in self?.changePage(1) }
        [NSView(), previous, pageLabel, next, NSView()].forEach { pagination.addArrangedSubview($0) }
        pagination.spacing = 12; pagination.isHidden = true
        errorLabel.font = .systemFont(ofSize: 11); errorLabel.textColor = .systemOrange
        errorLabel.maximumNumberOfLines = 3; errorLabel.isHidden = true
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 6
        list.translatesAutoresizingMaskIntoConstraints = false
        [header, list, pagination, errorLabel].forEach { stack.addArrangedSubview($0) }
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.translatesAutoresizingMaskIntoConstraints = false
        effect.identifier = NSUserInterfaceItemIdentifier("floating-transparency")
        chrome.addSubview(effect)
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: chrome.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: chrome.trailingAnchor),
            effect.topAnchor.constraint(equalTo: chrome.topAnchor),
            effect.bottomAnchor.constraint(equalTo: chrome.bottomAnchor)
        ])
        chrome.addSubview(stack)
        updateTransparency()
        minimumHeight = canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 0)
        NSLayoutConstraint.activate([
            canvas.widthAnchor.constraint(greaterThanOrEqualToConstant: 380), minimumHeight,
            chrome.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: Self.windowInset),
            chrome.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -Self.windowInset),
            chrome.topAnchor.constraint(equalTo: canvas.topAnchor, constant: Self.windowInset),
            chrome.bottomAnchor.constraint(equalTo: canvas.bottomAnchor, constant: -Self.windowInset),
            stack.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: chrome.topAnchor, constant: 8),
            pill.widthAnchor.constraint(greaterThanOrEqualToConstant: 24), pill.heightAnchor.constraint(equalToConstant: 20),
            pill.widthAnchor.constraint(equalTo: badge.widthAnchor, constant: 12),
            badge.centerXAnchor.constraint(equalTo: pill.centerXAnchor), badge.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            list.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pagination.widthAnchor.constraint(equalTo: stack.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.position() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.reduceMotion() {
                    self.stopRowMotion()
                    self.chrome.layer?.removeAnimation(forKey: self.reminderKey)
                }
                self.updateTransparency()
                self.updateActivityMotion()
            }
        })
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if self?.panel.isVisible == true { self?.present() }
                }
            })
        }
        timeRefresh = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.list.arrangedSubviews.compactMap { $0 as? CompletionCard }.forEach { $0.updateTime() }
            }
        }
        timeRefresh?.tolerance = 1
        reminder = Timer.scheduledTimer(withTimeInterval: CompletionMotion.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.remindUnread() }
        }
        reminder?.tolerance = 0.5
        positioning = false
    }

    func show(_ events: [CompletionEvent], animateNew: Bool) {
        guard !events.isEmpty else { displayedRows = []; count = 0; hide(); return }
        showSessions(events.map { SessionRow(event: $0) }, animateNew: animateNew)
    }

    func showSessions(_ rows: [SessionRow], animateNew: Bool) {
        if liveResize { pendingRows = rows; return }
        if editingComposer != nil {
            pendingRows = rows
            for composer in composers.values {
                if let current = rows.first(where: { $0.id == composer.row.id }) { composer.update(current) }
                else { var closed = composer.row; closed.isOpen = false; composer.update(closed) }
            }
            return
        }
        pendingRows = nil
        let ids = Set(rows.map(\.id))
        composers = composers.filter { ids.contains($0.key) || !$0.value.draft.isEmpty || $0.value.sending }
        let oldPositions = Dictionary(uniqueKeysWithValues: list.arrangedSubviews.compactMap { view -> (String, NSRect)? in
            guard let card = view as? CompletionCard else { return nil }
            var visible = card.convert(card.bounds, to: panel.contentView)
            if let layer = card.layer, let presentation = layer.presentation() {
                let remaining = presentation.frame.minY - layer.frame.minY
                visible.origin.y += card.superview?.isFlipped == true ? -remaining : remaining
            }
            return (card.row.id, panel.convertToScreen(visible))
        })
        count = rows.count
        displayedRows = rows
        // New completions still sort first, but never interrupt someone browsing a later page.
        clearList()
        guard !rows.isEmpty else { showEmpty(L10n.text("열려 있는 AI 세션을 기다리는 중입니다.", "Waiting for an open AI session.")); return }
        heading.stringValue = L10n.text("AI 세션", "AI sessions")
        badge.stringValue = "\(rows.count)"
        renderPage()
        position()
        present()
        panel.contentView?.layoutSubtreeIfNeeded()
        updateActivityMotion()
        if animateNew, !isCollapsed, !reduceMotion() {
            for card in list.arrangedSubviews.compactMap({ $0 as? CompletionCard }) {
                let current = panel.convertToScreen(card.convert(card.bounds, to: panel.contentView))
                let screenOffset = oldPositions[card.row.id].map { $0.minY - current.minY } ?? -20
                // The stack is flipped, while screen coordinates grow upward.
                // Screen-space positions also keep resizing from introducing a jump.
                let offset = card.superview?.isFlipped == true ? -screenOffset : screenOffset
                if abs(offset) > 1 {
                    let movement = CABasicAnimation(keyPath: "transform.translation.y")
                    movement.fromValue = offset; movement.toValue = 0; movement.duration = 0.6
                    movement.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    card.layer?.add(movement, forKey: "sessionPromotion")
                }
            }
        }
    }

    private func renderPage() {
        clearList(resetError: false)
        let pages = SessionTree.pages(displayedRows, capacity: pageSize)
        pageIndex = min(max(0, pageIndex), pages.count - 1)
        pagination.isHidden = isCollapsed || pages.count == 1
        pageLabel.stringValue = "\(pageIndex + 1) / \(pages.count)"
        if pageSize < preferredPageSize {
            pageLabel.stringValue += L10n.text(" · 창에 맞춰 \(pages[pageIndex].count)개", " · \(pages[pageIndex].count) fit in window")
        }
        pageLabel.toolTip = L10n.text("페이지당 최대 \(preferredPageSize)개 · 스크롤 없이 창 크기에 맞춥니다.", "Up to \(preferredPageSize) rows per page · fits the window without scrolling.")
        previous.isEnabled = pageIndex > 0
        next.isEnabled = pageIndex + 1 < pages.count
        for row in pages[pageIndex] {
            let composer = composers[row.id] ?? SessionComposer(row: row)
            composers[row.id] = composer
            composer.update(row)
            composer.onSend = { [weak self] row, text, done in
                guard let send = self?.onSend else { done(.failure(CompletionError.unavailable)); return }
                send(row, text, done)
            }
            composer.onLayoutChanged = { [weak self] in self?.position() }
            composer.onEditingEnded = { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.panel.isVisible, self.editingComposer == nil, let pending = self.pendingRows else { return }
                    self.showSessions(pending, animateNew: false)
                }
            }
            let card = CompletionCard(row: row, composer: onSend == nil ? nil : composer, open: { [weak self] in self?.onOpen?(row.event) },
                                      acknowledge: { [weak self] in self?.onAcknowledge?(row.event.id) })
            card.setTransparency(translucent && !reduceTransparency() ? transparencyPercent : 0)
            addRow(card)
        }
    }

    private func changePage(_ offset: Int) {
        panel.makeFirstResponder(nil)
        pageIndex += offset
        renderPage()
        position()
        updateActivityMotion()
    }

    func showEmpty(_ message: String) {
        count = 0; displayedRows = []; stopRowMotion(); clearList()
        pagination.isHidden = true
        heading.stringValue = L10n.text("AI 세션", "AI sessions")
        badge.stringValue = "0"
        let text = NSTextField(wrappingLabelWithString: message)
        text.font = .systemFont(ofSize: 13); text.textColor = .secondaryLabelColor
        addRow(text)
        position()
        present()
    }

    func showError(_ message: String?) {
        errorLabel.stringValue = message ?? ""; errorLabel.isHidden = isCollapsed || message == nil
        if panel.isVisible || message != nil { position() }
        if message != nil && panel.isVisible { present() }
    }

    func hide() {
        pendingRows = nil
        panel.makeFirstResponder(nil)
        stopRowMotion()
        list.arrangedSubviews.compactMap { $0 as? CompletionCard }.forEach { $0.setMotion(false) }
        panel.orderOut(nil)
    }

    private func present() {
        if !panel.isMiniaturized { panel.orderFrontRegardless() }
    }

    func restoreFromMiniaturized() {
        if panel.isMiniaturized { panel.deminiaturize(nil) }
    }

    func setTransparency(_ enabled: Bool) {
        preferences.set(enabled, forKey: "floatingTransparency")
        updateTransparency()
    }
    func setTransparencyPercent(_ value: Int) {
        guard CompletionGlass.percentages.contains(value) else { return }
        preferences.set(value, forKey: "backgroundTransparencyPercent")
        setTransparency(true)
    }
    private func updateTransparency() {
        let enabled = translucent && !reduceTransparency()
        effect.isHidden = !enabled
        effect.setTransparency(transparencyPercent)
        chrome.fillOpacity = enabled ? 0 : 1
        list.arrangedSubviews.compactMap { $0 as? CompletionCard }.forEach { $0.setTransparency(enabled ? transparencyPercent : 0) }
    }

    func setPageSize(_ value: Int) {
        guard Self.pageSizeOptions.contains(value) else { return }
        let latest = pendingRows ?? displayedRows
        pendingRows = nil
        panel.makeFirstResponder(panel.initialFirstResponder)
        preferences.set(value, forKey: "sessionPageSize")
        pageIndex = 0
        if panel.isVisible { showSessions(latest, animateNew: false) }
    }

    private func updateActivityMotion() {
        list.arrangedSubviews.compactMap { $0 as? CompletionCard }.forEach { $0.setMotion(panel.isVisible && !panel.isMiniaturized && !isCollapsed && !reduceMotion()) }
    }

    private func toggleCollapsed() {
        panel.makeFirstResponder(nil)
        if !isCollapsed { expandedContentSize = panel.contentRect(forFrameRect: panel.frame).size }
        isCollapsed.toggle()
        preferences.set(isCollapsed, forKey: "sessionPanelCollapsed")
        position()
        updateActivityMotion()
    }

    private func clearList(resetError: Bool = true) {
        if resetError { errorLabel.isHidden = true; errorLabel.stringValue = "" }
        list.arrangedSubviews.forEach { list.removeArrangedSubview($0); $0.removeFromSuperview() }
    }
    private func addRow(_ view: NSView) {
        list.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
    }

    private func tallestCardHeight(width: CGFloat) -> CGFloat {
        let cardWidth = width - Self.windowInset * 2 - 20
        return displayedRows.map { row -> CGFloat in
            let header: CGFloat = row.depth > 0 ? 36 : 48
            let input: CGFloat = onSend == nil ? 0 : 4 + (composers[row.id]?.preferredHeight ?? 50)
            guard let message = row.message else { return header + input + (input > 0 ? 8 : 0) }
            let textWidth = cardWidth - CGFloat(min(row.depth, 5)) * 14 - 44
            return header + 39 + CGFloat(SessionMessageView.tail(message, width: textWidth).lines) * 14 + input
        }.max() ?? 20
    }

    private var fixedContentHeight: CGFloat {
        26 + 18 + Self.windowInset * 2 + (count > 1 ? 32 : 0) + (errorLabel.stringValue.isEmpty ? 0 : 46)
    }
    private var editorReserve: CGFloat { onSend == nil ? 0 : 34 }
    private func minimumContentHeight(width: CGFloat) -> CGFloat {
        max(120, fixedContentHeight + tallestCardHeight(width: width) + 6 + editorReserve)
    }
    private func screenContainingWindow() -> NSRect? {
        let screens = visibleFrames()
        return screens.filter { $0.intersects(panel.frame) }.max {
            let lhs = $0.intersection(panel.frame), rhs = $1.intersection(panel.frame)
            return lhs.width * lhs.height < rhs.width * rhs.height
        } ?? screens.first
    }

    private func position() {
        let screens = visibleFrames()
        guard !positioning, !panel.isMiniaturized, let primary = screens.first else { return }
        positioning = true
        defer { positioning = false }
        stopRowMotion()
        let saved = preferences.bool(forKey: "completionPanelMoved")
        // Default to the primary display, then follow the display chosen by dragging.
        let currentScreen = saved ? screenContainingWindow() : nil
        let screenFrame = currentScreen ?? primary
        let visible = screenFrame.insetBy(dx: 8, dy: 8)
        let currentContent = panel.contentRect(forFrameRect: panel.frame).size
        let titleHeight = panel.frame.height - currentContent.height
        let maximumHeight = visible.height - titleHeight
        let width = min(max(380, liveResize ? currentContent.width : userContentSize?.width ?? 480), visible.width)
        list.isHidden = isCollapsed
        pagination.isHidden = isCollapsed || SessionTree.pages(displayedRows, capacity: pageSize).count == 1
        errorLabel.isHidden = isCollapsed || errorLabel.stringValue.isEmpty
        let minHeight = isCollapsed ? 0 : min(minimumContentHeight(width: width), maximumHeight)
        minimumHeight.constant = minHeight
        let requestedHeight = liveResize ? currentContent.height : userContentSize?.height
        let heightLimit = min(maximumHeight, max(minHeight, requestedHeight ?? maximumHeight))
        if count > 0 {
            // Use a stable capacity across pages, even when message lengths differ.
            let tallest = tallestCardHeight(width: width)
            // Only one editor has focus. Reserve its expansion once, not on every card.
            let capacity = min(preferredPageSize, max(1, Int((heightLimit - fixedContentHeight - editorReserve) / (tallest + 6))))
            if editingComposer == nil, capacity != pageSize { pageSize = capacity; renderPage() }
        }
        if !liveResize, width != currentContent.width {
            panel.setContentSize(NSSize(width: width, height: currentContent.height))
        }
        func fitMessages() {
            let cardWidth = width - Self.windowInset * 2 - 20
            list.arrangedSubviews.compactMap { $0 as? CompletionCard }.forEach { $0.fitMessage(width: cardWidth) }
        }
        fitMessages()
        // Measure the actual card layout so there is no clipped content or internal scrolling.
        var height = ceil(stack.fittingSize.height + 18 + Self.windowInset * 2)
        while height > heightLimit && pageSize > 1 && count > 0 && editingComposer == nil {
            pageSize -= 1
            renderPage()
            fitMessages()
            height = ceil(stack.fittingSize.height + 18 + Self.windowInset * 2)
        }
        if !isCollapsed { height = max(minHeight, requestedHeight == nil ? height : heightLimit) }
        height = min(height, maximumHeight) + titleHeight
        let old = panel.frame
        let x = currentScreen != nil ? min(max(old.minX, visible.minX), visible.maxX - width) : visible.maxX - width
        let y = currentScreen != nil ? min(max(old.maxY - height, visible.minY), visible.maxY - height) : visible.maxY - height
        let frame = NSRect(x: x, y: y, width: width, height: height)
        // Even setting an identical frame can replace AppKit's pre-zoom frame.
        if !liveResize, panel.frame != frame { panel.setFrame(frame, display: true) }
        preferences.set(NSStringFromRect(panel.frame), forKey: "sessionPanelFrame")
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        liveResize = true
        panel.makeFirstResponder(panel.initialFirstResponder)
        stopRowMotion()
    }
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard !positioning else { return frameSize }
        let content = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let width = max(380, content.width)
        let height = isCollapsed ? sender.contentRect(forFrameRect: sender.frame).height
            : max(content.height, minimumContentHeight(width: width))
        return sender.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: height)).size
    }
    func windowDidResize(_ notification: Notification) {
        guard !positioning, !panel.isMiniaturized else { return }
        let content = panel.contentRect(forFrameRect: panel.frame).size
        let height = isCollapsed ? userContentSize?.height ?? expandedContentSize?.height ?? 360 : content.height
        userContentSize = NSSize(width: content.width, height: height)
        preferences.set([Double(content.width), Double(height)], forKey: "sessionPanelContentSize")
        preferences.set(true, forKey: "completionPanelMoved")
        position()
    }
    func windowDidEndLiveResize(_ notification: Notification) {
        liveResize = false
        if let latest = pendingRows { showSessions(latest, animateNew: false) }
        else { position() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let onClose { onClose() } else { hide() }
        return false
    }
    @objc private func zoomWindow() {
        if isCollapsed { toggleCollapsed() }
        panel.makeFirstResponder(panel.initialFirstResponder)
        panel.zoom(nil)
    }
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
        screenContainingWindow()?.insetBy(dx: 8, dy: 8) ?? defaultFrame
    }
    func windowDidMiniaturize(_ notification: Notification) {
        stopRowMotion(); updateActivityMotion(); onMinimizeChanged?()
    }
    func windowDidDeminiaturize(_ notification: Notification) {
        position(); updateActivityMotion(); onMinimizeChanged?()
    }

    func windowWillMove(_ notification: Notification) {
        guard !positioning else { return }
        preferences.set(true, forKey: "completionPanelMoved")
        stopRowMotion()
    }
    func windowDidResignKey(_ notification: Notification) {
        panel.makeFirstResponder(panel.initialFirstResponder)
    }
    func windowDidMove(_ notification: Notification) {
        guard !positioning, !panel.isMiniaturized else { return }
        preferences.set(true, forKey: "completionPanelMoved")
        preferences.set(NSStringFromRect(panel.frame), forKey: "sessionPanelFrame")
        stopRowMotion()
        // Never clamp during a drag: the window must be able to cross display edges.
    }
    private func stopRowMotion() {
        list.arrangedSubviews.forEach { $0.layer?.removeAnimation(forKey: "sessionPromotion") }
        chrome.layer?.removeAnimation(forKey: reminderKey)
    }

    func remindUnread() {
        guard editingComposer == nil, panel.isVisible, !panel.isMiniaturized, displayedRows.contains(where: \.needsAttention), !reduceMotion(), activeReminder == nil,
              !list.arrangedSubviews.contains(where: { $0.layer?.animation(forKey: "sessionPromotion") != nil }) else { return }
        // Leave the promotion slide unobstructed and keep tall pages within their
        // transparent margin while reminding only about unacknowledged work.
        let degrees = min(3, atan(20 / max(1, chrome.bounds.height)) * 180 / .pi)
        chrome.layer?.add(CompletionMotion.wiggle(size: chrome.bounds.size, degrees: degrees), forKey: reminderKey)
    }
}
