import AppKit
import Foundation
import Testing
@testable import SystemMonitoring

@Test func colorRulesPreserveLegacySpritesAndRoundTrip() throws {
    var config = SpriteConfiguration()
    let legacyData = try JSONEncoder().encode(config)
    #expect(try JSONDecoder().decode(SpriteConfiguration.self, from: legacyData).colorRule == .fixed)
    for rule in [SpriteColorRule.usagePace, .usagePacePercent] {
        config.colorRule = rule
        let restored = try JSONDecoder().decode(SpriteConfiguration.self, from: JSONEncoder().encode(config))
        #expect(restored == config && restored.colorRule == rule)
    }
}

@Test @MainActor func readoutsHaveSideMarginsAndIndependentFilledIconColor() throws {
    var config = SpriteConfiguration(); config.symbol = "fan.fill"; config.colorHex = "FFFFFF"
    config.iconColorHex = "79BFFA"; config.showIcon = true
    let columns = [ReadoutColumn(label: "TEMP", value: "76.6"), ReadoutColumn(label: "FAN", value: "3648")]
    #expect(NSImage(systemSymbolName: config.symbol, accessibilityDescription: nil) != nil)
    for layout in SpriteReadoutLayout.allCases {
        config.layout = layout
        let placed = StackedReadout.layout(columns: columns, config: config, height: 24)
        #expect(placed.iconRect.minX == 3)
        #expect(placed.size.width - (placed.columns.map(\.value.maxX).max() ?? 0) == 3)
        let bitmap = try #require(StackedReadout.image(columns: columns, config: config, height: 24).tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        var blue = 0, white = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let ink = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), ink.alphaComponent > 0.5 else { continue }
                if ink.blueComponent > ink.redComponent * 1.5 { blue += 1 }
                if ink.redComponent > 0.95 && ink.greenComponent > 0.95 && ink.blueComponent > 0.95 { white += 1 }
            }
        }
        #expect(blue > 0 && white > 0)
    }
    let restored = try JSONDecoder().decode(SpriteConfiguration.self, from: JSONEncoder().encode(config))
    #expect(restored.iconColorHex == "79BFFA")
    let legacy = try JSONDecoder().decode(SpriteConfiguration.self, from: JSONEncoder().encode(SpriteConfiguration()))
    #expect(legacy.iconColorHex == "text")
}

@Test @MainActor func percentOnlyPaceKeepsDigitsAndLabelsWhite() throws {
    var config = SpriteConfiguration(); config.showIcon = false; config.bold = true
    config.colorHex = "FFFFFF"; config.colorRule = .usagePacePercent
    let columns = [ReadoutColumn(label: "Claude", value: "49%", colorHex: "FF453A")]
    let title = StackedReadout.attributedText(columns: columns, config: config)
    #expect(title.string == "Claude 49%")
    for index in 0..<(title.length - 1) {
        let ink = try #require(title.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor)
        #expect(ink.redComponent == 1 && ink.greenComponent == 1 && ink.blueComponent == 1)
    }
    let percentInk = try #require(title.attribute(.foregroundColor, at: title.length - 1, effectiveRange: nil) as? NSColor)
    #expect(percentInk.redComponent > percentInk.greenComponent * 2)
    for layout in [SpriteReadoutLayout.stacked, .twoRows] {
        config.layout = layout
        let image = StackedReadout.image(columns: columns, config: config, height: 24)
        #expect(!image.isTemplate)
        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        var whitePixels = 0, redPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let ink = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), ink.alphaComponent > 0.5 else { continue }
                if ink.redComponent > 0.95 && ink.greenComponent > 0.95 && ink.blueComponent > 0.95 { whitePixels += 1 }
                if ink.redComponent > ink.greenComponent * 2 { redPixels += 1 }
            }
        }
        #expect(whitePixels > 0 && redPixels > 0)
    }
    let noUnits = StackedReadout.attributedText(columns: [.init(label: "Claude", value: "49", colorHex: "FF453A")], config: config)
    let lastInk = try #require(noUnits.attribute(.foregroundColor, at: noUnits.length - 1, effectiveRange: nil) as? NSColor)
    #expect(lastInk.greenComponent == 1)
}

@Test @MainActor func independentColorsSurviveInlineAndImageRendering() throws {
    var config = SpriteConfiguration(); config.showIcon = false; config.layout = .twoRows
    let columns = [ReadoutColumn(label: "CL 5h", value: "10%", colorHex: "34C759"),
                   ReadoutColumn(label: "CL 7d", value: "70%", colorHex: "FF453A")]
    let title = StackedReadout.attributedText(columns: columns, config: config)
    #expect(title.string == "CL 5h 10%  CL 7d 70%")
    let green = try #require(title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
    let red = try #require(title.attribute(.foregroundColor, at: title.length - 1, effectiveRange: nil) as? NSColor)
    #expect(green.greenComponent > green.redComponent && red.redComponent > red.greenComponent)
    let image = StackedReadout.image(columns: columns, config: config, height: 24)
    #expect(!image.isTemplate)
    let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
    var greenPixels = 0, redPixels = 0
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
            guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), pixel.alphaComponent > 0.5 else { continue }
            if pixel.greenComponent > pixel.redComponent * 1.5 { greenPixels += 1 }
            if pixel.redComponent > pixel.greenComponent * 1.5 { redPixels += 1 }
        }
    }
    #expect(greenPixels > 0 && redPixels > 0)
    #expect(StackedReadout.image(columns: [.init(label: "CPU", value: "10%")], config: config, height: 24).isTemplate)
    config.enabled = false
    let paused = StackedReadout.attributedText(columns: columns, config: config)
    #expect(paused.string == "Paused" && paused.attribute(.foregroundColor, at: 0, effectiveRange: nil) == nil)
}

