import AppKit
import QuartzCore

enum CompletionColors {
    static let background = adaptive(light: 0.99, dark: 0.12)
    static let card = adaptive(light: 0.95, dark: 0.17)
    static let border = adaptive(light: 0.88, dark: 0.25)
    static let button = NSColor(calibratedRed: 0.14, green: 0.16, blue: 0.20, alpha: 1)
    private static func adaptive(light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(white: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light, alpha: 1)
        }
    }
}

final class CompletionSurface: NSView {
    private let fill: NSColor
    init(fill: NSColor, radius: CGFloat, border: Bool = true) {
        self.fill = fill
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = border ? 1 : 0
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill.cgColor
            layer?.borderColor = CompletionColors.border.cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class CompletionButton: NSButton {
    var perform: (() -> Void)?
    private let prominent: Bool
    private let plain: Bool
    init(_ title: String, symbol: String? = nil, prominent: Bool = false, plain: Bool = false, action: @escaping () -> Void) {
        self.prominent = prominent; self.plain = plain
        super.init(frame: .zero)
        self.title = title; self.perform = action
        target = self; self.action = #selector(invoke)
        font = .systemFont(ofSize: 12, weight: .semibold)
        isBordered = false
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        setButtonType(.momentaryChange)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { perform?() }
    override var intrinsicContentSize: NSSize {
        let text = (title as NSString).size(withAttributes: [.font: font!])
        if title.isEmpty, image != nil { return NSSize(width: 26, height: 26) }
        let height: CGFloat = controlSize == .mini ? 18 : controlSize == .small ? 24 : plain ? 28 : 36
        return NSSize(width: text.width + (image == nil ? 0 : 18) + (plain ? 0 : 24), height: height)
    }
    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor = isEnabled ? (prominent ? .white : .labelColor) : .tertiaryLabelColor
        if !plain {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
            (prominent ? CompletionColors.button : CompletionColors.background).setFill()
            path.fill()
            if !prominent { CompletionColors.border.setStroke(); path.lineWidth = 1; path.stroke() }
        }
        if isHighlighted {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font!, .foregroundColor: color, .paragraphStyle: paragraph]
        let size = (title as NSString).size(withAttributes: attributes)
        let textWidth = min(size.width, max(0, bounds.width - (image == nil ? 0 : 18) - (plain ? 0 : 24)))
        let totalWidth = textWidth + (image == nil ? 0 : 18)
        let x = alignment == .left ? 0 : (bounds.width - totalWidth) / 2
        (title as NSString).draw(in: NSRect(x: x, y: (bounds.height - size.height) / 2, width: textWidth, height: size.height), withAttributes: attributes)
        if let image {
            let tinted = image.withSymbolConfiguration(.init(paletteColors: [color])) ?? image
            let imageX = title.isEmpty ? (bounds.width - 13) / 2 : x + textWidth + 5
            tinted.draw(in: NSRect(x: imageX, y: (bounds.height - 13) / 2, width: 13, height: 13))
        }
    }
}

enum CompletionMotion {
    static let interval: TimeInterval = 12
    static func wiggle(size: NSSize, degrees: Double = 3) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "transform")
        // Layer transforms are relative to its center; pin the visual top-right corner.
        let pivot = CGPoint(x: size.width / 2, y: size.height / 2)
        let angles = [0, -degrees, degrees, -degrees, degrees, -degrees, degrees, 0]
        animation.values = angles.map { angle in
            let transform = CGAffineTransform(translationX: pivot.x, y: pivot.y)
                .rotated(by: angle * .pi / 180)
                .translatedBy(x: -pivot.x, y: -pivot.y)
            return NSValue(caTransform3D: CATransform3DMakeAffineTransform(transform))
        }
        animation.keyTimes = (0...7).map { NSNumber(value: Double($0) / 7) }
        animation.duration = 7 * 0.11
        animation.timingFunctions = (0..<7).map { _ in CAMediaTimingFunction(name: .easeInEaseOut) }
        return animation
    }
}
