import Foundation

/// A reading value for the monitoring layer, which lives in a module this one does not import.
public enum AIUsageValue: Sendable, Equatable {
    case percent(Double)
    /// Seconds until a window resets.
    case seconds(Double)
    case count(Double)
    case currency(Double)
    case text(String)
    case unavailable(String)
}

/// The `ai.` reading IDs shared with the monitoring catalog and the accounts board.
public enum AIUsageMetrics {
    public static let prefix = "ai."

    /// Windows with a catalog entry of their own. Model-scoped windows beyond these — Sonnet, Opus,
    /// anything Anthropic adds later — arrive in the snapshot and are surfaced dynamically instead.
    public static let staticWindowIDs: [AIProvider: [String]] = [
        .claude: ["session", "weekly", "sonnet", "fable"],
        .codex: ["session", "weekly", "spark", "sparkWeekly"]
    ]

    public static func ids(for provider: AIProvider) -> [String] {
        let base = "\(prefix)\(provider.rawValue)."
        let windows = (staticWindowIDs[provider] ?? []).map { base + $0 }
        let shared = ["sessionReset", "weeklyReset", "account", "plan", "spendToday", "spend7d", "spend30d"].map { base + $0 }
        switch provider {
        case .claude: return windows + shared + [base + "extraUsage", base + "claudeCodeShare"]
        case .codex: return windows + shared + [base + "credits", base + "creditsValue", base + "resets"]
        }
    }

    public static func provider(for metricID: String) -> AIProvider? {
        AIProvider.allCases.first { metricID.hasPrefix("\(prefix)\($0.rawValue).") }
    }

    /// The reading id for one window of a provider, e.g. `ai.claude.sonnet`.
    public static func id(_ provider: AIProvider, window: String) -> String {
        "\(prefix)\(provider.rawValue).\(window)"
    }

    /// Windows a snapshot carries that no catalog entry covers — a model-scoped limit the provider
    /// added on its own. The monitoring catalog turns these into readings so they can become sprites.
    public static func discoveredWindows(_ snapshot: UsageSnapshot) -> [(id: String, label: String, window: String)] {
        let known = Set(staticWindowIDs[snapshot.provider] ?? [])
        return snapshot.windows.filter { !known.contains($0.id) }
            .map { (id(snapshot.provider, window: $0.id), $0.label, $0.id) }
    }

    /// Every reading for one provider. Estimated spend comes from local logs, so it is passed in
    /// separately and survives a usage-endpoint failure.
    public static func values(for provider: AIProvider, result: Result<UsageSnapshot, UsageError>,
                              spend: SpendSummary? = nil, now: Date) -> [String: AIUsageValue] {
        let base = "\(prefix)\(provider.rawValue)."
        var values = spendValues(base: base, spend: spend)

        guard case .success(let snapshot) = result else {
            let text = errorText(result)
            for id in ids(for: provider) where values[id] == nil { values[id] = .unavailable(text) }
            return values
        }

        for window in staticWindowIDs[provider] ?? [] {
            values[base + window] = snapshot.window(window).map { .percent($0.usedPercent) }
                ?? .unavailable("Not reported for this account")
        }
        for discovered in discoveredWindows(snapshot) {
            guard let window = snapshot.window(discovered.window) else { continue }
            values[discovered.id] = .percent(window.usedPercent)
        }
        for (suffix, window) in [("sessionReset", "session"), ("weeklyReset", "weekly")] {
            if let reset = snapshot.window(window)?.resetsAt {
                values[base + suffix] = .seconds(max(0, reset.timeIntervalSince(now)))
            } else {
                values[base + suffix] = .unavailable(snapshot.window(window) == nil
                                                     ? "Not reported for this account" : "No reset time reported")
            }
        }
        values[base + "account"] = snapshot.accountEmail.map { .text($0) }
            ?? .unavailable("This login does not name its account")
        values[base + "plan"] = snapshot.plan.map { .text($0) } ?? .unavailable("Plan not reported")

        switch provider {
        case .claude:
            // A disabled extra-usage allowance is a real $0.00, not a missing value.
            values[base + "extraUsage"] = snapshot.extraUsage.map { .currency($0.usedDollars) }
                ?? .unavailable("Extra usage not reported")
            values[base + "claudeCodeShare"] = snapshot.breakdown.first { $0.id == "claude_code" }
                .map { .percent($0.percent) } ?? .unavailable("No weekly breakdown reported")
        case .codex:
            values[base + "credits"] = snapshot.creditsRemaining.map { .count($0) } ?? .unavailable("Credits not reported")
            values[base + "creditsValue"] = snapshot.creditDollars.map { .currency($0) } ?? .unavailable("Credits not reported")
            values[base + "resets"] = snapshot.resetCredits.map { .count(Double($0.available)) }
                ?? .unavailable("Reset credits not reported")
        }
        return values
    }

    private static func spendValues(base: String, spend: SpendSummary?) -> [String: AIUsageValue] {
        func all(_ value: AIUsageValue) -> [String: AIUsageValue] {
            [base + "spendToday": value, base + "spend7d": value, base + "spend30d": value]
        }
        guard let spend else { return all(.unavailable("Estimated spend has not been scanned yet")) }
        // Tokens from models with no published rate are left out of the dollars; a total that quietly
        // ignored part of the work would be worse than saying so.
        if spend.last30Days == 0, !spend.unpricedModels.isEmpty {
            return all(.unavailable("No published rate for \(spend.unpricedModels.prefix(2).joined(separator: ", "))"))
        }
        return [base + "spendToday": .currency(spend.today),
                base + "spend7d": .currency(spend.last7Days),
                base + "spend30d": .currency(spend.last30Days)]
    }

    private static func errorText(_ result: Result<UsageSnapshot, UsageError>) -> String {
        if case .failure(let error) = result { return error.localizedDescription }
        return "Unavailable"
    }
}
