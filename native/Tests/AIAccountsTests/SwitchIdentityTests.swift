import Foundation
import Testing
@testable import AIAccounts

// Claude Code can leave a previous account's `oauthAccount` in ~/.claude.json. Once it has rotated its
// tokens no saved copy matches the live login, so only Anthropic's profile endpoint can say whose it is.

private func identityBlob(_ access: String) -> String {
    let oauth: [String: Any] = ["accessToken": access, "refreshToken": "r-\(access)", "expiresAt": 4_000_000_000_000,
                                "scopes": ["user:inference", "user:profile"], "subscriptionType": "max"]
    return CredentialJSON.text(from: ["claudeAiOauth": oauth])!
}

private func identityProfile(_ email: String) -> String {
    CredentialJSON.text(from: ["accountUuid": "uuid-\(email)", "emailAddress": email, "organizationName": "\(email)'s Organization"])!
}

private actor ExpiredUsage: UsageFetching {
    private(set) var forcedActive = 0
    func activeUsage(_ provider: AIProvider, force: Bool) async -> Result<UsageSnapshot, UsageError> {
        if force { forcedActive += 1 }
        return .failure(.sessionExpired)
    }
    func savedUsage(_ provider: AIProvider, email: String, force: Bool) async -> Result<UsageSnapshot, UsageError> { .failure(.notLoggedIn) }
    func invalidate(_ provider: AIProvider) async {}
}

private struct IdentitySandbox {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("menusprite-identity-\(UUID().uuidString)")
    let keychain = InMemoryKeychain()
    var paths: AIAccountPaths { .sandbox(root: root, keychainPrefix: "test-") }
    var savedA: String { paths.savedService(.claude, email: "a@example.com") }
    var savedB: String { paths.savedService(.claude, email: "b@example.com") }

    /// a@ is signed in with tokens rotated since it was saved; b@ is saved; the state file still names b@.
    func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var config = SwitcherConfig()
        for (email, active) in [("a@example.com", true), ("b@example.com", false)] {
            config.upsert(SwitcherAccount(email: email, subscriptionType: "max", orgName: "", active: active,
                                          keychainAccount: paths.keychainAccount, oauthAccountJSON: identityProfile(email), provider: .claude))
        }
        try config.save(to: paths.switcherConfig)
        try keychain.writePassword(service: savedA, account: paths.keychainAccount, value: identityBlob("a-old"))
        try keychain.writePassword(service: savedB, account: paths.keychainAccount, value: identityBlob("b"))
        try keychain.writePassword(service: paths.claudeLiveService, account: paths.keychainAccount, value: identityBlob("a-rotated"))
        let state: [String: Any] = ["numStartups": 3, "oauthAccount": CredentialJSON.object(from: identityProfile("b@example.com"))!]
        try AtomicFile.write(JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted]), to: paths.claudeState, permissions: 0o644)
    }

    func access(_ service: String) -> String? {
        (try? keychain.readPassword(service: service, account: nil)).flatMap(ClaudeCredential.init(json:))?.accessToken
    }

    func profileServer(_ answer: @escaping @Sendable () throws -> HTTPResponse) -> FakeTransport {
        FakeTransport { request, _ in
            #expect(request.url.absoluteString == "https://api.anthropic.com/api/oauth/profile")
            return try answer()
        }
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Test func switchFilesTheLiveLoginUnderTheAccountAnthropicConfirms() async throws {
    let box = IdentitySandbox(); defer { box.cleanup() }
    try box.prepare()
    let http = box.profileServer { UsageFixtures.response(200, ["account": ["email": "a@example.com", "uuid": "uuid-a"]]) }
    let switcher = AccountSwitcher(paths: box.paths, keychain: box.keychain, http: http, gate: CredentialGate())
    // Trusting the stale state file would call b@ already signed in and overwrite its saved login with a@'s tokens.
    let outcome = try await switcher.switchAccount(.claude, to: "b@example.com")
    #expect(!outcome.alreadyActive)
    #expect(outcome.backedUpEmail == "a@example.com")
    #expect(box.access(box.savedA) == "a-rotated")
    #expect(box.access(box.savedB) == "b")
    #expect(box.access(box.paths.claudeLiveService) == "b")
    #expect(http.requests.first?.headers["Authorization"] == "Bearer a-rotated")
    #expect(outcome.notes.contains { $0.contains("Anthropic confirmed") })
}

@Test func saveCurrentLoginUsesTheConfirmedAccount() async throws {
    let box = IdentitySandbox(); defer { box.cleanup() }
    try box.prepare()
    let http = box.profileServer { UsageFixtures.response(200, ["account": ["email": "a@example.com"]]) }
    let account = try await AccountSwitcher(paths: box.paths, keychain: box.keychain, http: http, gate: CredentialGate())
        .saveCurrentLogin(.claude)
    #expect(account.email == "a@example.com")
    #expect(account.oauthAccountJSON.flatMap(ClaudeState.email(inOAuthAccount:)) == "a@example.com")
    #expect(box.access(box.savedA) == "a-rotated")
    #expect(box.access(box.savedB) == "b")
}

@Test func unconfirmedIdentityChangesNothing() async throws {
    let box = IdentitySandbox(); defer { box.cleanup() }
    try box.prepare()
    let http = box.profileServer { throw OfflineError() }
    let switcher = AccountSwitcher(paths: box.paths, keychain: box.keychain, http: http, gate: CredentialGate())
    await #expect(throws: SwitchingError.self) { try await switcher.switchAccount(.claude, to: "b@example.com") }
    await #expect(throws: SwitchingError.self) { try await switcher.saveCurrentLogin(.claude) }
    #expect(box.access(box.paths.claudeLiveService) == "a-rotated")
    #expect(box.access(box.savedA) == "a-old")
    #expect(box.access(box.savedB) == "b")
}

@Test func expiredLiveLoginIsNotSavedButTheSwitchProceeds() async throws {
    let box = IdentitySandbox(); defer { box.cleanup() }
    try box.prepare()
    let usage = ExpiredUsage()
    let http = box.profileServer { UsageFixtures.response(401, ["error": "unauthorized"]) }
    let switcher = AccountSwitcher(paths: box.paths, keychain: box.keychain, usage: usage, http: http, gate: CredentialGate())
    let outcome = try await switcher.switchAccount(.claude, to: "b@example.com")
    #expect(outcome.backedUpEmail == nil)
    #expect(box.access(box.savedA) == "a-old")
    #expect(box.access(box.paths.claudeLiveService) == "b")
    #expect(await usage.forcedActive == 1)
}
