import AppKit
import QuartzCore

private final class CompletionList: NSStackView {
    override var isFlipped: Bool { true }
}

private final class CompletionWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor final class CompletionPanel: NSObject, NSWindowDelegate {
    let panel: NSPanel
    private let chrome = CompletionSurface(fill: CompletionColors.background, radius: 14)
    private let list = CompletionList()
    private let stack = NSStackView()
    private let pagination = NSStackView()
    private let pageLabel = CompletionCard.label("", size: 11, color: .secondaryLabelColor)
    private let previous = CompletionButton("", symbol: "chevron.left", plain: true, action: {})
    private let next = CompletionButton("", symbol: "chevron.right", plain: true, action: {})
    private var displayedEvents: [CompletionEvent] = []
    private var isPreview = false
    private var pageIndex = 0
    private var pageSize = 3
    private let heading = CompletionCard.label("", size: 13)
    private let badge = CompletionCard.label("", size: 12)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let dismissAll: CompletionButton
    private var pulse: Timer?
    private var observers: [NSObjectProtocol] = []
    private var count = 0
    private let visibleFrames: () -> [NSRect]
    private let preferences: UserDefaults
    private let reduceMotion: () -> Bool
    private var positioning = true
    private let motionKey = "completionAttention"
    static let animationInset: CGFloat = 24
    var onOpen: ((CompletionEvent) -> Void)?
    var onAcknowledge: ((String) -> Void)?
    var onAcknowledgeAll: (() -> Void)?
    var onPreview: (() -> Void)?
    var activeWiggle: CAAnimation? { chrome.layer?.animation(forKey: motionKey) }

