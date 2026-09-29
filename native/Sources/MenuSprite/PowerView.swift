import SwiftUI
import PowerControl

struct PowerView: View {
    @ObservedObject var store: PowerStore
    let showPermissions: () -> Void
    var body: some View {
        VStack(spacing:0) {
            HStack {
                VStack(alignment:.leading,spacing:5) {
                    Text(BuildFeatures.powerPageTitle).font(.system(size:25,weight:.semibold,design:.rounded))
                    Text(BuildFeatures.publicPreview ? "Choose when your Mac stays awake." : "Choose when to charge, and when your Mac stays awake.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Permissions & Access",action:showPermissions).controlSize(.small)
                Button("Refresh") { store.refresh() }.keyboardShortcut("r",modifiers:.command)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    if BuildFeatures.privilegedPowerControls { battery }
                    awake
                    if BuildFeatures.privilegedPowerControls { lid; helper }
                    else { Text("Battery charging and closed-lid controls are not included in this public preview.").font(.callout).foregroundStyle(.secondary) }
                    if let notice = store.notice { Text(notice).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                }.padding(24)
            }
        }.frame(minWidth:800,minHeight:650)
        .background(Color(nsColor:.windowBackgroundColor))
    }
    private var battery: some View {
        GroupBox {
            VStack(alignment:.leading,spacing:16) {
                batteryHeader
                BatteryGauge(percent: store.snapshot.percent,
                             target: store.usesSystemLimit ? store.activeCeiling : store.snapshot.controlCeiling,
                             limit: store.usesSystemLimit ? (store.saverEnabled ? store.band.upper : nil)
                                : (store.snapshot.chargeSupported ? store.band.upper : nil),
                             chargingNow: (store.snapshot.chargeCurrent ?? 0) > 0,
                             onBattery: store.snapshot.adapterEnabled == false || store.isDraining,
                             setLimit: store.usesSystemLimit && store.canSetLimit ? { store.setLimit($0) } : nil)
                if store.usesSystemLimit { systemLimitControls }
                else if store.snapshot.chargeSupported { chargeLimitControls } else { limitUnavailable }
                Divider()
                cableActions
                if let conflict = store.batteryConflict {
                    Label("\(conflict) is running. Turn off its charge control, then quit it before starting MenuSprite.",systemImage:"exclamationmark.circle")
                        .font(.callout).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true)
                }
                Text(store.snapshot.capability).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
            }.padding(10)
        } label: { Label("Battery",systemImage:"battery.75percent") }
    }

    private var batteryHeader: some View {
        HStack(alignment:.firstTextBaseline) {
            Text(store.snapshot.percent.map { "\($0)%" } ?? "Unknown")
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
    }

    /// The band, shown only when the firmware can actually hold one.
    private var chargeLimitControls: some View {
        VStack(alignment:.leading,spacing:10) {
            LabeledSlider(title:"Charge limit", value:$store.band.upper, range:21...100)
            LabeledSlider(title:"Resume charging below", value:$store.band.lower, range:20...99)
            if !store.band.valid { Text("Resume level must be below the charge limit.").foregroundStyle(.orange).font(.callout) }
            HStack {
                Button("Apply charge limit") { store.battery(.maintain) }
                    .disabled(!store.canControlBattery || !store.band.valid)
                Button("Top up to 100% once") { store.battery(.topUp) }
                    .disabled(!store.canControlBattery || !store.band.valid)
            }
        }.onChange(of:store.band) { _,_ in store.settingsChanged() }
    }

    /// macOS's own charge limit: held by macOS through sleep and restarts, set to any level.
    private var systemLimitControls: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Toggle("Limit charging to \(store.band.upper)%", isOn: Binding(get: { store.saverEnabled }, set: { store.setSaver($0) }))
                    .disabled(!store.canSetLimit)
                Spacer()
                Button(store.topUpActive ? "Stop top up" : "Top up to 100% once") { store.toggleTopUp() }
                    .disabled(!store.canSetLimit || (!store.topUpActive && store.snapshot.pluggedIn != true))
                Button(store.isDraining && store.holdLevel == nil ? "Stop discharging" : "Discharge to \(store.band.upper)%") { store.toggleDischarge() }
                    .disabled(!store.canSetLimit || !(store.isDraining || store.holdLevel != nil || store.canDischargeToLimit))
            }
            Picker("Sailing", selection: Binding(get: { store.sailingBand }, set: { store.setSailing($0) })) {
                ForEach(Sailing.choices, id: \.self) { choice in
                    Text(choice == 0 ? "Off · exact limit" : "\(choice)% · charge only below \(max(0, store.band.upper - choice))%").tag(choice)
                }
            }.frame(width: 360).disabled(!store.canSetLimit)
            Toggle("MagSafe light: green while holding, amber while charging, blinking while discharging",
                   isOn: Binding(get: { store.ledControl }, set: { store.setLEDControl($0) }))
                .disabled(!store.helperInstalled)
            Text("Drag the line on the bar to set the limit. macOS enforces it through sleep and restarts, even with MenuSprite quit; above it, macOS runs the Mac from the battery until it gets there. Top up returns to your limit when you unplug.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }
    }

