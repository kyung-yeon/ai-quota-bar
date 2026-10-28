import Foundation

enum CLIPaths {
    static func executable(for provider: Provider) throws -> URL {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let name = provider.rawValue
        var paths: [String] = []
        if let url = Bundle.main.url(forResource: "\(name)-path", withExtension: "txt"),
           let path = try? String(contentsOf: url, encoding: .utf8) {
            paths.append(path.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        paths += ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", home.appendingPathComponent(".local/bin/\(name)").path]
        paths += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/\(name)" }
        if provider == .claude { paths.append(home.appendingPathComponent(".claude/local/claude").path) }
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? fm.contentsOfDirectory(atPath: nvm.path) {
            paths += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { nvm.appendingPathComponent("\($0)/bin/\(name)").path }
        }
        guard let path = paths.first(where: { !$0.isEmpty && fm.isExecutableFile(atPath: $0) }) else { throw ProviderFailure.missingCLI }
        return URL(fileURLWithPath: path)
    }
}
