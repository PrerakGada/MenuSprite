import Foundation

/// Anthropic's own answer to "whose login is this". Once Claude Code rotates its tokens no saved copy
/// matches the live login, and `~/.claude.json` can still name a previous account, so a switch or save
/// asks the OAuth profile endpoint before filing the live login under an email.
public enum LiveClaudeIdentity: Sendable, Equatable {
    case verified(tokenFingerprint: String, email: String)
    /// Anthropic rejected the login and refreshing it reported an expired session: nothing worth saving.
    case expired(tokenFingerprint: String)
    /// No answer (offline, server error, unexpected response). Nothing is filed under a guess.
    case unconfirmed(String)
}

enum ClaudeProfileAPI {
    static let url = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    enum Answer: Sendable, Equatable {
        case email(String)
        case rejected
        case failed(String)
    }

    static func request(accessToken: String) -> HTTPRequest {
        HTTPRequest(method: "GET", url: url, headers: [
            "Authorization": "Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))",
            "Accept": "application/json",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": ClaudeUsageAPI.userAgent
        ], timeout: 10)
    }

    static func answer(_ credential: ClaudeCredential, http: any HTTPTransport) async -> Answer {
        let response: HTTPResponse
        do {
            response = try await http.send(request(accessToken: credential.accessToken))
        } catch {
            return .failed("Could not reach Anthropic to confirm which Claude account is signed in.")
        }
        if response.statusCode == 401 || response.statusCode == 403 { return .rejected }
        guard response.isSuccess, let body = UsageParse.object(response.body),
              let email = CredentialJSON.nonEmpty((body["account"] as? [String: Any])?["email"]),
              AIAccountPaths.isUsableEmail(email) else {
            return .failed("Anthropic did not confirm which Claude account is signed in (HTTP \(response.statusCode)).")
        }
        return .email(email)
    }
}

extension AccountSwitcher {
    /// Nil when no verifier is configured or nothing is signed in; the state file is trusted then.
    /// Runs outside the credential gate: a rejected token is refreshed through the usage service,
    /// which writes the rotation back under that gate.
    func confirmLiveClaudeIdentity() async -> LiveClaudeIdentity? {
        guard let http, let credential = (try? readLiveClaude()).flatMap(ClaudeCredential.init(json:)) else { return nil }
        switch await ClaudeProfileAPI.answer(credential, http: http) {
        case .email(let email):
            return .verified(tokenFingerprint: credential.tokenFingerprint, email: email)
        case .failed(let reason):
            return .unconfirmed(reason)
        case .rejected:
            guard let usage else { return .unconfirmed("Anthropic rejected the signed-in Claude login.") }
            let refresh = await usage.activeUsage(.claude, force: true)
            if let current = (try? readLiveClaude()).flatMap(ClaudeCredential.init(json:)),
               current.tokenFingerprint != credential.tokenFingerprint,
               case .email(let email) = await ClaudeProfileAPI.answer(current, http: http) {
                return .verified(tokenFingerprint: current.tokenFingerprint, email: email)
            }
            if case .failure(.sessionExpired) = refresh { return .expired(tokenFingerprint: credential.tokenFingerprint) }
            return .unconfirmed("Anthropic rejected the signed-in Claude login and it could not be refreshed.")
        }
    }
}
