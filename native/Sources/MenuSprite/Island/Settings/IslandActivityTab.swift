import IslandKit
import SwiftUI

/// Activity: what the closed island shows at rest, whether it may cover the menus, and which notices
/// it raises.
struct IslandActivityTab: View {
    @ObservedObject var model: IslandSettingsModel
    @ObservedObject var environment: IslandEnvironment
    @ObservedObject var settings: IslandSettingsStore
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            atRest
            indicators
        }
    }

    // MARK: At rest

    private var atRest: some View {
        IslandSettingsCard(title: "At rest") {
            HStack(spacing: 12) {
                ForEach(IslandRestContent.allCases, id: \.self) { rest in
                    let reason = unavailableReason(rest)
                    IslandChoiceCard(title: rest.title, selected: settings.value.atRest == rest, enabled: reason == nil,
                                     minHeight: 96, help: reason) {
                        IslandRestPill(rest: rest)
                    } action: {
                        settings.update { $0.atRest = rest }
                    }
                }
            }
            IslandSwitchRow(symbol: "menubar.rectangle", title: "Show over the menus",
                            caption: "Keeps the timer, music and other live activity on screen when the menu bar is full, drawing over the menus beside the camera.",
                            isOn: settings.binding(\.coversMenus))
                .padding(.top, 4)
        }
    }

    /// AI limits needs the AI Agents section; a saved choice survives while it is away.
    private func unavailableReason(_ rest: IslandRestContent) -> String? {
        guard rest == .aiLimits else { return nil }
        let agents = environment.availability(of: .agents)
        if let reason = agents.reason { return "Needs the AI Agents section. \(reason)" }
        return settings.value.isVisible(.agents) ? nil : "Show “AI Agents” on the Content tab to rest on AI limits."
    }

    // MARK: Indicators

    private var indicators: some View {
        let states = IslandIndicatorID.allCases.map { ($0, environment.availability(of: $0)) }
        let anyReason = states.contains { $0.1.reason != nil }
        return IslandSettingsCard(title: "Indicators") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 10)], spacing: 10) {
                ForEach(states, id: \.0) { indicator, availability in
                    IslandOptionCard(title: indicator.title, symbol: indicator.symbol,
                                     included: settings.value.indicators.contains(indicator), availability: availability,
                                     toggle: { settings.update { $0.setIndicator(indicator, !$0.indicators.contains(indicator)) } },
                                     minHeight: anyReason ? 124 : 84)
                }
            }
            if settings.value.indicators.contains(.accessories), environment.availability(of: .accessories).isAvailable {
                Text("Shows accessories as they connect, and warns once when one's battery drops to 20%.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            let available = Set(states.filter { $0.1.isAvailable }.map(\.0))
            if IslandSettingsHints.indicatorsNeedAccessibility(settings.value, available: available, trusted: model.accessibilityTrusted) {
                IslandAccessibilityHint(message: "The volume, brightness and keyboard-light keys reach the island through Accessibility.",
                                        openPermissions: { environment.showPermissions() })
            }
        }
    }
}

/// A closed island in miniature, as each "At rest" choice would look.
struct IslandRestPill: View {
    let rest: IslandRestContent

    var body: some View {
        HStack(spacing: 0) {
            switch rest {
            case .nothing:
                EmptyView()
            case .battery:
                Image(systemName: "battery.75percent").font(.system(size: 11))
                Spacer(minLength: 12)
                Text("76%").font(.system(size: 9, weight: .semibold).monospacedDigit())
            case .music:
                Image(systemName: "music.note").font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 12)
                Image(systemName: "waveform").font(.system(size: 10, weight: .semibold))
            case .aiLimits:
                Image(systemName: "sparkles").font(.system(size: 11))
                Spacer(minLength: 12)
                Text("62%").font(.system(size: 9, weight: .semibold).monospacedDigit())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(width: width, height: 26)
        .background(Capsule().fill(Color.black))
        .accessibilityHidden(true)
    }

    private var width: CGFloat {
        switch rest {
        case .nothing: 56
        case .battery: 88
        case .music: 76
        case .aiLimits: 84
        }
    }
}
