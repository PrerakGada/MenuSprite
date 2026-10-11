import SwiftUI
import PowerControl

/// The Controls page, laid out like System Settings: grouped sections, each row a name on the left and
/// its one control on the right. Explanations sit behind ⓘ; only state and warnings are spelled out.
struct PowerView: View {
    @ObservedObject var store: PowerStore
    /// The limit while its slider is being dragged; applied on release.
    @State private var limitDraft: Double?

    var body: some View {
        VStack(spacing:0) {
            HStack {
                Text(BuildFeatures.powerPageTitle).font(.system(size:25,weight:.semibold,design:.rounded))
                Spacer()
                Button("Refresh") { store.refresh() }.keyboardShortcut("r",modifiers:.command)
            }.padding(.horizontal,24).padding(.vertical,16)
            Divider()
            Form {
                if store.helperState != .on { Section { turnOn } }
                if let notice = store.notice {
                    Section { Label(notice,systemImage:"exclamationmark.circle").foregroundStyle(.orange).textSelection(.enabled) }
                }
                status
                if store.usesSystemLimit { systemLimit } else if store.snapshot.chargeSupported { bandLimit } else {
                    Section("Charge limit") { Label(store.chargeUnsupportedReason,systemImage:"info.circle").foregroundStyle(.secondary) }
                }
                chargeNow
                awake
                rules
                lid
                if store.helperInstalled || store.helperState == .needsApproval { helper }
            }
            .formStyle(.grouped)
        }.frame(minWidth:800,minHeight:650)
        .background(Color(nsColor:.windowBackgroundColor))
    }

    // MARK: Battery

