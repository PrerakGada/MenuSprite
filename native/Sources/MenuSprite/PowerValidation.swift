import AppKit
import IOKit.pwr_mgt
import PowerControl
import SystemMonitoring

@MainActor
final class PowerValidation {
    let app: AppDelegate
    let directory: URL
    var checks: [[String:Any]] = []
    var measurements: [[String:Any]] = []
    init(app:AppDelegate,directory:URL) { self.app = app; self.directory = directory }
    func start() {
        Task {
            do { try await run() }
            catch { checks.append(["name":"Validation completed","passed":false,"error":error.localizedDescription]); try? report() }
            app.finishHeadlessMeasurement(); app.showPower()
        }
    }
    func startUI() {
        Task {
            do {
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                app.showPower()
                try await pause(3)
                guard let window = app.powerWindow, let view = window.contentView else { throw PowerFailure("Power window missing") }
                view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw PowerFailure("Cannot render the power view") }
                view.cacheDisplay(in:view.bounds,to:bitmap)
                try bitmap.representation(using:.png,properties:[:])?.write(to:directory.appendingPathComponent("power-controls.png"))
                let state: [String:Any] = ["visible":window.isVisible,"frame":NSStringFromRect(window.frame),"helperInstalled":app.powerStore.helperInstalled,"helperStatus":app.powerStore.helperStatus,"batteryConflict":app.powerStore.batteryConflict ?? "None","systemSleepDisabled":app.powerStore.snapshot.sleepDisabled as Any? ?? "Unknown"]
                try JSONSerialization.data(withJSONObject:state,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("ui-state.json"))
                for config in app.monitoringStore.sprites {
                    let columns = app.monitoringStore.menuColumns(config)
                    let image = StackedReadout.image(columns:columns,config:config,height:24)
                    if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data:tiff) { try rep.representation(using:.png,properties:[:])?.write(to:directory.appendingPathComponent("readout-\(config.name).png")) }
                }
            } catch { try? error.localizedDescription.write(to:directory.appendingPathComponent("ui-error.txt"),atomically:true,encoding:.utf8) }
        }
    }
    /// A real discharge on real hardware: the only way to prove the adapter
    /// switch is wired end to end, because every layer below the button is a
    /// firmware write this project refuses to claim without a readback.
    /// It restores the adapter on every exit path, including a thrown error.
    func startDischarge() {
        Task {
            var restored = false
            do {
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                note = Self.dischargeNote
                let store = app.powerStore!
                store.observeBattery(UUID())
                try await pause(3)
                check("Helper is connected", store.snapshot.helperConnected)
                check("Firmware publishes the adapter switch", store.snapshot.dischargeSupported)
                check("A charge limit is correctly refused on this firmware", !store.snapshot.chargeSupported)
                check("Discharge is offered", store.canDischarge)
                let before = store.snapshot
                measurements.append(["stage":"before","percent":before.percent as Any,"adapterEnabled":before.adapterEnabled as Any,
                                     "chargeCurrent":before.chargeCurrent as Any,"capability":before.capability])
                guard before.percent ?? 0 > store.band.upper else {
                    check("Battery is above the target so a discharge can start", false); try report(); return
                }
                store.battery(.discharge)
                try await pause(8)
                let during = store.snapshot
                check("Mode is discharge", during.mode == .discharge)
                check("Adapter is switched off in firmware", during.adapterEnabled == false)
                check("No charge key was written", during.chargingAllowed == nil)
                check("Charge current has stopped", (during.chargeCurrent ?? -1) == 0)
                check("The cable is still connected", during.pluggedIn == true)
                measurements.append(["stage":"during","percent":during.percent as Any,"adapterEnabled":during.adapterEnabled as Any,
                                     "chargeCurrent":during.chargeCurrent as Any,"error":during.error as Any])
                store.stopBattery()
                restored = true
                try await pause(8)
                let after = store.snapshot
                check("Stopping returns control", after.mode == .off)
                check("Adapter is reconnected", after.adapterEnabled == true)
                check("No recovery is left pending", !after.recoveryPending)
                measurements.append(["stage":"after","percent":after.percent as Any,"adapterEnabled":after.adapterEnabled as Any,
                                     "chargeCurrent":after.chargeCurrent as Any,"error":after.error as Any])
                try report()
            } catch {
                if !restored { app.powerStore?.stopBattery() }
                checks.append(["name":"Discharge validation completed","passed":false,"error":error.localizedDescription])
                try? report()
            }
            app.finishHeadlessMeasurement()
        }
    }
    /// macOS's own charge limit, end to end through the installed helper: a limit PowerUI refuses
    /// (60), Top Up, a paused discharge and the MagSafe LED, each read back from powerd or the SMC.
    /// Headless — no panel opens. Every exit path restores the original limit and LED setting.
    func startSystemLimit() {
        Task {
            let store = app.powerStore!
            let original = store.band.upper, originalLED = store.ledControl, originalSaver = store.saverEnabled
            let originalBand = store.sailingBand
            @MainActor func state(_ stage: String) {
                measurements.append(["stage":stage,"percent":store.snapshot.percent as Any,"pluggedIn":store.snapshot.pluggedIn as Any,
                                     "systemLimit":store.systemLimit as Any,"enforced":store.enforced.map { "\($0.limit)\($0.drain ? " drain" : "")" } as Any,
                                     "amperage":store.batteryAmperage as Any,"status":store.limitStatus,"notice":store.notice as Any,
                                     "led":store.snapshot.led.map { "\($0)" } as Any,"ledControl":store.snapshot.ledControl as Any])
            }
            @MainActor func settle() async throws { try await pause(4); store.refreshBatteryStatus(); try await pause(2) }
            /// powerd follows within ~20 s unless charging, when it waits for the next 1% (~2 min here).
            @MainActor func awaitEnforced(_ value: Int) async throws {
                for _ in 0..<40 where store.enforced?.limit != value { try await settle() }
            }
            do {
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                note = "Real writes to macOS's charge limit and the MagSafe LED, restored at the end."
                store.observeBattery(UUID())
                try await settle(); state("before")
                check("macOS manual charge limit is used", store.usesSystemLimit)
                check("Helper is installed", store.helperInstalled)
                check("A limit is on and macOS holds what MenuSprite asks", store.saverEnabled && store.systemLimit == store.desiredSystemLimit)
                try await awaitEnforced(store.desiredSystemLimit); state("before, powerd")
                check("powerd enforces it", store.enforced?.limit == store.desiredSystemLimit)

                if store.snapshot.pluggedIn == true, let percent = store.snapshot.percent, percent <= 95 {
                    store.setSailing(5); store.setLimit(percent + 2); try await settle(); state("sailing inside band")
                    check("Sailing: a limit 2% above the level holds the level instead of charging", store.systemLimit == percent && store.isSailing)
                    store.setSailing(0); try await settle(); state("sailing off")
                    check("Without sailing the exact limit applies", store.systemLimit == percent + 2)
                }
                // The remaining steps test exact limits, so sailing stays off until the restore.
                store.setSailing(0)
                // Two helper writes back to back: the second lands while the first is in flight and
                // must be queued, not dropped.
                store.setLimit(61); store.setLimit(60); try await settle(); state("limit 60")
                check("A limit PowerUI refuses (60) is taken through the helper", store.systemLimit == 60)
                try await awaitEnforced(60); state("limit 60, powerd")
                check("powerd enforces 60", store.enforced?.limit == 60)

                if store.snapshot.pluggedIn == true {
                    store.toggleTopUp(); try await settle(); state("top up")
                    check("Top up raises macOS's limit to 100", store.systemLimit == 100)
                    store.toggleTopUp(); try await settle(); state("top up stopped")
                    check("Stopping top up restores the limit", store.systemLimit == 60)
                    // Leaving 100 is where macOS used to fall back to its own saved 80.
                    try await awaitEnforced(60)
                    state("after top up, powerd")
                    check("After top up powerd enforces the limit again, not macOS's saved 80", store.enforced?.limit == 60)
                    // Draining is only expected when the pack is above the 60% test limit.
                    if (store.snapshot.percent ?? 0) > 60 {
                        for _ in 0..<5 where !store.isDraining { try await settle() }
                        check("macOS is draining toward the limit with the cable in", store.isDraining)
                    }
                    if store.isDraining, let percent = store.snapshot.percent {
                        store.toggleDischarge(); try await settle(); state("discharge paused")
                        check("Stopping a discharge holds the current level", store.holdLevel == percent && store.systemLimit == percent)
                        store.toggleDischarge(); try await settle(); state("discharge resumed")
                        check("Resuming drains to the limit again", store.holdLevel == nil && store.systemLimit == 60)
                    }
                    store.setLEDControl(true); try await settle(); state("led on")
                    let flow = BatteryHardware().batteryFlow()
                    let expected = MagSafeLED.desired(pluggedIn: true, charging: flow?.charging ?? false, amperage: flow?.amperage)
                    check("Helper reports LED control on", store.snapshot.ledControl == true)
                    check("MagSafe LED shows \(expected)", store.snapshot.led == expected)
                    try await pause(6)
                }
            } catch { checks.append(["name":"Charge limit validation completed","passed":false,"error":error.localizedDescription]) }
            store.setLEDControl(originalLED)
            store.setSailing(originalBand)
            store.setLimit(original)
            if !originalSaver { store.setSaver(false) }
            try? await settle(); state("restored")
            check("Original limit restored", store.band.upper == original && store.systemLimit == (originalSaver ? store.desiredSystemLimit : 100))
            try? report()
            app.finishHeadlessMeasurement()
        }
    }
    func check(_ name:String,_ passed:Bool) { checks.append(["name":name,"passed":passed]) }
    func pause(_ seconds:Double) async throws { try await Task.sleep(for:.milliseconds(Int(seconds*1000))) }
    func run() async throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let store = app.powerStore!
        check("No keep-awake assertion on app launch", store.assertionIDs.isEmpty)
        check("Battery control remains off on app launch",store.snapshot.mode == .off)
        check("Closed-lid control remains off on app launch",!store.snapshot.lidActive)
        let sprites = app.monitoringStore.sprites
        for id in ["cpu.usage","memory.usage","sensor.PSTR"] {
            let found = sprites.first { $0.metricIDs == [id] }
            check("Separate bright icon-free stacked \(id)", found.map { !$0.showIcon && $0.bold && $0.colorHex == "FFFFFF" && $0.layout == .stacked } ?? false)
        }
        try await pause(5)
        check("Real system power is available", app.monitoringStore.readings["sensor.PSTR"]?.available == true)
        try await measure("CPU-RAM-PWR-2s-controls-off",seconds:25)
        let oldDisplay = store.keepDisplay, oldAC = store.acOnly, oldPause = store.pauseWhenLocked, oldDuration = store.duration
        defer { store.stopAwake(); store.keepDisplay = oldDisplay; store.acOnly = oldAC; store.pauseWhenLocked = oldPause; store.duration = oldDuration }
        store.keepDisplay = true; store.acOnly = false; store.pauseWhenLocked = false; store.duration = 3600
        store.startAwake()
        check("Native idle-system and display assertions created",store.assertionIDs.count == 2 && store.awake)
        check("macOS reports this app's two assertions", ownAssertionCount() == 2)
        try await measure("CPU-RAM-PWR-2s-keep-awake-display",seconds:25)
        store.stopAwake()
        check("Stop releases both native assertions",store.assertionIDs.isEmpty && ownAssertionCount() == 0)
        store.duration = 1; store.startAwake(); try await pause(2)
        check("Timed session expires and releases native assertions",!store.awake && ownAssertionCount() == 0)
        try await measure("CPU-RAM-PWR-2s-after-stop",seconds:25)
        try JSONEncoder().encode(store.snapshot).write(to:directory.appendingPathComponent("native-power-probe.json"))
        try JSONEncoder().encode(sprites).write(to:directory.appendingPathComponent("active-readouts.json"))
        try report()
    }
    func ownAssertionCount() -> Int {
        var dictionary: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dictionary) == kIOReturnSuccess, let data = dictionary?.takeRetainedValue() as? [NSNumber:[[String:Any]]] else { return -1 }
        return (data[NSNumber(value:ProcessInfo.processInfo.processIdentifier)] ?? []).filter { ($0[kIOPMAssertionNameKey] as? String)?.hasPrefix("MenuSprite —") == true }.count
    }
    func usage() -> (rss:Double,footprint:Double,cpu:Double) {
        var info = task_vm_info_data_t(); var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to:&info) { p in p.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count) } }
        var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
        return (result == KERN_SUCCESS ? Double(info.resident_size)/1048576 : -1,result == KERN_SUCCESS ? Double(info.phys_footprint)/1048576 : -1,Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1e6)
    }
    func measure(_ name:String,seconds:Double) async throws {
        let start = Date(), before = usage(); try await pause(seconds); let after = usage(); let elapsed = Date().timeIntervalSince(start)
        measurements.append(["phase":name,"seconds":elapsed,"residentMiB":after.rss,"physicalFootprintMiB":after.footprint,"cpuPercentOneCore":(after.cpu-before.cpu)/elapsed*100])
        try report()
    }
    /// The note must describe the run that actually happened. A discharge writes
    /// privileged firmware through the root helper, so it must not carry the
    /// read-only run's disclaimer.
    var note = "Installed signed app, actual saved CPU/RAM/PWR setup. Fresh process and no windows during samples. Only this app's ordinary idle-sleep assertions were created and released. No privileged hardware or global sleep writes; physical lid, charging and root XPC flows remain unverified."
    static let dischargeNote = "Installed signed app driving the real root XPC helper. This run DID write privileged firmware: the adapter switch was turned off and back on, with each write confirmed by readback and journalled for recovery. No charge-inhibit key exists on this Mac and none was written. Physical lid behaviour and a full-depth discharge to the target remain unverified."
    func report() throws {
        let result: [String:Any] = ["bundle":Bundle.main.bundlePath,"version":Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") ?? "","checks":checks,"measurements":measurements,"note":note]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("report.json"))
    }
}
