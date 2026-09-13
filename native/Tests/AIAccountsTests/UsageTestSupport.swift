import Foundation
@testable import AIAccounts

/// Records every request and answers from a handler given the request and its zero-based index.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest, Int) throws -> HTTPResponse
    private let lock = NSLock()
    private let handler: Handler
    private let delay: Duration
    private var recorded: [HTTPRequest] = []

    init(delay: Duration = .zero, _ handler: @escaping Handler) {
        self.delay = delay
        self.handler = handler
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let index = lock.withLock { () -> Int in
            recorded.append(request)
            return recorded.count - 1
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        return try handler(request, index)
    }

    var requests: [HTTPRequest] { lock.withLock { recorded } }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = UsageFixtures.now) { current = start }

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

struct OfflineError: Error {}

/// Isolated paths, an in-memory keychain and a controllable clock; never touches a real login.
struct UsageSandbox {
    let root: URL
    let paths: AIAccountPaths
    let keychain = InMemoryKeychain()
    let clock = TestClock()

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("menusprite-usage-\(UUID().uuidString)")
        paths = .sandbox(root: root, keychainPrefix: "test-")
    }

    func service(_ http: FakeTransport) -> UsageService {
        let clock = self.clock
        return UsageService(paths: paths, keychain: keychain, http: http, now: { clock.now })
    }

    func setClaudeState(email: String) throws {
        let object: [String: Any] = ["numStartups": 3, "oauthAccount": ["emailAddress": email, "accountUuid": "u-1"] as [String: Any]]
        try AtomicFile.write(JSONSerialization.data(withJSONObject: object), to: paths.claudeState, permissions: 0o644)
    }

    func setLiveClaude(_ json: String) throws {
        try keychain.writePassword(service: paths.claudeLiveService, account: paths.keychainAccount, value: json)
    }

    func liveClaude() -> ClaudeCredential? {
        (try? keychain.readPassword(service: paths.claudeLiveService, account: nil)).flatMap { ClaudeCredential(json: $0) }
    }

    func setCodexAuth(_ json: String) throws {
        try AtomicFile.write(Data(json.utf8), to: paths.codexAuth, permissions: 0o600)
    }

    func codexAuth() throws -> CodexCredential? {
        CodexCredential(json: try String(contentsOf: paths.codexAuth, encoding: .utf8))
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

enum UsageFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func claudeCredential(access: String = "access-1", refresh: String? = "refresh-1", expiresIn: TimeInterval = 8 * 3600,
                                 from start: Date = now, scopes: [String] = ["user:inference", "user:profile"]) -> String {
        var oauth: [String: Any] = [
            "accessToken": access, "expiresAt": Int64((start.timeIntervalSince1970 + expiresIn) * 1000), "scopes": scopes,
            "subscriptionType": "max", "rateLimitTier": "default_claude_max_20x", "refreshTokenExpiresAt": 1_900_000_000_000 as Int64
        ]
        if let refresh { oauth["refreshToken"] = refresh }
        let object: [String: Any] = ["claudeAiOauth": oauth, "mcpOAuth": ["github|abc": ["accessToken": "mcp-keep"]]]
        return CredentialJSON.text(from: object)!
    }

    static func jwt(_ claims: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: claims)
        let body = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "e30.\(body).signature"
    }

    static func codexAuth(accessExpiry: TimeInterval, accessTag: String = "a1", refresh: String = "r1",
                          email: String = "dev@example.com", accountID: String = "acct-1") -> String {
        let idToken = jwt(["email": email, "https://api.openai.com/auth": ["chatgpt_account_id": accountID, "chatgpt_plan_type": "pro"]])
        let tokens: [String: Any] = ["access_token": jwt(["exp": accessExpiry, "tag": accessTag]), "refresh_token": refresh,
                                     "id_token": idToken, "account_id": accountID]
        let object: [String: Any] = ["auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(), "last_refresh": "2027-01-15T00:00:00Z", "tokens": tokens]
        return CredentialJSON.text(from: object)!
    }

    /// Shaped like a live `api/oauth/usage` response, including nulls OpenUsage tolerates.
    static func claudeUsageBody() -> [String: Any] {
        [
            "five_hour": ["utilization": 9.0, "resets_at": "2026-09-11T08:40:00.666Z"] as [String: Any],
            "seven_day": ["utilization": 77, "resets_at": "2026-09-11T08:00:00.123456+00:00"] as [String: Any],
            "seven_day_sonnet": ["utilization": NSNull(), "resets_at": NSNull()] as [String: Any],
            "seven_day_opus": NSNull(),
            "limits": [
                ["kind": "weekly_scoped", "scope": ["model": ["display_name": "Opus"]], "percent": 5] as [String: Any],
                ["kind": "weekly_scoped", "scope": ["model": ["display_name": "Fable"]], "percent": 100, "resets_at": 1_789_000_000] as [String: Any]
            ] as [Any],
            "extra_usage": ["is_enabled": true, "monthly_limit": 5000, "used_credits": 1234, "utilization": 24.68] as [String: Any]
        ]
    }

    /// Shaped like a live `wham/usage` response.
    static func codexUsageBody(primary: [String: Any]?, secondary: [String: Any]?, plan: String = "pro") -> [String: Any] {
        let rateLimit: [String: Any] = ["allowed": true, "limit_reached": false,
                                        "primary_window": primary ?? NSNull(), "secondary_window": secondary ?? NSNull()]
        let spark: [String: Any] = [
            "limit_name": "GPT-5.3-Codex-Spark", "metered_feature": "codex_bengalfox",
            "rate_limit": ["primary_window": ["used_percent": 3, "limit_window_seconds": 18_000, "reset_at": 1_800_018_000] as [String: Any],
                           "secondary_window": NSNull()] as [String: Any]
        ]
        return ["plan_type": plan, "rate_limit": rateLimit,
                "credits": ["has_credits": true, "unlimited": false, "balance": "821.5"] as [String: Any],
                "additional_rate_limits": [spark] as [Any]]
    }

    static func standardCodexBody() -> [String: Any] {
        codexUsageBody(primary: ["used_percent": 12, "limit_window_seconds": 18_000, "reset_at": 1_800_010_000] as [String: Any],
                       secondary: ["used_percent": 47, "limit_window_seconds": 604_800, "reset_after_seconds": 3_600] as [String: Any])
    }

    static func response(_ status: Int, _ body: Any = [String: Any](), headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: headers, body: try! JSONSerialization.data(withJSONObject: body))
    }

    static func tokenGrant(_ access: String, refresh: String? = nil, expiresIn: Int? = nil) -> HTTPResponse {
        var body: [String: Any] = ["access_token": access]
        if let refresh { body["refresh_token"] = refresh }
        if let expiresIn { body["expires_in"] = expiresIn }
        return response(200, body)
    }
}
