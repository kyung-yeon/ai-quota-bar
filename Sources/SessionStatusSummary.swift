import AppKit

/// Global session totals remain available even when the list is collapsed.
final class SessionStatusSummary: NSStackView {
    private let all = StatusTag(color: .secondaryLabelColor, identifier: "all")
    private let completed = StatusTag(color: .systemGreen, identifier: "completed")
    private let running = StatusTag(color: .systemBlue, identifier: "running")
    var onSelect: ((SessionStatusFilter) -> Void)?
    var reminderLayer: CALayer? { completed.layer }
    var reminderSize: NSSize { completed.bounds.size }

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 6
        for (filter, tag) in [(SessionStatusFilter.all, all), (.completed, completed), (.running, running)] {
            addArrangedSubview(tag)
            tag.perform = { [weak self] in self?.onSelect?(filter) }
        }
        setHuggingPriority(.required, for: .horizontal)
        all.toolTip = L10n.text("전체 세션 보기", "Show all sessions")
        completed.toolTip = L10n.text("아직 확인하지 않은 완료 응답 · 전체 세션", "Unacknowledged completions across all sessions")
        running.toolTip = L10n.text("현재 작업 중인 열린 세션 · 하위 에이전트 포함", "Open sessions currently working, including subagents")
        update([])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func addAcknowledgementAction(_ button: NSButton) {
        insertArrangedSubview(button, at: 2)
    }

    func update(_ rows: [SessionRow], selected: SessionStatusFilter = .all) {
        for (filter, tag) in [(SessionStatusFilter.all, all), (.completed, completed), (.running, running)] {
            let count = rows.filter(filter.matches).count
            tag.update(filter.title(count: count), active: count > 0, selected: filter == selected)
        }
    }
}

private final class StatusTag: NSButton {
    private let background: CompletionSurface
    private let dot: CompletionSurface
    private let label = NSTextField(labelWithString: "")
    var perform: (() -> Void)?

    init(color: NSColor, identifier: String) {
        background = CompletionSurface(fill: color, radius: 10, border: false)
        dot = CompletionSurface(fill: color, radius: 3, border: false)
        super.init(frame: .zero)
        self.identifier = NSUserInterfaceItemIdentifier("session-filter-\(identifier)")
        wantsLayer = true
        title = ""; isBordered = false
        setButtonType(.pushOnPushOff)
        target = self; action = #selector(invoke)
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
        setAccessibilityRole(.button)
        label.setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func invoke() { perform?() }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func draw(_ dirtyRect: NSRect) { background.alphaValue = isHighlighted ? 0.8 : 1 }

    func update(_ text: String, active: Bool, selected: Bool) {
        state = selected ? .on : .off
        label.stringValue = text
        label.font = .systemFont(ofSize: 11, weight: selected ? .semibold : .medium)
        label.textColor = active || selected ? .labelColor : .secondaryLabelColor
        background.fillOpacity = selected ? 0.22 : active ? 0.12 : 0.04
        background.layer?.borderWidth = selected ? 1 : 0
        dot.alphaValue = active ? 1 : 0.35
        setAccessibilityLabel(text)
        setAccessibilityValue(selected ? 1 : 0)
    }
}
