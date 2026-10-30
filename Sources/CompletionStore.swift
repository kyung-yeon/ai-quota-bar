import Foundation
import Darwin

struct CompletionState: Codable {
    var version = 1
    var events: [CompletionEvent] = []
    var contexts: [String: CompletionContext]?
    var sessions: [String: LiveSession]?
    var closedSessions: [String: LiveSession]?
    var unread: [CompletionEvent] { events.filter { $0.acknowledgedAt == nil }.sorted { $0.completedAt > $1.completedAt } }

    mutating func keepLatestPerSession(at now: Date = Date()) {
        var latest: [String: Int] = [:]
        for index in events.indices {
            if isSharedTerminalChild(events[index]) { events[index].usesParentDestination = true }
            let event = events[index]
            let key = event.providerID + "\u{0}" + event.sessionID
            if let previous = latest[key], events[previous].completedAt > event.completedAt { continue }
            latest[key] = index
        }
        for index in events.indices where events[index].acknowledgedAt == nil {
            let key = events[index].providerID + "\u{0}" + events[index].sessionID
            if let newest = latest[key], newest != index {
                // Keep replaced IDs for replay protection, but never resurface an older card.
                events[index].acknowledgedAt = events[newest].acknowledgedAt ?? now
            }
        }
    }
}

struct CompletionContext: Codable {
    var turn: String
    var updatedAt: Date
}

struct CompletionStore {
    let directory: URL
    var file: URL { directory.appendingPathComponent("completions.json") }
    static var standard: CompletionStore {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AiQuotaBar/Notifications")
        return CompletionStore(directory: base)
    }

    func load() throws -> CompletionState {
        guard FileManager.default.fileExists(atPath: file.path) else { return CompletionState() }
        do {
            var state = try JSONDecoder().decode(CompletionState.self, from: Data(contentsOf: file))
            guard state.version == 1 else { throw CompletionError.corruptStore }
            state.keepLatestPerSession()
            return state
        } catch { throw CompletionError.corruptStore }
    }

    func record(_ event: CompletionEvent) throws {
        try update { state in
            guard !state.events.contains(where: { $0.id == event.id }) else { return }
            state.events.append(event)
        }
    }

