import AppKit
import IslandKit
import SwiftUI

// Shared visual pieces every island page uses, so sections built separately still look like one thing.

extension IslandTint {
    var color: Color {
        switch self {
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .indigo: .indigo
        case .gray: .gray
        case .brown: .brown
        }
    }
}

enum IslandStyle {
    /// Card and control surfaces inside the black island.
    static let surface = Color.white.opacity(0.075)
    static let surfaceHover = Color.white.opacity(0.12)
    static let secondaryText = Color.white.opacity(0.62)
    static let tertiaryText = Color.white.opacity(0.42)
    static let cardRadius: CGFloat = 18
    static let tileHeight: CGFloat = 74
    static let tileMinWidth: CGFloat = 76
    static let tileSpacing: CGFloat = 8
    static let rowSpacing: CGFloat = 10
}

/// A rounded control surface for cards on island pages.
struct IslandCard<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: IslandStyle.cardRadius, style: .continuous).fill(IslandStyle.surface))
    }
}

/// The island's button look: a soft highlight on hover and press.
struct IslandButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 14
    func makeBody(configuration: Configuration) -> some View {
        IslandButtonBody(configuration: configuration, cornerRadius: cornerRadius)
    }
}

private struct IslandButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let cornerRadius: CGFloat
    @State private var hovering = false
    var body: some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(configuration.isPressed ? 0.14 : (hovering ? 0.07 : 0))))
            .onHover { hovering = $0 }
    }
}

/// A shortcut tile: a 40-pt circle with a symbol over a title of up to two lines.
struct IslandTileView: View {
    let title: String
    let symbol: String
    var isOn = false
    /// Fill and glyph colours when on (keep awake: yellow/black; mute and recording: red/white).
    var onFill: Color = .yellow
    var onGlyph: Color = .black
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(isOn ? onFill : Color.white.opacity(0.075))
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(isOn ? onGlyph : Color.white.opacity(0.85))
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 40, height: 40)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .frame(height: 28, alignment: .top)
            }
            .frame(maxWidth: .infinity, minHeight: IslandStyle.tileHeight, maxHeight: IslandStyle.tileHeight)
        }
        .buttonStyle(IslandButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(title)
    }
}

/// A thin capsule meter, as used by level notices.
struct IslandMeter: View {
    var value: Double
    var tint: Color = .white
    var height: CGFloat = 5
    var body: some View {
        GeometryReader { proxy in
            let clamped = min(1, max(0, value))
            let fill = clamped > 0 ? max(height, proxy.size.width * clamped) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule().fill(tint.opacity(0.9)).frame(width: fill)
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.14), value: value)
    }
}

/// A thick rounded bar with no knob: click or drag anywhere sets the value. AppKit underneath, so
/// keyboard and accessibility work, and one edit spans one drag.
struct IslandLevelSlider: NSViewRepresentable {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var tint: Color = .white
    var enabled = true
    var vertical = false
    /// Optional marker line (for example 100% on a 200% fader).
    var marker: Double?
    /// Optional colour for the part of the fill beyond the marker (a boost shown in orange).
    var overTint: Color?
    /// Called once when a drag (or a keyboard/accessibility change) begins and once when it ends.
    var editingChanged: ((Bool) -> Void)?
    var accessibilityLabel: String = ""

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound,
                              target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        let cell = IslandLevelCell()
        cell.minValue = range.lowerBound
        cell.maxValue = range.upperBound
        cell.doubleValue = value
        cell.coordinator = context.coordinator
        slider.cell = cell
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.isContinuous = true
        slider.isVertical = vertical
        slider.altIncrementValue = (range.upperBound - range.lowerBound) * 0.01
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        guard let cell = slider.cell as? IslandLevelCell else { return }
        cell.tint = NSColor(tint)
        cell.marker = marker
        cell.overTint = overTint.map { NSColor($0) }
        cell.minValue = range.lowerBound
        cell.maxValue = range.upperBound
        slider.isVertical = vertical
        slider.isEnabled = enabled
        slider.setAccessibilityLabel(accessibilityLabel)
        if !context.coordinator.tracking, abs(slider.doubleValue - value) > 1e-9 { slider.doubleValue = value }
        slider.needsDisplay = true
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: IslandLevelSlider
        var tracking = false
        init(_ parent: IslandLevelSlider) { self.parent = parent }

