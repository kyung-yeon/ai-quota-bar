import Foundation
import Darwin

func orcaRPCTests() throws {
    let directory = URL(fileURLWithPath: "/tmp/aqb-rpc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("socket").path
    let server = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(server) }
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
    let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard bound == 0, listen(server, 3) == 0 else { throw CompletionError.unavailable }
    let metadata = directory.appendingPathComponent("orca-runtime.json")
    try JSONSerialization.data(withJSONObject: ["runtimeId": "fixture-runtime", "authToken": "fixture-secret",
        "transports": [["kind": "unix", "endpoint": path]]]).write(to: metadata)
    let rpc = try OrcaLocalRPC(profile: directory.path)
    func serve(runtime: String) -> DispatchGroup {
        let group = DispatchGroup(); group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            let peer = accept(server, nil, nil)
            guard peer >= 0 else { return }; defer { close(peer) }
            var noSignal: Int32 = 1
            setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var request = Data(), bytes = [UInt8](repeating: 0, count: 4096)
            while !request.contains(10), request.count < 16_384 {
                let count = recv(peer, &bytes, bytes.count, 0)
                guard count > 0 else { return }; request.append(contentsOf: bytes.prefix(count))
            }
            guard let json = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
                  let id = json["id"] as? String else { return }
            let valid = json["authToken"] as? String == "fixture-secret" && json["method"] as? String == "terminal.agentStatus"
            guard var data = try? JSONSerialization.data(withJSONObject: ["id": id, "ok": valid,
                "result": ["verified": valid], "_meta": ["runtimeId": runtime]]) else { return }
            data.append(10)
            var frames = Data("{\"_keepalive\":true}\n".utf8); frames.append(data)
            // Split framing to exercise partial socket reads.
            for byte in frames { var byte = byte; _ = send(peer, &byte, 1, 0) }
        }
        return group
    }
    var group = serve(runtime: "fixture-runtime")
    let result = try rpc.call("terminal.agentStatus", ["terminal": "term_fixture"])
    guard result["verified"] as? Bool == true, group.wait(timeout: .now() + 2) == .success else { throw CompletionError.unavailable }
    group = serve(runtime: "replacement-runtime")
    do { _ = try rpc.call("terminal.agentStatus", [:]); throw CompletionError.invalidEvent }
    catch PromptSendError.unavailable { }
    guard group.wait(timeout: .now() + 2) == .success else { throw CompletionError.unavailable }
    try FileManager.default.removeItem(at: metadata)
    let other = directory.appendingPathComponent("metadata.json")
    try Data("{}".utf8).write(to: other)
    try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: other)
    do { _ = try OrcaLocalRPC(profile: directory.path); throw CompletionError.invalidEvent }
    catch PromptSendError.unavailable { }
    print("PASS: 3 local RPC framing, authentication, and runtime identity checks")
}
