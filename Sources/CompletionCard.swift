import AppKit

final class CompletionCard: NSView {
    private let time = CompletionCard.label("", size: 11, color: .secondaryLabelColor)
    private let completedAt: Date
    init(event: CompletionEvent, preview: Bool = false, open: @escaping () -> Void, acknowledge: @escaping () -> Void) {
        completedAt = event.completedAt
        super.init(frame: .zero)
        let surface = CompletionSurface(fill: CompletionColors.card, radius: 10)
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        let title = CompletionButton(event.project, plain: true, action: open)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.controlSize = .mini
        title.alignment = .left
        title.isEnabled = !preview
        let previewHint = L10n.text("예시 알림에는 연결된 세션이 없습니다.", "Sample alerts have no connected session.")
        title.toolTip = preview ? previewHint : event.project + "\n" + event.directory
        title.setAccessibilityLabel(L10n.text("\(event.project) 세션 열기", "Open \(event.project) session"))
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        let session = Self.label(event.sessionName, size: 11, color: .secondaryLabelColor)
        session.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let details = NSStackView(views: [title, session])
        details.orientation = .vertical; details.alignment = .leading; details.spacing = 1
        details.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let icon = NSImageView()
        icon.image = ProviderIcon.image(event.provider, size: 20)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.toolTip = event.provider.name + " · " + event.destination.label
        icon.setAccessibilityLabel(icon.toolTip!)
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let openButton = CompletionButton("", symbol: "arrow.up.right", plain: true, action: open)
        let openLabel = L10n.text("세션 열기", "Open session")
        openButton.toolTip = preview ? previewHint : openLabel
        openButton.setAccessibilityLabel(openLabel)
        openButton.identifier = NSUserInterfaceItemIdentifier("completion-open")
        openButton.isEnabled = !preview
        let dismiss = CompletionButton("", symbol: "checkmark", prominent: true, action: acknowledge)
        dismiss.toolTip = L10n.text("확인", "Dismiss")
        dismiss.setAccessibilityLabel(dismiss.toolTip!)
        dismiss.identifier = NSUserInterfaceItemIdentifier("completion-dismiss")
        [openButton, dismiss].forEach {
            $0.controlSize = .small
            $0.widthAnchor.constraint(equalToConstant: 26).isActive = true
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let buttons = NSStackView(views: [openButton, dismiss])
        buttons.spacing = 3
        let stack = NSView()
        [icon, details, time, buttons].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            stack.addSubview($0)
            $0.centerYAnchor.constraint(equalTo: stack.centerYAnchor).isActive = true
        }
        time.setContentHuggingPriority(.required, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(stack)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 48),
            stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 34),
            icon.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            details.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            time.leadingAnchor.constraint(equalTo: details.trailingAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: time.trailingAnchor, constant: 8),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            buttons.widthAnchor.constraint(equalToConstant: 55),
            title.widthAnchor.constraint(equalTo: details.widthAnchor),
            session.widthAnchor.constraint(equalTo: details.widthAnchor)
        ])
        updateTime()
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func updateTime() {
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
