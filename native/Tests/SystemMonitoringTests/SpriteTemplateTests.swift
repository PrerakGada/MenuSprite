import Foundation
import Testing
@testable import SystemMonitoring

private func metric(_ id: String) -> Metric? { MonitoringCatalog.base.first { $0.id == id } }

@Test func templateIDsAreUniqueAndEveryCategoryHasChoices() {
    let ids = SpriteTemplates.all.map(\.id)
    #expect(Set(ids).count == ids.count)
    for category in SpriteTemplate.Category.allCases {
        #expect(SpriteTemplates.templates(in: category).count >= 3, "\(category.rawValue) needs a few choices")
    }
}

@Test func everyTemplateReadsOnlyCatalogReadings() {
    for template in SpriteTemplates.all {
        for id in template.readingIDs { #expect(metric(id) != nil, "\(template.id) reads unknown \(id)") }
    }
}

@Test func everyTemplateMakesADrawableSpriteThatRemembersItsTemplate() throws {
    for template in SpriteTemplates.all {
        let config = template.make(metric: metric)
        let design = try #require(config.design, "\(template.id) has no design")
        #expect(config.templateID == template.id)
        // A status icon (Bluetooth's mark and dot) shows its readings only through rules.
        #expect(!(design.displayedReadingIDs + design.ruleOnlyReadingIDs).isEmpty, "\(template.id) uses no reading")
        #expect(config.enabled && config.showInMenuBar)
        // Rules only ever point at nodes that exist.
        let nodes = Set(design.root.flattened.map(\.id))
        for action in design.rules.flatMap({ $0.branches.flatMap(\.actions) + $0.otherwise }) {
            #expect(nodes.contains(action.target), "\(template.id) rule targets a missing node")
        }
    }
    // Two sprites from one template are two sprites.
    let template = try #require(SpriteTemplates.template("cpu.stacked"))
    #expect(template.make(metric: metric).id != template.make(metric: metric).id)
}

@Test func setsAndStartersNameRealTemplates() {
    for id in SpriteTemplates.starterIDs { #expect(SpriteTemplates.template(id) != nil, "\(id)") }
    for set in SpriteTemplates.sets {
        #expect(!set.templateIDs.isEmpty)
        for id in set.templateIDs { #expect(SpriteTemplates.template(id) != nil, "\(set.id) names \(id)") }
    }
}

@Test func aNewMacStartsWithTheStarterTemplates() {
    let initial = SpriteConfiguration.initial
    #expect(initial.map(\.templateID) == SpriteTemplates.starterIDs)
    #expect(initial.map(\.metricIDs) == [["cpu.usage"], ["memory.usage"], ["sensor.PSTR"], ["network.upload", "network.download"],
                                         ["sensor.fanSpeed", "sensor.cpuTemperature"], ["battery.charge"]])
    #expect(Set(initial.map(\.id)).count == initial.count)
    // Converted on load, as before the gallery.
    #expect(initial.allSatisfy { $0.design == nil })
}

@Test func resetGoesBackToTheTemplateAndKeepsWhatBelongsToTheSprite() throws {
    let template = try #require(SpriteTemplates.template("memory.pressure"))
    var config = template.make(metric: metric)
    config.name = "Mine"; config.interval = 60; config.enabled = false; config.showInMenuBar = false
    config.design?.rules = []
    let reset = template.reset(config, metric: metric)
    #expect(reset.id == config.id)
    #expect(!reset.enabled && !reset.showInMenuBar)
    #expect(reset.name == "RAM" && reset.interval == 2)
    #expect(reset.design?.rules.count == 1)
    #expect(reset.templateID == template.id)
}

@Test func templateIDSurvivesSavingAndOldFilesDecodeWithoutOne() throws {
    let config = try #require(SpriteTemplates.template("battery.glyph")).make(metric: metric)
    let decoded = try JSONDecoder().decode(SpriteConfiguration.self, from: JSONEncoder().encode(config))
    #expect(decoded.templateID == "battery.glyph")
    var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as! [String: Any]
    old.removeValue(forKey: "templateID")
    let legacy = try JSONDecoder().decode(SpriteConfiguration.self, from: JSONSerialization.data(withJSONObject: old))
    #expect(legacy.templateID == nil)
}
