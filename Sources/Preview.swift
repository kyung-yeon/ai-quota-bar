import AppKit

enum Preview {
    static func sampleStates() -> [Provider: ProviderState] {
        let now = Date()
        let reset = now.addingTimeInterval(6 * 86400).timeIntervalSince1970
        let passes = ResetCredits(availableCount: 2, credits: [
            ResetCredit(id: "preview-1", resetType: "codexRateLimits", status: "available", expiresAt: now.addingTimeInterval(86400).timeIntervalSince1970),
            ResetCredit(id: "preview-2", resetType: "codexRateLimits", status: "available", expiresAt: now.addingTimeInterval(3 * 86400).timeIntervalSince1970)
        ])
        return [
            .codex: ProviderState(snapshot: QuotaSnapshot(windows: [QuotaWindow(usedPercent: 2, windowDurationMins: 10080, resetsAt: reset)], resetCredits: passes), checkedAt: now),
            .claude: ProviderState(snapshot: QuotaSnapshot(windows: [QuotaWindow(usedPercent: 32, windowDurationMins: 300, resetsAt: now.addingTimeInterval(7200).timeIntervalSince1970), QuotaWindow(usedPercent: 61, windowDurationMins: 10080, resetsAt: reset)], resetCredits: nil), checkedAt: now)
        ]
    }

    static func write(states: [Provider: ProviderState], path: String) {
        let cards = Provider.allCases.map { ProviderCard(provider: $0, state: states[$0]!) }
        let height = cards.reduce(CGFloat(64)) { $0 + $1.frame.height + 1 }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: height))
        view.wantsLayer = true
        view.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
        view.appearance?.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        var top = height - 8
        for card in cards {
            top -= card.frame.height
            card.frame.origin = NSPoint(x: 0, y: top)
            view.addSubview(card)
            let separator = NSBox(frame: NSRect(x: 18, y: top - 1, width: 364, height: 1))
            separator.boxType = .separator
            view.addSubview(separator)
            top -= 1
        }
        let footer = NSTextField(labelWithString: "AiQuotaBar · " + L10n.text("5분마다 갱신", "Refreshes every 5 minutes"))
        footer.frame = NSRect(x: 18, y: 15, width: 364, height: 20)
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        view.addSubview(footer)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            do { try png.write(to: URL(fileURLWithPath: path)); print("Preview: \(path)") }
            catch { fputs("Preview write failed\n", stderr) }
        }
    }
}
