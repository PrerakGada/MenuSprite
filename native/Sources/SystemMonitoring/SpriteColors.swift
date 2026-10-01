import AppKit

/// Colours as sprites store them: "RRGGBB", or the name of one of Apple's system colours, which adapt to
/// the menu bar's and the board's light or dark appearance (a fixed hex orange that reads well on a dark
/// bar is too pale on a light one). "inherit" and "auto" are resolved by whoever draws.
public enum SpriteColors {
    public static let names = ["red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue", "indigo", "purple",
                               "pink", "brown", "gray", "white", "black"]

    public static func system(_ name: String) -> NSColor? {
        switch name.lowercased() {
        case "red": .systemRed; case "orange": .systemOrange; case "yellow": .systemYellow; case "green": .systemGreen
        case "mint": .systemMint; case "teal": .systemTeal; case "cyan": .systemCyan; case "blue": .systemBlue
        case "indigo": .systemIndigo; case "purple": .systemPurple; case "pink": .systemPink; case "brown": .systemBrown
        case "gray", "grey": .systemGray; case "white": .white; case "black": .black
        default: nil
        }
    }

    /// A stored colour, or nil for "inherit", "auto" and anything unreadable.
    public static func color(_ stored: String) -> NSColor? {
        if let named = system(stored) { return named }
        let hex = stored.hasPrefix("#") ? String(stored.dropFirst()) : stored
        guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else { return nil }
        return NSColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}

/// What a preview draws in place of a value's live reading, so an agent can see every branch of its rules
/// (a disk at 12 GB, a limit "over" its pace) without making it happen. Used only by agent renders.
public struct ValueOverride: Sendable, Equatable {
    public var text: String?
    public var number: Double?
    /// "on track", "ahead" or "over" for a Claude/Codex limit.
    public var pace: String?
    /// Drawn as unavailable, as a failed command or an unread sensor would be: shows the `is missing` branch.
    public var missing: Bool
    public init(text: String? = nil, number: Double? = nil, pace: String? = nil, missing: Bool = false) {
        self.text = text; self.number = number; self.pace = pace; self.missing = missing
    }
}
