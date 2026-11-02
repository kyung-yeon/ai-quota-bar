import Foundation
import Darwin

/// Local, authenticated, newline-delimited Orca RPC. No remote transport or token logging.
struct OrcaLocalRPC {
    private let endpoint: String
    private let token: String
    private let runtimeID: String

    init(profile: String?) throws {
        let folder = profile.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/orca")
        let file = folder.appendingPathComponent("orca-runtime.json")
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size < 65_536,
              let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
              let token = json["authToken"] as? String, !token.isEmpty,
              let runtimeID = json["runtimeId"] as? String, !runtimeID.isEmpty else { throw PromptSendError.unavailable }
        let transports = json["transports"] as? [[String: Any]] ?? (json["transport"] as? [String: Any]).map { [$0] } ?? []
        guard let endpoint = transports.first(where: { $0["kind"] as? String == "unix" })?["endpoint"] as? String,
              endpoint.hasPrefix("/"), endpoint.utf8.count < 104, !endpoint.utf8.contains(0),
              lstat(endpoint, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFSOCK else { throw PromptSendError.unavailable }
        self.endpoint = endpoint; self.token = token; self.runtimeID = runtimeID
    }

    func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PromptSendError.unavailable }
        defer { close(fd) }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(endpoint.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw PromptSendError.unavailable }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let id = UUID().uuidString
        var request = try JSONSerialization.data(withJSONObject: ["id": id, "authToken": token, "method": method, "params": params])
        request.append(10)
        let deadline = Date().addingTimeInterval(8)
        func ready(_ event: Int16) throws {
            var item = pollfd(fd: fd, events: event, revents: 0)
            let remaining = max(0, deadline.timeIntervalSinceNow * 1000)
            guard remaining > 0, poll(&item, 1, Int32(min(remaining, 8000))) > 0,
                  item.revents & event != 0 else { throw PromptSendError.unavailable }
        }
        var offset = 0
        while offset < request.count {
            try ready(Int16(POLLOUT))
            let sent = request.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), request.count - offset, 0) }
            if sent < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard sent > 0 else { throw PromptSendError.unavailable }; offset += sent
        }
        var buffer = Data(), chunk = [UInt8](repeating: 0, count: 8192)
        while buffer.count < 1_048_576 {
            try ready(Int16(POLLIN))
            let count = recv(fd, &chunk, chunk.count, 0)
            if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard count > 0 else { throw PromptSendError.unavailable }
            buffer.append(contentsOf: chunk.prefix(count))
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
                guard let result = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw PromptSendError.unavailable }
                if result["_keepalive"] != nil { continue }
                guard result["id"] as? String == id, (result["_meta"] as? [String: Any])?["runtimeId"] as? String == runtimeID,
                      result["ok"] as? Bool == true, let value = result["result"] as? [String: Any] else { throw PromptSendError.unavailable }
                return value
            }
        }
        throw PromptSendError.unavailable
    }
}
