import Foundation
import Darwin

/// Herdr's server outlives its clients, so its inherited terminal variables can be stale.
/// Register the attaching client, not the server, and reject bindings after that process exits.
struct HerdrClientBinding: Codable {
    let paneSocket: String
    let processID: Int32
    let processStart: String
    let destination: SessionDestination

    func matches(socket: String, runningStart: String?) -> Bool {
        paneSocket == socket && runningStart == processStart
    }

    static func startTime(_ pid: Int32) -> String? {
        guard kill(pid, 0) == 0,
              let data = try? SessionCommand.run("/bin/ps", ["-p", String(pid), "-o", "lstart="], environment: ["LC_ALL":"C"], timeout: 1),
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    static func file(socket: String, directory: URL) -> URL {
        directory.appendingPathComponent("herdr-\(completionHash(socket)).json")
    }

    static func resolve(_ original: SessionDestination, directory: URL) -> SessionDestination {
        guard var herdr = original.herdr else { return original }
        let identity = socketIdentity(herdr.socket)
        if let saved = herdr.socketIdentity, saved != identity { return SessionDestination(herdr: herdr) }
        guard let data = try? Data(contentsOf: file(socket: herdr.socket, directory: directory)),
              let binding = try? JSONDecoder().decode(Self.self, from: data),
              binding.matches(socket: herdr.socket, runningStart: startTime(binding.processID)), identity != nil else {
            return SessionDestination(herdr: herdr)
        }
        herdr.socketIdentity = identity
        var target = binding.destination; target.herdr = herdr
        return target
    }

    static func socketIdentity(_ path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeSocket,
              let device = attributes[.systemNumber] as? NSNumber, let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return "\(device):\(inode)"
    }

    static func attach(arguments: [String], directory: URL = CompletionStore.standard.directory) throws -> Never {
        guard arguments.isEmpty || (arguments.count == 2 && arguments[0] == "--session") else { throw CompletionError.unsupported }
        let env = SessionCommand.hookEnvironment()
        guard env["HERDR_PANE_ID"] == nil else { throw CompletionError.unsupported }
        let target = SessionDestination.capture(environment: env)
        try SessionNavigator.validate(target)
        let config = env["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        var socket = env["HERDR_SOCKET_PATH"] ?? config.appendingPathComponent("herdr/herdr.sock").path
        if let name = arguments.last {
            guard !name.isEmpty, name.count <= 100, name != ".", name != "..", name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) else { throw CompletionError.unsupported }
            socket = config.appendingPathComponent("herdr/sessions/\(name)/herdr.sock").path
        } else if env["HERDR_SOCKET_PATH"] == nil, let name = env["HERDR_SESSION"], !name.isEmpty {
            guard !name.contains("/"), name != ".", name != ".." else { throw CompletionError.unsupported }
            socket = config.appendingPathComponent("herdr/sessions/\(name)/herdr.sock").path
        }
        let cli = try SessionCommand.executable("herdr")
        guard let start = startTime(getpid()) else { throw CompletionError.unavailable }
        let binding = Self(paneSocket: socket, processID: getpid(), processStart: start, destination: target)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = file(socket: socket, directory: directory)
        try JSONEncoder().encode(binding).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let argv = ([cli] + arguments).map { strdup($0) } + [nil]
        argv.withUnsafeBufferPointer { buffer in _ = execv(cli, buffer.baseAddress!) }
        argv.forEach { free($0) }
        throw CompletionError.unavailable
    }
}
