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
        let role = payload["agent_type"] as? String
        let title = payload["agent_name"] as? String ?? ((role != nil && role != "default") ? role! : String(child.prefix(12)))
        let event = CompletionEvent(id: childKey, providerID: provider.rawValue, sessionID: child,
            project: String(title.prefix(100)), directory: cwd,
            sessionName: String((payload["model"] as? String ?? role ?? provider.name).prefix(120)),
            completedAt: now, destination: destination)
        let owner = sessions?[parentHash]?.owner
        sessions?[childKey] = LiveSession(event: event, activity: start ? .running : .idle,
            owner: owner, updatedAt: now, parentKey: parentKey, usesParentDestination: true)
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
        sessions = sessions?.filter { !ended.contains($0.value.key) }
    }
}
