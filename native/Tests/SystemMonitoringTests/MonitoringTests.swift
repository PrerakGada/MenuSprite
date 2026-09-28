import Foundation
import AppKit
import Testing
@testable import SystemMonitoring

@Test func cpuMathAndWrap() {
    let value = CPUDelta.percentages(previous: [10,10,10,0], current: [30,20,80,0])!
    #expect(abs(value.user - 20) < 0.001)
    #expect(abs(value.system - 10) < 0.001)
    #expect(abs(value.idle - 70) < 0.001)
    #expect(CPUDelta.percentages(previous: [1,1,1,1], current: [1,1,1,1]) == nil)
    let wrapped = CPUDelta.percentages(previous: [UInt32.max-2,0,0,0], current: [2,0,5,0])!
    #expect(abs(wrapped.user - 50) < 0.001)
}
@Test func counterRatesNeedAnIntervalAndHandleResets() {
    var counter = CounterDelta()
    #expect(counter.sample(1000, at: 1) == nil)
    #expect(counter.sample(3000, at: 3) == 1000)
    #expect(counter.sample(5, at: 4) == nil)
    #expect(counter.sample(5, at: 5) == 0)
    counter.reset()
    #expect(counter.sample(100, at: 6) == nil)
    var large = CounterDelta()
    #expect(large.sample(20_000_000_000, at: 1) == nil)
    #expect(large.sample(20_000_010_000, at: 3) == 5000)
}
@Test func firmwareDecoding() {
    #expect(SMCReader.decode([0x19, 0x80], type: "sp78") == 25.5)
    #expect(SMCReader.decode([0x1F, 0x40], type: "fpe2") == 2000)
    #expect(SMCReader.decode([0,0,0xC8,0x41], type: "flt ") == 25)
    #expect(SMCReader.decode([0xFF,0x80], type: "sp78") == -0.5)
    #expect(SMCReader.decode([0], type: "data") == nil)
    #expect(SMCReader.decode([0,0,0x80,0x7F], type: "flt ") == nil)
    #expect(!SMCReader.plausible(0, unit: .celsius))
    #expect(SMCReader.plausible(0, unit: .rpm))
}
@Test func catalogAndConfiguration() {
    #expect(Set(MonitoringCatalog.base.map(\.id)).count == MonitoringCatalog.base.count)
    #expect(MonitoringCatalog.base.allSatisfy { !$0.source.isEmpty && !$0.detail.isEmpty })
    var config = SpriteConfiguration(name: "  ", metricIDs: ["cpu.usage", "cpu.usage", "missing.device"])
    config.interval = 0.01; config.fontSize = .infinity; config.decimals = 99; config.colorHex = "bogus"
    config.normalize()
    #expect(config.name == "My sprite")
    #expect(config.metricIDs == ["cpu.usage", "missing.device"])
    #expect(config.interval == 2 && config.fontSize == 12 && config.decimals == 2)
    #expect(config.colorHex == "auto")
    config.enabled = false
    #expect(config.showInMenuBar) // visibility and enablement are independent
}
@Test func readingsDoNotInventZero() {
    #expect(!Reading(Double.nan).available)
    #expect(!Reading(unavailable: "Not supported").available)
    #expect(Reading(0).available)
    let memory = MonitoringCatalog.base.first { $0.id == "memory.used" }!
    #expect(MetricFormat.string(Reading(1073741824), metric: memory) == "1.0 GiB")
    let temperature = MonitoringCatalog.base.first { $0.id == "battery.temperature" }!
    var config = SpriteConfiguration(); config.fahrenheit = true
    #expect(MetricFormat.string(Reading(0), metric: temperature, config: config) == "32°F")
}

