import Foundation

public enum MetricUnit: String, Codable, Sendable {
    case percent, bytes, bytesPerSecond, count, perSecond, seconds, celsius, watts, volts, amps, rpm, dollars, text
}
public enum MetricGroup: String, Codable, CaseIterable, Sendable {
    case cpu = "CPU", memory = "Memory", network = "Network", disk = "Disk"
    case gpu = "GPU", battery = "Battery", system = "System", sensors = "Sensors & power"
    /// Claude and Codex limits, fetched from the providers by the app, never by `SystemSampler`.
    case ai = "AI usage"
    public var icon: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .network: "network"
        case .disk: "internaldrive"
        case .gpu: "display"
        case .battery: "battery.100percent"
        case .system: "desktopcomputer"
        case .sensors: "thermometer.medium"
        case .ai: "sparkles"
        }
    }
}
public struct Metric: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let shortName: String
    public let group: MetricGroup
    public let unit: MetricUnit
    public let detail: String
    public let source: String
    public let advanced: Bool
    public init(_ id: String, _ name: String, _ shortName: String, _ group: MetricGroup, _ unit: MetricUnit,
                _ detail: String, source: String, advanced: Bool = false) {
        self.id = id; self.name = name; self.shortName = shortName; self.group = group; self.unit = unit
        self.detail = detail; self.source = source; self.advanced = advanced
    }
}
public struct Reading: Codable, Sendable, Equatable {
    public let number: Double?
    public let text: String?
    public let issue: String?
    public let measuredAt: Date
    public init(_ value: Double, at: Date = Date()) {
        self.number = value.isFinite ? value : nil
        self.text = nil; self.issue = value.isFinite ? nil : "Invalid sensor value"; self.measuredAt = at
    }
    public init(text: String, at: Date = Date()) {
        self.number = nil; self.text = text; self.issue = nil; self.measuredAt = at
    }
    public init(unavailable: String, at: Date = Date()) {
        self.number = nil; self.text = nil; self.issue = unavailable; self.measuredAt = at
    }
    public var available: Bool { number != nil || text != nil }
}
public struct HistoryPoint: Codable, Sendable {
    public let time: Date; public let value: Double
    public init(time: Date, value: Double) { self.time = time; self.value = value }
}

public enum SpriteReadoutLayout: String, Codable, CaseIterable, Sendable {
    case inline, stacked, twoRows, bar
    public var title: String {
        switch self {
        case .inline: "Inline labels"; case .stacked: "Labels above values"; case .twoRows: "Two rows"
        case .bar: "Level bar"
        }
    }
}

/// Where a battery item shows its charge: drawn inside the battery glyph, or as text beside it.
public enum BatteryPercentPlacement: String, Codable, CaseIterable, Sendable {
    case inside, left, right
    public var title: String {
        switch self { case .inside: "Inside"; case .left: "Left"; case .right: "Right" }
    }
}

public enum SpriteColorRule: String, Codable, CaseIterable, Sendable {
    case fixed, usagePace, usagePacePercent, networkDirection, memoryPressure, powerDraw
    public var title: String {
        switch self {
        case .fixed: "Fixed color"
        case .usagePace: "AI usage pace"
        case .usagePacePercent: "AI usage pace (% only)"
        case .networkDirection: "Network: upload orange, download green"
        case .memoryPressure: "Memory pressure: label green, yellow, red"
        case .powerDraw: "Power draw label: yellow from 35 W, red above 45 W"
        }
    }
    /// The kernel's pressure level (the `memory.pressure` text) as a menu-bar color.
    /// An unreported level returns nil so the text keeps its own color rather than a guessed state.
    public static func memoryPressureHex(_ level: String?) -> String? {
        switch level { case "Normal": "30D158"; case "Warning": "FFD60A"; case "Critical": "FF453A"; default: nil }
    }
    /// A watts reading as a menu-bar color: its own text color below 35 W, yellow from 35 W to 45 W,
    /// red above 45 W. A missing reading returns nil rather than a guessed level.
    public static func powerDrawHex(_ watts: Double?) -> String? {
        guard let watts, watts.isFinite, watts >= 35 else { return nil }
        return watts > 45 ? "FF453A" : "FFD60A"
    }
    public var usesUsagePace: Bool { self == .usagePace || self == .usagePacePercent }
}

