import AppKit

final class CompletionCard: NSView {
    private let time = CompletionCard.label("", size: 11, color: .secondaryLabelColor)
    private let completedAt: Date
    let row: SessionRow
    private let spinner = SessionSpinner()
    private var messageView: SessionMessageView?
    private var cardHeight: NSLayoutConstraint!
    private var headerHeight: CGFloat { row.depth > 0 ? 36 : 48 }
    private var indentation: CGFloat { CGFloat(min(row.depth, 5)) * 14 }
    convenience init(event: CompletionEvent, open: @escaping () -> Void, acknowledge: @escaping () -> Void) {
        self.init(row: SessionRow(event: event), open: open, acknowledge: acknowledge)
    }
    init(row: SessionRow, open: @escaping () -> Void, acknowledge: @escaping () -> Void) {
        self.row = row
        let event = row.event
        completedAt = event.completedAt
        super.init(frame: .zero)
        wantsLayer = true
        identifier = NSUserInterfaceItemIdentifier(row.id)
        let surface = CompletionSurface(fill: CompletionColors.card, radius: 10)
        surface.alphaValue = !row.needsAttention && row.activity != .running ? 0.65 : 1
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        let title = CompletionButton(event.project, plain: true, action: open)
        title.font = .systemFont(ofSize: row.depth > 0 ? 12 : 13, weight: .semibold)
        title.controlSize = .mini
        title.alignment = .left
        title.foreground = !row.needsAttention && row.activity != .running ? .secondaryLabelColor : nil
        title.toolTip = event.project + "\n" + event.directory
        title.setAccessibilityLabel(L10n.text("\(event.project) 세션 열기", "Open \(event.project) session"))
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        let session = Self.label(row.progress?.summary ?? event.sessionName, size: row.depth > 0 ? 10 : 11, color: .secondaryLabelColor)
        if let progress = row.progress {
            session.identifier = NSUserInterfaceItemIdentifier("session-progress-label")
            session.lineBreakMode = .byTruncatingMiddle
            session.toolTip = event.sessionName + "\n\n" + progress.detail
            session.setAccessibilityLabel(progress.summary)
        }
        session.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let details = NSStackView(views: [title, session])
        details.orientation = .vertical; details.alignment = .leading; details.spacing = 1
        details.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let icon = NSImageView()
        let iconSize: CGFloat = row.depth > 0 ? 16 : 20
        icon.image = ProviderIcon.image(event.provider, size: iconSize)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.toolTip = event.provider.name + " · " + event.destination.label
        icon.setAccessibilityLabel(icon.toolTip!)
        icon.widthAnchor.constraint(equalToConstant: iconSize).isActive = true
        icon.heightAnchor.constraint(equalToConstant: iconSize).isActive = true
        let openButton = CompletionButton("", symbol: "arrow.up.right", plain: true, action: open)
        let openLabel = row.opensParent ? L10n.text("부모 세션 열기", "Open parent session") : L10n.text("세션 열기", "Open session")
        openButton.toolTip = openLabel
        openButton.setAccessibilityLabel(openLabel)
        openButton.identifier = NSUserInterfaceItemIdentifier("completion-open")
        let dismiss = CompletionButton("", symbol: "checkmark", prominent: true, action: acknowledge)
        dismiss.toolTip = L10n.text("확인", "Dismiss")
        dismiss.setAccessibilityLabel(dismiss.toolTip!)
        dismiss.identifier = NSUserInterfaceItemIdentifier("completion-dismiss")
        dismiss.isHidden = !row.needsAttention
        [openButton, dismiss].forEach {
            $0.controlSize = .small
            $0.widthAnchor.constraint(equalToConstant: 26).isActive = true
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let buttons = NSStackView(views: [openButton, dismiss])
        buttons.spacing = 3
        let status = NSStackView(views: [spinner, time])
        status.spacing = 4
        spinner.isHidden = row.activity != .running
        status.widthAnchor.constraint(equalTo: time.widthAnchor, constant: row.activity == .running ? 16 : 0).isActive = true
        let stack = NSView()
        [icon, details, status, buttons].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            stack.addSubview($0)
            $0.centerYAnchor.constraint(equalTo: stack.centerYAnchor).isActive = true
        }
        time.setContentHuggingPriority(.required, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(stack)
        if let progress = row.progress, progress.totalKnown {
            let bar = SessionProgressBar(progress: progress)
            bar.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: details.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: details.trailingAnchor),
                bar.topAnchor.constraint(equalTo: surface.topAnchor, constant: headerHeight - (row.depth > 0 ? 3 : 5)),
                bar.heightAnchor.constraint(equalToConstant: 2)
            ])
        }
        cardHeight = heightAnchor.constraint(equalToConstant: headerHeight)
        cardHeight.isActive = true
        if let message = row.message {
            let preview = SessionMessageView(message: message)
            preview.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(preview)
            messageView = preview
            NSLayoutConstraint.activate([
                preview.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 10),
                preview.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -10),
                preview.topAnchor.constraint(equalTo: surface.topAnchor, constant: headerHeight + 2),
                preview.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -8)
            ])
            fitMessage(width: 412)
        }
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor, constant: indentation),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: surface.topAnchor, constant: headerHeight / 2),
            stack.heightAnchor.constraint(equalToConstant: 34),
            icon.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            details.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: details.trailingAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: status.trailingAnchor, constant: 8),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            buttons.widthAnchor.constraint(equalToConstant: row.needsAttention ? 55 : 26),
            title.widthAnchor.constraint(equalTo: details.widthAnchor),
            session.widthAnchor.constraint(equalTo: details.widthAnchor)
        ])
        updateTime()
        setAccessibilityElement(false)
    }
    func fitMessage(width: CGFloat) {
        guard let messageView else { return }
        cardHeight.constant = headerHeight + 10 + messageView.fit(width: width - indentation - 20)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        guard indentation > 0 else { return }
        NSColor.separatorColor.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: indentation - 7, y: bounds.maxY))
        path.line(to: NSPoint(x: indentation - 7, y: bounds.midY))
        path.line(to: NSPoint(x: indentation - 1, y: bounds.midY))
        path.lineWidth = 1; path.stroke()
    }
    func setMotion(_ enabled: Bool) { spinner.setAnimating(enabled && row.activity == .running) }
    func updateTime() {
        if !row.needsAttention {
            switch row.activity {
            case .running: time.stringValue = L10n.text("작업 중", "Working")
            case .idle: time.stringValue = L10n.text("대기", "Idle")
            case .unknown: time.stringValue = L10n.text("열림", "Open")
            }
            time.setAccessibilityLabel(time.stringValue)
            return
        }
        let minutes = max(0, Int(Date().timeIntervalSince(completedAt) / 60))
        if minutes == 0 { time.stringValue = L10n.text("방금 전", "Just now") }
        else if minutes < 60 { time.stringValue = L10n.text("\(minutes)분 전", "\(minutes)m ago") }
        else if minutes < 1440 { time.stringValue = L10n.text("\(minutes / 60)시간 전", "\(minutes / 60)h ago") }
        else { time.stringValue = L10n.text("\(minutes / 1440)일 전", "\(minutes / 1440)d ago") }
        time.toolTip = dateText(completedAt.timeIntervalSince1970, format: "yMMMdjms")
        time.setAccessibilityLabel(time.toolTip!)
    }
    static func label(_ text: String, size: CGFloat, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size); field.textColor = color
        field.lineBreakMode = .byTruncatingTail; field.toolTip = text
        return field
    }
}

final class SessionSpinner: NSView {
    var isAnimating: Bool { layer?.animation(forKey: "working") != nil }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        widthAnchor.constraint(equalToConstant: 12).isActive = true
        heightAnchor.constraint(equalToConstant: 12).isActive = true
        setAccessibilityLabel(L10n.text("작업 중", "Working"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.setStroke()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: 6, y: 6), radius: 4, startAngle: 30, endAngle: 310)
        arc.lineWidth = 2; arc.lineCapStyle = .round; arc.stroke()
    }
    func setAnimating(_ enabled: Bool) {
        guard enabled else { layer?.removeAnimation(forKey: "working"); return }
        guard !isAnimating else { return }
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0; animation.toValue = -Double.pi * 2
        animation.duration = 0.9; animation.repeatCount = .infinity
        layer?.add(animation, forKey: "working")
    }
}
