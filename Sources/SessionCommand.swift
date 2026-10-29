import Foundation
import Darwin

/// Used only for terminal integration. Never execute shell text from an event.
enum SessionCommand {
    static func hookEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        var ancestor = getppid()
        for _ in 0..<12 {
            guard ancestor > 1, let data = try? run("/bin/ps", ["-p", String(ancestor), "-o", "ppid=,comm="], timeout: 0.3),
                  let text = String(data: data, encoding: .utf8) else { break }
            let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2, let parent = Int32(parts[0]), parent != ancestor else { break }
            if ["codex", "claude"].contains(URL(fileURLWithPath: String(parts[1])).lastPathComponent.lowercased()),
               let start = HerdrClientBinding.startTime(ancestor) {
                environment["AIQUOTABAR_OWNER_PID"] = String(ancestor)
                environment["AIQUOTABAR_OWNER_START"] = start
                break
            }
            ancestor = parent
        }
        guard environment["TERM_PROGRAM"] == "Apple_Terminal" else { return environment }
        var pid = getppid()
        var tty: String?
        var owner: Int32?
        for _ in 0..<16 {
            guard pid > 1, let data = try? run("/bin/ps", ["-p", String(pid), "-o", "ppid=,tty="], timeout: 0.3),
                  let text = String(data: data, encoding: .utf8) else { break }
            let fields = text.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, let parent = Int32(fields[0]), parent != pid else { break }
            let terminal = String(fields[1])
            if terminal.hasPrefix("ttys"), terminal.dropFirst(4).allSatisfy(\.isNumber) {
                if let tty, tty != terminal { break }
                tty = terminal; owner = pid
            }
            pid = parent
        }
        if let tty, let owner, let start = HerdrClientBinding.startTime(owner) {
            environment["AIQUOTABAR_TTY"] = "/dev/\(tty)"
            environment["AIQUOTABAR_TTY_PID"] = String(owner)
            environment["AIQUOTABAR_TTY_START"] = start
        }
        return environment
    }
    static func run(_ path: String, _ arguments: [String], environment: [String: String] = [:], timeout: TimeInterval = 4, outputLimit: Int = 262_144) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        // Drain concurrently so a large CLI response cannot fill the pipe and deadlock.
        let reader = DispatchGroup()
        let buffer = CommandOutput(limit: outputLimit)
        reader.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { reader.leave() }
            while let data = try? pipe.fileHandleForReading.read(upToCount: 8192), !data.isEmpty { buffer.append(data) }
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 0.2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            throw CompletionError.unavailable
        }
        guard reader.wait(timeout: .now() + 1) == .success, process.terminationStatus == 0 else { throw CompletionError.unavailable }
        return buffer.data
    }

    static func executable(_ name: String, bundled: String? = nil) throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [bundled, "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "\(home)/.local/bin/\(name)"]
        guard let path = candidates.compactMap({ $0 }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw CompletionError.unavailable }
        return path
    }

}

private final class CommandOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private let limit: Int
    init(limit: Int) { self.limit = limit }
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        if bytes.count < limit { bytes.append(data.prefix(limit - bytes.count)) }
    }
    var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
}
