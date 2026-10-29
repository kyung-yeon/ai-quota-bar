import AppKit

@MainActor final class CompletionController {
    private let store: CompletionStore
    private let panel = CompletionPanel()
    private var timer: Timer?
    private var loading = false
    private var events: [CompletionEvent] = []
    var onCountChanged: ((Int) -> Void)?
    var unreadCount: Int { events.count }

    init(store: CompletionStore = .standard) {
        self.store = store
        panel.onOpen = { [weak self] event in
            Task { @MainActor in
                do { try await SessionNavigator.open(event.destination); self?.panel.showError(nil) }
                catch { self?.panel.showError(error.localizedDescription) }
            }
        }
        panel.onAcknowledge = { [weak self] id in self?.acknowledge(id) }
        panel.onAcknowledgeAll = { [weak self] in self?.acknowledge(nil) }
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 0.5
    }

    func show() {
        panel.show(events, animateNew: false)
        if events.isEmpty {
            let alert = NSAlert()
            alert.messageText = L10n.text("미확인 완료 알림이 없습니다.", "No unread completions.")
            alert.informativeText = L10n.text("메뉴의 ‘완료 알림 연결’에서 Codex와 Claude Code를 연결할 수 있습니다.", "Connect Codex and Claude Code using Completion notifications in the menu.")
            alert.runModal()
        }
    }

    private func refresh() {
        guard !loading else { return }
        loading = true
        let store = self.store
        Task { @MainActor [weak self] in
            defer { self?.loading = false }
            do {
                let current = try await Task.detached(priority: .utility) { try store.load().unread }.value
                guard let self else { return }
                let newIDs = Set(current.map(\.id)).subtracting(self.events.map(\.id))
                if current != self.events {
                    self.events = current
                    self.panel.show(current, animateNew: !newIDs.isEmpty)
                    self.onCountChanged?(current.count)
                }
            } catch { self?.panel.showError(error.localizedDescription) }
        }
    }

    private func acknowledge(_ id: String?) {
        let store = self.store
        let ids = id.map { Set([$0]) } ?? Set(events.map(\.id))
        Task { @MainActor [weak self] in
            do {
                try await Task.detached {
                    try store.acknowledge(ids)
                }.value
                self?.panel.showError(nil)
                self?.refresh()
            } catch { self?.panel.showError(error.localizedDescription) }
        }
    }

    func configure(_ provider: Provider, remove: Bool = false) {
        let url = HookInstaller.configurationURL(provider)
        let alert = NSAlert()
        alert.messageText = remove
            ? L10n.text("\(provider.name) 알림 연결 해제", "Disconnect \(provider.name) notifications")
            : L10n.text("\(provider.name) 완료 알림 연결", "Connect \(provider.name) completions")
        alert.informativeText = L10n.text(
            "\(url.path)\n\nAiQuotaBar 알림 설정만 \(remove ? "제거" : "추가")하며 기존 설정을 백업합니다. \(remove ? "미확인 알림은 유지됩니다." : "연결 후 새 세션을 시작하세요. Codex에서는 /hooks에서 추가된 항목을 검토하고 신뢰해야 합니다. 다른 앱에서 관리하는 프로필은 별도 연결이 필요할 수 있습니다.")",
            "\(url.path)\n\nOnly AiQuotaBar hooks will be \(remove ? "removed" : "added"); existing settings are backed up. \(remove ? "Unread alerts are kept." : "Start a new session afterward. In Codex, review and trust the new entries in /hooks. Profiles managed by other apps may need separate setup.")")
        alert.addButton(withTitle: remove ? L10n.text("연결 해제", "Disconnect") : L10n.text("연결", "Connect"))
        alert.addButton(withTitle: L10n.text("취소", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn, let executable = Bundle.main.executableURL?.path else { return }
        do {
            try HookInstaller.install(provider, executable: executable, remove: remove)
            let done = NSAlert()
            done.messageText = L10n.text("알림 설정을 저장했습니다.", "Notification settings saved.")
            done.informativeText = remove
                ? L10n.text("새 세션부터 연결이 해제됩니다.", "The change applies to new sessions.")
                : L10n.text("새 Codex·Claude Code 세션에서 적용됩니다. Codex /hooks에서 신뢰를 승인한 뒤 응답을 완료하면 알림이 표시됩니다. AiQuotaBar를 실행해 두세요.", "Applies to new Codex / Claude Code sessions. Review Codex hooks in /hooks, then finish a response to receive an alert. Keep AiQuotaBar running.")
            done.runModal()
        } catch {
            let failure = NSAlert(); failure.messageText = error.localizedDescription; failure.runModal()
        }
    }
}