    /// Firmware without a writable charge-inhibit key. Say so once, plainly,
    /// rather than showing a limit control that could never take effect.
    private var limitUnavailable: some View {
        Label(store.chargeUnsupportedReason,systemImage:"info.circle")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
    }

    /// What can be done while the cable stays connected. On this Mac that is the
    /// adapter switch: run from the battery down to a chosen level, or stop and
    /// charge normally again.
    private var cableActions: some View {
        VStack(alignment:.leading,spacing:10) {
            Text("While the cable is connected").font(.subheadline).fontWeight(.medium)
            HStack(spacing:10) {
                Stepper("Run on battery down to \(store.band.upper)%",value:$store.band.upper,in:21...100)
                    .frame(width:290)
                    .onChange(of:store.band) { _,_ in store.settingsChanged() }
                Button(store.snapshot.mode == .discharge ? "Discharging…" : "Run on battery") { store.runOnBattery() }
                    .disabled(!store.canDischarge || !store.band.valid || store.snapshot.mode == .discharge
                              || (store.snapshot.percent ?? 0) <= store.band.upper)
                Button("Charge normally") { store.stopBattery() }
                    .disabled(store.snapshot.mode == .off && !store.snapshot.recoveryPending)
                Spacer()
            }
            if let reason = store.dischargeReason {
                Text(reason).font(.callout).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true)
            } else if (store.snapshot.percent ?? 0) <= store.band.upper && store.snapshot.mode == .off {
                Text("The battery is already at or below \(store.band.upper)%.").font(.callout).foregroundStyle(.secondary)
            }
            Text("A discharge uses the battery while the cable stays connected; it adds no artificial workload and reconnects the adapter at your level. Every control also stops on unplug, sleep, app quit, lost connection or critical heat.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
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

    private var awake: some View {
        GroupBox {
            VStack(alignment:.leading,spacing:14) {
                HStack {
                    Label(store.awake ? "Keeping Mac awake" : "Keep-awake is off",systemImage:store.awake ? "cup.and.saucer.fill" : "moon")
                        .font(.headline).foregroundStyle(store.awake ? Color.green : Color.primary)
                    Spacer()
                    Text(store.awakeReason).font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Picker("Duration",selection:$store.duration) {
                        ForEach(AwakeDurations.all, id: \.self) { Text(AwakeDurations.title($0)).tag($0) }
                    }.frame(width:240).onChange(of:store.duration) { _,_ in store.settingsChanged() }
                    Spacer()
                    Button("Start keep-awake") { store.startAwake() }.accessibilityIdentifier("start-keep-awake")
                    Button("Stop & pause rules") { store.stopAwake() }.accessibilityIdentifier("stop-keep-awake")
                }
                HStack(spacing:20) {
                    Toggle("Keep display on",isOn:$store.keepDisplay)
                    Toggle("Only on power",isOn:$store.acOnly)
                    Toggle("Pause while locked",isOn:$store.pauseWhenLocked)
                }.onChange(of:store.keepDisplay) { _,_ in store.settingsChanged() }
                    .onChange(of:store.acOnly) { _,_ in store.settingsChanged() }
                    .onChange(of:store.pauseWhenLocked) { _,_ in store.settingsChanged() }
                Divider()
                Text("Automatically keep awake when…").font(.subheadline).fontWeight(.medium)
                HStack {
                    Toggle("Power is connected",isOn:$store.autoAC)
                    Toggle("An external display is connected",isOn:$store.autoDisplay)
                    Spacer()
                    Button(store.automationPaused ? "Resume rules" : "Pause rules") {
                        if store.automationPaused { store.resumeRules() } else { store.pauseRules() }
                    }.disabled(!store.hasRules)
                }.onChange(of:store.autoAC) { _,_ in store.settingsChanged() }
                    .onChange(of:store.autoDisplay) { _,_ in store.settingsChanged() }
                HStack {
                    Text("A chosen app is running").font(.callout)
                    Spacer(); Button("Choose app…") { store.addAppRule() }
                }
                ForEach(store.appRules.keys.sorted(),id:\.self) { id in
                    HStack {
                        Text(store.appRules[id] ?? id).font(.callout); Spacer()
                        Button("Remove") { store.appRules.removeValue(forKey:id); store.settingsChanged() }.controlSize(.small)
                    }
                }
                Text("Prevents idle sleep. Manual Sleep and lid closure still follow macOS rules. Rules pause after Stop or restarting MenuSprite.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }.padding(10)
        } label: { Label("Keep awake",systemImage:"cup.and.saucer") }
    }
    private var lid: some View {
        GroupBox {
            VStack(alignment:.leading,spacing:12) {
                HStack {
                    Text(store.snapshot.lidActive ? "Closed-lid mode is active" : "Closed-lid mode is off").font(.headline)
                    Spacer()
                    if store.snapshot.lidActive { Button("Stop closed-lid mode") { store.stopLid() } }
                    else { Button("Start closed-lid mode") { store.startLid() }
                        .disabled(!store.snapshot.helperConnected || store.snapshot.pluggedIn != true || (store.snapshot.percent ?? 0) <= 20 || store.snapshot.sleepDisabled == true) }
                }
                Text("Disables system sleep, including lid-triggered sleep. Requires power, battery above 20%, and the administrator helper. Keep the Mac on a ventilated surface. Stops on unplug, timeout, critical thermal state or lost app connection.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Text("Uses the duration above; ‘Until stopped’ is capped at 24 hours for this mode. It does not guarantee that a disconnected external display remains available.")
                    .font(.caption).foregroundStyle(.secondary)
                if store.snapshot.sleepDisabled == true && !store.snapshot.lidActive {
                    Text("System sleep is already disabled outside MenuSprite. Turn that off in the controlling utility before starting here.").foregroundStyle(.orange).font(.callout)
                }
            }.padding(10)
        } label: { Label("Keep awake with the lid closed",systemImage:"laptopcomputer") }
    }
    private var helper: some View {
        GroupBox {
            VStack(alignment:.leading,spacing:10) {
                HStack {
                    Text(store.helperStatus).fontWeight(.medium)
                    Spacer()
                    Button("Show installer") { store.revealInstaller() }
                    Button("Copy install command") { store.copyInstallCommand() }
                }
                Text(store.snapshot.capability).font(.caption).foregroundStyle(.secondary)
                Text("The first developer build installs its signed helper through Terminal with your administrator password. It handles only battery controls and closed-lid sessions. Ordinary keep-awake needs no helper. Hardware writes and physical lid behavior still need on-device validation after installation.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }.padding(10)
        } label: { Label("MenuSprite power helper",systemImage:"lock.shield") }
    }
}
