import Foundation
import Darwin

/// Recover a missing hook destination only from its still-running local owner.
/// Never infer identity from a project name, directory, or terminal title.
enum OrcaProcessBinding {
    static func destination(for owner: SessionOwner,
                            isAlive: (SessionOwner) -> Bool = { $0.isAlive },
                            environment: (Int32) -> [String: String] = readEnvironment,
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

    private static func readEnvironment(_ pid: Int32) -> [String: String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 1_048_576
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return [:] }
        return routingEnvironment(Data(bytes.prefix(size)))
    }

    // Format: argc, executable, padding, argv, environment. See Apple's ps:
    // https://github.com/apple-oss-distributions/adv_cmds/blob/main/ps/print.c
    // Skip argv without decoding it, and retain only terminal-routing keys.
    static func routingEnvironment(_ data: Data) -> [String: String] {
        guard data.count >= 4, data.count <= 1_048_576 else { return [:] }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 65_536 else { return [:] }
        let bytes = [UInt8](data)
        var offset = 4
        func nextString() -> ArraySlice<UInt8>? {
            guard offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0) else { return nil }
            defer { offset = end + 1 }
            return bytes[offset..<end]
        }
        guard nextString() != nil else { return [:] }
        while offset < bytes.count && bytes[offset] == 0 { offset += 1 }
        for _ in 0..<argc { guard nextString() != nil else { return [:] } }
        let allowed: Set<String> = ["TERM_PROGRAM", "ORCA_TERMINAL_HANDLE", "ORCA_USER_DATA_PATH", "TMUX", "STY", "HERDR_PANE_ID"]
        var result: [String: String] = [:]
        while offset < bytes.count {
            guard let entry = nextString() else { return [:] }
            if entry.isEmpty { break }
            guard let equal = entry.firstIndex(of: 61), equal - entry.startIndex <= 32,
                  let key = String(bytes: entry[..<equal], encoding: .utf8), allowed.contains(key),
                  entry.count <= 4096, let value = String(bytes: entry[(equal + 1)...], encoding: .utf8) else { continue }
            result[key] = value
        }
        return result
    }
}
