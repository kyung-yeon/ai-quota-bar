import AppKit

@MainActor func openAcknowledgementUITests(_ expect: (Bool, String) throws -> Void) throws {
    func all(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + all($0) } }
    func wait(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    }
    for scenario in ["success", "failure", "new-response"] {
        let name = "AiQuotaBar.OpenAcknowledgement.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: name)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { preferences.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
        let store = CompletionStore(directory: directory)
        let event = CompletionEvent(id: "opened-response", providerID: "codex", sessionID: "opened-session",
            project: "Sample", directory: "/sample", sessionName: "Opened session", completedAt: Date(),
            destination: SessionDestination(host: .orca, target: "term_opened"))
        let other = CompletionEvent(id: "other-response", providerID: "codex", sessionID: "other-session",
            project: "Other", directory: "/other", sessionName: "Other session", completedAt: Date(),
            destination: SessionDestination(host: .orca, target: "term_other"))
        try store.record(event)
        try store.record(other)
        let live = LiveSession(event: event, activity: .running, owner: nil, updatedAt: Date())
        let panel = CompletionPanel(preferences: preferences, reduceMotion: { true })
        panel.panel.alphaValue = 0; panel.panel.ignoresMouseEvents = true
        var navigation: CheckedContinuation<Void, Error>?
        var destination: SessionDestination?
        let controller = CompletionController(store: store, panel: panel, preferences: preferences, openSession: { target in
            destination = target
            try await withCheckedThrowingContinuation { navigation = $0 }
        }, discover: { [live] }, connect: { [:] })
        defer { controller.close() }
        controller.start()
        wait { controller.unreadCount == 2 }
        let root = panel.panel.contentView!
        let card = all(root).compactMap { $0 as? CompletionCard }.first { $0.row.event.id == event.id }
        let open = card.flatMap { all($0).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "completion-open" } }
        try expect(open != nil, "The session shortcut is available for \(scenario)")
        open!.performClick(nil)
        wait { navigation != nil }
        try expect(destination == event.destination && navigation != nil,
            "The shortcut navigates to the clicked session's exact destination")
        try expect(try store.load().unread.count == 2, "Pending navigation leaves completions unread")
        if scenario == "failure" {
            navigation!.resume(throwing: NSError(domain: "Navigation test", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Session is unavailable"]))
            wait { all(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Session is unavailable" && !$0.isHidden } }
            try expect(all(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Session is unavailable" && !$0.isHidden },
                "Failed navigation displays its error")
            try expect(try store.load().unread.count == 2, "Failed navigation leaves both completions unread")
        } else {
            if scenario == "new-response" {
                let newer = CompletionEvent(id: "new-response", providerID: event.providerID, sessionID: event.sessionID,
                    project: event.project, directory: event.directory, sessionName: "New response",
                    completedAt: event.completedAt.addingTimeInterval(1), destination: event.destination)
                try store.record(newer)
            }
            navigation!.resume()
            if scenario == "success" {
                wait { controller.unreadCount == 1 }
                try expect(try CompletionStore(directory: directory).load().unread.map(\.id) == [other.id],
                    "Successful navigation acknowledges only the clicked response and persists it")
                try expect(all(root).compactMap { $0 as? CompletionCard }.contains {
                    $0.row.id == live.key && $0.row.activity == .running && !$0.row.needsAttention
                }, "Opening a completion preserves its currently running session")
            } else {
                wait { all(root).compactMap { $0 as? CompletionCard }.contains { $0.row.event.id == "new-response" } }
                try expect(try Set(store.load().unread.map(\.id)) == ["new-response", other.id],
                    "A newer response arriving during navigation remains unread")
            }
        }
    }
}
