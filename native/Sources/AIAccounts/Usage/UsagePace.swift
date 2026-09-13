import Foundation

/// A cumulative allowance for the current whole day/hour of a provider's limit window.
/// Buckets start at the provider's reset anniversary, not local midnight.
public struct UsagePace: Equatable, Sendable {
    public enum Level: String, Sendable { case onTrack, ahead, over }
    public let level: Level
    public let bucket: Int
    public let bucketCount: Int
    public let allowance: Double
    public let warningCeiling: Double

    public static func evaluate(_ window: UsageWindow, now: Date) -> Self? {
        guard let duration = window.windowSeconds, let reset = window.resetsAt,
              window.usedPercent.isFinite, (0...100).contains(window.usedPercent) else { return nil }
        let count: Int
        switch duration {
        case 604_800: count = 7
        case 18_000: count = 5
        default: return nil
        }
        let remaining = reset.timeIntervalSince(now)
        // A reset that has passed is an old reading, never a fresh zero-usage window.
        guard remaining.isFinite, remaining > 0, remaining <= duration else { return nil }
        let bucket = min(count, Int(floor((duration - remaining) / (duration / Double(count)))) + 1)
        let allowance = Double(bucket) * 100 / Double(count)
        let warningCeiling = min(100, Double(bucket + 1) * 100 / Double(count))
        let level: Level
        if window.usedPercent >= 100 { level = .over }
        else if window.usedPercent <= allowance { level = .onTrack }
        else if window.usedPercent <= warningCeiling { level = .ahead }
        else { level = .over }
        return Self(level: level, bucket: bucket, bucketCount: count,
                    allowance: allowance, warningCeiling: warningCeiling)
    }
}
