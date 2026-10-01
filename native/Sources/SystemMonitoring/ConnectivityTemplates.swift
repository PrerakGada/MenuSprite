import Foundation

/// Wi-Fi and Bluetooth sprites for the gallery. They are made to stand in for macOS's own Wi-Fi and
/// Bluetooth items, which macOS 27 draws with fixed gaps no setting can close (`docs/menu-bar-spacing.md`):
/// a MenuSprite item sits as tight as its neighbours. Each is an ordinary design, so every icon swap and
/// colour below is a rule the studio shows and lets Prerak change. Spec: `docs/wifi-bluetooth.md`.
extension SpriteTemplates {
    static let connectivity: [SpriteTemplate] = [
        hand("wifi.icon", .wifi, "Wi-Fi", "Bars that fill with the signal, a slash when Wi-Fi is off and a warning when it has not joined a network. Orange when the signal is weak.",
             symbol: "wifi", interval: 5, design: wifiIcon(name: false)),
        hand("wifi.name", .wifi, "Wi-Fi and network", "The signal bars beside the network's name. The name needs Location access, which the Wi-Fi board asks for.",
             symbol: "wifi", interval: 5, design: wifiIcon(name: true)),
        hand("wifi.details", .wifi, "Wi-Fi signal and link", "Signal in dBm above the link rate, beside the bars: how good the connection is, not how busy.",
             symbol: "wifi", interval: 5, design: wifiDetails),
        hand("network.wifi", .network, "Network with Wi-Fi", "Upload in orange above download in green, with the Wi-Fi bars in front. Click for the Wi-Fi board.",
             symbol: "wifi", interval: 2, design: networkWithWiFi),
        hand("bluetooth.status", .bluetooth, "Bluetooth", "The Bluetooth mark, dimmed when off. A green dot while headphones are connected, a blue one for anything else.",
             symbol: SpriteSymbols.bluetooth, interval: 5, design: bluetoothStatus),
        hand("bluetooth.headphones", .bluetooth, "Headphones", "Turns into your AirPods, AirPods Max, Beats or headphones when they connect, with the emptier bud's battery. Red below 20%.",
             symbol: "airpodspro", interval: 10, design: headphones),
        hand("bluetooth.buds", .bluetooth, "Earbuds left and right", "Each earbud's battery, one above the other, beside the earbuds' icon.",
             symbol: "airpodspro", interval: 10, design: earbuds)
    ]

    private static func hand(_ id: String, _ category: SpriteTemplate.Category, _ name: String, _ summary: String,
                             symbol: String, interval: Double, design: SpriteDesign) -> SpriteTemplate {
        var config = SpriteConfiguration(name: name, symbol: symbol, metricIDs: design.displayedReadingIDs)
        config.interval = interval
        config.showIcon = true
        return SpriteTemplate(id: id, category: category, name: name, summary: summary, recipe: config, design: design)
    }

    // MARK: Pieces

    private static func reading(_ id: String, _ name: String, _ metric: String, unit: Bool = true) -> SpriteVariable {
        var format = ValueFormat(); format.showUnit = unit
        return SpriteVariable(id: id, name: name, source: .reading(metric: metric), format: format)
    }
    private static func icon(_ symbol: String, size: Double, name: String, level: String? = nil, color: String = "inherit") -> DesignNode {
        var node = DesignNode(kind: .icon, name: name, symbol: symbol, variable: level)
        node.style.size = size; node.style.color = color
        return node
    }
    private static func when(_ variable: String, _ comparison: RuleComparison, _ operand: String = "", _ actions: [RuleAction]) -> RuleBranch {
        RuleBranch(conditions: [RuleCondition(variable: variable, comparison: comparison, operand: operand)], actions: actions)
    }

    /// The bars, bound to the signal, with the rules every Wi-Fi sprite shares.
    private static func wifiBars(size: Double = 15) -> (node: DesignNode, variables: [SpriteVariable], rules: [SpriteRule]) {
        let bars = icon("wifi", size: size, name: "Wi-Fi", level: "signal")
        let rules = [
            SpriteRule(name: "Off or not joined", branches: [
                when("state", .equals, "Off", [RuleAction(kind: .symbol, target: bars.id, value: "wifi.slash"),
                                               RuleAction(kind: .opacity, target: bars.id, value: "0.45")]),
                when("state", .equals, "Not connected", [RuleAction(kind: .symbol, target: bars.id, value: "wifi.exclamationmark"),
                                                         RuleAction(kind: .opacity, target: bars.id, value: "0.6")])
            ]),
            SpriteRule(name: "Weak signal", branches: [
                when("signal", .below, "25", [RuleAction(kind: .color, target: bars.id, value: "FF9F0A")])
            ])
        ]
        return (bars, [reading("signal", "Signal", "wifi.signal"), reading("state", "Wi-Fi", "wifi.state")], rules)
    }

    private static func wifiIcon(name: Bool) -> SpriteDesign {
        let bars = wifiBars()
        guard name else { return SpriteDesign(root: .row([bars.node], gap: 0), variables: bars.variables, rules: bars.rules) }
        var label = DesignNode.text([.value("network")], size: 12, name: "Network")
        label.style.tabular = false
        return SpriteDesign(root: .row([bars.node, label], gap: 4),
                            variables: bars.variables + [reading("network", "Network", "wifi.network")],
                            rules: bars.rules + [SpriteRule(name: "No name", branches: [
                                when("network", .isMissing, "", [RuleAction(kind: .hide, target: label.id)])
                            ])])
    }

