import AppKit

/// Shows the last five rendered lines, including the tail of a long paragraph.
final class SessionMessageView: NSView {
    private let heading: NSTextField
    private let body: NSTextField
    private let message: SessionMessage
    private(set) var displayedLineCount = 0
    var displayedText: String { body.stringValue }
    override var isFlipped: Bool { true }

    init(message: SessionMessage) {
        self.message = message
        heading = NSTextField(labelWithString: message.label)
        body = NSTextField(wrappingLabelWithString: "")
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("session-message")
        heading.font = .systemFont(ofSize: 10, weight: .medium)
        heading.textColor = .secondaryLabelColor
        body.font = .systemFont(ofSize: 11)
        body.textColor = .labelColor
        body.maximumNumberOfLines = 5
        body.lineBreakMode = .byWordWrapping
        body.cell?.wraps = true
        [heading, body].forEach { addSubview($0) }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func tail(_ message: SessionMessage, width: CGFloat) -> (text: String, lines: Int) {
        let storage = NSTextStorage(string: message.text, attributes: [.font: NSFont.systemFont(ofSize: 11)])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: max(20, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        var ranges: [NSRange] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, range, _ in
            ranges.append(range)
        }
        guard let first = ranges.suffix(5).first else { return ("", 0) }
        let characters = manager.characterRange(forGlyphRange: NSRange(location: first.location, length: manager.numberOfGlyphs - first.location), actualGlyphRange: nil)
        return ((message.text as NSString).substring(with: characters), min(5, ranges.count))
    }

    @discardableResult func fit(width: CGFloat) -> CGFloat {
        // NSTextField has a two-point inset on either side of its text cell.
        let contentWidth = max(20, width - 20)
        let excerpt = Self.tail(message, width: contentWidth - 4)
        displayedLineCount = excerpt.lines
        body.stringValue = excerpt.text
        heading.frame = NSRect(x: 10, y: 6, width: contentWidth, height: 13)
        body.frame = NSRect(x: 10, y: 21, width: contentWidth, height: CGFloat(excerpt.lines) * 14 + 2)
        setAccessibilityLabel(message.label + "\n" + excerpt.text)
        return 29 + CGFloat(excerpt.lines) * 14
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}
