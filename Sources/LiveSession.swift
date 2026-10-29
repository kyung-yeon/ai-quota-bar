import Foundation

enum SessionActivity: String, Codable { case idle, running, unknown }

struct SessionOwner: Codable, Equatable {
    let pid: Int32
    let startedAt: String
    var isAlive: Bool { HerdrClientBinding.startTime(pid) == startedAt }
}

struct LiveSession: Codable, Equatable {
    var event: CompletionEvent
    var activity: SessionActivity
    var owner: SessionOwner?
    var updatedAt: Date
    var completionToken: String?
    var key: String { event.sessionKey }
}

extension CompletionEvent {
    var sessionKey: String { providerID + "\u{0}" + sessionID }
    var terminalKey: String? {
        guard destination.host == .orca, !destination.target.isEmpty else { return nil }
        let profile = destination.profile ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/orca").path
        return providerID + "\u{0}" + profile + "\u{0}" + destination.target
    }
}

struct SessionRow: Equatable, Identifiable {
    var event: CompletionEvent
    var activity: SessionActivity = .idle
    var isOpen = false
    var needsAttention = true
    var id: String { event.sessionKey }

    /// Keep closed unread sessions, and show an acknowledged open session as idle.
    static func make(state: CompletionState, discovered: [LiveSession], isAlive: (SessionOwner) -> Bool = { $0.isAlive }) -> [SessionRow] {
        var live = (state.sessions ?? [:]).values.filter { $0.owner.map(isAlive) ?? true }
        // The runtime is authoritative about which Orca tabs are currently open.
        let discoveredTargets = Set(discovered.compactMap { $0.event.terminalKey })
        live.removeAll { $0.event.terminalKey.map { !discoveredTargets.contains($0) } ?? false }
        for var session in discovered {
            // Hooks give the real session ID; the runtime also covers pre-existing sessions.
            let known = live.filter { $0.event.terminalKey == session.event.terminalKey }.max { $0.updatedAt < $1.updatedAt }
            if let known {
                session.event = known.event
                if known.updatedAt > session.updatedAt { session.activity = known.activity }
            } else if let known = state.events.filter({ $0.terminalKey == session.event.terminalKey }).max(by: { $0.completedAt < $1.completedAt }) {
                session.event = known
            }
            live.removeAll { $0.event.terminalKey == session.event.terminalKey }
            live.append(session)
        }
        var rows: [String: SessionRow] = [:]
        for session in live {
            rows[session.key] = SessionRow(event: session.event, activity: session.activity, isOpen: true, needsAttention: false)
        }
        for event in state.unread {
            var row = rows[event.sessionKey] ?? SessionRow(event: event)
            row.event = event; row.needsAttention = true
            rows[event.sessionKey] = row
        }
        return rows.values.sorted {
            let left = $0.needsAttention ? 0 : ($0.activity == .running ? 1 : 2)
            let right = $1.needsAttention ? 0 : ($1.activity == .running ? 1 : 2)
            if left != right { return left < right }
            if left == 0, $0.event.completedAt != $1.event.completedAt { return $0.event.completedAt > $1.event.completedAt }
            if $0.event.project != $1.event.project { return $0.event.project.localizedStandardCompare($1.event.project) == .orderedAscending }
            return $0.id < $1.id
        }
    }
}
