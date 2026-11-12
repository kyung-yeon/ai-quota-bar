import Foundation

/// Runs off the main thread. Bounds apply per client; a capped or unreadable scan is visibly partial.
final class UsageCostScanner {
    private var records: [String: UsageCostRecord] = [:]
    private var incomplete: Set<String> = []
    private let environment: [String: String]
    private let home: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.home = home; self.environment = environment
    }

    func scan() -> UsageCostSnapshot {
        let codex = root("CODEX_HOME", fallback: home.appendingPathComponent(".codex"))
        scanFiles([codex.appendingPathComponent("sessions"), codex.appendingPathComponent("archived_sessions")], client: "Codex")
        let claude = root("CLAUDE_CONFIG_DIR", fallback: home.appendingPathComponent(".claude"))
        scanFiles([claude.appendingPathComponent("projects"), claude.appendingPathComponent("transcripts")], client: "Claude Code")
        let openCode = OpenCodeCostReader(home: home, environment: environment).read()
        if openCode.incomplete { incomplete.insert("OpenCode") }
        return UsageCostSnapshot(records: Array(records.values) + openCode.records, incompleteSources: incomplete)
    }

    private func root(_ key: String, fallback: URL) -> URL {
        guard let path = environment[key], path.hasPrefix("/") else { return fallback }
        return URL(fileURLWithPath: path)
    }

    private func scanFiles(_ roots: [URL], client: String) {
        let manager = FileManager.default
        var bytes = 0, files = 0
        let deadline = Date().addingTimeInterval(15)
        for root in roots {
            guard manager.fileExists(atPath: root.path) else { continue }
            guard let enumerator = manager.enumerator(at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles],
                errorHandler: { [self] _, _ in incomplete.insert(client); return true }) else {
                incomplete.insert(client); continue
            }
            for case let url as URL in enumerator {
                if Date() >= deadline || bytes >= 256 * 1024 * 1024 || files >= 10_000 || records.count >= 100_000 {
                    incomplete.insert(client); return
                }
                guard url.pathExtension == "jsonl" else { continue }
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                files += 1
                var model = "unknown", provider = "openai", turn: String?
                var previousTotal: [Double]?
                do {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    var line = Data(), oversized = false
                    while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                        bytes += chunk.count
                        if Date() >= deadline || bytes > 256 * 1024 * 1024 || records.count >= 100_000 {
                            incomplete.insert(client); return
                        }
                        var start = chunk.startIndex
                        for index in chunk.indices where chunk[index] == 10 {
                            if !oversized { line.append(chunk[start..<index]) }
                            if line.count > 2 * 1024 * 1024 { oversized = true }
                            if oversized { incomplete.insert(client); model = "unknown"; turn = nil }
                            else if !line.isEmpty {
                                if let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                                    if client == "Codex" {
                                        consumeCodex(object, model: &model, provider: &provider, turn: &turn, previousTotal: &previousTotal)
                                    } else { consumeClaude(object) }
                                } else { incomplete.insert(client); model = "unknown"; turn = nil }
                            }
                            line.removeAll(keepingCapacity: true); oversized = false; start = index + 1
                        }
                        if !oversized { line.append(chunk[start..<chunk.endIndex]) }
                        if line.count > 2 * 1024 * 1024 { line.removeAll(keepingCapacity: false); oversized = true }
                    }
                    // Writers may still be appending the final record; do not decode a partial line.
                    if !line.isEmpty || oversized { incomplete.insert(client) }
                } catch { incomplete.insert(client) }
            }
        }
    }

    private func consumeClaude(_ object: [String: Any]) {
        guard object["type"] as? String == "assistant", let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return }
        guard let id = usageIdentifier(message["id"]) ?? usageIdentifier(object["uuid"]) else {
            incomplete.insert("Claude Code"); return
        }
        let request = usageIdentifier(object["requestId"]) ?? ""
        let cache = usage["cache_creation"] as? [String: Any] ?? [:]
        let record = UsageCostRecord(client: "Claude Code", provider: "anthropic",
            model: usageIdentifier(message["model"]) ?? "unknown", input: usageNumber(usage, "input_tokens"),
            output: usageNumber(usage, "output_tokens"), cacheRead: usageNumber(usage, "cache_read_input_tokens"),
            cacheWrite: usageNumber(usage, "cache_creation_input_tokens"), cacheWriteHour: usageNumber(cache, "ephemeral_1h_input_tokens"))
        insert(record, key: "claude:\(id):\(request)")
    }

    private func consumeCodex(_ object: [String: Any], model: inout String, provider: inout String,
                              turn: inout String?, previousTotal: inout [Double]?) {
        guard let payload = object["payload"] as? [String: Any] else { return }
        if object["type"] as? String == "session_meta" {
            provider = usageIdentifier(payload["model_provider"]) ?? "openai"
        }
        if object["type"] as? String == "turn_context" {
            model = usageIdentifier(payload["model"]) ?? usageIdentifier(payload["model_name"]) ?? "unknown"
            turn = usageIdentifier(payload["turn_id"])
        }
        guard object["type"] as? String == "event_msg", payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any] else { return }
        func counts(_ value: Any?) -> [Double]? {
            guard let value = value as? [String: Any] else { return nil }
            let input = usageNumber(value, "input_tokens"), output = usageNumber(value, "output_tokens")
            let cache = min(input, usageNumber(value, "cached_input_tokens") + (value["cached_input_tokens"] == nil ? usageNumber(value, "cache_read_input_tokens") : 0))
            return [input, output, cache]
        }
        let total = counts(info["total_token_usage"]), last = counts(info["last_token_usage"])
        if let total, total == previousTotal { return }
        var delta = last
        if delta == nil, let total {
            if let previousTotal {
                if zip(total, previousTotal).allSatisfy({ $0 >= $1 }) { delta = zip(total, previousTotal).map(-) }
            }
            // The first cumulative-only observation is a baseline, not a new request.
            // Subsequent monotonic deltas are retained but cannot be priced per request.
        }
        if let total { previousTotal = total }
        guard let delta, delta.reduce(0, +) > 0 else { return }
        guard let identity = (total != nil ? turn : nil) ?? usageIdentifier(object["timestamp"]) else {
            incomplete.insert("Codex"); return
        }
        let key = "codex:\(identity):\(total ?? []):\(last ?? [])"
        insert(UsageCostRecord(client: "Codex", provider: provider, model: model,
            input: max(0, delta[0] - delta[2]), output: delta[1], cacheRead: delta[2], requestSized: last != nil), key: key)
    }

    private func insert(_ record: UsageCostRecord, key: String) {
        if var previous = records[key] { previous.merge(record); records[key] = previous }
        else { records[key] = record }
    }
}
