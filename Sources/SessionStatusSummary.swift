import AppKit

/// Global session totals remain available even when the list is collapsed.
final class SessionStatusSummary: NSStackView {
    private let completed = StatusTag(color: .systemGreen, identifier: "completed")
    private let running = StatusTag(color: .systemBlue, identifier: "running")

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 6
        addArrangedSubview(completed)
        addArrangedSubview(running)
        completed.toolTip = L10n.text("아직 확인하지 않은 완료 응답 · 전체 세션", "Unacknowledged completions across all sessions")
        running.toolTip = L10n.text("현재 작업 중인 열린 세션 · 하위 에이전트 포함", "Open sessions currently working, including subagents")
        update([])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ rows: [SessionRow]) {
        let done = rows.filter(\.needsAttention).count
        let working = rows.filter { $0.isOpen && $0.activity == .running }.count
        completed.update(L10n.text("완료 \(done)건", "Done \(done)"), active: done > 0)
        running.update(L10n.text("작업 중 \(working)건", "Working \(working)"), active: working > 0)
    }
}

private final class StatusTag: NSView {
    private let background: CompletionSurface
    private let dot: CompletionSurface
    private let label = NSTextField(labelWithString: "")

    init(color: NSColor, identifier: String) {
        background = CompletionSurface(fill: color, radius: 10, border: false)
        dot = CompletionSurface(fill: color, radius: 3, border: false)
        super.init(frame: .zero)
        label.identifier = NSUserInterfaceItemIdentifier("session-status-\(identifier)")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [background, dot, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            background.leadingAnchor.constraint(equalTo: leadingAnchor), background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor), background.bottomAnchor.constraint(equalTo: bottomAnchor),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6), dot.heightAnchor.constraint(equalToConstant: 6),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        label.setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ text: String, active: Bool) {
        label.stringValue = text
        label.textColor = active ? .labelColor : .secondaryLabelColor
        background.fillOpacity = active ? 0.12 : 0.04
        dot.alphaValue = active ? 1 : 0.35
        setAccessibilityLabel(text)
    }
}
