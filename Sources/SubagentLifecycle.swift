import Foundation

extension CompletionState {
    mutating func trackSubagent(_ payload: [String: Any], provider: Provider, destination: SessionDestination) throws {
        if payload["hook_event_name"] as? String == "SubagentStop", payload["agent_id"] == nil { return }
        guard let parent = payload["session_id"] as? String, CompletionEvent.validID(parent),
              let child = payload["agent_id"] as? String, CompletionEvent.validID(child), child != parent,
              let cwd = payload["cwd"] as? String, cwd.hasPrefix("/"), cwd.utf8.count <= 4096 else { throw CompletionError.invalidEvent }
        let start = payload["hook_event_name"] as? String == "SubagentStart"
        let parentKey = provider.rawValue + "\u{0}" + parent
        let childKey = completionHash(provider.rawValue + "\u{0}" + child)
        // Claude also emits Stop for internal agents that were never opened as children.
        guard start || sessions?[childKey] != nil else { return }
        if sessions == nil { sessions = [:] }
        let parentHash = completionHash(parentKey)
        let now = Date()
        if sessions?[parentHash] == nil {
            let event = CompletionEvent(id: parentHash, providerID: provider.rawValue, sessionID: parent,
                project: String(URL(fileURLWithPath: cwd).lastPathComponent.prefix(100)), directory: cwd,
                sessionName: String(parent.prefix(12)), completedAt: now, destination: destination)
            sessions?[parentHash] = LiveSession(event: event, activity: .unknown, updatedAt: now)
        }
        if let owner = sessions?[parentHash] { adoptRuntimeCompletions(for: owner) }
        let previous = sessions?[childKey]
        let role = payload["agent_type"] as? String
        let title = payload["agent_name"] as? String ?? previous?.event.project ?? ((role != nil && role != "default") ? role! : String(child.prefix(12)))
        let event = CompletionEvent(id: childKey, providerID: provider.rawValue, sessionID: child,
            project: String(title.prefix(100)), directory: cwd,
            sessionName: String((payload["model"] as? String ?? previous?.event.sessionName ?? role ?? provider.name).prefix(120)),
            completedAt: now, destination: destination.host == .unsupported ? (previous?.event.destination ?? destination) : destination)
        let owner = sessions?[parentHash]?.owner
        sessions?[childKey] = LiveSession(event: event, activity: start ? .running : .idle,
            owner: owner, updatedAt: now, parentKey: parentKey, usesParentDestination: true)
    }

    func isSharedTerminalChild(_ event: CompletionEvent) -> Bool {
        let key = completionHash(event.sessionKey)
        return event.usesParentDestination == true
            || (sessions?[key] ?? closedSessions?[key])?.usesParentDestination == true
    }

    mutating func adoptRuntimeCompletions(for session: LiveSession) {
        guard session.usesParentDestination != true, let terminal = session.event.terminalKey else { return }
        for index in events.indices where events[index].sessionID.hasPrefix("orca:") && events[index].terminalKey == terminal {
            let old = events[index], event = session.event
            events[index] = CompletionEvent(id: old.id, providerID: old.providerID, sessionID: event.sessionID,
                project: event.project, directory: event.directory, sessionName: event.sessionName,
                completedAt: old.completedAt, destination: event.destination, acknowledgedAt: old.acknowledgedAt)
        }
    }

    mutating func endSession(_ key: String) {
        var ended: Set<String> = [key]
        var count = -1
        while count != ended.count {
            count = ended.count
            for session in sessions?.values ?? Dictionary<String, LiveSession>().values {
                if session.parentKey.map({ ended.contains($0) }) == true { ended.insert(session.key) }
            }
        }
        for (id, session) in sessions ?? [:] where ended.contains(session.key) {
            if closedSessions == nil { closedSessions = [:] }
            closedSessions?[id] = session
        }
        sessions = sessions?.filter { !ended.contains($0.value.key) }
        pruneClosedSessions()
    }

    /// Keep only the metadata needed to place unread children beneath their
    /// ancestors. These records provide context, never evidence of an open CLI.
    mutating func pruneClosedSessions() {
        guard closedSessions != nil else { return }
        let metadata = (closedSessions ?? [:]).merging(sessions ?? [:]) { _, live in live }
        var needed = Set<String>()
        for event in unread {
            var key: String? = event.sessionKey
            for _ in 0..<32 {
                guard let current = key, needed.insert(completionHash(current)).inserted else { break }
                key = metadata[completionHash(current)]?.parentKey
            }
        }
        closedSessions = closedSessions?.filter { needed.contains($0.key) && sessions?[$0.key] == nil }
        if closedSessions?.isEmpty == true { closedSessions = nil }
    }
}
