import Foundation
import CoreFoundation

/// Sanitized usage only: no prompts, response bodies, paths, or credentials leave a reader.
struct UsageCostRecord {
    var client: String
    var provider: String
    var model: String
    var input: Double = 0 // Uncached input; cache counters are separate.
    var output: Double = 0 // Includes billed reasoning tokens.
    var cacheRead: Double = 0
    var cacheWrite: Double = 0
    var cacheWriteHour: Double = 0
    var recordedUSD: Double?
    var requestSized = true

    var tokens: Double { input + output + cacheRead + cacheWrite }
    mutating func merge(_ other: Self) {
        input = max(input, other.input); output = max(output, other.output)
        cacheRead = max(cacheRead, other.cacheRead); cacheWrite = max(cacheWrite, other.cacheWrite)
        cacheWriteHour = max(cacheWriteHour, other.cacheWriteHour)
        if let cost = other.recordedUSD { recordedUSD = max(recordedUSD ?? 0, cost) }
    }
}

struct UsageCostGroup {
    let client: String
    let provider: String
    let model: String
    var usd: Double = 0
    var estimated = 0
    var unestimated = 0
    var tokens: Double = 0
    var recorded = 0
}

struct UsageCostSnapshot {
    var groups: [UsageCostGroup] = []
    var incompleteSources: Set<String> = []
    var scannedAt = Date()
    var usd: Double { groups.reduce(0) { $0 + $1.usd } }
    var estimated: Int { groups.reduce(0) { $0 + $1.estimated } }
    var unestimated: Int { groups.reduce(0) { $0 + $1.unestimated } }

    init(records: [UsageCostRecord], incompleteSources: Set<String>) {
        self.incompleteSources = incompleteSources
        var indexed: [String: UsageCostGroup] = [:]
        for record in records where record.tokens > 0 || record.recordedUSD != nil {
            let key = [record.client, record.provider, record.model].joined(separator: "\u{1f}")
            var group = indexed[key] ?? UsageCostGroup(client: record.client, provider: record.provider, model: record.model)
            group.tokens += record.tokens
            if let usd = record.recordedUSD ?? UsageCostPricing.estimate(record), usd.isFinite, usd >= 0 {
                group.usd += usd; group.estimated += 1
                if record.recordedUSD != nil { group.recorded += 1 }
            } else { group.unestimated += 1 }
            indexed[key] = group
        }
        groups = indexed.values.sorted {
            if $0.client != $1.client { return $0.client < $1.client }
            if $0.provider != $1.provider { return $0.provider < $1.provider }
            return $0.model < $1.model
        }
    }
}

func usageNumber(_ object: [String: Any], _ key: String) -> Double {
    guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return 0 }
    let value = number.doubleValue
    return value.isFinite && value >= 0 && value < 1e15 ? value : 0
}

func usageIdentifier(_ value: Any?) -> String? {
    guard let value = value as? String, !value.isEmpty, value.utf8.count <= 256,
          !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
    return value
}
