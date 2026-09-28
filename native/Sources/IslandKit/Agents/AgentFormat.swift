import Foundation

/// How the AI Agents section writes times, tokens, dollars and model names.
public enum AgentFormat {
    /// A stopwatch: "0:42", "12:05", "1:02:05".
    public static func elapsed(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        let hours = total / 3600, minutes = total % 3600 / 60, secs = total % 60
        if hours > 0 { return "\(hours):" + pad(minutes) + ":" + pad(secs) }
        return "\(minutes):" + pad(secs)
    }

    /// Tokens, shortened without ever rounding up: "950", "4.2K", "48K", "120K", "1.5M".
    public static func tokens(_ count: Int, locale: Locale = .current) -> String {
        let value = max(0, count)
        let mark = locale.decimalSeparator ?? "."
        func oneDecimal(_ scaled: Int, _ unit: String) -> String {
            let whole = scaled / 10, tenth = scaled % 10
            return tenth == 0 ? "\(whole)\(unit)" : "\(whole)\(mark)\(tenth)\(unit)"
        }
        switch value {
        case ..<1_000: return "\(value)"
        case ..<10_000: return oneDecimal(value / 100, "K")
        case ..<1_000_000: return "\(value / 1_000)K"
        case ..<10_000_000: return oneDecimal(value / 100_000, "M")
        default: return "\(value / 1_000_000)M"
        }
    }

    /// API value in dollars: cents under $100, whole dollars from $100, thousands from $10,000.
    public static func cost(_ dollars: Double, locale: Locale = .current) -> String {
        let value = max(0, dollars.isFinite ? dollars : 0)
        if value < 100 {
            let cents = Int((value * 100).rounded())
            return "$\(cents / 100)\(locale.decimalSeparator ?? ".")" + pad(cents % 100)
        }
        if value < 10_000 { return "$\(Int(value.rounded()))" }
        return "$\(Int(value / 1_000))K"
    }

    /// A finished task's length: "42s", "4m 12s", "1h 05m".
    public static func duration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds.rounded() : 0))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m " + pad(total % 60) + "s" }
        return "\(total / 3600)h " + pad(total % 3600 / 60) + "m"
    }

    /// Time until a limit renews: "3d 4h" from a day, "2h 05m" from an hour, "12m" below, and never
    /// less than a minute or in seconds.
    public static func countdown(_ seconds: Double) -> String {
        let minutes = max(1, Int((max(0, seconds.isFinite ? seconds : 0) / 60).rounded(.up)))
        if minutes >= 1440 { return "\(minutes / 1440)d \(minutes % 1440 / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h " + pad(minutes % 60) + "m" }
        return "\(minutes)m"
    }

    /// "Just now", "5 min ago", "2 hr ago", "3 days ago".
    public static func ago(_ seconds: Double) -> String {
        let value = max(0, seconds.isFinite ? seconds : 0)
        if value < 60 { return "Just now" }
        if value < 3600 { return "\(Int(value / 60)) min ago" }
        if value < 86_400 { return "\(Int(value / 3600)) hr ago" }
        let days = Int(value / 86_400)
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }

    /// A model id as people say it: "claude-opus-5-5" → "Opus 5.5", "claude-haiku-4-5-20251001" →
    /// "Haiku 4.5", "gpt-6-astra" → "GPT-6 Astra". Snapshot dates, "latest", provider prefixes and
    /// tags are dropped. Nil for Claude Code's local stand-in ("<synthetic>").
    public static func modelName(_ id: String) -> String? {
        var name = id.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty, !name.hasPrefix("<") else { return nil }
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        for tag in ["@", "["] { if let mark = name.firstIndex(of: Character(tag)) { name = String(name[..<mark]) } }
        if let claude = name.range(of: "claude-") { name = String(name[claude.upperBound...]) }
        for suffix in [#"-latest$"#, #"-\d{4}-?\d{2}-?\d{2}$"#] {
            name = name.replacingOccurrences(of: suffix, with: "", options: .regularExpression)
        }
        let parts = name.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return nil }
        if parts[0] == "gpt" || parts[0].hasPrefix("gpt") {
            let head = parts[0] == "gpt" && parts.count > 1 ? "GPT-" + parts[1] : parts[0].uppercased()
            let rest = parts.dropFirst(parts[0] == "gpt" && parts.count > 1 ? 2 : 1).map(capitalized)
            return ([head] + rest).joined(separator: " ")
        }
        // Claude: a family word and version digits, in either order ("opus-5-5", "3-5-sonnet").
        let words = parts.filter { !$0.allSatisfy(\.isNumber) }
        let digits = parts.filter { $0.allSatisfy(\.isNumber) }
        let version = digits.joined(separator: ".")
        let family = words.map(capitalized).joined(separator: " ")
        if family.isEmpty { return version }
        return version.isEmpty ? family : family + " " + version
    }

    /// The folder a session works in, by name. A worktree Claude Code made belongs to the repository
    /// it was made from.
    public static func projectName(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let root = path.range(of: "/.claude/worktrees/").map { String(path[..<$0.lowerBound]) } ?? path
        let name = URL(fileURLWithPath: root).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    private static func capitalized(_ word: String) -> String { word.prefix(1).uppercased() + word.dropFirst() }
    private static func pad(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
}
