import Foundation
import Testing
@testable import AIAccounts

// Every test here uses sandbox paths and an in-memory keychain; no real login is read or written.

private struct SwitchSandbox {
    let root: URL
    let paths: AIAccountPaths
    let keychain = InMemoryKeychain()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("menusprite-switch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = .sandbox(root: root, keychainPrefix: "test-")
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func switcher(usage: (any UsageFetching)? = nil) -> AccountSwitcher {
        AccountSwitcher(paths: paths, keychain: keychain, usage: usage, gate: CredentialGate())
    }

    func saved(_ provider: AIProvider, _ email: String) -> String { paths.savedService(provider, email: email) }

    func put(_ service: String, _ value: String, account: String? = nil) throws {
        try keychain.writePassword(service: service, account: account ?? paths.keychainAccount, value: value)
    }

    func read(_ service: String) -> String? { try? keychain.readPassword(service: service, account: nil) }

    func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func claudeAccount(_ email: String, active: Bool, profile: String? = nil) -> SwitcherAccount {
        SwitcherAccount(email: email, subscriptionType: "max", orgName: "\(email)'s Organization", active: active,
                        keychainAccount: paths.keychainAccount, oauthAccountJSON: profile, provider: .claude)
    }

    func codexAccount(_ email: String, active: Bool) -> SwitcherAccount {
        SwitcherAccount(email: email, subscriptionType: "pro", orgName: "", active: active, keychainAccount: email, provider: .codex)
    }
}

private func switchJWT(_ claims: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: claims)
    let body = data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "e30.\(body).sig"
}

private func claudeBlob(access: String, refresh: String, mcp: Bool = false) -> String {
    var object: [String: Any] = ["claudeAiOauth": [
        "accessToken": access, "refreshToken": refresh, "expiresAt": 4_000_000_000_000,
        "scopes": ["user:inference", "user:profile"], "subscriptionType": "max", "rateLimitTier": "default_claude_max_20x"
    ]]
    if mcp { object["mcpOAuth"] = ["github|abc": ["accessToken": "mcp-token", "expiresAt": 1]] }
    return CredentialJSON.text(from: object)!
}

private func profile(_ email: String) -> String {
    SwitcherJSON.compact([
        "accountUuid": UUID().uuidString, "emailAddress": email, "organizationUuid": UUID().uuidString,
        "organizationName": "\(email)'s Organization", "hasExtraUsageEnabled": false,
        "ccOnboardingFlags": [String: Any](), "seatTier": NSNull()
    ])!
}

private func codexBlob(email: String, refresh: String) -> String {
    let idToken = switchJWT(["email": email, "https://api.openai.com/auth": ["chatgpt_account_id": "acct-\(email)", "chatgpt_plan_type": "pro"]])
    let payload: [String: Any] = [
        "auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(), "last_refresh": "2026-09-01T00:00:00Z",
        "tokens": ["access_token": switchJWT(["exp": 4_000_000_000, "sub": email]), "refresh_token": refresh,
                   "id_token": idToken, "account_id": "acct-\(email)"]
    ]
    return CredentialJSON.text(from: payload, pretty: true)!
}

/// Claude Code's own layout: two-space JSON with nested objects, escapes and non-ASCII text.
private func claudeStateFile(profile json: String) -> String {
    let account = JSONTextScanner.render(CredentialJSON.object(from: json)!, indentUnit: 2, level: 1)
    return """
    {
      "numStartups": 412,
      "theme": "dark",
      "projects": {
        "/Users/example/Developer/MenuSprite": {
          "allowedTools": [],
          "lastCost": 1.25,
          "note": "naïve — 🎛️ and \\"quotes\\" and a } brace"
        }
      },
      "oauthAccount": \(account),
      "userID": "abc123",
      "tipsHistory": {
        "new-user-warmup": 7
      }
    }
    """
}

