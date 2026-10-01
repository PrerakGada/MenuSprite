import Foundation

/// A ready-made sprite in the gallery: a few settings run through the same conversion that turns an
/// old settings-form sprite into a design, so every template draws the way a converted sprite does.
/// A sprite made from one keeps the template's id, which is what "Reset to template" goes back to.
/// Spec: `docs/sprite-gallery.md`.
public struct SpriteTemplate: Identifiable, Sendable {
    public enum Category: String, CaseIterable, Sendable {
        case cpu = "CPU", memory = "Memory", power = "Power", battery = "Battery", network = "Network"
        case disk = "Disk", gpu = "GPU", heat = "Heat & fans", ai = "AI usage", system = "System"
        case wifi = "Wi-Fi", bluetooth = "Bluetooth"
        public var icon: String {
            switch self {
            case .cpu: "cpu"; case .memory: "memorychip"; case .power: "bolt"; case .battery: "battery.100percent"
            case .network: "network"; case .disk: "internaldrive"; case .gpu: "display"; case .heat: "fan"
            case .ai: "sparkles"; case .system: "desktopcomputer"
            case .wifi: "wifi"; case .bluetooth: "headphones"
            }
        }
    }

    public let id: String
    public let category: Category
    public let name: String
    public let summary: String
    /// The settings the design is converted from. Its id is never used: `make` gives each sprite its own.
    let recipe: SpriteConfiguration
    /// A design made by hand (icons bound to values, rules that swap them), used as it is instead of
    /// converting the recipe. The recipe still carries the interval and the sprite's name and icon.
    var design: SpriteDesign? = nil

    /// Every reading the template draws or compares.
    public var readingIDs: [String] {
        if let design { return design.displayedReadingIDs + design.ruleOnlyReadingIDs }
        var ids = recipe.metricIDs
        if recipe.colorRule == .memoryPressure, !ids.contains("memory.pressure") { ids.append("memory.pressure") }
        return ids
    }

    /// A new sprite from this template: its own id, the template's design, running and in the menu bar.
    public func make(metric: (String) -> Metric?) -> SpriteConfiguration {
        var config = recipe
        config.id = UUID()
        config.design = design ?? SpriteDesign.migrated(from: recipe, metric: metric)
        config.templateID = id
        config.normalize()
        return config
    }

    /// `config` back as this template drew it. What belongs to the sprite rather than its look stays:
    /// its id (so its menu-bar place and left or right side hold), whether it runs, and whether it shows.
    public func reset(_ config: SpriteConfiguration, metric: (String) -> Metric?) -> SpriteConfiguration {
        var fresh = make(metric: metric)
        fresh.id = config.id
        fresh.enabled = config.enabled
        fresh.showInMenuBar = config.showInMenuBar
        return fresh
    }
}

/// A group of templates added together, a whole menu bar at once.
public struct SpriteTemplateSet: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public let templateIDs: [String]
}

public enum SpriteTemplates {
    public static func template(_ id: String?) -> SpriteTemplate? { id.flatMap { id in all.first { $0.id == id } } }
    public static func templates(in category: SpriteTemplate.Category) -> [SpriteTemplate] { all.filter { $0.category == category } }

    /// What a new Mac starts with. Order is the menu bar's, left to right.
    public static let starterIDs = ["cpu.stacked", "memory.pressure", "power.system", "network.twoRows", "heat.fanTemp", "battery.glyph"]

    public static let sets: [SpriteTemplateSet] = [
        SpriteTemplateSet(id: "essentials", name: "Essentials",
                          summary: "CPU, RAM, power, network, fan and battery: what a new Mac starts with.",
                          templateIDs: starterIDs),
        SpriteTemplateSet(id: "minimal", name: "Minimal",
                          summary: "Three quiet readings: a CPU bar, memory and the battery.",
                          templateIDs: ["cpu.bar", "memory.pressure", "battery.glyph"]),
        SpriteTemplateSet(id: "full", name: "Full setup",
                          summary: "Everything a heavy user watches: CPU bar, RAM, power, network in bits, fan and heat, Claude and Codex limits, battery.",
                          templateIDs: ["cpu.barOnly", "memory.pressure", "power.precise", "network.bits", "heat.quiet",
                                        "ai.weeklyPair", "ai.claudeSession", "battery.glyph"])
    ]

