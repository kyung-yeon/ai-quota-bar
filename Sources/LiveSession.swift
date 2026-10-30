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
    var parentKey: String?
    var childrenKnown: Bool?
    var usesParentDestination: Bool?
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
    var parentID: String?
    var depth = 0
    var opensParent = false
    var progress: SessionProgress?
    var id: String { event.sessionKey }

    /// Keep closed unread sessions, and show an acknowledged open session as idle.
    static func make(state: CompletionState, discovered: [LiveSession], isAlive: (SessionOwner) -> Bool = { $0.isAlive }) -> [SessionRow] {
        var live = (state.sessions ?? [:]).values.filter { $0.owner.map(isAlive) ?? true }
        // The runtime is authoritative about which Orca tabs are currently open.
        let discoveredTargets = Set(discovered.filter { $0.usesParentDestination != true }.compactMap { $0.event.terminalKey })
        live.removeAll { $0.event.terminalKey.map { !discoveredTargets.contains($0) } ?? false }
        var parentAliases: [String: String] = [:]
        for var session in discovered where session.usesParentDestination != true {
            // Hooks give the real session ID; the runtime also covers pre-existing sessions.
            let originalKey = session.key
            let known = live.filter { $0.usesParentDestination != true && $0.event.terminalKey == session.event.terminalKey }.max { $0.updatedAt < $1.updatedAt }
            if let known {
                session.event = known.event
                if known.updatedAt > session.updatedAt { session.activity = known.activity }
            } else if let known = state.events.filter({ !state.isSharedTerminalChild($0) && $0.terminalKey == session.event.terminalKey }).max(by: { $0.completedAt < $1.completedAt }) {
                session.event = known
            }
            parentAliases[originalKey] = session.key
            live.removeAll { $0.event.terminalKey == session.event.terminalKey && ($0.usesParentDestination != true || session.childrenKnown == true) }
            live.append(session)
        }
        for var child in discovered where child.usesParentDestination == true {
            child.parentKey = child.parentKey.map { parentAliases[$0] ?? $0 }
            live.removeAll { $0.key == child.key }
            live.append(child)
        }
        for index in live.indices { live[index].parentKey = live[index].parentKey.map { parentAliases[$0] ?? $0 } }
        // Children cannot outlive their owning session just because an old hook
        // did not capture a process ID. Remove orphaned descendants transitively.
        var previousCount = -1
        while previousCount != live.count {
            previousCount = live.count
            let keys = Set(live.map(\.key))
            live.removeAll { $0.parentKey.map { !keys.contains($0) } ?? false }
        }
        var rows: [String: SessionRow] = [:]
        for session in live {
            rows[session.key] = SessionRow(event: session.event, activity: session.activity, isOpen: true, needsAttention: false,
                parentID: session.parentKey, opensParent: session.usesParentDestination == true)
        }
        let saved = (state.closedSessions ?? [:]).merging(state.sessions ?? [:]) { _, open in open }
        var metadata = Dictionary(saved.values.map { ($0.key, $0) }, uniquingKeysWith: { _, latest in latest })
        for session in live { metadata[session.key] = session }
        for event in state.unread {
            var row = rows[event.sessionKey] ?? SessionRow(event: event)
            row.event = event; row.needsAttention = true
            if let session = metadata[event.sessionKey] {
                row.parentID = session.parentKey.map { parentAliases[$0] ?? $0 }
                row.opensParent = session.usesParentDestination == true
            }
            rows[event.sessionKey] = row
            var parent = row.parentID, seen: Set<String> = [row.id]
            for _ in 0..<32 {
                guard let key = parent, seen.insert(key).inserted, let ancestor = metadata[key] else { break }
                let owner = ancestor.parentKey.map { parentAliases[$0] ?? $0 }
                if rows[key] == nil {
                    rows[key] = SessionRow(event: ancestor.event, isOpen: false, needsAttention: false,
                        parentID: owner, opensParent: ancestor.usesParentDestination == true)
                }
                parent = owner
            }
        }
        for key in Array(rows.keys) where rows[key]?.opensParent == true {
            var parent = rows[key]?.parentID, seen: Set<String> = [key]
            while let id = parent, seen.insert(id).inserted, let ancestor = rows[id] {
                if ancestor.event.destination.host != .unsupported {
                    rows[key]?.event.destination = ancestor.event.destination
                    break
                }
                parent = ancestor.parentID
            }
        }
        for key in Array(rows.keys) {
            if let progress = state.progress?[completionHash(key)], progress.visible { rows[key]?.progress = progress }
        }
        return SessionTree.order(Array(rows.values))
    }

    static func precedes(_ lhs: SessionRow, _ rhs: SessionRow) -> Bool {
            let left = lhs.needsAttention ? 0 : (lhs.activity == .running ? 1 : 2)
            let right = rhs.needsAttention ? 0 : (rhs.activity == .running ? 1 : 2)
            if left != right { return left < right }
            if left == 0, lhs.event.completedAt != rhs.event.completedAt { return lhs.event.completedAt > rhs.event.completedAt }
            if lhs.event.project != rhs.event.project { return lhs.event.project.localizedStandardCompare(rhs.event.project) == .orderedAscending }
            return lhs.id < rhs.id
    }
}
