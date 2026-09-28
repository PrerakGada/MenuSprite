import CoreGraphics
import Foundation

/// The minute ruler's arithmetic: a tape of ticks one minute apart, centred on a fixed pointer, with
/// the selected minute under it. Every value, however it arrives, stays within 1…180.
public enum TimerRuler {
    public static let range = TimerSession.minuteRange
    /// Points between two minute ticks, and the drag or scroll distance of one minute.
    public static let spacing: CGFloat = 14
    /// Ticks this far past either edge are still drawn, so a tick slides in rather than pops.
    public static let overdraw: CGFloat = 16
    /// The share of each side over which ticks fade out.
    public static let fade: CGFloat = 0.12

    public static func clamp(_ minutes: Int) -> Int { min(max(minutes, range.lowerBound), range.upperBound) }

    /// Accessibility and restored values can be anything: infinities go to the nearer end, NaN to
    /// the first minute.
    public static func clamp(_ minutes: Double) -> Int {
        guard !minutes.isNaN else { return range.lowerBound }
        return clamp(Int(max(-1e6, min(1e6, minutes)).rounded()))
    }

    /// Where a minute's tick sits, as an offset from the pointer.
    public static func offset(of minute: Int, selected: Int) -> CGFloat { CGFloat(minute - selected) * spacing }

    /// A click without dragging selects the tick under it.
    public static func minute(atOffset offset: CGFloat, selected: Int) -> Int {
        guard offset.isFinite else { return clamp(selected) }
        return clamp(selected + Int((offset / spacing).rounded()))
    }

    /// The minutes whose ticks fall within the visible width (plus a little overdraw).
    public static func visibleMinutes(selected: Int, width: CGFloat) -> ClosedRange<Int> {
        let reach = Int(((max(0, width) / 2 + overdraw) / spacing).rounded(.up))
        let low = clamp(selected - reach), high = clamp(selected + reach)
        return low...high
    }

    /// Opacity of a tick at `offset` from the centre of a ruler `width` wide: full in the middle,
    /// fading to nothing over the outer 12% of each side.
    public static func edgeOpacity(offset: CGFloat, width: CGFloat) -> CGFloat {
        let half = width / 2
        guard half > 0 else { return 0 }
        let band = width * fade
        let fromEdge = half - abs(offset)
        guard band > 0 else { return fromEdge >= 0 ? 1 : 0 }
        return min(1, max(0, fromEdge / band))
    }

    /// Minute 1 and every fifth minute carry a label.
    public static func hasLabel(_ minute: Int) -> Bool { minute == 1 || minute % 5 == 0 }

    /// "25", then "1h00", "1h05"… from an hour; never a colon.
    public static func label(_ minute: Int) -> String {
        minute < 60 ? "\(minute)" : TimerFormat.hours(Double(minute) * 60, limit: Double(range.upperBound) * 60)
    }

    public enum Key: Sendable { case left, right, up, down, home, end }

    /// Left/Down one less, Right/Up one more, Home the first minute, End the last.
    public static func minute(after key: Key, selected: Int) -> Int {
        switch key {
        case .left, .down: clamp(selected - 1)
        case .right, .up: clamp(selected + 1)
        case .home: range.lowerBound
        case .end: range.upperBound
        }
    }

    /// One drag across the ruler. Moving 14 pt changes one minute; dragging left brings higher minutes
    /// under the pointer (the tape follows the finger). Past either end the anchor moves with the
    /// pointer, so reversing responds at once instead of first crossing a dead zone.
    public struct Drag: Equatable, Sendable {
        public private(set) var value: Int
        private var anchorX: CGFloat

        public init(startX: CGFloat, value: Int) {
            anchorX = startX
            self.value = TimerRuler.clamp(value)
        }

        /// The minute after the pointer moved to `x`.
        public mutating func move(to x: CGFloat) -> Int {
            guard x.isFinite else { return value }
            let steps = Int(((anchorX - x) / TimerRuler.spacing).rounded(.towardZero))
            guard steps != 0 else { return value }
            let target = value + steps
            let clamped = TimerRuler.clamp(target)
            if clamped == target {
                anchorX -= CGFloat(steps) * TimerRuler.spacing
            } else {
                anchorX = x
            }
            value = clamped
            return value
        }
    }

    /// Scroll-wheel and trackpad input. A wheel notch moves one tick; trackpad deltas add up in points
    /// until they cross a tick, so small movements do not keep changing it. The larger axis wins.
    public struct Scroll: Equatable, Sendable {
        private var carried: CGFloat = 0
        public init() {}

        /// Minutes to add for one scroll event. Horizontal movement follows the finger like a drag
        /// (content moving right shows lower minutes); scrolling up adds minutes.
        public mutating func steps(deltaX: CGFloat, deltaY: CGFloat, precise: Bool) -> Int {
            guard deltaX.isFinite, deltaY.isFinite else { return 0 }
            let amount = abs(deltaX) > abs(deltaY) ? -deltaX : deltaY
            guard amount != 0 else { return 0 }
            guard precise else { return amount > 0 ? 1 : -1 }
            carried += amount
            let steps = Int((carried / TimerRuler.spacing).rounded(.towardZero))
            carried -= CGFloat(steps) * TimerRuler.spacing
            return steps
        }

        /// A gesture or its momentum ended or was cancelled.
        public mutating func reset() { carried = 0 }
    }
}
