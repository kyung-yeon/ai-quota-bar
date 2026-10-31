import AppKit

final class SessionProgressBar: NSView {
    private let progress: SessionProgress
    init(progress: SessionProgress) {
        self.progress = progress
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("session-progress-bar")
        toolTip = progress.detail
        // The adjacent text exposes the checklist to assistive technology.
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        guard !progress.steps.isEmpty else { return }
        if progress.steps.count <= 20 {
            let count = CGFloat(progress.steps.count)
            let gap: CGFloat = 2
            let width = max(0, (bounds.width - gap * (count - 1)) / count)
            for (index, step) in progress.steps.enumerated() {
                color(step.status).setFill()
                NSBezierPath(roundedRect: NSRect(x: CGFloat(index) * (width + gap), y: 0, width: width, height: bounds.height), xRadius: 1, yRadius: 1).fill()
            }
        } else {
            // Very long lists use counts, avoiding subpixel segments.
            color(.pending).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 1, yRadius: 1).fill()
            let completed = bounds.width * CGFloat(progress.completedCount) / CGFloat(progress.steps.count)
            color(.completed).setFill()
            NSRect(x: 0, y: 0, width: completed, height: bounds.height).fill()
            color(.inProgress).setFill()
            NSRect(x: completed, y: 0, width: bounds.width * CGFloat(progress.activeIndices.count) / CGFloat(progress.steps.count), height: bounds.height).fill()
        }
    }
    private func color(_ status: ProgressStatus) -> NSColor {
        switch status {
        case .completed: return .systemGreen
        case .inProgress: return .systemBlue
        case .pending: return .tertiaryLabelColor
        }
    }
}