public struct SpriteConfiguration: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var symbol: String
    public var metricIDs: [String]
    public var enabled: Bool
    public var showInMenuBar: Bool
    public var interval: Double
    public var showLabels: Bool
    public var showUnits: Bool
    public var fontSize: Double
    public var bold: Bool
    public var colorHex: String // "auto" follows the system's menu-bar appearance.
    public var decimals: Int
    public var fahrenheit: Bool
    public var networkBits: Bool
    // Optional storage allows settings saved before this field existed to decode.
    private var readoutLayout: SpriteReadoutLayout?
    private var menuBarIconVisible: Bool?
    private var menuBarIconColor: String?
    public var iconColorHex: String {
        get { menuBarIconColor ?? "text" }
        set { menuBarIconColor = newValue }
    }
    private var readoutColorRule: SpriteColorRule?
    /// Level-bar thresholds in percent: the fill turns amber above `barWarning` and red above
    /// `barAlert`. Optional so configurations saved before the bar existed still decode.
    private var levelBarWarning: Int?
    private var levelBarAlert: Int?
    public var barWarning: Int {
        get { levelBarWarning ?? 60 }
        set { levelBarWarning = newValue }
    }
    public var barAlert: Int {
        get { levelBarAlert ?? 85 }
        set { levelBarAlert = newValue }
    }
    /// The level bar's fill color for a percentage, or nil while it is below the warning line.
    public func barHex(percent: Double) -> String? {
        percent > Double(barAlert) ? "FF453A" : percent > Double(barWarning) ? "FFD60A" : nil
    }
    /// Optional labels keep older configurations unchanged and allow personal readout names.
    private var readoutLabels: [String: String]?
    public func label(for metricID: String, fallback: String) -> String {
        let value = readoutLabels?[metricID]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? fallback : String(value.prefix(24))
    }
    public func customLabel(for metricID: String) -> String { readoutLabels?[metricID] ?? "" }
    public mutating func setLabel(_ label: String, for metricID: String) {
        if readoutLabels == nil { readoutLabels = [:] }
        readoutLabels?[metricID] = String(label.prefix(24))
    }
    public var colorRule: SpriteColorRule {
        get { readoutColorRule ?? .fixed }
        set { readoutColorRule = newValue }
    }
    public var showIcon: Bool {
        get { menuBarIconVisible ?? true }
        set { menuBarIconVisible = newValue }
    }
    private var batteryPercentPosition: BatteryPercentPlacement?
    /// Battery items only. Unset configurations draw the charge inside the glyph.
    public var batteryPercentPlacement: BatteryPercentPlacement {
        get { batteryPercentPosition ?? .inside }
        set { batteryPercentPosition = newValue }
    }
    /// The charge is drawn by the battery glyph itself, so it is not also a text column.
    public var drawsChargeInsideBattery: Bool {
        isBatteryItem && showIcon && batteryPercentPlacement == .inside && metricIDs.contains("battery.charge")
    }
    /// The icon follows the readings instead of leading them.
    public var iconTrailing: Bool { isBatteryItem && showIcon && batteryPercentPlacement == .left }
    /// A sprite made only of battery readings draws the live battery glyph and
    /// carries the charge-control menu on secondary click.
    public var isBatteryItem: Bool { !metricIDs.isEmpty && metricIDs.allSatisfy { $0.hasPrefix("battery.") } }
    public var layout: SpriteReadoutLayout {
        get { readoutLayout ?? .inline }
        set { readoutLayout = newValue }
    }
    /// The sprite's face, values and rules, edited in the studio. Nil only for a sprite saved before
    /// designs existed; the store converts those on load. The settings above stay in the file, so an
    /// older build still draws the sprite as it was.
    private var spriteDesign: SpriteDesign?
    public var design: SpriteDesign? {
        get { spriteDesign }
        set { spriteDesign = newValue }
    }
    /// The gallery template this sprite was made from, which "Reset to template" goes back to.
    /// Nil for a sprite made from scratch or saved before the gallery existed.
    public var templateID: String?
    public init(name: String = "My sprite", symbol: String = "gauge.with.dots.needle.50percent",
                metricIDs: [String] = ["cpu.usage"], enabled: Bool = true, showInMenuBar: Bool = true) {
        id = UUID(); self.name = name; self.symbol = symbol; self.metricIDs = metricIDs
        self.enabled = enabled; self.showInMenuBar = showInMenuBar; interval = 2
        showLabels = true; showUnits = true; fontSize = 12; bold = false; colorHex = "auto"
        decimals = 0; fahrenheit = false; networkBits = false
        readoutLayout = .inline
        menuBarIconVisible = true
    }
    public mutating func normalize() {
        name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        if name.isEmpty { name = "My sprite" }
        var seen: Set<String> = []
        if var design = spriteDesign {
            // The readings a designed sprite shows are whatever its face draws; a sprite of commands
            // alone shows none, and that is allowed.
            design.prune()
            spriteDesign = design
            metricIDs = Array(design.displayedReadingIDs.prefix(32))
        } else {
            metricIDs = Array(metricIDs.filter { seen.insert($0).inserted }.prefix(8))
            if metricIDs.isEmpty { metricIDs = ["cpu.usage"] }
        }
        readoutLabels = readoutLabels?.filter { metricIDs.contains($0.key) }
        interval = [1.0, 2, 5, 10, 30, 60].contains(interval) ? interval : 2
        fontSize = fontSize.isFinite ? min(16, max(10, fontSize)) : 12
        decimals = min(2, max(0, decimals))
        if readoutLayout == nil { readoutLayout = .inline }
        barWarning = min(95, max(5, barWarning))
        barAlert = min(100, max(barWarning + 5, barAlert))
        if menuBarIconVisible == nil { menuBarIconVisible = true }
        if colorHex != "auto" && (colorHex.count != 6 || UInt32(colorHex, radix: 16) == nil) { colorHex = "auto" }
        if iconColorHex != "text" && iconColorHex != "auto" && (iconColorHex.count != 6 || UInt32(iconColorHex, radix: 16) == nil) { iconColorHex = "text" }
    }
    /// What a new Mac starts with: the gallery's starter templates, as settings the store converts on load.
    public static var initial: [Self] {
        SpriteTemplates.starterIDs.compactMap { id in
            SpriteTemplates.template(id).map { template in
                var item = template.recipe; item.id = UUID(); item.templateID = id; return item
            }
        }
    }

    /// The battery item: the drawn glyph beside the charge, with the charge-control
    /// menu on secondary click. Seeded once for configurations saved before it existed.
    public static var battery: Self {
        var item = Self(name: "Battery", symbol: "battery.100percent", metricIDs: ["battery.charge"])
        item.showIcon = true; item.showLabels = false; item.bold = false
        item.fontSize = 12; item.layout = .inline; item.interval = 10
        return item
    }
}

