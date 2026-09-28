import Foundation

/// One scroll event, reduced to what the island's gestures need.
public struct IslandScrollSample: Equatable, Sendable {
    public enum Phase: Sendable, Equatable { case none, began, changed, ended, cancelled, mayBegin }
    public var deltaX: Double
    public var deltaY: Double
    /// Trackpads and Magic Mouse report precise deltas; wheels report line steps.
    public var precise: Bool
    /// "Natural" scrolling: the device reports deltas inverted from its movement.
    public var inverted: Bool
    public var phase: Phase
    public var momentum: Bool
    public var timestamp: Double
    public var modifiers: Bool

    public init(deltaX: Double, deltaY: Double, precise: Bool = true, inverted: Bool = false, phase: Phase = .changed,
                momentum: Bool = false, timestamp: Double, modifiers: Bool = false) {
        self.deltaX = deltaX; self.deltaY = deltaY; self.precise = precise; self.inverted = inverted
        self.phase = phase; self.momentum = momentum; self.timestamp = timestamp; self.modifiers = modifiers
    }
}

/// Which gestures the place a sequence started in allows. Decided once at the start of a sequence.
public struct IslandGestureOrigin: Equatable, Sendable {
    public var vertical: Bool
    public var horizontal: Bool
    public var islandOpen: Bool
    public init(vertical: Bool, horizontal: Bool, islandOpen: Bool) {
        self.vertical = vertical; self.horizontal = horizontal; self.islandOpen = islandOpen
    }
    public static let none = IslandGestureOrigin(vertical: false, horizontal: false, islandOpen: false)
}

public enum IslandGestureAction: Equatable, Sendable { case open, close, nextTrack, previousTrack }

/// Two-finger swipes over the island: down opens, up over the header or music closes, left/right over
/// music changes track. One decision per physical sequence; momentum never acts.
public struct IslandGestureRecognizer: Sendable {
    public static let verticalThreshold: Double = 24
    public static let horizontalThreshold: Double = 40
    public static let lockTravel: Double = 4
    public static let lockRatio: Double = 1.5
    public static let wheelGap: Double = 0.35
    public static let wheelScale: Double = 24

    private var origin: IslandGestureOrigin?
    private var phased = false
    private var lastTimestamp: Double?
    private var accumulated = (x: 0.0, y: 0.0)
    private var locked: Axis?
    private var fired = false

    private enum Axis { case vertical, horizontal }

    public init() {}

    public mutating func reset() {
        origin = nil; phased = false; lastTimestamp = nil
        accumulated = (0, 0); locked = nil; fired = false
    }

    /// Feeds one event. `originIfStarting` is asked only when a new sequence begins.
    public mutating func handle(_ sample: IslandScrollSample, originIfStarting: () -> IslandGestureOrigin) -> IslandGestureAction? {
        guard sample.deltaX.isFinite, sample.deltaY.isFinite, sample.timestamp.isFinite else { reset(); return nil }
        if sample.modifiers { reset(); return nil }
        if let last = lastTimestamp, sample.timestamp < last { reset() }
        if sample.momentum { if phased { reset() }; return nil }
        switch sample.phase {
        case .ended, .cancelled:
            reset(); return nil
        case .began, .mayBegin:
            reset()
            phased = true
            origin = originIfStarting()
            if sample.phase == .mayBegin { lastTimestamp = sample.timestamp; return nil }
        case .changed:
            // An orphan event after a sequence ended (or one whose start we never saw) cannot act.
            guard phased, origin != nil else { return nil }
        case .none:
            if phased { reset() }
            if let last = lastTimestamp, sample.timestamp - last > Self.wheelGap { reset() }
            if origin == nil { origin = originIfStarting() }
        }
        lastTimestamp = sample.timestamp
        guard let origin, !fired else { return nil }
        let sign = sample.inverted ? 1.0 : -1.0
        let scale = sample.precise ? 1.0 : Self.wheelScale
        let dx = sample.deltaX * sign * scale
        let dy = sample.deltaY * sign * scale
        accumulated.x += dx
        accumulated.y += dy
        if locked == nil {
            let ax = abs(accumulated.x), ay = abs(accumulated.y)
            if ay >= Self.lockTravel, ay >= Self.lockRatio * ax { locked = .vertical }
            else if sample.precise, ax >= Self.lockTravel, ax >= Self.lockRatio * ay { locked = .horizontal }
            else { return nil }
        }
        switch locked {
        case .vertical:
            guard origin.vertical, abs(accumulated.y) >= Self.verticalThreshold else { return nil }
            // Positive travel is "down" under both natural scrolling and a classic wheel.
            if accumulated.y > 0, !origin.islandOpen { fired = true; return .open }
            if accumulated.y < 0, origin.islandOpen { fired = true; return .close }
            return nil
        case .horizontal:
            guard origin.horizontal, abs(accumulated.x) >= Self.horizontalThreshold else { return nil }
            fired = true
            return accumulated.x < 0 ? .nextTrack : .previousTrack
        case nil:
            return nil
        }
    }
}
