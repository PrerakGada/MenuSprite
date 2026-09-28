import IslandKit
import SwiftUI

/// Layout: the island with its floating buttons to arrange, then its size and outline.
struct IslandLayoutTab: View {
    @ObservedObject var model: IslandSettingsModel
    @ObservedObject var environment: IslandEnvironment
    @ObservedObject var settings: IslandSettingsStore
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            IslandLayoutCanvasView(environment: environment, settings: settings, width: width) {
                model.reveal(.controls)
            }
            Text("Click + to add a button, drag a button to move it, and click a button to change it.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            sizeCard
            IslandSettingsCard {
                IslandSwitchRow(symbol: "capsule", title: "Show outline", isOn: settings.binding(\.outline))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: settings.value.size)
    }

    private var sizeCard: some View {
        IslandSettingsCard(title: "Size") {
            HStack(spacing: 12) {
                ForEach(IslandSize.allCases, id: \.self) { size in
                    IslandChoiceCard(title: size.title, symbol: Self.symbol(size), selected: settings.value.size == size) {
                        settings.update { $0.size = size }
                    }
                }
            }
            if settings.value.size == .custom {
                VStack(alignment: .leading, spacing: 10) {
                    IslandSizeSlider(title: "Width", value: settings.binding(\.customWidth, step: 10), range: IslandSettings.customWidthRange)
                    IslandSizeSlider(title: "Maximum height", value: settings.binding(\.customHeight, step: 10), range: IslandSettings.customHeightRange)
                    Text("The Controls page stays compact; longer pages and lists grow up to this height.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
                .transition(.opacity)
            }
        }
    }

    static func symbol(_ size: IslandSize) -> String {
        switch size {
        case .compact: "arrow.down.and.line.horizontal.and.arrow.up"
        case .spacious: "arrow.up.and.down.square"
        case .custom: "arrow.up.left.and.arrow.down.right"
        }
    }
}

/// A size slider with its value in points.
private struct IslandSizeSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13)).frame(width: 120, alignment: .leading)
            Slider(value: $value, in: range).accessibilityLabel(title)
            Text("\(Int(value.rounded())) pt")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
    }
}
