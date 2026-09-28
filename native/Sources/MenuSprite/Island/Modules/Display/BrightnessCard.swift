import IslandKit
import SwiftUI

/// The Controls page's brightness level, as a card of its own or as a row in the shared levels card.
/// Until "Control displays" is on it offers the way to settings instead of a slider.
struct BrightnessLevelView: View {
    @ObservedObject var controller: BrightnessController
    @ObservedObject var settings: IslandDisplaySettings
    let environment: IslandEnvironment
    let style: IslandCardStyle
    /// False in the settings preview, which never talks to a monitor.
    let readsMonitors: Bool

    var body: some View {
        Group {
            switch style {
            case .card(let height): card(tall: height >= 88)
            case .row: row
            }
        }
        .onAppear { controller.cardAppeared(readsMonitors: readsMonitors) }
        .onDisappear { controller.cardDisappeared() }
    }

    private var display: BrightnessDisplay? { settings.controlDisplays ? controller.current : nil }
    private var level: Double? { display.flatMap { controller.levels[$0.id] } }

    private func card(tall: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                sun
                Text("Brightness")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if display != nil {
                    // A short card has no room for the display line, so its readout becomes the display menu.
                    if tall { IslandPercentText(value: level) } else { readoutMenu }
                }
            }
            .frame(height: 16)
            control.frame(height: 28)
            if tall, let display {
                IslandMenuButton(environment: environment, entries: entries) {
                    IslandDeviceLabel(symbol: display.isBuiltIn ? "laptopcomputer" : "display", title: display.name)
                }
                .frame(maxWidth: 154, alignment: .leading)
                .frame(height: 14)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, tall ? 10 : 5)
        // Tall cards start at the top so side-by-side headers line up whether or not a device line shows.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: tall ? .top : .center)
    }

    private var row: some View {
        HStack(spacing: 6) {
            sun
            if display != nil {
                control.frame(height: 24)
                readoutMenu
            } else {
                Text("Brightness")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 4)
                control
            }
        }
        .frame(height: 24)
    }

    private var sun: some View {
        Image(systemName: "sun.max.fill")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 18, height: 16)
    }

    @ViewBuilder private var control: some View {
        if !settings.controlDisplays {
            Button("Settings…") { environment.actions.openSettings(.controls) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(IslandStyle.secondaryText)
                .fixedSize()
                .frame(maxWidth: style == .row ? nil : .infinity, alignment: .leading)
        } else if let display {
            IslandLevelSlider(value: Binding(get: { level ?? 0.5 }, set: { controller.setLevel($0, for: display) }),
                              accessibilityLabel: "Brightness")
        } else if controller.hasScanned {
            Text("No display found.")
                .font(.system(size: 10))
                .foregroundStyle(IslandStyle.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Color.clear
        }
    }

    private var readoutMenu: some View {
        IslandMenuButton(environment: environment, entries: entries) { IslandReadoutLabel(value: level) }
    }

    /// Every display with a brightness route, the card's own checked.
    private func entries() -> [IslandMenuEntry] {
        controller.displays.map { display in
            .item(display.name, checked: display.id == controller.current?.id) { [controller] in controller.chosen = display.id }
        }
    }
}

/// The opt-in that lets the island set display brightness and answer the brightness keys. For the
/// Controls options in Settings › Content.
struct IslandDisplayOptionsView: View {
    @ObservedObject private var settings = IslandDisplaySettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Control displays", isOn: $settings.controlDisplays)
            Text("Lets the island set the brightness of this Mac’s display and of external monitors that accept DDC, and answer the brightness keys while it shows notices.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