private actor RecordingUsage: UsageFetching {
    let keychain: InMemoryKeychain
    let paths: AIAccountPaths
    let result: Result<UsageSnapshot, UsageError>
    private(set) var calls: [String] = []

    init(keychain: InMemoryKeychain, paths: AIAccountPaths, result: Result<UsageSnapshot, UsageError>) {
        self.keychain = keychain; self.paths = paths; self.result = result
    }

    func activeUsage(_ provider: AIProvider, force: Bool) async -> Result<UsageSnapshot, UsageError> {
        calls.append("active:\(provider.rawValue)")
        return result
    }

    /// Simulates the usage service rotating an expiring saved token and writing it back.
    func savedUsage(_ provider: AIProvider, email: String, force: Bool) async -> Result<UsageSnapshot, UsageError> {
        calls.append("saved:\(provider.rawValue):\(email):\(force)")
        let service = paths.savedService(provider, email: email)
        if case .success = result, provider == .codex,
           let raw = try? keychain.readPassword(service: service, account: nil),
           let rotated = CodexCredential(json: raw)?.rotated(accessToken: switchJWT(["exp": 4_100_000_000]),
                                                             refreshToken: "rotated-refresh", idToken: nil) {
            try? keychain.writePassword(service: service, account: email, value: rotated.formatted(pretty: false))
        }
        return result
    }

    func invalidate(_ provider: AIProvider) async { calls.append("invalidate:\(provider.rawValue)") }
}

private let emptyUsage = UsageSnapshot(provider: .codex, accountEmail: nil, plan: nil, windows: [], fetchedAt: Date())

@Test func switchClaudeBacksUpSwapsAndRewritesOnlyTheProfile() async throws {
    let box = try SwitchSandbox(); defer { box.remove() }
    let profileA = profile("a@example.com"), profileB = profile("b@example.com")
    var config = SwitcherConfig()
    config.upsert(box.claudeAccount("a@example.com", active: true))
    config.upsert(box.claudeAccount("b@example.com", active: false, profile: profileB))
    config.upsert(box.codexAccount("c@example.com", active: true))
    try config.save(to: box.paths.switcherConfig)
    let savedA = claudeBlob(access: "a-old", refresh: "a-r1")
    let liveA = claudeBlob(access: "a-new", refresh: "a-r2", mcp: true) // rotated by Claude Code since it was saved
    let savedB = claudeBlob(access: "b", refresh: "b-r")
    try box.put(box.saved(.claude, "a@example.com"), savedA)
    try box.put(box.saved(.claude, "b@example.com"), savedB)
    try box.put(box.paths.claudeLiveService, liveA)
    let originalState = claudeStateFile(profile: profileA)
    try box.write(originalState, to: box.paths.claudeState)

    let outcome = try await box.switcher().switchAccount(.claude, to: "b@example.com")

    #expect(outcome.backedUpEmail == "a@example.com")
    #expect(!outcome.alreadyActive)
    let backup = try #require(box.read(box.saved(.claude, "a@example.com")))
    #expect(ClaudeCredential(json: backup)?.tokenFingerprint == ClaudeCredential(json: liveA)?.tokenFingerprint)
    #expect(CredentialJSON.object(from: backup)?["mcpOAuth"] != nil)

    let live = try #require(box.keychain.snapshot[box.paths.claudeLiveService])
    #expect(live.account == box.paths.keychainAccount)
    #expect(ClaudeCredential(json: live.value)?.tokenFingerprint == ClaudeCredential(json: savedB)?.tokenFingerprint)

    let newState = try #require(box.text(box.paths.claudeState))
    let oldBytes = Array(originalState.utf8), newBytes = Array(newState.utf8)
    let before = try #require(JSONTextScanner.topLevelValue(forKey: "oauthAccount", in: oldBytes))
    let after = try #require(JSONTextScanner.topLevelValue(forKey: "oauthAccount", in: newBytes))
    #expect(oldBytes[..<before.value.lowerBound] == newBytes[..<after.value.lowerBound])
    #expect(oldBytes[before.value.upperBound...] == newBytes[after.value.upperBound...])
    #expect(newState.contains("\n    \"emailAddress\": \"b@example.com\""))
    let stateObject = try #require(CredentialJSON.object(from: newState))
    #expect((stateObject["oauthAccount"] as? [String: Any])?["emailAddress"] as? String == "b@example.com")

    let updated = try box.switcher().loadConfig()
    #expect(updated.active(.claude)?.email == "b@example.com")
    #expect(updated.account(.claude, email: "a@example.com")?.active == false)
    #expect(updated.account(.claude, email: "a@example.com")?.oauthAccountJSON.flatMap(ClaudeState.email(inOAuthAccount:)) == "a@example.com")
    #expect(updated.active(.codex)?.email == "c@example.com")
}

