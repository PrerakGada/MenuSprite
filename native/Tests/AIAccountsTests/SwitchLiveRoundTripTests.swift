import Foundation
import Testing
@testable import AIAccounts

/// Real keychain, real `~/.claude.json`, real `accounts.json`, real Anthropic identity check. Moves the
/// live Claude login to another saved account and straight back — faster than Claude Code's 30-second
/// keychain cache — checking every store on the way. Prints emails and booleans only. Run only with
/// the account owner's explicit go-ahead:
/// `MENUSPRITE_LIVE_SWITCH_ROUNDTRIP="home@example.com>away@example.com" swift test --package-path native --filter liveClaudeSwitchRoundTrip`
@Test(.enabled(if: ProcessInfo.processInfo.environment["MENUSPRITE_LIVE_SWITCH_ROUNDTRIP"] != nil))
func liveClaudeSwitchRoundTrip() async throws {
    let parts = (ProcessInfo.processInfo.environment["MENUSPRITE_LIVE_SWITCH_ROUNDTRIP"] ?? "").split(separator: ">").map(String.init)
    try #require(parts.count == 2)
    let home = parts[0], away = parts[1]
    let paths = AIAccountPaths.standard
    let keychain = SystemKeychain()
    let switcher = AccountSwitcher(paths: paths, keychain: keychain, usage: UsageService(), http: URLSessionTransport())

    func live() throws -> ClaudeCredential? {
        try keychain.readPassword(service: paths.claudeLiveService, account: paths.keychainAccount).flatMap(ClaudeCredential.init(json:))
    }
    func saved(_ email: String) throws -> ClaudeCredential? {
        try keychain.readPassword(service: paths.savedService(.claude, email: email), account: nil).flatMap(ClaudeCredential.init(json:))
    }
    func stateEmail() -> String? { (try? ClaudeState.oauthAccountJSON(at: paths.claudeState)).flatMap(ClaudeState.email(inOAuthAccount:)) }
    func activeEmail() -> String? { (try? SwitcherConfig.load(from: paths.switcherConfig))?.active(.claude)?.email }

    let originalRaw = try #require(try keychain.readPassword(service: paths.claudeLiveService, account: paths.keychainAccount))
    let original = try #require(ClaudeCredential(json: originalRaw))
    let awayCopy = try #require(try saved(away))
    try #require(stateEmail() == home)
    print("before: state=\(stateEmail() ?? "nil") active=\(activeEmail() ?? "nil") liveEqualsSavedHome=\((try saved(home))?.tokenFingerprint == original.tokenFingerprint)")

    let started = Date()
    do {
        let first = try await switcher.switchAccount(.claude, to: away)
        let liveAfterFirst = try live()?.tokenFingerprint
        let homeCopyAfterFirst = try saved(home)?.tokenFingerprint
        let stateAfterFirst = stateEmail(), activeAfterFirst = activeEmail()
        let second = try await switcher.switchAccount(.claude, to: home)
        let elapsed = Date().timeIntervalSince(started)
        let finalLive = try live()
        print("switch 1: backedUp=\(first.backedUpEmail ?? "nil") notes=\(first.notes)")
        print("after 1: liveIsAwayCopy=\(liveAfterFirst == awayCopy.tokenFingerprint) homeCopyIsOriginalLive=\(homeCopyAfterFirst == original.tokenFingerprint) state=\(stateAfterFirst ?? "nil") active=\(activeAfterFirst ?? "nil")")
        print("switch 2: backedUp=\(second.backedUpEmail ?? "nil") notes=\(second.notes)")
        print("after 2: liveIsOriginal=\(finalLive?.tokenFingerprint == original.tokenFingerprint) awayCopyUnchanged=\((try saved(away))?.tokenFingerprint == awayCopy.tokenFingerprint) state=\(stateEmail() ?? "nil") active=\(activeEmail() ?? "nil") elapsed=\(String(format: "%.2f", elapsed))s")
        #expect(liveAfterFirst == awayCopy.tokenFingerprint)
        #expect(homeCopyAfterFirst == original.tokenFingerprint)
        #expect(stateAfterFirst == away)
        #expect(activeAfterFirst == away)
        #expect(finalLive?.tokenFingerprint == original.tokenFingerprint)
        #expect(stateEmail() == home)
        #expect(activeEmail() == home)
        #expect(elapsed < 20)
    } catch {
        // Put the original login, profile and active flag back before reporting anything.
        try? keychain.writePassword(service: paths.claudeLiveService, account: paths.keychainAccount, value: originalRaw)
        if var config = try? SwitcherConfig.load(from: paths.switcherConfig) {
            if let profile = config.account(.claude, email: home)?.oauthAccountJSON {
                _ = try? ClaudeStateWriter.replaceOAuthAccount(with: profile, at: paths.claudeState)
            }
            config.setActive(.claude, email: home)
            try? config.save(to: paths.switcherConfig)
        }
        Issue.record("Round trip failed; the original live login, profile and active flag were written back: \(error.localizedDescription)")
    }
}
