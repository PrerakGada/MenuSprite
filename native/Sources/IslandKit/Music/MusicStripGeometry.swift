import CoreGraphics
import Foundation

/// How far a box drawn in a closed strip's wing must sit from the strip's end so it keeps the 5 pt
/// gap from the silhouette, not just from the straight edge. A strip is barely taller than its
/// corners, so its lower half is one arc: the box's own lower corner must stay inside that arc.
public enum IslandEdgeInset {
    public static let gap: CGFloat = 5

    /// `boxHeight` is vertically centred in a strip `stripHeight` tall; `boxRadius` is the box's own
    /// corner radius.
    public static func inset(stripHeight: CGFloat, boxHeight: CGFloat, boxRadius: CGFloat, gap: CGFloat = gap) -> CGFloat {
        let shoulder = min(14, 0.19 * stripHeight)
        let corner = min(28, 0.34 * stripHeight)
        let straight = shoulder + gap
        let radius = max(0, min(boxRadius, boxHeight / 2))
        let boxCornerY = (stripHeight + boxHeight) / 2 - radius
        let arcCentreY = stripHeight - corner
        guard boxCornerY > arcCentreY else { return straight }
        let allowed = corner - gap - radius
        let dy = boxCornerY - arcCentreY
        // Too tall to clear the arc anywhere inside it: sit beyond the arc.
        guard allowed > dy else { return shoulder + corner + gap }
        let dx = (allowed * allowed - dy * dy).squareRoot()
        return max(straight, shoulder + corner - dx - radius)
    }
}

/// The compact music strip's measurements: the cover in the left wing, seven bars in the right, both
/// derived from the camera height so they read the same beside any notch.
public struct MusicStripGeometry: Equatable, Sendable {
    public static let barCount = 7
    public static let barWidth: CGFloat = 1.8
    public static let simulatedWing: CGFloat = 56

    public let stripHeight: CGFloat
    public let isPhysical: Bool

    public init(stripHeight: CGFloat, isPhysical: Bool) {
        self.stripHeight = min(64, max(16, stripHeight))
        self.isPhysical = isPhysical
    }

    public var coverSide: CGFloat { max(0, min(26, stripHeight - 2 * IslandEdgeInset.gap)) }

    /// Concentric with the strip's lower corners when the cover nearly fills the strip.
    public var coverRadius: CGFloat {
        let side = coverSide
        guard side > 0 else { return 0 }
        let corner = min(28, stripHeight * 0.34)
        if stripHeight - side <= 20 {
            return min(max(corner - (stripHeight - side) / 2, side * 0.2), side / 2)
        }
        return side * 0.28
    }

    public var coverInset: CGFloat { IslandEdgeInset.inset(stripHeight: stripHeight, boxHeight: coverSide, boxRadius: coverRadius) }

    public var barsHeight: CGFloat { min(16, max(6, stripHeight - 10)) }
    public var barsWidth: CGFloat { MusicBars.width(count: Self.barCount, barWidth: Self.barWidth) }
    public var barsInset: CGFloat {
        IslandEdgeInset.inset(stripHeight: stripHeight, boxHeight: barsHeight, boxRadius: Self.barWidth / 2)
    }

    /// Each wing: exactly enough for the cover or the bars plus its inset on a physical camera
    /// (34 pt beside a 32 pt notch); 56 pt beside a simulated one.
    public var wing: CGFloat {
        guard isPhysical else { return Self.simulatedWing }
        return max(coverInset + coverSide, barsInset + barsWidth).rounded(.up)
    }
}

/// The equalizer bars' motion. Each bar bobs between a low and a high height on its own period, the
/// centre bars taller; the compositor runs it, so it costs no per-frame work in the app.
public enum MusicBars {
    public struct Bar: Equatable, Sendable {
        /// Horizontal centre.
        public var x: CGFloat
        public var low: CGFloat
        public var high: CGFloat
        public var duration: Double
        public var timeOffset: Double
    }

    public static let spacing: CGFloat = 1.85

    public static func width(count: Int, barWidth: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count - 1) * spacing * barWidth + barWidth
    }

    public static func bar(_ index: Int, count: Int, barWidth: CGFloat, height: CGFloat) -> Bar {
        let centre = CGFloat(count - 1) / 2
        let distance = abs(CGFloat(index) - centre) / max(1, centre)
        let envelope = CGFloat(pow(Double(max(0, 1 - distance)), 1.5))
        return Bar(x: CGFloat(index) * spacing * barWidth + barWidth / 2,
                   low: max(barWidth, height * (0.12 + 0.25 * envelope)),
                   high: max(barWidth, height * (0.12 + 0.88 * envelope)),
                   duration: Double.pi / (5.2 + 0.61 * Double(index)),
                   timeOffset: 0.17 * Double(index))
    }

    /// A bar's height from a live level (0…1).
    public static func height(level: Double, barWidth: CGFloat, height: CGFloat) -> CGFloat {
        max(barWidth, height * (0.1 + 0.9 * CGFloat(min(1, max(0, level)))))
    }

    /// With fewer bars than bands, bar i reads band ⌊(i + 0.5) / bars × bands⌋.
    public static func band(forBar index: Int, bars: Int, bands: Int) -> Int {
        guard bars > 0, bands > 0 else { return 0 }
        return min(bands - 1, Int((Double(index) + 0.5) / Double(bars) * Double(bands)))
    }
}