public enum MetricFormat {
    public static func string(_ reading: Reading?, metric: Metric, config: SpriteConfiguration = .init(), compact: Bool = false) -> String {
        guard let reading else { return compact ? "—" : "Not sampled" }
        if let text = reading.text { return text }
        guard let value = reading.number else { return compact ? "—" : (reading.issue ?? "Unavailable") }
        let suffix = config.showUnits
        // In the menu bar a number never runs past three characters: the decimal is dropped once the
        // whole part needs the room ("95.4 KB/s" then "100 KB/s"). Panels keep the asked-for precision.
        func fitted(_ v: Double, _ digits: Int) -> Int {
            guard compact else { return digits }
            var digits = digits
            while digits > 0 {
                let step = pow(10.0, Double(digits))
                if abs((v * step).rounded() / step) < pow(10.0, Double(MetricFormat.compactDigits - digits)) { break }
                digits -= 1
            }
            return digits
        }
        func n(_ v: Double, _ digits: Int? = nil) -> String {
            String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), fitted(v, digits ?? config.decimals), v)
        }
        switch metric.unit {
        case .percent: return n(value) + (suffix ? "%" : "")
        case .bytes, .bytesPerSecond:
            let bits = metric.unit == .bytesPerSecond && config.networkBits && metric.group == .network
            let base = bits ? 1000.0 : 1024.0
            let units = bits ? ["b/s", "Kb/s", "Mb/s", "Gb/s", "Tb/s"] : (metric.unit == .bytes ? ["B", "KiB", "MiB", "GiB", "TiB"] : ["B/s", "KiB/s", "MiB/s", "GiB/s", "TiB/s"])
            var size = abs(value) * (bits ? 8 : 1); var index = 0
            // Step up at 1000, not 1024, so a value never needs a fourth integer digit ("1010.0 KiB/s").
            while size >= 1000 && index < units.count - 1 { size /= base; index += 1 }
            let digits = index == 0 ? 0 : max(1, config.decimals)
            return (value < 0 ? "−" : "") + n(size, digits) + (suffix ? " " + units[index] : "")
        case .celsius: return n(config.fahrenheit ? value * 1.8 + 32 : value) + (suffix ? (config.fahrenheit ? "°F" : "°C") : "")
        case .watts: return n(value) + (suffix ? " W" : "")
        case .volts: return n(value, max(2, config.decimals)) + (suffix ? " V" : "")
        case .amps: return n(value, max(2, config.decimals)) + (suffix ? " A" : "")
        case .rpm: return n(value, 0) + (suffix ? " rpm" : "")
        case .count: return n(value, metric.id.hasPrefix("cpu.load") ? 2 : 0)
        // Cents matter below $10; above that the menu bar is better served by whole dollars.
        case .dollars: return (suffix ? "$" : "") + n(value, abs(value) < 10 ? max(2, config.decimals) : max(0, config.decimals))
        case .perSecond: return n(value) + (suffix ? "/s" : "")
        case .seconds:
            let minutes = Int(max(0, value) / 60)
            if minutes >= 1440 { return "\(minutes / 1440)d \((minutes % 1440) / 60)h" }
            if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
            return "\(minutes)m"
        case .text: return n(value)
        }
    }
}

