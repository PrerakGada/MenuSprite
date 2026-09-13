import Foundation
import Testing
@testable import AIAccounts

/// Claude Code, the Codex CLI and OpenUsage refresh the same live logins MenuSprite reads.
/// Losing that race must reload the winner's login, never report a dead session.

@Test func claudeRefreshBeatenByAnotherClientReloadsInsteadOfReportingExpiry() async throws {
    let sandbox = UsageSandbox(); defer { sandbox.cleanup() }
    try sandbox.setClaudeState(email: "developer@example.com")
    try sandbox.setLiveClaude(UsageFixtures.claudeCredential(expiresIn: 60))
    let keychain = sandbox.keychain
    let paths = sandbox.paths
    let http = FakeTransport { request, _ in
        if request.method == "POST" {
            try keychain.writePassword(service: paths.claudeLiveService, account: paths.keychainAccount,
                                       value: UsageFixtures.claudeCredential(access: "access-cli", refresh: "refresh-cli"))
            return UsageFixtures.response(400, ["error": "invalid_grant"])
        }
        return UsageFixtures.response(200, UsageFixtures.claudeUsageBody())
    }
    let snapshot = try (await sandbox.service(http).activeUsage(.claude, force: false)).get()
    #expect(snapshot.window("weekly")?.usedPercent == 77)
    #expect(http.requests.map(\.method) == ["POST", "GET"])
    #expect(http.requests.last?.headers["Authorization"] == "Bearer access-cli")
    #expect(sandbox.liveClaude()?.refreshToken == "refresh-cli")
}

@Test func codexRefreshBeatenByTheCLIReloadsTheNewAuthFile() async throws {
    let sandbox = UsageSandbox(); defer { sandbox.cleanup() }
    let start = UsageFixtures.now.timeIntervalSince1970
    try sandbox.setCodexAuth(UsageFixtures.codexAuth(accessExpiry: start + 60))
    let authFile = sandbox.paths.codexAuth
    let http = FakeTransport { request, _ in
        if request.method == "POST" {
            let rotated = UsageFixtures.codexAuth(accessExpiry: start + 36_000, accessTag: "cli", refresh: "r-cli")
            try AtomicFile.write(Data(rotated.utf8), to: authFile, permissions: 0o600)
            return UsageFixtures.response(401, ["error": ["code": "refresh_token_reused"]])
        }
        return UsageFixtures.response(200, UsageFixtures.standardCodexBody())
    }
    let snapshot = try (await sandbox.service(http).activeUsage(.codex, force: false)).get()
    #expect(snapshot.window("weekly")?.usedPercent == 47)
    #expect(http.requests.map(\.method) == ["POST", "GET"])
    #expect(try sandbox.codexAuth()?.refreshToken == "r-cli")
}
