import AppKit
import IslandKit
import SwiftUI

/// The music bars. Plain Core Animation layers, so the bobbing runs in the compositor with no
/// per-frame work in the app; motion runs only while playing, with Reduce Motion off, and while the
/// bars are actually visible (not hidden, window visible and not occluded). Otherwise they rest as dots.
struct MusicBarsView: NSViewRepresentable {
    var count: Int
    var barWidth: CGFloat
    var playing: Bool
    var tint: NSColor

    func makeNSView(context: Context) -> MusicBarsLayerView { MusicBarsLayerView() }

    func updateNSView(_ view: MusicBarsLayerView, context: Context) {
        view.configure(count: count, barWidth: barWidth, playing: playing, tint: tint)
    }

    static func dismantleNSView(_ view: MusicBarsLayerView, coordinator: ()) { view.dismantle() }
}

final class MusicBarsLayerView: NSView {
    private static let animationKey = "island.music.bob"

    private var bars: [CALayer] = []
    private var barWidth: CGFloat = 1.8
    private var playing = false
    private var tint: NSColor = .white
    private var dismantled = false
    private var windowObservers: [NSObjectProtocol] = []
    private var motionObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMotion() }
        }
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    func configure(count: Int, barWidth: CGFloat, playing: Bool, tint: NSColor) {
        guard !dismantled else { return }
        if count != bars.count || barWidth != self.barWidth {
            // A different bar count replaces the bars.
            bars.forEach { $0.removeFromSuperlayer() }
            bars = (0..<count).map { _ in CALayer() }
            bars.forEach { layer?.addSublayer($0) }
            self.barWidth = barWidth
        }
        if tint != self.tint || bars.first?.backgroundColor == nil {
            self.tint = tint
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bars.forEach { $0.backgroundColor = tint.cgColor }
            CATransaction.commit()
        }
        self.playing = playing
        updateMotion()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        guard changed else { return }
        // Geometry changed: place the bars again and restart their motion from the new sizes.
        bars.forEach { $0.removeAnimation(forKey: Self.animationKey) }
        updateMotion()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        if let window, !dismantled {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateMotion() }
                })
            }
        }
        updateMotion()
    }

    override func viewDidHide() { super.viewDidHide(); updateMotion() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateMotion() }

    /// Ends every animation and observation for good.
    func dismantle() {
        dismantled = true
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        if let motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(motionObserver) }
        motionObserver = nil
        bars.forEach { $0.removeAllAnimations() }
    }

    private var shouldMove: Bool {
        guard !dismantled, playing, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, !isHiddenOrHasHiddenAncestor,
              let window, window.isVisible else { return false }
        return window.occlusionState.contains(.visible)
    }

    private func updateMotion() {
        let height = bounds.height
        guard height > 0, !bars.isEmpty else { return }
        let moving = shouldMove
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            let spec = MusicBars.bar(index, count: bars.count, barWidth: barWidth, height: height)
            bar.cornerRadius = barWidth / 2
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: moving ? spec.low : barWidth)
            bar.position = CGPoint(x: spec.x, y: height / 2)
            if moving {
                // Added only when missing, so metadata, tint and layout updates keep the phase.
                guard bar.animation(forKey: Self.animationKey) == nil else { continue }
                let bob = CABasicAnimation(keyPath: "bounds.size.height")
                bob.fromValue = spec.low
                bob.toValue = spec.high
                bob.duration = spec.duration
                bob.autoreverses = true
                bob.repeatCount = .infinity
                bob.timeOffset = spec.timeOffset
                bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bob.isRemovedOnCompletion = false
                bar.add(bob, forKey: Self.animationKey)
            } else {
                bar.removeAnimation(forKey: Self.animationKey)
            }
        }
        CATransaction.commit()
    }
}
