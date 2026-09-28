import Foundation

/// Decides when an accessory's battery is worth one warning. A device warns once when it falls to
/// 20% and not again until a real reading shows it back at 25% or more, so noise around the line
/// (21, 20, 21, 20) and repeated low readings never nag. The first reading of each device only
/// records where it stands: an accessory that is already low when the alerts start is not news.
public struct AccessoryBatteryWatch: Sendable {
    public static let warnAt = 20
    public static let rearmAt = 25
    /// Devices remembered at most; the least recently seen is forgotten first.
    public static let capacity = 128

    public struct Outcome: Equatable, Sendable {
        /// Devices that just crossed down to the warning level, lowest first.
        public var warnings: [AccessoryReading] = []
        /// Devices a fresh reading showed back at the re-arm level, whose queued warning is stale.
        public var recovered: [AccessoryIdentity] = []
    }

    private struct Episode {
        var isLow: Bool
        var consumedAt: Date
        var touched: UInt64
    }

    /// Readings observed before this moment are left over from before the alerts started.
    public let activatedAt: Date
    private var episodes: [AccessoryIdentity: Episode] = [:]
    private var clock: UInt64 = 0

    public init(activatedAt: Date) {
        self.activatedAt = activatedAt
    }

    public var rememberedCount: Int { episodes.count }

    /// Takes a merged set of readings. A reading counts only when it was observed after the alerts
    /// started and after the last reading counted for that device, and its level is valid; an
    /// invalid or missing level neither warns nor re-arms.
    public mutating func consume(_ readings: [AccessoryReading]) -> Outcome {
        var outcome = Outcome()
        for reading in readings {
            guard reading.observedAt > activatedAt, let level = reading.level.warningLevel, (0...100).contains(level) else { continue }
            let identity = reading.identity
            clock += 1
            guard var episode = episodes[identity] else {
                episodes[identity] = Episode(isLow: level <= Self.warnAt, consumedAt: reading.observedAt, touched: clock)
                evictIfNeeded()
                continue
            }
            guard reading.observedAt > episode.consumedAt else { continue }
            episode.consumedAt = reading.observedAt
            episode.touched = clock
            if level >= Self.rearmAt {
                episode.isLow = false
                outcome.recovered.append(identity)
            } else if level <= Self.warnAt, !episode.isLow {
                episode.isLow = true
                outcome.warnings.append(reading)
            }
            episodes[identity] = episode
        }
        outcome.warnings.sort { a, b in
            let (x, y) = (a.level.warningLevel ?? 0, b.level.warningLevel ?? 0)
            if x != y { return x < y }
            if a.kind != b.kind { return a.kind < b.kind }
            return a.identity.name < b.identity.name
        }
        return outcome
    }

    private mutating func evictIfNeeded() {
        guard episodes.count > Self.capacity,
              let oldest = episodes.min(by: { $0.value.touched < $1.value.touched })?.key else { return }
        episodes[oldest] = nil
    }
}
