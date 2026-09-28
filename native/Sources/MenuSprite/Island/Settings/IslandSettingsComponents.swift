import AppKit
import IslandKit
import SwiftUI

// The pieces every tab of Settings › Dynamic Island is built from, so the four tabs read as one page:
// titled cards, choice cards, icon rows, destination rows and the Accessibility hint.

enum IslandSettingsStyle {
    static let margin: CGFloat = 28
    static let cardPadding: CGFloat = 20
    static let cardRadius: CGFloat = 18
    static let cardFill = Color.primary.opacity(0.045)
    static let choiceFill = Color.primary.opacity(0.055)
    static let choiceRadius: CGFloat = 12
    static let iconTile: CGFloat = 30
    static let rowGap: CGFloat = 12

    static func textWidth(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width)
    }
}

/// A rounded card with an optional heading.
struct IslandSettingsCard<Content: View>: View {
    var title: String?
    var spacing: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if let title { Text(title).font(.system(size: 15, weight: .semibold)) }
            content
        }
        .padding(IslandSettingsStyle.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: IslandSettingsStyle.cardRadius, style: .continuous).fill(IslandSettingsStyle.cardFill))
    }
}

/// One option among several, drawn as a card: an illustration over a label, tinted when chosen.
struct IslandChoiceCard<Artwork: View>: View {
    let title: String
    let selected: Bool
    var enabled = true
    var minHeight: CGFloat = 84
    var help: String?
    @ViewBuilder var artwork: Artwork
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                artwork
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .background(RoundedRectangle(cornerRadius: IslandSettingsStyle.choiceRadius, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.14) : IslandSettingsStyle.choiceFill))
            .overlay(RoundedRectangle(cornerRadius: IslandSettingsStyle.choiceRadius, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.9) : .clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: IslandSettingsStyle.choiceRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .help(help ?? "")
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension IslandChoiceCard where Artwork == IslandChoiceSymbol {
    init(title: String, symbol: String, selected: Bool, enabled: Bool = true, help: String? = nil, action: @escaping () -> Void) {
        self.init(title: title, selected: selected, enabled: enabled, help: help, artwork: { IslandChoiceSymbol(name: symbol) }, action: action)
    }
}

struct IslandChoiceSymbol: View {
    let name: String
    var body: some View {
        Image(systemName: name).font(.system(size: 21, weight: .regular)).frame(height: 26)
    }
}

/// A small accent-tinted square holding a row's symbol.
struct IslandSettingsIcon: View {
    let symbol: String
    var tint: Color = .accentColor
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: IslandSettingsStyle.iconTile, height: IslandSettingsStyle.iconTile)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.14)))
    }
}

/// A section's coloured tile, as in the island's own gallery; grey while the section is hidden.
struct IslandSectionTile: View {
    let section: IslandSectionID
    var size: CGFloat = 22
    var dimmed = false
    var body: some View {
        Image(systemName: section.symbol)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(dimmed ? Color.gray.opacity(0.45) : section.tint.color))
    }
}

/// Icon, title and optional caption, with a control on the trailing edge.
struct IslandSettingsRow<Trailing: View>: View {
    let symbol: String
    let title: String
    var caption: String?
    var enabled = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: IslandSettingsStyle.rowGap) {
            IslandSettingsIcon(symbol: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let caption {
                    Text(caption).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            trailing
        }
        .opacity(enabled ? 1 : 0.5)
        .disabled(!enabled)
    }
}

/// A switch row bound to one island setting.
struct IslandSwitchRow: View {
    let symbol: String
    let title: String
    var caption: String?
    var enabled = true
    @Binding var isOn: Bool

    var body: some View {
        IslandSettingsRow(symbol: symbol, title: title, caption: caption, enabled: enabled) {
            Toggle(title, isOn: $isOn).toggleStyle(.switch).labelsHidden()
        }
    }
}

/// "Dynamic Island | Separate window" for one destination. The choice sits beside the title while the
/// row fits, drops under the title text otherwise, and becomes a pop-up menu when even that is too narrow.
struct IslandDestinationRow: View {
    static let islandTitle = "Dynamic Island"
    static let windowTitle = "Separate window"

    let symbol: String
    let title: String
    var caption: String?
    /// Why the row cannot be used on this Mac; the row is disabled and shows it.
    var reason: String?
    let width: CGFloat
    @Binding var inIsland: Bool

    var body: some View {
        let leading = IslandSettingsStyle.iconTile + IslandSettingsStyle.rowGap
        let segments = IslandSettingsStyle.textWidth(Self.islandTitle) + IslandSettingsStyle.textWidth(Self.windowTitle) + 48
        let menu = IslandSettingsStyle.textWidth(Self.windowTitle) + 44
        let placement = IslandChoiceRowFit.placement(available: width, leading: leading,
                                                     titleWidth: IslandSettingsStyle.textWidth(title), controlWidth: segments, menuWidth: menu)
        let note = reason ?? caption
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: IslandSettingsStyle.rowGap) {
                IslandSettingsIcon(symbol: symbol)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13))
                    if let note, placement == .beside { captionText(note) }
                }
                Spacer(minLength: 16)
                if placement == .beside { segmented }
            }
            switch placement {
            case .beside: EmptyView()
            case .underTitle: under(leading) { segmented }
            case .menuUnderTitle: under(leading) { menuPicker }
            case .menuUnderIcon: under(0) { menuPicker }
            }
        }
        .disabled(reason != nil)
        .opacity(reason == nil ? 1 : 0.55)
    }

    private var segmented: some View {
        Picker(title, selection: $inIsland) {
            Text(Self.islandTitle).tag(true)
            Text(Self.windowTitle).tag(false)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var menuPicker: some View {
        Picker(title, selection: $inIsland) {
            Text(Self.islandTitle).tag(true)
            Text(Self.windowTitle).tag(false)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }

    private func captionText(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func under<Control: View>(_ indent: CGFloat, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            control()
            if let note = reason ?? caption { captionText(note) }
        }
        .padding(.leading, indent)
    }
}

/// Asks the person to allow Accessibility in MenuSprite's Permissions window. It never prompts itself.
struct IslandAccessibilityHint: View {
    let message: String
    let openPermissions: () -> Void

    var body: some View {
        HStack(spacing: IslandSettingsStyle.rowGap) {
            IslandSettingsIcon(symbol: "accessibility", tint: .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility is off").font(.system(size: 13, weight: .medium))
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            Button("Open Permissions…", action: openPermissions)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.09)))
    }
}

/// Binding helpers onto the settings store: each write is one `update`.
extension IslandSettingsStore {
    func binding<Value: Equatable>(_ keyPath: WritableKeyPath<IslandSettings, Value>) -> Binding<Value> {
        Binding(get: { self.value[keyPath: keyPath] }, set: { new in self.update { $0[keyPath: keyPath] = new } })
    }

    /// A slider's value snapped to `step` as it is written, so the slider itself needs no tick marks.
    func binding(_ keyPath: WritableKeyPath<IslandSettings, Double>, step: Double) -> Binding<Double> {
        Binding(get: { self.value[keyPath: keyPath] }, set: { new in
            let snapped = ((new / step).rounded() * step * 1000).rounded() / 1000
            self.update { $0[keyPath: keyPath] = snapped }
        })
    }
}
