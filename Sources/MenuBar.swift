import AppKit

enum ProviderIcon {
    static func image(_ provider: Provider, size: CGFloat) -> NSImage? {
        let file = Bundle.main.url(forResource: provider.asset, withExtension: "png", subdirectory: "Assets")
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Assets/\(provider.asset).png")
        guard let image = NSImage(contentsOf: file) else { return nil }
        image.size = NSSize(width: size, height: size)
        return image
    }
}

private final class QuotaBar: NSView {
    let remaining: Int
    let current: Bool
    init(frame: NSRect, remaining: Int, current: Bool) {
        self.remaining = remaining
        self.current = current
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        let color: NSColor = !current ? .tertiaryLabelColor : remaining <= 10 ? .systemRed : remaining <= 30 ? .systemOrange : .controlAccentColor
        color.setFill()
        let fill = NSRect(x: 0, y: 0, width: bounds.width * CGFloat(remaining) / 100, height: bounds.height)
        NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
    }
}

final class ProviderCard: NSView {
    override var isFlipped: Bool { true }
    private var y: CGFloat = 12
    private let inset: CGFloat = 18
    private let contentWidth: CGFloat = 364

    init(provider: Provider, state: ProviderState, now: Date = Date()) {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        let icon = NSImageView(frame: NSRect(x: inset, y: y, width: 24, height: 24))
        icon.image = ProviderIcon.image(provider, size: 24)
        icon.setAccessibilityLabel(provider.name)
        addSubview(icon)
        label(provider.name, x: inset + 34, y: y + 2, width: 160, size: 14, weight: .semibold)
        let badge = state.fetching ? L10n.text("갱신 중", "Refreshing") : state.summary(at: now)
        label(badge, x: 212, y: y + 3, width: 170, size: 11, color: .secondaryLabelColor, alignment: .right)
        y += 36

        if let failure = state.failure {
            let message: String
            switch failure {
            case .missingCLI: message = L10n.text("\(provider.name)를 설치하면 사용량이 표시됩니다.", "Install \(provider.name) to see your usage.")
            case .authentication: message = L10n.text("\(provider.name)에 로그인한 뒤 새로고침해 주세요.", "Sign in to \(provider.name), then refresh.")
            default: message = failure.localizedDescription
            }
            line(message, color: .secondaryLabelColor)
        }

        // Never keep another account's quota visible after sign-out or CLI removal.
        let showSnapshot = state.failure != .missingCLI && state.failure != .authentication
        if showSnapshot, let snapshot = state.snapshot {
            let fresh = state.failure == nil && !state.stale(at: now)
            if !fresh { line(L10n.text("마지막 조회 기준", "Last known usage"), color: .secondaryLabelColor) }
            for window in snapshot.windows.sorted(by: { ($0.windowDurationMins ?? 0) > ($1.windowDurationMins ?? 0) }) {
                let current = fresh && !window.expired(at: now)
                label(window.label, x: inset, y: y, width: 170, size: 12, weight: .medium)
                let percent = L10n.text("\(window.remaining)% 남음", "\(window.remaining)% left")
                label(percent, x: 200, y: y, width: 182, size: 12, weight: .semibold, alignment: .right)
                y += 22
                addSubview(QuotaBar(frame: NSRect(x: inset, y: y, width: contentWidth, height: 5), remaining: window.remaining, current: current))
                y += 11
                if let reset = window.resetsAt {
                    let text = window.expired(at: now)
                        ? L10n.text("초기화 시각 지남 · 새로고침 필요", "Reset time passed · refresh required")
                        : L10n.text("초기화 \(dateText(reset))", "Resets \(dateText(reset))")
                    line(text, size: 11, color: .secondaryLabelColor)
                } else { line(L10n.text("초기화 시각 제공 안 됨", "Reset time unavailable"), size: 11, color: .secondaryLabelColor) }
                y += 6
            }

            if let credits = snapshot.resetCredits {
                let current = fresh && !credits.hasExpiredDetails(at: now)
                let title = L10n.text("초기화권 \(max(0, credits.availableCount))장", "Reset passes · \(max(0, credits.availableCount))")
                line(title + (current ? "" : L10n.text(" · 갱신 필요", " · refresh required")), weight: .medium)
                if credits.availableCount > 0 {
                    let details = credits.availableDetails(at: now)
                    for credit in details.prefix(3) { line(creditExpiryText(credit), size: 11, color: .secondaryLabelColor) }
                    if details.count < credits.availableCount {
                        line(L10n.text("일부 유효기간 정보 제공 안 됨", "Some expiry details unavailable"), size: 11, color: .secondaryLabelColor)
                    }
                    if details.count > 3 { line(L10n.text("아래 메뉴에서 전체 유효기간 확인", "See all expiry dates below"), size: 11, color: .secondaryLabelColor) }
                }
            } else { line(L10n.text("초기화권 · 정보 제공 안 됨", "Reset passes · unavailable"), size: 11, color: .secondaryLabelColor) }
        } else if state.failure == nil {
            line(L10n.text("사용량을 확인하고 있습니다…", "Checking your usage…"), color: .secondaryLabelColor)
        }
        if let date = state.checkedAt, showSnapshot {
            y += 5
            line(L10n.text("확인 \(dateText(date.timeIntervalSince1970, format: "jms"))", "Checked \(dateText(date.timeIntervalSince1970, format: "jms"))"), size: 10, color: .tertiaryLabelColor)
        }
        frame.size.height = y + 8
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func line(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) {
        label(text, x: inset, y: y, width: contentWidth, size: size, weight: weight, color: color)
        y += size + 9
    }
    private func label(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat,
                       weight: NSFont.Weight = .regular, color: NSColor = .labelColor, alignment: NSTextAlignment = .left) {
        let field = NSTextField(labelWithString: text)
        field.frame = NSRect(x: x, y: y, width: width, height: size + 8)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.alignment = alignment
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = text
        addSubview(field)
    }
}

func creditExpiryText(_ credit: ResetCredit) -> String {
    credit.expiresAt.map { L10n.text("\(dateText($0, format: "yyyyMMMdjm"))까지", "Expires \(dateText($0, format: "yyyyMMMdjm"))") }
        ?? L10n.text("유효기간 제한 없음", "No expiration")
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var status: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var states = Dictionary(uniqueKeysWithValues: Provider.allCases.map { ($0, ProviderState()) })
    private var menuOpen = false
    private var cardItems: [Provider: NSMenuItem] = [:]
    private var refreshItem: NSMenuItem?
    private var completions: CompletionController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.autoenablesItems = false
        menu.delegate = self
        status.menu = menu
        if !CommandLine.arguments.contains("--smoke-test") {
            let completions = CompletionController()
            self.completions = completions
            completions.onCountChanged = { [weak self] _ in self?.render() }
            completions.start()
        }
        render()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.render()
                for provider in Provider.allCases where Date().timeIntervalSince(self.states[provider]?.attemptedAt ?? .distantPast) >= 300 {
                    self.refresh(provider)
                }
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    }

