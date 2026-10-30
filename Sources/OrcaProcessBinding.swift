import Foundation
import Darwin

/// Recover a missing hook destination only from its still-running local owner.
/// Never infer identity from a project name, directory, or terminal title.
enum OrcaProcessBinding {
    static func destination(for owner: SessionOwner,
                            isAlive: (SessionOwner) -> Bool = { $0.isAlive },
                            environment: (Int32) -> [String: String] = { SessionProcessInfo.read($0).routingEnvironment },
                            parent: (Int32) -> (pid: Int32, executable: String)? = parentProcess) -> SessionDestination? {
        guard isAlive(owner) else { return nil }
        let env = environment(owner.pid)
        guard env["TERM_PROGRAM"]?.lowercased() == "orca", let handle = env["ORCA_TERMINAL_HANDLE"],
              env["TMUX"] == nil, env["STY"] == nil, env["HERDR_PANE_ID"] == nil else { return nil }
        var pid = owner.pid, seen = Set<Int32>()
        for _ in 0..<16 {
            guard pid > 1, seen.insert(pid).inserted, let process = parent(pid) else { return nil }
            let name = URL(fileURLWithPath: process.executable).lastPathComponent.lowercased()
            if pid == owner.pid, !["codex", "claude"].contains(name) { return nil }
            if ["ssh", "sshd", "tmux", "screen", "herdr"].contains(name) { return nil }
            if process.executable.hasSuffix("/Orca Terminal Host.app/Contents/MacOS/orca-terminal-host")
                || process.executable.hasSuffix("/Orca.app/Contents/MacOS/Orca") {
                // A local Orca daemon may inherit SSH_CONNECTION from its launcher.
                // Actual local ancestry, not that inherited flag, proves this binding.
                let target = SessionDestination(host: .orca, target: handle, profile: env["ORCA_USER_DATA_PATH"])
                guard isAlive(owner), (try? SessionNavigator.validate(target)) != nil else { return nil }
                return target
            }
            pid = process.pid
        }
        return nil
    }

    private static func parentProcess(_ pid: Int32) -> (pid: Int32, executable: String)? {
        guard let data = try? SessionCommand.run("/bin/ps", ["-p", String(pid), "-o", "ppid=,comm="], timeout: 0.3),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines).split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard fields.count == 2, let parent = Int32(fields[0]) else { return nil }
        return (parent, String(fields[1]))
    }

}
