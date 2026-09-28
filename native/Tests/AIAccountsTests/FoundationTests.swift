import Foundation
import Security
import Testing
@testable import AIAccounts

func fakeJWT(_ claims: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: claims)
    let body = data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "e30.\(body).signature"
}

@Test func keychainHexOutputParses() {
    let json = #"{"claudeAiOauth":{"accessToken":"a"}}"#
    #expect(CredentialJSON.object(from: CredentialJSON.hex(json))?["claudeAiOauth"] != nil)
    #expect(CredentialJSON.object(from: "not json") == nil)
    #expect(CredentialJSON.object(from: "abc") == nil)
}

@Test func claudeRotationPreservesUnmodelledKeys() throws {
    let json = #"{"claudeAiOauth":{"accessToken":"old","refreshToken":"r1","expiresAt":1000,"scopes":["user:inference","user:profile"],"subscriptionType":"max","rateLimitTier":"default_claude_max_20x","refreshTokenExpiresAt":99},"mcpOAuth":{"server":{"token":"keep"}}}"#
    let credential = try #require(ClaudeCredential(json: json))
    #expect(credential.canReadUsage)
    #expect(credential.subscriptionType == "max")
    #expect(credential.expires(within: 300, now: Date(timeIntervalSince1970: 1)))
    let rotated = try #require(credential.rotated(accessToken: "new", refreshToken: "r2", expiresInSeconds: 3600,
                                                  now: Date(timeIntervalSince1970: 1_000)))
    #expect(rotated.accessToken == "new")
    #expect(rotated.refreshToken == "r2")
    #expect(rotated.expiresAtMilliseconds == 4_600_000)
    let object = try #require(CredentialJSON.object(from: rotated.rawJSON))
    let mcp = object["mcpOAuth"] as? [String: Any]
    #expect((mcp?["server"] as? [String: Any])?["token"] as? String == "keep")
    #expect((object["claudeAiOauth"] as? [String: Any])?["refreshTokenExpiresAt"] as? Int == 99)
    #expect(rotated.tokenFingerprint != credential.tokenFingerprint)
    #expect(ClaudeCredential(json: #"{"claudeAiOauth":{"accessToken":"t","scopes":["user:inference"]}}"#)?.canReadUsage == false)
    #expect(ClaudeCredential(json: #"{"claudeAiOauth":{"accessToken":""}}"#) == nil)
}

@Test func codexIdentityAndRotation() throws {
    let idToken = fakeJWT(["email": "dev@example.com",
                           "https://api.openai.com/auth": ["chatgpt_account_id": "acct-1", "chatgpt_plan_type": "pro"]])
    let payload: [String: Any] = [
        "auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(), "last_refresh": "2026-09-01T00:00:00Z",
        "tokens": ["access_token": fakeJWT(["exp": 2_000]), "refresh_token": "r1", "id_token": idToken]
    ]
    let text = try #require(CredentialJSON.text(from: payload))
    let credential = try #require(CodexCredential(json: text))
    #expect(credential.email == "dev@example.com")
    #expect(credential.accountID == "acct-1")
    #expect(credential.plan == "pro")
    #expect(credential.expires(within: 300, now: Date(timeIntervalSince1970: 1_800)))
    #expect(!credential.expires(within: 300, now: Date(timeIntervalSince1970: 1_000)))
    let rotated = try #require(credential.rotated(accessToken: fakeJWT(["exp": 9_000]), refreshToken: "r2", idToken: nil,
                                                  now: Date(timeIntervalSince1970: 1_000)))
    #expect(rotated.refreshToken == "r2")
    #expect(rotated.idToken == idToken)
    #expect(rotated.accountID == "acct-1")
    #expect(rotated.lastRefresh == Date(timeIntervalSince1970: 1_000))
    let object = try #require(CredentialJSON.object(from: rotated.formatted(pretty: true)))
    #expect(object["auth_mode"] as? String == "chatgpt")
    #expect(object["OPENAI_API_KEY"] is NSNull)
}

@Test func emailsAndSandboxNames() {
    #expect(AIAccountPaths.isUsableEmail("developer@example.com"))
    #expect(!AIAccountPaths.isUsableEmail("no-at-sign"))
    #expect(!AIAccountPaths.isUsableEmail("quote\"@example.com"))
    let paths = AIAccountPaths.sandbox(root: URL(fileURLWithPath: "/tmp/x"), keychainPrefix: "menusprite-test-")
    #expect(paths.savedService(.claude, email: "a@example.com") == "menusprite-test-claude-switcher:a@example.com")
    #expect(paths.claudeLiveService == "menusprite-test-Claude Code-credentials")
    #expect(AIAccountPaths.standard.claudeLiveService == "Claude Code-credentials")
    #expect(AIAccountPaths.claudeCodeUserName(environment: ["USER": "bad name"]) == "claude-code-user")
}

@Test func atomicFileKeepsModeAndContents() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("menusprite-atomic-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("state.json")
    try AtomicFile.write(Data("one".utf8), to: file, permissions: 0o644)
    try AtomicFile.write(Data("two".utf8), to: file)
    #expect(try String(contentsOf: file, encoding: .utf8) == "two")
    let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    #expect(mode == 0o644)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["state.json"])
}

private actor OrderLog {
    var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
}

