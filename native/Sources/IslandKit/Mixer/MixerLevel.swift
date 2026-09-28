import Foundation

/// Per-app and system levels as the mixer stores and shows them. A level is a linear gain: 1 is the
/// app's own volume (100 %), apps go up to 2 (200 %, boosted through the limiter), the system output
/// and microphone stop at 1.
public enum MixerLevel {
    public static let unity = 1.0
    public static let appMaximum = 2.0
    public static let systemMaximum = 1.0
    /// Levels within half a percent of 100 % count as untouched: never stored, never tapped.
    public static let unityTolerance = 0.005

    public static func isUnity(_ gain: Double) -> Bool { abs(gain - unity) <= unityTolerance }
    public static func isBoosting(_ gain: Double) -> Bool { gain > unity + unityTolerance }

    /// Clamped to 0…maximum; nil for NaN and infinities, which must never reach a device or a tap.
    public static func clamp(_ gain: Double, maximum: Double) -> Double? {
        guard gain.isFinite else { return nil }
        return min(maximum, max(0, gain))
    }

    /// The whole percent a label shows.
    public static func percent(_ gain: Double) -> Int { Int((gain * 100).rounded()) }

    /// Reads a typed percentage: digits with the locale's decimal separator (or a point), an optional
    /// sign and an optional "%" suffix. Returns the gain clamped to 0…maximum, or nil when the text is
    /// not a plain finite number (so "abc", "inf", "1e3" and hex are refused).
    public static func parsePercent(_ text: String, maximum: Double, decimalSeparator: String = Locale.current.decimalSeparator ?? ".") -> Double? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasSuffix("%") { body = String(body.dropLast()).trimmingCharacters(in: .whitespaces) }
        if !decimalSeparator.isEmpty, decimalSeparator != "." { body = body.replacingOccurrences(of: decimalSeparator, with: ".") }
        var digits = Substring(body)
        if let sign = digits.first, sign == "+" || sign == "-" { digits = digits.dropFirst() }
        let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
        guard !digits.isEmpty, parts.count <= 2, parts.contains(where: { !$0.isEmpty }),
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let value = Double(body), value.isFinite else { return nil }
        return clamp(value / 100, maximum: maximum)
    }
}

/// Muting an app remembers the level it had, so unmuting puts it back (or at 100 % when it had none).
public struct MixerMute: Equatable, Sendable {
    public var gain: Double
    public var lastAudible: Double?

    public init(gain: Double, lastAudible: Double? = nil) {
        self.gain = gain
        self.lastAudible = lastAudible
    }

    public var isMuted: Bool { gain <= 0 }

    public func toggled() -> MixerMute {
        if isMuted { return MixerMute(gain: lastAudible.flatMap { $0 > 0 ? $0 : nil } ?? MixerLevel.unity, lastAudible: nil) }
        return MixerMute(gain: 0, lastAudible: gain)
    }
}
