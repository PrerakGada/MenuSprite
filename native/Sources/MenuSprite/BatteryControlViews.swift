import SwiftUI

/// A whole-percent slider with its value on the right, so a charge level can be
/// dragged rather than clicked up one step at a time.
struct LabeledSlider: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 175, alignment: .leading)
            Slider(value: Binding(get: { Double(value) },
                                  set: { value = min(range.upperBound, max(range.lowerBound, Int($0.rounded()))) }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
            Text("\(value)%").monospacedDigit().frame(width: 46, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue("\(value) percent")
    }
}

/// A battery bar showing the measured level, what the level is heading toward
/// while a control runs, and the saved limit. The fill colour reports the
/// hardware state — charging, running from the battery, or neither — instead of
/// whatever was last commanded.
struct BatteryGauge: View {
    let percent: Int?
    let target: Int?
    let limit: Int?
    let chargingNow: Bool
    let onBattery: Bool
    /// When set, the limit line can be dragged; the value is applied on release.
    var setLimit: ((Int) -> Void)? = nil
    @State private var dragging: Int?

    private var fill: Color {
        if onBattery { return .orange }
        if chargingNow { return .green }
        return .secondary
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: .quaternaryLabelColor))
                if let percent {
                    Capsule().fill(fill.opacity(0.85))
                        .frame(width: max(6, width * CGFloat(percent) / 100))
                }
                marker(at: dragging ?? limit, in: width, color: setLimit == nil ? .primary.opacity(0.55) : .accentColor)
                if dragging == nil { marker(at: target, in: width, color: .accentColor) }
                if let dragging {
                    Text("\(dragging)%").font(.caption.bold()).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 5).background(Capsule().fill(Color.accentColor))
                        .offset(x: min(width - 40, width * CGFloat(dragging) / 100 + 4))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard setLimit != nil else { return }
                dragging = min(100, max(21, Int((value.location.x / width * 100).rounded())))
            }.onEnded { _ in
                if let dragging { setLimit?(dragging) }
                dragging = nil
            })
        }
        .frame(height: 16)
        .accessibilityElement()
        .accessibilityLabel("Battery level")
        .accessibilityValue(percent.map { "\($0) percent" } ?? "unknown")
    }

    @ViewBuilder
    private func marker(at value: Int?, in width: CGFloat, color: Color) -> some View {
        if let value, (0...100).contains(value) {
            Rectangle().fill(color).frame(width: 2, height: 16)
                .offset(x: min(width - 2, width * CGFloat(value) / 100))
        }
    }
}
