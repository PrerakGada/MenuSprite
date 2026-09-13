import Foundation

/// Response parsing shared by the Claude and Codex mappers, matching OpenUsage's tolerances.
enum UsageParse {
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func number(_ value: Any?) -> Double? {
        CredentialJSON.number(value).flatMap { $0.isFinite ? $0 : nil }
    }

    static func text(_ value: Any?) -> String? { CredentialJSON.nonEmpty(value) }

    /// ISO 8601 text (any fractional precision, `Z` or an offset, a space for `T`, a ` UTC` suffix)
    /// or an epoch number in seconds or milliseconds.
    static func date(_ value: Any?) -> Date? {
        if let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return isoDate(text) ?? Double(text).map(epoch)
        }
        return number(value).map(epoch)
    }

    static func epoch(_ value: Double) -> Date {
        Date(timeIntervalSince1970: abs(value) < 1e10 ? value : value / 1000)
    }

    static func isoDate(_ raw: String) -> Date? {
        var text = raw
        if text.hasSuffix(" UTC") { text = String(text.dropLast(4)) + "Z" }
        if let range = text.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"#, options: .regularExpression) {
            text.replaceSubrange(range, with: text[range].replacingOccurrences(of: " ", with: "T"))
        }
        guard text.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}"#, options: .regularExpression) != nil else { return nil }
        // ISO8601DateFormatter accepts at most millisecond fractions; the API can send microseconds.
        if let range = text.range(of: #"\.\d+"#, options: .regularExpression) {
            let digits = String(text[range].dropFirst())
            text.replaceSubrange(range, with: "." + String((digits + "000").prefix(3)))
        }
        if text.range(of: #"(Z|[+-]\d{2}:?\d{2})$"#, options: .regularExpression) == nil { text += "Z" }
        return CredentialJSON.date(iso8601: text)
    }

    static func titleCased(_ text: String, separator: Character, lowercasingTail: Bool) -> String {
        text.split(separator: separator).map { word in
            word.prefix(1).uppercased() + (lowercasingTail ? word.dropFirst().lowercased() : String(word.dropFirst()))
        }.joined(separator: " ")
    }

    /// "max" + "default_claude_max_20x" → "Max 20x", as OpenUsage formats it.
    static func claudePlan(subscriptionType: String?, rateLimitTier: String?) -> String? {
        guard let raw = subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let base = titleCased(raw, separator: " ", lowercasingTail: true)
        guard let tier = rateLimitTier, let match = tier.range(of: #"\d+x"#, options: .regularExpression) else { return base }
        return "\(base) \(tier[match])"
    }

    static func codexPlan(_ value: Any?) -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "prolite": return "Pro 5x"
        case "pro": return "Pro 20x"
        case "self_serve_business_prolite": return "Business Premium"
        default: return titleCased(raw, separator: "_", lowercasingTail: false)
        }
    }

    static func retryAfterSeconds(_ response: HTTPResponse, now: Date) -> Int? {
        guard let raw = response.header("retry-after")?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = Int(raw), seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: raw).map { max(0, Int($0.timeIntervalSince(now).rounded(.up))) }
    }
}

extension UsageSnapshot {
    func withNotice(_ notice: String?) -> UsageSnapshot {
        UsageSnapshot(provider: provider, accountEmail: accountEmail, plan: plan, windows: windows,
                      extraUsage: extraUsage, creditsRemaining: creditsRemaining, creditDollars: creditDollars,
                      resetCredits: resetCredits, breakdown: breakdown, fetchedAt: fetchedAt, notice: notice)
    }
}