@Test func switchClaudeRefusesWithoutTouchingAnything() async throws {
    let box = try SwitchSandbox(); defer { box.remove() }
    var config = SwitcherConfig()
    for (email, active) in [("a@example.com", true), ("b@example.com", false), ("d@example.com", false), ("e@example.com", false)] {
        config.upsert(box.claudeAccount(email, active: active, profile: profile(email)))
    }
    try config.save(to: box.paths.switcherConfig)
    let liveA = claudeBlob(access: "a", refresh: "a-r")
    try box.put(box.saved(.claude, "a@example.com"), liveA)
    try box.put(box.saved(.claude, "b@example.com"), claudeBlob(access: "b", refresh: "b-r"))
    try box.put(box.saved(.claude, "e@example.com"), "not a credential")
    try box.put(box.paths.claudeLiveService, liveA)
    try box.write(claudeStateFile(profile: profile("a@example.com")), to: box.paths.claudeState)
    let keychainBefore = box.keychain.snapshot
    let stateBefore = box.text(box.paths.claudeState)
    let configBefore = box.text(box.paths.switcherConfig)
    let switcher = box.switcher()

    await #expect(throws: SwitchingError.accountNotSaved(.claude, "zzz@example.com")) {
        try await switcher.switchAccount(.claude, to: "zzz@example.com")
    }
    await #expect(throws: SwitchingError.savedCredentialMissing(.claude, "d@example.com")) {
        try await switcher.switchAccount(.claude, to: "d@example.com")
    }
    await #expect(throws: SwitchingError.savedCredentialUnreadable(.claude, "e@example.com")) {
        try await switcher.switchAccount(.claude, to: "e@example.com")
    }
    await #expect(throws: SwitchingError.invalidEmail("not-an-email")) {
        try await switcher.switchAccount(.claude, to: "not-an-email")
    }
    #expect(box.keychain.snapshot == keychainBefore)
    #expect(box.text(box.paths.claudeState) == stateBefore)
    #expect(box.text(box.paths.switcherConfig) == configBefore)
}

@Test func switchClaudeRestoresTheLiveLoginWhenTheProfileStepFails() async throws {
    let box = try SwitchSandbox(); defer { box.remove() }
    var config = SwitcherConfig()
    config.upsert(box.claudeAccount("a@example.com", active: true))
    config.upsert(box.claudeAccount("b@example.com", active: false, profile: profile("b@example.com")))
    try config.save(to: box.paths.switcherConfig)
    let liveA = claudeBlob(access: "a", refresh: "a-r", mcp: true)
    try box.put(box.saved(.claude, "a@example.com"), liveA)
    try box.put(box.saved(.claude, "b@example.com"), claudeBlob(access: "b", refresh: "b-r"))
    try box.put(box.paths.claudeLiveService, liveA)
    // A directory where the state file belongs makes the profile step throw after the live item changed.
    try FileManager.default.createDirectory(at: box.paths.claudeState, withIntermediateDirectories: true)

    do {
        _ = try await box.switcher().switchAccount(.claude, to: "b@example.com")
        Issue.record("The switch should have failed")
    } catch let error as SwitchingError {
        guard case .restoredAfterFailure = error else { Issue.record("Unexpected error: \(error)"); return }
    }
    #expect(box.keychain.snapshot[box.paths.claudeLiveService]?.value == liveA)
    #expect(try box.switcher().loadConfig().active(.claude)?.email == "a@example.com")
}

@Test func switchClaudeToTheLiveAccountOnlyRefreshesItsSavedCopy() async throws {
    let box = try SwitchSandbox(); defer { box.remove() }
    var config = SwitcherConfig()
    config.upsert(box.claudeAccount("a@example.com", active: false))
    config.upsert(box.claudeAccount("b@example.com", active: true))
    try config.save(to: box.paths.switcherConfig)
    let rotated = claudeBlob(access: "a-new", refresh: "a-r2")
    try box.put(box.saved(.claude, "a@example.com"), claudeBlob(access: "a-old", refresh: "a-r1"))
    try box.put(box.paths.claudeLiveService, rotated)
    let state = claudeStateFile(profile: profile("a@example.com"))
    try box.write(state, to: box.paths.claudeState)

    let outcome = try await box.switcher().switchAccount(.claude, to: "a@example.com")

    #expect(outcome.alreadyActive)
    #expect(box.keychain.snapshot[box.paths.claudeLiveService]?.value == rotated)
    #expect(ClaudeCredential(json: box.read(box.saved(.claude, "a@example.com")) ?? "")?.tokenFingerprint == ClaudeCredential(json: rotated)?.tokenFingerprint)
    #expect(box.text(box.paths.claudeState) == state)
    #expect(try box.switcher().loadConfig().active(.claude)?.email == "a@example.com")
}

