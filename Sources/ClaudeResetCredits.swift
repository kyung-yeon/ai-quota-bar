import Foundation

// Observed Claude OAuth inventory, separate from paid extra_usage and natural window resets.
// Decode independently so an unsupported/malformed optional block cannot discard usage windows.
enum ClaudeResetCredits {
    private struct Response: Decodable { let cedar_ember: Inventory? }
    private struct Inventory: Decodable {
        let eligible: Bool
        let grants: [Grant]
    }
    private struct Grant: Decodable {
        let resets_left: Int
        let starts_at: String?
        let ends_at: String?
        let paused: Bool
    }

    static func decode(_ data: Data, now: Date) -> ResetCredits? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let inventory = response.cedar_ember, inventory.eligible else { return nil }
        var credits: [ResetCredit] = []
        var count = 0
        for (index, grant) in inventory.grants.enumerated() {
            guard grant.resets_left >= 0 else { return nil }
            let start: Double?
            let end: Double?
            do {
                start = try grant.starts_at.map(ClaudeUsage.parseReset)
                end = try grant.ends_at.map(ClaudeUsage.parseReset)
            } catch { return nil }
            guard !grant.paused, grant.resets_left > 0,
                  start.map({ $0 <= now.timeIntervalSince1970 }) ?? true,
                  end.map({ $0 > now.timeIntervalSince1970 }) ?? true else { continue }
            let (total, overflow) = count.addingReportingOverflow(grant.resets_left)
            guard !overflow else { return nil }
            count = total
            // Keep only count/expiry; never retain redeemable grant IDs or server labels.
            credits.append(ResetCredit(id: "claude-grant-\(index)", resetType: "claudeRateLimits",
                                       status: "available", expiresAt: end, quantity: grant.resets_left))
        }
        return ResetCredits(availableCount: count, credits: credits)
    }
}