    @objc func refresh() { Provider.allCases.forEach { refresh($0) } }

    private func refresh(_ provider: Provider, allowKeychainPrompt: Bool = false) {
        guard states[provider]?.fetching == false else { return }
        states[provider]?.fetching = true
        states[provider]?.attemptedAt = Date()
        render()
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                await ProviderClient.fetch(provider, allowKeychainPrompt: allowKeychainPrompt)
            }.value
            guard let self else { return }
            self.states[provider]?.fetching = false
            switch result {
            case .success(let value):
                self.states[provider]?.snapshot = value
                self.states[provider]?.checkedAt = Date()
                self.states[provider]?.failure = nil
            case .failure(let error):
                self.states[provider]?.failure = error
                if error == .authentication || error == .missingCLI || error == .noData {
                    self.states[provider]?.snapshot = nil
                    self.states[provider]?.checkedAt = nil
                }
            }
            self.render()
            if CommandLine.arguments.contains("--smoke-test"), self.states.values.allSatisfy({ !$0.fetching }) {
                print("Status item visible: \(self.status.isVisible)")
                for p in Provider.allCases { print("\(p.name): \(self.states[p]!.summary(at: Date()))") }
                if let path = argument(after: "--preview") { Preview.write(states: self.states, path: path) }
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) { rebuildMenu(); menuOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false; rebuildMenu() }

