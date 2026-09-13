import Foundation

struct ClaudeTokenResponse: Sendable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Double?
}

/// Anthropic's OAuth usage endpoint — the source behind Claude Code's own usage screen and OpenUsage.
enum ClaudeUsageAPI {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let scopes = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
    static let userAgent = "claude-code/2.1.268"
    static let sessionSeconds: Double = 18_000
    static let weekSeconds: Double = 604_800

    static func usageRequest(accessToken: String) -> HTTPRequest {
        HTTPRequest(method: "GET", url: usageURL, headers: [
            "Authorization": "Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": userAgent
        ], timeout: 10)
    }

    static func refreshRequest(refreshToken: String) -> HTTPRequest {
        let body: [String: Any] = ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID, "scope": scopes]
        return HTTPRequest(method: "POST", url: tokenURL, headers: ["Content-Type": "application/json"],
                           body: try? JSONSerialization.data(withJSONObject: body), timeout: 15)
    }

    static func parseRefresh(_ response: HTTPResponse) throws -> ClaudeTokenResponse {
        if response.statusCode == 400 || response.statusCode == 401 {
            let body = UsageParse.object(response.body)
            let code = (body?["error"] as? String) ?? (body?["error_description"] as? String)
            // Without a recognized OAuth code the failure may be a proxy page, not an expired login.
            throw code == "invalid_grant" ? UsageError.sessionExpired : UsageError.requestFailed(status: response.statusCode)
        }
        guard response.isSuccess else { throw UsageError.requestFailed(status: response.statusCode) }
        guard let body = UsageParse.object(response.body), let access = body["access_token"] as? String, !access.isEmpty else {
            throw UsageError.invalidResponse
        }
        return ClaudeTokenResponse(accessToken: access, refreshToken: body["refresh_token"] as? String,
                                   expiresIn: UsageParse.number(body["expires_in"]))
    }

    static func snapshot(from response: HTTPResponse, credential: ClaudeCredential, email: String?, now: Date) throws -> UsageSnapshot {
        guard let body = UsageParse.object(response.body) else { throw UsageError.invalidResponse }
        var windows: [UsageWindow] = []
        func append(_ value: Any?, id: String, label: String, seconds: Double) {
            guard let object = value as? [String: Any], let used = UsageParse.number(object["utilization"]) else { return }
            windows.append(UsageWindow(id: id, label: label, usedPercent: used, resetsAt: UsageParse.date(object["resets_at"]), windowSeconds: seconds))
        }
        append(body["five_hour"], id: "session", label: "Session", seconds: sessionSeconds)
        append(body["seven_day"], id: "weekly", label: "Weekly", seconds: weekSeconds)
        append(body["seven_day_sonnet"], id: "sonnet", label: "Sonnet", seconds: weekSeconds)
        // Model-scoped weekly limits moved from `seven_day_<model>` keys into `limits[]`, and which
        // models appear there is the server's choice — map every one rather than the names we knew about.
        for scoped in scopedWeeklyWindows(body["limits"]) {
            windows.removeAll { $0.id == scoped.id }
            windows.append(scoped)
        }
        return UsageSnapshot(provider: .claude, accountEmail: email,
                             plan: UsageParse.claudePlan(subscriptionType: credential.subscriptionType, rateLimitTier: credential.rateLimitTier),
                             windows: windows, extraUsage: extraUsage(body),
                             breakdown: breakdownRows(body["seven_day_breakdown"]), fetchedAt: now)
    }

    /// Every `kind: "weekly_scoped"` limit, identified by its model's display name. `session` and
    /// `weekly_all` entries in the same array repeat `five_hour`/`seven_day`, so they are left alone.
    private static func scopedWeeklyWindows(_ limits: Any?) -> [UsageWindow] {
        guard let entries = limits as? [Any] else { return [] }
        return entries.compactMap { entry -> UsageWindow? in
            guard let object = entry as? [String: Any], object["kind"] as? String == "weekly_scoped",
                  let model = (object["scope"] as? [String: Any])?["model"] as? [String: Any],
                  let display = UsageParse.text(model["display_name"]),
                  let used = UsageParse.number(object["percent"]) else { return nil }
            let id = display.lowercased().filter { $0.isLetter || $0.isNumber }
            guard !id.isEmpty else { return nil }
            return UsageWindow(id: id, label: display, usedPercent: used,
                               resetsAt: UsageParse.date(object["resets_at"]), windowSeconds: weekSeconds)
        }
    }

    /// `spend` is the newer dollar-denominated shape; `extra_usage` is the older cents-based one. An
    /// allowance that is switched off still reports a real $0.00 — the record exists, it is just disabled.
    private static func extraUsage(_ body: [String: Any]) -> ExtraUsageSpend? {
        if let spend = body["spend"] as? [String: Any] {
            let exponent = UsageParse.number((spend["used"] as? [String: Any])?["exponent"]) ?? 2
            return ExtraUsageSpend(enabled: spend["enabled"] as? Bool ?? false,
                                   usedDollars: minorUnits(spend["used"], exponent: exponent) ?? 0,
                                   limitDollars: minorUnits(spend["limit"], exponent: exponent),
                                   percent: UsageParse.number(spend["percent"]),
                                   disabledReason: UsageParse.text(spend["disabled_reason"]))
        }
        guard let extra = body["extra_usage"] as? [String: Any] else { return nil }
        let usedCents = UsageParse.number(extra["used_credits"]) ?? 0
        let limitCents = UsageParse.number(extra["monthly_limit"])
        return ExtraUsageSpend(enabled: extra["is_enabled"] as? Bool ?? false, usedDollars: usedCents / 100,
                               limitDollars: (limitCents ?? 0) > 0 ? (limitCents ?? 0) / 100 : nil,
                               percent: UsageParse.number(extra["utilization"]),
                               disabledReason: UsageParse.text(extra["disabled_reason"]))
    }

    /// `{amount_minor, exponent}`, or a bare number in the same minor units. The currency code is not
    /// modelled: these readings are labelled in dollars, which is what the endpoint reports here.
    private static func minorUnits(_ value: Any?, exponent: Double) -> Double? {
        if let object = value as? [String: Any] {
            guard let minor = UsageParse.number(object["amount_minor"]) else { return nil }
            return minor / pow(10, UsageParse.number(object["exponent"]) ?? exponent)
        }
        return UsageParse.number(value).map { $0 / pow(10, exponent) }
    }

    /// The weekly window's split across surfaces (Claude Code, chats, Cowork, other).
    private static func breakdownRows(_ value: Any?) -> [UsageBreakdownRow] {
        guard let object = value as? [String: Any], let rows = object["rows"] as? [Any] else { return [] }
        return rows.compactMap { row -> UsageBreakdownRow? in
            guard let entry = row as? [String: Any], let key = UsageParse.text(entry["key"]),
                  let percent = UsageParse.number(entry["percent"]) else { return nil }
            return UsageBreakdownRow(id: key, label: UsageParse.text(entry["display_name"]) ?? key, percent: percent)
        }
    }
}