@Test func switchClaudeSavesAnUnsavedLiveLoginFirst() async throws {
    let box = try SwitchSandbox(); defer { box.remove() }
    var config = SwitcherConfig()
    config.upsert(box.claudeAccount("a@example.com", active: true))
    config.upsert(box.claudeAccount("b@example.com", active: false, profile: profile("b@example.com")))
    try config.save(to: box.paths.switcherConfig)
    let liveC = claudeBlob(access: "c", refresh: "c-r")
    try box.put(box.saved(.claude, "a@example.com"), claudeBlob(access: "a", refresh: "a-r"))
    try box.put(box.saved(.claude, "b@example.com"), claudeBlob(access: "b", refresh: "b-r"))
    try box.put(box.paths.claudeLiveService, liveC)
    try box.write(claudeStateFile(profile: profile("c@example.com")), to: box.paths.claudeState)

    let outcome = try await box.switcher().switchAccount(.claude, to: "b@example.com")

    #expect(outcome.backedUpEmail == "c@example.com")
    #expect(outcome.notes.contains { $0.contains("c@example.com") })
    #expect(box.read(box.saved(.claude, "c@example.com")).flatMap { ClaudeCredential(json: $0) }?.tokenFingerprint
            == ClaudeCredential(json: liveC)?.tokenFingerprint)
    #expect(box.read(box.saved(.claude, "a@example.com")).flatMap { ClaudeCredential(json: $0) }?.accessToken == "a")
    let updated = try box.switcher().loadConfig()
    #expect(updated.account(.claude, email: "c@example.com")?.active == false)
    #expect(updated.account(.claude, email: "c@example.com")?.oauthAccountJSON.flatMap(ClaudeState.email(inOAuthAccount:)) == "c@example.com")
    #expect(updated.active(.claude)?.email == "b@example.com")
}

@Test func switchCodexWritesTheRefreshedSavedCopyPrivately() async throws {
    let box = try SwitchSandbox(); defer { box.remove() }
    var config = SwitcherConfig()
    config.upsert(box.codexAccount("d@example.com", active: true))
    config.upsert(box.codexAccount("e@example.com", active: false))
    config.upsert(box.claudeAccount("a@example.com", active: true))
    try config.save(to: box.paths.switcherConfig)
    let liveD = codexBlob(email: "d@example.com", refresh: "d-r")
    try box.write(liveD, to: box.paths.codexAuth)
    try box.put(box.saved(.codex, "e@example.com"), CodexCredential(json: codexBlob(email: "e@example.com", refresh: "e-r1"))!.formatted(pretty: false),
                account: "e@example.com")
    let usage = RecordingUsage(keychain: box.keychain, paths: box.paths, result: .success(emptyUsage))

    let outcome = try await box.switcher(usage: usage).switchAccount(.codex, to: "e@example.com")

    #expect(outcome.backedUpEmail == "d@example.com")
    let auth = try #require(box.text(box.paths.codexAuth))
    #expect(CodexCredential(json: auth)?.email == "e@example.com")
    #expect(CodexCredential(json: auth)?.refreshToken == "rotated-refresh")
    #expect(auth.contains("\n"))
    #expect(try FileManager.default.attributesOfItem(atPath: box.paths.codexAuth.path)[.posixPermissions] as? Int == 0o600)
    #expect(box.read(box.saved(.codex, "d@example.com")).flatMap { CodexCredential(json: $0) }?.tokenFingerprint
            == CodexCredential(json: liveD)?.tokenFingerprint)
    #expect(box.keychain.snapshot[box.saved(.codex, "d@example.com")]?.account == "d@example.com")
    #expect(await usage.calls == ["saved:codex:e@example.com:true"])
    let updated = try box.switcher().loadConfig()
    #expect(updated.active(.codex)?.email == "e@example.com")
    #expect(updated.account(.codex, email: "d@example.com")?.active == false)
    #expect(updated.active(.claude)?.email == "a@example.com")
}

