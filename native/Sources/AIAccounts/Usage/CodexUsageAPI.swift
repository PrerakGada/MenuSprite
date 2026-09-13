import Foundation

struct CodexTokenResponse: Sendable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
}

/// ChatGPT's Codex usage endpoint — the source behind the Codex CLI's `/status` limits and OpenUsage.
enum CodexUsageAPI {
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let resetCreditsURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let userAgent = "MenuSprite"
    static let sessionSeconds: Double = 18_000
    static let weekSeconds: Double = 604_800

    static func usageRequest(accessToken: String, accountID: String?) -> HTTPRequest {
        var headers = ["Authorization": "Bearer \(accessToken)", "Accept": "application/json", "User-Agent": userAgent]
        if let accountID, !accountID.isEmpty { headers["ChatGPT-Account-Id"] = accountID }
        return HTTPRequest(method: "GET", url: usageURL, headers: headers, timeout: 10)
    }

    /// The Codex client sends these extra headers for the reset-credit endpoint; a plain usage request
    /// shape is not enough for it.
    static func resetCreditsRequest(accessToken: String, accountID: String?) -> HTTPRequest {
        var headers = ["Authorization": "Bearer \(accessToken)", "Accept": "application/json", "User-Agent": userAgent,
                       "OpenAI-Beta": "codex-1", "originator": "Codex Desktop"]
        if let accountID, !accountID.isEmpty { headers["ChatGPT-Account-Id"] = accountID }
        return HTTPRequest(method: "GET", url: resetCreditsURL, headers: headers, timeout: 10)
    }

    /// The count the usage body already carries. The dedicated endpoint is only worth a request when
    /// this is above zero: all it adds is the per-credit expiry list.
    static func embeddedResetCreditCount(_ response: HTTPResponse) -> Int? {
        UsageParse.object(response.body).flatMap(embeddedResetCreditCount)
    }

    private static func embeddedResetCreditCount(_ body: [String: Any]) -> Int? {
        guard let object = body["rate_limit_reset_credits"] as? [String: Any],
              let count = UsageParse.number(object["available_count"]), count >= 0 else { return nil }
        return Int(count.rounded(.down))
    }

    static func refreshRequest(refreshToken: String) -> HTTPRequest {
        let body = "grant_type=refresh_token&client_id=\(formEncoded(clientID))&refresh_token=\(formEncoded(refreshToken))"
        return HTTPRequest(method: "POST", url: tokenURL, headers: ["Content-Type": "application/x-www-form-urlencoded"],
                           body: Data(body.utf8), timeout: 15)
    }

    static func parseRefresh(_ response: HTTPResponse) throws -> CodexTokenResponse {
        if response.statusCode == 400 || response.statusCode == 401 {
            let body = UsageParse.object(response.body)
            let code: String?
            if let error = body?["error"] as? [String: Any] {
                code = (error["code"] as? String) ?? (error["error"] as? String)
            } else {
                code = (body?["error"] as? String) ?? (body?["code"] as? String)
            }
            switch code {
            case "refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated": throw UsageError.sessionExpired
            default: throw UsageError.requestFailed(status: response.statusCode)
            }
        }
        guard response.isSuccess else { throw UsageError.requestFailed(status: response.statusCode) }
        guard let body = UsageParse.object(response.body), let access = body["access_token"] as? String, !access.isEmpty else {
            throw UsageError.sessionExpired
        }
        return CodexTokenResponse(accessToken: access, refreshToken: body["refresh_token"] as? String, idToken: body["id_token"] as? String)
    }

    static func snapshot(from response: HTTPResponse, credential: CodexCredential, fallbackEmail: String?,
                         resetCredits resetResponse: HTTPResponse? = nil, now: Date) throws -> UsageSnapshot {
        guard let body = UsageParse.object(response.body) else { throw UsageError.invalidResponse }
        var windows = classifiedWindows(
            rateLimit: body["rate_limit"] as? [String: Any], ids: ("session", "weekly"), labels: ("Session", "Weekly"),
            headerPercents: (UsageParse.number(response.header("x-codex-primary-used-percent")),
                             UsageParse.number(response.header("x-codex-secondary-used-percent"))),
            now: now)
        if let entries = body["additional_rate_limits"] as? [Any],
           let spark = entries.compactMap({ $0 as? [String: Any] }).first(where: isSpark),
           let rateLimit = spark["rate_limit"] as? [String: Any] {
            windows += classifiedWindows(rateLimit: rateLimit, ids: ("spark", "sparkWeekly"), labels: ("Spark", "Spark Weekly"),
                                         headerPercents: (nil, nil), now: now)
        }
        // Codex prices a flex credit at four cents, the rate its own CLI and plugin use.
        let remaining = credits(response, body)
        return UsageSnapshot(provider: .codex, accountEmail: credential.email ?? fallbackEmail,
                             plan: UsageParse.codexPlan(body["plan_type"]) ?? UsageParse.codexPlan(credential.plan),
                             windows: windows, creditsRemaining: remaining,
                             creditDollars: remaining.map { max(0, $0.rounded(.down)) * 0.04 },
                             resetCredits: resetCredits(resetResponse, body: body), fetchedAt: now)
    }

