import Foundation

func selfTest() throws {
    var count = 0
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw NSError(domain: "Test failed: \(message)", code: 1) }
        count += 1
    }
    func codex(_ json: String) throws -> QuotaSnapshot {
        try JSONDecoder().decode(QuotaResponse.self, from: Data(json.utf8)).snapshot()
    }
    try expect(L10n.isKorean(["ko-KR", "en-US"]), "Korean system language")
    try expect(!L10n.isKorean(["en-US", "ko-KR"]), "English primary language")
    try expect(!L10n.isKorean(["ja-JP"]), "Other languages fall back to English")
    try expect(!L10n.isKorean(["kok-IN"]), "Konkani must not be mistaken for Korean")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let weekly = try codex(#"{"rateLimits":{"secondary":{"usedPercent":19,"windowDurationMins":10080,"resetsAt":1800500000}}}"#)
    try expect(weekly.weekly?.remaining == 81, "Codex weekly remaining")
    let mapped = try codex(#"{"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":10080}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":10,"windowDurationMins":300},"secondary":{"usedPercent":12,"windowDurationMins":10080}},"spark":{"primary":{"usedPercent":0,"windowDurationMins":10080}}}}"#)
    try expect(mapped.weekly?.remaining == 88, "Codex bucket takes precedence")
    try expect(mapped.windows.count == 2, "Session and weekly quotas retained")
    let credits = try codex(#"{"rateLimits":{"primary":{"usedPercent":1,"windowDurationMins":10080}},"rateLimitResetCredits":{"availableCount":5,"credits":[{"id":"valid","resetType":"codexRateLimits","status":"available","expiresAt":1800000500},{"id":"expired","resetType":"codexRateLimits","status":"available","expiresAt":1799999999},{"id":"used","resetType":"codexRateLimits","status":"redeemed","expiresAt":1800000400},{"id":"no-expiry","resetType":"codexRateLimits","status":"available","expiresAt":null}]}}"#)
    try expect(credits.resetCredits?.availableCount == 5, "Server count is authoritative even with partial details")
    let available = credits.resetCredits!.availableDetails(at: now)
    try expect(available.map(\.id) == ["valid", "no-expiry"], "Expired and redeemed credits hidden; nearest expiry first")
    try expect(weekly.resetCredits == nil, "Missing reset credit data is unknown, not zero")
    let countOnly = try codex(#"{"rateLimits":{"primary":{"usedPercent":0,"windowDurationMins":10080}},"rateLimitResetCredits":{"availableCount":2,"credits":null}}"#)
    try expect(countOnly.resetCredits?.availableCount == 2 && countOnly.resetCredits?.credits == nil, "Count-only credits supported")
    let claude = try ClaudeUsage.decode(Data(#"{"five_hour":{"utilization":24.5,"resets_at":"2027-01-15T10:00:00.123456+00:00"},"seven_day":{"utilization":62,"resets_at":"2027-01-20T10:00:00Z"},"extra_usage":{"is_enabled":true,"used_credits":1200}}"#.utf8))
    try expect(claude.windows.first?.remaining == 75, "Claude utilization is already a percentage")
    try expect(claude.weekly?.remaining == 38, "Claude weekly quota")
    try expect(claude.windows.allSatisfy { $0.resetsAt != nil }, "ISO8601 dates with and without fractional seconds")
    try expect(claude.resetCredits == nil, "Paid extra usage is not a reset credit")
    let zero = ResetCredits(availableCount: 0, credits: credits.resetCredits!.credits)
    try expect(zero.availableDetails(at: now).isEmpty, "Zero authoritative count hides inconsistent detail rows")
    let validCredentials = Data(#"{"claudeAiOauth":{"accessToken":"test-only-token","expiresAt":1800000001000}}"#.utf8)
    let token = try ClaudeClient.Credentials.token(from: validCredentials, now: now)
    try expect(token == "test-only-token", "Claude expiry is milliseconds, not seconds")
    for credentials in [#"{}"#, #"{"claudeAiOauth":{"accessToken":"","expiresAt":1800000001000}}"#, #"{"claudeAiOauth":{"accessToken":"expired-test-token","expiresAt":1800000000000}}"#, "not JSON"] {
        do { _ = try ClaudeClient.Credentials.token(from: Data(credentials.utf8), now: now); try expect(false, "Missing or expired credentials require sign in") }
        catch ProviderFailure.authentication { count += 1 }
    }
    for invalid in [#"{"rateLimits":null}"#, #"{"rateLimits":{"limitId":"spark","primary":{"usedPercent":0,"windowDurationMins":10080}}}"#] {
        do { _ = try codex(invalid); try expect(false, "Reject missing Codex quota") }
        catch ProviderFailure.noData { count += 1 }
    }
    do { _ = try ClaudeUsage.decode(Data(#"{"five_hour":null,"seven_day":null}"#.utf8)); try expect(false, "Missing Claude quota") }
    catch ProviderFailure.noData { count += 1 }
    var state = ProviderState()
    state.failure = .missingCLI
    try expect(state.summary(at: now) == L10n.text("설치 필요", "Install required"), "Missing installation state")
    state.failure = .authentication
    try expect(state.summary(at: now) == L10n.text("로그인 필요", "Sign in required"), "Missing authentication state")
    state.snapshot = weekly
    state.checkedAt = now
    state.failure = .connection
    try expect(state.summary(at: now) == L10n.text("연결 확인 필요", "Connection error"), "Network failure is not a login failure or a fresh percentage")
    state.failure = nil
    state.snapshot = weekly
    state.checkedAt = now
    try expect(state.summary(at: now) == "81%", "Fresh summary")
    try expect(state.summary(at: now.addingTimeInterval(901)) == L10n.text("갱신 필요", "Refresh required"), "Stale quota never presented as current")
    state.checkedAt = now.addingTimeInterval(600_000)
    try expect(state.summary(at: now.addingTimeInterval(600_000)) == L10n.text("갱신 필요", "Refresh required"), "Past reset never presented as current")
    try expect(QuotaWindow(usedPercent: 101, windowDurationMins: 300, resetsAt: nil).remaining == 0, "Overage clamps to zero remaining")
    try expect(QuotaWindow(usedPercent: -1, windowDurationMins: 300, resetsAt: nil).remaining == 100, "Negative usage clamps to full remaining")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aiquota-protocol-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fakeCLI = directory.appendingPathComponent("codex")
    for account in ["null", #"{"type":"apiKey"}"#] {
        let script = """
        #!/usr/bin/python3
        import json, sys
        for line in sys.stdin:
            request = json.loads(line)
            if request.get('id') == 1:
                print(json.dumps({'id': 1, 'result': {}}), flush=True)
            elif request.get('id') == 2:
                print(json.dumps({'id': 2, 'result': {'account': json.loads('\(account)')}}), flush=True)
        """
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)
        do { _ = try CodexClient.fetch(executable: fakeCLI); try expect(false, "Account handshake must reject unsupported auth") }
        catch let failure as ProviderFailure {
            try expect(failure == (account == "null" ? .authentication : .noData), "Signed-out Codex needs login; API-key auth has no subscription quota")
        }
    }
    print("PASS: \(count) quota, credit, date, and availability checks")
}
