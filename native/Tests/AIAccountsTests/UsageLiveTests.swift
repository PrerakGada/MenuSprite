import Foundation
import Testing
@testable import AIAccounts

/// Reads the real logins but refuses every mutation, so the live check can never rotate or write a credential.
private struct ReadOnlyKeychain: KeychainStoring {
    struct WriteBlocked: Error {}
    let base = SystemKeychain()
    func readPassword(service: String, account: String?) throws -> String? { try base.readPassword(service: service, account: account) }
    func accountName(service: String) throws -> String? { try base.accountName(service: service) }
    func writePassword(service: String, account: String, value: String) throws { throw WriteBlocked() }
    func deleteAll(service: String) throws -> Int { throw WriteBlocked() }
}

/// Lets only GET requests through, so no token refresh can reach a provider.
private struct GetOnlyTransport: HTTPTransport {
    struct PostBlocked: Error {}
    let base = URLSessionTransport()
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.method == "GET" else { throw PostBlocked() }
        return try await base.send(request)
    }
}

private func describe(_ result: Result<UsageSnapshot, UsageError>) -> String {
    switch result {
    case .failure(let error): return "failed: \(error.localizedDescription)"
    case .success(let snapshot):
        let windows = snapshot.windows.map { window in
            "\(window.id)=\(window.usedPercent)% resets=\(window.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "-")"
        }.joined(separator: " ")
        return "email=\(snapshot.accountEmail ?? "-") plan=\(snapshot.plan ?? "-") \(windows) credits=\(snapshot.creditsRemaining.map { "\($0)" } ?? "-")"
    }
}

/// One read-only GET per provider against the real logins, compared with OpenUsage's local API.
/// `MENUSPRITE_LIVE_USAGE=1 swift test --package-path native --filter liveReadOnlyUsage`
@Test(.enabled(if: ProcessInfo.processInfo.environment["MENUSPRITE_LIVE_USAGE"] == "1"))
func liveReadOnlyUsageMatchesOpenUsage() async throws {
    let paths = AIAccountPaths.standard
    let keychain = ReadOnlyKeychain()
    let service = UsageService(paths: paths, keychain: keychain, http: GetOnlyTransport())

    let claudeText = try keychain.readPassword(service: paths.claudeLiveService, account: paths.keychainAccount)
    if let claude = claudeText.flatMap(ClaudeCredential.init(json:)) {
        if claude.expires(within: 300) {
            print("[live] claude: live token expires within 5 minutes — not fetching, to avoid a refresh")
        } else {
            print("[live] claude: \(describe(await service.activeUsage(.claude, force: true)))")
        }
    } else {
        print("[live] claude: no live login")
    }

    let codexText = try? String(contentsOf: paths.codexAuth, encoding: .utf8)
    if let codex = codexText.flatMap(CodexCredential.init(json:)) {
        if codex.expires(within: 300) {
            print("[live] codex: live token expires within 5 minutes — not fetching, to avoid a refresh")
        } else {
            print("[live] codex: \(describe(await service.activeUsage(.codex, force: true)))")
        }
    } else {
        print("[live] codex: no live login")
    }

    guard let (data, _) = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:6736/v1/limits")!),
          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let providers = root["providers"] as? [String: Any] else {
        print("[openusage] local API unavailable")
        return
    }
    for name in ["claude", "codex"] {
        guard let provider = providers[name] as? [String: Any], let resources = provider["resources"] as? [String: Any] else { continue }
        let used = resources.keys.sorted().compactMap { key -> String? in
            guard let resource = resources[key] as? [String: Any], let value = resource["used"] as? NSNumber else { return nil }
            return "\(key)=\(value)% resets=\(resource["resetsAt"] as? String ?? "-")"
        }.joined(separator: " ")
        print("[openusage] \(name): plan=\(provider["plan"] as? String ?? "-") fetchedAt=\(provider["fetchedAt"] as? String ?? "-") \(used)")
    }
}
