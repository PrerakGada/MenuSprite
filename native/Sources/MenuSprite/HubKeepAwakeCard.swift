import AppKit
import SwiftUI

/// Keep Awake in the hub's Tools page: the switch with what it is doing, then every option — the
/// menu-bar icon while active and its colour, the default length, what right-click does, a global
/// shortcut, display sleep, start on open, automation, pointer nudging and closed-lid mode.
struct HubKeepAwakeCard: View {
    @ObservedObject var power: PowerStore
    var openPowerControls: () -> Void = {}
    @AppStorage("MenuSprite.KeepAwakeOptionsOpen") private var optionsOpen = false
    @State private var automationOpen = false
    @State private var shortcutTaken = false
    @State private var pointerAllowed = PointerNudge.allowed
    @State private var lidAttempted = false
    /// `--keep-awake-render` draws every section open without touching the saved disclosure state.
    private let showAll: Bool

    init(power: PowerStore, openPowerControls: @escaping () -> Void = {}, showAll: Bool = false) {
        self.power = power; self.openPowerControls = openPowerControls; self.showAll = showAll
        _automationOpen = State(initialValue: showAll)
    }

    var body: some View {
        HubCard(title: "Keep awake") {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.system(size: 14, weight: .medium))
                    if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { power.awake }, set: { $0 ? power.startAwake() : power.stopAwake() }))
                    .toggleStyle(.switch).labelsHidden()
                    .accessibilityLabel("Keep this Mac awake").accessibilityIdentifier("hub-keep-awake")
            }
            disclosure("Options", open: $optionsOpen)
            if optionsOpen || showAll { options }
            if power.helperInstalled {
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep going with the lid closed").font(.system(size: 14, weight: .medium))
                        Text(lidStatus.text).font(.system(size: 11)).foregroundStyle(lidStatus.warning ? .orange : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: Binding(get: { power.snapshot.lidActive }, set: { on in
                        lidAttempted = true
                        on ? power.startLid() : power.stopLid()
                    }))
                    .toggleStyle(.switch).labelsHidden().disabled(power.busy || lidBlockedByOther)
                    .accessibilityLabel("Keep going with the lid closed").accessibilityIdentifier("hub-keep-awake-lid")
                }
            }
        }
        // The lid switch depends on state only the root helper reads (who disabled sleep, if anyone).
        .onAppear { if power.helperInstalled { power.refreshBatteryStatus() } }
    }

    /// Sleep is already off, but not by MenuSprite: taking it over would let MenuSprite turn sleep
    /// back on underneath whoever set it, so the helper refuses and the card says why.
    private var lidBlockedByOther: Bool { power.snapshot.sleepDisabled == true && !power.snapshot.lidActive }
    private var lidStatus: (text: String, warning: Bool) {
        if power.snapshot.lidActive {
            let limit = power.duration > 0 ? AwakeDurations.title(power.duration) : "24 hours at most"
            return ("Sleep fully disabled for \(limit). Mind the power and heat.", false)
        }
        if lidBlockedByOther {
            let vorssaint = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier?.localizedCaseInsensitiveContains("vorssaint") == true }
            return (vorssaint
                    ? "Already on through Vorssaint, which disabled sleep itself. Turn off its \u{201C}Keep going with the lid closed\u{201D} to let MenuSprite own it."
                    : "System sleep is already disabled by another app or setting. Turn that off to let MenuSprite own it.", true)
        }
        if lidAttempted, let notice = power.notice { return (notice, true) }
        if power.snapshot.pluggedIn == false { return ("Needs the charger connected (and battery above 20%)", false) }
        return ("Disables all sleep, lid included, while on power", false)
    }

    private var headline: String {
        if power.awake {
            if let until = power.manualUntil { return "Active until \(until.formatted(date: .omitted, time: .shortened))" }
            return power.awakeReason.hasPrefix("Until stopped") ? "Active until you turn it off" : "Active · \(power.awakeReason)"
        }
        return power.duration == 0 ? "Keep awake until you turn it off" : "Keep awake for \(AwakeDurations.title(power.duration))"
    }
    private var detail: String? {
        if power.awake { return power.awakeReason.hasPrefix("Until") && !power.awakeReason.contains("·") ? nil : power.awakeReason }
        return power.awakeReason == "MenuSprite is allowing sleep" ? nil : power.awakeReason
    }

    @ViewBuilder private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Active icon").font(.system(size: 13, weight: .medium)); Spacer()
                Text(power.awakeIcon.title).font(.system(size: 12)).foregroundStyle(.secondary) }
            HStack(spacing: 6) {
                ForEach(AwakeIcon.allCases) { icon in
                    Button { power.awakeIcon = icon; power.settingsChanged() } label: {
                        iconPreview(icon).frame(maxWidth: .infinity).frame(height: 30)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(icon == power.awakeIcon ? Color.accentColor : .clear, lineWidth: 1.5))
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).help(icon.title).accessibilityLabel(icon.title)
                        .accessibilityAddTraits(icon == power.awakeIcon ? .isSelected : [])
                }
            }
            HStack { Text("Active icon colour").font(.system(size: 13, weight: .medium)); Spacer()
                Text(power.awakeTint.title).font(.system(size: 12)).foregroundStyle(.secondary) }
            HStack(spacing: 6) {
                ForEach(AwakeTint.allCases) { tint in
                    Button { power.awakeTint = tint; power.settingsChanged() } label: {
                        Group {
                            if let color = tint.color { Circle().fill(Color(nsColor: color)).frame(width: 16, height: 16) }
                            else { Image(systemName: "circle.slash").font(.system(size: 15)).foregroundStyle(.secondary) }
                        }
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .background(tint == power.awakeTint ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(tint == power.awakeTint ? Color.accentColor : .clear, lineWidth: 1.5))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).help(tint.title).accessibilityLabel(tint.title)
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))

        row("timer", "Default length") {
            Picker("", selection: Binding(get: { power.duration }, set: { power.duration = $0; power.settingsChanged() })) {
                ForEach(AwakeDurations.all, id: \.self) { Text(AwakeDurations.title($0)).tag($0) }
            }.labelsHidden().fixedSize()
        }
        row("cursorarrow.click.2", "Right-click on the icon") {
            Picker("", selection: Binding(get: { power.rightClick }, set: { power.rightClick = $0; power.settingsChanged() })) {
                ForEach(AwakeRightClick.allCases) { Text($0.title).tag($0) }
            }.labelsHidden().fixedSize()
        }
        row("keyboard", "Shortcut", note: shortcutTaken ? "Another app already uses that shortcut." : nil) {
            IslandShortcutRecorder(shortcut: Binding(get: { power.awakeShortcut }, set: {
                power.awakeShortcut = $0; power.settingsChanged(); shortcutTaken = !power.applyAwakeShortcut()
            })).controlSize(.small)
        }
        switchRow("display", "Allow the display to sleep", Binding(get: { !power.keepDisplay }, set: { power.keepDisplay = !$0 }))
        switchRow("play.circle", "Keep awake when MenuSprite opens", $power.awakeOnLaunch)

        Button { automationOpen.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: "bolt").frame(width: 18).foregroundStyle(.secondary)
                Text("Automation").font(.system(size: 13, weight: .medium))
                Spacer()
                Text(automationSummary).font(.system(size: 12)).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(automationOpen ? 90 : 0))
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("hub-keep-awake-automation")
        if automationOpen { automation.padding(.leading, 26) }

        switchRow("cursorarrow.motionlines", "Move pointer slightly", Binding(get: { power.jiggle }, set: { on in
            if on && !PointerNudge.allowed { PanelInteraction.hold(for: 3); PointerNudge.requestAccess() }
            pointerAllowed = PointerNudge.allowed
            power.jiggle = on
        }), note: power.jiggle && !pointerAllowed ? "Needs Accessibility access for MenuSprite (System Settings › Privacy & Security)." : nil)
        if power.jiggle {
            row(nil, "Every") {
                Picker("", selection: Binding(get: { power.jiggleMinutes }, set: { power.jiggleMinutes = $0; power.settingsChanged() })) {
                    ForEach([1, 2, 5, 10], id: \.self) { Text("\($0) min").tag($0) }
                }.labelsHidden().pickerStyle(.segmented).fixedSize()
            }.padding(.leading, 26)
        }
    }

    @ViewBuilder private var automation: some View {
        VStack(alignment: .leading, spacing: 8) {
            if power.automationPaused && power.hasRules {
                HStack {
                    Text("Rules are paused until you resume them.").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Resume") { power.resumeRules() }.controlSize(.small)
                }
            }
            Text("Turn on by itself when").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            switchRow(nil, "Power is connected", $power.autoAC)
            switchRow(nil, "An external display is connected", $power.autoDisplay)
            HStack {
                Text(power.appRules.isEmpty ? "No app rules" : "While \(power.appRules.values.sorted().joined(separator: ", ")) runs")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Apps…", action: openPowerControls).controlSize(.small).help("Choose apps in Power Controls")
            }
            Text("Hold back when").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.top, 2)
            switchRow(nil, "Running on battery", $power.acOnly)
            switchRow(nil, "The screen is locked", $power.pauseWhenLocked)
            row(nil, "Battery falls below") {
                Picker("", selection: Binding(get: { power.batteryFloor }, set: { power.batteryFloor = $0; power.settingsChanged() })) {
                    Text("Never").tag(0); ForEach([10, 20, 30, 50], id: \.self) { Text("\($0)%").tag($0) }
                }.labelsHidden().fixedSize()
            }
        }
    }

    private var automationSummary: String {
        guard power.hasRules else { return "Off" }
        return power.automationPaused ? "Paused" : "On"
    }

    private func iconPreview(_ icon: AwakeIcon) -> some View {
        let color = power.awakeTint.color.map { Color(nsColor: $0) } ?? .primary
        return Group {
            if let art = AwakeIconArt.image(icon: icon, tint: .none, size: NSSize(width: 28, height: 18)) {
                Image(nsImage: art).renderingMode(.template).foregroundStyle(color)
            } else {
                Image(systemName: icon.symbol).foregroundStyle(color)
            }
        }
    }

    private func disclosure(_ title: String, open: Binding<Bool>) -> some View {
        Button { open.wrappedValue.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(open.wrappedValue ? 90 : 0))
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
            }.foregroundStyle(.secondary).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("hub-keep-awake-options")
    }

    private func row<Trailing: View>(_ symbol: String?, _ title: String, note: String? = nil,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary) }
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 8)
                trailing()
            }
            if let note { Text(note).font(.system(size: 11)).foregroundStyle(.orange).padding(.leading, symbol == nil ? 0 : 26) }
        }
    }

    private func switchRow(_ symbol: String?, _ title: String, _ value: Binding<Bool>, note: String? = nil) -> some View {
        row(symbol, title, note: note) {
            Toggle("", isOn: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0; power.settingsChanged() }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
    }
}
