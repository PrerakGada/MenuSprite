import AppKit
import Foundation
import Testing
@testable import SystemMonitoring

private func metric(_ id: String) -> Metric? { MonitoringCatalog.base.first { $0.id == id } }

private func values(_ numbers: [String: Double], texts: [String: String] = [:], pace: [String: String] = [:]) -> DesignValues {
    DesignValues(
        formatted: { variable in
            guard let id = variable.readingID else { return "" }
            if let text = texts[id] { return text }
            return numbers[id].map { String(Int($0)) } ?? "—"
        },
        number: { $0.readingID.flatMap { numbers[$0] } },
        text: { $0.readingID.flatMap { texts[$0] } },
        aspect: { variable, _ in variable.readingID.flatMap { pace[$0] } })
}

@Test func legacySpritesDecodeWithoutADesignAndRoundTripWithOne() throws {
    var config = SpriteConfiguration(name: "RAM", symbol: "memorychip", metricIDs: ["memory.usage"])
    config.colorRule = .memoryPressure; config.layout = .stacked
    let legacy = try JSONDecoder().decode(SpriteConfiguration.self, from: JSONEncoder().encode(config))
    #expect(legacy.design == nil)
    config.design = SpriteDesign.migrated(from: config, metric: metric)
    config.normalize()
    let restored = try JSONDecoder().decode(SpriteConfiguration.self, from: JSONEncoder().encode(config))
    #expect(restored == config)
    // A rule-only reading is sampled but does not change which panel the sprite opens.
    #expect(restored.metricIDs == ["memory.usage"])
    #expect(restored.design?.ruleOnlyReadingIDs == ["memory.pressure"])
}

@Test func migrationKeepsReadingsAndTurnsColourRulesIntoRules() {
    var network = SpriteConfiguration(name: "Network", symbol: "network", metricIDs: ["network.upload", "network.download"])
    network.layout = .twoRows; network.colorRule = .networkDirection
    let design = SpriteDesign.migrated(from: network, metric: metric)
    #expect(design.displayedReadingIDs == ["network.upload", "network.download"])
    #expect(design.root.flattened.contains { $0.style.color == "FF9F0A" })
    #expect(design.root.flattened.contains { $0.style.color == "30D158" })

    var power = SpriteConfiguration(name: "Power", symbol: "bolt", metricIDs: ["sensor.PSTR"])
    power.layout = .stacked; power.colorRule = .powerDraw
    let powerDesign = SpriteDesign.migrated(from: power, metric: metric)
    let label = powerDesign.root.flattened.first { $0.name == "Label" }!
    #expect(SpriteRules.evaluate(powerDesign, values: values(["sensor.PSTR": 30]))[label.id] == nil)
    #expect(SpriteRules.evaluate(powerDesign, values: values(["sensor.PSTR": 40]))[label.id]?.color == "FFD60A")
    #expect(SpriteRules.evaluate(powerDesign, values: values(["sensor.PSTR": 50]))[label.id]?.color == "FF453A")
}

@Test func pacePercentRulesColourOnlyThePercentAndHideItWhileUnknown() {
    var config = SpriteConfiguration(name: "Claude", symbol: "terminal", metricIDs: ["ai.claude.session"])
    config.layout = .stacked; config.colorRule = .usagePacePercent
    let ai = Metric("ai.claude.session", "Claude session", "Claude", .ai, .percent, "", source: "")
    let design = SpriteDesign.migrated(from: config, metric: { $0 == ai.id ? ai : metric($0) })
    let percent = design.root.flattened.first { $0.name == "%" }!
    #expect(design.variables.first?.format.showUnit == false)
    let ahead = SpriteRules.evaluate(design, values: values(["ai.claude.session": 40], pace: ["ai.claude.session": "ahead"]))
    #expect(ahead[percent.id]?.color == SpriteDesign.paceColors.ahead && ahead[percent.id]?.hidden == nil)
    let unknown = SpriteRules.evaluate(design, values: values([:]))
    #expect(unknown[percent.id]?.hidden == true)
}

@Test func batteryWithChargeInsideIsAGlyphAlone() {
    let design = SpriteDesign.migrated(from: .battery, metric: metric)
    #expect(design.root.children.count == 1)
    #expect(design.root.children[0].kind == .battery && design.root.children[0].style.chargeInside)
    #expect(design.displayedReadingIDs == ["battery.charge"])
}