@Test func switchCodexRefusesAnExpiredSavedSession() async throws {
    let box = try SwitchSandbox(); defer { box.remove() }
    var config = SwitcherConfig()
    config.upsert(box.codexAccount("d@example.com", active: true))
    config.upsert(box.codexAccount("e@example.com", active: false))
    try config.save(to: box.paths.switcherConfig)
    let liveD = codexBlob(email: "d@example.com", refresh: "d-r")
    try box.write(liveD, to: box.paths.codexAuth)
    try box.put(box.saved(.codex, "e@example.com"), codexBlob(email: "e@example.com", refresh: "e-r"), account: "e@example.com")
    let usage = RecordingUsage(keychain: box.keychain, paths: box.paths, result: .failure(.sessionExpired))

    await #expect(throws: SwitchingError.codexSessionExpired("e@example.com")) {
        try await box.switcher(usage: usage).switchAccount(.codex, to: "e@example.com")
    }
    #expect(box.text(box.paths.codexAuth) == liveD)
    #expect(box.read(box.saved(.codex, "d@example.com")) == nil)
}

@Test func switchCodexKeyringModeRefusesSwitchingAndSaving() async throws {
    let box = try SwitchSandbox(); defer { box.remove() }
    let configURL = box.paths.codexAuth.deletingLastPathComponent().appendingPathComponent("config.toml")
    try box.write("model = \"gpt-5\"\ncli_auth_credentials_store = \"keyring\" # set by login\n[profiles.work]\ncli_auth_credentials_store = \"file\"\n", to: configURL)
    let switcher = box.switcher()
    #expect(switcher.codexUsesKeyring())
    await #expect(throws: SwitchingError.codexKeyringMode) { try await switcher.switchAccount(.codex, to: "e@example.com") }
    await #expect(throws: SwitchingError.codexKeyringMode) { try await switcher.saveCurrentLogin(.codex) }
    try box.write("[profiles.work]\ncli_auth_credentials_store = \"keyring\"\n", to: configURL)
    #expect(!switcher.codexUsesKeyring())
}

@Test func switchSaveCurrentLoginImportsClaudeAndCodex() async throws {
    let box = try SwitchSandbox(); defer { box.remove() }
    let liveClaude = claudeBlob(access: "f", refresh: "f-r", mcp: true)
    try box.put(box.paths.claudeLiveService, liveClaude)
    try box.write(claudeStateFile(profile: profile("f@example.com")), to: box.paths.claudeState)
    try box.write(codexBlob(email: "g@example.com", refresh: "g-r"), to: box.paths.codexAuth)
    let switcher = box.switcher()

    let claude = try await switcher.saveCurrentLogin(.claude)
    #expect(claude.email == "f@example.com")
    #expect(claude.orgName == "f@example.com's Organization")
    #expect(claude.subscriptionType == "max")
    #expect(claude.active)
    #expect(claude.keychainAccount == box.paths.keychainAccount)
    #expect(claude.oauthAccountJSON.flatMap(ClaudeState.email(inOAuthAccount:)) == "f@example.com")
    #expect(CredentialJSON.object(from: box.read(box.saved(.claude, "f@example.com")) ?? "")?["mcpOAuth"] != nil)

    let codex = try await switcher.saveCurrentLogin(.codex)
    #expect(codex.email == "g@example.com")
    #expect(codex.keychainAccount == "g@example.com")
    #expect(codex.subscriptionType == "pro")
    #expect(box.keychain.snapshot[box.saved(.codex, "g@example.com")]?.account == "g@example.com")

    #expect(try FileManager.default.attributesOfItem(atPath: box.paths.switcherConfig.path)[.posixPermissions] as? Int == 0o600)
    let overview = switcher.overview()
    #expect(overview.isLiveLoginSaved(.claude))
    #expect(overview.isLiveLoginSaved(.codex))
    #expect(overview.liveEmail(.claude) == "f@example.com")
    #expect(overview.activeEmail(.codex) == "g@example.com")
    #expect(overview.problems.isEmpty)
}

