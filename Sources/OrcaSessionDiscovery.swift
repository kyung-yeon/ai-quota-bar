import AppKit

/// Read only the running local runtime. History, transcripts and terminal previews
/// are not used to infer liveness and are never persisted.
enum OrcaSessionDiscovery {
    static func read() throws -> [LiveSession] {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.stablyai.orca").isEmpty else { return [] }
        let cli = try SessionCommand.executable("orca", bundled: "/Applications/Orca.app/Contents/Resources/bin/orca")
        let env = ["ORCA_ENVIRONMENT": "", "ORCA_PAIRING_CODE": "", "ORCA_REMOTE_PAIRING": ""]
        let terminals = try SessionCommand.run(cli, ["terminal", "list", "--limit", "1000", "--json"], environment: env, outputLimit: 4_194_304)
        let worktrees = try SessionCommand.run(cli, ["worktree", "ps", "--limit", "1000", "--json"], environment: env, outputLimit: 4_194_304)
        return try parse(terminals: terminals, worktrees: worktrees, profile: ProcessInfo.processInfo.environment["ORCA_USER_DATA_PATH"])
    }

    static func parse(terminals: Data, worktrees: Data, profile: String? = nil) throws -> [LiveSession] {
        func result(_ data: Data) throws -> [String: Any] {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CompletionError.unavailable }
            let result = json["result"] as? [String: Any] ?? json
            guard result["truncated"] as? Bool != true else { throw CompletionError.unavailable }
            return result
        }
        guard let terminals = try result(terminals)["terminals"] as? [[String: Any]],
              let worktrees = try result(worktrees)["worktrees"] as? [[String: Any]] else { throw CompletionError.unavailable }
        var agents: [String: [String: Any]] = [:]
        for worktree in worktrees {
            for agent in worktree["agents"] as? [[String: Any]] ?? [] {
                if let key = agent["paneKey"] as? String { agents[key] = agent }
            }
        }
        var sessions: [LiveSession] = []
        var paneKeys: [String: String] = [:]
        var paneParents: [String: String] = [:]
        for terminal in terminals {
            guard terminal["connected"] as? Bool == true, terminal["orphaned"] as? Bool != true,
                  let identity = terminal["agentIdentity"] as? String,
                  let provider = Provider(rawValue: identity),
                  let handle = terminal["handle"] as? String,
                  let cwd = terminal["worktreePath"] as? String, cwd.hasPrefix("/"),
                  let tab = terminal["tabId"] as? String, let leaf = terminal["leafId"] as? String,
                  let agent = agents[tab + ":" + leaf], agent["hasLivePty"] as? Bool == true else { continue }
            let destination = SessionDestination(host: .orca, target: handle, profile: profile)
            guard (try? SessionNavigator.validate(destination)) != nil else { continue }
            let status = (agent["programStatus"] as? [String: Any])?["state"] as? String ?? agent["state"] as? String ?? ""
            let activity: SessionActivity = ["working", "running"].contains(status) ? .running : (["done", "idle"].contains(status) ? .idle : .unknown)
            let timestamp = (agent["updatedAt"] as? Double ?? agent["stateStartedAt"] as? Double ?? 0) / 1000
            let updated = Date(timeIntervalSince1970: timestamp)
            let id = "orca:" + completionHash((profile ?? "") + "\u{0}" + handle)
            let title = String((terminal["title"] as? String ?? "Orca").prefix(120))
            let event = CompletionEvent(id: id, providerID: provider.rawValue, sessionID: id,
                project: String(URL(fileURLWithPath: cwd).lastPathComponent.prefix(100)), directory: cwd,
                sessionName: title, completedAt: updated, destination: destination)
            let done = agent["state"] as? String == "done" && agent["interrupted"] as? Bool != true
            let token = done ? (agent["stateStartedAt"] as? NSNumber)?.stringValue : nil
            let parent = LiveSession(event: event, activity: activity, updatedAt: updated, completionToken: token,
                childrenKnown: agent["children"] != nil || agent["subagents"] != nil)
            sessions.append(parent)
            paneKeys[tab + ":" + leaf] = parent.key
            paneParents[parent.key] = agent["parentPaneKey"] as? String
            sessions.append(contentsOf: children(agent, parent: parent))
        }
        for index in sessions.indices where sessions[index].usesParentDestination != true {
            sessions[index].parentKey = paneParents[sessions[index].key].flatMap { paneKeys[$0] }
        }
        return sessions
    }

    private static func children(_ agent: [String: Any], parent: LiveSession) -> [LiveSession] {
        // Canonical children (even an empty array) override the legacy roster.
        let canonical = agent["children"] as? [[String: Any]]
        let entries = canonical ?? agent["subagents"] as? [[String: Any]] ?? []
        let agents = entries.filter { canonical == nil || $0["kind"] as? String == "agent" }
        let byID = Dictionary(agents.compactMap { item -> (String, [String: Any])? in
            guard let id = item["id"] as? String else { return nil }; return (id, item)
        }, uniquingKeysWith: { _, latest in latest })
        // Retain a settled ancestor only if it owns a live descendant.
        var visible = Set(agents.compactMap { $0["membership"] as? String == "settled" ? nil : $0["id"] as? String })
        for id in visible {
            var owner = byID[id]?["parentChildWorkId"] as? String, seen: Set<String> = [id]
            while let current = owner, seen.insert(current).inserted, let item = byID[current] {
                visible.insert(current); owner = item["parentChildWorkId"] as? String
            }
        }
        func sessionID(_ item: [String: Any]) -> String? { (item["providerId"] ?? item["id"]) as? String }
        return agents.compactMap { item in
            guard let id = item["id"] as? String, visible.contains(id), let session = sessionID(item), CompletionEvent.validID(session) else { return nil }
            let role = item["agentType"] as? String
            let title = item["name"] as? String ?? ((role != nil && role != "default") ? role! : String(session.prefix(12)))
            let details = item["model"] as? String ?? role ?? parent.event.provider.name
            let state = item["state"] as? String ?? ""
            let activity: SessionActivity = agent["subagentObservation"] as? String == "unverifiable" ? .unknown
                : (["working", "running"].contains(state) ? .running : (["idle", "done", "completed", "waiting"].contains(state) ? .idle : .unknown))
            let owner = (item["parentChildWorkId"] as? String).flatMap { byID[$0] }.flatMap(sessionID)
            let event = CompletionEvent(id: "child:" + session, providerID: parent.event.providerID, sessionID: session,
                project: String(title.prefix(100)), directory: parent.event.directory, sessionName: String(details.prefix(120)),
                completedAt: parent.updatedAt, destination: parent.event.destination)
            return LiveSession(event: event, activity: activity, updatedAt: parent.updatedAt,
                parentKey: owner.map { parent.event.providerID + "\u{0}" + $0 } ?? parent.key, usesParentDestination: true)
        }
    }
}