@Test func readoutLayoutMigrationAndPersistence() throws {
    var original = SpriteConfiguration(name: "Existing", metricIDs: ["cpu.usage", "memory.usage"])
    original.interval = 5; original.colorHex = "78DFBD"
    let data = try JSONEncoder().encode(original)
    var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    legacy.removeValue(forKey: "readoutLayout")
    var decoded = try JSONDecoder().decode(SpriteConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(decoded.layout == .inline)
    #expect(decoded.id == original.id && decoded.metricIDs == original.metricIDs)
    #expect(decoded.interval == 5 && decoded.colorHex == "78DFBD")
    decoded.layout = .stacked
    decoded.normalize()
    let restored = try JSONDecoder().decode(SpriteConfiguration.self, from: JSONEncoder().encode(decoded))
    #expect(restored == decoded && restored.layout == .stacked)
}

@Test @MainActor func stackedReadoutsAreCompactAndFitTheBar() {
    let columns = [ReadoutColumn(label: "RAM", value: "85%"), ReadoutColumn(label: "CPU", value: "13%")]
    var config = SpriteConfiguration(); config.layout = .stacked
    for height: CGFloat in [22,24,28] {
        for size in [10.0,12,16] {
            config.fontSize = size
            let layout = StackedReadout.layout(columns: columns, config: config, height: height)
            #expect(layout.columns.count == 2)
            for placement in layout.columns {
                #expect(placement.value.minY >= 0 && placement.value.maxY <= height)
                #expect((placement.label?.minY ?? 0) >= placement.value.maxY)
                #expect((placement.label?.maxY ?? 0) <= height)
            }
            #expect(layout.columns[0].value.maxX < layout.columns[1].value.minX)
        }
    }
    config.fontSize = 12
    let layout = StackedReadout.layout(columns: columns, config: config, height: 24)
    let inlineWidth = (" RAM 85%  CPU 13%" as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)]).width + 14
    #expect(layout.size.width < inlineWidth)
    #expect(StackedReadout.image(columns: columns, config: config, height: 24).isTemplate)
    config.colorHex = "78DFBD"
    #expect(!StackedReadout.image(columns: columns, config: config, height: 24).isTemplate)
    config.showLabels = false
    #expect(StackedReadout.layout(columns: columns, config: config, height: 24).columns.allSatisfy { $0.label == nil })
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MENUSPRITE_LIVE_PROBE"] == "1"))
func liveSourceProbe() async throws {
    let sampler = SystemSampler()
    let sensors = await sampler.discoverSensors()
    print("SMC discovered: \(sensors.discovered.count), errors: \(sensors.sourceErrors)")
    print("Fan keys: \(sensors.discovered.filter { $0.unit == .rpm }.map(\.id))")
    let interfaces = await sampler.discoverInterfaces()
    #expect(interfaces.allSatisfy { $0.id.hasPrefix("network.if.") })
    let ids = Set(MonitoringCatalog.base.map(\.id))
    let first = await sampler.sample(ids: ids, groups: Set(MetricGroup.allCases))
    #expect(first.readings["network.download"]?.number == nil)
    _ = await sampler.discoverInterfaces() // discovering names must not reset an active rate baseline
    try await Task.sleep(for: .seconds(1))
    let sample = await sampler.sample(ids: ids, groups: Set(MetricGroup.allCases))
    for id in ["cpu.usage", "memory.usage", "memory.total", "network.download", "disk.read", "gpu.usage", "battery.charge", "battery.temperature", "sensor.PSTR", "sensor.PDTR", "sensor.cpuTemperature", "sensor.gpuTemperature"] {
        let value = sample.readings[id]
        print("\(id): \(value?.number.map(String.init(describing:)) ?? value?.text ?? value?.issue ?? "missing")")
    }
    #expect(sample.readings["cpu.usage"]?.available == true)
    #expect(sample.readings["memory.total"]?.number ?? 0 > 0)
    #expect(sample.readings["network.download"]?.available == true)
    await sampler.idle()
}

