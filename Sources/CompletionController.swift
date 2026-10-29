import AppKit

@MainActor final class CompletionController {
    private let store: CompletionStore
    private let panel = CompletionPanel()
    private var timer: Timer?
    private var loading = false
    private var connecting = false
    private var lastConnectionAttempt = Date.distantPast
    private let connect: @Sendable () -> [Provider: HookConnectionState]
    private(set) var connectionStates: [Provider: HookConnectionState] = [:]
    private var events: [CompletionEvent] = []
    var onCountChanged: ((Int) -> Void)?
    var onConnectionChanged: (() -> Void)?
    var unreadCount: Int { events.count }

    init(store: CompletionStore = .standard, connect: @escaping @Sendable () -> [Provider: HookConnectionState] = {
        guard let executable = Bundle.main.executableURL?.path else { return [:] }
        return HookInstaller.connectAvailable(executable: executable)
    }) {
        self.store = store
        self.connect = connect
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
        refreshConnections()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.refreshConnections()
            }
        }
        timer?.tolerance = 0.5
    }

    func show() {
        panel.show(events, animateNew: false)
        if events.isEmpty {
            let alert = NSAlert()
            alert.messageText = L10n.text("미확인 완료 알림이 없습니다.", "No unread completions.")
            alert.informativeText = connectionSummary
            alert.runModal()
        }
    }

    private var connectionSummary: String {
        let states = Provider.allCases.map { provider in
            "\(provider.name): \(connectionStates[provider]?.description ?? L10n.text("자동 연결 중…", "Connecting automatically…"))"
        }.joined(separator: "\n")
        return states + "\n\n" + L10n.text(
            "설치된 도구의 알림을 자동으로 연결합니다. 새 세션에서 응답이 끝나면 알림이 표시됩니다. Codex가 신뢰 승인을 요청하면 /hooks에서 AiQuotaBar 항목을 승인해 주세요.",
            "Installed tools connect automatically. Alerts appear when a response finishes in a new session. If Codex requests trust approval, review the AiQuotaBar entries in /hooks.")
    }

    func showConnectionStatus() {
        let alert = NSAlert()
        alert.messageText = L10n.text("완료 알림 상태", "Completion notification status")
        alert.informativeText = connectionSummary
        alert.runModal()
    }

    func refreshConnections(force: Bool = false) {
        guard !connecting, force || Date().timeIntervalSince(lastConnectionAttempt) >= 60 else { return }
        connecting = true
        lastConnectionAttempt = Date()
        let connect = self.connect
        Task { @MainActor [weak self] in
            let states = await Task.detached(priority: .utility) { connect() }.value
            guard let self else { return }
            self.connecting = false
            if self.connectionStates != states {
                self.connectionStates = states
                self.onConnectionChanged?()
            }
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
}