    private func render() {
        let title = NSMutableAttributedString(string: "")
        let now = Date()
        for (index, provider) in Provider.allCases.enumerated() {
            if index > 0 { title.append(NSAttributedString(string: "   ")) }
            if let image = ProviderIcon.image(provider, size: 16) {
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
                title.append(NSAttributedString(attachment: attachment))
            } else { title.append(NSAttributedString(string: provider.name)) }
            title.append(NSAttributedString(string: " \(states[provider]!.summary(at: now))", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor]))
        }
        if let count = completions?.unreadCount, count > 0 {
            title.append(NSAttributedString(string: "  ● \(count)", attributes: [.foregroundColor: NSColor.controlAccentColor, .font: NSFont.systemFont(ofSize: 12, weight: .semibold)]))
        }
        status.button?.attributedTitle = title
        let summary = Provider.allCases.map { "\($0.name): \(states[$0]!.summary(at: now))" }.joined(separator: " · ")
        status.button?.toolTip = "AiQuotaBar · \(summary)"
        status.button?.setAccessibilityLabel("AiQuotaBar · \(summary)")
        if menuOpen {
            for provider in Provider.allCases {
                cardItems[provider]?.view = ProviderCard(provider: provider, state: states[provider]!)
            }
            let busy = states.values.contains { $0.fetching }
            refreshItem?.title = busy ? L10n.text("갱신 중…", "Refreshing…") : L10n.text("지금 새로고침", "Refresh now")
            refreshItem?.isEnabled = !busy
            menu.update()
        } else { rebuildMenu() }
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        cardItems.removeAll()
        for provider in Provider.allCases {
            let state = states[provider]!
            let card = NSMenuItem()
            card.view = ProviderCard(provider: provider, state: state)
            menu.addItem(card)
            cardItems[provider] = card
            if state.failure == .missingCLI || state.failure == .authentication {
                let title = state.failure == .missingCLI ? L10n.text("\(provider.name) 설치 안내…", "Install \(provider.name)…") : L10n.text("\(provider.name) 로그인 안내…", "Sign in to \(provider.name)…")
                let item = action(title, #selector(openSetup(_:)))
                item.representedObject = provider.rawValue
            }
            if state.failure == .keychainLocked { _ = action(L10n.text("Claude Code 키체인 접근 허용…", "Allow Claude Code Keychain access…"), #selector(allowKeychain)) }
            if let credits = state.snapshot?.resetCredits, credits.availableDetails(at: Date()).count > 3 {
                let item = NSMenuItem(title: L10n.text("모든 초기화권 유효기간", "All reset pass expiry dates"), action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for credit in credits.availableDetails(at: Date()) { submenu.addItem(withTitle: creditExpiryText(credit), action: nil, keyEquivalent: "") }
                item.submenu = submenu
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        let info = NSMenuItem(title: L10n.text("5분마다 갱신", "Refreshes every 5 minutes") + " · " + TimeZone.autoupdatingCurrent.identifier, action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        _ = action(L10n.text("완료 알림 보기", "Show completions") + " (\(completions?.unreadCount ?? 0))", #selector(showCompletions))
        let setup = NSMenuItem(title: L10n.text("완료 알림 연결", "Completion notifications"), action: nil, keyEquivalent: "")
        let setupMenu = NSMenu()
        for provider in Provider.allCases {
            for remove in [false, true] {
                let item = NSMenuItem(title: provider.name + " · " + (remove ? L10n.text("연결 해제…", "Disconnect…") : L10n.text("연결…", "Connect…")), action: #selector(configureCompletions(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = [provider.rawValue, remove ? "remove" : "install"]
                setupMenu.addItem(item)
            }
        }
        setup.submenu = setupMenu; menu.addItem(setup)
        let busy = states.values.contains { $0.fetching }
        let refresh = action(busy ? L10n.text("갱신 중…", "Refreshing…") : L10n.text("지금 새로고침", "Refresh now"), #selector(refresh as () -> Void), key: "r")
        refresh.isEnabled = !busy
        refreshItem = refresh
        _ = action(L10n.text("AiQuotaBar 종료", "Quit AiQuotaBar"), #selector(quit), key: "q")
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }
    @objc private func openSetup(_ item: NSMenuItem) {
        guard let value = item.representedObject as? String, let provider = Provider(rawValue: value) else { return }
        NSWorkspace.shared.open(provider.setupURL)
    }
    @objc private func allowKeychain() { refresh(.claude, allowKeychainPrompt: true) }
    @objc private func showCompletions() { completions?.show() }
    @objc private func configureCompletions(_ item: NSMenuItem) {
        guard let values = item.representedObject as? [String], let provider = Provider(rawValue: values[0]) else { return }
        completions?.configure(provider, remove: values[1] == "remove")
    }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