@Test @MainActor func iconFreeBoldReadoutKeepsFullValueHeight() throws {
    var config = SpriteConfiguration(); config.layout = .stacked; config.fontSize = 14; config.bold = true
    let columns = [ReadoutColumn(label:"CPU",value:"100%")]
    let withIcon = StackedReadout.layout(columns:columns,config:config,height:24)
    config.showIcon = false; config.colorHex = "FFFFFF"
    let layout = StackedReadout.layout(columns:columns,config:config,height:24)
    #expect(layout.iconRect == .zero)
    #expect(withIcon.size.width - layout.size.width == 19)
    // A label above the value costs the value 1.5 pt, and nothing else shrinks it further.
    #expect(layout.valueFont.pointSize == 12.5)
    #expect(!StackedReadout.image(columns:columns,config:config,height:24).isTemplate)
    let restored = try JSONDecoder().decode(SpriteConfiguration.self,from:JSONEncoder().encode(config))
    #expect(!restored.showIcon)
    var legacy = try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(config)) as? [String:Any])
    legacy.removeValue(forKey:"menuBarIconVisible")
    #expect(try JSONDecoder().decode(SpriteConfiguration.self,from:JSONSerialization.data(withJSONObject:legacy)).showIcon)
    let metric = try #require(MonitoringCatalog.base.first { $0.id == "sensor.PSTR" })
    config.decimals = 0
    #expect(MetricFormat.string(Reading(22.4),metric:metric,config:config) == "22 W")
}

@Test @MainActor func pairedReadingsShareAColumnAndFitMenuBar() throws {
    var config = SpriteConfiguration(); config.layout = .twoRows; config.showIcon = false; config.bold = true; config.fontSize = 12
    for height: CGFloat in [22, 24, 28] {
        for columns in [
            [ReadoutColumn(label: "↑", value: "250.0 KiB/s"), .init(label: "↓", value: "12.3 MiB/s")],
            [ReadoutColumn(label: "FAN", value: "5200 rpm"), .init(label: "TEMP", value: "99°C")]
        ] {
            let layout = StackedReadout.layout(columns: columns, config: config, height: height)
            #expect(layout.columns.count == 2 && layout.iconRect == .zero)
            #expect(layout.columns[0].value.minY > layout.columns[1].value.maxY)
            #expect(abs(layout.columns[0].value.maxX - layout.columns[1].value.maxX) < 0.01)
            for row in layout.columns {
                #expect(row.value.minY >= 0 && row.value.maxY <= height)
                #expect((row.label?.minY ?? 0) >= 0 && (row.label?.maxY ?? 0) <= height)
                #expect((row.label?.maxX ?? 0) < row.value.minX)
            }
        }
    }
    let three = StackedReadout.layout(columns: [.init(label: "A", value: "1"), .init(label: "B", value: "2"), .init(label: "C", value: "3")], config: config, height: 24)
    #expect(three.columns[2].value.minX > three.columns[0].value.maxX)
    let restored = try JSONDecoder().decode(SpriteConfiguration.self, from: JSONEncoder().encode(config))
    #expect(restored.layout == .twoRows)
}

