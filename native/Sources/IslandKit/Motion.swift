import CoreGraphics
import Foundation

/// A spring described the way SwiftUI describes one: a perceptual duration and a bounce (0 = no
/// overshoot). Its position runs from 0 to 1.
public struct IslandSpring: Equatable, Sendable {
    public var duration: Double
    public var bounce: Double

    public init(duration: Double, bounce: Double) { self.duration = duration; self.bounce = max(0, min(0.95, bounce)) }

    public static let growWidth = IslandSpring(duration: 0.44, bounce: 0.25)
    public static let growHeight = IslandSpring(duration: 0.38, bounce: 0.22)
    public static let shrinkWidth = IslandSpring(duration: 0.30, bounce: 0)
    public static let shrinkHeight = IslandSpring(duration: 0.26, bounce: 0)

    var omega: Double { 2 * .pi / max(0.01, duration) }
    var damping: Double { 1 - bounce }

    /// Progress at time `t` from rest at 0 towards 1.
    public func value(at t: Double) -> Double {
        guard t > 0 else { return 0 }
        let w = omega, z = damping
        if z >= 1 {
            return 1 - exp(-w * t) * (1 + w * t)
        }
        let wd = w * sqrt(1 - z * z)
        return 1 - exp(-z * w * t) * (cos(wd * t) + (z * w / wd) * sin(wd * t))
    }

    /// The largest fraction of its travel this spring passes its target by.
    public var overshootFraction: Double {
        guard damping < 1 else { return 0 }
        return exp(-damping * .pi / sqrt(1 - damping * damping))
    }

    /// The same spring with its bounce reduced so a travel of `travel` points never passes the target
    /// by more than `limit` points.
    public func limited(travel: Double, limit: Double) -> IslandSpring {
        guard travel > 0, overshootFraction * travel > limit else { return self }
        let allowed = max(1e-6, limit / travel)
        let log = Foundation.log(allowed)
        let zeta = -log / sqrt(.pi * .pi + log * log)
        return IslandSpring(duration: duration, bounce: max(0, 1 - zeta))
    }
}

/// A precomputed resize: sizes sampled at 120 per second from the size on screen to the target.
public struct IslandMotionPlan: Equatable, Sendable {
    public var sizes: [CGSize]
    public var duration: Double
    /// When every moving side first comes within 1% of its travel; floating buttons emerge then.
    public var arrival: Double
    /// The largest size any frame reaches, before margins.
    public var envelope: CGSize

    public static let sampleRate: Double = 120
    public static let overshootLimit: CGFloat = 12

    public var isEmpty: Bool { sizes.count < 2 }
    public var target: CGSize { sizes.last ?? .zero }

    /// Plans a resize from `start` to `target`. Growing sides bounce a little (never more than 12 pt
    /// past the target); shrinking sides never pass it. Height is quicker than width, so an opening
    /// island drops ahead of widening.
    public static func plan(from start: CGSize, to target: CGSize, reduceMotion: Bool = false) -> IslandMotionPlan {
        guard start != target else {
            return IslandMotionPlan(sizes: [target], duration: 0, arrival: 0, envelope: target)
        }
        if reduceMotion {
            return IslandMotionPlan(sizes: [start, target], duration: 0, arrival: 0,
                                    envelope: CGSize(width: max(start.width, target.width), height: max(start.height, target.height)))
        }
        let dw = Double(target.width - start.width), dh = Double(target.height - start.height)
        let widthSpring = (dw > 0 ? IslandSpring.growWidth : IslandSpring.shrinkWidth).limited(travel: abs(dw), limit: Double(overshootLimit))
        let heightSpring = (dh > 0 ? IslandSpring.growHeight : IslandSpring.shrinkHeight).limited(travel: abs(dh), limit: Double(overshootLimit))
        let step = 1 / sampleRate
        let cap = 2.0
        var times: [Double] = []
        var t = 0.0
        while t <= cap + 1e-9 { times.append(t); t += step }
        // Find the first sample from which the motion stays settled, by scanning backwards.
        var last = times.count - 1
        while last > 0 {
            let time = times[last - 1]
            let w = abs(dw * (1 - widthSpring.value(at: time)))
            let h = abs(dh * (1 - heightSpring.value(at: time)))
            if w > 0.5 || h > 0.5 { break }
            last -= 1
        }
        let count = min(max(last, Int((0.1 * sampleRate).rounded())), Int((0.6 * sampleRate).rounded())) + 1
        var sizes: [CGSize] = []
        var envelope = CGSize(width: max(start.width, target.width), height: max(start.height, target.height))
        var arrival: Double?
        for index in 0..<count {
            let time = times[index]
            if index == count - 1 { sizes.append(target); break }
            let pw = widthSpring.value(at: time), ph = heightSpring.value(at: time)
            var width = Double(start.width) + dw * pw
            var height = Double(start.height) + dh * ph
            // Shrinking never undershoots: a narrowing island never dips below its target.
            if dw < 0 { width = max(width, Double(target.width)) }
            if dh < 0 { height = max(height, Double(target.height)) }
            width = max(0, width); height = max(0, height)
            let size = CGSize(width: width, height: height)
            sizes.append(size)
            envelope.width = max(envelope.width, size.width)
            envelope.height = max(envelope.height, size.height)
            if arrival == nil {
                let wOK = dw == 0 || abs(1 - pw) <= 0.01
                let hOK = dh == 0 || abs(1 - ph) <= 0.01
                if wOK && hOK { arrival = time }
            }
        }
        let duration = Double(count - 1) * step
        return IslandMotionPlan(sizes: sizes, duration: duration, arrival: arrival ?? duration,
                                envelope: CGSize(width: ceil(envelope.width), height: ceil(envelope.height)))
    }
}