extension MetricFormat {
    /// No menu-bar number is given room for more than this many characters.
    public static let compactDigits = 3

    /// The widest strings `string(_:metric:config:compact:)` produces in normal use, with every
    /// digit as "0" (digits are tabular). The menu bar reserves this width so an item does not
    /// resize as its value moves. Anything rarer than the reservation — 100% CPU, a 100 W draw, a
    /// GiB/s transfer — widens the item while it lasts, which is cheaper than holding the room all
    /// day. Empty means the width cannot be predicted.
    public static func widthTemplates(metric: Metric, config: SpriteConfiguration = .init()) -> [String] {
        let suffix = config.showUnits
        /// `integers` whole digits, with the decimals that still fit in three characters.
        func room(_ integers: Int, _ decimals: Int? = nil) -> String {
            let places = max(0, min(decimals ?? config.decimals, compactDigits - integers))
            return String(repeating: "0", count: integers) + (places > 0 ? "." + String(repeating: "0", count: places) : "")
        }
        switch metric.unit {
        // CPU and memory sit at 99% or below almost always, so two digits are reserved.
        case .percent: return [room(2) + (suffix ? "%" : "")]
        case .bytes, .bytesPerSecond:
            let bits = metric.unit == .bytesPerSecond && config.networkBits && metric.group == .network
            let units = bits ? ["b/s", "Kb/s", "Mb/s"] : (metric.unit == .bytes ? ["B", "KiB", "MiB", "GiB"] : ["B/s", "KiB/s", "MiB/s"])
            return units.enumerated().flatMap { index, unit -> [String] in
                let value = index == 0 ? [room(3, 0)] : [room(2, max(1, config.decimals)), room(3, 0)]
                return value.map { $0 + (suffix ? " " + unit : "") }
            }
        case .celsius:
            let unit = suffix ? (config.fahrenheit ? "°F" : "°C") : ""
            return [room(2) + unit, room(3, 0) + unit]
        // Nebula draws well under 100 W; a spike past it widens the item for as long as it lasts.
        case .watts: return [room(2) + (suffix ? " W" : "")]
        case .volts: return [room(2, max(2, config.decimals)) + (suffix ? " V" : "")]
        case .amps: return ["−" + room(1, max(2, config.decimals)) + (suffix ? " A" : "")]
        case .rpm: return [room(4, 0) + (suffix ? " rpm" : "")]
        case .count: return metric.id.hasPrefix("cpu.load") ? [room(1, 2)] : []
        case .dollars: return [(suffix ? "$" : "") + room(1, 2), (suffix ? "$" : "") + room(3, 0)]
        case .perSecond: return [room(3, 0) + (suffix ? "/s" : "")]
        case .seconds: return ["00h 00m", "0d 00h"]
        case .text: return []
        }
    }
}

/// Counter resets never become enormous positive rates or fabricated zero activity.
public struct CounterDelta: Sendable {
    private var previous: (value: UInt64, time: Double)?
    public init() {}
    public mutating func sample(_ value: UInt64, at time: Double) -> Double? {
        defer { previous = (value, time) }
        guard let old = previous, time > old.time, value >= old.value else { return nil }
        return Double(value - old.value) / (time - old.time)
    }
    public mutating func reset() { previous = nil }
}
public enum CPUDelta {
    /// Mach CPU ticks are UInt32 and may wrap during a long-running system session.
    public static func percentages(previous: [UInt32], current: [UInt32]) -> (user: Double, system: Double, idle: Double)? {
        guard previous.count == 4, current.count == 4 else { return nil }
        let delta = zip(current, previous).map { Double($0 &- $1) }
        let total = delta.reduce(0, +)
        guard total > 0 else { return nil }
        return ((delta[0] + delta[3]) / total * 100, delta[1] / total * 100, delta[2] / total * 100)
    }
}
