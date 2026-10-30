import AppKit

enum Preview {
    static func completionEvents() -> [CompletionEvent] {
        let projects = ["website", "api-service"]
        let names = [L10n.text("계정 설정 화면 개선", "Update account settings"), L10n.text("API 통합 테스트 추가", "Add API integration tests")]
        var demo: [CompletionEvent] = []
        for index in projects.indices {
            let provider = index % 2 == 0 ? "codex" : "claude"
            let destination = SessionDestination(host: index % 2 == 0 ? .cmux : .orca, target: "demo")
            let completedAt = Date().addingTimeInterval(Double(-index * 75))
            demo.append(CompletionEvent(id: "demo-\(index)", providerID: provider, sessionID: "sample-session-\(index)",
                project: projects[index], directory: "/projects/sample", sessionName: names[index], completedAt: completedAt, destination: destination))
        }
        return demo
    }

    @MainActor static func completions(path: String) {
        let panel = CompletionPanel()
        panel.panel.alphaValue = 0
        panel.panel.ignoresMouseEvents = true
        let demo = completionEvents()
        panel.panel.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
        let idle = CompletionEvent(id: "demo-idle", providerID: "codex", sessionID: "sample-idle",
            project: "design-system", directory: "/projects/sample", sessionName: L10n.text("컴포넌트 정리", "Organize components"),
            completedAt: Date(), destination: SessionDestination())
        let child = CompletionEvent(id: "demo-child", providerID: "codex", sessionID: "sample-child",
            project: "reviewer", directory: "/projects/sample", sessionName: L10n.text("예시 모델", "Example model"),
            completedAt: Date(), destination: demo[0].destination)
        let planTitles = [L10n.text("요구 사항 확인", "Review requirements"), L10n.text("구조 설계", "Design structure"),
                          L10n.text("구현", "Implementation"), L10n.text("검증", "Validation"),
                          L10n.text("설계 검토", "Design review"), L10n.text("테스트", "Tests"), L10n.text("마무리", "Finalize")]
        let steps: [ProgressStep] = planTitles.enumerated().map { index, title in
            let status: ProgressStatus = index < 4 ? .completed : index == 4 ? .inProgress : .pending
            return ProgressStep(id: String(index), title: title, status: status)
        }
        let progress = SessionProgress(steps: steps, totalKnown: true)
        let childProgress = SessionProgress(steps: [ProgressStep(id: "1", title: L10n.text("변경 사항 검토", "Review changes"), status: .inProgress), ProgressStep(id: "2", title: L10n.text("결과 정리", "Summarize findings"), status: .pending)], totalKnown: true)
        panel.showSessions(SessionTree.order([SessionRow(event: demo[0]),
                            SessionRow(event: child, activity: .running, isOpen: true, needsAttention: false, parentID: demo[0].sessionKey, opensParent: true, progress: childProgress),
                            SessionRow(event: demo[1], activity: .running, isOpen: true, needsAttention: false, progress: progress),
                            SessionRow(event: idle, isOpen: true, needsAttention: false)]), animateNew: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let view = panel.panel.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            do { try data.write(to: URL(fileURLWithPath: path)); print("Completion preview: \(path)") }
            catch { fputs("Preview write failed\n", stderr) }
        }
        panel.panel.orderOut(nil)
    }

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