    init(visibleFrames: @escaping () -> [NSRect] = { NSScreen.screens.map(\.visibleFrame) },
         preferences: UserDefaults = .standard,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.visibleFrames = visibleFrames
        self.preferences = preferences
        self.reduceMotion = reduceMotion
        panel = CompletionWindow(contentRect: NSRect(x: 0, y: 0, width: 504, height: 360),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        dismissAll = CompletionButton(L10n.text("모두 확인", "Dismiss all"), plain: true, action: {})
        super.init()
        panel.delegate = self
        panel.title = L10n.text("AiQuotaBar 완료 알림", "AiQuotaBar completions")
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true; panel.level = .statusBar; panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.becomesKeyOnlyIfNeeded = true; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.setFrameAutosaveName("CompletionPanel")
        let canvas = NSView()
        canvas.wantsLayer = true
        panel.contentView = canvas
        chrome.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(chrome)
        dismissAll.perform = { [weak self] in self?.onAcknowledgeAll?() }
        dismissAll.controlSize = .small
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        badge.font = .systemFont(ofSize: 11, weight: .semibold)
        badge.alignment = .center
        badge.translatesAutoresizingMaskIntoConstraints = false
        let pill = CompletionSurface(fill: CompletionColors.card, radius: 10, border: false)
        pill.addSubview(badge)
        let header = NSStackView(views: [heading, pill, NSView(), dismissAll]); header.spacing = 8
        previous.identifier = NSUserInterfaceItemIdentifier("completion-previous-page")
        next.identifier = NSUserInterfaceItemIdentifier("completion-next-page")
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
        chrome.addSubview(stack)
        NSLayoutConstraint.activate([
            chrome.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: Self.animationInset),
            chrome.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -Self.animationInset),
            chrome.topAnchor.constraint(equalTo: canvas.topAnchor, constant: Self.animationInset),
            chrome.bottomAnchor.constraint(equalTo: canvas.bottomAnchor, constant: -Self.animationInset),
            stack.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: chrome.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: chrome.bottomAnchor, constant: -10),
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
            MainActor.assumeIsolated { if self?.reduceMotion() == true { self?.stopAnimation() } }
        })
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if self?.panel.isVisible == true { self?.panel.orderFrontRegardless() }
                }
            })
        }
        pulse = Timer.scheduledTimer(withTimeInterval: CompletionMotion.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.list.arrangedSubviews.compactMap { $0 as? CompletionCard }.forEach { $0.updateTime() }
                self?.animate()
            }
        }
        pulse?.tolerance = 0.5
        positioning = false
    }

    func show(_ events: [CompletionEvent], animateNew: Bool, preview: Bool = false) {
        count = events.count
        displayedEvents = events
        isPreview = preview
        if animateNew { pageIndex = 0 }
        clearList()
        guard !events.isEmpty else { stopAnimation(); panel.orderOut(nil); return }
        heading.stringValue = preview ? L10n.text("미리보기 · 예시 데이터", "Preview · Sample data")
            : L10n.text("응답 완료", "Completed")
        badge.stringValue = "\(events.count)"
        dismissAll.title = L10n.text("모두 확인", "Dismiss all")
        renderPage()
        position()
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        if animateNew { animate() }
    }

    private func renderPage() {
        clearList(resetError: false)
        let pages = max(1, (count + pageSize - 1) / pageSize)
        pageIndex = min(max(0, pageIndex), pages - 1)
        pagination.isHidden = pages == 1
        pageLabel.stringValue = "\(pageIndex + 1) / \(pages)"
        previous.isEnabled = pageIndex > 0
        next.isEnabled = pageIndex + 1 < pages
        for event in displayedEvents.dropFirst(pageIndex * pageSize).prefix(pageSize) {
            let card = CompletionCard(event: event, preview: isPreview, open: { [weak self] in self?.onOpen?(event) },
                                      acknowledge: { [weak self] in self?.onAcknowledge?(event.id) })
            addRow(card)
        }
    }

    private func changePage(_ offset: Int) {
        pageIndex += offset
        renderPage()
        position()
    }

    func showEmpty(_ message: String) {
        count = 0; displayedEvents = []; stopAnimation(); clearList()
        pagination.isHidden = true
        heading.stringValue = L10n.text("완료 알림 대기 중", "Waiting for completions")
        badge.stringValue = "0"
        let text = NSTextField(wrappingLabelWithString: message)
        text.font = .systemFont(ofSize: 13); text.textColor = .secondaryLabelColor
        addRow(text)
        addRow(CompletionButton(L10n.text("플로팅 미리보기", "Preview floating alert"), symbol: "play.fill") { [weak self] in self?.onPreview?() })
        dismissAll.title = L10n.text("닫기", "Close")
        position()
        panel.orderFrontRegardless()
    }

    func showError(_ message: String?) {
        errorLabel.stringValue = message ?? ""; errorLabel.isHidden = message == nil
        if panel.isVisible || message != nil { position() }
        if message != nil { panel.orderFrontRegardless() }
    }

    private func clearList(resetError: Bool = true) {
        if resetError { errorLabel.isHidden = true; errorLabel.stringValue = "" }
        list.arrangedSubviews.forEach { list.removeArrangedSubview($0); $0.removeFromSuperview() }
    }
    private func addRow(_ view: NSView) {
        list.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
    }

    private func position() {
        let screens = visibleFrames()
        guard !positioning, let primary = screens.first else { return }
        positioning = true
        defer { positioning = false }
        stopAnimation()
        let saved = preferences.bool(forKey: "completionPanelMoved")
        // Default to the primary display, then follow the display chosen by dragging.
        let currentScreen = saved ? screens.filter { $0.intersects(panel.frame) }.max {
            let lhs = $0.intersection(panel.frame), rhs = $1.intersection(panel.frame)
            return lhs.width * lhs.height < rhs.width * rhs.height
        } : nil
        let screenFrame = currentScreen ?? primary
        let visible = screenFrame.insetBy(dx: 8, dy: 8)
        let width = min(432 + Self.animationInset * 2, visible.width)
        if count > 0 {
            let capacity = min(3, max(1, Int((visible.height - 120) / 54)))
            if capacity != pageSize { pageSize = capacity; renderPage() }
        }
        panel.setContentSize(NSSize(width: width, height: panel.frame.height))
        // Measure the actual card layout so there is no clipped content or internal scrolling.
        var height = ceil(stack.fittingSize.height + 18 + Self.animationInset * 2)
        while height > visible.height && pageSize > 1 && count > 0 {
            pageSize -= 1
            renderPage()
            height = ceil(stack.fittingSize.height + 18 + Self.animationInset * 2)
        }
        height = min(height, visible.height)
        let old = panel.frame
        let x = currentScreen != nil ? min(max(old.minX, visible.minX), visible.maxX - width) : visible.maxX - width
        let y = currentScreen != nil ? min(max(old.maxY - height, visible.minY), visible.maxY - height) : visible.maxY - height
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    func windowWillMove(_ notification: Notification) {
        guard !positioning else { return }
        preferences.set(true, forKey: "completionPanelMoved")
        stopAnimation()
    }
    func windowDidMove(_ notification: Notification) {
        guard !positioning, NSEvent.pressedMouseButtons != 0 else { return }
        preferences.set(true, forKey: "completionPanelMoved")
        stopAnimation()
        // Never clamp during a drag: the window must be able to cross display edges.
    }
    func animate() {
        guard count > 0, panel.isVisible, !reduceMotion(), activeWiggle == nil else { return }
        chrome.layer?.add(CompletionMotion.wiggle(size: chrome.bounds.size), forKey: motionKey)
    }
    private func stopAnimation() { chrome.layer?.removeAnimation(forKey: motionKey) }
}
