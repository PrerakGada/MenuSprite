import IslandKit
import SwiftUI

/// Behavior: how the island opens, which display it lives on, where MenuSprite's panels open, and
/// whether screen captures include it.
struct IslandBehaviorTab: View {
    @ObservedObject var environment: IslandEnvironment
    @ObservedObject var settings: IslandSettingsStore
    let width: CGFloat

    /// Rows sit inside a card's padding.
    private var rowWidth: CGFloat { width - 2 * IslandSettingsStyle.cardPadding }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            opening
            display
            destinations
            IslandSettingsCard(title: "Privacy") {
                IslandSwitchRow(symbol: "eye", title: "Show in screenshots and videos",
                                caption: "When off, screenshots and screen recordings leave the island out.",
                                isOn: settings.binding(\.showInCaptures))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: settings.value.opening)
    }

    // MARK: Opening

    private var opening: some View {
        IslandSettingsCard(title: "Opening") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(IslandOpening.allCases, id: \.self) { opening in
                    IslandChoiceCard(title: opening.title, symbol: Self.symbol(opening), selected: settings.value.opening == opening) {
                        settings.update { $0.opening = opening }
                    }
                }
            }
            if settings.value.opening.usesHover { activationTime.transition(.opacity) }
            IslandSwitchRow(symbol: "hand.draw", title: "Dynamic Island gestures",
                            caption: settings.value.gestures
                                ? "Scroll down on the island to open it, and up over its top row to close it. Swipe sideways over music to skip tracks. Lists still scroll as usual."
                                : nil,
                            isOn: settings.binding(\.gestures))
            IslandSwitchRow(symbol: "waveform", title: "Haptic feedback", isOn: settings.binding(\.haptics))
                .help("A light tap on a Force Touch trackpad when the island opens, changes page or sets timer minutes.")
            IslandSettingsRow(symbol: "arrow.uturn.backward", title: "When reopening") {
                reopenMenu
            }
        }
    }

    private var activationTime: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Activation time").font(.system(size: 13))
                Spacer()
                Text(String(format: "%.2f s", settings.value.hoverDelay))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: settings.binding(\.hoverDelay, step: 0.05), in: IslandSettings.hoverDelayRange)
                .accessibilityLabel("Activation time")
            Text("How long the pointer rests on the island before it opens.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.leading, IslandSettingsStyle.iconTile + IslandSettingsStyle.rowGap)
    }

    private var reopenMenu: some View {
        let options = IslandReopenMenu.options(visible: environment.visibleSections, saved: settings.value.reopen)
        return Picker("When reopening", selection: settings.binding(\.reopen)) {
            ForEach(options.prefix(3)) { option in Text(option.title).tag(option.value) }
            Divider()
            ForEach(options.dropFirst(3)) { option in
                Text(option.title).tag(option.value).disabled(!option.enabled)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }

    static func symbol(_ opening: IslandOpening) -> String {
        switch opening {
        case .click: "cursorarrow"
        case .preview: "rectangle.topthird.inset.filled"
        case .expand: "arrow.up.left.and.arrow.down.right"
        case .hidden: "eye.slash"
        }
    }

    // MARK: Display

    private var display: some View {
        IslandSettingsCard(title: "Display") {
            IslandSwitchRow(symbol: "arrow.down.right.and.arrow.up.left", title: "Hide content in full screen",
                            caption: settings.value.hideInFullScreen
                                ? "In a full-screen app the island shrinks to a plain black camera shape; clicking it still opens the island."
                                : nil,
                            isOn: settings.binding(\.hideInFullScreen))
            HStack(spacing: 12) {
                ForEach(IslandDisplayChoice.allCases, id: \.self) { choice in
                    IslandChoiceCard(title: choice.title, symbol: Self.symbol(choice), selected: settings.value.display == choice) {
                        settings.update { $0.display = choice }
                    }
                }
            }
        }
    }

    static func symbol(_ display: IslandDisplayChoice) -> String {
        switch display {
        case .automatic: "display.2"
        case .builtIn: "laptopcomputer"
        case .main: "display"
        }
    }

    // MARK: Where things open

    private var destinations: some View {
        IslandSettingsCard(title: "Where things open", spacing: 16) {
            IslandDestinationRow(symbol: "bubble.middle.top", title: "Open app panel",
                                 caption: "Where a click on the MenuSprite menu bar icon opens the app panel, on any display.",
                                 width: rowWidth, inIsland: settings.binding(\.appPanelInIsland))
            IslandSwitchRow(symbol: "menubar.rectangle", title: "Hide the menu bar icon",
                            caption: "Settings and the app panel open from the island instead. The icon comes back while the island is off or hidden in full screen.",
                            isOn: settings.binding(\.hideMenuBarIcon))
            destination(.tools, "Tools", symbol: "square.grid.2x2", \.toolsInIsland)
            destination(.clipboard, "Clipboard", symbol: "doc.on.clipboard", \.clipboardInIsland)
            destination(.files, "Files", symbol: "tray.full", \.filesInIsland)
            destination(.captures, "Captures", symbol: "camera.viewfinder", \.capturesInIsland)
            destination(.scratchpad, "Scratchpad", symbol: "note.text", \.scratchpadInIsland)
        }
    }

    /// A feature's destination row; disabled with its section's reason until that feature exists.
    private func destination(_ section: IslandSectionID, _ title: String, symbol: String,
                             _ keyPath: WritableKeyPath<IslandSettings, Bool>) -> some View {
        IslandDestinationRow(symbol: symbol, title: title, reason: environment.availability(of: section).reason,
                             width: rowWidth, inIsland: settings.binding(keyPath))
    }
}
