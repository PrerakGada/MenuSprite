import AppKit
import Combine
import IOKit.ps
import IOKit.pwr_mgt
import PowerControl

@MainActor
final class PowerStore: ObservableObject {
    @Published var snapshot = PowerSnapshot()
    @Published var helperStatus = "Not installed"
    @Published var notice: String?
    @Published var band = ChargeBand()
    @Published var duration: Double = 3600
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
    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var session = AwakeSession()
    private var externalPowerForAwake: Bool?
    private var expiry: DispatchWorkItem?
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
    var canControlBattery: Bool { BuildFeatures.privilegedPowerControls && !busy && snapshot.helperConnected && snapshot.chargeSupported && !snapshot.recoveryPending && batteryConflict == nil && snapshot.pluggedIn == true }
    var batteryControlReason: String? {
        if !BuildFeatures.privilegedPowerControls { return "Charge controls are unavailable in this public build." }
        if let batteryConflict { return "Disable \(batteryConflict)’s charge control, then quit it to use MenuSprite." }
        if !helperInstalled { return "Install MenuSprite’s power helper to enable charge controls." }
        if snapshot.recoveryPending { return "The power helper needs recovery. Open Power Controls." }
        if !snapshot.helperConnected { return "The power helper is not connected. Refresh to check." }
        if !snapshot.chargeSupported { return "Charge control is unavailable on this Mac’s firmware." }
        if snapshot.pluggedIn != true { return "Connect your power adapter to use charge controls." }
        return nil
    }
    var hasRules: Bool { autoAC || autoDisplay || !appRules.isEmpty }
    var assertionIDs: [IOPMAssertionID] { [systemAssertion,displayAssertion].filter { $0 != 0 } }
    var batteryObserverCount: Int { batteryObservers.count }

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        if let data = preferences.data(forKey:"power.chargeBand"), let saved = try? JSONDecoder().decode(ChargeBand.self,from:data), saved.valid { band = saved }
        keepDisplay = preferences.bool(forKey:"power.keepDisplay")
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
    }
    func opened() { settingsPageOpen = true; refresh() }
    func closed() { settingsPageOpen = false; disconnectIfIdle() }
    func observeBattery(_ id: UUID) { batteryObservers.insert(id); refreshBatteryStatus() }
    func stopObservingBattery(_ id: UUID) { batteryObservers.remove(id); disconnectIfIdle() }
    func refreshBatteryStatus() { refreshLocal(); if helperInstalled { send(.init(.status)) } }
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
        snapshot.chargeSupported = current.chargeSupported; snapshot.dischargeSupported = current.dischargeSupported
        snapshot.capability = current.capability; snapshot.chargingAllowed = current.chargingAllowed; snapshot.adapterEnabled = current.adapterEnabled
        batteryConflict = NSWorkspace.shared.runningApplications.first { app in
            let name = app.localizedName ?? ""
            return name.localizedCaseInsensitiveContains("AlDente") || name == "batt" || name == "BatteryKid"
        }?.localizedName
        if !helperInstalled { helperStatus = "Not installed · administrator approval required"; snapshot.helperConnected = false }
    }
    private func event() { refreshLocal(); reconcileAwake(); if pageOpen && helperInstalled { send(.init(.status)) } }
    func settingsChanged() {
        preferences.set(try? JSONEncoder().encode(band),forKey:"power.chargeBand")
        for (key,value) in [("keepDisplay",keepDisplay),("acOnly",acOnly),("pauseWhenLocked",pauseWhenLocked),("autoAC",autoAC),("autoDisplay",autoDisplay)] { preferences.set(value,forKey:"power.\(key)") }
        preferences.set(appRules,forKey:"power.appRules")
        reconcileAwake()
    }
    func startAwake() {
        session.start(duration: duration); manualUntil = session.deadline
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
        do {
            if systemAssertion == 0 { systemAssertion = try createAssertion(kIOPMAssertionTypePreventUserIdleSystemSleep, "MenuSprite — keep awake") }
            if keepDisplay && displayAssertion == 0 { displayAssertion = try createAssertion(kIOPMAssertionTypePreventUserIdleDisplaySleep,"MenuSprite — keep display awake") }
            if !keepDisplay && displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
            awake = true; awakeReason = reasons.joined(separator:" · ")
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
    }
    func battery(_ mode: BatteryMode) {
        guard canControlBattery, band.valid else { notice = "Install the helper, connect power and turn off the other battery controller first."; return }
        settingsChanged(); send(.init(.battery,mode:mode,band:band))
    }
    func stopBattery() { send(.init(.stopBattery)) }
    func startLid() { send(.init(.startLid,duration:duration > 0 ? duration : 86400)) }
    func stopLid() { send(.init(.stopLid)) }
    private func connected() -> NSXPCConnection {
        if let connection { return connection }
        let c = NSXPCConnection(machServiceName:PowerIdentity.service,options:.privileged)
        c.setCodeSigningRequirement(PowerIdentity.helperRequirement)
        c.remoteObjectInterface = NSXPCInterface(with:PowerHelperProtocol.self)
        c.invalidationHandler = { [weak self] in Task { @MainActor in self?.connection = nil; self?.snapshot.helperConnected = false } }
        c.interruptionHandler = { [weak self] in Task { @MainActor in self?.snapshot.helperConnected = false; self?.helperStatus = "Helper connection interrupted; recovery runs in the helper" } }
        c.resume(); connection = c; return c
    }
    private func send(_ request: PowerRequest) {
        guard BuildFeatures.privilegedPowerControls else { return }
        guard helperInstalled else { helperStatus = "Not installed · administrator approval required"; return }
        guard !refreshing || request.action != .status else { return }
        let isCommand = request.action != .status && request.action != .heartbeat
        if isCommand { guard !busy else { return }; busy = true }
        refreshing = true
        let c = connected()
        let proxy = c.remoteObjectProxyWithErrorHandler { [weak self] error in
            let message = error.localizedDescription
            Task { @MainActor in self?.refreshing = false; if isCommand { self?.busy = false }; self?.helperStatus = "Unavailable: \(message)"; self?.snapshot.helperConnected = false; self?.connection?.invalidate(); self?.connection = nil }
        } as? PowerHelperProtocol
        guard let data = try? JSONEncoder().encode(request) else { refreshing = false; if isCommand { busy = false }; return }
        proxy?.perform(data) { [weak self] data in Task { @MainActor in
            guard let self else { return }; self.refreshing = false; if isCommand { self.busy = false }
            guard let response = try? JSONDecoder().decode(PowerSnapshot.self,from:data) else { self.notice = "Invalid helper response"; return }
            self.snapshot = response; self.helperStatus = "Connected · signed MenuSprite helper"
            self.notice = response.error
            if response.mode != .off || response.lidActive {
                if self.heartbeat == nil {
                    self.heartbeat = Timer.scheduledTimer(withTimeInterval:20,repeats:true) { [weak self] _ in MainActor.assumeIsolated { self?.send(.init(.heartbeat)) } }
                    self.heartbeat?.tolerance = 2
                }
            } else { self.heartbeat?.invalidate(); self.heartbeat = nil; self.disconnectIfIdle() }
        }}
    }
    private func disconnectIfIdle() {
        if !pageOpen && snapshot.mode == .off && !snapshot.lidActive { connection?.invalidate(); connection = nil; snapshot.helperConnected = false }
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