    /// Two small lines (label then value) beside a leading icon, as the two-row readouts draw them.
    private static func twoLines(_ lines: [(label: String, variable: String)], colors: [String] = []) -> DesignNode {
        var rows: [DesignNode] = []
        for (index, line) in lines.enumerated() {
            var label = DesignNode.text([.literal(line.label)], size: 8, name: "Label")
            label.style.weight = .semibold; label.style.opacity = 0.9; label.style.align = .leading; label.style.tabular = false
            var value = DesignNode.text([.value(line.variable)], size: 12, name: "Value")
            value.style.align = .trailing
            var row = DesignNode.row([label, value], gap: 4, name: "Reading")
            row.style.justify = .spaceBetween
            if index < colors.count { row.style.color = colors[index] }
            rows.append(row)
        }
        var column = DesignNode.column(rows, gap: 2, name: "Pair")
        column.style.justify = .even
        return column
    }

    private static var wifiDetails: SpriteDesign {
        let bars = wifiBars()
        return SpriteDesign(root: .row([bars.node, twoLines([("SIG", "rssi"), ("LINK", "rate")])], gap: 4),
                            variables: bars.variables + [reading("rssi", "Signal dBm", "wifi.rssi"), reading("rate", "Link rate", "wifi.rate")],
                            rules: bars.rules)
    }

    /// The Network template exactly as the gallery draws it, with the bars in front.
    private static var networkWithWiFi: SpriteDesign {
        // The "network.twoRows" recipe, written out: reading `all` here would recurse into its own initialiser.
        var recipe = SpriteConfiguration(name: "Network", symbol: "network", metricIDs: ["network.upload", "network.download"])
        recipe.layout = .twoRows; recipe.colorRule = .networkDirection; recipe.showIcon = false; recipe.fontSize = 12
        var design = SpriteDesign.migrated(from: recipe) { id in MonitoringCatalog.base.first { $0.id == id } }
        let bars = wifiBars(size: 14)
        let existing = design.root.kind == .row ? design.root.children : [design.root]
        design.root = .row([bars.node] + existing, gap: 4)
        design.variables += bars.variables
        design.rules += bars.rules
        return design
    }

    private static var bluetoothStatus: SpriteDesign {
        let rune = icon(SpriteSymbols.bluetooth, size: 15, name: "Bluetooth")
        var dot = icon("circle.fill", size: 5, name: "Dot", color: "30D158")
        dot.style.hidden = true
        // A blank line under the dot lifts it to the rune's top corner: a column centres its pieces, and the
        // gap below the dot is what holds it up there (a dot alone at the column's top floats above the rune).
        var lift = DesignNode.text([.literal(" ")], size: 6, name: "Lift")
        lift.style.tabular = false
        let corner = DesignNode.column([dot, lift], gap: 7, name: "Corner")
        return SpriteDesign(
            root: .row([rune, corner], gap: 0.5),
            variables: [reading("state", "Bluetooth", "bluetooth.state"), reading("audio", "Headphones", "bluetooth.audio"),
                        reading("connected", "Connected", "bluetooth.connected")],
            rules: [
                SpriteRule(name: "Connected dot", branches: [
                    when("audio", .isPresent, "", [RuleAction(kind: .show, target: dot.id), RuleAction(kind: .color, target: dot.id, value: "30D158")]),
                    when("connected", .above, "0", [RuleAction(kind: .show, target: dot.id), RuleAction(kind: .color, target: dot.id, value: "0A84FF")])
                ]),
                SpriteRule(name: "Off", branches: [
                    when("state", .equals, "Off", [RuleAction(kind: .opacity, target: rune.id, value: "0.4"), RuleAction(kind: .hide, target: dot.id)])
                ])
            ])
    }

    /// The device's own icon, by what `bluetooth.audioKind` says it is; the Bluetooth mark when none is connected.
    private static func deviceIconRule(_ target: String) -> SpriteRule {
        let kinds: [(String, String)] = [("AirPods Pro", "airpodspro"), ("AirPods Max", "airpodsmax"), ("AirPods", "airpods"),
                                         ("Beats", "beats.headphones"), ("Headphones", "headphones"), ("Speaker", "hifispeaker")]
        return SpriteRule(name: "Device icon",
                          branches: kinds.map { kind, symbol in when("kind", .equals, kind, [RuleAction(kind: .symbol, target: target, value: symbol)]) },
                          otherwise: [RuleAction(kind: .symbol, target: target, value: SpriteSymbols.bluetooth)])
    }

    private static var headphones: SpriteDesign {
        let device = icon(SpriteSymbols.bluetooth, size: 15, name: "Device")
        var battery = DesignNode.text([.value("battery")], size: 12, name: "Battery")
        battery.style.weight = .medium
        return SpriteDesign(
            root: .row([device, battery], gap: 3),
            variables: [reading("battery", "Battery", "bluetooth.audioBattery"), reading("kind", "Kind", "bluetooth.audioKind"),
                        reading("state", "Bluetooth", "bluetooth.state")],
            rules: [
                deviceIconRule(device.id),
                SpriteRule(name: "Battery", branches: [
                    when("battery", .isMissing, "", [RuleAction(kind: .hide, target: battery.id)]),
                    when("battery", .below, "20", [RuleAction(kind: .color, target: battery.id, value: "FF453A")])
                ]),
                SpriteRule(name: "Off", branches: [
                    when("state", .equals, "Off", [RuleAction(kind: .opacity, target: device.id, value: "0.4")])
                ])
            ])
    }

    private static var earbuds: SpriteDesign {
        let device = icon(SpriteSymbols.bluetooth, size: 15, name: "Device")
        return SpriteDesign(
            root: .row([device, twoLines([("L", "left"), ("R", "right")])], gap: 4),
            variables: [reading("left", "Left", "bluetooth.batteryLeft"), reading("right", "Right", "bluetooth.batteryRight"),
                        reading("kind", "Kind", "bluetooth.audioKind")],
            rules: [deviceIconRule(device.id)])
    }
}
