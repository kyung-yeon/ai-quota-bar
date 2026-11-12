import Foundation

/// SQLite is opened read-only; SELECT returns usage scalars, never message bodies or titles.
struct OpenCodeCostReader {
    let home: URL
    let environment: [String: String]

    func read() -> (records: [UsageCostRecord], incomplete: Bool) {
        let base = environment["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? home.appendingPathComponent(".local/share")
        let directory = base.appendingPathComponent("opencode")
        var databases: [URL]
        if let override = environment["OPENCODE_DB"], !override.isEmpty {
            if override == ":memory:" { return ([], false) }
            databases = [override.hasPrefix("/") ? URL(fileURLWithPath: override) : directory.appendingPathComponent(override)]
        } else {
            databases = ((try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []).filter {
                $0.lastPathComponent.range(of: "^opencode(?:-[A-Za-z0-9_.-]+)?\\.db$", options: .regularExpression) != nil
            }.sorted {
                if $0.lastPathComponent == "opencode.db" { return true }
                if $1.lastPathComponent == "opencode.db" { return false }
                return $0.lastPathComponent < $1.lastPathComponent
            }
        }
        var all: [String: UsageCostRecord] = [:], incomplete = databases.count > 16
        var selectedSessions: Set<String> = []
        let deadline = Date().addingTimeInterval(20)
        for database in databases.prefix(16) {
            if Date() >= deadline { incomplete = true; break }
            guard FileManager.default.fileExists(atPath: database.path) else { continue }
            guard (try? database.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { incomplete = true; continue }
            do {
                let tables = Set(try query(database, "SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0["name"] as? String })
                var recognizedSchema = false
                var sessions: [String: UsageCostRecord] = [:]
                // Newer OpenCode stores cumulative totals. Do not attribute a session's entire
                // history to its last selected model: it may have switched models/providers.
                for table in ["session_v2", "session"] where tables.contains(table) {
                    let columns = try columns(database, table)
                    guard columns.contains("id"), columns.contains("cost"), columns.contains("tokens_input") else { continue }
                    recognizedSchema = true
                    let names = ["cost", "tokens_input", "tokens_output", "tokens_reasoning", "tokens_cache_read", "tokens_cache_write"]
                    let fields = names.map { columns.contains($0) ? $0 : "0 AS \($0)" }.joined(separator: ",")
                    let rows = try query(database, "SELECT id,\(fields) FROM \(table) LIMIT 50001")
                    if rows.count > 50_000 { incomplete = true }
                    for row in rows.prefix(50_000) {
                        guard let id = usageIdentifier(row["id"]) else { continue }
                        let cost = usageNumber(row, "cost")
                        let record = UsageCostRecord(client: "OpenCode", provider: "mixed/unspecified", model: "session totals",
                            input: usageNumber(row, "tokens_input"),
                            output: usageNumber(row, "tokens_output") + usageNumber(row, "tokens_reasoning"),
                            cacheRead: usageNumber(row, "tokens_cache_read"), cacheWrite: usageNumber(row, "tokens_cache_write"),
                            recordedUSD: cost > 0 ? cost : nil, requestSized: false)
                        guard record.tokens > 0 || cost > 0 else { continue }
                        if var previous = sessions[id] { previous.merge(record); sessions[id] = previous }
                        else { sessions[id] = record }
                    }
                }
                // Message-level records permit provider/model attribution (including DeepSeek).
                // For cumulative sessions, retain message breakdown only when it fully reconciles
                // to the recorded total; otherwise show one honest mixed-model session total.
                var messages: [String: (String, UsageCostRecord)] = [:]
                for table in ["session_message", "message"] where tables.contains(table) {
                    let columns = try columns(database, table)
                    guard ["id", "session_id", "data"].allSatisfy(columns.contains) else { continue }
                    recognizedSchema = true
                    let predicate = table == "message" ? "json_extract(data,'$.role')='assistant'"
                        : columns.contains("type") ? "type='assistant'" : "json_extract(data,'$.tokens.input') IS NOT NULL"
                    let projections = ["COALESCE(json_extract(data,'$.modelID'),json_extract(data,'$.model.modelID'),json_extract(data,'$.model.id'))",
                        "json_extract(data,'$.modelId')",
                        "COALESCE(json_extract(data,'$.providerID'),json_extract(data,'$.model.providerID'))",
                        "json_extract(data,'$.providerId')"]
                        + ["cost", "tokens.input", "tokens.output", "tokens.reasoning", "tokens.cache.read", "tokens.cache.write"].map { "json_extract(data,'$.\($0)')" }
                    let fields = projections.enumerated().map { "\($0.element) AS f\($0.offset)" }.joined(separator: ",")
                    let rows = try query(database, "SELECT id,session_id,\(fields) FROM \(table) WHERE json_valid(data) AND (\(predicate)) LIMIT 50001")
                    if rows.count > 50_000 { incomplete = true }
                    for row in rows.prefix(50_000) {
                        guard let id = usageIdentifier(row["id"]), let session = usageIdentifier(row["session_id"]), messages[id] == nil else { continue }
                        let model = usageIdentifier(row["f0"]) ?? usageIdentifier(row["f1"]) ?? "unknown"
                        let provider = usageIdentifier(row["f2"]) ?? usageIdentifier(row["f3"]) ?? "unknown"
                        let cost = usageNumber(row, "f4")
                        messages[id] = (session, UsageCostRecord(client: "OpenCode", provider: provider, model: model,
                            input: usageNumber(row, "f5"), output: usageNumber(row, "f6") + usageNumber(row, "f7"),
                            cacheRead: usageNumber(row, "f8"), cacheWrite: usageNumber(row, "f9"), recordedUSD: cost > 0 ? cost : nil))
                    }
                }
                var represented: Set<String> = []
                let bySession = Dictionary(grouping: messages.values, by: { $0.0 })
                for (session, entries) in bySession {
                    if let aggregate = sessions[session] {
                        let sum = entries.reduce(0) { $0 + ($1.1.recordedUSD ?? 0) }
                        guard let cost = aggregate.recordedUSD, entries.allSatisfy({ $0.1.recordedUSD != nil }), abs(sum - cost) < 0.000001 else { continue }
                    }
                    represented.insert(session)
                }
                for (id, entry) in messages where represented.contains(entry.0) && !selectedSessions.contains(entry.0) { merge(entry.1, key: "message:\(id)", into: &all) }
                for (id, record) in sessions where !represented.contains(id) && !selectedSessions.contains(id) { merge(record, key: "session:\(id)", into: &all) }
                selectedSessions.formUnion(sessions.keys)
                selectedSessions.formUnion(messages.values.map { $0.0 })
                // A supported database can contain only model switches and no billable usage.
                if !recognizedSchema && !tables.isEmpty { incomplete = true }
            } catch { incomplete = true }
        }
        return (Array(all.values), incomplete)
    }

    private func merge(_ record: UsageCostRecord, key: String, into records: inout [String: UsageCostRecord]) {
        if var previous = records[key] { previous.merge(record); records[key] = previous }
        else { records[key] = record }
    }

    private func columns(_ database: URL, _ table: String) throws -> Set<String> {
        Set(try query(database, "PRAGMA table_info(\(table))").compactMap { $0["name"] as? String })
    }

    private func query(_ database: URL, _ sql: String) throws -> [[String: Any]] {
        let data = try SessionCommand.run("/usr/bin/sqlite3", ["-readonly", "-json", database.path, sql], timeout: 3, outputLimit: 16 * 1024 * 1024)
        if data.isEmpty { return [] }
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw CompletionError.unavailable }
        return rows
    }
}