    func receive(_ data: Data, provider: Provider, environment: [String: String]) throws {
        guard data.count <= 1_048_576, let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CompletionError.invalidEvent }
        let name = payload["hook_event_name"] as? String ?? ""
        if name == "SubagentStart" || name == "SubagentStop" {
            let destination = HerdrClientBinding.resolve(.capture(environment: environment), directory: directory)
            try update { state in
                let parent = payload["session_id"] as? String ?? ""
                let parentKey = provider.rawValue + "\u{0}" + parent
                let known = state.sessions?[completionHash(parentKey)]
                let childID = payload["agent_id"] as? String ?? ""
                let child = state.sessions?[completionHash(provider.rawValue + "\u{0}" + childID)]
                if provider == .codex, environment["AIQUOTABAR_EPHEMERAL_EXEC"] == "1",
                   known?.parentKey == nil, child?.parentKey != parentKey { return }
                try state.trackSubagent(payload, provider: provider, destination: destination)
            }
            return
        }
        guard payload["agent_id"] == nil, !name.hasPrefix("Subagent") else { return }
        let session = (payload["session_id"] ?? payload["thread-id"]) as? String
        guard let session, CompletionEvent.validID(session) else { throw CompletionError.invalidEvent }
        let key = completionHash(provider.rawValue + "\u{0}" + session)
        let captured = HerdrClientBinding.resolve(.capture(environment: environment), directory: directory)
        try update { state in
            let known = state.sessions?[key] ?? state.closedSessions?[key]
            if provider == .codex, environment["AIQUOTABAR_EPHEMERAL_EXEC"] == "1", known?.parentKey == nil { return }
            let completion = try CompletionEvent.decode(data, provider: provider, environment: environment, fallbackToken: state.contexts?[key]?.turn)
            if let completion, state.events.contains(where: { $0.id == completion.id }) { return }
            if name == "SessionEnd" { state.endSession(provider.rawValue + "\u{0}" + session); return }
            let lifecycle = ["SessionStart", "UserPromptSubmit", "Stop", "Interrupt", "StopFailure"]
            if lifecycle.contains(name), let cwd = payload["cwd"] as? String, cwd.hasPrefix("/"), cwd.utf8.count <= 4096 {
                let now = Date()
                let previous = state.sessions?[key] ?? state.closedSessions?[key]
                let child = previous?.usesParentDestination == true ? previous : nil
                let event = CompletionEvent(id: key, providerID: provider.rawValue, sessionID: session,
                    project: child?.event.project ?? String(URL(fileURLWithPath: cwd).lastPathComponent.prefix(100)), directory: cwd,
                    sessionName: child?.event.sessionName ?? String((environment["AIQUOTABAR_SESSION_NAME"] ?? payload["session_name"] as? String ?? String(session.prefix(12))).prefix(120)),
                    completedAt: now, destination: child?.event.destination ?? captured)
                var owner = state.sessions?[key]?.owner
                if let pid = environment["AIQUOTABAR_OWNER_PID"].flatMap(Int32.init), let start = environment["AIQUOTABAR_OWNER_START"] {
                    owner = SessionOwner(pid: pid, startedAt: start)
                }
                if state.sessions == nil { state.sessions = [:] }
                let activity: SessionActivity
                if name == "SessionStart", payload["source"] as? String == "compact" {
                    activity = state.sessions?[key]?.activity ?? .idle
                } else { activity = name == "UserPromptSubmit" ? .running : .idle }
                let parentKey = previous?.parentKey
                let usesParent = previous?.usesParentDestination
                state.sessions?[key] = LiveSession(event: event, activity: activity, owner: owner, updatedAt: now, parentKey: parentKey, usesParentDestination: usesParent)
                if let live = state.sessions?[key] { state.adoptRuntimeCompletions(for: live) }
            }
            if name == "SessionStart" || name == "UserPromptSubmit" {
                var context = state.contexts?[key] ?? CompletionContext(turn: UUID().uuidString, updatedAt: Date())
                if name == "UserPromptSubmit" { context.turn = payload["prompt_id"] as? String ?? UUID().uuidString }
                context.updatedAt = Date()
                if state.contexts == nil { state.contexts = [:] }
                state.contexts?[key] = context
            } else if var event = completion {
                event.destination = captured
                if let child = state.sessions?[key], child.usesParentDestination == true {
                    event = CompletionEvent(id: event.id, providerID: event.providerID, sessionID: event.sessionID,
                        project: child.event.project, directory: event.directory, sessionName: child.event.sessionName,
                        completedAt: event.completedAt, destination: child.event.destination)
                    event.usesParentDestination = true
                }
                // Prefer the native identity once a previously untracked tab sends hooks.
                for index in state.events.indices where state.sessions?[key]?.usesParentDestination != true && state.events[index].id.hasPrefix("runtime:") && state.events[index].terminalKey == event.terminalKey && event.terminalKey != nil {
                    state.events[index].acknowledgedAt = state.events[index].acknowledgedAt ?? Date()
                }
                if !state.events.contains(where: { $0.id == event.id }) { state.events.append(event) }
            }
        }
    }

    func reconcileOrcaSessions(_ discovered: [LiveSession],
                               isAlive: (SessionOwner) -> Bool = { $0.isAlive },
                               resolve: (SessionOwner) -> SessionDestination? = { OrcaProcessBinding.destination(for: $0) }) throws {
        let targets = Set(discovered.filter { $0.usesParentDestination != true }.compactMap { $0.event.terminalKey })
        guard !targets.isEmpty else { return }
        let snapshot = try load()
        var bindings: [String: LiveSession] = [:]
        for (key, var session) in snapshot.sessions ?? [:] {
            guard session.usesParentDestination != true, session.event.destination.host == .unsupported,
                  session.event.destination.herdr == nil, let owner = session.owner, let target = resolve(owner) else { continue }
            session.event.destination = target
            guard let terminal = session.event.terminalKey, targets.contains(terminal) else { continue }
            bindings[key] = session
        }
        guard !bindings.isEmpty else { return }
        // A CLI can exit without SessionEnd. Its persisted record must not block
        // a new live owner in the same tab. Check lifetimes outside the file lock.
        let deadOwners = (snapshot.sessions ?? [:]).values.compactMap(\.owner).filter { !isAlive($0) }
        try update { state in
            for (key, binding) in bindings {
                guard let current = state.sessions?[key], current.owner == binding.owner,
                      current.updatedAt == binding.updatedAt, current.event.destination.host == .unsupported else { continue }
                let terminal = binding.event.terminalKey
                // Never collapse different native sessions that share an inherited handle.
                let candidates = (state.sessions ?? [:]).map { bindings[$0.key] ?? $0.value }
                guard !deadOwners.contains(binding.owner!), candidates.filter({
                    $0.usesParentDestination != true && $0.event.terminalKey == terminal
                        && !($0.owner.map(deadOwners.contains) ?? false)
                }).count == 1 else { continue }
                state.sessions?[key]?.event.destination = binding.event.destination
                for index in state.events.indices {
                    let old = state.events[index]
                    if old.sessionKey == binding.key {
                        state.events[index].destination = binding.event.destination
                    } else if old.sessionID.hasPrefix("orca:"), old.terminalKey == terminal {
                        state.events[index] = CompletionEvent(id: old.id, providerID: binding.event.providerID,
                            sessionID: binding.event.sessionID, project: binding.event.project, directory: binding.event.directory,
                            sessionName: binding.event.sessionName, completedAt: old.completedAt,
                            destination: binding.event.destination, acknowledgedAt: old.acknowledgedAt)
                    }
                }
            }
        }
    }

    func recordObservedCompletions(_ current: [LiveSession], previous: [LiveSession]) throws {
        let changed = current.filter { session in
            session.activity == .idle && session.completionToken != nil && previous.contains {
                $0.key == session.key && $0.activity == .running && $0.completionToken != session.completionToken
            }
        }
        guard !changed.isEmpty else { return }
        try update { state in
            for session in changed {
                guard let prior = previous.first(where: { $0.key == session.key }) else { continue }
                // Prefer a hook already delivered during the observed turn.
                if state.events.contains(where: { !state.isSharedTerminalChild($0) && $0.terminalKey == session.event.terminalKey && $0.completedAt >= prior.updatedAt }) { continue }
                let id = "runtime:" + completionHash(session.key + "\u{0}" + session.completionToken!)
                guard !state.events.contains(where: { $0.id == id }) else { continue }
                let source = state.sessions?.values.filter { $0.usesParentDestination != true && $0.event.terminalKey == session.event.terminalKey }.max { $0.updatedAt < $1.updatedAt }?.event
                    ?? state.events.filter { !state.isSharedTerminalChild($0) && $0.terminalKey == session.event.terminalKey }.max { $0.completedAt < $1.completedAt }
                    ?? session.event
                state.events.append(CompletionEvent(id: id, providerID: source.providerID, sessionID: source.sessionID,
                    project: source.project, directory: source.directory, sessionName: source.sessionName,
                    completedAt: session.updatedAt, destination: source.destination))
            }
        }
    }

    func acknowledge(_ id: String) throws {
        try update { state in
            if let index = state.events.firstIndex(where: { $0.id == id }) { state.events[index].acknowledgedAt = Date() }
        }
    }

    func acknowledgeAll() throws {
        try update { state in
            for index in state.events.indices where state.events[index].acknowledgedAt == nil { state.events[index].acknowledgedAt = Date() }
        }
    }

    func acknowledge(_ ids: Set<String>) throws {
        try update { state in
            for index in state.events.indices where ids.contains(state.events[index].id) { state.events[index].acknowledgedAt = Date() }
        }
    }

    private func update(_ change: (inout CompletionState) throws -> Void) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(directory.appendingPathComponent("store.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw CompletionError.busy }
        defer { close(lock) }
        let deadline = Date().addingTimeInterval(2)
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else { throw CompletionError.busy }
            usleep(10_000)
        }
        defer { flock(lock, LOCK_UN) }
        var state = try load()
        try change(&state)
        state.keepLatestPerSession()
        state.pruneClosedSessions()
        // Never expire unread alerts. Keep acknowledged IDs for 90 days to suppress replays.
        let cutoff = Date().addingTimeInterval(-90 * 86400)
        state.events.removeAll { $0.acknowledgedAt.map { $0 < cutoff } ?? false }
        state.contexts = state.contexts?.filter { $0.value.updatedAt > cutoff }
        let data = try JSONEncoder().encode(state)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
