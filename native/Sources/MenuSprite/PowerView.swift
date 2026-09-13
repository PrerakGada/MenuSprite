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
            VStack(alignment:.leading,spacing:14) {
                HStack(alignment:.firstTextBaseline) {
                    Text(store.snapshot.percent.map { "\($0)%" } ?? "Unknown").font(.system(size:32,weight:.bold,design:.rounded)).monospacedDigit()
                    Text(store.snapshot.pluggedIn.map { $0 ? "Power connected" : "On battery" } ?? "Power source unknown").foregroundStyle(.secondary)
                    Spacer()
                    Text(modeLabel).fontWeight(.semibold)
                }
                HStack(spacing:24) {
                    Stepper("Charge to \(store.band.upper)%",value:$store.band.upper,in:21...100).frame(width:210)
                    Stepper("Resume below \(store.band.lower)%",value:$store.band.lower,in:20...99).frame(width:235)
                }
                .onChange(of:store.band) { _,_ in store.settingsChanged() }
                Text("Hold between these levels while plugged in. Top up charges to 100% once, then returns to the limit. Discharge uses the battery while connected until it reaches your limit.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                if !store.band.valid { Text("Resume level must be below the charge limit.").foregroundStyle(.orange) }
                if let conflict = store.batteryConflict {
                    Label("\(conflict) is running. Turn off its charge control, then quit it before starting MenuSprite.",systemImage:"exclamationmark.circle")
                        .font(.callout).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true)
                }
                HStack {
                    Button("Apply charge limit") { store.battery(.maintain) }.disabled(!store.canControlBattery || !store.band.valid)
                    Button("Top up to 100%") { store.battery(.topUp) }.disabled(!store.canControlBattery || !store.band.valid)
                    Button("Discharge to \(store.band.upper)%") { store.battery(.discharge) }.disabled(!store.canControlBattery || !store.band.valid || !store.snapshot.dischargeSupported)
                    Spacer()
                    Button("Stop battery control") { store.stopBattery() }.disabled(store.snapshot.mode == .off && !store.snapshot.recoveryPending)
                }
                Text("Controls stop on unplug, sleep, app quit or lost connection. Starting again is explicit. Discharge does not add an artificial workload.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }.padding(10)
        } label: { Label("Battery",systemImage:"battery.75percent") }
    }
    private var modeLabel: String {
        if store.snapshot.recoveryPending { return "Recovery needs attention" }
        if !store.snapshot.helperConnected && store.snapshot.mode != .off { return "Connection lost · check helper recovery" }
        return switch store.snapshot.mode {
        case .off: "MenuSprite control is off"
        case .maintain: "Maintaining \(store.snapshot.band.lower)–\(store.snapshot.band.upper)%"
        case .topUp: "Topping up to 100%"
        case .discharge: "Discharging to \(store.snapshot.band.upper)%"
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
                        Text("15 minutes").tag(900.0); Text("30 minutes").tag(1800.0)
                        Text("1 hour").tag(3600.0); Text("2 hours").tag(7200.0)
                        Text("8 hours").tag(28800.0); Text("Until stopped").tag(0.0)
                    }.frame(width:240)
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
