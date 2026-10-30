import Foundation

extension CompletionState {
    mutating func trackProgress(_ payload: [String: Any], provider: Provider,
                                environment: [String: String], destination: SessionDestination) {
        guard let parentID = payload["session_id"] as? String, CompletionEvent.validID(parentID) else { return }
        let id = payload["agent_id"] as? String ?? parentID
        guard CompletionEvent.validID(id) else { return }
        let sessionKey = provider.rawValue + "\u{0}" + id
        let key = completionHash(sessionKey)
        let known = sessions?[key]
        // Internal agents must have explicit ownership. Never apply a child update to its parent.
        if payload["agent_id"] != nil && known?.parentKey != provider.rawValue + "\u{0}" + parentID { return }
        if provider == .codex, environment["AIQUOTABAR_EPHEMERAL_EXEC"] == "1", known?.parentKey == nil { return }
        if let expected = contexts?[key]?.nativeTurn, let turn = payload["turn_id"] as? String, turn != expected { return }
        if let expected = contexts?[key]?.nativePrompt, let prompt = payload["prompt_id"] as? String, prompt != expected { return }
        guard let next = (progress?[key] ?? SessionProgress()).applying(payload, provider: provider) else { return }
        if known == nil {
            guard closedSessions?[key] == nil, let cwd = payload["cwd"] as? String,
                  cwd.hasPrefix("/"), cwd.utf8.count <= 4096 else { return }
            let event = CompletionEvent(id: key, providerID: provider.rawValue, sessionID: id,
                project: String(URL(fileURLWithPath: cwd).lastPathComponent.prefix(100)), directory: cwd,
                sessionName: String((environment["AIQUOTABAR_SESSION_NAME"] ?? String(id.prefix(12))).prefix(120)),
                completedAt: Date(), destination: destination)
            let owner = environment["AIQUOTABAR_OWNER_PID"].flatMap(Int32.init).flatMap { pid in
                environment["AIQUOTABAR_OWNER_START"].map { SessionOwner(pid: pid, startedAt: $0) }
            }
            if sessions == nil { sessions = [:] }
            sessions?[key] = LiveSession(event: event, activity: .running, owner: owner, updatedAt: Date())
            if let session = sessions?[key] { adoptRuntimeCompletions(for: session) }
        }
        if progress == nil { progress = [:] }
        progress?[key] = next
    }

    mutating func pruneProgress() {
        let needed = Set((sessions ?? [:]).keys).union((closedSessions ?? [:]).keys)
            .union(unread.map { completionHash($0.sessionKey) })
        progress = progress?.filter { needed.contains($0.key) }
        if progress?.isEmpty == true { progress = nil }
    }
}
