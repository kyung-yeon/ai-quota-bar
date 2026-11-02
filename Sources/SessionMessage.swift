import Foundation

/// A bounded excerpt, never a transcript or tool output. One per provider/session.
struct SessionMessage: Codable, Equatable {
    enum Role: String, Codable { case user, assistant }
    let role: Role
    let text: String
    var label: String {
        role == .assistant ? L10n.text("최근 응답", "Latest response") : L10n.text("최근 요청", "Latest request")
    }

    init?(_ raw: String?, role: Role) {
        guard let raw else { return nil }
        // Bound work before normalization. Remove terminal escape sequences and controls.
        let tail = String(raw.suffix(16_384))
            .replacingOccurrences(of: "\u{001B}\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let clean = String(String.UnicodeScalarView(tail.unicodeScalars.filter {
            $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0)
        }))
        let lines = clean.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.suffix(5)
        let text = String(lines.joined(separator: "\n").suffix(1_200))
        guard !text.isEmpty else { return nil }
        self.role = role; self.text = text
    }

    static func runtime(_ agent: [String: Any]) -> SessionMessage? {
        SessionMessage(agent["lastAssistantMessage"] as? String, role: .assistant)
            ?? SessionMessage(agent["prompt"] as? String, role: .user)
    }
}

extension CompletionState {
    mutating func trackMessage(_ payload: [String: Any], provider: Provider) {
        guard let parent = (payload["session_id"] ?? payload["thread-id"]) as? String else { return }
        let name = payload["hook_event_name"] as? String ?? ""
        let id = payload["agent_id"] as? String ?? parent
        guard CompletionEvent.validID(id) else { return }
        let key = completionHash(provider.rawValue + "\u{0}" + id)
        if id != parent && sessions?[key]?.parentKey != provider.rawValue + "\u{0}" + parent { return }
        if !["UserPromptSubmit", "SubagentStart"].contains(name) {
            if let expected = contexts?[key]?.nativeTurn, let turn = (payload["turn_id"] ?? payload["turn-id"]) as? String, turn != expected { return }
            if let expected = contexts?[key]?.nativePrompt, let prompt = payload["prompt_id"] as? String, prompt != expected { return }
        }
        let message: SessionMessage?
        if name == "SubagentStart" {
            message = nil
        } else if name == "UserPromptSubmit" {
            message = SessionMessage(payload["prompt"] as? String, role: .user)
        } else if ["Stop", "SubagentStop"].contains(name) || payload["type"] as? String == "agent-turn-complete" {
            message = SessionMessage((payload["last_assistant_message"] ?? payload["last-assistant-message"]) as? String, role: .assistant)
            // An absent response does not erase the request that explains this work.
            guard message != nil else { return }
        } else { return }
        if messages == nil { messages = [:] }
        messages?[key] = message
        sessions?[key]?.messageCleared = message == nil
    }

    mutating func adoptMessage(from event: CompletionEvent, to sessionKey: String) {
        let oldKey = completionHash(event.sessionKey), newKey = completionHash(sessionKey)
        guard oldKey != newKey, messages?[newKey] == nil,
              (contexts?[newKey]?.updatedAt ?? .distantPast) <= event.completedAt,
              let message = messages?[oldKey] else { return }
        messages?[newKey] = message
    }

    mutating func pruneMessages() {
        let needed = Set((sessions ?? [:]).keys).union((closedSessions ?? [:]).keys)
            .union(unread.map { completionHash($0.sessionKey) })
        messages = messages?.filter { needed.contains($0.key) }
        if messages?.isEmpty == true { messages = nil }
    }
}
