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
    public var active: Bool { mode != .off || recovery.lidOwned }
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
    public func restoreAll() throws {
        guard !recoveryUnavailable else { throw PowerFailure("Cannot restore an unreadable recovery journal") }
        var failure: Error?
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
        do {
            if Date().timeIntervalSince(lastHeartbeat) > 65 { try restoreAll(); throw PowerFailure("Controls stopped because MenuSprite disconnected") }
            let state = hardware.snapshot()
            if ProcessInfo.processInfo.thermalState == .critical { try restoreAll(); throw PowerFailure("Controls stopped at critical thermal state") }
            if recovery.lidOwned && (state.pluggedIn != true || (state.percent ?? 0) <= 20 || Date() >= (deadline ?? .distantPast)) { try restoreLid() }
            if mode != .off {
                try noBatteryConflict()
                guard state.chargeSupported, let percent = state.percent, let allow = state.chargingAllowed, state.pluggedIn != nil else { throw PowerFailure("Battery state unavailable; restoring controls") }
                if state.pluggedIn != true { try restoreBattery() }
                else if let decision = BatteryPolicy.decide(mode:mode,band:band,percent:percent,chargingAllowed:allow) {
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
        if active || !recovery.original.isEmpty || recovery.lidOwned {
            if timer == nil { timer = Timer.scheduledTimer(withTimeInterval:15,repeats:true) { [weak self] _ in self?.tick() }; timer?.tolerance = 2 }
        } else { timer?.invalidate(); timer = nil }
    }
private func sleepDisabled() -> Bool? {
    guard let text = try? execute("/usr/bin/pmset", ["-g"]) else { return nil }
    for line in text.split(separator:"\n") {
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        if fields.first == "SleepDisabled", fields.count == 2 { return fields[1] == "1" }
    }
    return nil
}
    public var needsRecovery: Bool { recoveryUnavailable || !recovery.original.isEmpty || recovery.lidOwned }
    public func snapshot() -> PowerSnapshot {
        var result = hardware.snapshot(); result.mode = mode; result.band = band
        result.lidActive = recovery.lidOwned; result.sleepDisabled = sleepDisabled(); result.helperConnected = true; result.recoveryPending = recoveryUnavailable || (!recovery.original.isEmpty && mode == .off); result.error = lastError
        return result
    }
    public func handle(_ request: PowerRequest) -> PowerSnapshot {
        do {
            guard !recoveryUnavailable || request.action == .status else { throw PowerFailure("Controls blocked by unreadable recovery journal") }
            switch request.action {
            case .status: break
            case .heartbeat: lastHeartbeat = Date()
            case .stopAll: try restoreAll()
            case .stopBattery: try restoreBattery()
            case .stopLid: try restoreLid()
            case .battery:
                guard request.band.valid, request.mode != .off else { throw PowerFailure("Invalid charge band") }
                guard recovery.original.isEmpty || mode != .off else { throw PowerFailure("Recover previous control changes before starting") }
                try noBatteryConflict()
                let s = hardware.snapshot()
                guard s.chargeSupported, s.pluggedIn == true else { throw PowerFailure("Connect power and use supported firmware before starting") }
                guard request.mode != .discharge || s.dischargeSupported else { throw PowerFailure("Forced discharge is unavailable on this firmware") }
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
