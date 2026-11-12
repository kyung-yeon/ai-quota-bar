import Foundation

enum UsageCostPricing {
    // Standard text API list prices, USD / million tokens, checked 2026-11-12.
    // https://developers.openai.com/api/docs/pricing
    // https://developers.openai.com/api/docs/models/gpt-5.4
    // https://developers.openai.com/api/docs/models/gpt-5.1-codex
    // https://platform.claude.com/docs/en/about-claude/pricing
    // Deliberately exact IDs: unknown aliases/providers must not become a zero-dollar estimate.
    private static let openAI: [String: [Double]] = [
        "gpt-6-astra": [10, 50, 1], "gpt-6.1-sol": [2, 10, 0.1],
        "gpt-6.1-terra": [1, 5, 0.05], "gpt-6-luna": [0.1, 0.5, 0.01],
        "gpt-5.4": [2.5, 15, 0.25], "gpt-5.4-2026-03-05": [2.5, 15, 0.25],
        "gpt-5.1-codex": [1.25, 10, 0.125]
    ]
    private static let anthropic: [String: [Double]] = [
        "claude-fable-5-2": [8, 40, 0.2, 10, 16],
        "claude-opus-5-5": [4, 20, 0.2, 5, 8],
        "claude-sonnet-5-5": [2, 10, 0.1, 2.5, 4],
        "claude-haiku-5-5": [0.1, 0.5, 0.01, 0.125, 0.2],
        "claude-fable-5-1": [10, 50, 0.25, 12.5, 20],
        "claude-mythos-5-1": [10, 50, 0.25, 12.5, 20],
        "claude-fable-5": [10, 50, 1, 12.5, 20],
        "claude-mythos-5": [10, 50, 1, 12.5, 20],
        "claude-opus-5": [5, 25, 0.5, 6.25, 10],
        "claude-opus-4-8": [5, 25, 0.5, 6.25, 10],
        "claude-opus-4-7": [5, 25, 0.5, 6.25, 10],
        "claude-opus-4-6": [5, 25, 0.5, 6.25, 10],
        "claude-opus-4-5": [5, 25, 0.5, 6.25, 10],
        "claude-opus-4-1": [15, 75, 1.5, 18.75, 30],
        "claude-opus-4": [15, 75, 1.5, 18.75, 30],
        "claude-sonnet-5": [2, 10, 0.2, 2.5, 4],
        "claude-sonnet-4-6": [3, 15, 0.3, 3.75, 6],
        "claude-sonnet-4-5": [3, 15, 0.3, 3.75, 6],
        "claude-sonnet-4": [3, 15, 0.3, 3.75, 6],
        "claude-haiku-4-5": [1, 5, 0.1, 1.25, 2]
    ]

    static func estimate(_ record: UsageCostRecord) -> Double? {
        let prompt = record.input + record.cacheRead + record.cacheWrite
        if record.provider == "openai", let rates = openAI[record.model] {
            // Total-only deltas lack request boundaries for context-dependent pricing.
            guard record.requestSized, record.cacheWrite == 0 else { return nil }
            // Session-wide long-context surcharge cannot be reconstructed reliably here.
            guard !record.model.hasPrefix("gpt-5.4") || prompt <= 272_000 else { return nil }
            return (record.input * rates[0] + record.output * rates[1] + record.cacheRead * rates[2]) / 1_000_000
        }
        guard record.provider == "anthropic", record.requestSized else { return nil }
        var model = record.model
        // Claude's documented dated snapshots retain the base model's list price.
        if let suffix = model.range(of: "-[0-9]{8}$", options: .regularExpression) { model.removeSubrange(suffix) }
        guard var rates = anthropic[model] else { return nil }
        if model == "claude-haiku-5-5", prompt > 100_000 { rates = [0.5, 2.5, 0.05, 0.625, 1] }
        if prompt > 200_000, ["claude-opus-4", "claude-opus-4-1", "claude-opus-4-5", "claude-sonnet-4", "claude-sonnet-4-5"].contains(model) { return nil }
        let hour = min(record.cacheWriteHour, record.cacheWrite)
        return (record.input * rates[0] + record.output * rates[1] + record.cacheRead * rates[2]
            + (record.cacheWrite - hour) * rates[3] + hour * rates[4]) / 1_000_000
    }
}