@Test func memoryPressureRuleMapsKernelLevelsAndLeavesUnknownUncolored() throws {
    #expect(SpriteColorRule.memoryPressureHex("Normal") == "30D158")
    #expect(SpriteColorRule.memoryPressureHex("Warning") == "FFD60A")
    #expect(SpriteColorRule.memoryPressureHex("Critical") == "FF453A")
    #expect(SpriteColorRule.memoryPressureHex(nil) == nil && SpriteColorRule.memoryPressureHex("Unknown") == nil)
    var config = SpriteConfiguration(metricIDs: ["memory.usage"]); config.colorRule = .memoryPressure
    #expect(try JSONDecoder().decode(SpriteConfiguration.self, from: JSONEncoder().encode(config)).colorRule == .memoryPressure)
    #expect(SpriteConfiguration.initial.first { $0.metricIDs == ["memory.usage"] }?.colorRule == .memoryPressure)
}

@Test func powerDrawRuleColorsWattsByThreshold() throws {
    #expect(SpriteColorRule.powerDrawHex(nil) == nil && SpriteColorRule.powerDrawHex(.nan) == nil)
    #expect(SpriteColorRule.powerDrawHex(12) == nil && SpriteColorRule.powerDrawHex(34.9) == nil)
    #expect(SpriteColorRule.powerDrawHex(35) == "FFD60A" && SpriteColorRule.powerDrawHex(45) == "FFD60A")
    #expect(SpriteColorRule.powerDrawHex(45.1) == "FF453A" && SpriteColorRule.powerDrawHex(90) == "FF453A")
    var config = SpriteConfiguration(metricIDs: ["sensor.PSTR"]); config.colorRule = .powerDraw
    #expect(try JSONDecoder().decode(SpriteConfiguration.self, from: JSONEncoder().encode(config)).colorRule == .powerDraw)
    #expect(SpriteConfiguration.initial.first { $0.metricIDs == ["sensor.PSTR"] }?.colorRule == .powerDraw)
}

@Test func levelBarThresholdsColorOnlyAboveTheLinesAndSurviveDecoding() throws {
    var config = SpriteConfiguration()
    #expect(config.barHex(percent: 60) == nil && config.barHex(percent: 61) == "FFD60A")
    #expect(config.barHex(percent: 85) == "FFD60A" && config.barHex(percent: 86) == "FF453A")
    config.layout = .bar; config.barWarning = 90; config.barAlert = 50
    config.normalize()
    #expect(config.barWarning == 90 && config.barAlert == 95)
    let restored = try JSONDecoder().decode(SpriteConfiguration.self, from: JSONEncoder().encode(config))
    #expect(restored == config && restored.layout == .bar)
}

@Test @MainActor func levelBarIsNarrowerThanTextAndFillsFromTheBottom() throws {
    var config = SpriteConfiguration(); config.showIcon = false; config.fontSize = 14
    let columns = [ReadoutColumn(label: "CPU", value: "100%", level: 0.5)]
    config.layout = .stacked
    let stacked = StackedReadout.layout(columns: columns, config: config, height: 24).size.width
    config.layout = .bar
    let placed = StackedReadout.layout(columns: columns, config: config, height: 24)
    #expect(placed.size.width == StackedReadout.barWidth + 2 * StackedReadout.horizontalPadding)
    #expect(placed.size.width < stacked / 2)
    let bitmap = try #require(StackedReadout.image(columns: columns, config: config, height: 24).tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
    func inked(_ row: Int) -> Bool {
        (0..<bitmap.pixelsWide).contains { (bitmap.colorAt(x: $0, y: row)?.alphaComponent ?? 0) > 0.9 }
    }
    // Bitmap rows run top-down: half full means solid ink low in the bar, none high up.
    let bar = placed.columns[0].value
    let scale = CGFloat(bitmap.pixelsHigh) / 24
    #expect(inked(Int((24 - bar.minY - 3) * scale)))
    #expect(!inked(Int((24 - bar.maxY + 3) * scale)))
}

@Test @MainActor func memoryPressureColorsOnlyTheLabel() throws {
    var config = SpriteConfiguration(metricIDs: ["memory.usage"]); config.colorHex = "FFFFFF"
    config.colorRule = .memoryPressure; config.layout = .inline
    let text = StackedReadout.attributedText(columns: [ReadoutColumn(label: "RAM", value: "62%", colorHex: "30D158")], config: config)
    func ink(_ at: Int) -> NSColor? { (text.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor)?.usingColorSpace(.deviceRGB) }
    let label = try #require(ink(0)), value = try #require(ink(text.length - 1))
    #expect(label.greenComponent > 0.7 && label.redComponent < 0.3)
    #expect(value.redComponent > 0.95 && value.greenComponent > 0.95 && value.blueComponent > 0.95)
}

@Test @MainActor func powerDrawColorsOnlyTheLabel() throws {
    var config = SpriteConfiguration(metricIDs: ["sensor.PSTR"]); config.colorHex = "FFFFFF"
    config.colorRule = .powerDraw; config.layout = .inline
    let text = StackedReadout.attributedText(columns: [ReadoutColumn(label: "PWR", value: "52 W", colorHex: "FF453A")], config: config)
    func ink(_ at: Int) -> NSColor? { (text.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor)?.usingColorSpace(.deviceRGB) }
    let label = try #require(ink(0)), value = try #require(ink(text.length - 1))
    #expect(label.redComponent > 0.9 && label.greenComponent < 0.4)
    #expect(value.redComponent > 0.95 && value.greenComponent > 0.95 && value.blueComponent > 0.95)
}
