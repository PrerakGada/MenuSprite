import Foundation

/// Tokens of one request, split the way both providers bill them.
public struct TokenBreakdown: Sendable, Equatable, Codable {
    public var input: Int
    public var cacheWrite5m: Int
    public var cacheWrite1h: Int
    public var cacheRead: Int
    public var output: Int

    public init(input: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0, cacheRead: Int = 0, output: Int = 0) {
        self.input = input; self.cacheWrite5m = cacheWrite5m; self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead; self.output = output
    }

    public var total: Int { input + cacheWrite5m + cacheWrite1h + cacheRead + output }

    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(input: lhs.input + rhs.input, cacheWrite5m: lhs.cacheWrite5m + rhs.cacheWrite5m,
             cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h, cacheRead: lhs.cacheRead + rhs.cacheRead,
             output: lhs.output + rhs.output)
    }

    public static func += (lhs: inout Self, rhs: Self) { lhs = lhs + rhs }
}

/// Dollars per million tokens for one model.
public struct ModelRate: Sendable, Equatable {
    public let input: Double
    public let output: Double
    /// Explicit cache-read rate; `nil` uses the standard fraction of the input rate.
    public let cacheRead: Double?

    public init(input: Double, output: Double, cacheRead: Double? = nil) {
        self.input = input; self.output = output; self.cacheRead = cacheRead
    }
}

/// The one place rates live. Everything here is Anthropic's first-party API pricing as published in the
/// bundled `claude-api` skill's model table, cached 2026-06-24. Nothing is inferred from the models
/// themselves, and no rate is guessed: a model absent from this table is reported as unpriced.
public enum ModelPricing {
    /// Cache writes bill above the input rate: 5-minute writes at 1.25×, 1-hour writes at 2×, from
    /// Anthropic's published caching pricing (checked 13 September 2026). The difference is not
    /// cosmetic here — 1-hour writes dominate the token mix in these logs, so the placeholder 1.25×
    /// this build started with understated every total.
    public static let cacheWrite5mMultiplier = 1.25
    public static let cacheWrite1hMultiplier = 2.0
    /// Cache reads bill at a tenth of the input rate unless the model states its own.
    public static let cacheReadFraction = 0.1
    /// Claude Code writes this in place of a model name for work it ran locally; real tokens, no charge.
    public static let syntheticModel = "<synthetic>"

    public static let ratesUpdated = "2026-06-24 (claude-api skill model table)"

    public static let rates: [String: ModelRate] = [
        "claude-opus-5": ModelRate(input: 5, output: 25),
        "claude-opus-4-8": ModelRate(input: 5, output: 25),
        "claude-opus-4-7": ModelRate(input: 5, output: 25),
        "claude-opus-4-6": ModelRate(input: 5, output: 25),
        "claude-sonnet-5": ModelRate(input: 2, output: 10),
        "claude-sonnet-4-6": ModelRate(input: 3, output: 15),
        "claude-sonnet-4-5": ModelRate(input: 3, output: 15),
        "claude-haiku-4-5": ModelRate(input: 1, output: 5),
        "claude-fable-5": ModelRate(input: 10, output: 50),
        // Claude Fable 5.1 reads cache at 0.025× base input rather than the standard 0.1×, i.e. $0.25/MTok.
        "claude-fable-5-1": ModelRate(input: 10, output: 50, cacheRead: 0.25)
    ]

    /// Trims a provider prefix and a dated snapshot suffix, so `claude-haiku-4-5-20251001` prices as
    /// `claude-haiku-4-5`. Returns the name unchanged when neither applies.
    public static func canonical(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        if let match = name.range(of: #"-\d{8}$"#, options: .regularExpression) { name.removeSubrange(match) }
        return name
    }

    public static func rate(for model: String) -> ModelRate? {
        let name = canonical(model)
        if name == syntheticModel { return ModelRate(input: 0, output: 0, cacheRead: 0) }
        return rates[name]
    }

    /// Dollars for one token breakdown, or `nil` when no published rate covers the model. A `nil` is the
    /// signal to count the tokens and name the model rather than fold an unpriced model into a total.
    public static func cost(_ tokens: TokenBreakdown, model: String) -> Double? {
        guard let rate = rate(for: model) else { return nil }
        let read = rate.cacheRead ?? rate.input * cacheReadFraction
        let dollarsPerMillion = Double(tokens.input) * rate.input
            + Double(tokens.cacheWrite5m) * rate.input * cacheWrite5mMultiplier
            + Double(tokens.cacheWrite1h) * rate.input * cacheWrite1hMultiplier
            + Double(tokens.cacheRead) * read
            + Double(tokens.output) * rate.output
        return dollarsPerMillion / 1_000_000
    }
}
