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
        return terminals.compactMap { terminal in
            guard terminal["connected"] as? Bool == true, terminal["orphaned"] as? Bool != true,
                  let identity = terminal["agentIdentity"] as? String,
                  let provider = Provider(rawValue: identity),
                  let handle = terminal["handle"] as? String,
                  let cwd = terminal["worktreePath"] as? String, cwd.hasPrefix("/"),
                  let tab = terminal["tabId"] as? String, let leaf = terminal["leafId"] as? String,
                  let agent = agents[tab + ":" + leaf], agent["hasLivePty"] as? Bool == true,
                  agent["parentPaneKey"] == nil || agent["parentPaneKey"] is NSNull else { return nil }
            let destination = SessionDestination(host: .orca, target: handle, profile: profile)
            guard (try? SessionNavigator.validate(destination)) != nil else { return nil }
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
            return LiveSession(event: event, activity: activity, updatedAt: updated, completionToken: token)
        }
    }
}