    /// Builds a recipe. Values follow the sprite form's own defaults unless named.
    private static func t(_ id: String, _ category: SpriteTemplate.Category, _ name: String, _ summary: String,
                          _ metrics: [String], layout: SpriteReadoutLayout = .stacked, labels: Bool = true,
                          units: Bool = true, symbol: String? = nil, showIcon: Bool = false, iconColor: String = "text",
                          rule: SpriteColorRule = .fixed, size: Double? = nil, bold: Bool = false, decimals: Int = 0,
                          bits: Bool = false, interval: Double = 2, labelText: [String: String] = [:],
                          batteryPercent: BatteryPercentPlacement? = nil) -> SpriteTemplate {
        var config = SpriteConfiguration(name: name, symbol: symbol ?? category.icon, metricIDs: metrics)
        config.layout = layout
        config.showLabels = labels; config.showUnits = units
        config.showIcon = showIcon; config.iconColorHex = iconColor
        config.colorRule = rule
        config.fontSize = size ?? (layout == .stacked && metrics.count == 1 ? 14 : 12)
        config.bold = bold; config.decimals = decimals; config.networkBits = bits; config.interval = interval
        for (metric, label) in labelText { config.setLabel(label, for: metric) }
        if let batteryPercent { config.batteryPercentPlacement = batteryPercent }
        return SpriteTemplate(id: id, category: category, name: name, summary: summary, recipe: config)
    }

