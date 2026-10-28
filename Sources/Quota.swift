import Foundation

enum Provider: String, CaseIterable {
    case codex, claude
    var name: String { self == .codex ? "Codex" : "Claude Code" }
    var asset: String { self == .codex ? "Codex" : "Claude" }
    var setupURL: URL {
        URL(string: self == .codex ? "https://developers.openai.com/codex/cli/" : "https://code.claude.com/docs/en/quickstart")!
    }
}

enum ProviderFailure: Error, LocalizedError {
    case missingCLI, authentication, noData, timeout, connection, keychainLocked, rateLimited
    var errorDescription: String? {
        switch self {
        case .missingCLI: return L10n.text("설치 필요", "Install required")
        case .authentication: return L10n.text("로그인 필요", "Sign in required")
        case .noData: return L10n.text("한도 정보 제공 안 됨", "Limits unavailable")
        case .timeout: return L10n.text("조회 시간 초과", "Request timed out")
        case .connection: return L10n.text("연결 확인 필요", "Connection error")
        case .keychainLocked: return L10n.text("키체인 접근 필요", "Keychain access required")
        case .rateLimited: return L10n.text("잠시 후 다시 조회", "Try again later")
        }
    }
}

struct QuotaWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Double?
    var remaining: Int { usedPercent.isFinite ? Int(max(0, min(100, 100 - usedPercent)).rounded(.down)) : 0 }
    var label: String {
        switch windowDurationMins {
        case 10080: return L10n.text("주간", "Weekly")
        case 300: return L10n.text("5시간", "5-hour")
        case .some(let minutes): return L10n.text("\(minutes)분", "\(minutes)-min")
        case nil: return L10n.text("세션", "Session")
        }
    }
    func expired(at date: Date) -> Bool { resetsAt.map { $0 <= date.timeIntervalSince1970 } ?? false }
}

struct ResetCredit: Decodable {
    let id: String
    let resetType: String
    let status: String
    let expiresAt: Double?
}

struct ResetCredits: Decodable {
    let availableCount: Int
    let credits: [ResetCredit]?

    func availableDetails(at date: Date) -> [ResetCredit] {
        guard availableCount > 0 else { return [] }
        return (credits ?? []).filter {
            $0.status == "available" && $0.resetType == "codexRateLimits" &&
            ($0.expiresAt.map { $0 > date.timeIntervalSince1970 } ?? true)
        }.sorted { ($0.expiresAt ?? .infinity) < ($1.expiresAt ?? .infinity) }
    }

    func hasExpiredDetails(at date: Date) -> Bool {
        (credits ?? []).contains { $0.status == "available" && ($0.expiresAt.map { $0 <= date.timeIntervalSince1970 } ?? false) }
    }
}

struct QuotaSnapshot {
    let windows: [QuotaWindow]
    let resetCredits: ResetCredits?
    var weekly: QuotaWindow? { windows.first { $0.windowDurationMins == 10080 } }
    var summaryWindow: QuotaWindow? { weekly ?? windows.first }
}

struct QuotaBucket: Decodable {
    let limitId: String?
    let primary: QuotaWindow?
    let secondary: QuotaWindow?
}

struct QuotaResponse: Decodable {
    let rateLimits: QuotaBucket?
    let rateLimitsByLimitId: [String: QuotaBucket]?
    let rateLimitResetCredits: ResetCredits?

    func snapshot() throws -> QuotaSnapshot {
        let bucket = rateLimitsByLimitId?["codex"] ?? rateLimits
        guard let bucket, bucket.limitId == nil || bucket.limitId == "codex" else { throw ProviderFailure.noData }
        let windows = [bucket.primary, bucket.secondary].compactMap { $0 }.filter { $0.usedPercent.isFinite }
        guard !windows.isEmpty else { throw ProviderFailure.noData }
        return QuotaSnapshot(windows: windows, resetCredits: rateLimitResetCredits)
    }
}

struct ClaudeUsage: Decodable {
    struct Window: Decodable {
        let utilization: Double
        let resets_at: String?
    }
    let five_hour: Window?
    let seven_day: Window?

    static func decode(_ data: Data) throws -> QuotaSnapshot {
        let usage = try JSONDecoder().decode(Self.self, from: data)
        let windows = try [(usage.five_hour, 300), (usage.seven_day, 10080)].compactMap { window, minutes -> QuotaWindow? in
            guard let window, window.utilization.isFinite else { return nil }
            var reset: Double?
            if let raw = window.resets_at {
                let format = ISO8601DateFormatter()
                format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let fractional = format.date(from: raw)
                format.formatOptions = [.withInternetDateTime]
                guard let date = fractional ?? format.date(from: raw) else { throw ProviderFailure.connection }
                reset = date.timeIntervalSince1970
            }
            return QuotaWindow(usedPercent: window.utilization, windowDurationMins: minutes, resetsAt: reset)
        }
        guard !windows.isEmpty else { throw ProviderFailure.noData }
        // Claude's usage endpoint has no verified reset-credit contract. Extra usage is paid credit, not a reset.
        return QuotaSnapshot(windows: windows, resetCredits: nil)
    }
}

struct ProviderState {
    var snapshot: QuotaSnapshot?
    var checkedAt: Date?
    var attemptedAt: Date?
    var fetching = false
    var failure: ProviderFailure?

    func stale(at date: Date) -> Bool { checkedAt.map { date.timeIntervalSince($0) > 900 } ?? true }
    func summary(at date: Date) -> String {
        if let failure { return failure.localizedDescription }
        guard let window = snapshot?.summaryWindow else { return fetching ? L10n.text("조회 중…", "Loading…") : L10n.text("대기 중", "Pending") }
        guard !stale(at: date), !window.expired(at: date) else { return L10n.text("갱신 필요", "Refresh required") }
        return "\(window.remaining)%"
    }
}

func dateText(_ timestamp: Double, format: String = "MMMdjm") -> String {
    let formatter = DateFormatter()
    formatter.locale = L10n.locale
    formatter.timeZone = .autoupdatingCurrent
    formatter.setLocalizedDateFormatFromTemplate(format)
    return formatter.string(from: Date(timeIntervalSince1970: timestamp))
}