@Test @MainActor func menuBarWidthHoldsWhileValuesChange() throws {
    let percent = try #require(MonitoringCatalog.base.first { $0.id == "cpu.usage" })
    let download = try #require(MonitoringCatalog.base.first { $0.id == "network.download" })
    let power = try #require(MonitoringCatalog.base.first { $0.id == "sensor.PSTR" })
    let temperature = try #require(MonitoringCatalog.base.first { $0.id == "sensor.cpuTemperature" })
    // A menu-bar number never runs past three characters: the decimal goes once the whole part needs it.
    var config = SpriteConfiguration(); config.decimals = 1
    #expect(MetricFormat.string(Reading(95.42 * 1024), metric: download, config: config, compact: true) == "95.4 KiB/s")
    #expect(MetricFormat.string(Reading(100.4 * 1024), metric: download, config: config, compact: true) == "100 KiB/s")
    #expect(MetricFormat.string(Reading(99.97 * 1024), metric: download, config: config, compact: true) == "100 KiB/s")
    #expect(MetricFormat.string(Reading(99.8), metric: temperature, config: config, compact: true) == "99.8°C")
    #expect(MetricFormat.string(Reading(101.2), metric: temperature, config: config, compact: true) == "101°C")
    #expect(MetricFormat.string(Reading(121.6), metric: power, config: config, compact: true) == "122 W")
    // Panels keep the precision that was asked for.
    #expect(MetricFormat.string(Reading(121.64), metric: power, config: config) == "121.6 W")
    // Units step up at 1000, so no value needs a fourth whole digit.
    #expect(MetricFormat.string(Reading(1010 * 1024), metric: download) == "1.0 MiB/s")

    for layout in SpriteReadoutLayout.allCases {
        var config = SpriteConfiguration(); config.layout = layout; config.showIcon = false; config.decimals = 1
        func width(_ values: [(Metric, String)]) -> CGFloat {
            StackedReadout.layout(columns: values.map { ReadoutColumn(label: "X", value: $0.1,
                widthTemplates: MetricFormat.widthTemplates(metric: $0.0, config: config)) }, config: config, height: 24).size.width
        }
        // Digit count, unit letters and ink shape all vary; the item width must not.
        let widths = [
            width([(percent, "9%"), (download, "0 B/s")]), width([(percent, "99%"), (download, "999 KiB/s")]),
            width([(percent, "11%"), (download, "11.1 KiB/s")]), width([(percent, "88%"), (download, "88.8 MiB/s")]),
        ]
        #expect(Set(widths).count == 1, "\(layout): \(widths)")
        #expect(width([(power, "8.1 W")]) == width([(power, "88.8 W")]))
        // The reservations are deliberately tight: at whole numbers — how CPU, RAM and power are
        // actually shown — 100% and a 100 W draw are rare enough to widen the item for.
        config.decimals = 0
        #expect(width([(percent, "100%")]) > width([(percent, "99%")]))
        #expect(width([(power, "122 W")]) > width([(power, "99 W")]))
        config.decimals = 1
    }
    // Once a value has needed more room, passing the reserved widths back keeps it.
    config.layout = .stacked
    let wide = StackedReadout.layout(columns: [.init(label: "P", value: "122 W")], config: config, height: 24)
    let after = StackedReadout.layout(columns: [.init(label: "P", value: "8.0 W")], config: config, height: 24, reserved: wide.valueWidths)
    #expect(after.size.width == wide.size.width)
}

@Test @MainActor func stackedLabelsGrowWithoutWideningTheItem() throws {
    let percent = try #require(MonitoringCatalog.base.first { $0.id == "cpu.usage" })
    var config = SpriteConfiguration(); config.layout = .stacked; config.showIcon = false; config.fontSize = 14
    func placed(_ label: String, _ value: String) -> StackedReadout.Layout {
        StackedReadout.layout(columns: [ReadoutColumn(label: label, value: value,
            widthTemplates: MetricFormat.widthTemplates(metric: percent, config: config))],
            config: config, height: NSStatusBar.system.thickness)
    }
    let cpu = placed("CPU", "13%")
    // The label is readable and the value gives up a point and a half for it.
    #expect(cpu.labelFont.pointSize == 8.5)
    #expect(cpu.valueFont.pointSize == 12.5)
    // Both rows still fit the bar.
    #expect(cpu.columns[0].value.minY >= 0)
    #expect((cpu.columns[0].label?.maxY ?? 0) <= NSStatusBar.system.thickness)
    // Narrower than the old 14 pt value with its 6.5 pt label.
    var old = config; old.fontSize = 15.5
    #expect(cpu.size.width < StackedReadout.layout(columns: [.init(label: "CPU", value: "13%")], config: old,
                                                  height: NSStatusBar.system.thickness).size.width)
    // A long label takes only the room the number already needed; it never pushes the item wider.
    let claude = placed("Claude", "49%")
    #expect(claude.labelFont.pointSize < cpu.labelFont.pointSize)
    #expect(claude.size.width == cpu.size.width)
}