@Test func switchRemoveRefusesTheSignedInAccountAndDeletesSavedOnes() async throws {
    let box = try SwitchSandbox(); defer { box.remove() }
    var config = SwitcherConfig()
    config.upsert(box.claudeAccount("a@example.com", active: true))
    config.upsert(box.claudeAccount("b@example.com", active: false))
    try config.save(to: box.paths.switcherConfig)
    let liveA = claudeBlob(access: "a", refresh: "a-r")
    try box.put(box.saved(.claude, "a@example.com"), liveA)
    try box.put(box.saved(.claude, "b@example.com"), claudeBlob(access: "b", refresh: "b-r"))
    try box.put(box.paths.claudeLiveService, liveA)
    let switcher = box.switcher()

    await #expect(throws: SwitchingError.activeAccountRemoval(.claude, "a@example.com")) {
        try await switcher.removeAccount(.claude, email: "a@example.com")
    }
    try await switcher.removeAccount(.claude, email: "b@example.com")
    #expect(box.read(box.saved(.claude, "b@example.com")) == nil)
    #expect(box.read(box.saved(.claude, "a@example.com")) == liveA)
    #expect(try switcher.loadConfig().account(.claude, email: "b@example.com") == nil)
    await #expect(throws: SwitchingError.accountNotSaved(.claude, "b@example.com")) {
        try await switcher.removeAccount(.claude, email: "b@example.com")
    }
}

@Test func switchOverviewPrefersIdenticalTokensOverAStaleProfile() async throws {
    let box = try SwitchSandbox(); defer { box.remove() }
    var config = SwitcherConfig()
    config.upsert(box.claudeAccount("a@example.com", active: true))
    config.upsert(box.claudeAccount("b@example.com", active: false))
    config.autoSwitch["claude"] = true
    try config.save(to: box.paths.switcherConfig)
    let savedB = claudeBlob(access: "b", refresh: "b-r")
    try box.put(box.saved(.claude, "b@example.com"), savedB)
    try box.put(box.paths.claudeLiveService, savedB)
    try box.write(claudeStateFile(profile: profile("a@example.com")), to: box.paths.claudeState)
    let switcher = box.switcher()

    let overview = switcher.overview()
    #expect(overview.liveEmail(.claude) == "b@example.com")
    #expect(overview.savedCredentials == ["claude:b@example.com"])
    #expect(overview.live[.codex] == nil)

    try await switcher.setAutoSwitch(.codex, enabled: true)
    let settings = try switcher.loadConfig()
    #expect(settings.isAutoSwitchEnabled(.codex))
    #expect(settings.isAutoSwitchEnabled(.claude))
}

@Test func switchStateWriterHandlesCompactMissingAndBrokenFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("menusprite-state-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let newProfile = #"{"emailAddress":"y@example.com","organizationName":"Y"}"#

    let compact = root.appendingPathComponent("compact.json")
    try Data(#"{"a":1,"oauthAccount":{"emailAddress":"x@example.com"},"z":[1,2]}"#.utf8).write(to: compact)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: compact.path)
    #expect(try ClaudeStateWriter.replaceOAuthAccount(with: newProfile, at: compact) == .replaced)
    let compactText = try String(contentsOf: compact, encoding: .utf8)
    #expect(compactText == #"{"a":1,"oauthAccount":{"emailAddress":"y@example.com","organizationName":"Y"},"z":[1,2]}"#)
    #expect(try FileManager.default.attributesOfItem(atPath: compact.path)[.posixPermissions] as? Int == 0o644)

    let missing = root.appendingPathComponent("missing.json")
    #expect(try ClaudeStateWriter.replaceOAuthAccount(with: newProfile, at: missing) == .fileMissing)
    #expect(!FileManager.default.fileExists(atPath: missing.path))

    let broken = root.appendingPathComponent("broken.json")
    try Data("{not json".utf8).write(to: broken)
    #expect(try ClaudeStateWriter.replaceOAuthAccount(with: newProfile, at: broken) == .unparsable)
    #expect(try String(contentsOf: broken, encoding: .utf8) == "{not json")

    let signedOut = root.appendingPathComponent("signed-out.json")
    try Data("{\n  \"theme\": \"dark\"\n}".utf8).write(to: signedOut)
    #expect(try ClaudeStateWriter.replaceOAuthAccount(with: newProfile, at: signedOut) == .replaced)
    let object = try #require(CredentialJSON.object(from: try String(contentsOf: signedOut, encoding: .utf8)))
    #expect(object["theme"] as? String == "dark")
    #expect((object["oauthAccount"] as? [String: Any])?["emailAddress"] as? String == "y@example.com")
}
