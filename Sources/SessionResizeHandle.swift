import AppKit

/// A visible bottom-right grip, in addition to the native window resize edges.
final class SessionResizeHandle: NSView {
    var onBegin: (() -> Void)?
    var onResize: ((NSRect) -> Void)?
    var onEnd: (() -> Void)?
    private var dragStart: (frame: NSRect, pointer: NSPoint)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("session-resize-handle")
        toolTip = L10n.text("드래그하여 창 크기 조절", "Drag to resize the window")
        setAccessibilityLabel(toolTip!)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        if #available(macOS 15, *) {
            addCursorRect(bounds, cursor: .frameResize(position: .bottomRight, directions: .all))
        } else {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setStroke()
        for offset in [CGFloat(4), 8, 12] {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: bounds.maxX - offset, y: 3))
            line.line(to: NSPoint(x: bounds.maxX - 3, y: offset))
            line.lineWidth = 1
            line.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStart = (window.frame, window.convertPoint(toScreen: event.locationInWindow))
        onBegin?()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, let start = dragStart else { return }
        let pointer = window.convertPoint(toScreen: event.locationInWindow)
        let width = max(1, start.frame.width + pointer.x - start.pointer.x)
        let height = max(1, start.frame.height - pointer.y + start.pointer.y)
        onResize?(NSRect(x: start.frame.minX, y: start.frame.maxY - height, width: width, height: height))
    }
    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
        onEnd?()
    }
}
