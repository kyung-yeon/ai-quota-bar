import AppKit

// Finder uses points; include 1x and 2x TIFF representations for Retina displays.
let size = NSSize(width: 640, height: 420)
let image = NSImage(size: size)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
}

for scale in [1, 2] {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 640 * scale, pixelsHigh: 420 * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    bitmap.size = size
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = context
    NSGradient(starting: color(250, 252, 253), ending: color(237, 248, 245))!
        .draw(in: NSRect(origin: .zero, size: size), angle: -90)

    func text(_ value: String, top: CGFloat, font: NSFont, ink: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let label = NSAttributedString(string: value, attributes: attributes)
        let bounds = label.size()
        label.draw(at: NSPoint(x: (size.width - bounds.width) / 2, y: size.height - top - bounds.height))
    }

    text("AiQuotaBar", top: 40, font: .systemFont(ofSize: 30, weight: .semibold), ink: color(30, 43, 47))
    text("Drag to Applications to install", top: 91, font: .systemFont(ofSize: 16, weight: .medium), ink: color(54, 73, 78))
    text("응용 프로그램 폴더로 드래그하여 설치하세요", top: 117, font: .systemFont(ofSize: 13), ink: color(104, 122, 126))

    color(98, 155, 142).setStroke()
    let arrow = NSBezierPath()
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 295, y: 210))
    arrow.line(to: NSPoint(x: 345, y: 210))
    arrow.move(to: NSPoint(x: 334, y: 221))
    arrow.line(to: NSPoint(x: 345, y: 210))
    arrow.line(to: NSPoint(x: 334, y: 199))
    arrow.stroke()

    text("Then open AiQuotaBar from Applications.", top: 340, font: .systemFont(ofSize: 12), ink: color(104, 122, 126))
    text("복사가 끝나면 응용 프로그램에서 실행하세요", top: 361, font: .systemFont(ofSize: 11), ink: color(104, 122, 126))
    NSGraphicsContext.restoreGraphicsState()
    image.addRepresentation(bitmap)
}

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift Tools/render-dmg-background.swift <output.tiff>")
}
try image.tiffRepresentation(using: .lzw, factor: 1)!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
