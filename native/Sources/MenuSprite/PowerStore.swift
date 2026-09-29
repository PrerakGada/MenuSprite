import AppKit
import Combine
import IOKit.ps
import IOKit.pwr_mgt
import PowerControl
import PowerUIBridge

@MainActor
final class PowerStore: ObservableObject {
    @Published var snapshot = PowerSnapshot()
    @Published var helperStatus = "Not installed"
    @Published var notice: String?
    @Published var band = ChargeBand()
    /// The default keep-awake length in seconds, 0 = until turned off. Saved.
    @Published var duration: Double = 0
    @Published var awakeIcon: AwakeIcon = .menuSprite
    @Published var awakeTint: AwakeTint = .orange
    /// Start a default-length session whenever MenuSprite opens.
    @Published var awakeOnLaunch = false
    @Published var jiggle = false
    @Published var jiggleMinutes = 5
    /// Stop holding the Mac awake on battery below this percentage; 0 = never.
    @Published var batteryFloor = 0
    @Published var rightClick: AwakeRightClick = .toggle
    @Published var awakeShortcut: IslandShortcut?
    @Published var keepDisplay = false
    @Published var acOnly = false
    @Published var pauseWhenLocked = true
    @Published var autoAC = false
    @Published var autoDisplay = false
    @Published var appRules: [String:String] = [:]
    @Published private(set) var awake = false
    @Published private(set) var awakeReason = "MenuSprite is allowing sleep"
    @Published private(set) var manualUntil: Date?
    @Published private(set) var batteryConflict: String?
    @Published private(set) var automationPaused = false
    @Published private(set) var busy = false
    /// The saved charge-limit intent, distinct from what the hardware is doing right now.
    /// It is what lets the limit come back after sleep, an unplug or a relaunch, which a
    /// one-shot control could not do. Nothing is applied without the same guards as a manual start.
    @Published private(set) var saverEnabled = false
    private var lastSaverAttempt: Date?
    // MARK: macOS's own charge limit (see SystemChargeLimit)
    /// PowerUI's manual charge limit exists on this Mac. When it does, the limit, Top Up and
    /// Discharge all run through it; the SMC path remains for firmware that still has keys.
    let usesSystemLimit = BuildFeatures.privilegedPowerControls && MSPowerUI.isSupported()
    /// The limit PowerUI reports, and the policy powerd is actually enforcing.
    @Published private(set) var systemLimit: Int?
    @Published private(set) var enforced: EnforcedChargeLimit?
    /// Signed pack current in mA, negative while the Mac runs from the battery.
    @Published private(set) var batteryAmperage: Int?
    /// Charge to 100% once; the saved limit returns when the cable is unplugged.
    @Published private(set) var topUpActive = false
    /// Discharge stopped part-way: hold at this level instead of draining to the limit.
    @Published private(set) var holdLevel: Int?
    @Published private(set) var ledControl = false
    /// Sailing band in percent (0 = an exact limit): no top-up until the level falls this far below the limit.
    @Published private(set) var sailingBand = 5
    private var sailRecharging = false
    private var lastLimitWrite: (value: Int, at: Date)?
    private var limitCheck: DispatchWorkItem?
    /// A limit change that arrived while the helper was still busy with the previous one.
    private var limitWriteWaiting = false
    private var lastNudge: Date?
    /// Charge capability is a root-only read on some firmware: CHTE's size is invisible to an
    /// unprivileged process even where the helper can see it. Once the helper has answered, its
    /// reading wins — the in-process read must never downgrade it back to "unsupported".
    private var helperCapability: (charge: Bool, discharge: Bool, text: String)?
    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var session = AwakeSession()
    private var externalPowerForAwake: Bool?
    private var expiry: DispatchWorkItem?
    private var jiggleTimer: Timer?
    private var heartbeat: Timer?
    private var connection: NSXPCConnection?
    private var observers: [NSObjectProtocol] = []
    private var distributed: [NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?
    private var locked = false
    private var settingsPageOpen = false
    private var batteryObservers: Set<UUID> = []
    private var pageOpen: Bool { settingsPageOpen || !batteryObservers.isEmpty }
    private let preferences: UserDefaults
    private var refreshing = false
    var helperInstalled: Bool { BuildFeatures.privilegedPowerControls && FileManager.default.fileExists(atPath:PowerIdentity.helperPath) }
    var canControlBattery: Bool { canRequestBattery && snapshot.helperConnected }
    /// Everything a charge command needs except an already-open connection. launchd starts the
    /// helper on demand, so the menu-bar battery item can offer the control without holding one
    /// — and the firmware, adapter and conflict checks below are all read in this process.
    var canRequestBattery: Bool { usesSystemLimit ? canSetLimit : requestable && snapshot.chargeSupported }
    /// Setting macOS's limit needs neither the cable nor an open helper connection.
    var canSetLimit: Bool { usesSystemLimit && !busy && batteryConflict == nil }
    /// Running from the battery with the cable in needs only the adapter switch,
    /// which some firmware publishes while publishing no charge control at all.
    /// Gating it on `chargeSupported` hid a control this Mac can actually run.
    var canRequestDischarge: Bool { requestable && snapshot.dischargeSupported }
    var canDischarge: Bool { canRequestDischarge && snapshot.helperConnected }
    private var requestable: Bool { BuildFeatures.privilegedPowerControls && !busy && helperInstalled && !snapshot.recoveryPending && batteryConflict == nil && snapshot.pluggedIn == true }
    var batteryControlReason: String? {
        if usesSystemLimit {
            if let batteryConflict { return "Quit \(batteryConflict) so MenuSprite alone sets the charge limit." }
            return nil
        }
        if let reason = commonBatteryReason { return reason }
        if !snapshot.chargeSupported { return chargeUnsupportedReason }
        if !snapshot.helperConnected { return "The power helper is not connected. Refresh to check." }
        return nil
    }
    /// Why a discharge cannot start, which is a shorter list than a charge limit.
    var dischargeReason: String? {
        if let reason = commonBatteryReason { return reason }
        if !snapshot.dischargeSupported { return "This Mac’s firmware publishes no adapter switch, so it cannot run from the battery on demand." }
        if !snapshot.helperConnected { return "The power helper is not connected. Refresh to check." }
        return nil
    }
    /// Stated once so the window, the menu and the hub all say the same thing.
    var chargeUnsupportedReason: String {
        snapshot.dischargeSupported
            ? "This Mac’s firmware publishes no writable charge-inhibit key, so a charge limit cannot be held. Running from the battery still works."
            : "Charge control is unavailable on this Mac’s firmware."
    }
    private var commonBatteryReason: String? {
        if !BuildFeatures.privilegedPowerControls { return "Charge controls are unavailable in this public build." }
        if let batteryConflict { return "Disable \(batteryConflict)’s charge control, then quit it to use MenuSprite." }
        if !helperInstalled { return "Install MenuSprite’s power helper to enable charge controls." }
        if snapshot.recoveryPending { return "The power helper needs recovery. Open Power Controls." }
        if snapshot.pluggedIn != true { return "Connect your power adapter to use charge controls." }
        return nil
    }
    /// The same explanation for a control that does not need an open connection.
    var batteryRequestReason: String? { canRequestBattery ? nil : batteryControlReason }
    var hasRules: Bool { autoAC || autoDisplay || !appRules.isEmpty }
    var assertionIDs: [IOPMAssertionID] { [systemAssertion,displayAssertion].filter { $0 != 0 } }
    var batteryObserverCount: Int { batteryObservers.count }

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        if let data = preferences.data(forKey:"power.chargeBand"), let saved = try? JSONDecoder().decode(ChargeBand.self,from:data), saved.valid { band = saved }
        saverEnabled = preferences.bool(forKey:"power.saverEnabled")
        topUpActive = preferences.bool(forKey:"power.topUp")
        holdLevel = preferences.object(forKey:"power.holdLevel") as? Int
        ledControl = preferences.bool(forKey:"power.magsafeLED")
        sailingBand = preferences.object(forKey:"power.sailing") as? Int ?? 5
        sailRecharging = preferences.bool(forKey:"power.sailRecharging")
        if usesSystemLimit && preferences.object(forKey:"power.saverEnabled") == nil {
            // First run on the macOS limit: adopt whatever limit is already set rather than
            // replacing it, so installing this build never undoes a limit that is working.
            let current = MSPowerUI.currentLimit()
            if (21..<100).contains(current) {
                band.upper = current; band.lower = min(band.lower, current - 1)
                saverEnabled = true
                preferences.set(try? JSONEncoder().encode(band),forKey:"power.chargeBand")
            }
            preferences.set(saverEnabled, forKey:"power.saverEnabled")
        }
        keepDisplay = preferences.bool(forKey:"power.keepDisplay")
        duration = preferences.object(forKey:"power.duration") as? Double ?? 0
        awakeIcon = preferences.string(forKey:"power.awakeIcon").flatMap(AwakeIcon.init(rawValue:)) ?? .menuSprite
        awakeTint = preferences.string(forKey:"power.awakeTint").flatMap(AwakeTint.init(rawValue:)) ?? .orange
        awakeOnLaunch = preferences.bool(forKey:"power.awakeOnLaunch")
        jiggle = preferences.bool(forKey:"power.jiggle")
        jiggleMinutes = preferences.object(forKey:"power.jiggleMinutes") as? Int ?? 5
        batteryFloor = preferences.integer(forKey:"power.batteryFloor")
        rightClick = preferences.string(forKey:"power.rightClick").flatMap(AwakeRightClick.init(rawValue:)) ?? .toggle
        awakeShortcut = preferences.data(forKey:"power.awakeShortcut").flatMap { try? JSONDecoder().decode(IslandShortcut.self, from: $0) }
        acOnly = preferences.bool(forKey:"power.acOnly")
        pauseWhenLocked = preferences.object(forKey:"power.pauseWhenLocked") as? Bool ?? true
        // Rules are saved, but require Resume after app launch. A restart never
        // silently reenables an indefinite session or hardware control.
        autoAC = preferences.bool(forKey:"power.autoAC")
        autoDisplay = preferences.bool(forKey:"power.autoDisplay")
        appRules = preferences.dictionary(forKey:"power.appRules") as? [String:String] ?? [:]
        automationPaused = hasRules
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didWakeNotification] {
            let isWake = name == NSWorkspace.didWakeNotification
            observers.append(center.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in MainActor.assumeIsolated {
                if isWake { self?.session.wake() }; self?.event()
            } })
        }
        for (name, active) in [(NSWorkspace.sessionDidBecomeActiveNotification, true), (NSWorkspace.sessionDidResignActiveNotification, false)] {
            observers.append(center.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSessionActive(active) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in MainActor.assumeIsolated { self?.event() } })
        observers.append(center.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in MainActor.assumeIsolated {
            self?.handleSleep()
        }})
        for (name,value) in [("com.apple.screenIsLocked",true),("com.apple.screenIsUnlocked",false)] {
            distributed.append(DistributedNotificationCenter.default().addObserver(forName:NSNotification.Name(name),object:nil,queue:.main) { [weak self] _ in MainActor.assumeIsolated { self?.locked = value; self?.reconcileAwake() } })
        }
        if let state = CGSessionCopyCurrentDictionary() as? [String:Any] {
            locked = state["CGSSessionScreenIsLocked"] as? Bool ?? false
            session.sessionActive = state[kCGSessionOnConsoleKey as String] as? Bool ?? true
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            MainActor.assumeIsolated { Unmanaged<PowerStore>.fromOpaque(context).takeUnretainedValue().event() }
        },context)?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(),powerSource,.defaultMode) }
        refreshLocal()
        resumeSaverIfPossible()
        reconcileLimit()
        if ledControl { send(.init(.status)) }
    }
    func opened() { settingsPageOpen = true; refresh() }
    func closed() { settingsPageOpen = false; disconnectIfIdle() }
    func observeBattery(_ id: UUID) { batteryObservers.insert(id); refreshBatteryStatus() }
    func stopObservingBattery(_ id: UUID) { batteryObservers.remove(id); disconnectIfIdle() }
    func refreshBatteryStatus() { refreshLocal(); if helperInstalled { send(.init(.status)) } }
    /// One status round trip at launch, so the firmware answer comes from the root helper
    /// rather than from what this unprivileged process happens to be able to read.
    func askHelperForCapability() { if helperInstalled && helperCapability == nil { send(.init(.status)) } }
    func refresh() {
        refreshLocal()
        if pageOpen && !helperInstalled {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath:"/usr/bin/pmset"); process.arguments = ["-g"]; process.standardOutput = pipe
            if (try? process.run()) != nil {
                let text = String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self); process.waitUntilExit()
                snapshot.sleepDisabled = text.split(separator:"\n").compactMap { line -> Bool? in
                    let fields = line.split(whereSeparator: { $0.isWhitespace })
                    return fields.count == 2 && fields[0] == "SleepDisabled" ? fields[1] == "1" : nil
                }.first
            }
        }
        if helperInstalled { send(.init(.status)) }
    }
    private func refreshLocal() {
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
            let value = source as String
            externalPowerForAwake = value == kIOPSACPowerValue ? true : (value == kIOPSBatteryPowerValue || value == kIOPMUPSPowerKey ? false : nil)
        } else { externalPowerForAwake = nil }
        let current = BatteryHardware().snapshot()
        snapshot.percent = current.percent; snapshot.pluggedIn = current.pluggedIn
        if let reported = helperCapability {
            snapshot.chargeSupported = reported.charge; snapshot.dischargeSupported = reported.discharge
            snapshot.capability = reported.text
        } else {
            snapshot.chargeSupported = current.chargeSupported; snapshot.dischargeSupported = current.dischargeSupported
            snapshot.capability = current.capability
        }
        snapshot.chargingAllowed = current.chargingAllowed; snapshot.adapterEnabled = current.adapterEnabled
        snapshot.chargeCurrent = current.chargeCurrent; snapshot.batteryVoltage = current.batteryVoltage
        if usesSystemLimit { readLimitState() }
        batteryConflict = NSWorkspace.shared.runningApplications.first { app in
            let name = app.localizedName ?? ""
            return name.localizedCaseInsensitiveContains("AlDente") || name == "batt" || name == "BatteryKid"
        }?.localizedName
        if !helperInstalled { helperStatus = "Not installed · administrator approval required"; snapshot.helperConnected = false }
    }
    private func event() {
        refreshLocal(); reconcileAwake()
        // A reconnected adapter is the moment a saved limit can start again.
        if snapshot.pluggedIn != true { lastSaverAttempt = nil }
        reconcileLimit()
        // macOS holds its own limit, so only the SMC path and the LED need the helper polled.
        if helperInstalled && (pageOpen || ledControl || (saverEnabled && !usesSystemLimit)) { send(.init(.status)) }
    }
    func settingsChanged() {
        preferences.set(try? JSONEncoder().encode(band),forKey:"power.chargeBand")
        for (key,value) in [("keepDisplay",keepDisplay),("acOnly",acOnly),("pauseWhenLocked",pauseWhenLocked),("autoAC",autoAC),("autoDisplay",autoDisplay)] { preferences.set(value,forKey:"power.\(key)") }
        preferences.set(appRules,forKey:"power.appRules")
        for (key,value) in [("awakeOnLaunch",awakeOnLaunch),("jiggle",jiggle)] { preferences.set(value,forKey:"power.\(key)") }
        preferences.set(duration,forKey:"power.duration"); preferences.set(jiggleMinutes,forKey:"power.jiggleMinutes")
        preferences.set(batteryFloor,forKey:"power.batteryFloor")
        preferences.set(awakeIcon.rawValue,forKey:"power.awakeIcon"); preferences.set(awakeTint.rawValue,forKey:"power.awakeTint")
        preferences.set(rightClick.rawValue,forKey:"power.rightClick")
        preferences.set(awakeShortcut.flatMap { try? JSONEncoder().encode($0) },forKey:"power.awakeShortcut")
        reconcileAwake()
    }
    /// Called once the app is running for real (not in validation modes): the global shortcut and
    /// the optional start-on-open session.
    func startKeepAwakeServices() {
        applyAwakeShortcut()
        if awakeOnLaunch && !awake { startAwake() }
    }
    /// Registers the saved shortcut; false when another app already owns that combination.
    @discardableResult func applyAwakeShortcut() -> Bool {
        IslandShortcuts.shared.register("keepAwake", awakeShortcut) { [weak self] in self?.toggleAwake() }
    }
    func toggleAwake() { awake ? stopAwake() : startAwake() }
    /// Starts a session of the given length (the saved default when nil).
    func startAwake(for seconds: Double? = nil) {
        session.start(duration: seconds ?? duration); manualUntil = session.deadline
        expiry?.cancel()
        if let end = manualUntil {
            let item = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.expireManualSession() }
            }
            expiry = item; DispatchQueue.main.asyncAfter(deadline:.now()+end.timeIntervalSinceNow,execute:item)
        }
        reconcileAwake()
    }
    func stopAwake() {
        session.cancelManual(); manualUntil = nil; expiry?.cancel(); expiry = nil
        automationPaused = true; releaseAssertions(); awakeReason = "MenuSprite is allowing sleep · automation paused"
    }
    private func expireManualSession() {
        session.cancelManual(); manualUntil = nil; expiry = nil
        reconcileAwake()
    }
    func handleSleep() {
        expiry?.cancel(); expiry = nil; session.sleep(); manualUntil = nil; releaseAssertions()
        if snapshot.mode != .off || snapshot.lidActive { send(.init(.stopAll)) }
    }
    func setSessionActive(_ active: Bool) { session.sessionActive = active; reconcileAwake() }
    func resumeAfterSleep() { session.wake(); event() }
    func pauseRules() { automationPaused = true; reconcileAwake() }
    func resumeRules() { automationPaused = false; reconcileAwake() }
    func addAppRule() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; panel.directoryURL = URL(fileURLWithPath:"/Applications"); panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url:url), let id = bundle.bundleIdentifier else { return }
        appRules[id] = bundle.object(forInfoDictionaryKey:"CFBundleDisplayName") as? String ?? url.deletingPathExtension().lastPathComponent
        settingsChanged()
    }
    private var externalDisplay: Bool {
        NSScreen.screens.contains { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) == 0
        }
    }
    private func reconcileAwake() {
        var reasons: [String] = []
        if session.manual { reasons.append(manualUntil.map { "Until \($0.formatted(date:.omitted,time:.shortened))" } ?? "Until stopped") }
        if !automationPaused {
            if autoAC && externalPowerForAwake == true { reasons.append("Power connected") }
            if autoDisplay && externalDisplay { reasons.append("External display") }
            for app in NSWorkspace.shared.runningApplications {
                if let id = app.bundleIdentifier, let name = appRules[id] { reasons.append(name) }
            }
        }
        if reasons.isEmpty { releaseAssertions(); awakeReason = hasRules && automationPaused ? "MenuSprite is allowing sleep · automation paused" : "MenuSprite is allowing sleep"; return }
        if let reason = session.pauseReason(locked: locked, pauseWhenLocked: pauseWhenLocked, acOnly: acOnly, externalPower: externalPowerForAwake) {
            releaseAssertions(); awakeReason = reason; return
        }
        if batteryFloor > 0, snapshot.pluggedIn == false, let percent = snapshot.percent, percent < batteryFloor {
            releaseAssertions(); awakeReason = "Paused · battery below \(batteryFloor)%"; return
        }
        do {
            if systemAssertion == 0 { systemAssertion = try createAssertion(kIOPMAssertionTypePreventUserIdleSystemSleep, "MenuSprite — keep awake") }
            if keepDisplay && displayAssertion == 0 { displayAssertion = try createAssertion(kIOPMAssertionTypePreventUserIdleDisplaySleep,"MenuSprite — keep display awake") }
            if !keepDisplay && displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
            awake = true; awakeReason = reasons.joined(separator:" · ")
            updateJiggle()
        } catch { releaseAssertions(); notice = error.localizedDescription; awakeReason = "Keep-awake could not start" }
    }
    private func createAssertion(_ type: String, _ reason: String) throws -> IOPMAssertionID {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(type as CFString,IOPMAssertionLevel(kIOPMAssertionLevelOn),reason as CFString,&id)
        guard result == kIOReturnSuccess else { throw PowerFailure("macOS rejected the keep-awake assertion (\(result))") }
        return id
    }
    private func releaseAssertions() {
        for id in assertionIDs { IOPMAssertionRelease(id) }
        systemAssertion = 0; displayAssertion = 0; awake = false
        updateJiggle()
    }
    /// One repeating timer while awake with "Move pointer slightly" on; none otherwise.
    private func updateJiggle() {
        let interval = TimeInterval(max(1, jiggleMinutes) * 60)
        guard awake && jiggle else { jiggleTimer?.invalidate(); jiggleTimer = nil; return }
        if let jiggleTimer, jiggleTimer.isValid, jiggleTimer.timeInterval == interval { return }
        jiggleTimer?.invalidate()
        jiggleTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            PointerNudge.nudge(ifIdleFor: min(60, interval / 2))
        }
    }
    /// Menu-facing description of what the hardware is doing, never what was merely asked for.
    var chargeStatus: String {
        switch snapshot.mode {
        case .off:
            if !snapshot.chargeSupported {
                return snapshot.dischargeSupported ? "Charge limit unavailable · discharge on demand" : "Charge control unavailable"
            }
            return saverEnabled ? "Charge limit \(band.upper)% · not applied" : "Charge limit off"
        case .maintain: return "Limiting to \(snapshot.band.lower)–\(snapshot.band.upper)%"
        case .topUp: return "Topping up to 100%"
        case .discharge: return "Discharging to \(snapshot.band.upper)%"
        }
    }
    /// What the pack is doing right now, measured from the firmware rather than
    /// inferred from the last command, so a control that silently stopped shows.
    var flowDescription: String {
        guard let plugged = snapshot.pluggedIn else { return "Power source unknown" }
        if let mA = snapshot.chargeCurrent, mA > 0 {
            let amps = Double(mA) / 1000
            if let mV = snapshot.batteryVoltage, mV > 0 {
                return String(format: "Charging · %.2f A (%.1f W)", amps, amps * Double(mV) / 1000)
            }
            return String(format: "Charging · %.2f A", amps)
        }
        if plugged && snapshot.adapterEnabled == false { return "Running from the battery · cable connected" }
        if plugged { return "Power connected · not charging" }
        return "On battery"
    }
    /// True while MenuSprite itself is holding the adapter off.
    var runningOnBatteryByChoice: Bool { snapshot.mode == .discharge && snapshot.adapterEnabled == false }
    func setSaver(_ on: Bool) {
        saverEnabled = on
        preferences.set(on, forKey: "power.saverEnabled")
        lastSaverAttempt = nil
        if usesSystemLimit {
            if !on { setTopUp(false); setHold(nil); writeSystemLimit(100) } else { reconcileLimit(force: true) }
            return
        }
        if on { battery(.maintain) } else { stopBattery() }
    }
    /// Choosing a ceiling keeps the resume level a fixed step below it, and re-applies
    /// immediately when the limit is already running so the menu needs no second click.
    func setLimit(_ upper: Int) {
        let upper = min(100, max(21, upper))
        band.upper = upper
        band.lower = min(band.lower, upper - 1)
        if band.lower < 20 { band.lower = 20 }
        if upper > 20 { band.lower = min(band.lower, upper - 1) }
        settingsChanged()
        lastSaverAttempt = nil
        if usesSystemLimit {
            // Choosing a limit is the intent to hold it; a paused discharge no longer applies.
            setHold(nil); setTopUp(false)
            if !saverEnabled { saverEnabled = true; preferences.set(true, forKey: "power.saverEnabled") }
            reconcileLimit(force: true); return
        }
        if saverEnabled || snapshot.mode != .off { battery(snapshot.mode == .off ? .maintain : snapshot.mode) }
    }
    /// Re-applies a saved limit once conditions allow it — after a relaunch, a wake or a
    /// reconnected adapter. Throttled so a persistent refusal cannot become a retry loop.
    private func resumeSaverIfPossible() {
        guard !usesSystemLimit, saverEnabled, snapshot.mode == .off, canRequestBattery, band.valid else { return }
        if let last = lastSaverAttempt, Date().timeIntervalSince(last) < 30 { return }
        lastSaverAttempt = Date()
        battery(.maintain)
    }
    func battery(_ mode: BatteryMode) {
        if usesSystemLimit {
            switch mode {
            case .maintain: setSaver(true)
            case .topUp: toggleTopUp()
            case .discharge: toggleDischarge()
            case .off: setSaver(false)
            }
            return
        }
        let allowed = mode == .discharge ? canRequestDischarge : canRequestBattery
        let reason = mode == .discharge ? dischargeReason : batteryRequestReason
        guard allowed, band.valid else { notice = reason ?? "Install the helper, connect power and turn off the other battery controller first."; return }
        settingsChanged(); send(.init(.battery,mode:mode,band:band))
    }
    func stopBattery() { send(.init(.stopBattery)) }
    /// Low Power Mode, switched through the helper; macOS announces the change itself
    /// (`NSProcessInfoPowerStateDidChange`), so the battery item redraws from the real state.
    var lowPowerEnabled: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
    /// The installed helper rejected a command this build sends: it needs reinstalling.
    private(set) var helperOutdated = false
    func toggleLowPower() {
        guard BuildFeatures.privilegedPowerControls, helperInstalled else {
            notice = "Low Power Mode is switched through the power helper, which is not installed."
            NSSound.beep(); return
        }
        send(.init(.lowPower, lowPower: !lowPowerEnabled))
    }
    /// Run from the battery with the cable in through the adapter switch — independent of the
    /// charge limit, down to the chosen level, then hand the adapter back.
    func runOnBattery() {
        guard canRequestDischarge, band.valid else { notice = dischargeReason ?? "Running on battery is unavailable."; return }
        settingsChanged(); send(.init(.battery,mode:.discharge,band:band))
    }

    // MARK: macOS charge limit

    /// The level macOS should hold right now.
    var desiredSystemLimit: Int { topUpActive ? 100 : (holdLevel ?? sailTarget.limit) }
    private var sailTarget: (limit: Int, recharging: Bool) {
        Sailing.target(limit: band.upper, band: sailingBand, percent: snapshot.percent, recharging: sailRecharging)
    }
    /// macOS has MenuSprite's value but powerd still charges under the previous one; it switches
    /// at the next whole percent (about two minutes at this Mac's charge rate).
    var limitWaitsForNextStep: Bool {
        guard let enforced, let systemLimit, enforced.limit != systemLimit else { return false }
        return (snapshot.chargeCurrent ?? 0) > 0 || (batteryAmperage ?? 0) > 50
    }
    /// Inside the band: macOS is told to hold the current level rather than top up.
    var isSailing: Bool {
        saverEnabled && !topUpActive && holdLevel == nil && snapshot.pluggedIn == true && sailTarget.limit < band.upper
    }
    /// macOS is running the Mac from its battery to reach the limit, cable connected.
    var isDraining: Bool {
        guard snapshot.pluggedIn == true, let percent = snapshot.percent else { return false }
        // powerd re-registers its policy after a change and briefly records none; fall back to
        // the limit PowerUI reports and the measured current rather than calling that "holding".
        // Its record also lags PowerUI by several seconds after a change, so a record that
        // disagrees with PowerUI is treated as stale.
        if let enforced, systemLimit == nil || enforced.limit == systemLimit { return enforced.drain && percent > enforced.limit }
        guard let systemLimit else { return false }
        return percent > systemLimit && (batteryAmperage ?? 0) < -50
    }
    /// What the pack and macOS are doing, in the words every surface uses.
    var limitStatus: String {
        guard usesSystemLimit else { return chargeStatus }
        if let batteryConflict { return "\(batteryConflict) is also running" }
        guard saverEnabled else { return systemLimit.map { $0 < 100 ? "macOS limit \($0)% · not managed by MenuSprite" : "Charge limit off" } ?? "Charge limit off" }
        let target = desiredSystemLimit
        if let systemLimit, systemLimit != target { return "Applying \(target)%… macOS reports \(systemLimit)%" }
        if limitWaitsForNextStep, let percent = snapshot.percent, target <= percent + 1 {
            return "\(target)% set · macOS applies it at the next 1% step"
        }
        guard snapshot.pluggedIn == true, let percent = snapshot.percent else { return "Limit \(band.upper)% · held by macOS when plugged in" }
        if topUpActive { return percent >= 100 ? "Topped up · \(band.upper)% returns when unplugged" : "Topping up to 100%" }
        if let holdLevel { return "Discharge paused · holding \(holdLevel)%" }
        // Above the target macOS drains to it; powerd's record can lag a change by seconds, so the
        // level alone decides the words rather than a stale record.
        if isDraining || percent > target { return "Discharging to \(target)% · cable connected" }
        if isSailing { return "Sailing · holding \(percent)%, charges below \(band.upper - sailingBand)%" }
        if (snapshot.chargeCurrent ?? 0) > 0 { return "Charging to \(target)%" }
        return percent < target ? "Plugged in · below \(target)%" : "Holding \(target)%"
    }
    /// Where the bar's marker and the menu-bar tick belong: the limit macOS is enforcing.
    var activeCeiling: Int? {
        guard usesSystemLimit else { return snapshot.controlCeiling }
        // The user's limit, not the level sailing is holding at this moment.
        guard saverEnabled, !topUpActive, band.upper < 100 else { return nil }
        return band.upper
    }
    func toggleTopUp() { setTopUp(!topUpActive); if topUpActive { setHold(nil) }; reconcileLimit(force: true) }
    /// Discharge drains to the limit; pressing it while draining stops and holds the level reached.
    func toggleDischarge() {
        guard usesSystemLimit else { battery(snapshot.mode == .discharge ? .maintain : .discharge); return }
        setTopUp(false)
        if holdLevel != nil { setHold(nil) }
        else if saverEnabled, isDraining, let percent = snapshot.percent { setHold(percent) }
        else if !saverEnabled { saverEnabled = true; preferences.set(true, forKey: "power.saverEnabled") }
        reconcileLimit(force: true)
    }
    var canDischargeToLimit: Bool {
        usesSystemLimit && canSetLimit && snapshot.pluggedIn == true && !topUpActive && (snapshot.percent ?? 0) > band.upper
    }
    func setSailing(_ band: Int) {
        sailingBand = max(0, min(20, band)); preferences.set(sailingBand, forKey:"power.sailing")
        reconcileLimit(force: true)
    }
    func setLEDControl(_ on: Bool) {
        ledControl = on; preferences.set(on, forKey: "power.magsafeLED")
        send(.init(.status))
        if !on { disconnectIfIdle() }
    }
    private func setTopUp(_ on: Bool) { topUpActive = on; preferences.set(on, forKey: "power.topUp") }
    private func setHold(_ level: Int?) {
        holdLevel = level
        if let level { preferences.set(level, forKey: "power.holdLevel") } else { preferences.removeObject(forKey: "power.holdLevel") }
    }
    private func readLimitState() {
        let limit = MSPowerUI.currentLimit()
        systemLimit = limit > 0 ? limit : nil
        enforced = EnforcedChargeLimit.current()
        batteryAmperage = BatteryHardware().batteryFlow()?.amperage
    }
    /// Keeps macOS's limit on MenuSprite's target. Runs on launch, wake, plug and every power
    /// event; it only writes when the two differ, and never when MenuSprite's limit is off, so
    /// a limit chosen in System Settings is left alone until the user turns MenuSprite's on.
    func reconcileLimit(force: Bool = false) {
        guard usesSystemLimit else { return }
        if snapshot.pluggedIn == false && (topUpActive || holdLevel != nil) { setTopUp(false); setHold(nil) }
        if let hold = holdLevel, let percent = snapshot.percent, percent <= band.upper || hold <= band.upper { setHold(nil) }
        guard saverEnabled, batteryConflict == nil else { return }
        readLimitState()
        let sail = sailTarget
        if sail.recharging != sailRecharging { sailRecharging = sail.recharging; preferences.set(sail.recharging, forKey:"power.sailRecharging") }
        // macOS does not charge on battery, so there is nothing to hold; the plug-in event writes.
        if snapshot.pluggedIn != true && !force { return }
        let target = desiredSystemLimit
        // PowerUI reports a write a second or two late, so right after one the value actually
        // sent is the truth; comparing with the stale report let a queued change go unsent.
        let recent = lastLimitWrite.flatMap { Date().timeIntervalSince($0.at) < 15 ? $0.value : nil }
        guard (recent ?? systemLimit) != target else {
            // PowerUI agrees; make sure powerd does too, once its record has had time to catch up.
            if let last = lastLimitWrite, Date().timeIntervalSince(last.at) < 40 { return }
            if enforced?.limit != target { verifyEnforced() }
            return
        }
        if !force, let last = lastLimitWrite, last.value == target, Date().timeIntervalSince(last.at) < 30 { return }
        writeSystemLimit(target)
    }
    private func writeSystemLimit(_ value: Int) {
        // Recorded only once it is really sent; a write deferred behind a busy helper is re-derived later.
        if busy { limitWriteWaiting = true; return }
        lastLimitWrite = (value, Date())
        if MSPowerUI.isEnabled() == 0 { _ = MSPowerUI.enable() }
        let accepted = MSPowerUI.availableLimits().map(\.intValue)
        // Every write goes through the helper when it is installed, so PowerUIAgent always sees a
        // preference change; PowerUI's API is the fallback for the values it accepts, and 100.
        if (!helperInstalled || value == 100), accepted.contains(value), (try? MSPowerUI.setLimit(value)) != nil {
            notice = nil; checkLimitSoon(); return
        }
        guard helperInstalled else {
            notice = "macOS accepts only 80–100% in 5% steps without MenuSprite’s power helper. Install it for \(value)%."
            return
        }
        // At 100 PowerUIAgent's limit is off and it ignores the stored preference, and turning it
        // back on restores macOS's own saved value (80), not ours. Bring it back on at a value it
        // accepts first, then write ours (measured 25 Sep: 100 → 55 alone never took; 80 → 55 did).
        if MSPowerUI.currentLimit() >= 100, let floor = accepted.min() { _ = try? MSPowerUI.setLimit(floor) }
        send(.init(.chargeLimit, limit: value))
        checkLimitSoon()
    }
    /// PowerUIAgent applies a change a moment after it is written.
    /// PowerUI can report MenuSprite's value while powerd still enforces an older policy — seen
    /// after the limit was turned off and on, and re-writing the same value does not refresh it.
    /// Only a *changed* stored value reaches powerd, so a stuck policy is nudged one step up and,
    /// once PowerUI reports the step, written back (measured 25 Sep: 56 then 55 cleared it).
    private func verifyEnforced() {
        // A check scheduled by an earlier write must not act on a newer one still settling.
        if let last = lastLimitWrite, Date().timeIntervalSince(last.at) < 30 { return }
        readLimitState()
        let target = desiredSystemLimit
        guard usesSystemLimit, saverEnabled, snapshot.pluggedIn == true, target < 100, systemLimit == target,
              enforced?.limit != target, helperInstalled, !busy else { return }
        // While charging, PowerUIAgent hands a new limit to powerd only at the next 1% step
        // (measured 25 Sep, several times); a nudge cannot hurry it and would only rewrite.
        guard !limitWaitsForNextStep else { return }
        if let lastNudge, Date().timeIntervalSince(lastNudge) < 120 {
            notice = "macOS reports \(target)% but is enforcing \(enforced.map { "\($0.limit)%" } ?? "no limit"). Retrying shortly."
            return
        }
        lastNudge = Date()
        lastLimitWrite = (target + 1, Date())
        send(.init(.chargeLimit, limit: target + 1))
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in MainActor.assumeIsolated { self?.reconcileLimit(force: true) } }
    }
    /// powerd's record catches up several seconds later, so the state is read again then too.
    private func checkLimitSoon() {
        limitCheck?.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated {
            guard let self else { return }
            self.readLimitState()
            if self.saverEnabled, self.systemLimit != self.desiredSystemLimit {
                self.notice = "macOS did not take \(self.desiredSystemLimit)% (it reports \(self.systemLimit.map { "\($0)%" } ?? "no limit")). Reinstall the power helper if this persists."
            }
            for delay in [6.0, 14.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in MainActor.assumeIsolated { self?.readLimitState() } }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [weak self] in MainActor.assumeIsolated { self?.verifyEnforced() } }
        }}
        limitCheck = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }
    /// The user turning the limit off in the menu, as opposed to a sleep or unplug stopping it.
    func stopSaver() { setSaver(false) }
    func startLid() { send(.init(.startLid,duration:duration > 0 ? duration : 86400)) }
    func stopLid() { send(.init(.stopLid)) }
    private func connected() -> NSXPCConnection {
        if let connection { return connection }
        let c = NSXPCConnection(machServiceName:PowerIdentity.service,options:.privileged)
        c.setCodeSigningRequirement(PowerIdentity.helperRequirement)
        c.remoteObjectInterface = NSXPCInterface(with:PowerHelperProtocol.self)
        c.invalidationHandler = { @Sendable [weak self] in Task { @MainActor in self?.connection = nil; self?.snapshot.helperConnected = false } }
        c.interruptionHandler = { @Sendable [weak self] in Task { @MainActor in self?.snapshot.helperConnected = false; self?.helperStatus = "Helper connection interrupted; recovery runs in the helper" } }
        c.resume(); connection = c; return c
    }
    private func send(_ request: PowerRequest) {
        guard BuildFeatures.privilegedPowerControls else { return }
        guard helperInstalled else { helperStatus = "Not installed · administrator approval required"; return }
        guard !refreshing || request.action != .status else { return }
        var request = request
        request.led = ledControl
        let wroteLimit = request.action == .chargeLimit
        let switchedLowPower = request.action == .lowPower
        let isCommand = request.action != .status && request.action != .heartbeat
        if isCommand {
            // A limit asked for mid-command is not dropped: the latest target is re-applied
            // when the helper answers (dragging right after changing sailing hit this).
            guard !busy else { if request.action == .chargeLimit { limitWriteWaiting = true }; return }
            busy = true
        }
        refreshing = true
        let c = connected()
        let proxy = c.remoteObjectProxyWithErrorHandler { @Sendable [weak self] error in
            let message = error.localizedDescription
            Task { @MainActor in self?.refreshing = false; if isCommand { self?.busy = false }; self?.helperStatus = "Unavailable: \(message)"; self?.snapshot.helperConnected = false; self?.connection?.invalidate(); self?.connection = nil }
        } as? PowerHelperProtocol
        guard let data = try? JSONEncoder().encode(request) else { refreshing = false; if isCommand { busy = false }; return }
        proxy?.perform(data) { @Sendable [weak self] data in Task { @MainActor in
            guard let self else { return }; self.refreshing = false; if isCommand { self.busy = false }
            if isCommand && self.limitWriteWaiting {
                self.limitWriteWaiting = false
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.reconcileLimit(force: true) } }
            }
            guard let response = try? JSONDecoder().decode(PowerSnapshot.self,from:data) else { self.notice = "Invalid helper response"; return }
            self.snapshot = response; self.helperStatus = "Connected · signed MenuSprite helper"
            self.helperCapability = (response.chargeSupported, response.dischargeSupported, response.capability)
            // A helper older than this build rejects commands it does not know.
            if switchedLowPower { self.helperOutdated = response.error == "Invalid request" }
            self.notice = response.error == "Invalid request" && isCommand
                ? "The power helper predates this control. Reinstall it (Copy helper install command), then try again."
                : response.error
            if isCommand, response.error != nil { NSSound.beep() }
            if response.mode != .off || response.lidActive || response.ledControl == true {
                if self.heartbeat == nil {
                    self.heartbeat = Timer.scheduledTimer(withTimeInterval:20,repeats:true) { [weak self] _ in MainActor.assumeIsolated { self?.send(.init(.heartbeat)) } }
                    self.heartbeat?.tolerance = 2
                }
            } else {
                self.heartbeat?.invalidate(); self.heartbeat = nil
                self.resumeSaverIfPossible()
                if wroteLimit { self.readLimitState() }
                if !self.saverEnabled || self.snapshot.mode != .off || self.usesSystemLimit { self.disconnectIfIdle() }
            }
        }}
    }
    private func disconnectIfIdle() {
        if !pageOpen && snapshot.mode == .off && !snapshot.lidActive && !ledControl { connection?.invalidate(); connection = nil; snapshot.helperConnected = false }
    }
    func revealInstaller() {
        if let url = Bundle.main.url(forResource:"install-power-helper",withExtension:"sh") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
    func copyInstallCommand() {
        guard let url = Bundle.main.url(forResource:"install-power-helper",withExtension:"sh") else { return }
        let quoted = "'" + url.path.replacingOccurrences(of:"'",with:"'\\''") + "'"
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("sudo /bin/bash \(quoted)",forType:.string)
        notice = "Install command copied. Run it in Terminal; macOS needs your administrator password. Then click Refresh."
    }
    func shutdown() {
        expiry?.cancel(); heartbeat?.invalidate(); releaseAssertions()
        // Invalidating the sole authenticated connection tells the helper to restore.
        connection?.invalidate(); connection = nil
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(),powerSource,.defaultMode) }
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer); NotificationCenter.default.removeObserver(observer) }
        for observer in distributed { DistributedNotificationCenter.default().removeObserver(observer) }
    }
}
