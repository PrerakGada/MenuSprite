import Foundation

private func command(_ path: String, _ arguments: [String]) throws -> String {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: path); p.arguments = arguments
    p.standardOutput = out; p.standardError = out
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw PowerFailure("\(path) failed: \(String(decoding:data,as:UTF8.self))") }
    return String(decoding:data,as:UTF8.self)
}
struct Recovery: Codable {
    var original: [String:[UInt8]] = [:]
    var written: [String:[UInt8]] = [:]
    var previous: [String:[UInt8]] = [:]
    var lidOwned = false
    /// MenuSprite put the fans in manual mode; a restart must hand them back. Optional so older journals decode.
    var fansOwned: Bool?
}
public final class PowerController {
    let hardware: PowerHardware
    let recoveryURL: URL
    let execute: (String,[String]) throws -> String
    var recovery = Recovery()
    var recoveryUnavailable = false
    var mode = BatteryMode.off
    var band = ChargeBand()
    var lastHeartbeat = Date()
    var deadline: Date?
    public var lastError: String?
    var timer: Timer?
    /// MagSafe LED control follows the app's setting. It is cosmetic, so it is never journaled:
    /// every stop simply hands the LED back to macOS.
    public private(set) var ledControl = false
    var ledWritten: MagSafeLED?
    /// The speed the fans are being held at. Never journaled as intent: the app re-sends it on every
    /// request, so after a sleep or restart the fans stay with macOS until the app asks again.
    public private(set) var fanTarget = FanTarget.automatic
    public var active: Bool { mode != .off || recovery.lidOwned || ledControl || fanTarget.isManual }
    public convenience init() {
        self.init(hardware: BatteryHardware(), recoveryURL: URL(fileURLWithPath: PowerIdentity.journalPath), execute: command)
    }
    init(hardware: PowerHardware, recoveryURL: URL, execute: @escaping (String,[String]) throws -> String) {
        self.hardware = hardware; self.recoveryURL = recoveryURL; self.execute = execute
        if FileManager.default.fileExists(atPath:recoveryURL.path) {
            do { recovery = try JSONDecoder().decode(Recovery.self,from:Data(contentsOf:recoveryURL)) }
            catch { recoveryUnavailable = true; lastError = "Recovery journal is unreadable. Controls are blocked; inspect the root-owned journal before proceeding." }
            if !recoveryUnavailable { do { try restoreAll() } catch { lastError = error.localizedDescription } }
        }
    }
    func save() throws {
        let data = try JSONEncoder().encode(recovery)
        try data.write(to:recoveryURL,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:recoveryURL.path)
    }
    func write(_ values: [String:[UInt8]]) throws {
        for key in values.keys.sorted() {
            let value = values[key]!
            guard let current = hardware.read(key) else { throw PowerFailure("Cannot read \(key)") }
            if let owned = recovery.written[key], current != owned { throw PowerFailure("Another controller changed \(key). Stop it before using MenuSprite.") }
            if current == value { continue }
            let normal = hardware.chargeValues(allow:true).merging(hardware.adapterValues(allow:true)) { $1 }[key]
            let inhibited = hardware.chargeValues(allow:false).merging(hardware.adapterValues(allow:false)) { $1 }[key]
            guard current == normal || current == inhibited else { throw PowerFailure("Unrecognized current \(key) state; cannot safely restore it") }
            if recovery.original[key] == nil { recovery.original[key] = current }
            recovery.previous[key] = current
            recovery.written[key] = value
            try save() // Journal intent before touching hardware, including partial writes.
            try hardware.writeControl(key,value)
            recovery.previous.removeValue(forKey:key)
            try save()
        }
    }
    func restoreBattery() throws {
        mode = .off
        var failure: Error?
        // Reconnect the adapter before restoring charging.
        let keys = recovery.original.keys.sorted { $0.contains("I") && !$1.contains("I") }
        for key in keys {
            do {
                guard let current = hardware.read(key) else { throw PowerFailure("Cannot restore unreadable \(key)") }
                if current == recovery.written[key] || current == recovery.previous[key] { try hardware.writeControl(key,recovery.original[key]!) }
                // If somebody else changed it, leave their value alone.
                recovery.original.removeValue(forKey:key); recovery.written.removeValue(forKey:key); recovery.previous.removeValue(forKey:key)
                try save()
            } catch { failure = error }
        }
        if let failure { throw failure }
    }
    func restoreLid() throws {
        guard recovery.lidOwned else { return }
        guard let disabled = sleepDisabled() else { throw PowerFailure("Cannot check system sleep during restoration") }
        if disabled { _ = try execute("/usr/bin/pmset", ["disablesleep","0"]) }
        recovery.lidOwned = false; deadline = nil; try save()
    }
    func setLED(_ on: Bool) { ledControl = on; updateLED() }
    /// Green while the cable holds the level, amber while charging, blinking while running from
    /// the battery with the cable in. Re-applied on every tick because macOS writes the key too.
    public func updateLED() {
        guard ledControl else { restoreLED(); return }
        let state = hardware.snapshot(), flow = hardware.batteryFlow()
        let desired = MagSafeLED.desired(pluggedIn: state.pluggedIn, charging: flow?.charging ?? false, amperage: flow?.amperage)
        if desired == .system {
            restoreLED(keepControl: true); return
        }
        guard hardware.readLED() != desired || ledWritten != desired else { return }
        do { try hardware.writeLED(desired); ledWritten = desired }
        catch { lastError = error.localizedDescription; ledControl = false }
    }
    func restoreLED(keepControl: Bool = false) {
        if !keepControl { ledControl = false }
        guard ledWritten != nil else { return }
        ledWritten = nil
        try? hardware.writeLED(.system)
    }
    // MARK: Fans
    func noFanConflict() throws {
        let processes = try execute("/bin/ps",["-axo","comm="])
        if let other = processes.split(separator:"\n").first(where: { $0.contains("/Macs Fan Control.app/") || $0.contains("/TG Pro.app/") || $0.contains("/smcFanControl.app/") }) {
            let name = other.split(separator:"/").first { $0.hasSuffix(".app") }.map { $0.dropLast(4) } ?? "Another fan controller"
            throw PowerFailure("\(name) is running and controls the fans too. Quit it to use MenuSprite's fan control.")
        }
    }
    func applyFans(_ target: FanTarget) throws {
        guard let percent = target.percent else { try restoreFans(); return }
        guard FanPolicy.valid(target) else { throw PowerFailure("Choose a fan speed between 1% and 100%") }
        try noFanConflict()
        let fans = hardware.fans().filter(\.controllable)
        guard !fans.isEmpty else { throw PowerFailure("This Mac's firmware publishes no writable fan control") }
        recovery.fansOwned = true; try save() // Journal before touching hardware.
        fanTarget = target
        for fan in fans { try hardware.writeFan(fan.index, rpm: FanPolicy.rpm(percent: percent, for: fan)) }
        // The SMC takes about a second to report a new target; wait for it rather than guess.
        for attempt in 0..<11 {
            let missed = hardware.fans().filter { $0.controllable && abs(($0.target ?? 0) - FanPolicy.rpm(percent: percent, for: $0)) > 2 }
            if missed.isEmpty { return }
            if attempt == 10 { throw PowerFailure("Fan \(missed[0].index + 1) did not take \(Int(FanPolicy.rpm(percent: percent, for: missed[0]))) rpm") }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }
    /// The firmware can fall back to automatic on its own (seen after sleep on other Macs); put it back.
    func maintainFans() {
        guard let percent = fanTarget.percent else { return }
        do {
            try noFanConflict()
            for fan in hardware.fans() where fan.controllable {
                let rpm = FanPolicy.rpm(percent: percent, for: fan)
                if !fan.manual || abs((fan.target ?? 0) - rpm) > 2 { try hardware.writeFan(fan.index, rpm: rpm) }
            }
        } catch {
            lastError = error.localizedDescription
            do { try restoreFans() } catch { lastError = (lastError ?? "") + " " + error.localizedDescription }
        }
    }
    func restoreFans() throws {
        fanTarget = .automatic
        guard recovery.fansOwned == true else { return }
        var failure: Error?
        for fan in hardware.fans() where fan.manual {
            do { try hardware.writeFan(fan.index, rpm: nil) } catch { failure = error }
        }
        if let failure { throw failure }
        recovery.fansOwned = nil; try save()
    }
    public func restoreAll() throws {
        guard !recoveryUnavailable else { throw PowerFailure("Cannot restore an unreadable recovery journal") }
        restoreLED()
        var failure: Error?
        do { try restoreFans() } catch { failure = error }
        do { try restoreBattery() } catch { failure = error }
        do { try restoreLid() } catch { failure = error }
        if let failure { throw failure }
    }
    func noBatteryConflict() throws {
        let processes = try execute("/bin/ps",["-axo","comm="])
        if processes.split(separator:"\n").contains(where: { $0.contains("/AlDente") || $0.hasSuffix("/batt") || $0.contains("/BatteryKid") }) {
            throw PowerFailure("Another battery controller is running. Turn off its charge control and quit it before starting MenuSprite.")
        }
    }
    func tick() {
        if mode == .off && !recovery.original.isEmpty {
            do { try restoreBattery() } catch { lastError = error.localizedDescription }
        }
        updateLED()
        maintainFans()
        if !fanTarget.isManual && recovery.fansOwned == true {
            do { try restoreFans() } catch { lastError = error.localizedDescription }
        }
        do {
            if Date().timeIntervalSince(lastHeartbeat) > 65 { try restoreAll(); throw PowerFailure("Controls stopped because MenuSprite disconnected") }
            let state = hardware.snapshot()
            if ProcessInfo.processInfo.thermalState == .critical { try restoreAll(); throw PowerFailure("Controls stopped at critical thermal state") }
            if recovery.lidOwned && (state.pluggedIn != true || (state.percent ?? 0) <= 20 || Date() >= (deadline ?? .distantPast)) { try restoreLid() }
            if mode != .off {
                try noBatteryConflict()
                guard let percent = state.percent, state.pluggedIn != nil else { throw PowerFailure("Battery state unavailable; restoring controls") }
                if state.pluggedIn != true { try restoreBattery() }
                else if !state.chargeSupported {
                    // Adapter-only firmware can run the Mac from its battery but
                    // cannot inhibit charging, so a discharge is a one-shot that
                    // hands control back at the target rather than a held band.
                    guard mode == .discharge else { throw PowerFailure("This firmware cannot hold a charge limit") }
                    if percent > band.upper { try write(hardware.adapterValues(allow:false)) }
                    else { try restoreBattery() }
                }
                else if let allow = state.chargingAllowed,
                        let decision = BatteryPolicy.decide(mode:mode,band:band,percent:percent,chargingAllowed:allow) {
                    if decision.adapter { try write(hardware.adapterValues(allow:true)) }
                    try write(hardware.chargeValues(allow:decision.charge))
                    if !decision.adapter { try write(hardware.adapterValues(allow:false)) }
                    mode = decision.mode
                }
            }
        } catch {
            lastError = error.localizedDescription
            do { try restoreAll() } catch { lastError = (lastError ?? "") + " Restoration failed: " + error.localizedDescription }
        }
        schedule()
    }
    public func schedule() {
        if active || !recovery.original.isEmpty || recovery.lidOwned || recovery.fansOwned == true {
            if timer == nil { timer = Timer.scheduledTimer(withTimeInterval:15,repeats:true) { [weak self] _ in self?.tick() }; timer?.tolerance = 2 }
        } else { timer?.invalidate(); timer = nil }
    }
/// macOS's energy mode, from `pmset -g`: 0 automatic, 1 Low Power Mode, 2 High Power Mode.
private func powerMode() -> Int? {
    guard let text = try? execute("/usr/bin/pmset", ["-g"]) else { return nil }
    for line in text.split(separator:"\n") {
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        if fields.first == "powermode", fields.count == 2 { return Int(fields[1]) }
    }
    return nil
}
private func sleepDisabled() -> Bool? {
    guard let text = try? execute("/usr/bin/pmset", ["-g"]) else { return nil }
    for line in text.split(separator:"\n") {
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        if fields.first == "SleepDisabled", fields.count == 2 { return fields[1] == "1" }
    }
    return nil
}
    public var needsRecovery: Bool { recoveryUnavailable || !recovery.original.isEmpty || recovery.lidOwned || recovery.fansOwned == true }
    public func snapshot() -> PowerSnapshot {
        var result = hardware.snapshot(); result.mode = mode; result.band = band
        result.lidActive = recovery.lidOwned; result.sleepDisabled = sleepDisabled(); result.helperConnected = true; result.recoveryPending = recoveryUnavailable || (!recovery.original.isEmpty && mode == .off); result.error = lastError
        result.systemLimit = geteuid() == 0 ? SystemChargeLimit.stored() : nil
        result.ledControl = ledControl; result.led = hardware.readLED()
        result.fanTarget = fanTarget; result.fans = hardware.fans()
        return result
    }
    public func handle(_ request: PowerRequest) -> PowerSnapshot {
        do {
            guard !recoveryUnavailable || request.action == .status else { throw PowerFailure("Controls blocked by unreadable recovery journal") }
            // Any request is proof the app is alive; the LED setting rides along on every one.
            lastHeartbeat = Date()
            if let led = request.led, led != ledControl || led { setLED(led) }
            // A fan failure must not cancel the command it rode in on; it hands the fans back instead.
            if let fans = request.fans, fans != fanTarget || request.action == .fans {
                do { try applyFans(fans); if request.action == .fans { lastError = nil } }
                catch {
                    lastError = error.localizedDescription
                    do { try restoreFans() } catch { lastError = (lastError ?? "") + " " + error.localizedDescription }
                }
            }
            switch request.action {
            case .status, .fans: break
            case .heartbeat: lastHeartbeat = Date()
            case .stopAll: try restoreAll()
            case .stopBattery: try restoreBattery()
            case .stopLid: try restoreLid()
            case .chargeLimit:
                // macOS enforces this itself, through sleep and after MenuSprite quits, so
                // nothing is journaled and no timer runs for it.
                guard let limit = request.limit else { throw PowerFailure("No charge limit given") }
                try SystemChargeLimit.write(limit)
                lastError = nil
            case .lowPower:
                // Needs root: macOS's own Low Power Mode switch accepts only Apple's entitled clients.
                // Both power sources are set, so "normal" is the automatic mode on battery and adapter.
                guard let on = request.lowPower else { throw PowerFailure("No Low Power Mode state given") }
                _ = try execute("/usr/bin/pmset", ["-a", "powermode", on ? "1" : "0"])
                guard powerMode() == (on ? 1 : 0) else { throw PowerFailure("macOS did not confirm Low Power Mode \(on ? "on" : "off")") }
                lastError = nil
            case .battery:
                guard request.band.valid, request.mode != .off else { throw PowerFailure("Invalid charge band") }
                guard recovery.original.isEmpty || mode != .off else { throw PowerFailure("Recover previous control changes before starting") }
                try noBatteryConflict()
                let s = hardware.snapshot()
                guard s.pluggedIn == true else { throw PowerFailure("Connect power before starting a battery control") }
                if request.mode == .discharge {
                    guard s.dischargeSupported else { throw PowerFailure("Forced discharge is unavailable on this firmware") }
                    guard (s.percent ?? 0) > request.band.upper else { throw PowerFailure("The battery is already at or below that level") }
                } else {
                    guard s.chargeSupported else { throw PowerFailure("This firmware publishes no writable charge control, so a charge limit cannot be held") }
                }
                band = request.band; mode = request.mode; lastError = nil; lastHeartbeat = Date(); tick()
            case .startLid:
                guard recovery.original.isEmpty || mode != .off else { throw PowerFailure("Battery recovery must finish first") }
                guard request.duration.isFinite, (60...86400).contains(request.duration) else { throw PowerFailure("Choose a closed-lid session of 1 minute to 24 hours") }
                let s = hardware.snapshot()
                guard s.pluggedIn == true, (s.percent ?? 0) > 20 else { throw PowerFailure("Closed-lid mode requires AC power and battery above 20%") }
                guard sleepDisabled() == false else { throw PowerFailure("System sleep is already disabled by another setting or utility. Turn that off first.") }
                recovery.lidOwned = true; try save()
                _ = try execute("/usr/bin/pmset",["disablesleep","1"])
                guard sleepDisabled() == true else { throw PowerFailure("macOS did not confirm disabled sleep") }
                deadline = Date().addingTimeInterval(request.duration); lastHeartbeat = Date(); lastError = nil
            }
        } catch { lastError = error.localizedDescription }
        schedule(); return snapshot()
    }
}
