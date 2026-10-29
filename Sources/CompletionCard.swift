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
        title.toolTip = event.project + "\n" + event.directory
        title.setAccessibilityLabel(L10n.text("\(event.project) 세션 열기", "Open \(event.project) session"))
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        let session = Self.label(event.sessionName, size: 11, color: .secondaryLabelColor)
        session.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let details = NSStackView(views: [title, session])
        details.orientation = .vertical; details.alignment = .leading; details.spacing = 1
        let icon = NSImageView()
        icon.image = ProviderIcon.image(event.provider, size: 20)
        icon.toolTip = event.provider.name + " · " + event.destination.label
        icon.setAccessibilityLabel(icon.toolTip!)
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let copy = CompletionButton("", symbol: "doc.on.doc", plain: true) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(SessionNavigator.resumeCommand(event), forType: .string)
        }
        copy.toolTip = L10n.text("재개 명령 복사", "Copy resume command")
        copy.setAccessibilityLabel(copy.toolTip!)
        copy.isEnabled = !preview
        copy.identifier = NSUserInterfaceItemIdentifier("completion-copy")
        let openButton = CompletionButton("", symbol: "arrow.up.right", plain: true, action: open)
        openButton.toolTip = L10n.text("세션 열기", "Open session")
        openButton.setAccessibilityLabel(openButton.toolTip!)
        openButton.identifier = NSUserInterfaceItemIdentifier("completion-open")
        openButton.isEnabled = !preview
        let dismiss = CompletionButton("", symbol: "checkmark", prominent: true, action: acknowledge)
        dismiss.toolTip = L10n.text("확인", "Dismiss")
        dismiss.setAccessibilityLabel(dismiss.toolTip!)
        dismiss.identifier = NSUserInterfaceItemIdentifier("completion-dismiss")
        [copy, openButton, dismiss].forEach {
            $0.controlSize = .small
            $0.widthAnchor.constraint(equalToConstant: 26).isActive = true
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let buttons = NSStackView(views: [copy, openButton, dismiss])
        buttons.spacing = 3
        let stack = NSStackView(views: [icon, details, NSView(), time, buttons])
        stack.alignment = .centerY; stack.spacing = 8
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
