import Foundation
import Darwin

enum CodexClient {
    static func fetch(executable override: URL? = nil) throws -> QuotaSnapshot {
        let process = Process()
        let input = Pipe(), output = Pipe()
        let executable = try override ?? CLIPaths.executable(for: .codex)
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = executable.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        process.environment = env
        process.standardInput = input
        process.standardOutput = output
        // Never persist account responses, credentials, or app-server stderr.
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            // Bound cleanup even if this app-server version does not exit on EOF.
            let end = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < end { usleep(10_000) }
            if process.isRunning { process.terminate() }
            let termEnd = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < termEnd { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "ai_quota_bar", "version": "2.0.0"], "capabilities": [:]]])
        var buffer = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        let fd = output.fileHandleForReading.fileDescriptor
        while ProcessInfo.processInfo.systemUptime < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, 250)
            if result < 0 {
                if errno == EINTR { continue }
                throw ProviderFailure.connection
            }
            if result == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(fd, &bytes, bytes.count)
            guard count > 0 else { throw ProviderFailure.connection }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count < 2_000_000 else { throw ProviderFailure.connection }
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = object["id"] as? Int else { continue }
                if let error = object["error"] as? [String: Any] {
                    let message = (error["message"] as? String ?? "").lowercased()
                    if message.contains("auth") || message.contains("log in") || message.contains("login") { throw ProviderFailure.authentication }
                    throw ProviderFailure.connection
                }
                if id == 1 {
                    try send(["method": "initialized"])
                    try send(["id": 2, "method": "account/read", "params": ["refreshToken": false]])
                } else if id == 2 {
                    guard let payload = object["result"] as? [String: Any],
                          let account = payload["account"] as? [String: Any] else { throw ProviderFailure.authentication }
                    guard account["type"] as? String != "apiKey" else { throw ProviderFailure.noData }
                    try send(["id": 3, "method": "account/rateLimits/read", "params": ["excludeResetCreditDetails": false]])
                } else if id == 3, let payload = object["result"] {
                    let data = try JSONSerialization.data(withJSONObject: payload)
                    return try JSONDecoder().decode(QuotaResponse.self, from: data).snapshot()
                }
            }
        }
        throw ProviderFailure.timeout
    }
}
