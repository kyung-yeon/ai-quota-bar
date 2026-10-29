import AppKit
import QuartzCore

private final class CompletionButton: NSButton {
    var perform: (() -> Void)?
    convenience init(_ title: String, action: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        self.perform = action; self.target = self; self.action = #selector(invoke)
        bezelStyle = .rounded
        font = .systemFont(ofSize: 11)
    }
    @objc private func invoke() { perform?() }
}

private final class CompletionList: NSStackView {
    override var isFlipped: Bool { true }
}

final class CompletionCard: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    init(event: CompletionEvent, open: @escaping () -> Void, acknowledge: @escaping () -> Void) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        let icon = NSImageView()
        icon.image = ProviderIcon.image(event.provider, size: 20)
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let provider = Self.label(event.provider.name + " · " + event.destination.label, size: 11, color: .secondaryLabelColor)
        let header = NSStackView(views: [icon, provider]); header.spacing = 8
        let title = CompletionButton(event.project, action: open)
        title.isBordered = false; title.alignment = .left
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.toolTip = event.directory
        title.setAccessibilityLabel(L10n.text("\(event.project) 세션 열기", "Open \(event.project) session"))
        let session = Self.label(event.sessionName, size: 12)
        let time = Self.label(L10n.text("응답 완료 · ", "Response finished · ") + dateText(event.completedAt.timeIntervalSince1970, format: "MMMdjms"), size: 11, color: .secondaryLabelColor)
        let buttons = NSStackView(views: [
            CompletionButton(L10n.text("세션 열기", "Open session"), action: open),
            CompletionButton(L10n.text("재개 명령 복사", "Copy resume")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(SessionNavigator.resumeCommand(event), forType: .string)
            },
            CompletionButton(L10n.text("확인", "Dismiss"), action: acknowledge)
        ])
        buttons.spacing = 7
        let stack = NSStackView(views: [header, title, session, time, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            provider.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -28),
            session.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    static func label(_ text: String, size: CGFloat, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size); field.textColor = color
        field.lineBreakMode = .byTruncatingTail; field.toolTip = text
        return field
    }
}

@MainActor final class CompletionPanel: NSObject, NSWindowDelegate {
    let panel: NSPanel
    private let list = CompletionList()
    private let scroll = NSScrollView()
    private let heading = CompletionCard.label("", size: 14)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let dismissAll: CompletionButton
    private var pulse: Timer?
    private var observers: [NSObjectProtocol] = []
    private var count = 0
    var onOpen: ((CompletionEvent) -> Void)?
    var onAcknowledge: ((String) -> Void)?
    var onAcknowledgeAll: (() -> Void)?

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 260), styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        dismissAll = CompletionButton(L10n.text("모두 확인", "Dismiss all"), action: {})
        super.init()
        panel.delegate = self
        panel.title = L10n.text("AiQuotaBar 완료 알림", "AiQuotaBar completions")
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.setFrameAutosaveName("CompletionPanel")
        let visual = NSVisualEffectView()
        visual.material = .popover; visual.blendingMode = .behindWindow; visual.state = .active
        visual.wantsLayer = true
        panel.contentView = visual
        dismissAll.perform = { [weak self] in self?.onAcknowledgeAll?() }
        let header = NSStackView(views: [heading, NSView(), dismissAll]); header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.font = .systemFont(ofSize: 11); errorLabel.textColor = .systemOrange
        errorLabel.maximumNumberOfLines = 3
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 10
        list.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = list
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        visual.addSubview(header); visual.addSubview(scroll); visual.addSubview(errorLabel)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: visual.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: visual.trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: visual.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: visual.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: visual.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: errorLabel.topAnchor, constant: -8),
            errorLabel.leadingAnchor.constraint(equalTo: visual.leadingAnchor, constant: 16),
            errorLabel.trailingAnchor.constraint(equalTo: visual.trailingAnchor, constant: -16),
            errorLabel.bottomAnchor.constraint(equalTo: visual.bottomAnchor, constant: -10),
            list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        ])
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.position() }
        })
        pulse = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.animate() }
        }
    }

    func show(_ events: [CompletionEvent], animateNew: Bool) {
        count = events.count
        heading.stringValue = L10n.text("완료된 응답 \(events.count)개", "\(events.count) finished responses")
        list.arrangedSubviews.forEach { list.removeArrangedSubview($0); $0.removeFromSuperview() }
        // All unread events stay in the store; keep the live view bounded and expose the next batch on dismissal.
        for event in events.prefix(100) {
            let card = CompletionCard(event: event, open: { [weak self] in self?.onOpen?(event) }, acknowledge: { [weak self] in self?.onAcknowledge?(event.id) })
            list.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        if events.count > 100 {
            list.addArrangedSubview(CompletionCard.label(L10n.text("최근 100개 표시 · 확인하면 다음 항목이 표시됩니다.", "Showing newest 100 · dismiss to see older items."), size: 10))
        }
        guard !events.isEmpty else { panel.orderOut(nil); return }
        position()
        panel.orderFrontRegardless()
        if animateNew { animate() }
    }

    func showError(_ message: String?) {
        errorLabel.stringValue = message ?? ""
        if message != nil { panel.orderFrontRegardless() }
    }

    private func position() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let height = min(visible.height, CGFloat(min(count, 3)) * 165 + 100)
        let saved = UserDefaults.standard.bool(forKey: "completionPanelMoved")
        let old = panel.frame
        let width = min(390, visible.width)
        let x = saved ? min(max(old.minX, visible.minX), visible.maxX - width) : visible.maxX - width
        let y = saved ? min(max(old.maxY - height, visible.minY), visible.maxY - height) : visible.maxY - height
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    func windowDidMove(_ notification: Notification) {
        if NSEvent.pressedMouseButtons != 0 { UserDefaults.standard.set(true, forKey: "completionPanelMoved") }
    }

    private func animate() {
        guard count > 0, panel.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let movement = CAKeyframeAnimation(keyPath: "transform.translation.x")
        movement.values = [0, -4, 4, -3, 3, 0]; movement.duration = 0.5
        panel.contentView?.layer?.add(movement, forKey: "completionAttention")
    }
}