    /// Prefers the dedicated endpoint — the only source of per-credit expiries — and falls back to the
    /// count embedded in the usage body when that request was skipped or failed.
    private static func resetCredits(_ dedicated: HTTPResponse?, body: [String: Any]) -> ResetCredits? {
        if let dedicated, dedicated.isSuccess, let object = UsageParse.object(dedicated.body),
           let count = UsageParse.number(object["available_count"]), count >= 0 {
            return ResetCredits(available: Int(count.rounded(.down)), expiries: availableExpiries(object["credits"]))
        }
        return embeddedResetCreditCount(body).map { ResetCredits(available: $0) }
    }

    /// `status` is optional upstream, so only an explicitly non-available credit is dropped.
    private static func availableExpiries(_ value: Any?) -> [Date] {
        guard let credits = value as? [Any] else { return [] }
        return credits.compactMap { credit -> Date? in
            guard let object = credit as? [String: Any] else { return nil }
            if let status = UsageParse.text(object["status"]), status != "available" { return nil }
            return UsageParse.date(object["expires_at"])
        }.sorted()
    }

    private enum Kind { case session, weekly }

    private struct Candidate {
        let window: [String: Any]
        let usedPercent: Double?
        let slot: Kind
    }

    /// Codex normally sends the 5-hour window as `primary_window` and the weekly one as
    /// `secondary_window`, but can move a sole weekly limit into the primary slot. Classify by the
    /// reported duration; the slot mapping only covers payloads without a familiar duration.
    static func classifiedWindows(rateLimit: [String: Any]?, ids: (session: String, weekly: String),
                                  labels: (session: String, weekly: String),
                                  headerPercents: (primary: Double?, secondary: Double?), now: Date) -> [UsageWindow] {
        let candidates = [
            candidate(rateLimit?["primary_window"], header: headerPercents.primary, slot: .session),
            candidate(rateLimit?["secondary_window"], header: headerPercents.secondary, slot: .weekly)
        ].compactMap { $0 }
        let kinds: [(Kind, String, String)] = [(.session, ids.session, labels.session), (.weekly, ids.weekly, labels.weekly)]
        return kinds.compactMap { entry -> UsageWindow? in
            let (kind, id, label) = entry
            let exact = candidates.first { exactKind($0.window) == kind }
            let bySlot = candidates.first { exactKind($0.window) == nil && $0.slot == kind }
            guard let chosen = exact ?? bySlot, let used = chosen.usedPercent else { return nil }
            let seconds = UsageParse.number(chosen.window["limit_window_seconds"]) ?? (kind == .session ? sessionSeconds : weekSeconds)
            return UsageWindow(id: id, label: label, usedPercent: used, resetsAt: resetDate(chosen.window, now: now), windowSeconds: seconds)
        }
    }

    private static func candidate(_ value: Any?, header: Double?, slot: Kind) -> Candidate? {
        guard let window = (value as? [String: Any]) ?? (header == nil ? nil : [:]) else { return nil }
        return Candidate(window: window, usedPercent: UsageParse.number(window["used_percent"]) ?? header, slot: slot)
    }

    private static func exactKind(_ window: [String: Any]) -> Kind? {
        switch UsageParse.number(window["limit_window_seconds"]).map({ Int($0) }) {
        case Int(sessionSeconds): return .session
        case Int(weekSeconds): return .weekly
        default: return nil
        }
    }

    private static func resetDate(_ window: [String: Any], now: Date) -> Date? {
        if let resetAt = UsageParse.number(window["reset_at"]) { return Date(timeIntervalSince1970: resetAt) }
        if let after = UsageParse.number(window["reset_after_seconds"]) { return now.addingTimeInterval(after) }
        return nil
    }

    private static func credits(_ response: HTTPResponse, _ body: [String: Any]) -> Double? {
        if let credits = body["credits"] as? [String: Any] {
            if let balance = UsageParse.number(credits["balance"]) { return balance }
            if credits["has_credits"] as? Bool == false { return 0 }
        }
        return UsageParse.number(response.header("x-codex-credits-balance"))
    }

    private static func isSpark(_ entry: [String: Any]) -> Bool {
        [entry["limit_name"], entry["metered_feature"]].compactMap { ($0 as? String)?.lowercased() }.contains { $0.contains("spark") }
    }

    private static let formAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func formEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? value
    }
}
