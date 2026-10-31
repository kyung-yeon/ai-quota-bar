import AppKit

@MainActor final class CompletionController {
    private let store: CompletionStore
    private let panel: CompletionPanel
    private var timer: Timer?
    private var loading = false
    private var connecting = false
    private var lastConnectionAttempt = Date.distantPast
    private let connect: @Sendable () -> [Provider: HookConnectionState]
    private(set) var connectionStates: [Provider: HookConnectionState] = [:]
    private var events: [CompletionEvent] = []
    private var rows: [SessionRow] = []
    private var discovered: [LiveSession] = []
    private var discoveryUnavailable = false
    private let discover: @Sendable () throws -> [LiveSession]
    private let sendPrompt: @Sendable (SessionRow, String) throws -> String
    private let preferences: UserDefaults
    private(set) var isOpen: Bool
    var onVisibilityChanged: (() -> Void)?
    var onCountChanged: ((Int) -> Void)?
    var onConnectionChanged: (() -> Void)?
    var unreadCount: Int { events.count }
    var pageSize: Int { panel.preferredPageSize }
    var translucent: Bool { panel.translucent }
    func toggleTransparency() { panel.setTransparency(!panel.translucent) }
    func setPageSize(_ value: Int) { panel.setPageSize(value) }

    init(store: CompletionStore = .standard, panel: CompletionPanel? = nil, preferences: UserDefaults = .standard,
         sendPrompt: @escaping @Sendable (SessionRow, String) throws -> String = { try SessionPromptSender.send($0, text: $1) },
         discover: @escaping @Sendable () throws -> [LiveSession] = { try OrcaSessionDiscovery.read() },
         connect: @escaping @Sendable () -> [Provider: HookConnectionState] = {
        guard let executable = Bundle.main.executableURL?.path else { return [:] }
        return HookInstaller.connectAvailable(executable: executable)
    }) {
        self.store = store
        self.sendPrompt = sendPrompt
        self.panel = panel ?? CompletionPanel(preferences: preferences)
        self.connect = connect
        self.discover = discover
        self.preferences = preferences
        self.isOpen = !preferences.bool(forKey: "sessionPanelHidden")
        let panel = self.panel
        panel.onOpen = { [weak self] event in
            Task { @MainActor in
                do { try await SessionNavigator.open(event.destination); self?.panel.showError(nil) }
                catch { self?.panel.showError(error.localizedDescription) }
            }
        }
        panel.onAcknowledge = { [weak self] id in self?.acknowledge(id) }
        panel.onClose = { [weak self] in self?.close() }
        panel.onSend = { [weak self] row, text, done in
            guard let self, !self.discoveryUnavailable,
                  let current = self.rows.first(where: { $0.id == row.id }), current.isOpen,
                  current.activity == .idle, current.event.destination == row.event.destination else {
                done(.failure(PromptSendError.notReady)); return
            }
            let send = self.sendPrompt
            Task { @MainActor in
                let result = await Task.detached { Result { try send(current, text) } }.value
                done(result)
            }
        }
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
        isOpen = true
        preferences.set(false, forKey: "sessionPanelHidden")
        panel.showSessions(rows, animateNew: false)
        onVisibilityChanged?()
    }

    func close() {
        isOpen = false
        preferences.set(true, forKey: "sessionPanelHidden")
        panel.hide()
        onVisibilityChanged?()
    }

    func toggle() { if isOpen { close() } else { show() } }

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
        let discover = self.discover
        let previous = discovered
        Task { @MainActor [weak self] in
            defer { self?.loading = false }
            do {
                let result = try await Task.detached(priority: .utility) {
                    let live: [LiveSession]
                    let unavailable: Bool
                    do { live = try discover(); unavailable = false }
                    catch { live = previous.map { var value = $0; value.activity = .unknown; return value }; unavailable = true }
                    if !unavailable {
                        try store.reconcileOrcaSessions(live)
                        try store.recordObservedCompletions(live, previous: previous)
                    }
                    let state = try store.load()
                    return (state.unread, SessionRow.make(state: state, discovered: live), live, unavailable)
                }.value
                guard let self else { return }
                let (current, rows, live, unavailable) = result
                // Unknown is a display state, not evidence that a running turn stopped.
                // Keep the last successful snapshot so recovery can detect its completion.
                if !unavailable { self.discovered = live }
                let newIDs = Set(current.map(\.id)).subtracting(self.events.map(\.id))
                if current != self.events || rows != self.rows || (self.isOpen && !self.panel.panel.isVisible) {
                    self.events = current
                    self.rows = rows
                    if self.isOpen { self.panel.showSessions(rows, animateNew: !newIDs.isEmpty) }
                    self.onCountChanged?(current.count)
                }
                if unavailable && self.isOpen {
                    self.panel.showError(L10n.text("Orca 상태를 갱신하지 못했습니다. 잠시 후 다시 확인합니다.", "Could not refresh Orca status. Retrying shortly."))
                } else if self.discoveryUnavailable {
                    self.panel.showError(nil)
                }
                self.discoveryUnavailable = unavailable
            } catch { self?.panel.showError(error.localizedDescription) }
        }
    }

    private func acknowledge(_ id: String) {
        if events.isEmpty { return }
        let store = self.store
        let ids: Set<String> = [id]
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
