import Foundation
import Security
import CryptoKit
import LocalAuthentication

enum ClaudeClient {
    // The legacy Keychain interaction switch is process-wide. Every app Keychain read
    // (including the explicit Allow action) must hold this lock while using it.
    private static let keychainReadLock = NSLock()

    struct Credentials: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let expiresAt: Double?
        }
        let claudeAiOauth: OAuth?

        static func token(from data: Data, now: Date = Date()) throws -> String {
            guard let credentials = try? JSONDecoder().decode(Self.self, from: data),
                  let oauth = credentials.claudeAiOauth, !oauth.accessToken.isEmpty,
                  oauth.expiresAt.map({ $0 / 1000 > now.timeIntervalSince1970 }) ?? true else {
                throw ProviderFailure.authentication
            }
            return oauth.accessToken
        }
    }

    static func accessToken(allowKeychainPrompt: Bool) throws -> String {
        let env = ProcessInfo.processInfo.environment
        if let token = env["CLAUDE_CODE_OAUTH_TOKEN"], !token.isEmpty { return token }
        let configured = env["CLAUDE_CONFIG_DIR"]
        let directory = configured ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        var service = "Claude Code-credentials"
        if configured != nil {
            let hash = SHA256.hash(data: Data(directory.utf8)).map { String(format: "%02x", $0) }.joined()
            service += "-" + hash.prefix(8)
        }
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: NSUserName(), kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne
        ]
        let context = LAContext()
        context.interactionNotAllowed = !allowKeychainPrompt
        query[kSecUseAuthenticationContext] = context
        var result: CFTypeRef?
        let status = readKeychain(query as CFDictionary, allowPrompt: allowKeychainPrompt, result: &result)
        if status == errSecSuccess, let data = result as? Data {
            return try Credentials.token(from: data)
        }
        // Same fallback file as Claude Code. Read in memory only; never copy or log credentials.
        let file = URL(fileURLWithPath: directory).appendingPathComponent(".credentials.json")
        if let data = try? Data(contentsOf: file) { return try Credentials.token(from: data) }
        if status != errSecItemNotFound { throw ProviderFailure.keychainLocked }
        throw ProviderFailure.authentication
    }

    private static func readKeychain(_ query: CFDictionary, allowPrompt: Bool, result: inout CFTypeRef?) -> OSStatus {
        keychainReadLock.lock()
        defer { keychainReadLock.unlock() }
        if allowPrompt { return SecItemCopyMatching(query, &result) }

        // LAContext gates Data Protection authentication, but not legacy login-keychain
        // ACL dialogs. Keep the legacy API here until that store has a replacement.
        var previous: DarwinBoolean = false
        let readStatus = SecKeychainGetUserInteractionAllowed(&previous)
        guard readStatus == errSecSuccess else { return readStatus }
        let setStatus = SecKeychainSetUserInteractionAllowed(false)
        guard setStatus == errSecSuccess else { return setStatus }
        defer { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return SecItemCopyMatching(query, &result)
    }

    static func fetch(allowKeychainPrompt: Bool = false) async throws -> QuotaSnapshot {
        let executable = try CLIPaths.executable(for: .claude)
        let token = try accessToken(allowKeychainPrompt: allowKeychainPrompt)
        let inventoryAgent = await inventoryUserAgent(executable: executable)
        let usageURL = "https://api.anthropic.com/api/oauth/usage"
        var request = URLRequest(url: URL(string: usageURL + (inventoryAgent == nil ? "" : "?cedar_ember=1"))!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(inventoryAgent ?? "AiQuotaBar/2.0", forHTTPHeaderField: "User-Agent")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 25
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            var (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, inventoryAgent != nil,
               http.statusCode == 400 || (http.statusCode == 403 &&
                   !(String(data: data, encoding: .utf8)?.contains("user:profile") ?? false)) {
                // Optional inventory rejection must not hide ordinary usage. Retry only once.
                try Task.checkCancellation()
                request.url = URL(string: usageURL)
                request.setValue("AiQuotaBar/2.0", forHTTPHeaderField: "User-Agent")
                (data, response) = try await session.data(for: request)
            }
            guard let response = response as? HTTPURLResponse else { throw ProviderFailure.connection }
            switch response.statusCode {
            case 200: return try ClaudeUsage.decode(data)
            case 401, 403: throw ProviderFailure.authentication
            case 429: throw ProviderFailure.rateLimited
            default: throw ProviderFailure.connection
            }
        } catch let error as URLError where error.code == .timedOut { throw ProviderFailure.timeout }
    }

    private static func inventoryUserAgent(executable: URL) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            guard let data = try? SessionCommand.run(executable.path, ["--version"], timeout: 2, outputLimit: 1024),
                  let output = String(data: data, encoding: .utf8),
                  let version = output.split(whereSeparator: \.isWhitespace).first,
                  version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else { return nil }
            // Match the installed CLI's observed inventory surface; do not invent a version.
            return "claude-cli/\(version) (external, cli)"
        }.value
    }
}

// Do not forward a user's bearer token to a redirected destination.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum ProviderClient {
    static func fetch(_ provider: Provider, allowKeychainPrompt: Bool = false) async -> Result<QuotaSnapshot, ProviderFailure> {
        do {
            let value: QuotaSnapshot
            switch provider {
            case .codex: value = try CodexClient.fetch()
            case .claude: value = try await ClaudeClient.fetch(allowKeychainPrompt: allowKeychainPrompt)
            }
            return .success(value)
        } catch { return .failure((error as? ProviderFailure) ?? .connection) }
    }
}
