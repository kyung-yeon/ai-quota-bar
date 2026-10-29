import Foundation
import Darwin

func navigationTests() throws {
    func expect(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "Navigation test: \(message)", code: 1) }
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aiquota-binding-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let socketPath = "/tmp/aqb-\(UUID().uuidString).sock"
    defer { try? FileManager.default.removeItem(at: directory); unlink(socketPath) }
    func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CompletionError.unavailable }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in socketPath.utf8.enumerated() { raw[index] = byte }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { close(fd); throw CompletionError.unavailable }
        return fd
    }
    let firstSocket = try makeSocket()
    defer { close(firstSocket) }
    let start = HerdrClientBinding.startTime(getpid())!
    let outer = SessionDestination(host: .iterm, target: "w0t0p0:sample")
    let binding = HerdrClientBinding(paneSocket: socketPath, processID: getpid(), processStart: start, destination: outer)
    try JSONEncoder().encode(binding).write(to: HerdrClientBinding.file(socket: socketPath, directory: directory))
    let unresolved = SessionDestination(herdr: HerdrDestination(pane: "w1:p1", socket: socketPath))
    let resolved = HerdrClientBinding.resolve(unresolved, directory: directory)
    try expect(resolved.host == .iterm && resolved.herdr?.socketIdentity != nil, "Live Herdr client resolves its outer terminal")
    unlink(socketPath)
    let secondSocket = try makeSocket()
    defer { close(secondSocket) }
    try expect(HerdrClientBinding.resolve(resolved, directory: directory).host == .unsupported, "Server restart cannot route an old alert to a reused pane")
    let newEvent = HerdrClientBinding.resolve(unresolved, directory: directory)
    try expect(newEvent.host == .iterm, "New completions can use the new server")
    let dead = HerdrClientBinding(paneSocket: socketPath, processID: getpid(), processStart: "not-this-process", destination: outer)
    try JSONEncoder().encode(dead).write(to: HerdrClientBinding.file(socket: socketPath, directory: directory))
    try expect(HerdrClientBinding.resolve(unresolved, directory: directory).host == .unsupported, "Expired client binding refuses to guess")
    let before = Date()
    do { _ = try SessionCommand.run("/bin/sleep", ["10"], timeout: 0.1); try expect(false, "Navigation helper must time out") }
    catch CompletionError.unavailable { try expect(Date().timeIntervalSince(before) < 2, "Hung helper is bounded") }
    print("PASS: 5 navigation lifetime and timeout checks")
}
