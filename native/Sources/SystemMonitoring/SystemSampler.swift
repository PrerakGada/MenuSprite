import Foundation
import Darwin
import IOKit
import IOKit.ps

public struct SampleBatch: Sendable {
    public var readings: [String: Reading]
    public var discovered: [Metric]
    public var sourceErrors: [String]
}

public actor SystemSampler {
    private let hostPort = mach_host_self()
    private var oldCPUTicks: [[UInt32]]?
    private var counters: [String: CounterDelta] = [:]
    private var networkMembership: Set<String>?
    private var diskMembership: Set<UInt64>?
    private var smc: SMCReader?
    private var sensorKeys: [String] = []
    private var sensorMetrics: [Metric] = []
    private var sensorsDiscovered = false
    private var activeGroups: Set<MetricGroup> = []
    public init() {}
    deinit { mach_port_deallocate(mach_task_self_, hostPort) }

    public func resetBaselines() { oldCPUTicks = nil; counters = [:]; networkMembership = nil; diskMembership = nil }
    public func idle() { resetBaselines(); smc = nil; activeGroups = [] }
    public func configure(active groups: Set<MetricGroup>) {
        for removed in activeGroups.subtracting(groups) {
            switch removed {
            case .cpu: oldCPUTicks = nil
            case .network: networkMembership = nil
            case .disk: diskMembership = nil
            default: break
            }
            let prefix = removed == .sensors ? "sensor." : removed.rawValue.lowercased() + "."
            counters = counters.filter { !$0.key.hasPrefix(prefix) }
        }
        if !groups.contains(.sensors) { smc = nil }
        activeGroups = groups
    }

    public func sample(ids: Set<String>, groups: Set<MetricGroup>) -> SampleBatch {
        var result = SampleBatch(readings: [:], discovered: [], sourceErrors: [])
        let now = ProcessInfo.processInfo.systemUptime
        for group in groups {
            let values: [String: Reading]
            switch group {
            case .cpu: values = cpu()
            case .memory: values = memory(now: now)
            case .network:
                let network = network(now: now)
                values = network.readings; result.discovered += network.discovered
            case .disk: values = disk(now: now)
            case .gpu: values = gpu()
            case .battery: values = battery()
            case .system: values = system()
            case .sensors: values = sensors(ids: ids)
            case .ai: values = [:]
            }
            result.readings.merge(values) { _, new in new }
        }
        // Explicitly clear failed requested readings; never let stale numbers look live.
        // AI usage readings come from the app's usage service, so they are never cleared here.
        for id in ids where result.readings[id] == nil && !id.hasPrefix("ai.") {
            result.readings[id] = Reading(unavailable: "Not reported by this Mac")
        }
        return result
    }

    public func discoverSensors() -> SampleBatch {
        if sensorsDiscovered { return .init(readings: [:], discovered: sensorMetrics, sourceErrors: []) }
        smc = smc ?? SMCReader()
        guard let reader = smc, reader.failure == nil else {
            return .init(readings: [:], discovered: [], sourceErrors: [smc?.failure ?? "SMC unavailable"])
        }
        sensorKeys = reader.keys()
        var readings: [String: Reading] = [:]
        sensorMetrics = []
        let baseIDs = Set(MonitoringCatalog.base.map(\.id))
        for key in sensorKeys {
            guard let unit = SMCReader.unit(for: key), let value = reader.read(key), SMCReader.plausible(value, unit: unit) else { continue }
            let id = "sensor." + key
            readings[id] = Reading(value)
            guard !baseIDs.contains(id) else { continue }
            let name: String
            let advanced: Bool
            if unit == .rpm {
                let fanNumber = (Int(String(key.dropFirst().prefix(1))) ?? 0) + 1
                let kind = ["Ac": "speed", "Mn": "minimum", "Mx": "maximum", "Tg": "target"][String(key.suffix(2))] ?? "speed"
                name = "Fan \(fanNumber) \(kind)"; advanced = !key.hasSuffix("Ac")
            } else {
                let title: String
                switch unit { case .celsius: title = "Temperature"; case .watts: title = "Power"; case .volts: title = "Voltage"; default: title = "Current" }
                name = "\(title) · \(key)"; advanced = true
            }
            sensorMetrics.append(Metric(id, name, unit == .rpm ? "Fan \((Int(String(key.dropFirst().prefix(1))) ?? 0) + 1)" : key, .sensors, unit,
                "Read-only firmware sensor \(key). Raw keys are shown when a reliable component name is not established. Firmware availability and units can vary by Mac; no hardware setting is changed.",
                source: "AppleSMC \(key), \(reader.info(key)?.type ?? "unknown type")", advanced: advanced))
        }
        sensorMetrics.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        sensorsDiscovered = !sensorKeys.isEmpty
        return .init(readings: readings, discovered: sensorMetrics, sourceErrors: sensorKeys.isEmpty ? ["No readable SMC key catalog"] : [])
    }
    public func discoverInterfaces() -> [Metric] {
        network(now: ProcessInfo.processInfo.systemUptime, sampleRates: false).discovered
    }

    private func sensors(ids: Set<String>) -> [String: Reading] {
        smc = smc ?? SMCReader()
        guard let reader = smc, reader.failure == nil else {
            return Dictionary(uniqueKeysWithValues: ids.filter { $0.hasPrefix("sensor.") }.map { ($0, Reading(unavailable: smc?.failure ?? "SMC unavailable")) })
        }
        var result: [String: Reading] = [:]
        let brand = Self.sysctlString("machdep.cpu.brand_string") ?? ""
        if ids.contains("sensor.gpuTemperature") && sensorKeys.isEmpty { sensorKeys = reader.keys() }
        let cpuKeys: [String]
        if brand.contains("Apple M5") {
            cpuKeys = ["00","04","08","0C","0G","0K","0O","0R","0U","0X","0a","0d","0g","0j","0m","0p","0u","0y"].map { "Tp" + $0 }
        } else { cpuKeys = [] }
        for id in ids where id.hasPrefix("sensor.") {
            if id == "sensor.fanSpeed" {
                let count = reader.read("FNum").flatMap { $0 >= 0 && $0 <= 10 ? Int($0) : nil }
                let values = (0..<(count ?? 10)).compactMap { index -> Double? in
                    let key = "F\(index)Ac"
                    guard let value = reader.read(key), SMCReader.plausible(value, unit: .rpm) else { return nil }
                    result["sensor." + key] = Reading(value)
                    return value
                }
                result[id] = values.max().map { Reading($0) } ?? Reading(unavailable: "No fan speed reported by this Mac")
            } else if id == "sensor.cpuTemperature" || id == "sensor.gpuTemperature" {
                let keys = id == "sensor.cpuTemperature" ? cpuKeys : sensorKeys.filter { $0.hasPrefix("Tg") }
                let values = keys.compactMap { reader.read($0) }.filter { SMCReader.plausible($0, unit: .celsius) }
                result[id] = values.max().map { Reading($0) } ?? Reading(unavailable: "No mapped sensor; inspect individual keys")
            } else {
                let key = String(id.dropFirst(7))
                if let unit = SMCReader.unit(for: key), let value = reader.read(key), SMCReader.plausible(value, unit: unit) {
                    result[id] = Reading(value)
                } else { result[id] = Reading(unavailable: "Sensor not reported") }
            }
        }
        return result
    }

    private func rate(_ id: String, _ counter: UInt64, now: Double, multiplier: Double = 1) -> Reading {
        var delta = counters[id] ?? CounterDelta()
        let value = delta.sample(counter, at: now)
        counters[id] = delta
        return value.map { Reading($0 * multiplier) } ?? Reading(unavailable: "Measuring interval…")
    }

    private func cpu() -> [String: Reading] {
        var result: [String: Reading] = [:]
        var processorCount: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        let status = host_processor_info(hostPort, PROCESSOR_CPU_LOAD_INFO, &processorCount, &info, &count)
        if status == KERN_SUCCESS, let info {
            defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.size)) }
            let current = (0..<Int(processorCount)).map { core in
                (0..<4).map { UInt32(bitPattern: info[core * 4 + $0]) }
            }
            if let old = oldCPUTicks, old.count == current.count {
                var perCore: [(user: Double, system: Double, idle: Double)] = []
                for index in current.indices {
                    if let usage = CPUDelta.percentages(previous: old[index], current: current[index]) {
                        perCore.append(usage)
                        result["cpu.core.\(index)"] = Reading(usage.user + usage.system)
                    }
                }
                if !perCore.isEmpty {
                    let n = Double(perCore.count)
                    let user = perCore.reduce(0) { $0 + $1.user } / n
                    let system = perCore.reduce(0) { $0 + $1.system } / n
                    result["cpu.usage"] = Reading(user + system)
                    result["cpu.user"] = Reading(user); result["cpu.system"] = Reading(system)
                    result["cpu.idle"] = Reading(perCore.reduce(0) { $0 + $1.idle } / n)
                }
            }
            oldCPUTicks = current
            for id in ["cpu.usage", "cpu.user", "cpu.system", "cpu.idle"] where result[id] == nil { result[id] = Reading(unavailable: "Measuring interval…") }
        }
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) == 3 {
            for (index, minutes) in [1,5,15].enumerated() { result["cpu.load\(minutes)"] = Reading(loads[index]) }
        }
        for (id, key) in [("cpu.cores", "hw.logicalcpu"), ("cpu.performanceCores", "hw.perflevel0.physicalcpu"), ("cpu.efficiencyCores", "hw.perflevel1.physicalcpu")] {
            if let count: Int32 = Self.sysctlValue(key, initial: 0) { result[id] = Reading(Double(count)) }
        }
        return result
    }

    private func memory(now: Double) -> [String: Reading] {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(hostPort, HOST_VM_INFO64, $0, &count) }
        }
        guard status == KERN_SUCCESS else { return [:] }
        var size: vm_size_t = 0
        guard host_page_size(hostPort, &size) == KERN_SUCCESS else { return [:] }
        let page = Double(size)
        let total = Double(Self.sysctlValue("hw.memsize", initial: UInt64(0)) ?? 0)
        let app = max(0, Double(stats.internal_page_count) - Double(stats.purgeable_count)) * page
        let wired = Double(stats.wire_count) * page
        let compressed = Double(stats.compressor_page_count) * page
        let used = app + wired + compressed
        var result: [String: Reading] = [
            "memory.total": Reading(total), "memory.app": Reading(app), "memory.wired": Reading(wired),
            "memory.compressed": Reading(compressed), "memory.used": Reading(used),
            "memory.cached": Reading((Double(stats.external_page_count) + Double(stats.purgeable_count)) * page),
            "memory.free": Reading(Double(stats.free_count) * page), "memory.active": Reading(Double(stats.active_count) * page),
            "memory.inactive": Reading(Double(stats.inactive_count) * page), "memory.purgeable": Reading(Double(stats.purgeable_count) * page),
            "memory.filebacked": Reading(Double(stats.external_page_count) * page)
        ]
        if total > 0 { result["memory.usage"] = Reading(used / total * 100) }
        else { result["memory.total"] = Reading(unavailable: "Installed memory not reported") }
        if let level: Int32 = Self.sysctlValue("kern.memorystatus_vm_pressure_level", initial: 0) {
            if let label = [1: "Normal", 2: "Warning", 4: "Critical"][Int(level)] { result["memory.pressure"] = Reading(text: label) }
        }
        if let swap = Self.sysctlValue("vm.swapusage", initial: xsw_usage()) {
            result["memory.swapUsed"] = Reading(Double(swap.xsu_used))
            result["memory.swapTotal"] = Reading(Double(swap.xsu_total))
            result["memory.swapFree"] = Reading(Double(swap.xsu_avail))
        }
        for (id, value) in [("memory.swapIn", stats.swapins), ("memory.swapOut", stats.swapouts), ("memory.pageIn", stats.pageins), ("memory.pageOut", stats.pageouts)] {
            result[id] = rate(id, value, now: now, multiplier: page)
        }
        return result
    }

    private func gpu() -> [String: Reading] {
        var result: [String: Reading] = [:]
        let entries = Self.registryProperties(className: "IOAccelerator", property: "PerformanceStatistics")
        for (id, key) in [("gpu.usage", "Device Utilization %"), ("gpu.renderer", "Renderer Utilization %"), ("gpu.tiler", "Tiler Utilization %")] {
            let values = entries.compactMap { ($0[key] as? NSNumber)?.doubleValue }.filter { (0...100).contains($0) }
            if let max = values.max() { result[id] = Reading(max) }
        }
        for (id, key) in [("gpu.memoryUsed", "In use system memory"), ("gpu.memoryAllocated", "Alloc system memory")] {
            let values = entries.compactMap { ($0[key] as? NSNumber)?.doubleValue }.filter { $0 >= 0 }
            if !values.isEmpty { result[id] = Reading(values.reduce(0, +)) }
        }
        return result
    }

    private func disk(now: Double) -> [String: Reading] {
        var result: [String: Reading] = [:]
        var volume = statfs()
        if statfs(NSHomeDirectory(), &volume) == 0 {
            let total = Double(volume.f_blocks) * Double(volume.f_bsize)
            let free = Double(volume.f_bfree) * Double(volume.f_bsize)
            result["disk.total"] = Reading(total); result["disk.free"] = Reading(free)
            result["disk.used"] = Reading(max(0, total - free))
            result["disk.available"] = Reading(Double(volume.f_bavail) * Double(volume.f_bsize))
            if total > 0 { result["disk.usage"] = Reading((total - free) / total * 100) }
        }
        let entries = Self.registryProperties(className: "IOBlockStorageDriver", property: "Statistics")
        // Driver membership changes re-prime the aggregate rate instead of producing a spike.
        let membership = Set(entries.compactMap { ($0["_registryID"] as? NSNumber)?.uint64Value })
        if diskMembership != membership {
            for id in ["disk.read", "disk.write", "disk.readIOPS", "disk.writeIOPS"] { counters[id] = nil }
            diskMembership = membership
        }
        for (id, key) in [("disk.read", "Bytes (Read)"), ("disk.write", "Bytes (Write)"), ("disk.readIOPS", "Operations (Read)"), ("disk.writeIOPS", "Operations (Write)")] {
            let values = entries.compactMap { ($0[key] as? NSNumber)?.uint64Value }
            if !values.isEmpty { result[id] = rate(id, values.reduce(0, &+), now: now) }
        }
        return result
    }

    private func system() -> [String: Reading] {
        var result: [String: Reading] = [:]
        if let boot = Self.sysctlValue("kern.boottime", initial: timeval()) {
            result["system.uptime"] = Reading(max(0, Date().timeIntervalSince1970 - Double(boot.tv_sec)))
        }
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "Nominal"
        case .fair: thermal = "Fair"
        case .serious: thermal = "Serious"
        case .critical: thermal = "Critical"
        @unknown default: thermal = "Unknown"
        }
        result["system.thermal"] = Reading(text: thermal)
        result["system.lowPower"] = Reading(text: ProcessInfo.processInfo.isLowPowerModeEnabled ? "On" : "Off")
        return result
    }

    private func battery() -> [String: Reading] {
        var result: [String: Reading] = [:]
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                      description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                if let current = description[kIOPSCurrentCapacityKey] as? NSNumber,
                   let max = description[kIOPSMaxCapacityKey] as? NSNumber, max.doubleValue > 0 {
                    result["battery.charge"] = Reading(current.doubleValue / max.doubleValue * 100)
                }
                let powerState = description[kIOPSPowerSourceStateKey] as? String
                let onAC = powerState == kIOPSACPowerValue
                let charging = description[kIOPSIsChargingKey] as? Bool
                if charging == true { result["battery.state"] = Reading(text: "Charging") }
                else if onAC { result["battery.state"] = Reading(text: charging == false ? "AC · not charging" : "On AC power") }
                else if powerState == kIOPSBatteryPowerValue { result["battery.state"] = Reading(text: "On battery") }
                let remaining = IOPSGetTimeRemainingEstimate()
                result["battery.remaining"] = powerState == kIOPSBatteryPowerValue && remaining > 0 ? Reading(remaining) : Reading(unavailable: onAC ? "On AC power" : "Estimate unavailable")
                if charging == true, let minutes = description[kIOPSTimeToFullChargeKey] as? NSNumber,
                   minutes.doubleValue > 0, minutes.doubleValue < 65535 {
                    result["battery.timeToFull"] = Reading(minutes.doubleValue * 60)
                } else { result["battery.timeToFull"] = Reading(unavailable: charging == false ? "Not charging" : "Estimate unavailable") }
                if let condition = description[kIOPSBatteryHealthKey] as? String { result["battery.condition"] = Reading(text: condition) }
                break
            }
        }
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if entry != 0 {
            defer { IOObjectRelease(entry) }
            func number(_ key: String) -> NSNumber? {
                IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
            }
            if let value = number("Temperature")?.doubleValue, value > 0, value < 15000 { result["battery.temperature"] = Reading(value / 100) }
            if let cycles = number("CycleCount") { result["battery.cycles"] = Reading(cycles.doubleValue) }
            if let capacity = number("AppleRawMaxCapacity")?.doubleValue, let design = number("DesignCapacity")?.doubleValue, design > 0 {
                result["battery.capacityRatio"] = Reading(capacity / design * 100)
            }
            if let rawVoltage = number("Voltage")?.doubleValue, rawVoltage > 0 {
                result["battery.voltage"] = Reading(rawVoltage / 1000)
                if let rawCurrent = number("InstantAmperage") ?? number("Amperage") {
                    let amps = Double(rawCurrent.int64Value) / 1000
                    result["battery.current"] = Reading(amps)
                    result["battery.power"] = Reading(rawVoltage / 1000 * amps)
                }
            }
        }
        if let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
           let watts = adapter[kIOPSPowerAdapterWattsKey] as? NSNumber {
            result["battery.adapterRated"] = Reading(watts.doubleValue)
        }
        return result
    }

    private func network(now: Double, sampleRates: Bool = true) -> SampleBatch {
        struct Interface { let name: String; let flags: Int32; let data: if_data64 }
        // IFDATA_GENERAL preserves full-width totals on current macOS. The routing
        // message interface returned narrowed/quantized totals on the acceptance Mac.
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFALLDATA, 0, IFDATA_GENERAL]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return .init(readings: [:], discovered: [], sourceErrors: ["Interface counters unavailable"]) }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &bytes, &size, nil, 0) == 0 else { return .init(readings: [:], discovered: [], sourceErrors: ["Interface counters changed; retry"]) }
        var interfaces: [Interface] = []
        bytes.withUnsafeBytes { buffer in
            let stride = MemoryLayout<ifmibdata>.stride
            for offset in Swift.stride(from: 0, through: max(0, size - stride), by: stride) where offset + stride <= size {
                var entry = buffer.loadUnaligned(fromByteOffset: offset, as: ifmibdata.self)
                let name = withUnsafeBytes(of: &entry.ifmd_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                let flags = Int32(bitPattern: entry.ifmd_flags)
                if !name.isEmpty && flags & IFF_LOOPBACK == 0 {
                    interfaces.append(.init(name: name, flags: flags, data: entry.ifmd_data))
                }
            }
        }
        var result = SampleBatch(readings: [:], discovered: [], sourceErrors: [])
        let running = interfaces.filter { $0.flags & IFF_UP != 0 && $0.flags & IFF_RUNNING != 0 }
        let hardware = running.filter { $0.name.hasPrefix("en") }
        let membership = Set(hardware.map(\.name))
        if sampleRates && membership != networkMembership {
            for id in ["network.download", "network.upload", "network.packetsIn", "network.packetsOut"] { counters[id] = nil }
            networkMembership = membership
        }
        if !hardware.isEmpty {
            let received = hardware.reduce(UInt64(0)) { $0 &+ $1.data.ifi_ibytes }
            let sent = hardware.reduce(UInt64(0)) { $0 &+ $1.data.ifi_obytes }
            if sampleRates {
                result.readings["network.download"] = rate("network.download", received, now: now)
                result.readings["network.upload"] = rate("network.upload", sent, now: now)
                result.readings["network.packetsIn"] = rate("network.packetsIn", hardware.reduce(0) { $0 &+ $1.data.ifi_ipackets }, now: now)
                result.readings["network.packetsOut"] = rate("network.packetsOut", hardware.reduce(0) { $0 &+ $1.data.ifi_opackets }, now: now)
            }
            result.readings["network.received"] = Reading(Double(received))
            result.readings["network.sent"] = Reading(Double(sent))
        }
        for interface in interfaces {
            let isUp = interface.flags & IFF_UP != 0 && interface.flags & IFF_RUNNING != 0
            for (suffix, title, short, unit, value) in [
                ("download", "download rate", "↓", MetricUnit.bytesPerSecond, interface.data.ifi_ibytes),
                ("upload", "upload rate", "↑", .bytesPerSecond, interface.data.ifi_obytes),
                ("received", "bytes received", "Rx", .bytes, interface.data.ifi_ibytes),
                ("sent", "bytes sent", "Tx", .bytes, interface.data.ifi_obytes)
            ] {
                let id = "network.if.\(interface.name).\(suffix)"
                result.discovered.append(Metric(id, "\(interface.name) · \(title)", "\(interface.name) \(short)", .network, unit,
                    "This interface only. Virtual/VPN interfaces can overlap the hardware aggregate. Counters restart with interface creation/reset.", source: "IFMIB IFDATA_GENERAL \(interface.name)", advanced: true))
                if unit == .bytes {
                    result.readings[id] = Reading(Double(value))
                } else if isUp && sampleRates {
                    result.readings[id] = rate(id, value, now: now)
                } else {
                    if sampleRates { counters[id] = nil }
                    result.readings[id] = Reading(unavailable: "Interface is inactive")
                }
            }
        }
        return result
    }

    static func sysctlValue<T>(_ name: String, initial: T) -> T? {
        var value = initial
        var size = MemoryLayout<T>.size
        let status = withUnsafeMutableBytes(of: &value) { sysctlbyname(name, $0.baseAddress, &size, nil, 0) }
        return status == 0 && size == MemoryLayout<T>.size ? value : nil
    }
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size < 4096 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    static func registryProperties(className: String, property: String) -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [[String: Any]] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            if var values = IORegistryEntryCreateCFProperty(entry, property as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
                var id: UInt64 = 0
                if IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS { values["_registryID"] = NSNumber(value: id) }
                result.append(values)
            }
        }
        return result
    }
}
