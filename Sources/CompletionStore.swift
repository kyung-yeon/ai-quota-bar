import Foundation
import Darwin

struct CompletionState: Codable {
    var version = 1
    var events: [CompletionEvent] = []
    var contexts: [String: CompletionContext]?
    var unread: [CompletionEvent] { events.filter { $0.acknowledgedAt == nil }.sorted { $0.completedAt > $1.completedAt } }
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
            let state = try JSONDecoder().decode(CompletionState.self, from: Data(contentsOf: file))
            guard state.version == 1 else { throw CompletionError.corruptStore }
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
        let session = (payload["session_id"] ?? payload["thread-id"]) as? String
        guard let session, CompletionEvent.validID(session) else { throw CompletionError.invalidEvent }
        let key = completionHash(provider.rawValue + "\u{0}" + session)
        let captured = HerdrClientBinding.resolve(.capture(environment: environment), directory: directory)
        try update { state in
            if name == "SessionStart" || name == "UserPromptSubmit" {
                var context = state.contexts?[key] ?? CompletionContext(turn: UUID().uuidString, updatedAt: Date())
                if name == "UserPromptSubmit" { context.turn = payload["prompt_id"] as? String ?? UUID().uuidString }
                context.updatedAt = Date()
                if state.contexts == nil { state.contexts = [:] }
                state.contexts?[key] = context
            } else if var event = try CompletionEvent.decode(data, provider: provider, environment: environment, fallbackToken: state.contexts?[key]?.turn) {
                event.destination = captured
                if !state.events.contains(where: { $0.id == event.id }) { state.events.append(event) }
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
        // Never expire unread alerts. Keep acknowledged IDs for 90 days to suppress replays.
        let cutoff = Date().addingTimeInterval(-90 * 86400)
        state.events.removeAll { $0.acknowledgedAt.map { $0 < cutoff } ?? false }
        state.contexts = state.contexts?.filter { $0.value.updatedAt > cutoff }
        let data = try JSONEncoder().encode(state)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