@Test func credentialGateSerializesAsyncWork() async throws {
    let gate = CredentialGate()
    let log = OrderLog()
    async let first: Void = gate.run {
        await log.append("a1")
        try await Task.sleep(for: .milliseconds(120))
        await log.append("a2")
    }
    try await Task.sleep(for: .milliseconds(30))
    async let second: Void = gate.run {
        await log.append("b1")
        await log.append("b2")
    }
    _ = try await (first, second)
    #expect(await log.entries == ["a1", "a2", "b1", "b2"])
}

@Test func inMemoryKeychainMatchesAccount() throws {
    let keychain = InMemoryKeychain()
    try keychain.writePassword(service: "s", account: "testuser", value: "v")
    #expect(try keychain.readPassword(service: "s", account: nil) == "v")
    #expect(try keychain.readPassword(service: "s", account: "other") == nil)
    #expect(try keychain.deleteAll(service: "s") == 1)
    #expect(try keychain.readPassword(service: "s", account: nil) == nil)
}

/// Uses a disposable keychain and synthetic values; never reads the login keychain. Run explicitly:
/// `MENUSPRITE_KEYCHAIN_TESTS=1 swift test --package-path native --filter systemKeychain`
@Test(.enabled(if: ProcessInfo.processInfo.environment["MENUSPRITE_KEYCHAIN_TESTS"] == "1"))
func systemKeychainRoundTripsStdinAndFrameworkPaths() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("menusprite-keychain-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("isolated.keychain-db").path
    let password = UUID().uuidString
    var isolated: SecKeychain?
    let status = password.withCString { SecKeychainCreate(path, UInt32(password.utf8.count), $0, false, nil, &isolated) }
    try #require(status == errSecSuccess)
    let isolatedKeychain = try #require(isolated)
    defer { SecKeychainDelete(isolatedKeychain) }
    let keychain = SystemKeychain(keychainPath: path)
    let service = "menusprite-test-item \(UUID().uuidString)"
    defer { _ = try? keychain.deleteAll(service: service) }
    let small = #"{"claudeAiOauth":{"accessToken":"é-small"}}"#
    let large = "{\"claudeAiOauth\":{\"accessToken\":\"\(String(repeating: "x", count: 6_000))\"}}"
    // Create through the framework so the unsigned test runner has explicit access.
    // No login-keychain access or interactive trust grant is required.
    try keychain.writePassword(service: service, account: "testuser", value: large)
    #expect(try keychain.readPassword(service: service, account: "testuser") == large)
    #expect(try keychain.accountName(service: service) == "testuser")
    // The CLIs' own login is read through /usr/bin/security, as they read it, so it cannot partition-mismatch.
    #expect(try keychain.readCLIOwnedPassword(service: service, account: "testuser") == large)
    #expect(try keychain.readCLIOwnedPassword(service: service, account: nil) == large)
    #expect(try keychain.readCLIOwnedPassword(service: "menusprite-absent \(UUID().uuidString)", account: nil) == nil)
    let huge = "{\"claudeAiOauth\":{\"accessToken\":\"\(String(repeating: "y", count: 100_000))\"}}"
    try keychain.writePassword(service: service, account: "testuser", value: huge)
    #expect(try keychain.readCLIOwnedPassword(service: service, account: "testuser") == huge) // larger than a pipe buffer
    try keychain.writePassword(service: service, account: "testuser", value: large)
    let cli = Process(), output = Pipe()
    cli.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    cli.arguments = ["find-generic-password", "-s", service, "-a", "testuser", "-w", path]
    cli.standardOutput = output; cli.standardError = FileHandle.nullDevice
    try cli.run()
    let cliValue = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    cli.waitUntilExit()
    #expect(cli.terminationStatus == 0)
    #expect(cliValue.trimmingCharacters(in: .whitespacesAndNewlines) == large)
    try keychain.writePassword(service: service, account: "testuser", value: small)
    #expect(try keychain.readPassword(service: service, account: "testuser") == small)
    try keychain.writePassword(service: service, account: "testuser", value: large)
    #expect(try keychain.readPassword(service: service, account: "testuser") == large)
    #expect(try keychain.deleteAll(service: service) == 1)
    #expect(try keychain.readPassword(service: service, account: nil) == nil)
    #expect(try keychain.readCLIOwnedPassword(service: service, account: nil) == nil)
}

@Test func providerRedirectsNeverForwardCredentials() async throws {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let source = URL(string: "https://provider.example/usage")!
    let task = session.dataTask(with: source) // Remains suspended; no network request occurs.
    for status in [301, 302, 303, 307, 308] {
        let response = try #require(HTTPURLResponse(url: source, statusCode: status,
                                                   httpVersion: nil, headerFields: nil))
        var redirected = URLRequest(url: URL(string: "https://other.example/token")!)
        redirected.httpMethod = "POST"
        redirected.setValue("Bearer synthetic-token", forHTTPHeaderField: "Authorization")
        redirected.httpBody = Data("refresh_token=synthetic".utf8)
        let permitted: URLRequest? = await withCheckedContinuation { continuation in
            NoRedirectDelegate().urlSession(session, task: task, willPerformHTTPRedirection: response,
                                           newRequest: redirected) { continuation.resume(returning: $0) }
        }
        #expect(permitted == nil)
    }
}