@Test func rulesTakeTheFirstHoldingBranchAndLaterRulesWin() {
    var design = SpriteDesign(root: .row([DesignNode.text([.value("cpu")])]),
                              variables: [SpriteVariable(id: "cpu", name: "CPU", source: .reading(metric: "cpu.usage"))])
    let target = design.root.children[0].id
    design.rules = [
        SpriteRule(branches: [RuleBranch(conditions: [RuleCondition(variable: "cpu", comparison: .above, operand: "80")],
                                         actions: [RuleAction(kind: .color, target: target, value: "FF0000")]),
                              RuleBranch(conditions: [RuleCondition(variable: "cpu", comparison: .above, operand: "50")],
                                         actions: [RuleAction(kind: .color, target: target, value: "FFFF00")])],
                   otherwise: [RuleAction(kind: .color, target: target, value: "00FF00")]),
        SpriteRule(branches: [RuleBranch(match: .any, conditions: [RuleCondition(variable: "cpu", comparison: .isMissing),
                                                                   RuleCondition(variable: "cpu", comparison: .atLeast, operand: "99")],
                                         actions: [RuleAction(kind: .hide, target: target)])])
    ]
    #expect(SpriteRules.evaluate(design, values: values(["cpu.usage": 90]))[target]?.color == "FF0000")
    #expect(SpriteRules.evaluate(design, values: values(["cpu.usage": 60]))[target]?.color == "FFFF00")
    #expect(SpriteRules.evaluate(design, values: values(["cpu.usage": 10]))[target]?.color == "00FF00")
    #expect(SpriteRules.evaluate(design, values: values(["cpu.usage": 99]))[target]?.hidden == true)
    #expect(SpriteRules.evaluate(design, values: values([:]))[target]?.hidden == true)
    design.rules[1].enabled = false
    #expect(SpriteRules.evaluate(design, values: values([:]))[target]?.hidden == nil)
}

@Test func textTemplatesParseValuesAndKeepOtherBraces() {
    #expect(TextTemplate.parse("{cpu}%") == [.value("cpu"), .literal("%")])
    #expect(TextTemplate.parse("a {not a value} b") == [.literal("a {not a value} b")])
    #expect(TextTemplate.string([.literal("↑ "), .value("up")]) == "↑ {up}")
}

@Test func droppingBesideOrBelowWrapsInTheRightContainer() {
    let a = DesignNode.text([.literal("A")]), b = DesignNode.text([.literal("B")]), c = DesignNode.text([.literal("C")])
    var design = SpriteDesign(root: .row([a, b]))
    // Below A inside a row: A becomes a column of A over C.
    let step1 = design.insert(c, at: .below, of: a.id); #expect(step1)
    #expect(design.root.children.count == 2 && design.root.children[0].kind == .column)
    #expect(design.root.children[0].children.map(\.id) == [a.id, c.id])
    // Moving C beside B joins the row; the column left with only A folds away.
    let step2 = design.move(c.id, to: .right, of: b.id); #expect(step2)
    #expect(design.root.children.map(\.id) == [a.id, b.id, c.id])
    // A node cannot be moved into itself.
    let column = DesignNode.column([DesignNode.text([.literal("X")])])
    design.root.children.append(column)
    let step3 = design.move(column.id, to: .below, of: column.children[0].id); #expect(!step3)
}

@Test func splitMergeUnwrapAndDeleteKeepTheTreeTidy() {
    let value = DesignNode.text([.value("cpu")])
    var design = SpriteDesign(root: .row([value]), variables: [SpriteVariable(id: "cpu", name: "CPU", source: .reading(metric: "cpu.usage"))])
    let label = design.split(value.id, axis: .column)!
    #expect(design.root.children[0].kind == .column)
    #expect(design.root.children[0].children.map(\.id) == [value.id, label])
    let second = design.split(value.id, axis: .row)!
    let step4 = design.mergeWithNext(value.id); #expect(step4)
    #expect(design.root.find(second) == nil)
    #expect(design.root.find(value.id)?.segments == [.value("cpu"), .literal("Text")])
    // Deleting the label leaves a one-child column, which folds into the value.
    let rule = SpriteRule(branches: [RuleBranch(conditions: [RuleCondition(variable: "cpu")],
                                                actions: [RuleAction(target: label)])])
    design.rules = [rule]
    let step5 = design.delete(label); #expect(step5)
    #expect(design.root.children.map(\.id) == [value.id])
    #expect(design.rules[0].branches[0].actions.isEmpty)
    // Deleting a variable drops it from texts.
    design.variables = []; design.prune()
    #expect(design.root.find(value.id)?.segments == [.literal("Text")])
}

@Test @MainActor func rendererDrawsNestedLayoutsWithinTheBar() {
    var column = DesignNode.column([DesignNode.text([.literal("CPU")], size: 9), DesignNode.text([.value("cpu")], size: 20)])
    column.style.gap = 1.5
    var root = DesignNode.row([DesignNode(kind: .icon, symbol: "cpu"), column], gap: 5); root.style.padding = 3
    let design = SpriteDesign(root: root, variables: [SpriteVariable(id: "cpu", name: "CPU", source: .reading(metric: "cpu.usage"))])
    let output = DesignRenderer.render(design, values: values(["cpu.usage": 42]), height: 24)
    #expect(output.size.height == 24)
    #expect(output.isTemplate)
    for placed in output.placed { #expect(placed.frame.minY >= 0 && placed.frame.maxY <= 24, "\(placed.id) \(placed.frame)") }
    let texts = output.placed.filter { $0.kind == .text }
    #expect(texts.map(\.text) == ["CPU", "42"])
    // The 20 pt value shrank so both lines fit the 22 pt band.
    #expect(texts[1].fontSize < 20)
    #expect(output.placed.first { $0.kind == .icon }!.frame.minX == 3)
}