    private var status: some View {
        Section {
            HStack(alignment:.firstTextBaseline,spacing:12) {
                Text(store.snapshot.percent.map { "\($0)%" } ?? "—")
                    .font(.system(size:34,weight:.bold,design:.rounded)).monospacedDigit()
                VStack(alignment:.leading,spacing:2) {
                    Text(store.flowDescription).foregroundStyle(.secondary)
                    if store.runningOnBatteryByChoice {
                        Text("MenuSprite is holding the adapter off").font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer()
                Text(modeLabel).fontWeight(.semibold).multilineTextAlignment(.trailing)
            }
            BatteryGauge(percent: store.snapshot.percent,
                         target: store.usesSystemLimit ? store.activeCeiling : store.snapshot.controlCeiling,
                         limit: store.usesSystemLimit ? (store.saverEnabled ? store.band.upper : nil)
                            : (store.snapshot.chargeSupported ? store.band.upper : nil),
                         chargingNow: (store.snapshot.chargeCurrent ?? 0) > 0,
                         onBattery: store.snapshot.adapterEnabled == false || store.isDraining,
                         setLimit: store.usesSystemLimit && store.canSetLimit ? { store.setLimit($0) } : nil)
                .padding(.vertical,4)
        } header: { titled("Battery",tip:store.snapshot.capability) }
    }

    /// macOS's own charge limit: held by macOS through sleep and restarts, set to any level.
    private var systemLimit: some View {
        Section {
            switchRow("Limit charging","macOS holds the limit through sleep and restarts, even with MenuSprite quit. Above it, the Mac runs from the battery until it gets there. You can also drag the line on the bar.",
                      isOn: Binding(get: { store.saverEnabled }, set: { store.setSaver($0) }), disabled: !store.canSetLimit)
            LabeledContent("Limit") {
                HStack(spacing:10) {
                    Slider(value: Binding(get: { limitDraft ?? Double(store.band.upper) }, set: { limitDraft = $0.rounded() }),
                           in: 21...100) { editing in
                        if !editing, let draft = limitDraft { store.setLimit(Int(draft)); limitDraft = nil }
                    }.frame(width:220)
                    Text("\(Int(limitDraft ?? Double(store.band.upper)))%").monospacedDigit().frame(width:42,alignment:.trailing)
                }
            }.disabled(!store.canSetLimit)
            LabeledContent {
                Picker("Sailing", selection: Binding(get: { store.sailingBand }, set: { store.setSailing($0) })) {
                    ForEach(Sailing.choices, id: \.self) { choice in
                        Text(choice == 0 ? "Off" : "\(choice)% · charge below \(max(0, store.band.upper - choice))%").tag(choice)
                    }
                }.labelsHidden().fixedSize().disabled(!store.canSetLimit)
            } label: {
                named("Sailing","Once the battery reaches the limit, it drifts down this far before charging starts again, instead of topping up every few minutes.")
            }
            switchRow("MagSafe light","Green while holding the limit, amber while charging, blinking while discharging. Needs power controls on.",
                      isOn: Binding(get: { store.ledControl }, set: { store.setLEDControl($0) }), disabled: !store.helperInstalled)
        } header: { Text("Charge limit") } footer: { conflict }
    }

    /// The band, shown only when the firmware can actually hold one.
    private var bandLimit: some View {
        Section {
            LabeledSlider(title:"Charge limit", value:$store.band.upper, range:21...100)
            LabeledSlider(title:"Resume charging below", value:$store.band.lower, range:20...99)
            LabeledContent("") {
                Button("Apply charge limit") { store.battery(.maintain) }
                    .disabled(!store.canControlBattery || !store.band.valid)
            }
        } header: { Text("Charge limit") } footer: {
            if !store.band.valid { Text("Resume level must be below the charge limit.").foregroundStyle(.orange) } else { conflict }
        }
        .onChange(of:store.band) { _,_ in store.settingsChanged() }
    }

    @ViewBuilder private var conflict: some View {
        if let conflict = store.batteryConflict {
            Label("\(conflict) is running. Turn off its charge control and quit it.",systemImage:"exclamationmark.circle").foregroundStyle(.orange)
        }
    }

    /// One-off actions; each ends by itself and the limit takes over again.
    private var chargeNow: some View {
        Section {
            LabeledContent {
                if store.usesSystemLimit {
                    Button(store.topUpActive ? "Stop" : "Top up") { store.toggleTopUp() }
                        .disabled(!store.canSetLimit || (!store.topUpActive && store.snapshot.pluggedIn != true))
                } else {
                    Button("Top up") { store.battery(.topUp) }.disabled(!store.canControlBattery || !store.band.valid)
                }
            } label: { named("Top up to 100%","Charges to 100% once. Your limit returns when you unplug.") }
            LabeledContent {
                if store.usesSystemLimit {
                    Button(store.dischargeActive ? "Stop" : "Discharge") { store.toggleDischarge() }
                        .disabled(!store.canSetLimit || !(store.dischargeActive || store.canDischargeToLimit))
                } else {
                    Button(store.snapshot.mode == .discharge ? "Discharging…" : "Discharge") { store.runOnBattery() }
                        .disabled(!store.canDischarge || !store.band.valid || store.snapshot.mode == .discharge
                                  || (store.snapshot.percent ?? 0) <= store.band.upper)
                }
            } label: { named("Discharge to \(store.band.upper)%","Runs the Mac from the battery with the cable connected until it reaches your limit, with no artificial workload. Stops on unplug, sleep, quit, lost connection or critical heat.") }
            if store.snapshot.mode != .off || store.snapshot.recoveryPending {
                LabeledContent("MenuSprite is controlling the adapter") {
                    Button("Charge normally") { store.stopBattery() }
                }
            }
        } header: { Text("Charge now") } footer: {
            if let reason = store.dischargeReason, reason != store.helperReason, !store.usesSystemLimit {
                Text(reason).foregroundStyle(.orange)
            } else if store.snapshot.pluggedIn != true {
                Text("Connect the power adapter to top up or discharge.").foregroundStyle(.secondary)
            }
        }
    }

    private var modeLabel: String {
        if store.usesSystemLimit && store.snapshot.mode == .off { return store.limitStatus }
        if store.snapshot.recoveryPending { return "Recovery needs attention" }
        if !store.snapshot.helperConnected && store.snapshot.mode != .off { return "Connection lost · check helper recovery" }
        return switch store.snapshot.mode {
        case .off: "MenuSprite control is off"
        case .maintain: "Maintaining \(store.snapshot.band.lower)–\(store.snapshot.band.upper)%"
        case .topUp: "Topping up to 100%"
        case .discharge: "Running on battery to \(store.snapshot.band.upper)%"
        }
    }

    // MARK: Keep awake

    private var awake: some View {
        Section {
            Toggle(isOn: Binding(get: { store.awake }, set: { $0 ? store.startAwake() : store.stopAwake() })) {
                VStack(alignment:.leading,spacing:2) {
                    Text("Keep Mac awake")
                    Text(store.awakeReason).font(.caption).foregroundStyle(store.awake ? .green : .secondary)
                }
            }.accessibilityIdentifier("keep-awake")
            Picker("Duration",selection:$store.duration) {
                ForEach(AwakeDurations.all, id: \.self) { Text(AwakeDurations.title($0)).tag($0) }
            }.onChange(of:store.duration) { _,_ in store.settingsChanged() }
            Toggle("Keep display on",isOn:$store.keepDisplay)
            Toggle("Only on power",isOn:$store.acOnly)
            Toggle("Pause while locked",isOn:$store.pauseWhenLocked)
        } header: {
            titled("Keep awake",tip:"Prevents idle sleep. Choosing Sleep and closing the lid still follow macOS rules.")
        }
        .onChange(of:store.keepDisplay) { _,_ in store.settingsChanged() }
        .onChange(of:store.acOnly) { _,_ in store.settingsChanged() }
        .onChange(of:store.pauseWhenLocked) { _,_ in store.settingsChanged() }
    }

    private var rules: some View {
        Section {
            Toggle("Power is connected",isOn:$store.autoAC)
            Toggle("An external display is connected",isOn:$store.autoDisplay)
            ForEach(store.appRules.keys.sorted(),id:\.self) { id in
                LabeledContent("\(store.appRules[id] ?? id) is running") {
                    Button("Remove") { store.appRules.removeValue(forKey:id); store.settingsChanged() }
                }
            }
            LabeledContent("An app is running") { Button("Choose app…") { store.addAppRule() } }
            if store.hasRules {
                LabeledContent {
                    Button(store.automationPaused ? "Resume" : "Pause") {
                        if store.automationPaused { store.resumeRules() } else { store.pauseRules() }
                    }
                } label: {
                    Text(store.automationPaused ? "Rules are paused" : "Rules are on")
                        .foregroundStyle(store.automationPaused ? .orange : .primary)
                }
            }
        } header: {
            titled("Keep awake automatically when",tip:"Rules pause when you turn keep-awake off and after MenuSprite restarts; resume them here.")
        }
        .onChange(of:store.autoAC) { _,_ in store.settingsChanged() }
        .onChange(of:store.autoDisplay) { _,_ in store.settingsChanged() }
    }

    private var lid: some View {
        Section {
            switchRow("Stay awake with the lid closed","Turns off system sleep, including when the lid closes. Needs power controls on, the cable connected and the battery above 20%. Keep the Mac on a ventilated surface. Uses the keep-awake duration, capped at 24 hours, and stops on unplug, timeout, critical heat or lost connection. A disconnected external display may not stay available.",
                      isOn: Binding(get: { store.snapshot.lidActive }, set: { $0 ? store.startLid() : store.stopLid() }),
                      disabled: !store.snapshot.lidActive && (!store.snapshot.helperConnected || store.snapshot.pluggedIn != true
                                || (store.snapshot.percent ?? 0) <= 20 || store.snapshot.sleepDisabled == true))
        } header: { Text("Lid closed") } footer: {
            if store.snapshot.sleepDisabled == true && !store.snapshot.lidActive {
                Text("System sleep is already disabled by another utility. Turn it off there first.").foregroundStyle(.orange)
            }
        }
    }

    // MARK: Power helper

    private var helper: some View {
        Section {
            LabeledContent {
                HStack {
                    if store.helperState == .on, let action = store.helperActionTitle { Button(action) { store.enableHelper() } }
                    if store.helperState == .on || store.helperState == .needsApproval { Button("Turn off") { store.disableHelper() } }
                }
            } label: { Text(store.helperStatus) }
        } header: { titled("Power controls",tip:Self.helperExplanation) }
    }

    private static let helperExplanation = "Charge limits, discharge, Low Power Mode, fan speeds and the closed-lid mode need a small helper that runs as root. It ships inside MenuSprite, and macOS asks you to allow it once under System Settings → General → Login Items & Extensions. It accepts requests only from this signed app, and hands the fans, adapter and sleep back to macOS when MenuSprite quits, the Mac sleeps or the app stops answering. Keep-awake and every reading work without it."

    /// The first thing on the page while power controls are not on: what it unlocks and the one button.
    private var turnOn: some View {
        HStack(alignment:.center,spacing:14) {
            Image(systemName:"bolt.shield.fill").font(.system(size:28)).foregroundStyle(Color.accentColor)
            VStack(alignment:.leading,spacing:3) {
                HStack(spacing:6) {
                    Text(turnOnTitle).font(.headline)
                    InfoTip(Self.helperExplanation)
                }
                Text(turnOnDetail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            Spacer()
            if let action = store.helperActionTitle {
                Button(action) { store.enableHelper() }.buttonStyle(.borderedProminent).controlSize(.large)
            }
        }.padding(.vertical,6)
    }
    private var turnOnTitle: String {
        switch store.helperState {
        case .needsApproval: "Allow MenuSprite in System Settings"
        case .missing: "Power helper missing"
        case .legacy, .on: "Power helper needs an update"
        case .off: "Power controls are off"
        }
    }
    private var turnOnDetail: String {
        switch store.helperState {
        case .needsApproval: "Login Items & Extensions → allow MenuSprite in the background."
        case .missing: "Reinstall MenuSprite to get it back."
        case .legacy, .on: "One administrator prompt, then everything keeps working."
        case .off: "Turn on for any charge limit, discharge, fan speeds and closed-lid mode."
        }
    }

    // MARK: Pieces

    /// A row's name with its explanation behind an ⓘ.
    private func named(_ title: String, _ tip: String) -> some View {
        HStack(spacing:6) { Text(title); InfoTip(tip) }
    }
    /// A switch row whose ⓘ stays readable while the switch itself is unavailable, so the tip can say why.
    private func switchRow(_ title: String, _ tip: String, isOn: Binding<Bool>, disabled: Bool) -> some View {
        LabeledContent {
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).disabled(disabled)
        } label: {
            named(title, tip).foregroundStyle(disabled ? .secondary : .primary)
        }
    }
    /// A section header with its explanation behind an ⓘ.
    private func titled(_ title: String, tip: String) -> some View {
        HStack(spacing:6) {
            Text(title)
            if !tip.isEmpty { InfoTip(tip) }
        }
    }
}
