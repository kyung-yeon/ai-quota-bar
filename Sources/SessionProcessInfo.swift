import Foundation
import Darwin

/// Transient, bounded process metadata. Never retain argv or unrelated environment values.
struct SessionProcessInfo {
    var routingEnvironment: [String: String] = [:]
    var isEphemeralExec = false

    static func read(_ pid: Int32) -> Self {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 1_048_576
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return Self() }
        return parse(Data(bytes.prefix(size)))
    }

    // Format documented in Apple's ps: argc, executable, padding, argv, environment.
    // https://github.com/apple-oss-distributions/adv_cmds/blob/main/ps/print.c
    static func parse(_ data: Data) -> Self {
        guard data.count >= 4, data.count <= 1_048_576 else { return Self() }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 65_536 else { return Self() }
        let bytes = [UInt8](data)
        var offset = 4
        func nextString() -> ArraySlice<UInt8>? {
            guard offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0) else { return nil }
            defer { offset = end + 1 }
            return bytes[offset..<end]
        }
        guard nextString() != nil else { return Self() }
        while offset < bytes.count && bytes[offset] == 0 { offset += 1 }
        var exec = false, ephemeral = false, optionsEnded = false
        for index in 0..<argc {
            guard let arg = nextString() else { return Self() }
            // Recognize the explicit command form only; arbitrary prompt text is not a flag.
            if index == 1 { exec = arg.elementsEqual("exec".utf8) || arg.elementsEqual("e".utf8) }
            if index > 1 && !optionsEnded && arg.elementsEqual("--ephemeral".utf8) { ephemeral = true }
            if arg.elementsEqual("--".utf8) { optionsEnded = true }
        }
        let allowed: Set<String> = ["TERM_PROGRAM", "ORCA_TERMINAL_HANDLE", "ORCA_USER_DATA_PATH", "TMUX", "STY", "HERDR_PANE_ID"]
        var result = Self(isEphemeralExec: exec && ephemeral)
        while offset < bytes.count {
            guard let entry = nextString() else { return Self() }
            if entry.isEmpty { break }
            guard let equal = entry.firstIndex(of: 61), equal - entry.startIndex <= 32,
                  let key = String(bytes: entry[..<equal], encoding: .utf8), allowed.contains(key),
                  entry.count <= 4096, let value = String(bytes: entry[(equal + 1)...], encoding: .utf8) else { continue }
            result.routingEnvironment[key] = value
        }
        return result
    }
}
