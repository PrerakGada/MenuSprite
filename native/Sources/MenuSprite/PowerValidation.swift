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
    func report() throws {
        let result: [String:Any] = ["bundle":Bundle.main.bundlePath,"version":Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") ?? "","checks":checks,"measurements":measurements,"note":"Installed signed app, actual saved CPU/RAM/PWR setup. Fresh process and no windows during samples. Only this app's ordinary idle-sleep assertions were created and released. No privileged hardware or global sleep writes; physical lid, charging and root XPC flows remain unverified."]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("report.json"))
    }
}