        @objc func changed(_ sender: NSSlider) {
            if tracking {
                parent.value = sender.doubleValue
            } else {
                // A keyboard or accessibility change is its own complete edit.
                parent.editingChanged?(true)
                parent.value = sender.doubleValue
                parent.editingChanged?(false)
            }
        }

        func began() {
            guard !tracking else { return }
            tracking = true
            parent.editingChanged?(true)
        }

        func ended() {
            guard tracking else { return }
            tracking = false
            parent.editingChanged?(false)
        }
    }
}

final class IslandLevelCell: NSSliderCell {
    var tint: NSColor = .white
    var marker: Double?
    var overTint: NSColor?
    weak var coordinator: IslandLevelSlider.Coordinator?

    override func startTracking(at startPoint: NSPoint, in controlView: NSView) -> Bool {
        MainActor.assumeIsolated { coordinator?.began() }
        return super.startTracking(at: startPoint, in: controlView)
    }

    override func stopTracking(last lastPoint: NSPoint, current stopPoint: NSPoint, in controlView: NSView, mouseIsUp flag: Bool) {
        super.stopTracking(last: lastPoint, current: stopPoint, in: controlView, mouseIsUp: flag)
        MainActor.assumeIsolated { coordinator?.ended() }
    }

    override func knobRect(flipped: Bool) -> NSRect { .zero }

    override func drawKnob(_ knobRect: NSRect) {}

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        guard let view = controlView else { return }
        let bounds = view.bounds
        let span = maxValue - minValue
        let fraction = span > 0 ? min(1, max(0, (doubleValue - minValue) / span)) : 0
        if isVertical {
            let thickness = bounds.width * 0.78
            let track = NSRect(x: bounds.midX - thickness / 2, y: bounds.minY, width: thickness, height: bounds.height)
            let radius = thickness / 2
            NSColor.white.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
            var fill = track
            fill.size.height = track.height * fraction
            if view.isFlipped { fill.origin.y = track.maxY - fill.height }
            tint.withAlphaComponent(isEnabled ? 0.92 : 0.3).setFill()
            let fillPath = NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius)
            fillPath.fill()
            if let marker, span > 0 {
                let offset = track.height * CGFloat((marker - minValue) / span)
                let y = view.isFlipped ? track.maxY - offset : track.minY + offset
                if let overTint, doubleValue > marker {
                    NSGraphicsContext.saveGraphicsState()
                    fillPath.addClip()
                    overTint.withAlphaComponent(isEnabled ? 0.92 : 0.3).setFill()
                    (view.isFlipped ? NSRect(x: track.minX, y: track.minY, width: track.width, height: y - track.minY)
                                    : NSRect(x: track.minX, y: y, width: track.width, height: track.maxY - y)).fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
                NSColor.white.withAlphaComponent(0.45).setFill()
                NSRect(x: track.minX, y: y - 0.5, width: track.width, height: 1).fill()
            }
        } else {
            let thickness = bounds.height * 0.78
            let track = NSRect(x: bounds.minX, y: bounds.midY - thickness / 2, width: bounds.width, height: thickness)
            let radius = thickness / 2
            NSColor.white.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
            var fill = track
            fill.size.width = fraction > 0 ? max(thickness, track.width * fraction) : 0
            tint.withAlphaComponent(isEnabled ? 0.92 : 0.3).setFill()
            let fillPath = NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius)
            fillPath.fill()
            if let marker, span > 0 {
                let x = track.minX + track.width * CGFloat((marker - minValue) / span)
                if let overTint, doubleValue > marker {
                    NSGraphicsContext.saveGraphicsState()
                    fillPath.addClip()
                    overTint.withAlphaComponent(isEnabled ? 0.92 : 0.3).setFill()
                    NSRect(x: x, y: track.minY, width: track.maxX - x, height: track.height).fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
                NSColor.white.withAlphaComponent(0.45).setFill()
                NSRect(x: x - 0.5, y: track.minY, width: 1, height: track.height).fill()
            }
        }
    }
}

/// A plain "section not built" or "unavailable" page body.
struct IslandUnavailableView: View {
    let symbol: String
    let message: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 22, weight: .medium)).foregroundStyle(IslandStyle.tertiaryText)
            Text(message).font(.system(size: 12, weight: .medium)).foregroundStyle(IslandStyle.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