    public static let all: [SpriteTemplate] = [
        // CPU
        t("cpu.stacked", .cpu, "CPU", "Usage in large type under a small label.", ["cpu.usage"]),
        t("cpu.icon", .cpu, "CPU with icon", "The chip icon beside the percentage.", ["cpu.usage"],
          layout: .inline, labels: false, showIcon: true, size: 13),
        t("cpu.bar", .cpu, "CPU bar", "A level bar that turns amber, then red, as the CPU fills.", ["cpu.usage"],
          layout: .bar, showIcon: true),
        t("cpu.barOnly", .cpu, "CPU bar, no icon", "Just the level bar: the smallest CPU reading.", ["cpu.usage"],
          layout: .bar, symbol: "chart.xyaxis.line"),
        t("cpu.userSystem", .cpu, "User and system", "Apps' share and macOS's share of the CPU, one above the other.",
          ["cpu.user", "cpu.system"], layout: .twoRows),
        t("cpu.load", .cpu, "Load averages", "Runnable work over 1, 5 and 15 minutes, as Terminal's uptime shows it.",
          ["cpu.load1", "cpu.load5", "cpu.load15"], layout: .inline, labels: false, symbol: "gauge.with.dots.needle.50percent",
          showIcon: true, decimals: 1, interval: 5),
        t("cpu.cpuGpu", .cpu, "CPU and GPU", "Both processors' usage, one above the other.", ["cpu.usage", "gpu.usage"], layout: .twoRows),

        // Memory
        t("memory.pressure", .memory, "RAM", "Memory used, with its label green, yellow or red by memory pressure.",
          ["memory.usage"], rule: .memoryPressure),
        t("memory.icon", .memory, "RAM with icon", "The memory icon beside the percentage used.", ["memory.usage"],
          layout: .inline, labels: false, showIcon: true, size: 13),
        t("memory.bar", .memory, "RAM bar", "A level bar of memory used.", ["memory.usage"], layout: .bar, showIcon: true),
        t("memory.available", .memory, "Available RAM", "How much memory apps can still take before macOS compresses or swaps.",
          ["memory.available"], decimals: 1, labelText: ["memory.available": "Free"]),
        t("memory.pressureLevel", .memory, "Memory pressure", "macOS's own verdict: Normal, Warning or Critical, coloured to match.",
          ["memory.pressure"], layout: .inline, rule: .memoryPressure, size: 12, interval: 5),
        t("memory.swap", .memory, "Swap", "Disk space in use as overflow memory. Rising swap means RAM is short.",
          ["memory.swapUsed"], decimals: 1, interval: 5),
        t("memory.usedSwap", .memory, "Used and swap", "Memory used and swap in use, one above the other.",
          ["memory.used", "memory.swapUsed"], layout: .twoRows, decimals: 1, labelText: ["memory.used": "RAM"]),
        t("memory.appCompressed", .memory, "Apps and compressed", "Memory apps hold, and how much macOS has squeezed.",
          ["memory.app", "memory.compressed"], layout: .twoRows, decimals: 1),

        // Power
        t("power.system", .power, "Power", "What the whole Mac draws, its label yellow from 35 W and red above 45 W.",
          ["sensor.PSTR"], rule: .powerDraw),
        t("power.precise", .power, "Power, one decimal", "The same reading to a tenth of a watt.", ["sensor.PSTR"],
          rule: .powerDraw, decimals: 1),
        t("power.icon", .power, "Power with bolt", "A bolt beside the watts.", ["sensor.PSTR"],
          layout: .inline, labels: false, symbol: "bolt.fill", showIcon: true, size: 13),
        t("power.flow", .power, "Adapter and battery", "Watts in from the charger, and into or out of the battery.",
          ["sensor.PDTR", "battery.power"], layout: .twoRows, decimals: 1, labelText: ["sensor.PDTR": "In", "battery.power": "Batt"]),
        t("power.heat", .power, "Power and temperature", "Watts drawn and the hottest CPU sensor, one above the other.",
          ["sensor.PSTR", "sensor.cpuTemperature"], layout: .twoRows, rule: .powerDraw),

        // Battery
        t("battery.glyph", .battery, "Battery", "The battery drawn with its charge inside.", ["battery.charge"],
          layout: .inline, labels: false, symbol: "battery.100percent", showIcon: true, interval: 10),
        t("battery.percentLeft", .battery, "Percent and battery", "The charge beside the battery, as macOS draws it.",
          ["battery.charge"], layout: .inline, labels: false, symbol: "battery.100percent", showIcon: true,
          interval: 10, batteryPercent: .left),
        t("battery.timeLeft", .battery, "Battery and time left", "The battery with the time macOS expects it to last.",
          ["battery.charge", "battery.remaining"], layout: .inline, labels: false, symbol: "battery.100percent",
          showIcon: true, interval: 30),
        t("battery.percent", .battery, "Battery percent", "The charge in large type under a small label.", ["battery.charge"],
          interval: 10, labelText: ["battery.charge": "BAT"]),
        t("battery.health", .battery, "Battery health", "Capacity left against new, and cycles used.",
          ["battery.capacityRatio", "battery.cycles"], layout: .twoRows, interval: 60, labelText: ["battery.capacityRatio": "Health"]),
        t("battery.temperature", .battery, "Battery temperature", "The pack's own temperature.", ["battery.temperature"],
          decimals: 1, interval: 10),

        // Network
        t("network.twoRows", .network, "Network", "Upload in orange above download in green.",
          ["network.upload", "network.download"], layout: .twoRows, rule: .networkDirection),
        t("network.bits", .network, "Network in bits", "The same, in bits per second, as speed tests and ISPs quote.",
          ["network.upload", "network.download"], layout: .twoRows, rule: .networkDirection, bits: true),
        t("network.download", .network, "Download only", "Just the download rate, in green.", ["network.download"],
          layout: .inline, rule: .networkDirection, size: 12),
        t("network.inline", .network, "Up and down in a line", "Both rates side by side with their arrows.",
          ["network.upload", "network.download"], layout: .inline, rule: .networkDirection, size: 12),
        t("network.packets", .network, "Packets", "Packets per second each way: busy-ness rather than size.",
          ["network.packetsOut", "network.packetsIn"], layout: .twoRows),

        // Disk
        t("disk.available", .disk, "Disk free", "Space you can still use on the data volume.", ["disk.available"],
          interval: 60, labelText: ["disk.available": "Disk"]),
        t("disk.bar", .disk, "Disk bar", "A level bar of the data volume filling up.", ["disk.usage"], layout: .bar,
          showIcon: true, interval: 60),
        t("disk.icon", .disk, "Disk with icon", "The drive icon beside the percentage used.", ["disk.usage"],
          layout: .inline, labels: false, showIcon: true, size: 13, interval: 60),
        t("disk.io", .disk, "Read and write", "Bytes read and written per second, one above the other.",
          ["disk.read", "disk.write"], layout: .twoRows),

        // GPU
        t("gpu.stacked", .gpu, "GPU", "GPU usage in large type under a small label.", ["gpu.usage"]),
        t("gpu.bar", .gpu, "GPU bar", "A level bar of GPU usage.", ["gpu.usage"], layout: .bar, showIcon: true),
        t("gpu.usageTemp", .gpu, "GPU and temperature", "GPU usage and its hottest sensor.", ["gpu.usage", "sensor.gpuTemperature"],
          layout: .twoRows),
        t("gpu.memory", .gpu, "GPU memory", "System memory the GPU is using right now.", ["gpu.memoryUsed"], decimals: 1),

        // Heat & fans
        t("heat.fanTemp", .heat, "Fan & CPU temperature", "A blue fan beside the fan speed and the CPU's temperature.",
          ["sensor.fanSpeed", "sensor.cpuTemperature"], layout: .twoRows, symbol: "fan.fill", showIcon: true, iconColor: "79BFFA"),
        t("heat.quiet", .heat, "Fan & temperature, numbers only", "The blue fan with just the two numbers: temperature over rpm.",
          ["sensor.cpuTemperature", "sensor.fanSpeed"], layout: .twoRows, labels: false, units: false, symbol: "fan.fill",
          showIcon: true, iconColor: "79BFFA", decimals: 1),
        t("heat.cpuTemp", .heat, "CPU temperature", "The hottest mapped CPU sensor.", ["sensor.cpuTemperature"]),
        t("heat.cpuGpuTemp", .heat, "CPU and GPU temperature", "Both chips' hottest sensors, one above the other.",
          ["sensor.cpuTemperature", "sensor.gpuTemperature"], layout: .twoRows, labelText: ["sensor.cpuTemperature": "CPU", "sensor.gpuTemperature": "GPU"]),
        t("heat.fan", .heat, "Fan speed", "A fan beside its rpm.", ["sensor.fanSpeed"], layout: .inline, labels: false,
          symbol: "fan.fill", showIcon: true, size: 12),
        t("heat.thermal", .heat, "Thermal state", "Whether macOS is holding the Mac back for heat.", ["system.thermal"],
          layout: .inline, labels: false, symbol: "thermometer.medium", showIcon: true, size: 12, interval: 10),

        // AI usage
        t("ai.claudeSession", .ai, "Claude session", "Claude's 5-hour limit; the % is green, amber or red against an even pace.",
          ["ai.claude.session"], symbol: "terminal", rule: .usagePacePercent, bold: true, interval: 30,
          labelText: ["ai.claude.session": "Claude"]),
        t("ai.weeklyPair", .ai, "Weekly AI usage", "Codex and Claude weekly limits, numbers only, each % coloured by pace.",
          ["ai.codex.weekly", "ai.claude.weekly"], layout: .twoRows, labels: false, rule: .usagePacePercent, bold: true,
          interval: 30, labelText: ["ai.claude.weekly": "Claude", "ai.codex.weekly": "GPT"]),
        t("ai.claudePair", .ai, "Claude limits", "Claude's 5-hour and weekly limits, coloured by pace.",
          ["ai.claude.session", "ai.claude.weekly"], layout: .twoRows, rule: .usagePace, interval: 30,
          labelText: ["ai.claude.session": "5h", "ai.claude.weekly": "7d"]),
        t("ai.codexPair", .ai, "Codex limits", "Codex's 5-hour and weekly limits, coloured by pace.",
          ["ai.codex.session", "ai.codex.weekly"], layout: .twoRows, rule: .usagePace, interval: 30,
          labelText: ["ai.codex.session": "5h", "ai.codex.weekly": "7d"]),
        t("ai.claudeBar", .ai, "Claude session bar", "Claude's 5-hour limit as a level bar.", ["ai.claude.session"],
          layout: .bar, symbol: "sparkles", showIcon: true, interval: 30),
        t("ai.claudeReset", .ai, "Claude session and reset", "How much of the 5-hour limit is used and when it resets.",
          ["ai.claude.session", "ai.claude.sessionReset"], layout: .twoRows, rule: .usagePace, interval: 30,
          labelText: ["ai.claude.session": "Used", "ai.claude.sessionReset": "Resets"]),
        t("ai.spendToday", .ai, "Estimated spend today", "What today's Claude and Codex use would cost at API rates. Needs Estimate spend turned on.",
          ["ai.claude.spendToday", "ai.codex.spendToday"], layout: .twoRows, decimals: 2, interval: 60,
          labelText: ["ai.claude.spendToday": "Claude", "ai.codex.spendToday": "Codex"]),

        // System
        t("system.cpuRam", .system, "CPU and RAM", "The two readings people check most, one above the other.",
          ["cpu.usage", "memory.usage"], layout: .twoRows, rule: .memoryPressure),
        t("system.uptime", .system, "Uptime", "How long since the Mac last started.", ["system.uptime"],
          layout: .inline, labels: false, symbol: "clock", showIcon: true, size: 12, interval: 60),
        t("system.lowPower", .system, "Low Power Mode", "Whether Low Power Mode is on.", ["system.lowPower"],
          layout: .inline, labels: false, symbol: "leaf", showIcon: true, size: 12, interval: 10)
    ] + connectivity
}
